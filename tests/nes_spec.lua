---@module 'luassert'

local Config = require("sidekick.config")
local Nes = require("sidekick.nes")

describe("nes enabled option", function()
  local buf
  local original_enabled

  before_each(function()
    original_enabled = Config.nes.enabled
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local foo" })
    vim.api.nvim_set_current_buf(buf)
    vim.g.sidekick_nes = nil
    vim.b[buf].sidekick_nes = nil
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.g.sidekick_nes = nil
    vim.b.sidekick_nes = nil
    Config.nes.enabled = original_enabled
    Nes._edits = {}
  end)

  it("is enabled by default", function()
    assert.is_true(Config.nes.enabled(buf))
  end)

  it("honors global toggle", function()
    vim.g.sidekick_nes = false
    assert.is_false(Config.nes.enabled(buf))
  end)

  it("honors buffer toggle", function()
    vim.b[buf].sidekick_nes = false
    assert.is_false(Config.nes.enabled(buf))
  end)

  it("filters pending edits when disabled", function()
    local version = vim.lsp.util.buf_versions[buf] or 0
    vim.lsp.util.buf_versions[buf] = version
    ---@type sidekick.NesEdit
    Nes._edits = {
      {
        buf = buf,
        from = { 0, 0 },
        to = { 0, 0 },
        text = "",
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
        textDocument = { uri = "", version = version },
        command = { title = "", command = "" },
      },
    }

    vim.g.sidekick_nes = false
    assert.are.same({}, Nes.get(buf))
  end)
end)

describe("nes review navigation", function()
  local buf
  local original_enabled
  local original_nes_enabled

  local function edit(pos, hunks)
    local version = vim.lsp.util.buf_versions[buf] or 0
    return {
      buf = buf,
      from = vim.deepcopy(pos),
      to = vim.deepcopy(pos),
      text = "",
      textDocument = { uri = "", version = version },
      is_empty = function()
        return false
      end,
      diff = function(self)
        return { hunks = self._hunks }
      end,
      _hunks = hunks,
    }
  end

  before_each(function()
    original_enabled = Nes.enabled
    original_nes_enabled = Config.nes.enabled
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.util.buf_versions[buf] = vim.lsp.util.buf_versions[buf] or 0
    Nes.enabled = true
    Config.nes.enabled = true
  end)

  after_each(function()
    Nes._edits = {}
    Nes.enabled = original_enabled
    Config.nes.enabled = original_nes_enabled
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("summarizes edits and hunks in source order", function()
    Nes._edits = {
      edit({ 2, 0 }, { { pos = { 2, 0 }, cover = 1 } }),
      edit({ 0, 0 }, {
        { pos = { 0, 0 }, cover = 1 },
        { pos = { 0, 3 }, cover = 1 },
      }),
    }

    local summary = Nes.summary()
    local items = Nes.review_items()

    assert.are.same({ edits = 2, hunks = 3, current = 1 }, summary)
    assert.are.same(
      { { 0, 0 }, { 0, 3 }, { 2, 0 } },
      vim.tbl_map(function(item)
        return item.pos
      end, items)
    )

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    assert.is_nil(Nes.summary().current)
  end)

  it("navigates to the next and previous edit hunk", function()
    Nes._edits = {
      edit({ 0, 0 }, { { pos = { 0, 0 }, cover = 1 } }),
      edit({ 2, 0 }, { { pos = { 2, 0 }, cover = 1 } }),
    }
    local original_jump = Nes._jump
    local jumped
    Nes._jump = function(pos)
      jumped = pos
      return true
    end

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(Nes.next())
    assert.are.same({ 2, 0 }, jumped)

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    assert.is_true(Nes.prev())
    assert.are.same({ 0, 0 }, jumped)

    Nes._jump = original_jump
  end)

  it("updates the review summary without redrawing diff marks", function()
    local UI = require("sidekick.nes.ui")
    local old_show = Config.nes.diff.show
    local old_signs = Config.nes.signs
    local old_summary = Config.nes.review.summary
    Config.nes.diff.show = "always"
    Config.nes.signs = true
    Config.nes.review.summary = true

    local edit = {
      buf = buf,
      from = { 0, 0 },
      to = { 0, 0 },
      text = "updated",
      textDocument = { version = vim.lsp.util.buf_versions[buf] },
      is_empty = function()
        return false
      end,
      diff = function()
        return {
          hunks = {
            { pos = { 0, 0 }, cover = 1, extmarks = {} },
          },
        }
      end,
    }
    Nes._edits = { edit }

    UI.render(edit)
    local before = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, {})
    UI.update_summary()
    local after = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, {})

    UI._hide(buf)
    Config.nes.diff.show = old_show
    Config.nes.signs = old_signs
    Config.nes.review.summary = old_summary
    assert.are.same(before, after)
  end)
end)
