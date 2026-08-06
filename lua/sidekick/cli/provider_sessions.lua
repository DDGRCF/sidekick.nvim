local Procs = require("sidekick.cli.procs")
local Util = require("sidekick.util")

local M = {}

M.roots = {
  antigravity = vim.fs.normalize(vim.fn.expand("~/.gemini/antigravity-cli/conversations")),
  codex = vim.fs.normalize(vim.fn.expand("~/.codex/sessions")),
  claude = vim.fs.normalize(vim.fn.expand("~/.claude/projects")),
  grok = vim.fs.normalize(vim.fn.expand("~/.grok")),
}

local function env_value(tool, name)
  local value
  for _, env in ipairs({ tool and tool.config and tool.config.env, tool and tool.env }) do
    if type(env) == "table" and env[name] ~= nil then
      value = env[name]
    end
  end
  if value == false then
    return
  end
  return type(value) == "string" and value or vim.env[name]
end

local function resolve_path(path, cwd)
  if type(path) ~= "string" or path == "" then
    return
  end
  path = vim.fn.expand(path)
  local absolute = path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\")
  return vim.fs.normalize(absolute and path or vim.fs.joinpath(cwd or vim.fn.getcwd(), path))
end

local function root(provider, tool, cwd)
  if provider == "codex" then
    local home = resolve_path(env_value(tool, "CODEX_HOME"), cwd)
    if home then
      return vim.fs.joinpath(home, "sessions")
    end
  end
  return M.roots[provider]
end

local function read_prefix(path)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local data = file:read(128 * 1024)
  file:close()
  return data
end

