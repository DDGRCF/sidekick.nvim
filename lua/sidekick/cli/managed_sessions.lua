local Util = require("sidekick.util")

local M = {}

local providers = {
  copilot = {
    new = { "--session-id" },
    resume = { "--resume" },
    selectors = { "--session-id", "--resume", "-r" },
    blockers = { "--continue", "--connect" },
  },
  pi = {
    new = { "--session-id" },
    resume = { "--session" },
    selectors = { "--session-id", "--session" },
    blockers = { "--continue", "--resume", "-c", "-r" },
  },
  qwen = {
    new = { "--session-id" },
    resume = { "--resume" },
    selectors = { "--session-id", "--resume", "-r" },
    blockers = { "--continue", "-c" },
  },
}

---@param id? string
function M.valid_id(id)
  return type(id) == "string"
    and id:match(
        "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"
      )
      ~= nil
end

---@param seed? string
function M.uuid(seed)
  local hex = vim.fn.sha256(seed or table.concat({ vim.uv.hrtime(), vim.fn.getpid(), math.random() }, ":")):sub(1, 32)
  hex = hex:sub(1, 12) .. "4" .. hex:sub(14)
  local variant = (tonumber(hex:sub(17, 17), 16) % 4) + 8
  hex = hex:sub(1, 16) .. ("%x"):format(variant) .. hex:sub(18)
  return table.concat({ hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21) }, "-")
end

---@param cmd string[]
---@param flags string[]
local function selected_id(cmd, flags)
  local wanted = {}
  for _, flag in ipairs(flags) do
    wanted[flag] = true
  end
  for i, arg in ipairs(cmd) do
    if wanted[arg] and M.valid_id(cmd[i + 1]) then
      return cmd[i + 1]
    end
    for flag in pairs(wanted) do
      local id = arg:match("^" .. vim.pesc(flag) .. "=(.+)$")
      if M.valid_id(id) then
        return id
      end
    end
  end
end

