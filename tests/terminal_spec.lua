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

  it("coalesces output signals without collecting text", function()
    local old_output = Activity.output
    local calls = 0
    local seen = "unexpected"
    Activity.output = function(_, output)
      calls = calls + 1
      seen = output
    end
    local t = setmetatable({ id = "output-signal" }, Terminal)

    for _ = 1, 100 do
      t:_queue_output()
    end
    vim.wait(1000, function()
      return calls > 0
    end)

    Activity.output = old_output
    if t.output_timer and not t.output_timer:is_closing() then
      t.output_timer:close()
    end
    assert.are.equal(1, calls)
    assert.is_nil(seen)
  end)

  it("reads changed text only for custom status adapters", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    local queued = {}
    local t = setmetatable({
      tool = { config = {} },
      _queue_output = function(_, output)
        queued[#queued + 1] = output == nil and true or output
      end,
    }, Terminal)
    local old_get_lines = vim.api.nvim_buf_get_lines
    local reads = 0
    vim.api.nvim_buf_get_lines = function(...)
      reads = reads + 1
      return old_get_lines(...)
    end

    t:_on_lines(buf, 0, 2)
    assert.are.same({ true }, queued)
    assert.are.equal(0, reads)

    t.tool.config.status = function() end
    t:_on_lines(buf, 0, 2)

    vim.api.nvim_buf_get_lines = old_get_lines
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.are.same({ true, "one\ntwo" }, queued)
    assert.are.equal(1, reads)
  end)

  it("ignores terminal changes with no new lines", function()
    local queued = false
    local t = setmetatable({
      tool = { config = { status = function() end } },
      _queue_output = function()
        queued = true
      end,
    }, Terminal)

    t:_on_lines(0, 7, 7)

    assert.is_false(queued)
  end)

  it("counts ready lines without reading the full buffer", function()
    for _, trailing in ipairs({ 0, 99, 250 }) do
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = { "one", "two", "three", "four", "five", "six" }
      for _ = 1, trailing do
        lines[#lines + 1] = ""
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local t = setmetatable({ buf = buf }, Terminal)
      local old_get_lines = vim.api.nvim_buf_get_lines
      local reads = {}
      vim.api.nvim_buf_get_lines = function(changed_buf, first, last, strict)
        reads[#reads + 1] = { first, last }
        return old_get_lines(changed_buf, first, last, strict)
      end

      local count = t:_ready_line_count()

      vim.api.nvim_buf_get_lines = old_get_lines
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.are.equal(6, count)
      for _, range in ipairs(reads) do
        assert.is_true(range[2] ~= -1)
        assert.is_true(range[2] - range[1] <= 100)
      end
    end
  end)

  it("checks the terminal cursor only while focused in terminal mode", function()
    local cases = {
      { focused = true, mode = "t", line = 1, ready = false },
      { focused = true, mode = "t", line = 4, ready = true },
      { focused = true, mode = "n", line = 1, ready = true },
      { focused = false, mode = "t", line = 1, ready = true },
    }
    local old_mode = vim.fn.mode
    local ok, err = xpcall(function()
      for _, case in ipairs(cases) do
        vim.fn.mode = function()
          return case.mode
        end
        local t = setmetatable({
          is_focused = function()
            return case.focused
          end,
        }, Terminal)
        assert.are.equal(case.ready, t:_ready_cursor(case.line))
      end
    end, debug.traceback)
    vim.fn.mode = old_mode
    assert.is_true(ok, err)
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
