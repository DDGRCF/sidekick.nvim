local Procs = require("sidekick.cli.procs")
local Util = require("sidekick.util")

local M = {}

M.roots = {
  antigravity = vim.fs.normalize(vim.fn.expand("~/.gemini/antigravity-cli/conversations")),
  codex = vim.fs.normalize(vim.fn.expand("~/.codex/sessions")),
  claude = vim.fs.normalize(vim.fn.expand("~/.claude/projects")),
}

local function read_prefix(path)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local data = file:read(128 * 1024)
  file:close()
  return data
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
  local data = read_prefix(path)
  if not data then
    return
  end
  local first = data:match("^[^\r\n]+")
  local ok, value = pcall(vim.json.decode, first or "")
  if not ok or type(value) ~= "table" then
    return
  end
  if provider == "codex" then
    local payload = type(value.payload) == "table" and value.payload or {}
    return payload.id or payload.session_id
  end
  return value.sessionId
end

local function allowed(provider, path)
  path = vim.fs.normalize(path)
  local root = M.roots[provider]
  local extension = provider == "antigravity" and "%.db$" or "%.jsonl?$"
  return root and path:sub(1, #root + 1) == root .. "/" and path:match(extension)
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

---@param provider "antigravity"|"codex"|"claude"
---@param session sidekick.cli.Session
---@return sidekick.cli.Conversation?
function M.capture(provider, session)
  local found = {}
  local scanned = {}
  local function scan(pid)
    if scanned[pid] then
      return
    end
    scanned[pid] = true
    for _, path in ipairs(proc_paths(pid)) do
      if allowed(provider, path) then
        local id = session_id(provider, path)
        if id then
          found[id] = path
        end
      end
    end
  end
  for _, root_pid in ipairs(session.pids or {}) do
    for _, pid in ipairs(Procs.pids(root_pid)) do
      scan(pid)
    end
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

---@param provider "antigravity"|"codex"|"claude"
---@param conversation sidekick.cli.Conversation
function M.verify(provider, conversation)
  local path = conversation.data and conversation.data.path
  return type(path) == "string"
    and allowed(provider, path)
    and vim.uv.fs_stat(path) ~= nil
    and session_id(provider, path) == conversation.id
    and (provider ~= "antigravity" or valid_antigravity(path))
end

---@param provider "antigravity"|"codex"|"claude"
---@param args string[]
function M.adapter(provider, args)
  return {
    args = args,
    capture = function(_, session)
      return M.capture(provider, session)
    end,
    verify = function(_, terminal, conversation)
      if not M.verify(provider, conversation) then
        return false
      end
      local matched = false
      local timeout = math.max(1000, require("sidekick.config").cli.workspace.resume_timeout_ms)
      vim.wait(timeout, function()
        if terminal.closed or not terminal:is_running() then
          return true
        end
        local current = M.capture(provider, terminal)
        matched = current ~= nil and current.id == conversation.id
        return matched
      end, 50)
      return matched
    end,
    preflight = function(_, conversation)
      return M.verify(provider, conversation)
    end,
  }
end

return M
