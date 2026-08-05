---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local Prompt = require("sidekick.cli.ui.prompt")
local Select = require("sidekick.cli.ui.select")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")

describe("cli routing", function()
  it("preserves the selected prompt text for the first agent title", function()
    local original_select = Prompt.select
    local original_send = Cli.send
    local sent
    Prompt.select = function(opts)
      opts.cb("Review the current changes", { { { "context" } } })
    end
    Cli.send = function(opts)
      sent = opts
    end

    Cli.prompt()

    Prompt.select = original_select
    Cli.send = original_send
    assert.are.equal("Review the current changes", sent.msg)
    assert.is_not_nil(sent.text)
  end)

  it("auto-selects a sole managed session instead of adding a duplicate tool", function()
    local original = Session.sessions
    local session = {
      id = "tmux 42",
      tool = Config.get_tool("codex"),
      cwd = Session.cwd(),
      backend = "tmux",
      priority = 50,
      started = true,
      external = false,
      is_attached = function()
        return false
      end,
    }
    Session.sessions = function()
      return { session }
    end

    local states = State.get({ name = "codex" })

    Session.sessions = original
    assert.are.equal(1, #states)
    assert.are.equal(session, states[1].session)
  end)

  it("keeps a new-tool choice alongside an external session", function()
    local original = Session.sessions
    local session = {
      id = "tmux 42",
      tool = Config.get_tool("codex"),
      cwd = Session.cwd(),
      backend = "tmux",
      priority = 10,
      started = true,
      external = true,
      is_attached = function()
        return false
      end,
    }
    Session.sessions = function()
      return { session }
    end

    local states = State.get({ name = "codex" })

    Session.sessions = original
    assert.are.equal(2, #states)
    assert.is_true(vim.iter(states):any(function(state)
      return state.session == nil
    end))
  end)

  it("formats same-tool sessions with distinct bounded identities", function()
    local function state(title, instance)
      return {
        tool = { name = "codex" },
        installed = true,
        started = true,
        session = {
          id = "tmux " .. instance,
          instance_id = instance,
          title = title,
          backend = "tmux",
          cwd = Session.cwd(),
        },
      }
    end
    local function text(parts)
      return table.concat(vim.tbl_map(function(part)
        return part[1]
      end, parts))
    end

    local first = text(Select.format(state("Implement the panel", "11111111")))
    local second = text(Select.format(state("Review the panel", "22222222")))
    local long = text(Select.format(state(("long "):rep(100), "33333333")))
    local new = text(Select.format({ tool = { name = "codex" }, installed = true, new = true }))

    assert.are_not.equal(first, second)
    assert.matches("Implement the panel", first)
    assert.is_true(#long < 200)
    assert.matches("new", new)
  end)
end)
