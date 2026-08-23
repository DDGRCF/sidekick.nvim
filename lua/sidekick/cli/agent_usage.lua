local Util = require("sidekick.util")

local M = {}

local CACHE_MS = 1500
local CACHE_MAX = 64
local FILE_READ_MAX = 512 * 1024
local FILE_CACHE_MAX = 64
local cache = {} ---@type table<string,{at:number,pending?:boolean,ready?:boolean,value?:sidekick.cli.ContextUsage,source_buf?:integer,source_tick?:integer}>
local file_cache = {} ---@type table<string,{at:number,size:integer,stamp:string,dev?:integer,ino?:integer,partial?:string,value?:sidekick.cli.ContextUsage}>

---@param keep? string
local function prune_file_cache(keep)
  while vim.tbl_count(file_cache) > FILE_CACHE_MAX do
    local oldest_key, oldest_at
    for key, entry in pairs(file_cache) do
      if key ~= keep and (not oldest_at or entry.at < oldest_at) then
        oldest_key, oldest_at = key, entry.at
      end
    end
    if not oldest_key then
      break
    end
    file_cache[oldest_key] = nil
  end
end

---@class sidekick.cli.ContextUsage
---@field used number
---@field max? number
---@field percent? number

local function valid(value)
  if type(value) ~= "table" or type(value.used) ~= "number" or value.used < 0 then
    return
  end
  local max = type(value.max) == "number" and value.max > 0 and value.max or nil
  if max and value.used > max then
    return
  end
  local percent = max and math.floor(value.used / max * 100 + 0.5) or value.percent
  if type(percent) == "number" and percent >= 0 and percent <= 100 then
    percent = math.floor(percent + 0.5)
  else
    percent = nil
  end
  return { used = value.used, max = max, percent = percent }
end

local function amount(value)
  value = value:gsub("[%s,]", ""):lower()
  local suffix = value:sub(-1)
  local scale = ({ k = 1e3, m = 1e6, g = 1e9 })[suffix] or 1
  if scale ~= 1 then
    value = value:sub(1, -2)
  end
  local number = tonumber(value)
  return number and number * scale or nil
end

local function latest_pair(text)
  local latest
  local token = "([%d][%d%.,]*%s*[kmg]?)"
  for used, max in text:gmatch("context[^%d\n]*" .. token .. "%s*/%s*" .. token) do
    used, max = amount(used), amount(max)
    if used and max then
      latest = valid({ used = used, max = max })
    end
  end
  for used, max in text:gmatch("context[^%d\n]*" .. token .. "%s+of%s+" .. token) do
    used, max = amount(used), amount(max)
    if used and max then
      latest = valid({ used = used, max = max })
    end
  end
  return latest
end

local function latest_percent(text, label, invert)
  local latest
  for percent in text:gmatch("context%s+" .. label .. "[^%d\n]*(%d+%.?%d*)%%") do
    percent = tonumber(percent)
    if percent then
      latest = invert and 100 - percent or percent
    end
  end
  return latest and valid({ used = latest, max = 100 }) or nil
end

---@param output? string
---@return sidekick.cli.ContextUsage?
function M.parse(output)
  if type(output) ~= "string" then
    return
  end
  -- Multiplexer dumps can include terminal control sequences around status text.
  output = output:gsub("\27%[[0-?]*[ -/]*[@-~]", ""):lower():gsub("tokens?", "")
  return latest_pair(output)
    or latest_percent(output, "left", true)
    or latest_percent(output, "remaining", true)
    or latest_percent(output, "used", false)
    or latest_percent(output, "usage", false)
end

---@param output? string
---@return sidekick.cli.ContextUsage?
function M.parse_codex(output)
  if type(output) ~= "string" then
    return
  end
  local latest
  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    if line:find('"token_count"', 1, true) then
      local ok, event = pcall(vim.json.decode, line)
      local info = ok and event.payload and event.payload.type == "token_count" and event.payload.info or nil
      local max = info and tonumber(info.model_context_window) or nil
      if max then
        for _, usage in ipairs({ info.total_token_usage or false, info.last_token_usage or false }) do
          if type(usage) == "table" then
            latest = valid({ used = tonumber(usage.total_tokens), max = max })
              or valid({ used = tonumber(usage.input_tokens), max = max })
              or latest
          end
        end
      end
    end
  end
  return latest
end

