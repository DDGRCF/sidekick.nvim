---@module 'luassert'

local Changes = require("sidekick.cli.changes")
local Proposal = require("sidekick.cli.proposal")

local function git(cwd, args)
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert.are.equal(0, result.code, result.stderr)
end

local function repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  git(root, { "init" })
  vim.fn.writefile({ "before" }, root .. "/main.lua")
  git(root, { "add", "main.lua" })
  git(root, { "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial" })
  return root
end

describe("cli changes", function()
  it("builds text hunks for proposal changes", function()
    local item = {
      path = "main.lua",
      kind = "text",
      current = "one\ntwo\n",
      proposal = "one\nnew\n",
    }
    local diff = Changes._diff(item)
    assert.is_not_nil(diff)
    assert.are.equal(1, #diff.hunks)
    assert.are.equal("change", diff.hunks[1].kind)
  end)

  it("does not make a text diff for file-level changes", function()
    assert.is_nil(Changes._diff({ path = "image.png", kind = "file" }))
  end)

  it("annotates pending files with review status and line statistics", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "after", "added" }, proposal.cwd .. "/main.lua")
    vim.fn.writefile({ "new" }, proposal.cwd .. "/new.lua")

    local items = Changes._collect(proposal)
    assert.are.same(
      {
        {
          path = "main.lua",
          status = "M",
          stats = { added = 2, deleted = 1, hunks = 2 },
        },
        {
          path = "new.lua",
          status = "A",
          stats = { added = 1, deleted = 0, hunks = 1 },
        },
      },
      vim.tbl_map(function(item)
        return { path = item.path, status = item.status, stats = item.stats }
      end, items)
    )

    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)

  it("opens a dedicated tab with a read-only Current snapshot and editable Proposal buffer", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")
    local Panel = require("sidekick.cli.panel")
    local active = Panel.active
    local previous_tab = vim.api.nvim_get_current_tabpage()
    local columns = vim.o.columns
    vim.o.columns = 80
    Panel.active = function()
      return { proposal = proposal, title = "Test agent", tool = { name = "codex" } }
    end

    assert.is_true(Changes.open())
    local review_tab = vim.api.nvim_get_current_tabpage()
    assert.are_not.equal(previous_tab, review_tab)
    assert.is_true(Changes.open())
    assert.are.equal(review_tab, vim.api.nvim_get_current_tabpage())

    local wins = vim.api.nvim_tabpage_list_wins(review_tab)
    local buffers = vim.tbl_map(vim.api.nvim_win_get_buf, wins)
    assert.are.equal(3, #buffers)
    local current = vim.tbl_filter(function(buf)
      return vim.api.nvim_buf_get_name(buf):find("sidekick://changes/current/", 1, true) ~= nil
    end, buffers)[1]
    local pending = vim.tbl_filter(function(buf)
      return vim.api.nvim_buf_get_name(buf) == proposal.cwd .. "/main.lua"
    end, buffers)[1]
    local list = vim.tbl_filter(function(buf)
      return vim.api.nvim_buf_get_name(buf):find("sidekick://changes/list/", 1, true) ~= nil
    end, buffers)[1]
    assert.is_not_nil(current)
    assert.is_not_nil(pending)
    assert.is_not_nil(list)
    assert.are.equal("nofile", vim.bo[current].buftype)
    assert.is_false(vim.bo[current].modifiable)
    assert.are.equal("", vim.bo[pending].buftype)
    assert.is_true(vim.bo[pending].modifiable)
    local positions = {}
    for _, win in ipairs(wins) do
      positions[vim.api.nvim_win_get_buf(win)] = vim.api.nvim_win_get_position(win)
    end
    assert.is_true(positions[list][1] < positions[current][1])
    assert.are.equal(positions[current][1], positions[pending][1])

    assert.is_true(Changes.close())
    vim.o.columns = columns
    Panel.active = active
    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)

  it("uses a three-column layout in wide editors", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")
    local Panel = require("sidekick.cli.panel")
    local active = Panel.active
    local columns = vim.o.columns
    vim.o.columns = 140
    Panel.active = function()
      return { proposal = proposal, title = "Test agent", tool = { name = "codex" } }
    end

    assert.is_true(Changes.open())
    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    local positions = {}
    for _, win in ipairs(wins) do
      positions[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))] = vim.api.nvim_win_get_position(win)
    end
    local list = vim.tbl_filter(function(name)
      return name:find("sidekick://changes/list/", 1, true) ~= nil
    end, vim.tbl_keys(positions))[1]
    local current = vim.tbl_filter(function(name)
      return name:find("sidekick://changes/current/", 1, true) ~= nil
    end, vim.tbl_keys(positions))[1]
    local pending = proposal.cwd .. "/main.lua"
    assert.are.equal(positions[list][1], positions[current][1])
    assert.are.equal(positions[current][1], positions[pending][1])
    assert.is_true(positions[list][2] < positions[current][2])
    assert.is_true(positions[current][2] < positions[pending][2])

    assert.is_true(Changes.close())
    vim.o.columns = columns
    Panel.active = active
    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)

  it("requires saving Proposal edits before dp accepts the hunk", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")
    local Panel = require("sidekick.cli.panel")
    local active = Panel.active
    Panel.active = function()
      return { proposal = proposal, title = "Test agent", tool = { name = "codex" } }
    end

    assert.is_true(Changes.open())
    local proposal_win = vim.api.nvim_get_current_win()
    local proposal_buf = vim.api.nvim_win_get_buf(proposal_win)
    vim.api.nvim_buf_set_lines(proposal_buf, 0, -1, false, { "reviewer edit" })
    assert.is_false(Changes.refresh(true))
    assert.are.same({ "reviewer edit" }, vim.api.nvim_buf_get_lines(proposal_buf, 0, -1, false))
    assert.is_nil(Changes.accept_at_cursor())
    assert.are.equal("before", vim.fn.readfile(root .. "/main.lua")[1])

    vim.cmd("write")
    vim.api.nvim_win_set_cursor(proposal_win, { 1, 0 })
    assert.is_true(Changes.accept_at_cursor())
    assert.are.equal("reviewer edit", vim.fn.readfile(root .. "/main.lua")[1])

    assert.is_true(Changes.close())
    Panel.active = active
    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)

  it("sends a selected hunk and feedback to the original agent without opening its panel", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")
    local Panel = require("sidekick.cli.panel")
    local active = Panel.active
    local input = vim.ui.input
    local sent = {}
    local terminal = {
      proposal = proposal,
      title = "Test agent",
      tool = { name = "codex" },
      is_running = function()
        return true
      end,
      send = function(_, message, opts)
        sent[#sent + 1] = { message = message, opts = opts }
      end,
      submit = function(_, opts)
        sent[#sent + 1] = { submit = true, opts = opts }
      end,
    }
    Panel.active = function()
      return terminal
    end
    vim.ui.input = function(_, callback)
      callback("Use the original behavior instead")
    end

    assert.is_true(Changes.open())
    Changes.request()
    assert.are.equal(2, #sent)
    assert.matches("File: main.lua", sent[1].message)
    assert.matches("Use the original behavior instead", sent[1].message)
    assert.are.same({ show = false }, sent[1].opts)
    assert.is_true(sent[2].submit)
    assert.are.same({ show = false }, sent[2].opts)

    vim.ui.input = input
    assert.is_true(Changes.close())
    Panel.active = active
    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)

  it("accepts and rejects proposal hunks without touching the other side", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")

    local changed = Changes._collect(proposal)[1]
    assert.is_true(Changes.apply(proposal, changed, "accept", changed.diff.hunks[1]))
    assert.are.equal("agent", vim.fn.readfile(root .. "/main.lua")[1])

    vim.fn.writefile({ "other" }, proposal.cwd .. "/main.lua")
    changed = Changes._collect(proposal)[1]
    assert.is_true(Changes.apply(proposal, changed, "reject", changed.diff.hunks[1]))
    assert.are.equal("agent", vim.fn.readfile(proposal.cwd .. "/main.lua")[1])

    Proposal.discard(proposal)
    vim.fn.delete(root, "rf")
  end)
end)
