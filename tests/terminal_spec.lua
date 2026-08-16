---@module 'luassert'

local Activity = require("sidekick.cli.activity")
local Terminal = require("sidekick.cli.terminal")

describe("cli terminal scheduling", function()
  it("coalesces output bursts before updating activity", function()
    local old_output = Activity.output
    local seen = {}
    Activity.output = function(_, output)
      seen[#seen + 1] = output
    end
    local t = setmetatable({ id = "output-coalesce" }, Terminal)

    for i = 1, 100 do
      t:_queue_output("line " .. i)
    end
    vim.wait(1000, function()
      return #seen > 0
    end)

    Activity.output = old_output
    if t.output_timer and not t.output_timer:is_closing() then
      t.output_timer:close()
    end
    assert.are.equal(1, #seen)
    assert.matches("line 1", seen[1])
    assert.matches("line 100", seen[1])
  end)

  it("bounds buffered output passed to status adapters", function()
    local old_output = Activity.output
    local seen
    Activity.output = function(_, output)
      seen = output
    end
    local t = setmetatable({ id = "output-bound" }, Terminal)

    t:_queue_output(string.rep("x", 128 * 1024))
    t:_flush_output()

    Activity.output = old_output
    if t.output_timer and not t.output_timer:is_closing() then
      t.output_timer:close()
    end
    assert.are.equal(64 * 1024, #seen)
  end)

  it("uses a one-shot timer only while input is queued", function()
    local starts = {}
    local timer = {
      start = function(_, timeout, repeat_interval, callback)
        starts[#starts + 1] = { timeout, repeat_interval, callback }
      end,
    }
    local t = setmetatable({
      id = "send-demand",
      _sidekick_ready = true,
      send_queue = { "queued" },
      timer = timer,
      is_running = function()
        return false
      end,
    }, Terminal)

    t:_schedule_send(0)
    assert.are.same({ 0, 0 }, { starts[1][1], starts[1][2] })
    starts[1][3]()
    vim.wait(1000, function()
      return #t.send_queue == 0
    end)

    assert.are.equal(1, #starts)
    assert.is_false(t._sidekick_send_scheduled)
  end)
end)
