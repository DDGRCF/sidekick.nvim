local Procs = require("sidekick.cli.procs")
local Util = require("sidekick.util")

local M = {}
local crush_default_root = vim.fs.normalize(vim.fn.expand("~/.local/share/crush"))
local crush_config_data_dir

M.roots = {
  antigravity = vim.fs.normalize(vim.fn.expand("~/.gemini/antigravity-cli/conversations")),
  codex = vim.fs.normalize(vim.fn.expand("~/.codex/sessions")),
  claude = vim.fs.normalize(vim.fn.expand("~/.claude/projects")),
  grok = vim.fs.normalize(vim.fn.expand("~/.grok")),
  cursor = vim.fs.normalize(vim.fn.expand("~/.cursor/chats")),
  crush = crush_default_root,
}

local function env_value(tool, name)
  local value
  local envs = {}
  if tool and tool.config and tool.config.env then
    envs[#envs + 1] = tool.config.env
  end
  if tool and tool.env then
    envs[#envs + 1] = tool.env
  end
  for _, env in ipairs(envs) do
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

local function command_data_dir(tool, cwd)
  local cmd = tool and tool.cmd
  if type(cmd) ~= "table" then
    return
  end
  for i, arg in ipairs(cmd) do
    if arg == "--data-dir" or arg == "-D" then
      return resolve_path(cmd[i + 1], cwd)
    end
    local value = type(arg) == "string" and arg:match("^%-%-data%-dir=(.+)$")
    if value then
      return resolve_path(value, cwd)
    end
  end
end

local function crush_roots(tool, cwd, session_root)
  local ret = {}
  local seen = {}
  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    path = vim.fs.normalize(path)
    if not seen[path] then
      seen[path] = true
      ret[#ret + 1] = path
    end
  end

  add(session_root)
  add(command_data_dir(tool, cwd))
  add(resolve_path(env_value(tool, "CRUSH_GLOBAL_DATA"), cwd))
  add(M.roots.crush)
  add(vim.fs.joinpath(cwd or vim.fn.getcwd(), ".crush"))
  return ret
end

local function root(provider, tool, cwd)
  if provider == "grok" then
    local home = resolve_path(env_value(tool, "GROK_HOME"), cwd)
    if home then
      return home
    end
  elseif provider == "codex" then
    local home = resolve_path(env_value(tool, "CODEX_HOME"), cwd)
    if home then
      return vim.fs.joinpath(home, "sessions")
    end
  elseif provider == "crush" then
    return command_data_dir(tool, cwd)
      or resolve_path(env_value(tool, "CRUSH_GLOBAL_DATA"), cwd)
      or (crush_config_data_dir and crush_config_data_dir(tool, cwd))
      or M.roots.crush
  end
  return M.roots[provider]
end

---@param id string
---@param tool? sidekick.cli.Tool
---@param cwd? string
---@return string?
local function codex_writer_lock(id, tool, cwd)
  local session_root = root("codex", tool, cwd)
  local home = session_root and vim.fs.dirname(session_root) or nil
  return home and vim.fs.joinpath(home, "thread-writer-locks", id .. ".lock") or nil
end

---@param path string
---@return boolean? held
local function lock_held(path)
  -- Codex uses an advisory lock on an empty per-thread file. Checking only
  -- for the file is not enough: stale lock files can survive a crash.
  -- `flock -n` lets us distinguish a live writer from that stale file.
  if vim.fn.executable("flock") ~= 1 then
    return
  end
  local ok, result = pcall(function()
    return vim.system({ "flock", "-n", path, "-c", "true" }, { text = true }):wait()
  end)
  if not ok or type(result) ~= "table" then
    return
  end
  if result.code == 0 then
    return false
  elseif result.code == 1 then
    return true
  end
end

---@param id string
---@param tool? sidekick.cli.Tool
---@param cwd? string
---@return "active"|"free"|"unknown"
function M.codex_writer_status(id, tool, cwd)
  if type(id) ~= "string" or id == "" or not id:match("^[%w%-]+$") then
    return "unknown"
  end
  local path = codex_writer_lock(id, tool, cwd)
  if not path or not vim.uv.fs_stat(path) then
    return "free"
  end
  local held = lock_held(path)
  if held == true then
    return "active"
  elseif held == false then
    return "free"
  end
  return "unknown"
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

crush_config_data_dir = function(tool, cwd)
  cwd = vim.fs.normalize(cwd or vim.fn.getcwd())
  local checked = {}

  local function read_data_dir(path)
    path = resolve_path(path, cwd)
    if not path or checked[path] then
      return
    end
    checked[path] = true
    local data = read_prefix(path)
    if not data then
      return
    end

    local ok, config = pcall(vim.json.decode, data)
    if ok and type(config) == "table" then
      local options = type(config.options) == "table" and config.options or {}
      if type(options.data_directory) == "string" and options.data_directory ~= "" then
        return resolve_path(options.data_directory, cwd)
      end
    end

    -- Crush accepts JSON configuration with comments. Keep this fallback
    -- deliberately narrow: a malformed or dynamic value simply means that
    -- discovery remains conservative instead of executing configuration code.
    local value = data:match('"options"%s*:%s*{.-"data_directory"%s*:%s*"([^"\\]*)"')
    return value and resolve_path(value, cwd) or nil
  end

  local dir = cwd
  while true do
    local data_dir = read_data_dir(vim.fs.joinpath(dir, ".crush.json"))
      or read_data_dir(vim.fs.joinpath(dir, "crush.json"))
    if data_dir then
      return data_dir
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end

  local global_config = env_value(tool, "CRUSH_GLOBAL_CONFIG")
  local data_dir = read_data_dir(global_config)
  if data_dir then
    return data_dir
  end

  local config_home = resolve_path(env_value(tool, "XDG_CONFIG_HOME") or "~/.config", cwd)
  return read_data_dir(config_home and vim.fs.joinpath(config_home, "crush", "crush.json"))
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

local function is_grok_id(id)
  if type(id) ~= "string" then
    return false
  end
  if #id == 12 then
    return id:match("^[0-9a-fA-F]+$") ~= nil
  end
  local lengths = { 8, 4, 4, 4, 12 }
  local parts = vim.split(id, "-", { plain = true })
  if #parts ~= #lengths then
    return false
  end
  for i, part in ipairs(parts) do
    if #part ~= lengths[i] or part:match("^[0-9a-fA-F]+$") == nil then
      return false
    end
  end
  return true
end

local function grok_session_id(path, session_root)
  session_root = session_root or M.roots.grok
  if not session_root then
    return
  end
  path = vim.fs.normalize(path)
  session_root = vim.fs.normalize(session_root)
  local prefix = session_root .. "/sessions/"
  if path:sub(1, #prefix) ~= prefix then
    return
  end
  local id = path:sub(#prefix + 1):match("^[^/]+/([^/]+)/")
  return is_grok_id(id) and id or nil
end

local function valid_antigravity(path)
  local data = read_prefix(path)
  return data
    and data:sub(1, 16) == "SQLite format 3\0"
    and data:find("trajectory_meta", 1, true) ~= nil
    and data:find("CREATE TABLE", 1, true) ~= nil
end

local function antigravity_project_id(id)
  local root = vim.fs.dirname(M.roots.antigravity or "")
  if not root or root == "." then
    return
  end
  local data = read_prefix(vim.fs.joinpath(root, "cache", "conversation_metadata.json"))
  if not data then
    return
  end
  local ok, metadata = pcall(vim.json.decode, data)
  if not ok or type(metadata) ~= "table" then
    return
  end
  local entry = metadata.conversations and metadata.conversations[id]
  local project_id = entry and entry.summary and entry.summary.ProjectID
  return type(project_id) == "string" and project_id:match("^[%w_.%-]+$") and project_id or nil
end

local function session_id(provider, path, session_root)
  if provider == "antigravity" then
    return vim.fs.basename(path):match("^([%w%-]+)%.db$")
  elseif provider == "grok" then
    return grok_session_id(path, session_root)
  elseif provider == "cursor" then
    return vim.fs.basename(vim.fs.dirname(path))
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

local function claude_session_path(id, session_root)
  if type(id) ~= "string" or not id:match("^[%w%-]+$") or type(session_root) ~= "string" then
    return
  end
  local matches = {}
  for _, extension in ipairs({ "jsonl", "json" }) do
    for _, path in ipairs(vim.fn.globpath(session_root, "**/" .. id .. "." .. extension, false, true)) do
      if session_id("claude", path, session_root) == id then
        matches[vim.fs.normalize(path)] = true
      end
    end
  end
  local paths = vim.tbl_keys(matches)
  return #paths == 1 and paths[1] or nil
end

local function allowed(provider, path, session_root, tool, cwd)
  path = vim.fs.normalize(path)
  session_root = session_root or M.roots[provider]
  if provider == "crush" then
    for _, candidate in ipairs(crush_roots(tool, cwd, session_root)) do
      if path == vim.fs.joinpath(candidate, "crush.db") then
        return true
      end
    end
    return false
  end
  if provider == "grok" then
    return (session_root and path == session_root .. "/grok.db") or grok_session_id(path, session_root) ~= nil
  end
  if provider == "cursor" then
    return session_root
      and path:sub(1, #session_root + 1) == session_root .. "/"
      and path:match("/[^/]+/store%.db$") ~= nil
  end
  local extension = provider == "antigravity" and "%.db$" or "%.jsonl?$"
  return session_root and path:sub(1, #session_root + 1) == session_root .. "/" and path:match(extension)
end

local function database_path(provider, path)
  if provider ~= "grok" and provider ~= "cursor" then
    return path
  end
  return path:gsub("%-wal$", ""):gsub("%-shm$", "")
end

local function valid_id(provider, id)
  if provider == "grok" then
    return is_grok_id(id)
  elseif provider == "opencode" then
    return type(id) == "string" and #id >= 8 and #id <= 128 and id:match("^ses_[0-9A-Za-z]+$") ~= nil
  elseif provider == "crush" then
    return type(id) == "string" and #id >= 8 and #id <= 128 and id:match("^[0-9A-Za-z%-]+$") ~= nil
  end
  return type(id) == "string" and id ~= ""
end

local function exact_command_id(provider, id)
  return valid_id(provider, id) and id:sub(1, 1) ~= "-" and not id:find("[%c%s]") and id or nil
end

local function command_value(cmd, flag)
  local args = type(cmd) == "table" and cmd or vim.split(cmd or "", "%s+")
  for i, arg in ipairs(args) do
    arg = type(arg) == "string" and arg:gsub("^['\"]", ""):gsub("['\"]$", "") or arg
    if arg == flag then
      local value = args[i + 1]
      return type(value) == "string" and value:gsub("^['\"]", ""):gsub("['\"]$", "") or nil
    end
    local value = type(arg) == "string" and arg:match("^" .. vim.pesc(flag) .. "=(.+)$") or nil
    if value then
      return value
    end
  end
end

local function command_has(cmd, flag)
  local args = type(cmd) == "table" and cmd or vim.split(cmd or "", "%s+")
  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      arg = arg:gsub("^['\"]", ""):gsub("['\"]$", "")
      if arg == flag or arg:find("^" .. vim.pesc(flag) .. "=") then
        return true
      end
    end
  end
  return false
end

local function process_session_id(session)
  local ids = {}
  local disabled = false
  local function inspect(cmd)
    if command_has(cmd, "--no-session-persistence") then
      disabled = true
    end
    local id = exact_command_id("claude", command_value(cmd, "--session-id"))
    if id then
      ids[id] = true
    end
  end

  local tool = session.tool
  local tool_cmd = tool and tool.cmd
  inspect(tool_cmd)
  if disabled then
    return
  end

  -- The command-line id is authoritative and avoids a full process-table
  -- scan for Sidekick-managed sessions.
  local direct = exact_command_id("claude", command_value(tool_cmd, "--session-id"))
  if direct then
    return direct
  end

  -- A native fork intentionally has no new id in its command line. Its
  -- transcript is discovered below, so do not scan every descendant's args.
  local native_fork = command_has(tool_cmd, "--fork-session")
  if
    not native_fork
    and session.pids
    and #session.pids > 0
    and type(tool) == "table"
    and type(tool.is_proc) == "function"
  then
    local procs = Procs.new()
    for _, root_pid in ipairs(session.pids) do
      for _, pid in ipairs(Procs.pids(root_pid)) do
        local proc = procs:get(pid)
        if proc and tool:is_proc(proc) then
          inspect(proc.cmd)
        end
      end
    end
  end

  local found = vim.tbl_keys(ids)
  return #found == 1 and found[1] or nil
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

---@param session sidekick.cli.Terminal
---@return "active_writer"?
local function codex_resume_error(session)
  local text = output(session)
  if text:find("already has an active writer", 1, true) then
    return "active_writer"
  end
end

local function output_ids(provider, session)
  local found = {}
  local patterns = provider == "grok" and { "[0-9a-fA-F][0-9a-fA-F%-]+" } or { "ses_[0-9A-Za-z]+" }
  for _, pattern in ipairs(patterns) do
    for id in output(session):gmatch(pattern) do
      if valid_id(provider, id) then
        found[id] = true
      end
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

local proc_paths

local function crush_sessions(tool, data_dir)
  if type(data_dir) ~= "string" or data_dir == "" then
    return {}
  end
  local executable = tool and tool.cmd and tool.cmd[1] or "crush"
  if vim.fn.executable(executable) ~= 1 then
    return {}
  end
  local lines = Util.exec({ executable, "--data-dir", data_dir, "session", "list", "--json" }, { notify = false })
  local ok, sessions = pcall(vim.json.decode, table.concat(lines or {}, "\n"))
  return ok and type(sessions) == "table" and sessions or {}
end

local function crush_session_id(item)
  if type(item) ~= "table" then
    return
  end
  local id = item.uuid or item.id
  return valid_id("crush", id) and id or nil
end

local function crush_resolve(items, id)
  if not valid_id("crush", id) then
    return
  end
  local matches = {}
  for _, item in ipairs(items) do
    local uuid = crush_session_id(item)
    local hash = type(item) == "table" and item.id
    if uuid == id or hash == id or (type(hash) == "string" and hash:sub(1, #id) == id) then
      matches[#matches + 1] = uuid
    end
  end
  return #matches == 1 and matches[1] or nil
end

local function crush_process_id(proc)
  local env = proc and proc.env or nil
  if type(env) == "table" and valid_id("crush", env.CRUSH_SESSION_ID) then
    return env.CRUSH_SESSION_ID
  end
  local cmd = proc and proc.cmd or ""
  return cmd:match("%-%-session=([^%s]+)") or cmd:match("%-%-session%s+([^%s]+)") or cmd:match("%-s%s+([^%s]+)")
end

local function crush_capture(session, session_root)
  local found = {}
  local explicit = {}
  local scanned = {}
  local procs = Procs.new()
  local function scan(pid)
    if scanned[pid] then
      return
    end
    scanned[pid] = true
    local proc = procs:get(pid)
    local id = crush_process_id(proc)
    if id then
      explicit[id] = true
    end
    for _, path in ipairs(proc_paths(pid)) do
      path = database_path("crush", path)
      if allowed("crush", path, session_root, session.tool, session.cwd) then
        found[path] = true
      end
    end
  end
  for _, root_pid in ipairs(session.pids or {}) do
    for _, pid in ipairs(Procs.pids(root_pid)) do
      scan(pid)
    end
  end

  local paths = vim.tbl_keys(found)
  if #paths == 0 then
    return
  end

  local candidates = {}
  for _, path in ipairs(paths) do
    local items = crush_sessions(session.tool, vim.fs.dirname(path))
    for id in pairs(explicit) do
      local resolved = crush_resolve(items, id) or (valid_id("crush", id) and id or nil)
      if resolved then
        candidates[resolved] = path
      end
    end
    -- Without a provider-owned current-session id, only accept the
    -- unambiguous case. The first row is global to the data directory and
    -- cannot identify which of several live Crush clients owns the terminal.
    if vim.tbl_isempty(explicit) and #paths == 1 and #items == 1 then
      local latest = crush_session_id(items[1])
      if latest then
        candidates[latest] = path
      end
    end
  end

  local ids = vim.tbl_keys(candidates)
  if #ids ~= 1 then
    return
  end
  local id = ids[1]
  local path = candidates[id]
  return {
    id = id,
    provider = "crush",
    resumable = true,
    data = { path = path },
  }
end

local function crush_has(tool, data_dir, id)
  return crush_resolve(crush_sessions(tool, data_dir), id) == id
end

proc_paths = function(pid)
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

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"|"cursor"|"crush"
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
  if provider == "crush" then
    return crush_capture(session, root(provider, session.tool, session.cwd))
  end
  local session_root = root(provider, session.tool, session.cwd)
  if provider == "claude" then
    local id = process_session_id(session)
    if id then
      local data = { managed = true }
      local path = claude_session_path(id, session_root)
      if path then
        data.path = path
      end
      return { id = id, provider = provider, resumable = true, data = data }
    end
  end
  local found = {}
  local scanned = {}
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
          local id = session_id(provider, path, session_root)
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
    local candidates = {}
    for path in pairs(found) do
      local id = session_id(provider, path, session_root)
      if id then
        candidates[id] = path
      end
    end
    local candidate_ids = vim.tbl_keys(candidates)
    if #candidate_ids == 1 then
      local id = candidate_ids[1]
      return {
        id = id,
        provider = provider,
        resumable = true,
        data = { path = candidates[id] },
      }
    elseif #candidate_ids > 1 then
      return
    end
    local paths = vim.tbl_keys(found)
    if #paths ~= 1 or paths[1] ~= session_root .. "/grok.db" or not valid_database(paths[1]) then
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
    data = vim.tbl_extend("force", { path = found[ids[1]] }, {
      project_id = provider == "antigravity" and antigravity_project_id(ids[1]) or nil,
    }),
  }
end

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"|"cursor"|"crush"
---@param conversation sidekick.cli.Conversation
---@param tool? sidekick.cli.Tool
---@param cwd? string
function M.verify(provider, conversation, tool, cwd)
  local path = conversation.data and conversation.data.path
  local session_root = root(provider, tool, cwd)
  if provider == "claude" and not path then
    path = claude_session_path(conversation.id, session_root)
    if path then
      conversation.data = vim.deepcopy(conversation.data or {})
      conversation.data.path = path
    end
  end
  if provider == "claude" and not path and conversation.data and conversation.data.managed == true then
    -- Sidekick assigns this id before Claude creates its transcript. The
    -- managed id is authoritative during that short startup window; the
    -- post-launch capture still has to observe the conversation itself.
    return valid_id(provider, conversation.id)
  end
  if provider == "opencode" then
    return valid_id(provider, conversation.id) and opencode_has(conversation.id)
  elseif provider == "grok" then
    local path_id = type(path) == "string" and session_id(provider, path, session_root) or nil
    return type(path) == "string"
      and allowed(provider, path, session_root, tool, cwd)
      and vim.uv.fs_stat(path) ~= nil
      and valid_id(provider, conversation.id)
      and (path_id == conversation.id or (path == session_root .. "/grok.db" and valid_database(path)))
  elseif provider == "crush" then
    return type(path) == "string"
      and allowed(provider, path, session_root, tool, cwd)
      and vim.uv.fs_stat(path) ~= nil
      and valid_database(path)
      and valid_id(provider, conversation.id)
      and crush_has(tool, vim.fs.dirname(path), conversation.id)
  end
  return type(path) == "string"
    and allowed(provider, path, session_root)
    and vim.uv.fs_stat(path) ~= nil
    and (provider ~= "cursor" or valid_database(path))
    and session_id(provider, path, session_root) == conversation.id
    and (provider ~= "antigravity" or valid_antigravity(path))
end

---@param provider "antigravity"|"codex"|"claude"|"grok"|"opencode"|"cursor"|"crush"
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
      local resume_error
      local timeout = math.max(1000, require("sidekick.config").cli.workspace.resume_timeout_ms)
      local started = vim.uv.now()
      vim.wait(timeout, function()
        resume_error = provider == "codex" and codex_resume_error(terminal) or nil
        if resume_error then
          return true
        end
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
      if resume_error then
        return false, resume_error
      end
      return matched
    end,
    preflight = function(tool, conversation, saved)
      if provider == "codex" then
        local writer = M.codex_writer_status(conversation.id, tool, saved and saved.cwd)
        if writer == "active" then
          return false, "active_writer"
        elseif writer == "unknown" then
          return false, "writer_unknown"
        end
      end
      return M.verify(provider, conversation, tool, saved and saved.cwd)
    end,
  }
end

return M
