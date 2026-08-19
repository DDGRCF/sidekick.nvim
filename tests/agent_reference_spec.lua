---@module 'luassert'

local AgentReference = require("sidekick.cli.agent_reference")
local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local Text = require("sidekick.text")
local Util = require("sidekick.util")

describe("cli agent references", function()
  local root
  local old = {}

  local function agent(opts)
    opts = opts or {}
    return {
      id = opts.id or "terminal: source",
      instance_id = opts.instance_id or "source123",
      title = opts.title or "Fix the parser",
      cwd = opts.cwd or "/tmp/project",
      tool = opts.tool or {
        name = opts.name or "claude",
        format = function(_, text)
          return Text.to_string(text)
        end,
      },
      conversation = opts.conversation or {
        id = opts.conversation_id or "conversation-42",
        provider = opts.provider or "claude",
        resumable = true,
      },
      is_running = opts.is_running or function()
        return true
      end,
    }
  end

  before_each(function()
    root = vim.fn.tempname()
    old.root = AgentReference.root
    old.sessions = Session.sessions
    old.active = Panel.active
    old.select = vim.ui.select
    old.emit = Util.emit
    old.send = AgentReference.send
    old.reference = Config.cli.agent_reference
    old.capture = Resume.capture
    AgentReference.root = root
  end)

  after_each(function()
    AgentReference.root = old.root
    Session.sessions = old.sessions
    Panel.active = old.active
    vim.ui.select = old.select
    Util.emit = old.emit
    AgentReference.send = old.send
    Config.cli.agent_reference = old.reference
    Resume.capture = old.capture
    vim.fn.delete(root, "rf")
  end)

  it("creates a file-like reference with agent and session identity only", function()
    local source = agent()
    source.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source.buf, 0, -1, false, { "SECRET CONVERSATION CONTENT" })

    local path = assert(AgentReference.create(source))
    local content = table.concat(vim.fn.readfile(path), "\n")

    assert.is_not_nil(content:find("Agent: `claude`", 1, true))
    assert.is_not_nil(content:find("Native conversation: `claude:conversation-42`", 1, true))
    assert.is_not_nil(content:find("Sidekick session: `terminal: source`", 1, true))
    assert.is_not_nil(content:find("--remote-expr", 1, true))
    assert.is_nil(content:find("SECRET CONVERSATION CONTENT", 1, true))
    vim.api.nvim_buf_delete(source.buf, { force = true })
  end)

  it("discovers the native conversation before creating a reference", function()
    local source = agent({ conversation = false })
    source.conversation = nil
    Resume.capture = function(session, opts)
      assert.is_true(opts.require_current)
      session.conversation = { id = "discovered-42", provider = "claude", resumable = true }
      return session.conversation
    end

    local path = assert(AgentReference.create(source))
    local content = table.concat(vim.fn.readfile(path), "\n")

    assert.is_not_nil(content:find("Session: `discovered-42`", 1, true))
    assert.is_not_nil(content:find("Native conversation: `claude:discovered-42`", 1, true))
  end)

  it("queries live output lazily by agent instance id", function()
    local source = agent()
    source.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source.buf, 0, -1, false, {
      "old line",
      "\27[31mcurrent result\27[0m",
    })
    Session.sessions = function()
      return { source }
    end
    Config.cli.agent_reference = { max_lines = 1, max_bytes = 4096 }

    local result = AgentReference.query("source123")

    assert.is_not_nil(result:find("Agent: claude", 1, true))
    assert.is_not_nil(result:find("Session: conversation-42", 1, true))
    assert.is_not_nil(result:find("current result", 1, true))
    assert.is_nil(result:find("old line", 1, true))
    assert.is_nil(result:find("\27", 1, true))
    vim.api.nvim_buf_delete(source.buf, { force = true })
  end)

  it("sends only the reference to the current target agent", function()
    local source = agent()
    local sent, submitted, focused, shown, event
    local target = agent({
      id = "terminal: target",
      instance_id = "target123",
      name = "codex",
      conversation_id = "target-conversation",
    })
    target.send = function(_, value)
      sent = value
    end
    target.submit = function()
      submitted = true
    end
    target.show = function()
      shown = true
    end
    target.focus = function()
      focused = true
    end
    Util.emit = function(name, data)
      event = { name, data }
    end

    local path = AgentReference.send(source, target)

    assert.is_not_nil(path)
    assert.is_not_nil(sent:find("running agent reference", 1, true))
    assert.is_not_nil(sent:find("agent: claude", 1, true))
    assert.is_not_nil(sent:find("session: conversation-42", 1, true))
    assert.is_not_nil(sent:find(path, 1, true))
    assert.is_true(submitted)
    assert.is_true(shown)
    assert.is_true(focused)
    assert.are.equal("SidekickCliReference", event[1])
    assert.are.equal("conversation-42", event[2].session)
  end)

  it("selects from other running agents and keeps the active agent as target", function()
    local source = agent()
    local target = agent({
      id = "terminal: target",
      instance_id = "target123",
      name = "codex",
      conversation_id = "target-conversation",
    })
    Session.sessions = function()
      return { target, source }
    end
    Panel.active = function()
      return target
    end
    local selected_items, select_opts
    vim.ui.select = function(items, opts, cb)
      selected_items, select_opts = items, opts
      cb(items[1])
    end
    local sent
    AgentReference.send = function(selected, current)
      sent = { selected, current }
    end

    AgentReference.select()

    assert.are.same({ source }, selected_items)
    assert.are.equal("sidekick_agent_reference", select_opts.kind)
    assert.is_string(select_opts.format_item(source))
    assert.is_table(select_opts.format_item(source, true))
    assert.is_table(select_opts.snacks.format(source))
    assert.are.same({ source, target }, sent)
  end)

  it("formats Codex references with icon, status, session, backend, and project", function()
    local source = agent({
      id = "terminal: codex",
      instance_id = "codex123",
      name = "codex",
      conversation_id = "019fe6a3-e835-7772-8959-fd1213bf1392",
      cwd = "/tmp/project",
      title = "Implement references",
    })
    source.status = "working"
    source.mux_backend = "tmux"
    local icon = Config.cli.win.tabs.icons.codex

    local native = AgentReference.format(source, false)
    local chunks = AgentReference.format(source, true)
    local rendered = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, chunks))

    assert.is_not_nil(native:find(vim.trim(icon), 1, true))
    assert.is_not_nil(native:find("codex", 1, true))
    assert.is_not_nil(native:find("Implement references", 1, true))
    assert.is_not_nil(native:find("working", 1, true))
    assert.is_not_nil(native:find("[tmux]", 1, true))
    assert.is_not_nil(native:find("session 019fe6a3", 1, true))
    assert.is_not_nil(native:find("/tmp/project", 1, true))
    assert.are.equal(native, rendered)
    assert.are.equal("SidekickCliToolCodex", chunks[1][2])
    assert.are.equal("SidekickCliStatusWorking", chunks[4][2])
  end)
end)
