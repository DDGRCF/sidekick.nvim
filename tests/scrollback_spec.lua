---@module 'luassert'

local Scrollback = require("sidekick.cli.scrollback")

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
end)
