---@module 'luassert'

local Session = require("sidekick.cli.session")

describe("cli sessions", function()
  before_each(function()
    Session.setup()
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
end)
