---@module 'luassert'

local Proposal = require("sidekick.cli.proposal")

local function git(cwd, args)
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert.are.equal(0, result.code, result.stderr)
  return result.stdout or ""
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

describe("cli proposals", function()
  local root
  local proposal

  after_each(function()
    if proposal then
      Proposal.discard(proposal)
      proposal = nil
    end
    if root then
      vim.fn.delete(root, "rf")
      root = nil
    end
  end)

  it("seeds saved changes into a clean isolated worktree", function()
    root = repo()
    vim.fn.writefile({ "user change" }, root .. "/main.lua")
    vim.fn.writefile({ "new file" }, root .. "/new.lua")

    proposal = assert(Proposal.create(root, "proposal-" .. vim.fn.sha256(root):sub(1, 8)))

    assert.are_not.equal(root, proposal.cwd)
    assert.are.equal("user change", vim.fn.readfile(proposal.cwd .. "/main.lua")[1])
    assert.are.equal("new file", vim.fn.readfile(proposal.cwd .. "/new.lua")[1])
    assert.are.equal("", git(proposal.cwd, { "status", "--porcelain" }))
    assert.is_not_nil(Proposal.get(proposal.id))
  end)

  it("rejects non-Git directories", function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local result, err = Proposal.create(root, "proposal-" .. vim.fn.sha256(root):sub(1, 8))
    assert.is_nil(result)
    assert.is_true(err:find("requires a Git", 1, true) ~= nil)
  end)
end)
