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

  it("opens the changes review with responsive layout", function()
    local root = repo()
    local proposal = assert(Proposal.create(root, "changes-" .. vim.fn.sha256(root):sub(1, 8)))
    vim.fn.writefile({ "agent" }, proposal.cwd .. "/main.lua")
    local Panel = require("sidekick.cli.panel")
    local active = Panel.active
    Panel.active = function()
      return { proposal = proposal, title = "Test agent", tool = { name = "codex" } }
    end

    assert.is_true(Changes.open())
    assert.is_false(Changes.open())

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
