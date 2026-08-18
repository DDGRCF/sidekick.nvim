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
  omp = {
    resume = { "--resume" },
    selectors = { "--resume", "--session", "-r" },
    blockers = { "--no-session" },
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

local function read_json(path)
  local file = io.open(path, "r")
  local raw = file and file:read("*a") or nil
  if file then
    file:close()
  end
  local ok, decoded = pcall(vim.json.decode, raw or "")
  return ok and type(decoded) == "table" and decoded or nil
end

local function resolve_path(path, cwd)
  if type(path) ~= "string" or path == "" then
    return
  end
  path = vim.fn.expand(path)
  local absolute = path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\")
  return vim.fs.normalize(absolute and path or vim.fs.joinpath(cwd or vim.fn.getcwd(), path))
end

local function pi_control_id(session)
  local control = session.conversation and session.conversation.data and session.conversation.data.control
  local record = type(control) == "string" and read_json(control) or nil
  return record and M.valid_id(record.id) and record.id or nil
end

local function valid_omp_id(id)
  return type(id) == "string" and id ~= "" and #id <= 4096 and not id:find("[%c%s]")
end

local function omp_control_id(session, tool)
  local control = session.conversation and session.conversation.data and session.conversation.data.control
    or tool and arg_value(tool.cmd, "--sidekick-session-file")
    or env_value(tool, "SIDEKICK_OMP_SESSION_FILE")
  local record = type(control) == "string" and read_json(control) or nil
  return record and valid_omp_id(record.id) and record.id or nil, record and record.file or nil, control
end

local function omp_control_path(key)
  local control = vim.fs.joinpath(vim.fn.stdpath("state"), "sidekick", "omp", key .. ".json")
  vim.fn.mkdir(vim.fs.dirname(control), "p")
  return control
end

local function track_omp(cmd, extension, control)
  if extension and control then
    vim.list_extend(cmd, { "--extension", extension, "--sidekick-session-file", control })
  end
end

local function current_id(provider, session, spec, tool)
  if provider == "pi" then
    return pi_control_id(session) or process_id(session, spec)
  elseif provider == "omp" then
    return omp_control_id(session, tool)
  end
  return process_id(session, spec)
end

local function verified_id(provider, session, spec, tool, conversation)
  if provider == "pi" and conversation.data and conversation.data.control then
    return pi_control_id(session)
  elseif provider == "omp" then
    return omp_control_id(session, tool)
  end
  return process_id(session, spec)
end

local function copilot_tui_id(session)
  if not (session.buf and vim.api.nvim_buf_is_valid(session.buf)) then
    return
  end
  local count = vim.api.nvim_buf_line_count(session.buf)
  local lines = vim.api.nvim_buf_get_lines(session.buf, math.max(0, count - 2000), count, false)
  local switched = nil
  for _, line in ipairs(lines) do
    if line:find("/resume", 1, true) or line:find("/continue", 1, true) then
      switched = false
      for id in line:gmatch("[0-9a-fA-F%-]+") do
        if M.valid_id(id) then
          switched = id
        end
      end
    end
  end
  return switched
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

local function pi_exists(id, cwd, tool)
  local root = tool and arg_value(tool.cmd, "--session-dir") or env_value(tool, "PI_CODING_AGENT_SESSION_DIR")
  if not root then
    local agent = resolve_path(env_value(tool, "PI_CODING_AGENT_DIR") or "~/.pi/agent")
    local settings = agent and read_json(vim.fs.joinpath(agent, "settings.json")) or nil
    root = settings and settings.sessionDir or agent and vim.fs.joinpath(agent, "sessions")
  end
  root = resolve_path(root or "~/.pi/agent/sessions", cwd)
  if vim.uv.fs_stat(root) == nil then
    return false
  end
  return #vim.fn.globpath(root, "**/*_" .. id .. ".jsonl", false, true) > 0
end

local function omp_file_id(path)
  local file = io.open(path, "r")
  local raw = file and file:read("*l") or nil
  if file then
    file:close()
  end
  local ok, record = pcall(vim.json.decode, raw or "")
  return ok and type(record) == "table" and record.type == "session" and valid_omp_id(record.id) and record.id or nil
end

local function omp_exists(id, cwd, tool, conversation)
  if not valid_omp_id(id) then
    return false
  end
  local path = conversation and conversation.data and conversation.data.path
  if type(path) == "string" and omp_file_id(path) == id then
    return true
  end
  local root = tool and arg_value(tool.cmd, "--session-dir") or env_value(tool, "PI_CODING_AGENT_SESSION_DIR")
  if not root then
    local agent = resolve_path(env_value(tool, "PI_CODING_AGENT_DIR") or "~/.omp/agent")
    root = agent and vim.fs.joinpath(agent, "sessions")
  end
  root = resolve_path(root or "~/.omp/agent/sessions", cwd)
  for _, candidate in ipairs(vim.fn.globpath(root, "**/*.jsonl", false, true)) do
    if omp_file_id(candidate) == id then
      return true
    end
  end
  return false
end

local exists = {
  copilot = copilot_exists,
  omp = omp_exists,
  pi = pi_exists,
}

---@param provider "copilot"|"omp"|"pi"
function M.adapter(provider)
  local spec = assert(providers[provider], "unknown managed CLI provider: " .. provider)
  local extension_name = ({ omp = "omp-sidekick.ts", pi = "pi-sidekick.ts" })[provider]
  local extension = extension_name and vim.api.nvim_get_runtime_file("sk/extensions/" .. extension_name, false)[1]
    or nil
  return {
    args = spec.resume,
    prepare = function(tool, session)
      local cmd = vim.deepcopy(tool.cmd)
      local id = provider ~= "omp" and selected_id(cmd, spec.selectors) or nil
      if provider == "omp" then
        if has_arg(cmd, spec.blockers) then
          return
        end
      elseif not id then
        if has_arg(cmd, vim.list_extend(vim.deepcopy(spec.selectors), spec.blockers)) then
          return
        end
        id = M.uuid()
        vim.list_extend(cmd, spec.new)
        cmd[#cmd + 1] = id
      end
      local data = { managed = true }
      local env
      if (provider == "pi" or provider == "omp") and extension then
        local control_id = provider == "omp" and session.instance_id or id
        local control = provider == "omp" and omp_control_path(control_id)
          or vim.fs.joinpath(vim.fn.stdpath("state"), "sidekick", provider, control_id .. ".json")
        vim.fn.mkdir(vim.fs.dirname(control), "p")
        if provider == "omp" then
          track_omp(cmd, extension, control)
        else
          vim.list_extend(cmd, { "--extension", extension })
        end
        data.control = control
        env = { [provider == "omp" and "SIDEKICK_OMP_SESSION_FILE" or "SIDEKICK_PI_SESSION_FILE"] = control }
      end
      return {
        cmd = cmd,
        env = env,
        conversation = provider ~= "omp" and {
          id = id,
          provider = provider,
          resumable = true,
          data = data,
        } or nil,
      }
    end,
    capture = function(tool, session)
      local tui_id
      if provider == "copilot" then
        tui_id = copilot_tui_id(session)
      end
      if tui_id == false then
        local data = vim.deepcopy(session.conversation and session.conversation.data or {})
        data.managed = true
        data.reason = "interactive session switch could not be identified"
        return {
          id = session.conversation and session.conversation.id,
          provider = provider,
          resumable = false,
          data = data,
        }
      end
      local id, path, control = current_id(provider, session, spec, tool)
      id = type(tui_id) == "string" and tui_id or id
      if id then
        local data = vim.deepcopy(session.conversation and session.conversation.data or {})
        data.managed = true
        data.path = path or data.path
        data.control = control or data.control
        return { id = id, provider = provider, resumable = true, data = data }
      end
      if session.conversation and session.conversation.provider == provider then
        return session.conversation
      end
    end,
    preflight = function(tool, conversation, saved)
      local valid = provider == "omp" and valid_omp_id(conversation.id) or M.valid_id(conversation.id)
      return valid and exists[provider](conversation.id, saved and saved.cwd, tool, conversation)
    end,
    command = (provider == "pi" or provider == "omp") and function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      if extension and conversation.data and conversation.data.control then
        if provider == "omp" then
          track_omp(cmd, extension, conversation.data.control)
        else
          vim.list_extend(cmd, { "--extension", extension })
        end
      end
      vim.list_extend(cmd, { provider == "omp" and "--resume" or "--session", conversation.id })
      return cmd
    end or nil,
    env = (provider == "pi" or provider == "omp") and function(_, conversation)
      local control = conversation.data and conversation.data.control
      local name = provider == "omp" and "SIDEKICK_OMP_SESSION_FILE" or "SIDEKICK_PI_SESSION_FILE"
      return type(control) == "string" and { [name] = control } or nil
    end or nil,
    verify = function(tool, terminal, conversation)
      local logical = terminal.parent or terminal
      local valid = provider == "omp" and valid_omp_id(conversation and conversation.id)
        or M.valid_id(conversation and conversation.id)
      if not valid or not exists[provider](conversation.id, logical.cwd, tool, conversation) then
        return false
      end
      local matched = false
      local started = vim.uv.now()
      local timeout = math.max(1000, require("sidekick.config").cli.workspace.resume_timeout_ms)
      vim.wait(timeout, function()
        if terminal.closed == true or not terminal:is_running() then
          return true
        end
        local active = verified_id(provider, logical, spec, tool, conversation)
        matched = active == conversation.id and vim.uv.now() - started >= 1000
        return matched
      end, 50)
      return matched
    end,
  }
end

function M.fork(provider)
  assert(provider == "omp", "unknown managed CLI fork provider: " .. provider)
  local extension = vim.api.nvim_get_runtime_file("sk/extensions/omp-sidekick.ts", false)[1]
  return {
    available = function(tool)
      if not extension then
        return false, "the bundled Oh My Pi session extension is unavailable"
      end
      if has_arg(tool.cmd, providers.omp.blockers) then
        return false, "Oh My Pi session persistence is disabled"
      end
      return true
    end,
    command = function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      local control = omp_control_path(M.uuid())
      track_omp(cmd, extension, control)
      vim.list_extend(cmd, { "--fork", conversation.id })
      return cmd
    end,
  }
end

return M
