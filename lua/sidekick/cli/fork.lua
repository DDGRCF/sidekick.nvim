local Config = require("sidekick.config")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

local M = {}

local function call(fn, ...)
  local ok, ret, reason = pcall(fn, ...)
  if ok then
    return ret, reason
  end
  Util.debug("CLI fork adapter failed", ret)
  return nil, tostring(ret)
end

local function tool_for(tool)
  if type(tool) == "string" then
    return Config.get_tool(tool)
  end
  if tool and not tool.config and tool.name then
    return Config.get_tool(tool.name)
  end
  return tool
end

local function adapter_for(tool)
  tool = tool_for(tool)
  return tool and tool.config and tool.config.fork
end

local function valid_conversation(tool, conversation)
  return type(conversation) == "table"
    and conversation.provider == tool.name
    and conversation.resumable == true
    and type(conversation.id) == "string"
    and conversation.id ~= ""
    and conversation.id:sub(1, 1) ~= "-"
    and #conversation.id <= 4096
    and not conversation.id:find("[%c%s]")
end

---@param tool sidekick.cli.Tool
---@param source sidekick.cli.Terminal?
---@return boolean available
---@return string? reason
function M.available(tool, source)
  tool = tool_for(tool)
  if not tool or type(tool.name) ~= "string" then
    return false, "CLI tool is missing"
  end
  local adapter = adapter_for(tool)
  if adapter == nil or adapter == false then
    return false, ("CLI tool `%s` does not support native conversation fork"):format(tool.name)
  end
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.available) == "function" then
    local available, reason = call(adapter.available, tool, source)
    if available ~= true then
      return false,
        type(reason) == "string" and reason or ("CLI tool `%s` cannot fork this conversation"):format(tool.name)
    end
  end
  local has_command = type(adapter) == "function"
    or (type(adapter) == "table" and vim.islist(adapter) and #adapter > 0)
    or (
      type(adapter) == "table"
      and not vim.islist(adapter)
      and (
        type(adapter.command) == "function"
        or type(adapter.prepare) == "function"
        or type(adapter.args) == "table" and #adapter.args > 0
      )
    )
  if not has_command then
    return false, ("CLI tool `%s` has an incomplete fork adapter"):format(tool.name)
  end
  return true
end

---@param tool sidekick.cli.Tool
---@param source sidekick.cli.Terminal?
---@param opts? {capture?:boolean} Skip provider discovery when false.
---@return boolean ready
---@return string? reason
---@return "ready"|"pending"|"unavailable" status
function M.ready(tool, source, opts)
  tool = tool_for(tool)
  local available, reason = M.available(tool, source)
  if not available then
    return false, reason, "unavailable"
  end
  if not source then
    return true, nil, "ready"
  end
  if source.closed or (type(source.is_running) == "function" and not source:is_running()) then
    return false, "the selected agent is no longer running", "unavailable"
  end

  local conversation = source.conversation or (source.parent and source.parent.conversation)
  if not valid_conversation(tool, conversation) then
    -- Picker enrichment can run frequently while agents are active. Defer
    -- provider discovery until the user actually starts a fork so refreshes
    -- never spawn provider queries for every listed agent.
    if opts and opts.capture == false then
      return false, "an exact conversation id is not available yet", "pending"
    end
    local ok, captured = pcall(Resume.capture, source)
    conversation = ok and captured or nil
    if not ok then
      Util.debug("CLI fork conversation capture failed", captured)
    end
  end
  if not valid_conversation(tool, conversation) then
    return false, "an exact conversation id is not available yet", "pending"
  end

  local adapter = adapter_for(tool)
  local prepared = type(adapter) == "table" and not vim.islist(adapter) and type(adapter.prepare) == "function"
  if not prepared then
    local cmd, mode, command_reason = M.command(tool, conversation, source)
    if not cmd or mode ~= "exact" then
      return false, command_reason or "the exact fork command is not available", "unavailable"
    end
  end
  return true, nil, "ready"
end

---@param tool sidekick.cli.Tool
---@param conversation sidekick.cli.Conversation
---@param source sidekick.cli.Terminal?
---@return string[]? cmd
---@return "exact"|"unsupported" mode
---@return string? reason
function M.command(tool, conversation, source)
  tool = tool_for(tool)
  if not tool or not valid_conversation(tool, conversation) then
    return nil, "unsupported", "conversation does not contain an exact resumable id"
  end

  local available, reason = M.available(tool, source)
  if not available then
    return nil, "unsupported", reason
  end

  local adapter = adapter_for(tool)
  if type(adapter) == "function" then
    local cmd, adapter_reason = call(adapter, tool, conversation, source)
    if type(cmd) == "table" then
      return cmd, "exact"
    end
    return nil, "unsupported", adapter_reason or "fork adapter did not return a command"
  end
  if type(adapter) == "table" and not vim.islist(adapter) then
    if type(adapter.command) == "function" then
      local cmd, adapter_reason = call(adapter.command, tool, conversation, source)
      if type(cmd) == "table" then
        return cmd, "exact"
      end
      return nil, "unsupported", adapter_reason or "fork adapter did not return a command"
    end
    adapter = adapter.args
  end

  if type(adapter) ~= "table" or #adapter == 0 then
    return nil, "unsupported", "fork adapter has no command arguments"
  end

  local cmd = vim.deepcopy(tool.cmd)
  vim.list_extend(cmd, adapter)
  cmd[#cmd + 1] = conversation.id
  return cmd, "exact"
end

local function title(source, opts)
  if opts and type(opts.title) == "string" and vim.trim(opts.title) ~= "" then
    return vim.trim(opts.title)
  end
  local source_title = source.title
  if type(source_title) ~= "string" or vim.trim(source_title) == "" then
    source_title = source.tool.name
  end
  local icon = Config.ui.icons.fork
  icon = type(icon) == "string" and vim.trim(icon) or "↗"
  return ("%s Fork · %s"):format(icon, vim.trim(source_title))
end

local function fork_info(source, conversation)
  local info = {
    provider = conversation.provider,
    id = conversation.id,
  }
  if type(source.title) == "string" and vim.trim(source.title) ~= "" then
    info.title = vim.trim(source.title)
  end
  return info
end

local function stop_timer(terminal)
  local timer = terminal and terminal._sidekick_fork_timer
  terminal._sidekick_fork_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param source sidekick.cli.Terminal
---@param terminal sidekick.cli.Terminal
---@param expected sidekick.cli.Conversation
---@param tool sidekick.cli.Tool
---@param after_start? fun(self:sidekick.cli.Tool,terminal:sidekick.cli.Terminal,conversation:sidekick.cli.Conversation,source:sidekick.cli.Terminal):boolean,string?
local function verify_child(source, terminal, expected, tool, after_start)
  local timeout = math.max(1000, Config.cli.workspace.resume_timeout_ms)
  local started = vim.uv.now()
  local timer = vim.uv.new_timer()
  if not timer then
    source._sidekick_forking = nil
    terminal:close()
    return Util.error("Failed to verify fork: could not create verification timer")
  end

  terminal._sidekick_fork_timer = timer
  local function finish(ok, reason)
    stop_timer(terminal)
    source._sidekick_forking = nil
    if not ok then
      if not terminal.closed then
        terminal:close()
      end
      return Util.error(("Failed to verify fork of `%s`: %s"):format(source.tool.name, reason))
    end
    Session.persist(terminal)
    Util.emit("SidekickCliFork", { id = terminal.id, source_id = source.id })
  end

  local function check()
    if terminal.closed or not terminal:is_running() then
      return finish(false, "child exited before receiving an independent conversation id")
    end

    local conversation = Resume.capture(terminal)
    if conversation and conversation.provider == expected.provider and type(conversation.id) == "string" then
      if conversation.id == expected.id then
        if vim.uv.now() - started >= timeout then
          return finish(false, "provider reused the source conversation id")
        end
        timer:start(250, 0, vim.schedule_wrap(check))
        return
      end
      return finish(true)
    end

    if vim.uv.now() - started >= timeout then
      return finish(false, "child conversation id could not be verified")
    end
    timer:start(250, 0, vim.schedule_wrap(check))
  end

  if after_start then
    local ok, started_ok, reason = pcall(after_start, tool, terminal, expected, source)
    if not ok or started_ok == false then
      stop_timer(terminal)
      source._sidekick_forking = nil
      if not terminal.closed then
        terminal:close()
      end
      return Util.error(
        ("Failed to start fork of `%s`: %s"):format(
          source.tool.name,
          ok and (reason or "provider rejected the fork request") or tostring(started_ok)
        )
      )
    end
  end

  timer:start(0, 0, vim.schedule_wrap(check))
end

---@param source sidekick.cli.Terminal
---@param opts? sidekick.cli.ForkOpts
---@return sidekick.cli.Terminal?
function M.start(source, opts)
  opts = opts or {}
  if not source or source.closed then
    return Util.error("No live agent is available to fork")
  end
  if type(source.is_running) ~= "function" or not source:is_running() then
    return Util.error("The selected agent is no longer running")
  end
  if source._sidekick_forking then
    return Util.warn("A fork is already starting for this agent")
  end

  local tool = Config.get_tool(source.tool.name)
  local available, reason = M.available(tool, source)
  if not available then
    return Util.warn(reason)
  end

  local conversation = Resume.capture(source)
  if not valid_conversation(tool, conversation) then
    return Util.warn(("Cannot fork `%s`: no exact resumable conversation id is available"):format(tool.name))
  end

  source._sidekick_forking = true
  local function launch(cmd)
    if type(cmd) ~= "table" or #cmd == 0 then
      source._sidekick_forking = nil
      return Util.warn(("Cannot fork `%s`: the provider did not return a child command"):format(tool.name))
    end
    local ok, child = pcall(Session.new, {
      tool = tool:clone({
        cmd = cmd,
        env = vim.deepcopy(source.tool.env or {}),
      }),
      cwd = source.cwd,
      backend = "terminal",
      title = title(source, opts),
      forked_from = fork_info(source, conversation),
      skip_resume_prepare = true,
    })
    if not ok then
      source._sidekick_forking = nil
      return Util.error(("Failed to create forked `%s` session: %s"):format(tool.name, tostring(child)))
    end
    local state = State.get_state(child)
    local attached_ok, attached = pcall(State.attach, state, {
      show = true,
      focus = opts.focus ~= false,
      cwd = source.cwd,
    })
    if not attached_ok then
      source._sidekick_forking = nil
      child:close()
      return Util.error(("Failed to attach forked `%s` session: %s"):format(tool.name, tostring(attached)))
    end
    local terminal = attached and attached.terminal
    if not terminal then
      source._sidekick_forking = nil
      child:close()
      return Util.error(("Failed to start forked `%s` terminal"):format(tool.name))
    end

    local adapter = adapter_for(tool)
    local after_start = type(adapter) == "table" and not vim.islist(adapter) and adapter.after_start or nil
    verify_child(source, terminal, conversation, tool, after_start)
    return terminal
  end

  local adapter = adapter_for(tool)
  local prepare = type(adapter) == "table" and not vim.islist(adapter) and adapter.prepare or nil
  if type(prepare) == "function" then
    local callback_called = false
    local function done(cmd, prepare_reason)
      if callback_called then
        return
      end
      callback_called = true
      vim.schedule(function()
        if source.closed or not source:is_running() then
          source._sidekick_forking = nil
          return Util.warn("The selected agent exited before its fork was ready")
        end
        if not cmd then
          source._sidekick_forking = nil
          return Util.warn(
            prepare_reason or ("Cannot fork `%s`: the provider did not return a child command"):format(tool.name)
          )
        end
        launch(cmd)
      end)
    end
    local ok, prepared, prepare_reason = pcall(prepare, tool, conversation, source, done)
    if not ok or prepared == false then
      source._sidekick_forking = nil
      return Util.warn(
        ok and (prepare_reason or ("Cannot fork `%s`"):format(tool.name))
          or ("Cannot fork `%s`: %s"):format(tool.name, prepared)
      )
    end
    return
  end

  local cmd, mode, command_reason = M.command(tool, conversation, source)
  if not cmd or mode ~= "exact" then
    source._sidekick_forking = nil
    return Util.warn(command_reason or ("Cannot fork `%s`"):format(tool.name))
  end
  return launch(cmd)
end

return M
