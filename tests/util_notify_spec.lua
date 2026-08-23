---@module 'luassert'

local Util = require("sidekick.util")

describe("util notify", function()
  it("routes to vim.notify with title", function()
    local called = {}
    local original_schedule = vim.schedule
    local original_notify = vim.notify

    vim.schedule = function(cb)
      cb()
    end
    vim.notify = function(msg, level, opts)
      table.insert(called, { msg = msg, level = level, opts = opts })
    end

    Util.error("oops")
    Util.info("hello")
    Util.notify("hidden", vim.log.levels.WARN, {
      when = function()
        return false
      end,
    })
    Util.notify("broken guard", vim.log.levels.WARN, {
      when = function()
        error("guard failed")
      end,
    })

    vim.schedule = original_schedule
    vim.notify = original_notify

    assert.are.same({
      { msg = "oops", level = vim.log.levels.ERROR, opts = { title = "Sidekick" } },
      { msg = "hello", level = vim.log.levels.INFO, opts = { title = "Sidekick" } },
    }, called)
  end)
end)
