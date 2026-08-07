---@module 'luassert'

local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")

describe("cli sessions", function()
  before_each(function()
    Session.setup()
  end)

  it("initializes the terminal backend for direct first-session creation", function()
    local old_backends = Session.backends
    local old_did_setup = Session.did_setup
    local old_mux_enabled = Config.cli.mux.enabled
    Session.backends = {}
    Session.did_setup = false
    Config.cli.mux.enabled = false

    local ok, session = pcall(Session.new, { tool = "codex" })

    Session.backends = old_backends
    Session.did_setup = old_did_setup
    Config.cli.mux.enabled = old_mux_enabled

    assert.is_true(ok)
    assert.are.equal("terminal", session.backend)
    session:close()
  end)

  it("disambiguates terminal buffer names for duplicate instance ids", function()
    local tool = {
      name = "sidekick-test",
      cmd = { vim.o.shell, vim.o.shellcmdflag, "exit 0" },
      config = {},
    }
    local id = tostring(vim.uv.hrtime())
    local first = Session.new({
      tool = tool,
      backend = "terminal",
      id = "duplicate-buffer-first-" .. id,
      cwd = vim.fn.getcwd(),
      instance_id = "same-instance",
      hidden = true,
    })
    local second = Session.new({
      tool = tool,
      backend = "terminal",
      id = "duplicate-buffer-second-" .. id,
      cwd = vim.fn.getcwd(),
      instance_id = "same-instance",
      hidden = true,
    })

    local first_name, second_name, first_started, second_started
    local ok, err = pcall(function()
      first:start()
      second:start()
      first_started = first.started
      second_started = second.started
      first_name = vim.api.nvim_buf_get_name(first.buf)
      second_name = vim.api.nvim_buf_get_name(second.buf)
    end)
    first:close()
    second:close()

    assert.is_true(ok, err)
    assert.is_true(first_started)
    assert.is_true(second_started)
    assert.are_not.equal(first_name, second_name)
    assert.matches("^sidekick://agent/same%-instance", first_name)
    assert.matches("^sidekick://agent/same%-instance", second_name)
  end)

  it("gives new agents of the same tool unique session ids", function()
    local first = Session.new({ tool = "codex", backend = "terminal" })
    local second = Session.new({ tool = "codex", backend = "terminal" })

    assert.are_not.equal(first.instance_id, second.instance_id)
    assert.are_not.equal(first.sid, second.sid)
    assert.matches("^codex ", first.sid)
    assert.matches("^codex ", second.sid)

    first:close()
    second:close()
  end)

  it("derives stable instance ids for discovered sessions", function()
    assert.are.equal(Session.instance("tmux 42"), Session.instance("tmux 42"))
    assert.are_not.equal(Session.instance("tmux 42"), Session.instance("tmux 43"))
  end)

  it("assigns exact provider conversation ids to managed CLIs", function()
    for _, name in ipairs({ "copilot", "pi", "qwen" }) do
      local session = Session.new({ tool = name, backend = "terminal" })
      assert.are.equal(name, session.conversation.provider)
      assert.is_true(session.conversation.resumable)
      assert.is_true(require("sidekick.cli.managed_sessions").valid_id(session.conversation.id))
      assert.is_true(vim.tbl_contains(session.tool.cmd, session.conversation.id))
      session:close()
    end
  end)

  it("keeps the legacy tool/cwd id available for discovery", function()
    local sid = Session.sid({ tool = "codex", cwd = "/tmp/project" })
    local instance = Session.sid({ tool = "codex", cwd = "/tmp/project", instance_id = "12345678" })
    assert.are.equal(sid .. " 12345678", instance)
  end)

  it("still recognizes pre-instance tmux session names", function()
    local Tmux = require("sidekick.cli.session.tmux")
    local cwd = Session.cwd({ cwd = "/tmp/project" })
    local legacy = Session.sid({ tool = "codex", cwd = cwd })
    local session = setmetatable({
      tool = { name = "codex" },
      cwd = cwd,
      sid = legacy .. " 12345678",
      mux_session = legacy,
    }, { __index = Tmux })

    assert.is_true(session:is_session())
    assert.are.same({ cmd = { "tmux", "attach-session", "-t", legacy } }, session:attach())
  end)

  it("persists a wrapper title back to its mux parent", function()
    local Util = require("sidekick.util")
    local parent = Session.new({ tool = "codex", backend = "terminal", id = "title-parent" })
    parent.backend = "zellij"
    parent.mux_session = "title-zellij"
    local child = Session.new({ tool = "codex", backend = "terminal", id = "title-child", parent = parent })
    child.title = "Persist this title"

    Session.persist(child)
    child:close()

    assert.are.equal(child.title, parent.title)
    assert.are.equal(child.title, Util.get_state(parent.sid).title)
    assert.are.equal(child.title, Util.get_state(parent.mux_session).title)
    parent:close()
    Util.del_state(parent.mux_session)
  end)

  it("persists native conversation metadata through terminal wrappers", function()
    local Util = require("sidekick.util")
    local parent = Session.new({ tool = "codex", backend = "terminal", id = "conversation-parent" })
    parent.backend = "zellij"
    parent.mux_session = "conversation-zellij"
    local child = Session.new({ tool = "codex", backend = "terminal", id = "conversation-child", parent = parent })
    child.conversation = { provider = "codex", id = "chat-42", resumable = true }

    Session.persist(child)

    assert.are.same(child.conversation, parent.conversation)
    assert.are.same(child.conversation, Util.get_state(parent.sid).conversation)
    assert.are.same(child.conversation, Util.get_state(parent.mux_session).conversation)

    child:close()
    parent:close()
    Util.del_state(parent.mux_session)
  end)

  it("rolls back a hidden terminal when its cwd no longer exists", function()
    local Terminal = require("sidekick.cli.terminal")
    local cwd = vim.fn.tempname() .. "/missing"
    local session = Session.new({ tool = "codex", backend = "terminal", cwd = cwd, hidden = true })

    local ok = pcall(function()
      session:start()
    end)

    assert.is_true(ok)
    assert.is_true(session.closed)
    assert.is_nil(Terminal.terminals[session.id])
  end)
end)
