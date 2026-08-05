---@module 'luassert'

local Git = require("sidekick.cli.agent_git")

describe("cli agent git metadata", function()
  it("parses branches and changed paths", function()
    local result = Git.parse("## feature.api...origin/feature.api\0 M lua/a.lua\0?? tests/new.lua\0")
    assert.are.equal("feature.api", result.branch)
    assert.are.same({ "lua/a.lua", "tests/new.lua" }, result.changed_files)
  end)

  it("keeps both paths for renames", function()
    local result = Git.parse("## main\0R  old.lua\0new.lua\0")
    assert.are.same({ "old.lua", "new.lua" }, result.changed_files)
  end)

  it("starts metadata collection without waiting on the UI thread", function()
    local old_system = vim.system
    local callback
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    vim.system = function(_, _, cb)
      callback = cb
      return {
        wait = function()
          error("collect must not wait")
        end,
      }
    end

    local result = Git.collect({ cwd }, function() end)

    vim.system = old_system
    assert.are.same({}, result)
    assert.is_function(callback)
    vim.fn.delete(cwd, "rf")
  end)
end)
