---@module 'luassert'

local Activity = require("sidekick.cli.activity")
local Session = require("sidekick.cli.session")
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

  it("clears unread output when entering an agent from another window", function()
    local source = vim.api.nvim_get_current_win()
    local id = "focus-unread-" .. vim.uv.hrtime()
    local t = Session.new({
      id = id,
      cwd = vim.fn.getcwd(),
      backend = "terminal",
      tool = {
        name = "sidekick-focus-test",
        cmd = { vim.o.shell, vim.o.shellcmdflag, "sleep 10" },
        config = {},
      },
    })
    local ok, err = xpcall(function()
      t:start()
      t.normal_mode = true

      local events = {}
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = t.group })) do
        events[autocmd.event] = true
      end
      assert.is_true(events.BufEnter)
      assert.is_true(events.WinEnter)

      local agent_win = assert(t:window())
      vim.api.nvim_set_current_win(agent_win)

      t._sidekick_unread = true
      vim.api.nvim_exec_autocmds("BufEnter", {})
      assert.is_false(Activity.unread(t))

      t._sidekick_unread = true
      vim.api.nvim_set_current_win(source)
      vim.api.nvim_set_current_win(agent_win)
      assert.is_false(Activity.unread(t))
    end, debug.traceback)

    if vim.api.nvim_win_is_valid(source) then
      vim.api.nvim_set_current_win(source)
    end
    if not t.closed then
      t:close()
    end
    assert.is_true(ok, err)
  end)
end)