---@param cmd string[]
---@param flag string
local function arg_value(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return cmd[i + 1]
    end
    local value = arg:match("^" .. vim.pesc(flag) .. "=(.+)$")
    if value then
      return value
    end
  end
end

local function env_value(tool, name)
  local value = tool and (tool.env and tool.env[name] or tool.config and tool.config.env and tool.config.env[name])
  return type(value) == "string" and value or vim.env[name]
end

local function system_env(tool)
  local ret = {}
  for key, value in
    pairs(vim.tbl_extend("force", {}, tool and tool.config and tool.config.env or {}, tool and tool.env or {}))
  do
    if type(value) == "string" or type(value) == "number" then
      ret[key] = tostring(value)
    end
  end
  return ret
end

local function process_id(session, spec)
  local id = selected_id(session.tool.cmd, spec.selectors)
  if id or not session.pids then
    return id
  end
  local procs = require("sidekick.cli.procs").new()
  for _, pid in ipairs(session.pids) do
    local proc = procs:get(pid)
    id = proc and selected_id(vim.split(proc.cmd, "%s+"), spec.selectors) or nil
    if id then
      return id
    end
  end
end

local function qwen_active_id(session, tool)
  local pids = {}
  for _, pid in ipairs(session.pids or {}) do
    pids[pid] = true
  end
  if vim.tbl_isempty(pids) then
    return
  end
  local root = env_value(tool, "QWEN_RUNTIME_DIR") or vim.fn.expand("~/.qwen")
  local locks = vim.fs.joinpath(root, "tmp", "session-writer-locks")
  for _, path in ipairs(vim.fn.globpath(locks, "*.lock", false, true)) do
    local file = io.open(path, "r")
    local raw = file and file:read("*a") or nil
    if file then
      file:close()
    end
    local ok, record = pcall(vim.json.decode, raw or "")
    if
      ok
      and type(record) == "table"
      and record.state == "active"
      and pids[tonumber(record.pid)]
      and M.valid_id(record.session_id)
    then
      return record.session_id
    end
  end
end

local function current_id(provider, session, spec, tool)
  return provider == "qwen" and qwen_active_id(session, tool) or process_id(session, spec)
end

---@param cmd string[]
---@param flags string[]
local function has_arg(cmd, flags)
  for _, arg in ipairs(cmd) do
    for _, flag in ipairs(flags) do
      if arg == flag or arg:find(flag .. "=", 1, true) == 1 then
        return true
      end
    end
  end
  return false
end

local function copilot_exists(id, _, tool)
  local root = tool and arg_value(tool.cmd, "--config-dir")
    or env_value(tool, "COPILOT_HOME")
    or env_value(tool, "COPILOT_CONFIG_DIR")
    or vim.fn.expand("~/.copilot")
  return vim.uv.fs_stat(vim.fs.joinpath(root, "session-state", id, "events.jsonl")) ~= nil
end

local function pi_exists(id, _, tool)
  local root = tool and arg_value(tool.cmd, "--session-dir") or env_value(tool, "PI_CODING_AGENT_SESSION_DIR")
  root = vim.fs.normalize(root or vim.fn.expand("~/.pi/agent/sessions"))
  if vim.uv.fs_stat(root) == nil then
    return false
  end
  return #vim.fn.globpath(root, "**/*_" .. id .. ".jsonl", false, true) > 0
end

local function qwen_exists(id, cwd, tool)
  local executable = tool and tool.cmd[1] or "qwen"
  if vim.fn.executable(executable) ~= 1 then
    return false
  end
  local lines = Util.exec(
    { executable, "sessions", "list", "--json", "--limit", "2147483647" },
    { notify = false, cwd = cwd, env = system_env(tool) }
  )
  for _, line in ipairs(lines or {}) do
    local ok, session = pcall(vim.json.decode, line)
    if ok and type(session) == "table" and (session.sessionId == id or session.id == id) then
      return true
    end
  end
  return false
end

local exists = {
  copilot = copilot_exists,
  pi = pi_exists,
  qwen = qwen_exists,
}

---@param provider "copilot"|"pi"|"qwen"
function M.adapter(provider)
  local spec = assert(providers[provider], "unknown managed CLI provider: " .. provider)
  return {
    args = spec.resume,
    prepare = function(tool, session)
      local cmd = vim.deepcopy(tool.cmd)
      local id = selected_id(cmd, spec.selectors)
      if not id then
        if has_arg(cmd, vim.list_extend(vim.deepcopy(spec.selectors), spec.blockers)) then
          return
        end
        id = M.uuid()
        vim.list_extend(cmd, spec.new)
        cmd[#cmd + 1] = id
      end
      return {
        cmd = cmd,
        conversation = {
          id = id,
          provider = provider,
          resumable = true,
          data = { managed = true },
        },
      }
    end,
    capture = function(tool, session)
      local id = current_id(provider, session, spec, tool)
      if id then
        return { id = id, provider = provider, resumable = true, data = { managed = true } }
      end
      if session.conversation and session.conversation.provider == provider then
        return session.conversation
      end
    end,
    preflight = function(tool, conversation, saved)
      return M.valid_id(conversation.id) and exists[provider](conversation.id, saved and saved.cwd, tool)
    end,
    verify = function(tool, terminal, conversation)
      local logical = terminal.parent or terminal
      if
        not M.valid_id(conversation and conversation.id)
        or current_id(provider, logical, spec, tool) ~= conversation.id
        or not exists[provider](conversation.id, logical.cwd, tool)
      then
        return false
      end
      local stable = false
      local started = vim.uv.now()
      vim.wait(1500, function()
        stable = terminal.closed ~= true and terminal:is_running() and vim.uv.now() - started >= 1000
        return stable or terminal.closed == true or not terminal:is_running()
      end, 50)
      return stable
    end,
  }
end

return M