---@param output? string
---@return sidekick.cli.ContextUsage?
function M.parse_claude(output)
  if type(output) ~= "string" then
    return
  end
  local latest
  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    local ok, event = pcall(vim.json.decode, line)
    local message = ok and event.type == "assistant" and event.message or nil
    local usage = type(message) == "table" and message.usage or nil
    if type(usage) == "table" then
      local used, found = 0, false
      for _, key in ipairs({ "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens" }) do
        local value = tonumber(usage[key])
        if value then
          used = used + value
          found = true
        end
      end
      if found then
        latest = valid({ used = used }) or latest
      end
    end
  end
  return latest
end

---@param response? string|table
---@return sidekick.cli.ContextUsage?
function M.parse_opencode(response)
  if type(response) == "string" then
    local ok, decoded = pcall(vim.json.decode, response)
    response = ok and decoded or nil
  end
  if type(response) ~= "table" then
    return
  end
  local latest
  for _, item in ipairs(response) do
    local info = type(item) == "table" and item.info or nil
    local tokens = type(info) == "table" and info.role == "assistant" and info.tokens or nil
    if type(tokens) == "table" then
      local used, found = 0, false
      local cache = type(tokens.cache) == "table" and tokens.cache or {}
      for _, value in ipairs({ tokens.input, tokens.output, tokens.reasoning, cache.read, cache.write }) do
        value = tonumber(value)
        if value then
          used = used + value
          found = true
        end
      end
      if found then
        latest = valid({ used = used }) or latest
      end
    end
  end
  return latest
end

---@param path string
---@param parser fun(output?:string):sidekick.cli.ContextUsage?
---@param cb fun(value?:sidekick.cli.ContextUsage)
local function read_incremental(path, parser, cb)
  local key = path .. "\31" .. tostring(parser)
  vim.uv.fs_stat(path, function(stat_err, stat)
    if stat_err or not stat then
      file_cache[key] = nil
      cb()
      return
    end

    local mtime = stat.mtime or {}
    local stamp = table.concat({ stat.dev or "", stat.ino or "", mtime.sec or "", mtime.nsec or "" }, ":")
    local previous = file_cache[key]
    local same_file = previous and previous.dev == stat.dev and previous.ino == stat.ino
    if previous and same_file and previous.size == stat.size and previous.stamp == stamp then
      previous.at = vim.uv.now()
      cb(previous.value)
      return
    end

    local incremental = same_file and previous.size < stat.size and stat.size - previous.size <= FILE_READ_MAX
    local offset = incremental and previous.size or math.max(0, stat.size - FILE_READ_MAX)
    local size = stat.size - offset
    if size == 0 then
      file_cache[key] = { at = vim.uv.now(), size = stat.size, stamp = stamp, dev = stat.dev, ino = stat.ino }
      prune_file_cache(key)
      cb()
      return
    end

    vim.uv.fs_open(path, "r", 438, function(open_err, fd)
      if open_err or not fd then
        cb(previous and previous.value or nil)
        return
      end
      vim.uv.fs_read(fd, size, offset, function(read_err, data)
        vim.uv.fs_close(fd)
        if read_err or not data then
          cb(previous and previous.value or nil)
          return
        end

        -- A capped initial read may begin in the middle of a JSONL record.
        if not incremental and offset > 0 then
          local newline = data:find("\n", 1, true)
          data = newline and data:sub(newline + 1) or ""
        end
        if incremental and previous and previous.partial and previous.partial ~= "" then
          data = previous.partial .. data
        end

        local value = parser(data)
        local partial = data:match("([^\n]*)$")
        file_cache[key] = {
          at = vim.uv.now(),
          size = stat.size,
          stamp = stamp,
          dev = stat.dev,
          ino = stat.ino,
          partial = partial and partial:sub(-64 * 1024) or nil,
          value = value or (incremental and previous and previous.value or nil),
        }
        prune_file_cache(key)
        cb(file_cache[key].value)
      end)
    end)
  end)
end

local function terminal_output(terminal, cb)
  if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
    local count = vim.api.nvim_buf_line_count(terminal.buf)
    local output = table.concat(vim.api.nvim_buf_get_lines(terminal.buf, math.max(0, count - 400), count, false), "\n")
    return vim.schedule(function()
      cb(M.parse(output))
    end)
  end
  local source = type(terminal.dump_async) == "function" and terminal
    or (terminal.parent and type(terminal.parent.dump_async) == "function" and terminal.parent or nil)
  if source then
    source:dump_async(function(output)
      cb(M.parse(output))
    end)
  else
    vim.schedule(function()
      cb()
    end)
  end
end

