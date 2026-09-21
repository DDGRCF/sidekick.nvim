---@module 'luassert'

local Config = require("sidekick.config")
local Scrollback = require("sidekick.cli.scrollback")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")

describe("cli scrollback", function()
  it("refreshes copied mux output before scrolling it into view", function()
    local win = vim.api.nvim_get_current_win()
    local source = vim.api.nvim_get_current_buf()
    local terminal = {
      parent = {
        dump = function()
          return "first\nsecond\n"
        end,
      },
      window = function()
        return win
      end,
      bo = function() end,
      keys = function() end,
    }
    local scrollback = setmetatable({
      terminal = function()
        return terminal
      end,
    }, Scrollback)

    local ok, err = xpcall(function()
      scrollback:open()
      assert.is_true(vim.api.nvim_buf_is_valid(scrollback.buf))
      assert.are.equal(9998, vim.bo[scrollback.buf].scrollback)
    end, debug.traceback)

    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(source) then
      vim.api.nvim_win_set_buf(win, source)
    end
    if scrollback.buf and vim.api.nvim_buf_is_valid(scrollback.buf) then
      vim.api.nvim_buf_delete(scrollback.buf, { force = true })
    end
    assert.is_true(ok, err)
  end)

  it("opens only explicit requests while an unfocused terminal is idle", function()
    local opened = {}
    local terminal = {
      is_open = function()
        return true
      end,
      is_focused = function()
        return false
      end,
    }
    local scrollback = setmetatable({
      terminal = function()
        return terminal
      end,
      is_open = function()
        return false
      end,
      open = function(_, win_pos)
        opened[#opened + 1] = win_pos
      end,
    }, Scrollback)

    scrollback:update({ open = true, win_pos = { 3, 4 }, reason = "mouse" })
    scrollback.closing = true
    scrollback:update({ open = true, win_pos = { 5, 6 }, reason = "mouse" })

    assert.are.same({ { 3, 4 } }, opened)
  end)

  it("respects native_scroll and configuration when determining enablement", function()
    local direct_non_native = { tool = { native_scroll = false } }
    local direct_default = { tool = {} }
    local direct_native = { tool = { native_scroll = true } }
    local mux_non_native = {
      parent = { dump = function() end },
      tool = { native_scroll = false },
    }
    local mux_native = {
      parent = { dump = function() end },
      tool = { native_scroll = true },
    }
    local mux_no_dump = {
      parent = {},
      tool = { native_scroll = false },
    }

    assert.is_false(Scrollback.is_enabled(direct_non_native))
    assert.is_false(Scrollback.is_enabled(direct_default))
    assert.is_false(Scrollback.is_enabled(direct_native))
    assert.is_true(Scrollback.is_enabled(mux_non_native))
    assert.is_false(Scrollback.is_enabled(mux_native))
    assert.is_false(Scrollback.is_enabled(mux_no_dump))

    local old_scrollback = Config.cli.scrollback
    Config.cli.scrollback = { enabled = true }
    assert.is_true(Scrollback.is_enabled(direct_non_native))
    assert.is_true(Scrollback.is_enabled(mux_no_dump))
    Config.cli.scrollback = false
    assert.is_false(Scrollback.is_enabled(direct_non_native))
    Config.cli.scrollback = old_scrollback
  end)

  it("bounds terminal dump and provides async dump", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 50 do
      lines[#lines + 1] = "line " .. i
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local t = setmetatable({
      buf = buf,
      buf_valid = function()
        return true
      end,
    }, Terminal)

    local dumped = t:dump(10)
    local dumped_lines = vim.split(dumped, "\n", { plain = true })
    assert.are.equal(10, #dumped_lines)
    assert.are.equal("line 41", dumped_lines[1])
    assert.are.equal("line 50", dumped_lines[10])

    local async_dumped
    t:dump_async(10, function(output)
      async_dumped = output
    end)
    vim.wait(1000, function()
      return async_dumped ~= nil
    end)
    assert.are.equal(dumped, async_dumped)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("configures live terminal scrollback limit", function()
    local t = setmetatable({
      opts = { bo = {} },
    }, Terminal)

    local buf1 = vim.api.nvim_create_buf(false, true)
    t:bo(buf1)
    assert.are.equal(100000, vim.bo[buf1].scrollback)
    vim.api.nvim_buf_delete(buf1, { force = true })

    local old_scrollback = Config.cli.scrollback
    Config.cli.scrollback = { enabled = true, dump = 2000, limit = 50000 }
    local buf2 = vim.api.nvim_create_buf(false, true)
    t:bo(buf2)
    assert.are.equal(50000, vim.bo[buf2].scrollback)
    vim.api.nvim_buf_delete(buf2, { force = true })
    Config.cli.scrollback = old_scrollback

    local t_custom = setmetatable({
      opts = { bo = { scrollback = 25000 } },
    }, Terminal)
    local buf3 = vim.api.nvim_create_buf(false, true)
    t_custom:bo(buf3)
    assert.are.equal(25000, vim.bo[buf3].scrollback)
    vim.api.nvim_buf_delete(buf3, { force = true })
  end)

  it("reproduces cursor eviction in a live terminal with bounded scrollback", function()
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      "local buf = vim.api.nvim_create_buf(false, true)",
      "vim.api.nvim_win_set_buf(0, buf)",
      "vim.bo[buf].scrollback = 10",
      "local command = [[i=1; while [ $i -le 30 ]; do echo init$i; i=$((i + 1)); done; echo SEED_DONE; sleep 0.5; i=1; while [ $i -le 200 ]; do echo stream$i; i=$((i + 1)); done; echo STREAM_DONE]]",
      'local job = vim.fn.jobstart({ "sh", "-c", command }, { term = true })',
      'assert(vim.wait(2000, function() return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "SEED_DONE") end) == true)',
      "local count = vim.api.nvim_buf_line_count(buf)",
      "vim.api.nvim_win_set_cursor(0, { math.max(1, count - 5), 0 })",
      "assert(vim.api.nvim_win_get_cursor(0)[1] > 1)",
      'assert(vim.wait(3000, function() return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "STREAM_DONE") end) == true)',
      "assert(vim.api.nvim_win_get_cursor(0)[1] == 1)",
      'assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "init1"))',
      "if vim.fn.jobwait({ job }, 0)[1] == -1 then vim.fn.jobstop(job) end",
      "vim.cmd.qa({ bang = true })",
    }, script)

    local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true }):wait()
    vim.fn.delete(script)
    assert(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
  end)

  it("keeps a static snapshot stable while the live buffer changes", function()
    local win = vim.api.nvim_get_current_win()
    local source = vim.api.nvim_get_current_buf()
    local live = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(live, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(win, live)

    local terminal = {
      buf = live,
      normal_mode = false,
      window = function()
        return win
      end,
      is_open = function()
        return true
      end,
      is_focused = function()
        return true
      end,
      bo = function() end,
      keys = function() end,
      dump = function()
        return table.concat(vim.api.nvim_buf_get_lines(live, 0, -1, false), "\n")
      end,
    }
    local scrollback = setmetatable({
      terminal = function()
        return terminal
      end,
    }, Scrollback)

    local ok, err = xpcall(function()
      scrollback:open()
      assert.is_true(scrollback:is_open())
      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      local cursor = vim.api.nvim_win_get_cursor(win)
      local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      local snapshot = vim.api.nvim_buf_get_lines(scrollback.buf, 0, -1, false)

      vim.api.nvim_buf_set_lines(live, -1, -1, false, { "background output" })
      assert.are.same(cursor, vim.api.nvim_win_get_cursor(win))
      assert.are.equal(view.topline, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
      assert.are.same(snapshot, vim.api.nvim_buf_get_lines(scrollback.buf, 0, -1, false))
    end, debug.traceback)

    if vim.api.nvim_buf_is_valid(source) then
      vim.api.nvim_win_set_buf(win, source)
    end
    if scrollback.buf and vim.api.nvim_buf_is_valid(scrollback.buf) then
      vim.api.nvim_buf_delete(scrollback.buf, { force = true })
    end
    if vim.api.nvim_buf_is_valid(live) then
      vim.api.nvim_buf_delete(live, { force = true })
    end
    assert.is_true(ok, err)
  end)

  it("handles TermLeave, WinEnter, and TermEnter when snapshots are enabled", function()
    local source = vim.api.nvim_get_current_win()
    local old_scrollback = Config.cli.scrollback
    Config.cli.scrollback = vim.tbl_extend("force", {}, old_scrollback, { enabled = true })
    local id = "scrollback-lifecycle-" .. vim.uv.hrtime()
    local t = Session.new({
      id = id,
      cwd = vim.fn.getcwd(),
      backend = "terminal",
      tool = {
        name = "sidekick-scrollback-lifecycle-test",
        cmd = { "sh", "-c", "sleep 10" },
        config = {},
        native_scroll = false,
      },
    })
    local original_mode = vim.fn.mode
    local original_stopinsert = vim.cmd.stopinsert
    local original_update
    local sb
    local mode = "n"

    local ok, err = xpcall(function()
      t:start()
      local win = assert(t:window())
      vim.api.nvim_set_current_win(win)
      sb = assert(t.scrollback)
      vim.fn.mode = function(full)
        return mode == "t" and "t" or full and "nt" or "n"
      end

      vim.api.nvim_exec_autocmds("TermLeave", { buffer = t.buf })
      assert.is_true(vim.wait(1000, function()
        return sb:is_open()
      end))
      assert.is_true(t.normal_mode)

      local reasons = {}
      local stopinsert_calls = 0
      original_update = sb.update
      sb.update = function(self, opts)
        reasons[#reasons + 1] = opts and opts.reason
        return original_update(self, opts)
      end
      vim.cmd.stopinsert = function(...)
        stopinsert_calls = stopinsert_calls + 1
        return original_stopinsert(...)
      end

      vim.api.nvim_set_current_win(source)
      vim.api.nvim_set_current_win(win)
      assert.is_true(vim.wait(1000, function()
        return vim.tbl_contains(reasons, "WinEnter")
      end))
      assert.is_true(stopinsert_calls > 0)
      assert.is_true(sb:is_open())
      assert.is_true(t.normal_mode)
      sb.update = original_update
      original_update = nil
      vim.cmd.stopinsert = original_stopinsert

      mode = "t"
      vim.api.nvim_exec_autocmds("TermEnter", { buffer = sb.buf })
      assert.is_true(vim.wait(1000, function()
        return not sb:is_open() and vim.api.nvim_win_get_buf(win) == t.buf
      end))
      assert.is_false(t.normal_mode)
    end, debug.traceback)

    vim.fn.mode = original_mode
    vim.cmd.stopinsert = original_stopinsert
    Config.cli.scrollback = old_scrollback
    if original_update and sb then
      sb.update = original_update
    end
    if vim.api.nvim_win_is_valid(source) then
      vim.api.nvim_set_current_win(source)
    end
    if not t.closed then
      t:close()
    end
    assert.is_true(ok, err)
  end)
end)
