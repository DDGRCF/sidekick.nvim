local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}

---@alias sidekick.cli.ActivityStatus "idle"|"starting"|"working"|"waiting"|"done"|"error"
---@alias sidekick.cli.ActivityEventType "input"|"output"|"ready"|"exit"

---@param terminal sidekick.cli.Terminal
---@param status sidekick.cli.ActivityStatus
---@param data? table
function M.set(terminal, status, data)
  if terminal.status == status then
    return
  end
  terminal.status = status
  terminal.last_activity = vim.uv.now()
  Util.emit(
    "SidekickCliStatus",
    vim.tbl_extend("force", {
      id = terminal.id,
      status = status,
    }, data or {})
  )
  local ok, Panel = pcall(require, "sidekick.cli.panel")
  if ok then
    Panel.refresh(terminal.id)
  end
end

---@param terminal sidekick.cli.Terminal
---@param event sidekick.cli.ActivityEvent
---@return sidekick.cli.ActivityStatus?
local function adapter(terminal, event)
  local status = terminal.tool and terminal.tool.config and terminal.tool.config.status
  if type(status) ~= "function" then
    return
  end
  local ok, ret = pcall(status, terminal.tool, event)
  if ok then
    return ret
  end
  Util.debug("CLI status adapter failed", ret)
end

---@param terminal sidekick.cli.Terminal
local function stop_timer(terminal)
  terminal._sidekick_activity_generation = (terminal._sidekick_activity_generation or 0) + 1
  local timer = terminal.activity_timer
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  terminal.activity_timer = nil
end

---@param terminal sidekick.cli.Terminal
local function complete_later(terminal)
  stop_timer(terminal)
  local generation = terminal._sidekick_activity_generation
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  terminal.activity_timer = timer
  timer:start(math.max(0, Config.cli.status.quiet_ms), 0, function()
    timer:stop()
    timer:close()
    if terminal.activity_timer == timer then
      terminal.activity_timer = nil
    end
    vim.schedule(function()
      if
        terminal._sidekick_activity_generation == generation
        and terminal:is_running()
        and terminal.status == "working"
      then
        M.set(terminal, "done")
      end
    end)
  end)
end

---@class sidekick.cli.ActivityEvent
---@field type sidekick.cli.ActivityEventType
---@field data? string
---@field code? integer
---@field terminal sidekick.cli.Terminal

---@param terminal sidekick.cli.Terminal
---@param kind sidekick.cli.ActivityEventType
---@param opts? {data?:string,code?:integer}
local function event(terminal, kind, opts)
  opts = opts or {}
  local ev = {
    type = kind,
    data = opts.data,
    code = opts.code,
    terminal = terminal,
  } --[[@as sidekick.cli.ActivityEvent]]
  local exact = adapter(terminal, ev)
  if exact then
    M.set(terminal, exact)
    return exact
  end
end

---@param terminal sidekick.cli.Terminal
function M.starting(terminal)
  stop_timer(terminal)
  M.set(terminal, "starting")
end

---@param terminal sidekick.cli.Terminal
function M.ready(terminal)
  if not event(terminal, "ready") and terminal.status == "starting" then
    M.set(terminal, "idle")
  end
end

---@param terminal sidekick.cli.Terminal
---@param input? string
function M.input(terminal, input)
  stop_timer(terminal)
  terminal._sidekick_working = true
  if not event(terminal, "input", { data = input }) then
    M.set(terminal, "working")
  end
end

---@param terminal sidekick.cli.Terminal
---@param output? string
function M.output(terminal, output)
  if not terminal._sidekick_working then
    return
  end
  if not event(terminal, "output", { data = output }) then
    M.set(terminal, "working")
    complete_later(terminal)
  end
end

---@param terminal sidekick.cli.Terminal
function M.ack(terminal)
  if terminal.status == "done" then
    terminal._sidekick_working = false
    stop_timer(terminal)
    M.set(terminal, "idle")
  end
end

---@param terminal sidekick.cli.Terminal
---@param code integer
function M.exit(terminal, code)
  stop_timer(terminal)
  if not event(terminal, "exit", { code = code }) then
    M.set(terminal, code == 0 and "idle" or "error", { code = code })
  end
end

---@param terminal sidekick.cli.Terminal
function M.close(terminal)
  stop_timer(terminal)
end

return M