local function prune()
  while vim.tbl_count(cache) > CACHE_MAX do
    local oldest_key, oldest_at
    for key, entry in pairs(cache) do
      if not oldest_at or entry.at < oldest_at then
        oldest_key, oldest_at = key, entry.at
      end
    end
    cache[oldest_key] = nil
  end
end

local function fetch(terminal, done)
  local usage = terminal.tool and terminal.tool.config and terminal.tool.config.usage
  if type(usage) == "function" then
    local ok, ret = pcall(usage, terminal.tool, terminal, done)
    if type(ret) == "table" then
      return done(ret)
    elseif ret == true then
      return
    end
  end
  terminal_output(terminal, done)
end

local function fallback_source(terminal)
  local usage = terminal.tool and terminal.tool.config and terminal.tool.config.usage
  if type(usage) == "function" then
    return
  end
  local buf = terminal.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf, vim.api.nvim_buf_get_changedtick(buf)
  end
end

---@param terminal sidekick.cli.Terminal
---@return sidekick.cli.ContextUsage?
function M.get(terminal)
  if terminal.closed then
    return
  end
  local key = table.concat({ terminal.id, terminal.instance_id or "" }, ":")
  local entry = cache[key]
  local now = vim.uv.now()
  if entry and (entry.pending or (entry.ready and now - entry.at <= CACHE_MS)) then
    return entry.value
  end
  local source_buf, source_tick = fallback_source(terminal)
  if entry and entry.ready and source_buf and entry.source_buf == source_buf and entry.source_tick == source_tick then
    entry.at = now
    return entry.value
  end
  entry = entry or { at = 0 }
  entry.at = now
  entry.pending = true
  entry.ready = false
  cache[key] = entry
  vim.schedule(function()
    local completed = false
    local function done(value)
      if completed or cache[key] ~= entry then
        return
      end
      completed = true
      local previous = entry.value
      entry.at = vim.uv.now()
      entry.pending = false
      entry.ready = true
      entry.value = valid(value)
      entry.source_buf = source_buf
      entry.source_tick = source_tick
      prune()
      if not vim.deep_equal(previous, entry.value) then
        vim.schedule(function()
          Util.emit("SidekickCliUsage", { id = terminal.id, usage = entry.value })
        end)
      end
    end
    local ok = pcall(fetch, terminal, done)
    if not ok then
      done()
    end
  end)
  return entry.value
end

---@param _? sidekick.cli.Tool
---@param terminal sidekick.cli.Terminal
---@param cb fun(value?:sidekick.cli.ContextUsage)
---@return boolean?
function M.codex(_, terminal, cb)
  local conversation = terminal.conversation or (terminal.parent and terminal.parent.conversation)
  local path = conversation and conversation.data and conversation.data.path
  if type(path) ~= "string" or path == "" then
    return
  end
  read_incremental(path, M.parse_codex, cb)
  return true
end

---@param _? sidekick.cli.Tool
---@param terminal sidekick.cli.Terminal
---@param cb fun(value?:sidekick.cli.ContextUsage)
---@return boolean?
function M.claude(_, terminal, cb)
  local conversation = terminal.conversation or (terminal.parent and terminal.parent.conversation)
  local path = conversation and conversation.data and conversation.data.path
  if type(path) ~= "string" or path == "" then
    return
  end
  read_incremental(path, M.parse_claude, cb)
  return true
end

---@param terminal sidekick.cli.Terminal
local function opencode_session(terminal)
  local conversation = terminal.conversation or (terminal.parent and terminal.parent.conversation)
  local id = conversation and conversation.id
  local base_url = terminal.base_url or (terminal.parent and terminal.parent.base_url)
  if
    type(id) ~= "string"
    or not id:match("^[%w_-]+$")
    or type(base_url) ~= "string"
    or not (
      base_url:match("^https?://localhost:%d+$")
      or base_url:match("^https?://127%.0%.0%.1:%d+$")
      or base_url:match("^https?://%[::1%]:%d+$")
    )
  then
    return
  end
  return base_url, id
end

---@param _? sidekick.cli.Tool
---@param terminal sidekick.cli.Terminal
---@param cb fun(value?:sidekick.cli.ContextUsage)
---@return boolean?
function M.opencode(_, terminal, cb)
  local base_url, id = opencode_session(terminal)
  if not base_url or not id then
    return
  end
  vim.system(
    { "curl", "-sS", "--max-time", "1", base_url .. "/session/" .. id .. "/message" },
    { text = true },
    function(result)
      cb(type(result) == "table" and result.code == 0 and M.parse_opencode(result.stdout) or nil)
    end
  )
  return true
end

function M.clear()
  cache = {}
  file_cache = {}
end

return M
