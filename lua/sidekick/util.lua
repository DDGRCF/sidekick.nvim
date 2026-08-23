local M = {}

---@class sidekick.NotifyOpts
---@field when? fun():boolean

---@param msg string|string[]
---@param level? vim.log.levels
---@param opts? sidekick.NotifyOpts
function M.notify(msg, level, opts)
  msg = type(msg) == "table" and table.concat(msg, "\n") or msg
  vim.schedule(function()
    if opts and opts.when then
      local ok, show = pcall(opts.when)
      if not ok or not show then
        return
      end
    end
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Sidekick" })
  end)
end

---@param msg string|string[]
function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

---@param msg string|string[]
function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---@param msg string|string[]
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string|string[]
---@param what? any
function M.debug(msg, what)
  if require("sidekick.config").debug then
    if what ~= nil then
      msg = type(msg) == "table" and msg or { msg } ---@type string[]
      msg[#msg + 1] = "```lua"
      msg[#msg + 1] = vim.inspect(what)
      msg[#msg + 1] = "```"
    end
    M.warn(msg)
  end
end

---@generic T
---@param t T
---@return { value?:T }|fun():T?
function M.ref(t)
  return setmetatable({ value = t }, {
    __mode = "v",
    __call = function(m)
      return m.value
    end,
  })
end

---@generic T
---@param fn T
---@param ms? number
---@return T
function M.debounce(fn, ms)
  local timer = assert(vim.uv.new_timer())
  return function(...)
    local args = { ... }
    timer:start(
      ms or 20,
      0,
      vim.schedule_wrap(function()
        pcall(fn, unpack(args))
      end)
    )
  end
end

--- @param buffer integer Buffer id, or 0 for current buffer
--- @param ns_id integer Namespace id from `nvim_create_namespace()`
--- @param row integer Line where to place the mark, 0-based. `api-indexing`
--- @param col integer Column where to place the mark, 0-based. `api-indexing`
--- @param opts vim.api.keyset.set_extmark Optional parameters.
function M.set_extmark(buffer, ns_id, row, col, opts)
  -- opts.strict = false
  local ok, ret = pcall(vim.api.nvim_buf_set_extmark, buffer, ns_id, row, col, opts or {})
  if not ok then
    local e = vim.deepcopy(opts) --[[@as sidekick.Extmark]]
    e.row, e.col = row, col
    M.error("Failed to set extmark: " .. ret .. "\n```lua\n" .. vim.inspect(e) .. "\n```")
    return nil
  end
  return ret
end

--- Exit visual mode if in visual mode, and return the type of visual mode exited.
function M.exit_visual_mode()
  local kind, mode = M.visual_mode()
  if not mode then
    return
  end
  vim.cmd("normal! " .. mode)
  return kind, mode
end

--- Exit visual mode if in visual mode, and return the type of visual mode exited.
---@return sidekick.VisualMode?, string?
function M.visual_mode()
  ---@alias sidekick.VisualMode "char"|"line"|"block"
  local mode = vim.fn.mode()
  if not (mode:match("^[vV]$") or mode == "\22") then
    return
  end
  return (mode == "V" and "line" or mode == "v" and "char" or "block"), mode
end

---@param str string
function M.width(str)
  str = str:gsub("\t", string.rep(" ", vim.o.tabstop))
  return vim.api.nvim_strwidth(str)
end

--- UTF-8 aware word splitting. See |keyword|
---@param str string
function M.split_words(str)
  if str == "" then
    return {}
  end

  local ret = {} ---@type string[]
  local word = {} ---@type string[]
  local starts = vim.str_utf_pos(str)

  local function flush()
    if #word > 0 then
      ret[#ret + 1] = table.concat(word)
      word = {}
    end
  end

  for idx, start in ipairs(starts) do
    local stop = (starts[idx + 1] or (#str + 1)) - 1
    local ch = str:sub(start, stop)
    if vim.fn.charclass(ch) == 2 then -- iskeyword
      word[#word + 1] = ch
    else
      flush()
      ret[#ret + 1] = ch
    end
  end

  flush()
  return ret
end

--- UTF-8 aware character splitting
---@param str string
function M.split_chars(str)
  if str == "" then
    return {}
  end

  local ret = {} ---@type string[]
  local starts = vim.str_utf_pos(str)
  for i = 1, #starts - 1 do
    table.insert(ret, str:sub(starts[i], starts[i + 1] - 1))
  end
  table.insert(ret, str:sub(starts[#starts], #str))
  return ret
end

--- Split a string into composed characters without breaking combining marks.
---@param str string
function M.split_graphemes(str)
  local ret = {} ---@type string[]
  for i = 0, vim.fn.strchars(str, true) - 1 do
    ret[#ret + 1] = vim.fn.strcharpart(str, i, 1, true)
  end
  return ret
end

function M.deprecate(deprecated, replacement)
  M.warn(("`%s` is deprecated.\nPlease use `%s` instead."):format(deprecated, replacement))
end

---@param cmd string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
function M.exec(cmd, opts)
  opts = opts or {}
  opts.text = true
  local result = vim.system(cmd, opts):wait()
  if result.code ~= 0 or not result.stdout then
    if opts.notify ~= false then
      M.error(("Command failed: `%s`\n%s"):format(table.concat(vim.tbl_map(tostring, cmd), " "), result.stderr or ""))
    end
    return nil
  end
  return vim.split(result.stdout, "\n", { plain = true, trimempty = true }), result.stdout
end

---@class sidekick.util.Curl
---@field method? "GET"|"POST"|"PUT"|"DELETE" HTTP method
---@field headers? table<string, string> HTTP headers
---@field data? any Request body
---@field timeout_ms? integer Maximum request time in milliseconds

---@param url string
---@param opts? sidekick.util.Curl
---@return string? response
function M.curl(url, opts)
  opts = opts or {}

  local cmd = { "curl", "-s", "-S" }

  if opts.method then
    vim.list_extend(cmd, { "-X", opts.method })
  end

  if opts.timeout_ms then
    local seconds = math.max(1, opts.timeout_ms) / 1000
    vim.list_extend(cmd, { "--max-time", ("%.3f"):format(seconds) })
  end

  for key, value in pairs(opts.headers or {}) do
    vim.list_extend(cmd, { "-H", ("%s: %s"):format(key, value) })
  end

  -- Handle JSON data
  if type(opts.data) == "string" then
    vim.list_extend(cmd, { "-d", opts.data })
  elseif opts.data ~= nil then
    local ok, json = pcall(vim.json.encode, opts.data)
    if not ok then
      M.error("Failed to encode JSON data")
      return
    end
    vim.list_extend(cmd, { "-H", "Content-Type: application/json" })
    vim.list_extend(cmd, { "-d", json })
  end

  table.insert(cmd, url)

  local ret = M.exec(cmd)
  return ret and table.concat(ret, "\n") or nil
end

local state_dir = vim.fn.stdpath("state") .. "/sidekick"

---@param key string
---@param value any
function M.set_state(key, value)
  vim.fn.mkdir(state_dir, "p")
  local path = state_dir .. "/" .. key .. ".json"
  local ok, data = pcall(vim.json.encode, value)
  if not ok then
    return false, "failed to encode state: " .. tostring(data)
  end
  local tmp = ("%s.tmp.%d.%s"):format(path, vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, "failed to open temporary state: " .. tostring(err)
  end
  local wrote, write_err = f:write(data)
  local flushed, flush_err = f:flush()
  f:close()
  if not wrote or not flushed then
    vim.fn.delete(tmp)
    return false, "failed to write state: " .. tostring(write_err or flush_err)
  end
  if vim.uv.fs_stat(path) then
    pcall(vim.uv.fs_copyfile, path, path .. ".bak")
  end
  local renamed, rename_err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    vim.fn.delete(tmp)
    return false, "failed to replace state: " .. tostring(rename_err)
  end
  return true
end

---@param key string
---@return any
function M.get_state(key)
  local path = state_dir .. "/" .. key .. ".json"
  local f = io.open(path, "r")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, result = pcall(vim.json.decode, data)
    return ok and result or nil
  end
end

---@param key string
function M.del_state(key)
  vim.fn.delete(state_dir .. "/" .. key .. ".json")
end

---@param event string
---@param data? any
function M.emit(event, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event,
    modeline = false,
    data = data,
  })
end

---@generic T: table
---@param ... T
---@return T
function M.merge(...)
  local todo = {} ---@type table[]
  for i = 1, select("#", ...) do
    local o = select(i, ...)
    if type(o) == "table" then
      todo[#todo + 1] = vim.deepcopy(o)
    end
  end
  return #todo == 0 and {} or #todo == 1 and todo[1] or vim.tbl_deep_extend("force", unpack(todo))
end

---@param a any[]
---@param b any[]
function M.overlaps(a, b)
  local set = {} ---@type table<any, boolean>
  for _, v in ipairs(a) do
    set[v] = true
  end
  for _, v in ipairs(b) do
    if set[v] then
      return true
    end
  end
  return false
end

---@param buf number
---@param pos sidekick.Pos
---@private
function M.fix_pos(buf, pos)
  local last_line = vim.api.nvim_buf_line_count(buf) - 1
  if pos[1] > last_line then
    return { last_line, #(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or "") }
  end
  return pos
end

return M
