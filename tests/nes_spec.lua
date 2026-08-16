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

describe("nes hunk actions", function()
  local buf
  local original_get_client
  local original_ui_update
  local original_inline

  before_each(function()
    local Edit = require("sidekick.nes.edit")
    original_get_client = Config.get_client
    original_ui_update = require("sidekick.nes.ui").update
    original_inline = Config.nes.diff.inline
    Config.nes.diff.inline = false
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.util.buf_versions[buf] = 0
    Nes.enabled = true
    Config.nes.enabled = true
    Config.get_client = function()
      return { id = 1, offset_encoding = "utf-16", name = "copilot" }
    end
    require("sidekick.nes.ui").update = function() end
    local edit = setmetatable({
      buf = buf,
      from = { 0, 0 },
      to = { 2, 5 },
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 2, character = 5 },
      },
      text = "one\nTWO\nthree\nfour",
      textDocument = { uri = "file:///tmp/nes-hunk.lua", version = 0 },
    }, Edit)
    Nes._edits = { edit }
  end)

  after_each(function()
    Config.get_client = original_get_client
    require("sidekick.nes.ui").update = original_ui_update
    Config.nes.diff.inline = original_inline
    Nes._edits = {}
    Nes._skip_update = {}
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("accepts only the hunk under the cursor and keeps the remaining hunk", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_true(Nes.accept())
    assert.are.same({ "one", "TWO", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(1, Nes.summary().hunks)
  end)

  it("rejects the current hunk without changing the buffer", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_true(Nes.reject())
    assert.are.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(1, Nes.summary().hunks)
  end)

  it("keeps adjacent same-line edits after accepting one", function()
    local Edit = require("sidekick.nes.edit")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij" })

    local function make_edit(from_col, to_col, text, uri)
      return setmetatable({
        buf = buf,
        from = { 0, from_col },
        to = { 0, to_col },
        range = {
          start = { line = 0, character = from_col },
          ["end"] = { line = 0, character = to_col },
        },
        text = text,
        textDocument = { uri = uri, version = 0 },
      }, Edit)
    end

    Nes._edits = {
      make_edit(0, 3, "ABC", "file:///tmp/nes-adjacent-a.lua"),
      make_edit(3, 6, "DEF", "file:///tmp/nes-adjacent-b.lua"),
    }

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(Nes.accept())
    assert.are.same({ "ABCdefghij" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(1, #Nes.get(buf))
  end)

  it("uses the cursor column to select inline hunks", function()
    local Edit = require("sidekick.nes.edit")
    Config.nes.diff.inline = "words"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a b c d e f g h i j" })
    local text = "A b c d e f g h i J"
    Nes._edits = {
      setmetatable({
        buf = buf,
        from = { 0, 0 },
        to = { 0, #"a b c d e f g h i j" },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = #"a b c d e f g h i j" },
        },
        text = text,
        textDocument = { uri = "file:///tmp/nes-inline.lua", version = 0 },
      }, Edit),
    }

    vim.api.nvim_win_set_cursor(0, { 1, 18 })
    assert.is_true(Nes.accept())
    assert.are.same({ "a b c d e f g h i J" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)

describe("nes preview refresh", function()
  local Preview = require("sidekick.nes.preview")
  local Edit = require("sidekick.nes.edit")
  local buf
  local original_get_client
  local original_enabled
  local original_nes_enabled

  local function preview_windows()
    local ret = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if name:match("%[NES current%]$") then
        ret["[NES current]"] = win
      elseif name:match("%[NES suggested%]$") then
        ret["[NES suggested]"] = win
      end
    end
    return ret
  end

  before_each(function()
    original_get_client = Config.get_client
    original_enabled = Nes.enabled
    original_nes_enabled = Config.nes.enabled
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdef", "second" })
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.util.buf_versions[buf] = 0
    Nes.enabled = true
    Config.nes.enabled = true
    Config.get_client = function()
      return { offset_encoding = "utf-16" }
    end
    Nes._edits = {
      setmetatable({
        buf = buf,
        from = { 0, 0 },
        to = { 0, 3 },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 3 },
        },
        text = "XYZ",
        textDocument = { uri = "", version = 0 },
      }, Edit),
    }
  end)

  after_each(function()
    Preview.close()
    Config.get_client = original_get_client
    Nes.enabled = original_enabled
    Config.nes.enabled = original_nes_enabled
    Nes._edits = {}
    Nes._skip_update = {}
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("refreshes preview buffers in place and keeps focus", function()
    assert.is_true(Preview.open())
    local before = preview_windows()
    assert.is_not_nil(before["[NES current]"])
    assert.is_not_nil(before["[NES suggested]"])
    vim.api.nvim_set_current_win(before["[NES suggested]"])

    for _ = 1, 5 do
      assert.is_true(Preview.refresh())
    end

    local after = preview_windows()
    assert.are.equal(before["[NES current]"], after["[NES current]"])
    assert.are.equal(before["[NES suggested]"], after["[NES suggested]"])
    assert.are.equal(before["[NES suggested]"], vim.api.nvim_get_current_win())
    assert.are.same({ "abcdef", "second" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.same(
      { "XYZdef", "second" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(after["[NES suggested]"]), 0, -1, false)
    )
  end)

  it("does not rebuild preview windows on resize events", function()
    assert.is_true(Preview.open())
    local before = preview_windows()
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("VimResized", {})
    end
    local after = preview_windows()
    assert.are.equal(before["[NES current]"], after["[NES current]"])
    assert.are.equal(before["[NES suggested]"], after["[NES suggested]"])
  end)

  it("does not clear edits when a preview pane emits TextChanged", function()
    Nes.setup()
    assert.is_true(Preview.open())
    local before = preview_windows()
    local suggested_buf = vim.api.nvim_win_get_buf(before["[NES suggested]"])
    vim.api.nvim_set_current_win(before["[NES suggested]"])
    assert.is_true(Preview.refresh())
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = suggested_buf })
    vim.wait(150)

    assert.is_true(vim.api.nvim_win_is_valid(before["[NES suggested]"]))
    assert.are.equal(1, #Nes.get(buf))
  end)
end)
