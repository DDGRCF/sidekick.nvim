---@module 'luassert'

local Resume = require("sidekick.cli.resume")

describe("cli conversation resume", function()
  local function tool(config)
    return {
      name = "agent",
      cmd = { "agent", "--ui" },
      config = config,
    }
  end

  it("resumes an exact native conversation id", function()
    local cmd, mode = Resume.command(tool({ resume = { "resume" } }), {
      conversation = { id = "conversation-42", provider = "agent", resumable = true },
    })

    assert.are.same({ "agent", "--ui", "resume", "conversation-42" }, cmd)
    assert.are.equal("exact", mode)
  end)

  it("never substitutes the latest conversation for a missing id", function()
    local t = tool({ resume = { "resume" }, continue = { "resume", "--last" } })
    local cmd, mode = Resume.command(t, {})

    assert.is_nil(cmd)
    assert.are.equal("unsupported", mode)
  end)

  it("rejects option-like conversation ids", function()
    local cmd, mode = Resume.command(tool({ resume = { "resume" } }), {
      conversation = { id = "--last", provider = "agent", resumable = true },
    })

    assert.is_nil(cmd)
    assert.are.equal("unsupported", mode)
  end)

  it("never treats an interactive session browser as an exact restore", function()
    local cmd, mode = Resume.command(tool({ resume = { "--resume" } }), {})

    assert.is_nil(cmd)
    assert.are.equal("unsupported", mode)
  end)

  it("reports unsupported tools instead of starting a fresh chat", function()
    local cmd, mode = Resume.command(tool({}), {})

    assert.is_nil(cmd)
    assert.are.equal("unsupported", mode)
  end)

  it("supports provider-owned command adapters", function()
    local cmd, mode = Resume.command(
      tool({
        resume = {
          command = function(_, conversation, saved)
            return { "custom", conversation.id, saved.cwd }
          end,
        },
      }),
      {
        conversation = { id = "abc", provider = "agent", resumable = true },
        cwd = "/tmp/project",
      }
    )

    assert.are.same({ "custom", "abc", "/tmp/project" }, cmd)
    assert.are.equal("exact", mode)
  end)

  it("uses exact native ids for Grok and OpenCode", function()
    for _, case in ipairs({
      { name = "grok", id = "a1b2c3d4e5f6", file = "sk/cli/grok.lua" },
      { name = "opencode", id = "ses_1234567890abcdefghijklmnop", file = "sk/cli/opencode.lua" },
    }) do
      local config = assert(loadfile(case.file))()
      local cmd, mode = Resume.command({ name = case.name, cmd = config.cmd, config = config }, {
        conversation = { id = case.id, provider = case.name, resumable = true },
      })

      local expected = vim.deepcopy(config.cmd)
      vim.list_extend(expected, { "--session", case.id })
      assert.are.same(expected, cmd)
      assert.are.equal("exact", mode)
    end
  end)

  it("rejects mismatched and explicitly non-resumable conversations", function()
    local t = tool({ resume = { "resume" } })
    assert.is_nil(Resume.command(t, {
      conversation = { id = "abc", provider = "other", resumable = true },
    }))
    assert.is_nil(Resume.command(t, {
      conversation = { id = "abc", provider = "agent", resumable = false },
    }))
  end)

  it("refreshes cached metadata from the currently running conversation", function()
    local Session = require("sidekick.cli.session")
    local old_set = Session.set_conversation
    Session.set_conversation = function(_, conversation)
      return conversation
    end
    local current = Resume.capture({
      tool = tool({
        resume = {
          capture = function()
            return { id = "new", provider = "agent", resumable = true }
          end,
        },
      }),
      conversation = { id = "old", provider = "agent", resumable = true },
      pids = {},
    })
    Session.set_conversation = old_set

    assert.are.equal("new", current.id)
  end)
end)
