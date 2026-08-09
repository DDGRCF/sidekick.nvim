local Util = require("sidekick.util")

local M = {}

local function logical(session)
  return session.parent or session
end

local function call(fn, ...)
  local ok, ret = pcall(fn, ...)
  if ok then
    return ret
  end
  Util.debug("CLI resume adapter failed", ret)
end

---@param session sidekick.cli.Session
---@param opts? {require_current?:boolean}
---@return sidekick.cli.Conversation?
function M.capture(session, opts)
  local attached = session
  session = logical(attached)
  local adapter = session.tool.config.resume
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.capture) == "function" then
    local capture_session = setmetatable({
      pids = {},
      buf = attached.buf or session.buf,
    }, { __index = session })
    vim.list_extend(capture_session.pids, session.pids or {})
    if attached ~= session then
      vim.list_extend(capture_session.pids, attached.pids or {})
    end
    if session.mux_session and (session.backend == "tmux" or session.backend == "zellij") then
      local ok, discovered = pcall(require("sidekick.cli.session." .. session.backend).sessions)
      if ok then
        for _, candidate in ipairs(discovered or {}) do
          if
            candidate.mux_session == session.mux_session
            and (not candidate.instance_id or candidate.instance_id == session.instance_id)
          then
            vim.list_extend(capture_session.pids, candidate.pids or {})
          end
        end
      end
    end
    local conversation = call(adapter.capture, session.tool, capture_session)
    if type(conversation) == "string" then
      conversation = { id = conversation }
    end
    if type(conversation) == "table" then
      conversation = require("sidekick.cli.session").set_conversation(session, conversation)
      return vim.deepcopy(conversation)
    end
  end
  if opts and opts.require_current then
    -- Provider discovery is authoritative for external sessions. A managed
    -- session is the exception: its exact id was assigned to the command
    -- before it started, so the cached metadata remains authoritative while
    -- the provider creates its transcript file.
    local cached = session.conversation or attached.conversation
    if cached and cached.data and cached.data.managed == true then
      return vim.deepcopy(cached)
    end
    return
  end
  if session.conversation or attached.conversation then
    return vim.deepcopy(session.conversation or attached.conversation)
  end
end

---@param tool sidekick.cli.Tool
---@param saved sidekick.cli.WorkspaceAgent
---@return string[]? cmd
---@return "exact"|"unsupported" mode
function M.command(tool, saved)
  local conversation = saved.conversation
  if
    type(conversation) ~= "table"
    or conversation.provider ~= tool.name
    or conversation.resumable ~= true
    or type(conversation.id) ~= "string"
    or conversation.id == ""
    or conversation.id:sub(1, 1) == "-"
    or #conversation.id > 4096
    or conversation.id:find("[%c%s]")
  then
    return nil, "unsupported"
  end
  local adapter = tool.config.resume
  if type(adapter) == "function" then
    local cmd = call(adapter, tool, conversation, saved)
    return type(cmd) == "table" and cmd or nil, type(cmd) == "table" and "exact" or "unsupported"
  end
  if type(adapter) == "table" and not vim.islist(adapter) then
    if type(adapter.command) == "function" then
      local cmd = call(adapter.command, tool, conversation, saved)
      return type(cmd) == "table" and cmd or nil, type(cmd) == "table" and "exact" or "unsupported"
    end
    adapter = adapter.args
  end

  local args = adapter
  if type(args) ~= "table" or #args == 0 then
    return nil, "unsupported"
  end

  local cmd = vim.deepcopy(tool.cmd)
  vim.list_extend(cmd, args)
  cmd[#cmd + 1] = conversation.id
  return cmd, "exact"
end

---@param tool sidekick.cli.Tool
---@param terminal sidekick.cli.Terminal
---@param saved sidekick.cli.WorkspaceAgent
---@return boolean?
function M.verify(tool, terminal, saved)
  local adapter = tool.config.resume
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.verify) == "function" then
    return call(adapter.verify, tool, terminal, saved.conversation, saved)
  end
  return false
end

---@param tool sidekick.cli.Tool
---@param saved sidekick.cli.WorkspaceAgent
function M.preflight(tool, saved)
  local adapter = tool.config.resume
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.preflight) == "function" then
    return call(adapter.preflight, tool, saved.conversation, saved) == true
  end
  return false
end

---@param tool sidekick.cli.Tool
---@param saved sidekick.cli.WorkspaceAgent
function M.env(tool, saved)
  local adapter = tool.config.resume
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.env) == "function" then
    local env = call(adapter.env, tool, saved.conversation, saved)
    return type(env) == "table" and env or nil
  end
end

return M
