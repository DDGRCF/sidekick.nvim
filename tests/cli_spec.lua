---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local Context = require("sidekick.cli.context")
local History = require("sidekick.cli.history")
local Prompt = require("sidekick.cli.ui.prompt")
local Select = require("sidekick.cli.ui.select")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Workspace = require("sidekick.cli.workspace")

describe("cli routing", function()
  it("includes the Git diff in the review changes prompt", function()
    assert.is_not_nil(Config.cli.prompts.review_changes:find("{git_diff}", 1, true))
  end)

  it("waits for asynchronous context before sending", function()
    local original_context_get = Context.get
    local original_cwd = Session.cwd
    local original_with = State.with
    local ready = false
    local update
    local sends = 0
    Context.get = function(opts)
      update = opts.on_update
      return {
        render = function()
          if ready then
            return "ready", { { { "ready" } } }, false
          end
          return "", { {} }, true
        end,
      }
    end
    Session.cwd = function(opts)
      return opts and opts.cwd or "/tmp"
    end
    State.with = function()
      sends = sends + 1
    end

    Cli.send({ msg = "{git_status}", cwd = "/tmp" })
    local before = sends
    ready = true
    update()
    vim.wait(100, function()
      return sends == 1
    end)
    update()
    vim.wait(20)

    Context.get = original_context_get
    Session.cwd = original_cwd
    State.with = original_with
    assert.are.equal(0, before)
    assert.are.equal(1, sends)
  end)

  it("waits for asynchronous prompts with the native select provider", function()
    local original_context_get = Context.get
    local original_prompts = Config.cli.prompts
    local original_select = vim.ui.select
    local ready = false
    local update
    local calls = 0
    local selected
    Config.cli.prompts = { async = { msg = "{git_status}" } }
    Context.get = function(opts)
      update = opts.on_update
      return {
        render = function()
          if ready then
            return "complete", { { { "complete" } } }, false
          end
          return "partial", { { { "partial" } } }, true
        end,
      }
    end
    vim.ui.select = function(items)
      calls = calls + 1
      selected = vim.deepcopy(items)
      return nil
    end

    Prompt.select({ cb = function() end })
    local before = calls
    ready = true
    update()
    vim.wait(100, function()
      return calls == 1
    end)

    Context.get = original_context_get
    Config.cli.prompts = original_prompts
    vim.ui.select = original_select
    assert.are.equal(0, before)
    assert.are.equal(1, calls)
    assert.are.equal("complete", selected[1].data)
  end)

  it("opens a fork picker when no active agent is selected", function()
    local Panel = require("sidekick.cli.panel")
    local AgentPicker = require("sidekick.cli.agent_picker")
    local original_active = Panel.active
    local original_items = Panel.picker_items
    local original_open = AgentPicker.open
    local items = { { id = "live-agent" } }
    local opened

    Panel.active = function()
      return nil
    end
    Panel.picker_items = function()
      return items
    end
    AgentPicker.open = function(value, opts)
      opened = { items = value, opts = opts }
    end

    Cli.fork()

    Panel.active = original_active
    Panel.picker_items = original_items
    AgentPicker.open = original_open

    assert.are.same(items, opened.items)
    assert.is_true(opened.opts.fork)
  end)

  it("captures the cwd before opening the new-agent picker", function()
    local original_tools = Config.tools
    local original_attach = State.attach
    local original_select = vim.ui.select
    local original_cwd = Session.cwd
    local original_after_restore = Workspace.after_restore
    local attached
    local source_cwd = "/tmp/sidekick-source"
    local picker_cwd = "/tmp/sidekick-picker"
    Config.tools = function()
      return { codex = { name = "codex", cmd = { "true" } } }
    end
    Session.cwd = function(opts)
      return opts and opts.cwd or source_cwd
    end
    State.attach = function(_, opts)
      attached = opts
    end
    Workspace.after_restore = function()
      return false
    end
    vim.ui.select = function(items, _, cb)
      Session.cwd = function(opts)
        return opts and opts.cwd or picker_cwd
      end
      cb(items[1])
    end

    Cli.new({ proposal = false })

    Config.tools = original_tools
    State.attach = original_attach
    vim.ui.select = original_select
    Session.cwd = original_cwd
    Workspace.after_restore = original_after_restore
    assert.are.equal(source_cwd, attached.cwd)
  end)

  it("focuses a selected conversation after the picker callback returns", function()
    local original_get = State.get
    local original_attach = State.attach
    local original_select = vim.ui.select
    local original_schedule = vim.schedule
    local original_after_restore = Workspace.after_restore
    local scheduled
    local selecting = false
    local attached = false
    local state = {
      tool = { name = "codex" },
      installed = true,
      session = { id = "conversation-42" },
    }

    State.get = function()
      return { state }
    end
    State.attach = function(selected, opts)
      assert.is_false(selecting)
      assert.are.equal(state, selected)
      assert.is_true(opts.show)
      attached = true
    end
    Workspace.after_restore = function()
      return false
    end
    vim.schedule = function(cb)
      scheduled = cb
    end
    vim.ui.select = function(items, _, cb)
      selecting = true
      cb(items[1])
      assert.is_false(attached)
      selecting = false
    end

    Cli.select()
    assert.is_function(scheduled)
    scheduled()

    State.get = original_get
    State.attach = original_attach
    vim.ui.select = original_select
    vim.schedule = original_schedule
    Workspace.after_restore = original_after_restore
    assert.is_true(attached)
  end)

  it("does not auto-attach an agent from another cwd", function()
    local original_attached = Session.attached
    local original_active = require("sidekick.cli.panel").active
    local original_select = Select.select
    local original_schedule = vim.schedule
    local original_schedule_wrap = vim.schedule_wrap
    local original_cwd = Session.cwd
    local selected
    local source_cwd = "/tmp/sidekick-source"
    local other = {
      id = "other-cwd",
      tool = { name = "codex" },
      cwd = "/tmp/sidekick-other",
      backend = "terminal",
      is_attached = function()
        return true
      end,
    }
    Session.cwd = function(opts)
      return opts and opts.cwd or source_cwd
    end
    Session.attached = function()
      return { [other.id] = other }
    end
    require("sidekick.cli.panel").active = function()
      return nil
    end
    Select.select = function(opts)
      selected = opts
    end
    vim.schedule = function(cb)
      cb()
    end
    vim.schedule_wrap = function(cb)
      return cb
    end

    State.with(function() end, { attach = true })

    Session.attached = original_attached
    require("sidekick.cli.panel").active = original_active
    Select.select = original_select
    vim.schedule = original_schedule
    vim.schedule_wrap = original_schedule_wrap
    Session.cwd = original_cwd
    assert.is_not_nil(selected)
    assert.are.equal(source_cwd, selected.filter.cwd)
  end)

  it("defers the new-agent picker until a prompt callback has returned", function()
    local original_prompt_select = Prompt.select
    local original_select = Select.select
    local original_get = State.get
    local original_active = require("sidekick.cli.panel").active
    local original_schedule = vim.schedule
    local selected
    local scheduled
    Prompt.select = function(opts)
      opts.cb("Explain this", {})
    end
    Select.select = function(opts)
      selected = opts
    end
    State.get = function(filter)
      assert.is_true(filter.attached)
      return {}
    end
    require("sidekick.cli.panel").active = function()
      return nil
    end
    vim.schedule = function(cb)
      scheduled = cb
    end

    Cli.prompt()

    assert.is_function(scheduled)
    assert.is_nil(selected)
    scheduled()
    assert.is_true(selected.auto)

    Prompt.select = original_prompt_select
    Select.select = original_select
    State.get = original_get
    require("sidekick.cli.panel").active = original_active
    vim.schedule = original_schedule
  end)

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
    local original_cwd = Session.cwd
    local sent
    Session.cwd = function(opts)
      return opts and opts.cwd or "/tmp/sidekick-source"
    end
    Prompt.select = function(opts)
      Session.cwd = function(opts)
        return opts and opts.cwd or "/tmp/sidekick-picker"
      end
      opts.cb("Review the current changes", { { { "context" } } })
    end
    Cli.send = function(opts)
      sent = opts
    end

    Cli.prompt()

    Prompt.select = original_select
    Cli.send = original_send
    Session.cwd = original_cwd
    assert.are.equal("Review the current changes", sent.msg)
    assert.is_not_nil(sent.text)
    assert.are.equal("/tmp/sidekick-source", sent.cwd)
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

  it("uses the shared brand icon mapping in the CLI tool selector", function()
    local old_icons = Config.cli.win.tabs.icons
    Config.cli.win.tabs.icons = { codex = " C " }
    local parts = Select.format({ tool = { name = "codex" }, installed = true, new = true })
    Config.cli.win.tabs.icons = old_icons

    assert.are.same({ "C", "SidekickCliInstalled" }, parts[1])
    assert.are.same({ "codex" }, parts[3])
    assert.matches(
      "C codex",
      table.concat(vim.tbl_map(function(part)
        return part[1]
      end, parts))
    )
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

    Cli.new({ name = name, proposal = false })

    Config.tools = original_tools
    State.attach = original_attach
    local current = History.get("tools", name)
    assert.are.equal(name, attached.tool.name)
    assert.are.equal((previous and previous.count or 0) + 1, current.count)
  end)
end)
