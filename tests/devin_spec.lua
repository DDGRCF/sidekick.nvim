---@module 'luassert'

local Util = require("sidekick.util")

describe("cli devin provider", function()
  local old_exec

  before_each(function()
    old_exec = Util.exec
    Util.exec = function(cmd)
      assert.are.same({ "devin", "list", "--format", "json" }, cmd)
      return {},
        vim.json.encode({
          { id = "older", last_activity_at = 1, working_directory = "/tmp" },
          { id = "newer-session", last_activity_at = 5, working_directory = "/tmp" },
          { id = "hidden-one", last_activity_at = 99, hidden = true, working_directory = "/tmp" },
        })
    end
  end)

  after_each(function()
    Util.exec = old_exec
  end)

  it("captures the latest visible session for the working directory", function()
    local config = assert(loadfile("sk/cli/devin.lua"))()
    local conversation = config.resume.capture({}, { cwd = "/tmp" })
    assert.are.equal("devin", conversation.provider)
    assert.are.equal("newer-session", conversation.id)
    assert.is_true(conversation.resumable)
  end)

  it("ignores sessions from other working directories", function()
    Util.exec = function()
      return {},
        vim.json.encode({
          { id = "other-project", last_activity_at = 50, working_directory = "/elsewhere" },
        })
    end
    local config = assert(loadfile("sk/cli/devin.lua"))()
    assert.is_nil(config.resume.capture({}, { cwd = "/tmp" }))
  end)

  it("builds an exact resume command", function()
    local config = assert(loadfile("sk/cli/devin.lua"))()
    local cmd = require("sidekick.cli.resume").command(
      { name = "devin", cmd = config.cmd, config = config },
      { conversation = { id = "newer-session", provider = "devin", resumable = true } }
    )
    assert.are.same({ "devin", "--resume", "newer-session" }, cmd)
  end)

  it("never shells out for a cached capture", function()
    local calls = 0
    Util.exec = function()
      calls = calls + 1
      return {}, vim.json.encode({ { id = "cached", last_activity_at = 1, working_directory = "/tmp" } })
    end
    local config = assert(loadfile("sk/cli/devin.lua"))()
    assert.is_nil(config.resume.capture_cached({}, { cwd = "/tmp" }))
    assert.are.equal(0, calls)

    assert.are.equal("cached", config.resume.capture({}, { cwd = "/tmp" }).id)
    assert.are.equal(1, calls)

    -- Cached now: repeated captures and snapshots must not touch the CLI again.
    assert.are.equal("cached", config.resume.capture({}, { cwd = "/tmp" }).id)
    assert.are.equal("cached", config.resume.capture_cached({}, { cwd = "/tmp" }).id)
    assert.are.equal(1, calls)
  end)

  it("verifies from cache only, reporting unknown instead of blocking", function()
    local shells = 0
    Util.exec = function()
      shells = shells + 1
      return {}, "[]"
    end
    local spawned = 0
    local old_system = vim.system
    vim.system = function()
      spawned = spawned + 1
      return { pid = 1 }
    end
    local config = assert(loadfile("sk/cli/devin.lua"))()
    local tool = { name = "devin", cmd = { "devin" }, config = config }
    local conversation = { id = "cold", provider = "devin", resumable = true }
    local saved = { conversation = conversation, cwd = "/tmp" }

    -- A cold cache cannot answer, so it says so and warms itself in the
    -- background instead of freezing the editor on `devin list`.
    assert.is_nil(config.resume.verify(tool, { cwd = "/tmp" }, conversation, saved))
    assert.is_true(config.resume.preflight(tool, conversation, saved))
    assert.are.equal(0, shells)
    assert.are.equal(1, spawned)
    vim.system = old_system
  end)

  it("blocks only against a fresh list that already disagrees", function()
    local config = assert(loadfile("sk/cli/devin.lua"))()
    local tool = { name = "devin", cmd = { "devin" }, config = config }
    -- Warm the cache through the blocking, user-initiated capture path.
    assert.are.equal("newer-session", config.resume.capture({}, { cwd = "/tmp" }).id)
    local saved = { conversation = { id = "newer-session", provider = "devin" }, cwd = "/tmp" }
    assert.is_true(config.resume.verify(tool, { cwd = "/tmp" }, saved.conversation, saved))
    saved.conversation = { id = "gone", provider = "devin" }
    assert.is_false(config.resume.verify(tool, { cwd = "/tmp" }, saved.conversation, saved))
  end)

  it("captures asynchronously without blocking", function()
    local old_system = vim.system
    vim.system = function(_, _, on_exit)
      vim.schedule(function()
        on_exit({ code = 0, stdout = vim.json.encode({ { id = "async-id", last_activity_at = 3 } }) })
      end)
      return { pid = 1 }
    end
    local config = assert(loadfile("sk/cli/devin.lua"))()
    local captured
    local handled = config.resume.capture_async({}, { cwd = "/tmp" }, function(conversation)
      captured = conversation
    end)
    assert.is_nil(handled)
    vim.wait(500, function()
      return captured ~= nil
    end)
    vim.system = old_system
    assert.are.equal("async-id", captured and captured.id)
    assert.are.equal("devin", captured and captured.provider)
  end)
end)
