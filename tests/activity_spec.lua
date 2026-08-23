---@module 'luassert'

local Activity = require("sidekick.cli.activity")
local Config = require("sidekick.config")
local Util = require("sidekick.util")

describe("cli activity", function()
  local original_notifications

  before_each(function()
    original_notifications = Config.cli.status.notify
    Config.cli.status.notify = false
  end)

  after_each(function()
    Config.cli.status.notify = original_notifications
  end)

  local function terminal(status)
    return {
      id = "activity-test",
      status = status or "idle",
      tool = { config = {} },
      is_running = function()
        return true
      end,
    }
  end

  it("tracks the generic agent lifecycle", function()
    local t = terminal()
    Activity.starting(t)
    assert.are.equal("starting", t.status)
    Activity.ready(t)
    assert.are.equal("idle", t.status)
    Activity.input(t, "hello\n")
    assert.are.equal("working", t.status)
    Activity.output(t, "thinking")
    assert.are.equal("working", t.status)
    Activity.close(t)
  end)

  it("passes output to a tool-specific status adapter", function()
    local seen
    local t = terminal("working")
    t._sidekick_working = true
    t.tool.config.status = function(_, event)
      seen = event.data
      return event.type == "output" and "waiting" or nil
    end

    Activity.output(t, "approve this command?")
    assert.are.equal("approve this command?", seen)
    assert.are.equal("waiting", t.status)
  end)

  it("marks non-zero exits as errors", function()
    local t = terminal("working")
    Activity.exit(t, 1)
    assert.are.equal("error", t.status)
  end)

  it("refreshes activity timestamps for repeated status updates", function()
    local old_now = vim.uv.now
    local now = 100
    vim.uv.now = function()
      now = now + 1
      return now
    end
    local t = terminal("working")

    Activity.set(t, "working")
    local first = t.last_activity
    Activity.set(t, "working")
    local second = t.last_activity

    vim.uv.now = old_now
    assert.are.equal(101, first)
    assert.are.equal(102, second)
  end)

  it("throttles repeated activity events without losing timestamps", function()
    local old_emit = Util.emit
    local old_now = vim.uv.now
    local now = 100
    local events = {}
    Util.emit = function(event, data)
      events[#events + 1] = { event = event, data = data }
    end
    vim.uv.now = function()
      return now
    end
    local t = terminal("working")

    Activity.set(t, "working")
    now = 150
    Activity.set(t, "working")
    now = 200
    Activity.set(t, "working")

    Util.emit = old_emit
    vim.uv.now = old_now
    assert.are.equal(2, #events)
    assert.are.equal(200, t.last_activity)
    assert.are.equal(200, events[2].data.last_activity)
  end)

  it("reuses the quiet timer across output bursts", function()
    local old_ms = Config.cli.status.quiet_ms
    Config.cli.status.quiet_ms = 10000
    local t = terminal("working")
    t._sidekick_working = true

    Activity.output(t, "first")
    local timer = t.activity_timer
    Activity.output(t, "second")

    Config.cli.status.quiet_ms = old_ms
    assert.are.equal(timer, t.activity_timer)
    Activity.close(t)
  end)

  it("tracks unread output until the agent is acknowledged", function()
    local t = terminal("working")
    t._sidekick_working = true

    Activity.output(t, "finished work")

    assert.is_true(Activity.unread(t))
    Activity.ack(t)
    assert.is_false(Activity.unread(t))
    Activity.close(t)
  end)

  it("clears unread output when an agent regains focus", function()
    local t = terminal("done")
    t._sidekick_unread = true
    t.is_focused = function()
      return true
    end

    assert.is_true(Activity.focus(t))
    assert.is_false(Activity.unread(t))

    t._sidekick_unread = true
    t.is_focused = function()
      return false
    end
    assert.is_false(Activity.focus(t))
    assert.is_true(Activity.unread(t))
  end)

  it("acknowledges a completed agent when it is selected", function()
    local t = terminal("done")
    t._sidekick_working = true

    Activity.ack(t)

    assert.are.equal("idle", t.status)
    assert.is_false(t._sidekick_working)
  end)

  it("does not let an old quiet callback complete newer work", function()
    local old_ms = Config.cli.status.quiet_ms
    local old_schedule = vim.schedule
    local scheduled
    Config.cli.status.quiet_ms = 0
    local t = terminal("working")
    t._sidekick_working = true
    Activity.output(t, "old work")
    vim.schedule = function(fn)
      scheduled = fn
    end
    vim.wait(1000, function()
      return scheduled ~= nil
    end)

    Activity.input(t, "new work")
    vim.schedule = old_schedule
    scheduled()
    Config.cli.status.quiet_ms = old_ms

    assert.are.equal("working", t.status)
    Activity.close(t)
  end)

  it("notifies configured background status transitions once", function()
    local original_notify = Util.notify
    local notifications = {}
    Util.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end
    Config.cli.status.notify = { waiting = true, error = true, done = false }
    local t = terminal("working")
    t.title = "Fix tests"
    t.tool.name = "codex"

    Activity.set(t, "waiting")
    Activity.set(t, "waiting")
    Activity.set(t, "working")
    Activity.set(t, "done")
    Activity.set(t, "working")
    Activity.set(t, "error", { code = 7 })

    Util.notify = original_notify
    assert.are.equal(2, #notifications)
    assert.matches("codex", notifications[1].msg)
    assert.matches("Fix tests", notifications[1].msg)
    assert.matches("Waiting for input", notifications[1].msg)
    assert.are.equal(vim.log.levels.INFO, notifications[1].level)
    assert.matches("Exited with code 7", notifications[2].msg)
    assert.are.equal(vim.log.levels.ERROR, notifications[2].level)
  end)

  it("does not notify focused or intentionally closing agents", function()
    local original_notify = Util.notify
    local notifications = 0
    Util.notify = function()
      notifications = notifications + 1
    end
    Config.cli.status.notify = { waiting = true, error = true, done = true }
    local t = terminal("working")
    t.is_focused = function()
      return true
    end

    Activity.set(t, "waiting")
    Activity.set(t, "error", { code = 1 })
    local closing = terminal("working")
    closing.closed = true
    Activity.set(closing, "error", { code = -1 })

    Util.notify = original_notify
    assert.are.equal(0, notifications)
  end)

  it("supports opting into done notifications and disabling all notifications", function()
    local original_notify = Util.notify
    local notifications = {}
    Util.notify = function(msg)
      notifications[#notifications + 1] = msg
    end
    local t = terminal("working")
    Config.cli.status.notify = { waiting = false, error = false, done = true }

    Activity.set(t, "done")
    Config.cli.status.notify = false
    Activity.set(t, "working")
    Activity.set(t, "error", { code = 1 })

    Util.notify = original_notify
    assert.are.equal(1, #notifications)
    assert.matches("Finished", notifications[1])
  end)

  it("drops a queued notification when its status is no longer current", function()
    local original_notify = Util.notify
    local when
    Util.notify = function(_, _, opts)
      when = opts.when
    end
    Config.cli.status.notify = { waiting = true, error = true, done = false }
    local t = terminal("working")

    Activity.set(t, "waiting")
    assert.is_true(when())
    Activity.set(t, "working")

    Util.notify = original_notify
    assert.is_false(when())
  end)
end)
