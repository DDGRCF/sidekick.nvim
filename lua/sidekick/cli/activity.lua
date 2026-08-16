local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}

local ACTIVITY_EVENT_INTERVAL = 100 -- ms

---@alias sidekick.cli.ActivityStatus "idle"|"starting"|"working"|"waiting"|"done"|"error"
---@alias sidekick.cli.ActivityEventType "input"|"output"|"ready"|"exit"

local function is_focused(terminal)
  if type(terminal.is_focused) ~= "function" then
    return false
  end
  local ok, focused = pcall(terminal.is_focused, terminal)
  return ok and focused == true
end

local function set_unread(terminal, unread)
  unread = unread == true
  if terminal._sidekick_unread == unread then
    return
  end
  terminal._sidekick_unread = unread
  Util.emit("SidekickCliAttention", {
    id = terminal.id,
    unread = unread,
  })
  local ok, Panel = pcall(require, "sidekick.cli.panel")
  if ok then
    Panel.refresh(terminal.id)
  end
end

local function mark_unread(terminal)
  if not is_focused(terminal) then
    set_unread(terminal, true)
  end
end

---@param terminal sidekick.cli.Terminal
---@param status sidekick.cli.ActivityStatus
---@param data? table
function M.set(terminal, status, data)
  terminal.last_activity = vim.uv.now()
  if terminal.status == status then
    local last = terminal._sidekick_activity_emitted_at
    if last and terminal.last_activity - last < ACTIVITY_EVENT_INTERVAL then
      return
    end
    terminal._sidekick_activity_emitted_at = terminal.last_activity
    Util.emit("SidekickCliActivity", {
      id = terminal.id,
      last_activity = terminal.last_activity,
    })
    return
  end
  terminal.status = status
  terminal._sidekick_activity_emitted_at = terminal.last_activity
  if status == "waiting" or status == "done" or status == "error" then
    mark_unread(terminal)
  end
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
---@param close? boolean
local function stop_timer(terminal, close)
  terminal._sidekick_activity_generation = (terminal._sidekick_activity_generation or 0) + 1
  local timer = terminal.activity_timer
  if timer and not timer:is_closing() then
    timer:stop()
    if close then
      timer:close()
    end
  end
  if close then
    terminal.activity_timer = nil
  end
end

---@param terminal sidekick.cli.Terminal
local function complete_later(terminal)
  stop_timer(terminal)
  local generation = terminal._sidekick_activity_generation
  local timer = terminal.activity_timer or vim.uv.new_timer()
  if not timer then
    return
  end
  terminal.activity_timer = timer
  timer:start(math.max(0, Config.cli.status.quiet_ms), 0, function()
    timer:stop()
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
  mark_unread(terminal)
  if not event(terminal, "output", { data = output }) then
    M.set(terminal, "working")
    complete_later(terminal)
  end
end

---@param terminal sidekick.cli.Terminal
function M.ack(terminal)
  M.read(terminal)
  if terminal.status == "done" then
    terminal._sidekick_working = false
    stop_timer(terminal)
    M.set(terminal, "idle")
  end
end

---@param terminal sidekick.cli.Terminal
function M.read(terminal)
  set_unread(terminal, false)
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
  stop_timer(terminal, true)
end

---@param terminal sidekick.cli.Terminal
---@return boolean
function M.unread(terminal)
  return terminal._sidekick_unread == true
end

return M
