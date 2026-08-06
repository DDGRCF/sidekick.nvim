---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local History = require("sidekick.cli.history")
local Prompt = require("sidekick.cli.ui.prompt")
local Select = require("sidekick.cli.ui.select")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Workspace = require("sidekick.cli.workspace")

describe("cli routing", function()
  it("waits for an automatic workspace restore before opening the tool picker", function()
    local original_after_restore = Workspace.after_restore
    local original_get = State.get
    local original_select = vim.ui.select
    local deferred
    local select_calls = 0
    Workspace.after_restore = function(cb)
      deferred = cb
      return true
    end
    State.get = function()
      return { { tool = { name = "codex" }, installed = true } }
    end
    vim.ui.select = function()
      select_calls = select_calls + 1
    end

    Select.select({ cb = function() end })

    assert.are.equal(0, select_calls)
    assert.is_function(deferred)
    Workspace.after_restore = function()
      return false
    end
    deferred()
    assert.are.equal(1, select_calls)

    Workspace.after_restore = original_after_restore
    State.get = original_get
    vim.ui.select = original_select
  end)

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

  it("prioritizes recent tools for select and new", function()
    local original_get = State.get
    local original_tools = Config.tools
    local original_select = vim.ui.select
    local prefix = "history-" .. tostring(vim.uv.hrtime())
    local names = { prefix .. "-one", prefix .. "-two", prefix .. "-three" }
    local select_states = {
      { tool = { name = names[1] }, installed = true },
      { tool = { name = names[2] }, installed = true },
      { tool = { name = names[3] }, installed = true },
    }
    local seen = {}
    local select_calls = 0

    State.get = function()
      return vim.deepcopy(select_states)
    end
    local select_tools = function(items, _, cb)
      select_calls = select_calls + 1
      seen[#seen + 1] = vim.tbl_map(function(state)
        return state.tool.name
      end, items)
      if select_calls <= 2 then
        cb(items[1])
      elseif select_calls == 3 then
        cb(items[2])
      end
    end
    vim.ui.select = select_tools
    Select.select({ cb = function() end })
    Select.select({ cb = function() end })
    Select.select({ cb = function() end })
    Select.select({ cb = function() end })

    local new_tools = {
      first = { name = names[1], cmd = { "true" } },
      second = { name = names[2], cmd = { "true" } },
      third = { name = names[3], cmd = { "true" } },
    }
    local new_seen = {}
    local new_calls = 0
    Config.tools = function()
      return new_tools
    end
    vim.ui.select = function(items, _, cb)
      new_calls = new_calls + 1
      new_seen[#new_seen + 1] = vim.tbl_map(function(state)
        return state.tool.name
      end, items)
      if new_calls == 1 then
        cb(items[3])
      end
    end
    Select.select({ new = true, cb = function() end })
    Select.select({ new = true, cb = function() end })

    vim.ui.select = select_tools
    Select.select({ cb = function() end })

    State.get = original_get
    Config.tools = original_tools
    vim.ui.select = original_select
    local first = seen[1][1]
    local second = seen[3][2]
    local third = new_seen[1][3]
    assert.are.equal(first, seen[2][1])
    assert.are.equal(first, seen[3][1])
    assert.are.equal(second, seen[4][1])
    assert.are.equal(first, seen[4][2])
    assert.are.equal(second, new_seen[1][1])
    assert.are.equal(first, new_seen[1][2])
    assert.are.equal(third, new_seen[2][1])
    assert.are.equal(first, new_seen[2][2])
    assert.are.equal(third, seen[5][1])
  end)

  it("records explicitly named new tools", function()
    local original_tools = Config.tools
    local original_attach = State.attach
    local name = "history-direct-new-" .. tostring(vim.uv.hrtime())
    local previous = History.get("tools", name)
    local attached

    Config.tools = function()
      return { [name] = { name = name, cmd = { "true" } } }
    end
    State.attach = function(state)
      attached = state
    end

    Cli.new({ name = name })

    Config.tools = original_tools
    State.attach = original_attach
    local current = History.get("tools", name)
    assert.are.equal(name, attached.tool.name)
    assert.are.equal((previous and previous.count or 0) + 1, current.count)
  end)
end)