local function read_first_line(path)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local parts, bytes = {}, 0
  while bytes < 2 * 1024 * 1024 do
    local chunk = file:read(64 * 1024)
    if not chunk then
      break
    end
    local newline = chunk:find("[\r\n]")
    if newline then
      parts[#parts + 1] = chunk:sub(1, newline - 1)
      file:close()
      return table.concat(parts)
    end
    bytes = bytes + #chunk
    parts[#parts + 1] = chunk
  end
  file:close()
  return bytes < 2 * 1024 * 1024 and table.concat(parts) or nil
end

local function valid_antigravity(path)
  local data = read_prefix(path)
  return data
    and data:sub(1, 16) == "SQLite format 3\0"
    and data:find("trajectory_meta", 1, true) ~= nil
    and data:find("CREATE TABLE", 1, true) ~= nil
end

local function session_id(provider, path)
  if provider == "antigravity" then
    return vim.fs.basename(path):match("^([%w%-]+)%.db$")
  end
  local line = read_first_line(path)
  if not line then
    return
  end
  local ok, value = pcall(vim.json.decode, line)
  if not ok or type(value) ~= "table" then
    return
  end
  if provider == "codex" then
    local payload = type(value.payload) == "table" and value.payload or {}
    return payload.id or payload.session_id
  end
  return value.sessionId
end

local function allowed(provider, path, session_root)
  path = vim.fs.normalize(path)
  session_root = session_root or M.roots[provider]
  if provider == "grok" then
    return session_root and path == session_root .. "/grok.db"
  end
  local extension = provider == "antigravity" and "%.db$" or "%.jsonl?$"
  return session_root and path:sub(1, #session_root + 1) == session_root .. "/" and path:match(extension)
end

local function database_path(provider, path)
  if provider ~= "grok" then
    return path
  end
  return path:gsub("%-wal$", ""):gsub("%-shm$", "")
end

local function valid_id(provider, id)
  if provider == "grok" then
    return type(id) == "string" and #id == 12 and id:match("^[0-9a-f]+$") ~= nil
  elseif provider == "opencode" then
    return type(id) == "string" and #id >= 8 and #id <= 128 and id:match("^ses_[0-9A-Za-z]+$") ~= nil
  end
  return type(id) == "string" and id ~= ""
end

local function valid_database(path)
  local data = read_prefix(path)
  return data ~= nil and data:sub(1, 16) == "SQLite format 3\0"
end

local function output(session)
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    local count = vim.api.nvim_buf_line_count(session.buf)
    return table.concat(vim.api.nvim_buf_get_lines(session.buf, math.max(0, count - 2000), count, false), "\n")
  end
  if type(session.dump) == "function" then
    local ok, ret = pcall(session.dump, session)
    if ok and type(ret) == "string" then
      return ret
    end
  end
  return ""
end

local function output_ids(provider, session)
  local found = {}
  local pattern = provider == "grok" and "[0-9a-f]+" or "ses_[0-9A-Za-z]+"
  for id in output(session):gmatch(pattern) do
    if valid_id(provider, id) then
      found[id] = true
    end
  end
  return found
end

local function opencode_sessions()
  if vim.fn.executable("opencode") ~= 1 then
    return {}
  end
  local lines = Util.exec({ "opencode", "session", "list", "--format", "json" }, { notify = false })
  local ok, sessions = pcall(vim.json.decode, table.concat(lines or {}, "\n"))
  return ok and type(sessions) == "table" and sessions or {}
end

local function opencode_has(id)
  for _, session in ipairs(opencode_sessions()) do
    if session.id == id then
      return true
    end
  end
  return false
end

local function opencode_url(session)
  local wanted = {}
  for _, root in ipairs(session.pids or {}) do
    for _, pid in ipairs(Procs.pids(root)) do
      wanted[pid] = true
    end
  end
  local backend = require("sidekick.cli.session").backends.opencode
  if not backend or type(backend.sessions) ~= "function" then
    return
  end
  for _, candidate in ipairs(backend.sessions()) do
    for _, pid in ipairs(candidate.pids or { candidate.pid }) do
      if wanted[pid] then
        return candidate.base_url
      end
    end
  end
end

local function curl_json(url)
  local lines = Util.exec({ "curl", "-sS", "--max-time", "1", url }, { notify = false })
  local ok, value = pcall(vim.json.decode, table.concat(lines or {}, "\n"))
  return ok and value or nil
end

local function opencode_active(session)
  local url = opencode_url(session)
  local statuses = url and curl_json(url .. "/session/status") or nil
  if type(statuses) ~= "table" then
    return
  end
  local ids = {}
  for id in pairs(statuses) do
    if valid_id("opencode", id) then
      ids[#ids + 1] = id
    end
  end
  return #ids == 1 and ids[1] or nil
end

local function proc_paths(pid)
  local ret = {}
  local fd = "/proc/" .. pid .. "/fd"
  local scan = vim.uv.fs_scandir(fd)
  if scan then
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      local path = vim.uv.fs_readlink(fd .. "/" .. name)
      if path then
        ret[#ret + 1] = path:gsub(" %(deleted%)$", "")
      end
    end
  elseif vim.fn.executable("lsof") == 1 then
    for _, line in ipairs(Util.exec({ "lsof", "-a", "-p", tostring(pid), "-Fn" }, { notify = false }) or {}) do
      local path = line:match("^n(/.*)$")
      if path then
        ret[#ret + 1] = path
      end
    end
  end
  return ret
end

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"
---@param session sidekick.cli.Session
---@return sidekick.cli.Conversation?
function M.capture(provider, session)
  if provider == "opencode" then
    local active = opencode_active(session)
    if active then
      return { id = active, provider = provider, resumable = true }
    end
    local available = {}
    for _, item in ipairs(opencode_sessions()) do
      available[item.id] = true
    end
    local ids = vim.tbl_filter(function(id)
      return available[id] == true
    end, vim.tbl_keys(output_ids(provider, session)))
    if #ids == 1 then
      return { id = ids[1], provider = provider, resumable = true }
    end
    return
  end
  local found = {}
  local scanned = {}
  local session_root = root(provider, session.tool, session.cwd)
  local function scan(pid)
    if scanned[pid] then
      return
    end
    scanned[pid] = true
    for _, path in ipairs(proc_paths(pid)) do
      path = database_path(provider, path)
      if allowed(provider, path, session_root) then
        if provider == "grok" then
          found[path] = path
        else
          local id = session_id(provider, path)
          if id then
            found[id] = path
          end
        end
      end
    end
  end
  for _, root_pid in ipairs(session.pids or {}) do
    for _, pid in ipairs(Procs.pids(root_pid)) do
      scan(pid)
    end
  end
  if provider == "grok" then
    local paths = vim.tbl_keys(found)
    if #paths ~= 1 or not valid_database(paths[1]) then
      return
    end
    local path = paths[1]
    local candidates = output_ids(provider, session)
    local ids = vim.tbl_keys(candidates)
    if #ids ~= 1 then
      return
    end
    return {
      id = ids[1],
      provider = provider,
      resumable = true,
      data = { path = path },
    }
  end
  local ids = vim.tbl_keys(found)
  if #ids ~= 1 then
    return
  end
  return {
    id = ids[1],
    provider = provider,
    resumable = true,
    data = { path = found[ids[1]] },
  }
end

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"
---@param conversation sidekick.cli.Conversation
---@param tool? sidekick.cli.Tool
---@param cwd? string
function M.verify(provider, conversation, tool, cwd)
  local path = conversation.data and conversation.data.path
  local session_root = root(provider, tool, cwd)
  if provider == "opencode" then
    return valid_id(provider, conversation.id) and opencode_has(conversation.id)
  elseif provider == "grok" then
    return type(path) == "string"
      and allowed(provider, path)
      and vim.uv.fs_stat(path) ~= nil
      and valid_id(provider, conversation.id)
      and valid_database(path)
  end
  return type(path) == "string"
    and allowed(provider, path, session_root)
    and vim.uv.fs_stat(path) ~= nil
    and session_id(provider, path) == conversation.id
    and (provider ~= "antigravity" or valid_antigravity(path))
end

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"
---@param args string[]
function M.adapter(provider, args)
  return {
    args = args,
    capture = function(_, session)
      return M.capture(provider, session)
    end,
    verify = function(_, terminal, conversation)
      if not M.verify(provider, conversation, terminal.tool, terminal.cwd) then
        return false
      end
      local matched = false
      local timeout = math.max(1000, require("sidekick.config").cli.workspace.resume_timeout_ms)
      local started = vim.uv.now()
      vim.wait(timeout, function()
        if terminal.closed or not terminal:is_running() then
          return true
        end
        if provider == "opencode" then
          local url = opencode_url(terminal)
          matched = vim.uv.now() - started >= 1000
            and url ~= nil
            and type(curl_json(url .. "/session/" .. conversation.id)) == "table"
        else
          local current = M.capture(provider, terminal)
          matched = current ~= nil and current.id == conversation.id
        end
        return matched
      end, 50)
      return matched
    end,
    preflight = function(tool, conversation, saved)
      return M.verify(provider, conversation, tool, saved and saved.cwd)
    end,
  }
end

return M
