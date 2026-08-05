---@module 'luassert'

local Provider = require("sidekick.cli.provider_sessions")

describe("cli provider sessions", function()
  it("captures and verifies an open Codex session file by process identity", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local path = root .. "/rollout-conversation.jsonl"
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({ type = "session_meta", payload = { id = "conversation-42" } }) .. "\n")
    file:flush()
    local old_root = Provider.roots.codex
    Provider.roots.codex = vim.fs.normalize(root)

    local conversation = Provider.capture("codex", { pids = { vim.fn.getpid() } })

    assert.are.equal("conversation-42", conversation.id)
    assert.are.equal("codex", conversation.provider)
    assert.is_true(Provider.verify("codex", conversation))
    file:close()
    Provider.roots.codex = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures and verifies an open Antigravity conversation database", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "b98bb537-9e1f-4780-8fb4-2f4f0a3b9712"
    local path = root .. "/" .. id .. ".db"
    local file = assert(io.open(path, "wb"))
    file:write("not a database")
    file:flush()
    local old_root = Provider.roots.antigravity
    Provider.roots.antigravity = vim.fs.normalize(root)

    local invalid = {
      id = id,
      provider = "antigravity",
      resumable = true,
      data = { path = path },
    }
    assert.is_false(Provider.verify("antigravity", invalid))

    file:seek("set", 0)
    file:write("SQLite format 3\0", string.rep("\0", 84), "CREATE TABLE trajectory_meta")
    file:flush()
    local conversation = Provider.capture("antigravity", { pids = { vim.fn.getpid() } })

    assert.are.equal(id, conversation.id)
    assert.are.equal("antigravity", conversation.provider)
    assert.is_true(Provider.verify("antigravity", conversation))

    file:close()
    Provider.roots.antigravity = old_root
    vim.fn.delete(root, "rf")
  end)
end)
