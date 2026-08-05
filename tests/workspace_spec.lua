---@module 'luassert'

local Panel = require("sidekick.cli.panel")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")
local Workspace = require("sidekick.cli.workspace")

describe("cli workspace", function()
  local terminal
  local saved_workspace
  local session_sessions

  before_each(function()
    saved_workspace = Util.get_state("cli-workspace")
    session_sessions = Session.sessions
  end)

  after_each(function()
    if terminal then
      Terminal.terminals[terminal.id] = nil
      Session._attached[terminal.id] = nil
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        vim.api.nvim_buf_delete(terminal.buf, { force = true })
      end
    end
    Panel.hide()
    Panel.panels[vim.api.nvim_get_current_tabpage()] = nil
    Session.sessions = session_sessions
    Workspace.partial = false
    Workspace.restoring = false
    if saved_workspace == nil then
      Util.del_state("cli-workspace")
    else
      Util.set_state("cli-workspace", saved_workspace)
    end
    terminal = nil
  end)

  it("snapshots resumable conversations and panel placement", function()
    terminal = {
      id = "workspace-agent",
      sid = "codex workspace-agent",
      instance_id = "agent0001",
      cwd = vim.fs.normalize(vim.fn.getcwd()),
      backend = "terminal",
      tool = { name = "codex", config = { resume = { "resume" } } },
      title = "Workspace agent",
      status = "done",
      conversation = { provider = "codex", id = "conversation-1", resumable = true },
      buf = vim.api.nvim_create_buf(false, true),
      started = true,
      is_running = function()
        return true
      end,
      wo = function() end,
    }
    Terminal.terminals[terminal.id] = terminal
    Panel.show(terminal)
    Panel.panels[vim.api.nvim_get_current_tabpage()].pinned[terminal.id] = nil
    Panel.pin(terminal.id)

    local state = Workspace.snapshot()

    assert.are.equal(1, state.version)
    assert.are.equal(1, #state.agents)
    assert.are.equal("conversation-1", state.agents[1].conversation.id)
    assert.are.equal("codex workspace-agent", state.panels[1].active)
    assert.is_true(state.panels[1].pinned["codex workspace-agent"])
  end)

  it("rejects malformed agents without creating placeholder tabs", function()
    Util.set_state("cli-workspace", {
      version = 1,
      saved_at = os.time(),
      agents = { { key = "broken", tool = "codex" } },
      panels = {},
    })
    local before = vim.tbl_count(Terminal.terminals)

    local result = Workspace.restore()

    assert.are.equal(0, result.restored)
    assert.are.equal(0, #result.failed)
    assert.are.equal(before, vim.tbl_count(Terminal.terminals))
    assert.is_false(Workspace.partial)
  end)

  it("claims a different native tab for panels with the same cwd", function()
    local original = vim.api.nvim_get_current_tabpage()
    local cwd = vim.fn.getcwd()
    Util.set_state("cli-workspace", {
      version = 1,
      saved_at = os.time(),
      agents = {},
      panels = {
        { tab = { id = "same-cwd-one", cwd = cwd }, order = {}, pinned = {}, layout = "right", sizes = {} },
        { tab = { id = "same-cwd-two", cwd = cwd }, order = {}, pinned = {}, layout = "right", sizes = {} },
      },
    })
    Session.sessions = function()
      return {}
    end

    local result = Workspace.restore()
    local found = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      found[vim.t[tab].sidekick_workspace_id] = tab
    end

    assert.are.equal(0, result.restored)
    assert.is_not_nil(found["same-cwd-one"])
    assert.is_not_nil(found["same-cwd-two"])
    assert.are_not.equal(found["same-cwd-one"], found["same-cwd-two"])
    for _, tab in pairs(found) do
      if tab ~= original and vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd.tabclose()
      end
    end
    vim.api.nvim_set_current_tabpage(original)
  end)

  it("always releases the restore guard after an unexpected backend failure", function()
    Util.set_state("cli-workspace", { version = 1, saved_at = os.time(), agents = {}, panels = {} })
    Session.sessions = function()
      error("backend exploded")
    end

    local result = Workspace.restore()

    assert.are.equal(0, result.restored)
    assert.is_false(Workspace.restoring)
  end)
end)
