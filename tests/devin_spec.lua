---@module 'luassert'

local Util = require("sidekick.util")

describe("cli devin provider", function()
  local old_exec

  before_each(function()
    old_exec = Util.exec
    Util.exec = function(cmd)
      assert.are.same({ "devin", "list", "--format", "json" }, cmd)
      return {}, vim.json.encode({
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
      return {}, vim.json.encode({
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
end)
