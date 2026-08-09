---@module 'luassert'

local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")
local Workspace = require("sidekick.cli.workspace")

describe("cli workspace", function()
  local terminal
  local saved_workspace
  local session_sessions
  local executable
  local info
  local did_setup
  local workspace_enabled
  local workspace_autorestore
  local restore_pending
  local restore_waiters

  before_each(function()
    saved_workspace = Util.get_state("cli-workspace")
    session_sessions = Session.sessions
    executable = vim.fn.executable
    info = Util.info
    did_setup = Workspace.did_setup
    workspace_enabled = Config.cli.workspace.enabled
    workspace_autorestore = Config.cli.workspace.autorestore
    restore_pending = Workspace.restore_pending
    restore_waiters = Workspace.restore_waiters
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
    vim.fn.executable = executable
    Util.info = info
    Workspace.did_setup = did_setup
    Config.cli.workspace.enabled = workspace_enabled
    Config.cli.workspace.autorestore = workspace_autorestore
    Workspace.restore_pending = restore_pending
    Workspace.restore_waiters = restore_waiters
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
      forked_from = { provider = "codex", id = "parent-conversation", title = "Parent agent" },
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
    assert.are.same(terminal.forked_from, state.agents[1].forked_from)
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

  it("discards agents without exact resume metadata without a persistent failure", function()
    local cwd = vim.fn.getcwd()
    Util.set_state("cli-workspace", {
      version = 1,
      saved_at = os.time(),
      agents = {
        {
          key = "unresumable",
          tool = "codex",
          cwd = cwd,
          backend = "terminal",
          instance_id = "agent0001",
        },
      },
      panels = {
        {
          tab = { id = "unresumable-panel", cwd = cwd },
          order = { "unresumable" },
          pinned = { unresumable = true },
          layout = "right",
          sizes = {},
        },
      },
    })
    Session.sessions = function()
      return {}
    end
    vim.fn.executable = function(cmd)
      return cmd == "codex" and 1 or executable(cmd)
    end

    local result = Workspace.restore()
    local state = Util.get_state("cli-workspace")

    assert.are.equal(0, result.restored)
    assert.are.equal(0, #result.failed)
    assert.is_false(Workspace.partial)
    assert.are.same({}, state.agents)
    assert.are.same({}, state.panels[1].order)
    assert.are.same({}, state.panels[1].pinned)

    local next_result = Workspace.restore()

    assert.are.equal(0, #next_result.failed)
  end)

  it("is silent when an empty workspace has nothing to restore", function()
    local messages = {}
    Util.info = function(message)
      messages[#messages + 1] = message
    end
    Util.set_state("cli-workspace", { version = 1, saved_at = os.time(), agents = {}, panels = {} })
    Session.sessions = function()
      return {}
    end

    local result = Workspace.restore()

    assert.are.equal(0, result.restored)
    assert.are.same({}, messages)
  end)

  it("keeps the cwd of an existing tab when restoring its panel", function()
    local tab = vim.api.nvim_get_current_tabpage()
    local original_cwd = vim.fn.getcwd()
    local original_id = vim.t[tab].sidekick_workspace_id
    local saved_cwd = vim.fn.tempname()
    vim.fn.mkdir(saved_cwd, "p")
    vim.t[tab].sidekick_workspace_id = "existing-panel"
    Util.set_state("cli-workspace", {
      version = 1,
      saved_at = os.time(),
      agents = {},
      panels = {
        {
          tab = { id = "existing-panel", cwd = saved_cwd },
          order = {},
          pinned = {},
          layout = "right",
          sizes = {},
        },
      },
    })
    Session.sessions = function()
      return {}
    end

    local result = Workspace.restore()
    local restored_cwd = vim.fn.getcwd()

    vim.t[tab].sidekick_workspace_id = original_id
    vim.cmd.tcd(vim.fn.fnameescape(original_cwd))
    vim.fn.delete(saved_cwd, "rf")
    assert.are.equal(0, #result.failed)
    assert.are.equal(original_cwd, restored_cwd)
  end)

  it("restores after VimEnter and delays pickers until restore completes", function()
    local original_restore = Workspace.restore
    local original_create_autocmd = vim.api.nvim_create_autocmd
    local original_schedule = vim.schedule
    local original_vim = vim
    local restore_calls = 0
    local restore_opts
    local vim_enter
    local scheduled = {}
    local picker_calls = 0
    Config.cli.workspace.enabled = true
    Config.cli.workspace.autorestore = true
    Util.set_state("cli-workspace", { version = 1, saved_at = os.time(), agents = {}, panels = {} })
    Workspace.restore = function(opts)
      restore_calls = restore_calls + 1
      restore_opts = opts
      return { restored = 0, failed = {}, modes = {} }
    end
    vim.api.nvim_create_autocmd = function(event, opts)
      if event == "VimEnter" then
        vim_enter = opts.callback
      end
      return 1
    end
    vim.schedule = function(cb)
      scheduled[#scheduled + 1] = cb
    end

    local function setup(did_enter)
      _G.vim = setmetatable({ v = { vim_did_enter = did_enter } }, { __index = original_vim })
      Workspace.did_setup = false
      Workspace.restore_pending = false
      Workspace.restore_waiters = {}
      Workspace.setup()
      _G.vim = original_vim
    end

    setup(1)
    assert.are.equal(0, restore_calls)
    assert.is_true(Workspace.after_restore(function()
      picker_calls = picker_calls + 1
    end))
    assert.are.equal(1, #scheduled)
    scheduled[1]()
    assert.are.equal(1, restore_calls)
    assert.are.same({ silent = true }, restore_opts)
    assert.are.equal(1, picker_calls)

    restore_calls = 0
    restore_opts = nil
    picker_calls = 0
    scheduled = {}
    setup(0)
    assert.are.equal(0, restore_calls)
    assert.is_function(vim_enter)
    vim_enter()
    assert.are.equal(0, restore_calls)
    assert.are.equal(1, #scheduled)
    scheduled[1]()
    assert.are.equal(1, restore_calls)
    assert.are.same({ silent = true }, restore_opts)

    vim.api.nvim_create_autocmd = original_create_autocmd
    vim.schedule = original_schedule
    Workspace.restore = original_restore
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

  it("blocks repeated automatic resumes after an active writer conflict", function()
    local tab = vim.api.nvim_get_current_tabpage()
    local original_workspace_id = vim.t[tab].sidekick_workspace_id
    local cwd = vim.fn.getcwd()
    local preflight = Resume.preflight
    local calls = 0
    Resume.preflight = function()
      calls = calls + 1
      return false, "active_writer"
    end

    Util.set_state("cli-workspace", {
      version = 1,
      saved_at = os.time(),
      agents = {
        {
          key = "blocked-agent",
          tool = "codex",
          cwd = cwd,
          backend = "terminal",
          instance_id = "agent0001",
          conversation = { provider = "codex", id = "conversation-42", resumable = true },
        },
      },
      panels = {
        {
          tab = { id = "blocked-panel", cwd = cwd },
          order = { "blocked-agent" },
          pinned = {},
          layout = "right",
          sizes = {},
        },
      },
    })
    vim.t[tab].sidekick_workspace_id = "blocked-panel"
    Session.sessions = function()
      return {}
    end
    vim.fn.executable = function(cmd)
      return cmd == "codex" and 1 or executable(cmd)
    end

    local first = Workspace.restore({ silent = true })
    local saved = Util.get_state("cli-workspace")
    local second = Workspace.restore({ silent = true })

    Resume.preflight = preflight
    vim.t[tab].sidekick_workspace_id = original_workspace_id
    assert.are.equal(0, first.restored)
    assert.are.equal(0, #first.failed)
    assert.is_true(saved.agents[1].restore_blocked)
    assert.are.equal(0, second.restored)
    assert.are.equal(0, #second.failed)
    -- The second automatic restore only rechecks the provider-owned writer
    -- state; it does not start another resume process.
    assert.are.equal(2, calls)
  end)
end)
