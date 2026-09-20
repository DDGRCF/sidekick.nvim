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

    assert.is_true(Scrollback.is_enabled(direct_non_native))
    assert.is_true(Scrollback.is_enabled(direct_default))
    assert.is_false(Scrollback.is_enabled(direct_native))
    assert.is_true(Scrollback.is_enabled(mux_non_native))
    assert.is_false(Scrollback.is_enabled(mux_native))
    assert.is_true(Scrollback.is_enabled(mux_no_dump))

    local old_scrollback = Config.cli.scrollback
    Config.cli.scrollback = { enabled = false }
    assert.is_false(Scrollback.is_enabled(direct_non_native))
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

  it("maintains stable snapshot cursor and view while live terminal streams background output", function()
    local source = vim.api.nvim_get_current_win()
    local id = "stable-scrollback-" .. vim.uv.hrtime()
    local t = Session.new({
      id = id,
      cwd = vim.fn.getcwd(),
      backend = "terminal",
      tool = {
        name = "sidekick-stable-scrollback-test",
        cmd = { vim.o.shell },
        config = {},
        native_scroll = false,
      },
    })

    local ok, err = xpcall(function()
      t:start()
      local win = assert(t:window())
      vim.api.nvim_set_current_win(win)

      -- Seed initial lines
      vim.fn.chansend(t.job, "i=1; while [ $i -le 30 ]; do echo init$i; i=$((i + 1)); done\n")
      vim.wait(1000, function()
        return vim.api.nvim_buf_line_count(t.buf) >= 30
      end)

      local sb = assert(t.scrollback)

      -- If sb was opened on WinEnter in normal mode, close it first to test open/close lifecycle
      if sb:is_open() then
        sb:close()
      end
      assert.is_false(sb:is_open())
      assert.are.equal(t.buf, vim.api.nvim_win_get_buf(win))

      -- Enter scrollback snapshot
      sb:open()
      assert.is_true(sb:is_open())
      assert.are.equal(sb.buf, vim.api.nvim_win_get_buf(win))

      -- Move cursor to line 5 in snapshot buffer
      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      local cursor_before = vim.api.nvim_win_get_cursor(win)
      local view_before = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      local snap_lines_before = vim.api.nvim_buf_get_lines(sb.buf, 0, -1, false)

      -- Stream significant output into the live terminal buffer
      vim.fn.chansend(t.job, "i=1; while [ $i -le 200 ]; do echo stream$i; i=$((i + 1)); done\n")
      vim.wait(1000, function()
        return vim.api.nvim_buf_line_count(t.buf) > 100
      end)

      -- Snapshot cursor and view in the window must remain identical
      local cursor_after = vim.api.nvim_win_get_cursor(win)
      local view_after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      local snap_lines_after = vim.api.nvim_buf_get_lines(sb.buf, 0, -1, false)

      assert.are.same(cursor_before, cursor_after)
      assert.are.equal(view_before.topline, view_after.topline)
      assert.are.equal(view_before.lnum, view_after.lnum)
      assert.are.same(snap_lines_before, snap_lines_after)
      assert.are.equal(sb.buf, vim.api.nvim_win_get_buf(win))

      -- Closing scrollback restores live terminal buffer
      sb:close()
      assert.is_false(sb:is_open())
      assert.are.equal(t.buf, vim.api.nvim_win_get_buf(win))
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
