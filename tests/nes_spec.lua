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

describe("nes LSP synchronization", function()
  local buf
  local original_enabled
  local original_nes_enabled
  local original_get_client
  local original_get_client_by_id

  before_each(function()
    original_enabled = Nes.enabled
    original_nes_enabled = Config.nes.enabled
    original_get_client = Config.get_client
    original_get_client_by_id = vim.lsp.get_client_by_id
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local foo = 1" })
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.util.buf_versions[buf] = 7
    Nes.enabled = true
    Config.nes.enabled = true
    Nes._edits = {}
    Nes._requests = {}
  end)

  after_each(function()
    Config.get_client = original_get_client
    vim.lsp.get_client_by_id = original_get_client_by_id
    Nes.enabled = original_enabled
    Config.nes.enabled = original_nes_enabled
    Nes._edits = {}
    Nes._requests = {}
    Nes._skip_update = {}
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("ignores stale LspNotify versions and requests the current version", function()
    local requests = {}
    local client = {
      id = 91,
      offset_encoding = "utf-16",
      request = function(_, method, params)
        requests[#requests + 1] = { method = method, params = params }
        return false
      end,
    }
    Config.get_client = function(target)
      assert.are.equal(buf, target)
      return client
    end

    Nes.update({
      buf = buf,
      data = { params = { textDocument = { version = 6 } } },
    })
    assert.are.equal(0, #requests)

    Nes.update({
      buf = buf,
      data = { params = { textDocument = { version = 7 } } },
    })
    assert.are.equal(1, #requests)
    assert.are.equal("textDocument/copilotInlineEdit", requests[1].method)
    assert.are.equal(7, requests[1].params.textDocument.version)
  end)

  it("notifies Copilot when a valid inline edit is shown", function()
    local notified
    local client = {
      id = 92,
      offset_encoding = "utf-16",
      notify = function(_, method, params)
        notified = { method = method, params = params }
      end,
    }
    vim.lsp.get_client_by_id = function(id)
      return id == client.id and client or nil
    end
    Nes._requests[client.id] = 17

    Nes._handler(nil, {
      edits = {
        {
          command = { title = "show", command = "copilot.show", arguments = { "edit-1" } },
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 0 },
          },
          text = "local foo = 2",
          textDocument = { uri = vim.uri_from_bufnr(buf), version = 7 },
        },
      },
    }, { client_id = client.id, request_id = 17 })

    assert.are.equal("textDocument/didShowInlineEdit", notified.method)
    assert.are.same({ "edit-1" }, notified.params.item.command.arguments)
    assert.are.equal(1, #Nes._edits)
  end)
end)

describe("nes review navigation", function()
  local buf
  local original_enabled
  local original_nes_enabled
  local original_show
  local original_signs
  local original_summary
  local extra_bufs

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
    original_show = Config.nes.diff.show
    original_signs = Config.nes.signs
    original_summary = Config.nes.review.summary
    extra_bufs = {}
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.util.buf_versions[buf] = vim.lsp.util.buf_versions[buf] or 0
    Nes.enabled = true
    Config.nes.enabled = true
  end)

  after_each(function()
    require("sidekick.nes.ui").hide()
    Nes._edits = {}
    Nes._invalidate_review()
    Nes.enabled = original_enabled
    Config.nes.enabled = original_nes_enabled
    Config.nes.diff.show = original_show
    Config.nes.signs = original_signs
    Config.nes.review.summary = original_summary
    for _, extra in ipairs(extra_bufs) do
      if vim.api.nvim_buf_is_valid(extra) then
        vim.api.nvim_buf_delete(extra, { force = true })
      end
    end
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

  it("invalidates the review cache when NES is disabled for a buffer", function()
    Config.nes.enabled = function(target)
      return vim.b[target].sidekick_nes ~= false
    end
    Nes._edits = {
      edit({ 0, 0 }, { { pos = { 0, 0 }, cover = 1 } }),
    }

    assert.are.equal(1, Nes.summary(buf).edits)
    vim.b[buf].sidekick_nes = false
    assert.are.same({ edits = 0, hunks = 0 }, Nes.summary(buf))
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
    local original_nes_summary = Nes.summary
    local summary_calls = 0
    Nes.summary = function(...)
      summary_calls = summary_calls + 1
      return original_nes_summary(...)
    end
    UI.update_summary()
    Nes.summary = original_nes_summary
    local after = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, {})

    UI._hide(buf)
    Config.nes.diff.show = old_show
    Config.nes.signs = old_signs
    Config.nes.review.summary = old_summary
    assert.are.same(before, after)
    assert.are.equal(1, summary_calls)
  end)

  it("keeps the previous buffer sign after a cursor-only redraw", function()
    local UI = require("sidekick.nes.ui")
    local second = vim.api.nvim_create_buf(false, true)
    extra_bufs[#extra_bufs + 1] = second
    vim.api.nvim_buf_set_lines(second, 0, -1, false, { "other" })
    vim.lsp.util.buf_versions[second] = vim.lsp.util.buf_versions[second] or 0
    Config.nes.diff.show = "cursor"
    Config.nes.signs = false
    Config.nes.review.summary = false

    local function buffer_edit(target)
      return {
        buf = target,
        from = { 0, 0 },
        to = { 0, 0 },
        text = "updated",
        textDocument = { version = vim.lsp.util.buf_versions[target] },
        is_empty = function()
          return false
        end,
        diff = function()
          return {
            hunks = {
              { pos = { 0, 0 }, cover = 1, extmarks = {}, kind = "change" },
            },
          }
        end,
      }
    end
    Nes._edits = { buffer_edit(buf), buffer_edit(second) }

    vim.api.nvim_set_current_buf(buf)
    UI.update()
    vim.api.nvim_set_current_buf(second)
    UI.update_cursor()
    local marks = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, { details = true })
    local signs = vim.tbl_filter(function(mark)
      return mark[4].sign_text ~= nil
    end, marks)

    assert.are.equal(1, #marks)
    assert.are.equal(1, #signs)
  end)

  it("skips redrawing diff extmarks when cursor moves between non-edit lines", function()
    local UI = require("sidekick.nes.ui")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line0", "line1", "line2", "line3", "line4" })
    Config.nes.diff.show = "cursor"
    Config.nes.signs = true
    Config.nes.review.summary = false

    local test_edit = {
      buf = buf,
      from = { 0, 0 },
      to = { 0, 5 },
      text = "EDIT0",
      textDocument = { version = vim.lsp.util.buf_versions[buf] },
      is_empty = function()
        return false
      end,
      diff = function()
        return {
          hunks = {
            { pos = { 0, 0 }, cover = 1, extmarks = { { row = 0, col = 0, hl_group = "SidekickDiffAdd" } }, kind = "change" },
          },
        }
      end,
    }
    Nes._edits = { test_edit }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    UI.update_cursor()

    local extmarks_before = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, { details = true })
    assert.are.equal(1, #extmarks_before)

    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    UI.update_cursor()

    local extmarks_after = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, { details = true })
    assert.are.same(extmarks_before, extmarks_after)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    UI.update_cursor()
    local extmarks_in_edit = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, { details = true })
    assert.is_true(#extmarks_in_edit > #extmarks_before)
  end)

  it("supports table options for summary customization", function()
    local UI = require("sidekick.nes.ui")
    Config.nes.review.summary = { details = false, icon = true, current = true }
    local test_edit = {
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
    Nes._edits = { test_edit }
    UI.render(test_edit)

    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("sidekick.nes.summary"), 0, -1, { details = true })
    assert.are.equal(1, #marks)
    local vt = marks[1][4].virt_text
    assert.are.equal(2, #vt)
  end)

  it("only clears rendered and summary buffers on hide", function()
    local UI = require("sidekick.nes.ui")
    local untracked_buf = vim.api.nvim_create_buf(false, true)
    extra_bufs[#extra_bufs + 1] = untracked_buf
    vim.api.nvim_buf_set_lines(untracked_buf, 0, -1, false, { "untracked" })
    local extmark_id = vim.api.nvim_buf_set_extmark(untracked_buf, Config.ns, 0, 0, {
      virt_text = { { "custom", "Comment" } },
    })

    local test_edit = {
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
    Nes._edits = { test_edit }
    UI.render(test_edit)

    UI.hide()

    local remaining = vim.api.nvim_buf_get_extmarks(untracked_buf, Config.ns, 0, -1, {})
    assert.are.equal(1, #remaining)
    assert.are.equal(extmark_id, remaining[1][1])

    local tracked_remaining = vim.api.nvim_buf_get_extmarks(buf, Config.ns, 0, -1, {})
    assert.are.equal(0, #tracked_remaining)
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

  it("skips preview content writes when the edit snapshot is unchanged", function()
    assert.is_true(Preview.open())
    local windows = preview_windows()
    local left_buf = vim.api.nvim_win_get_buf(windows["[NES current]"])
    local right_buf = vim.api.nvim_win_get_buf(windows["[NES suggested]"])
    local left_tick = vim.api.nvim_buf_get_changedtick(left_buf)
    local right_tick = vim.api.nvim_buf_get_changedtick(right_buf)

    assert.is_true(Preview.refresh())
    assert.are.equal(left_tick, vim.api.nvim_buf_get_changedtick(left_buf))
    assert.are.equal(right_tick, vim.api.nvim_buf_get_changedtick(right_buf))
  end)

  it("does not rebuild preview windows on resize events", function()
    assert.is_true(Preview.open())
    local before = preview_windows()
    local left_buf = vim.api.nvim_win_get_buf(before["[NES current]"])
    local right_buf = vim.api.nvim_win_get_buf(before["[NES suggested]"])
    local left_tick = vim.api.nvim_buf_get_changedtick(left_buf)
    local right_tick = vim.api.nvim_buf_get_changedtick(right_buf)
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("VimResized", {})
    end
    local after = preview_windows()
    assert.are.equal(before["[NES current]"], after["[NES current]"])
    assert.are.equal(before["[NES suggested]"], after["[NES suggested]"])
    assert.are.equal(left_tick, vim.api.nvim_buf_get_changedtick(left_buf))
    assert.are.equal(right_tick, vim.api.nvim_buf_get_changedtick(right_buf))
  end)

  it("does not clear edits when a preview pane emits TextChanged", function()
    Nes.setup()
    assert.is_true(Preview.open())
    local before = preview_windows()
    local suggested_buf = vim.api.nvim_win_get_buf(before["[NES suggested]"])
    vim.api.nvim_set_current_win(before["[NES suggested]"])
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
    assert.is_true(Preview.refresh())
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = suggested_buf })
    vim.wait(150)

    assert.is_true(vim.api.nvim_win_is_valid(before["[NES suggested]"]))
    assert.are.equal(1, #Nes.get(buf))
  end)

  it("configures interactive review keymaps on preview buffers", function()
    assert.is_true(Preview.open())
    local windows = preview_windows()
    local suggested_buf = vim.api.nvim_win_get_buf(windows["[NES suggested]"])
    local keymaps = {}
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(suggested_buf, "n")) do
      keymaps[km.lhs] = km
    end

    assert.is_not_nil(keymaps["a"])
    assert.is_not_nil(keymaps["A"])
    assert.is_not_nil(keymaps["r"])
    assert.is_not_nil(keymaps["<Tab>"])
    assert.is_not_nil(keymaps["]c"])
    assert.is_not_nil(keymaps["[c"])
  end)

  it("applies all edits and closes preview when A keymap is invoked", function()
    assert.is_true(Preview.open())
    local windows = preview_windows()
    local suggested_buf = vim.api.nvim_win_get_buf(windows["[NES suggested]"])
    local keymap_A
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(suggested_buf, "n")) do
      if km.lhs == "A" then
        keymap_A = km
        break
      end
    end
    assert.is_not_nil(keymap_A)
    keymap_A.callback()
    vim.wait(100)

    assert.are.same({ "XYZdef", "second" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local after = preview_windows()
    assert.is_nil(after["[NES current]"])
    assert.is_nil(after["[NES suggested]"])
  end)

  it("accepts a hunk when invoked from the suggested pane even after line-shifting edits", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3", "line4" })
    Nes._edits = {
      setmetatable({
        buf = buf,
        from = { 0, 0 },
        to = { 3, 5 },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 3, character = 5 },
        },
        text = "line1\ninserted_a\ninserted_b\nline2\nline3\nmodified4",
        textDocument = { uri = "", version = 0 },
      }, Edit),
    }

    assert.is_true(Preview.open())
    local windows = preview_windows()
    local suggested_win = windows["[NES suggested]"]
    local suggested_buf = vim.api.nvim_win_get_buf(suggested_win)
    vim.api.nvim_set_current_win(suggested_win)

    local lines = vim.api.nvim_buf_get_lines(suggested_buf, 0, -1, false)
    local target_line
    for i, line in ipairs(lines) do
      if line == "modified4" then
        target_line = i
        break
      end
    end
    assert.is_not_nil(target_line)
    vim.api.nvim_win_set_cursor(suggested_win, { target_line, 0 })

    local keymap_a
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(suggested_buf, "n")) do
      if km.lhs == "a" then
        keymap_a = km
        break
      end
    end
    assert.is_not_nil(keymap_a)
    keymap_a.callback()
    vim.wait(100)

    local source_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal("modified4", source_lines[#source_lines])
  end)

  it("navigates between multiple inline hunks on the same line", function()
    local text_orig = "prefix text with aaa and then bbb in the middle of long line"
    local text_mod = "prefix text with AAA and then BBB in the middle of long line"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text_orig })
    Nes._edits = {
      setmetatable({
        buf = buf,
        from = { 0, 0 },
        to = { 0, #text_orig },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = #text_orig },
        },
        text = text_mod,
        textDocument = { uri = "", version = 0 },
      }, Edit),
    }

    assert.is_true(Preview.open())
    local windows = preview_windows()
    local suggested_win = windows["[NES suggested]"]
    local suggested_buf = vim.api.nvim_win_get_buf(suggested_win)
    vim.api.nvim_set_current_win(suggested_win)

    local keymaps = {}
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(suggested_buf, "n")) do
      keymaps[km.lhs] = km
    end

    vim.api.nvim_win_set_cursor(suggested_win, { 1, 0 })
    assert.is_not_nil(keymaps["]c"])
    keymaps["]c"].callback()

    local cur = vim.api.nvim_win_get_cursor(suggested_win)
    assert.are.equal(17, cur[2])

    -- Next jump moves to the second inline hunk
    keymaps["]c"].callback()
    cur = vim.api.nvim_win_get_cursor(suggested_win)
    assert.are.equal(30, cur[2])

    -- Prev jump moves back to the first inline hunk
    assert.is_not_nil(keymaps["[c"])
    keymaps["[c"].callback()
    cur = vim.api.nvim_win_get_cursor(suggested_win)
    assert.are.equal(17, cur[2])
  end)

  it("calculates proposed deltas correctly even when edits are returned in reverse order", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3", "line4" })
    local edit_earlier = setmetatable({
      buf = buf,
      from = { 0, 0 },
      to = { 1, 0 },
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 1, character = 0 },
      },
      text = "line1\ninserted_extra_1\ninserted_extra_2\n",
      textDocument = { uri = "", version = 0 },
    }, Edit)

    local edit_later = setmetatable({
      buf = buf,
      from = { 3, 0 },
      to = { 3, 5 },
      range = {
        start = { line = 3, character = 0 },
        ["end"] = { line = 3, character = 5 },
      },
      text = "new4",
      textDocument = { uri = "", version = 0 },
    }, Edit)

    Nes._edits = { edit_later, edit_earlier }

    assert.is_true(Preview.open())
    local windows = preview_windows()
    local suggested_win = windows["[NES suggested]"]
    local suggested_buf = vim.api.nvim_win_get_buf(suggested_win)
    vim.api.nvim_set_current_win(suggested_win)

    local lines = vim.api.nvim_buf_get_lines(suggested_buf, 0, -1, false)
    local target_line
    for i, line in ipairs(lines) do
      if line == "new4" then
        target_line = i
        break
      end
    end
    assert.is_not_nil(target_line)
    vim.api.nvim_win_set_cursor(suggested_win, { target_line, 0 })

    local keymap_a
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(suggested_buf, "n")) do
      if km.lhs == "a" then
        keymap_a = km
        break
      end
    end
    assert.is_not_nil(keymap_a)
    keymap_a.callback()
    vim.wait(100)

    local source_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal("new4", source_lines[#source_lines])
  end)
end)
