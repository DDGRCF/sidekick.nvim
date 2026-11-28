---@module 'luassert'

local Config = require("sidekick.config")
local Diff = require("sidekick.nes.diff")
local Edit = require("sidekick.nes.edit")
local TS = require("sidekick.treesitter")

local function stub_ts()
  local original = {
    get_virtual_lines = TS.get_virtual_lines,
    highlight_block = TS.highlight_block,
  }
  local calls = { highlight_ws = {} }

  TS.get_virtual_lines = function(lines, opts)
    lines = type(lines) == "string" and vim.split(lines, "\n", { plain = true }) or lines
    local ret = {}
    for i, line in ipairs(lines) do
      ret[i] = { { line, opts and opts.bg } }
    end
    return ret
  end

  TS.highlight_block = function(virtual_lines, opts)
    table.insert(calls.highlight_ws, {
      lines = vim.deepcopy(virtual_lines),
      opts = opts,
    })
    return virtual_lines
  end

  return function()
    TS.get_virtual_lines = original.get_virtual_lines
    TS.highlight_block = original.highlight_block
  end,
    calls
end

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "lua"
  return buf
end

local function make_edit(buf, from_line, from_col, to_line, to_col, text)
  return {
    buf = buf,
    from = { from_line, from_col },
    to = { to_line, to_col },
    text = text,
    range = {
      start = { line = from_line, character = from_col },
      ["end"] = { line = to_line, character = to_col },
    },
    textDocument = { uri = ("test://%d"):format(buf), version = 0 },
  }
end

