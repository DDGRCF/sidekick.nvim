---@module 'luassert'

local Activity = require("sidekick.cli.activity")
local Config = require("sidekick.config")

describe("cli activity", function()
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
end)