describe("diff", function()
  local inline_default

  before_each(function()
    inline_default = Config.nes.diff.inline
  end)

  after_each(function()
    Config.nes.diff.inline = inline_default
  end)

  ---@type {name:string, lines?:string[], inline?:"words"|"chars"|false, edit:{from:{integer,integer}, to:{integer,integer}, text:string}, check:fun(diff:sidekick.Diff, calls:{highlight_ws:table[]})}[]
  local cases = {
    {
      name = "inline word change",
      inline = "words",
      edit = {
        from = { 0, 6 },
        to = { 0, 9 },
        text = "food",
      },
      check = function(diff, calls)
        local hunk = diff.hunks[1]
        assert.are.same(true, hunk.inline)
        assert.are.same("change", hunk.kind)
        assert.are.same({ 0, 6 }, hunk.pos)
        assert.are.same(2, #hunk.extmarks)
        assert.are.same({
          row = 0,
          col = 6,
          end_col = 9,
          hl_group = "SidekickDiffDelete",
        }, hunk.extmarks[1])
        assert.are.same({
          row = 0,
          col = 9,
          virt_text = { { "food", "SidekickDiffAdd" } },
          virt_text_pos = "inline",
        }, hunk.extmarks[2])
        assert.are.same(0, #calls.highlight_ws)
      end,
    },
    {
      name = "inline disabled forces block diff",
      inline = false,
      edit = {
        from = { 0, 6 },
        to = { 0, 9 },
        text = "food",
      },
      check = function(diff, calls)
        local hunk = diff.hunks[1]
        assert.is_true(hunk.inline == nil)
        assert.are.same("change", hunk.kind)
        assert.are.same({ 0, 0 }, hunk.pos)
        assert.are.same(2, #hunk.extmarks)
        assert.are.same("SidekickDiffDelete", hunk.extmarks[1].line_hl_group)
        assert.are.same(1, #calls.highlight_ws)
      end,
    },
    {
      name = "insert ratio falls back to block diff",
      inline = "words",
      edit = {
        from = { 0, 11 },
        to = { 0, 12 },
        text = "12345678901234567890",
      },
      check = function(diff, calls)
        local hunk = diff.hunks[1]
        assert.is_nil(hunk.inline)
        assert.are.same("change", hunk.kind)
        assert.are.same({ 0, 0 }, hunk.pos)
        assert.are.same(2, #hunk.extmarks)
        assert.is_true(hunk.extmarks[2].hl_eol)
        assert.are.same({
          leading = "SidekickDiffContext",
          trailing = "SidekickDiffContext",
          block = "SidekickDiffAdd",
          width = 33,
        }, calls.highlight_ws[1].opts)
      end,
    },
    {
      name = "newline insertion mixes inline and block hunks",
      inline = "words",
      edit = {
        from = { 0, 11 },
        to = { 0, 12 },
        text = "1\n2",
      },
      check = function(diff, calls)
        assert.are.same(2, #diff.hunks)

        local delete = diff.hunks[1]
        assert.are.same(true, delete.inline)
        assert.are.same("delete", delete.kind)
        assert.are.same({ 0, 11 }, delete.pos)
        assert.are.same(1, #delete.extmarks)
        assert.are.same({
          row = 0,
          col = 11,
          end_col = 12,
          hl_group = "SidekickDiffDelete",
        }, delete.extmarks[1])

        local add = diff.hunks[2]
        assert.is_nil(add.inline)
        assert.are.same("add", add.kind)
        assert.are.same({ 0, 0 }, add.pos)
        assert.are.same(1, #add.extmarks)
        assert.is_true(add.extmarks[1].hl_eol)
        assert.are.same(1, #calls.highlight_ws)
        assert.are.same({ {
          { "21", "SidekickDiffAdd" },
        } }, calls.highlight_ws[1].lines)
      end,
    },
    {
      name = "char inline mode adds single token",
      inline = "chars",
      edit = {
        from = { 0, 6 },
        to = { 0, 9 },
        text = "food",
      },
      check = function(diff)
        local hunk = diff.hunks[1]
        assert.are.same(true, hunk.inline)
        assert.are.same("add", hunk.kind)
        assert.are.same({ 0, 8 }, hunk.pos)
        assert.are.same({
          row = 0,
          col = 9,
          virt_text = { { "d", "SidekickDiffAdd" } },
          virt_text_pos = "inline",
        }, hunk.extmarks[1])
      end,
    },
    {
      name = "insertion before first column uses inline add",
      inline = "words",
      edit = {
        from = { 0, 0 },
        to = { 0, 0 },
        text = "-- ",
      },
      check = function(diff)
        local hunk = diff.hunks[1]
        assert.are.same(true, hunk.inline)
        assert.are.same("add", hunk.kind)
        assert.are.same({ 0, 0 }, hunk.pos)
        assert.are.same(1, #hunk.extmarks)
        assert.are.same({
          row = 0,
          col = 0,
          virt_text = {
            { "-", "SidekickDiffAdd" },
            { "-", "SidekickDiffAdd" },
            { " ", "SidekickDiffAdd" },
          },
          virt_text_pos = "inline",
        }, hunk.extmarks[1])
      end,
    },
    {
      name = "insertion after last column produces inline add",
      inline = "words",
      edit = {
        from = { 0, #"local foo = 1" },
        to = { 0, #"local foo = 1" },
        text = " bar",
      },
      check = function(diff)
        local hunk = diff.hunks[1]
        assert.are.same(true, hunk.inline)
        assert.are.same("add", hunk.kind)
        assert.are.same({ 0, 12 }, hunk.pos)
        assert.are.same(1, #hunk.extmarks)
        assert.are.same({
          row = 0,
          col = 13,
          virt_text = {
            { " ", "SidekickDiffAdd" },
            { "bar", "SidekickDiffAdd" },
          },
          virt_text_pos = "inline",
        }, hunk.extmarks[1])
      end,
    },
    {
      name = "appending after last line produces block add",
      inline = "words",
      lines = { "test1", "test2" },
      edit = {
        from = { 2, 0 },
        to = { 2, 0 },
        text = "bar",
      },
      check = function(diff)
        assert.are.same(1, #diff.hunks)
        local hunk = diff.hunks[1]
        assert.is_nil(hunk.inline)
        assert.are.same("add", hunk.kind)
        assert.are.same({ 1, 0 }, hunk.pos)
        assert.are.same(1, #hunk.extmarks)
        assert.is_true(hunk.extmarks[1].hl_eol)
        assert.are.same({ {
          { "bar", "SidekickDiffAdd" },
        } }, hunk.extmarks[1].virt_lines)
      end,
    },
    {
      name = "addition targeting distant line is accepted",
      inline = "words",
      edit = {
        from = { 5, 0 },
        to = { 5, 0 },
        text = "foo",
      },
      check = function(diff, calls)
        assert.are.same(1, #diff.hunks)
        local hunk = diff.hunks[1]
        assert.is_nil(hunk.inline)
        assert.are.same("add", hunk.kind)
        assert.are.same({ 4, 0 }, hunk.pos)
        assert.are.same(1, #hunk.extmarks)
        assert.is_true(hunk.extmarks[1].hl_eol)
        assert.are.same({ {
          { "foo", "SidekickDiffAdd" },
        } }, calls.highlight_ws[1].lines)
      end,
    },
    {
      name = "deletion referring to distant range yields no hunks",
      inline = "words",
      edit = {
        from = { 5, 0 },
        to = { 5, 3 },
        text = "",
      },
      check = function(diff)
        assert.are.same(0, #diff.hunks)
      end,
    },
  }

  for _, case in ipairs(cases) do
    it(case.name, function()
      local restore, calls = stub_ts()
      local buf = make_buf(case.lines or { "local foo = 1" })
      Config.nes.diff.inline = case.inline
      local edit =
        make_edit(buf, case.edit.from[1], case.edit.from[2], case.edit.to[1], case.edit.to[2], case.edit.text)
      local ok, diff = pcall(Diff.diff, edit)
      vim.api.nvim_buf_delete(buf, { force = true })
      restore()
      assert(ok, diff)
      diff = diff ---@type sidekick.Diff
      case.check(diff, calls)
    end)
  end

  it("reuses an edit diff until the buffer changes", function()
    local restore = stub_ts()
    local buf = make_buf({ "local foo = 1" })
    local edit = setmetatable(make_edit(buf, 0, 6, 0, 9, "food"), Edit)
    local original_diff = Diff.diff
    local calls = 0
    Diff.diff = function(value)
      calls = calls + 1
      return original_diff(value)
    end

    edit:diff()
    edit:diff()
    assert.are.equal(1, calls)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local bar = 1" })
    edit:diff()
    assert.are.equal(2, calls)

    Diff.diff = original_diff
    restore()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("diff hunk actions", function()
  it("accepts a block hunk while keeping the other proposal hunks", function()
    local diff = {
      from = { lines = { "one", "two", "three" } },
      to = { lines = { "one", "TWO", "three", "four" } },
    }
    local current, pending = Diff.apply_hunk(diff, {
      kind = "change",
      pos = { 1, 0 },
      cover = 1,
      from_index = 2,
      from_count = 1,
      to_index = 2,
      to_count = 1,
      extmarks = {},
    }, "accept")

    assert.are.same({ "one", "TWO", "three" }, current)
    assert.are.same({ "one", "TWO", "three", "four" }, pending)
  end)

  it("rejects an inline hunk without discarding another inline change", function()
    local diff = {
      from = { lines = { "one two three" } },
      to = { lines = { "one TWO THREE" } },
    }
    local current, pending = Diff.apply_hunk(diff, {
      kind = "change",
      pos = { 0, 4 },
      cover = 1,
      inline = true,
      from_index = 1,
      to_index = 1,
      from_col = 4,
      from_end_col = 7,
      to_col = 4,
      to_end_col = 7,
      extmarks = {},
    }, "reject")

    assert.are.same({ "one two three" }, current)
    assert.are.same({ "one two THREE" }, pending)
  end)
end)

describe("diff hunk mutations", function()
  it("describes byte-exact mutations for inline hunks", function()
    local diff = {
      range = { from = { 0, 0 }, to = { 0, 0 } },
      from = { lines = { "one two three" } },
      to = { lines = { "one TWO three" } },
    }
    local mutation = Diff.hunk_mutation(diff --[[@as sidekick.Diff]], {
      kind = "change",
      pos = { 0, 4 },
      cover = 1,
      inline = true,
      from_index = 1,
      to_index = 1,
      from_col = 4,
      from_end_col = 7,
      to_col = 4,
      to_end_col = 7,
      extmarks = {},
    })
    assert.are.same({
      kind = "bytes",
      row = 0,
      count = 0,
      new_count = 0,
      from_col = 4,
      end_col = 7,
      replacement = "TWO",
    }, mutation)
  end)

  it("trims single-line block mutations to the changed bytes", function()
    local diff = {
      range = { from = { 0, 0 }, to = { 0, 0 } },
      from = { lines = { "cccc dddd" } },
      to = { lines = { "CCCC dddd" } },
    }
    local mutation = Diff.hunk_mutation(diff --[[@as sidekick.Diff]], {
      kind = "change",
      pos = { 0, 0 },
      cover = 1,
      from_index = 1,
      from_count = 1,
      to_index = 1,
      to_count = 1,
      extmarks = {},
    })
    assert.are.same({
      kind = "bytes",
      row = 0,
      count = 0,
      new_count = 0,
      from_col = 0,
      end_col = 4,
      replacement = "CCCC",
    }, mutation)
  end)

  it("describes line mutations for insertions and deletions", function()
    local diff = {
      range = { from = { 3, 0 }, to = { 3, 0 } },
      from = { lines = { "a", "b" } },
      to = { lines = { "a", "x", "y", "b" } },
    }
    -- insertion after diff line 1 (buffer row 3): rows insert before row 4
    local insert = Diff.hunk_mutation(diff --[[@as sidekick.Diff]], {
      kind = "add",
      pos = { 3, 0 },
      cover = 0,
      from_index = 1,
      from_count = 0,
      to_index = 2,
      to_count = 2,
      extmarks = {},
    })
    assert.are.same({ kind = "lines", row = 4, count = 0, new_count = 2 }, insert)

    local delete = Diff.hunk_mutation(diff --[[@as sidekick.Diff]], {
      kind = "delete",
      pos = { 3, 0 },
      cover = 2,
      from_index = 1,
      from_count = 2,
      to_index = 1,
      to_count = 0,
      extmarks = {},
    })
    assert.are.same({ kind = "lines", row = 3, count = 2, new_count = 0 }, delete)
  end)

  it("places insertions before the first line at the first row", function()
    local diff = {
      range = { from = { 2, 0 }, to = { 2, 0 } },
      from = { lines = { "a" } },
      to = { lines = { "x", "a" } },
    }
    local mutation = Diff.hunk_mutation(diff --[[@as sidekick.Diff]], {
      kind = "add",
      pos = { 2, 0 },
      cover = 0,
      from_index = 0,
      from_count = 0,
      to_index = 1,
      to_count = 1,
      extmarks = {},
    })
    assert.are.same({ kind = "lines", row = 2, count = 0, new_count = 1 }, mutation)
  end)

  describe("transform_pos", function()
    local bytes = {
      kind = "bytes",
      row = 2,
      count = 0,
      new_count = 0,
      from_col = 4,
      end_col = 7,
      replacement = "LONGER",
    } ---@type sidekick.diff.Mutation

    ---@type {name:string, pos:{integer,integer}, expected?:{integer,integer}}[]
    local bytes_cases = {
      { name = "other rows are untouched", pos = { 1, 6 }, expected = { 1, 6 } },
      { name = "columns before the mutation are untouched", pos = { 2, 2 }, expected = { 2, 2 } },
      { name = "the start boundary of a replacement stays", pos = { 2, 4 }, expected = { 2, 4 } },
      { name = "positions inside the mutation are lost", pos = { 2, 5 } },
      { name = "positions at the end boundary shift", pos = { 2, 7 }, expected = { 2, 10 } },
      { name = "positions after the mutation shift by the delta", pos = { 2, 9 }, expected = { 2, 12 } },
    }
    for _, case in ipairs(bytes_cases) do
      it(case.name, function()
        assert.are.same(case.expected, Diff.transform_pos(case.pos, bytes))
      end)
    end

    it("pushes positions at a pure insertion point past the inserted bytes", function()
      local insertion = {
        kind = "bytes",
        row = 0,
        count = 0,
        new_count = 0,
        from_col = 3,
        end_col = 3,
        replacement = "abc",
      } ---@type sidekick.diff.Mutation
      assert.are.same({ 0, 6 }, Diff.transform_pos({ 0, 3 }, insertion))
      assert.are.same({ 0, 2 }, Diff.transform_pos({ 0, 2 }, insertion))
    end)

    it("shifts rows after line mutations and drops rows inside", function()
      local lines = { kind = "lines", row = 2, count = 2, new_count = 5 } ---@type sidekick.diff.Mutation
      assert.are.same({ 0, 3 }, Diff.transform_pos({ 0, 3 }, lines))
      assert.is_nil(Diff.transform_pos({ 2, 0 }, lines))
      assert.is_nil(Diff.transform_pos({ 3, 7 }, lines))
      assert.are.same({ 7, 4 }, Diff.transform_pos({ 4, 4 }, lines))
    end)

    it("shifts rows below pure line insertions without losing positions", function()
      local insert = { kind = "lines", row = 2, count = 0, new_count = 2 } ---@type sidekick.diff.Mutation
      assert.are.same({ 1, 0 }, Diff.transform_pos({ 1, 0 }, insert))
      assert.are.same({ 4, 5 }, Diff.transform_pos({ 2, 5 }, insert))
    end)
  end)
end)
