---@module 'luassert'

local Config = require("sidekick.config")
local Status = require("sidekick.status")

describe("status handler", function()
  local notify
  local orig_notify
  local orig_get_client

  before_each(function()
    orig_notify = require("sidekick.util").notify
    orig_get_client = Config.get_client
    notify = {}
    require("sidekick.util").notify = function(msg, level)
      table.insert(notify, { msg = msg, level = level })
    end
    Config.get_client = function()
      return { id = 42 }
    end
  end)

  after_each(function()
    require("sidekick.util").notify = orig_notify
    Config.get_client = orig_get_client
  end)

  it("stores status and warns on message", function()
    Status.on_status(nil, {
      busy = true,
      kind = "Warning",
      message = "issue detected",
    }, {
      client_id = 42,
    })

    assert.are.same({
      { msg = "**Copilot:** issue detected", level = vim.log.levels.WARN },
    }, notify)

    assert.are.same({ busy = true, kind = "Warning", message = "issue detected" }, Status.get())
  end)

  it("appends sign-in hint when message mentions not signed", function()
    Status.on_status(nil, {
      busy = false,
      kind = "Error",
      message = "User not signed in",
    }, {
      client_id = 42,
    })

    assert.is_truthy(notify[1])
    assert.matches("SignIn", notify[1].msg)
    assert.are.equal(vim.log.levels.ERROR, notify[1].level)
  end)

  it("get() returns nil when no client", function()
    Config.get_client = function()
      return nil
    end
    assert.is_nil(Status.get())
  end)

  it("attach installs handler", function()
    local handlers = {}
    local client = { handlers = handlers }
    Status.attach(client)
    assert.are.equal(Status.on_status, handlers.didChangeStatus)
  end)

  it("summarizes CLI activity and attention", function()
    local Session = require("sidekick.cli.session")
    local Panel = require("sidekick.cli.panel")
    local original_attached = Session.attached
    local original_get = Session.get
    local original_active = Panel.active
    local working = {
      id = "summary-working",
      tool = { name = "codex" },
      cwd = "/tmp",
      status = "working",
      _sidekick_unread = true,
    }
    local waiting = {
      id = "summary-waiting",
      tool = { name = "claude" },
      cwd = "/tmp",
      status = "waiting",
    }
    Session.attached = function()
      return { working, waiting }
    end
    Session.get = function(id)
      return id == working.id and working or id == waiting.id and waiting or nil
    end
    Panel.active = function()
      return working
    end

    for _, session in ipairs({ working, waiting }) do
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SidekickCliAttach",
        modeline = false,
        data = { id = session.id },
      })
    end

    local summary = Status.summary()

    for _, session in ipairs({ working, waiting }) do
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SidekickCliDetach",
        modeline = false,
        data = { id = session.id },
      })
    end

    Session.attached = original_attached
    Session.get = original_get
    Panel.active = original_active
    assert.are.same({
      total = 2,
      active = 1,
      starting = 0,
      working = 1,
      waiting = 1,
      done = 0,
      error = 0,
      unread = 1,
      attention = 2,
    }, summary)
  end)

  it("updates one CLI session without rescanning all attached jobs", function()
    local Session = require("sidekick.cli.session")
    local Panel = require("sidekick.cli.panel")
    local original_attached = Session.attached
    local original_get = Session.get
    local original_active = Panel.active
    local id = "status-incremental-" .. tostring(vim.uv.hrtime())
    local session = {
      id = id,
      tool = { name = "codex" },
      cwd = "/tmp",
      status = "working",
      last_activity = 10,
    }
    Session.attached = function()
      error("unexpected full session scan")
    end
    Session.get = function(session_id)
      return session_id == id and session or nil
    end
    Panel.active = function()
      return session
    end

    local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "SidekickCliAttach",
      modeline = false,
      data = { id = id },
    })
    local item = vim.tbl_filter(function(value)
      return value.id == id
    end, Status.cli())[1]
    vim.api.nvim_exec_autocmds("User", {
      pattern = "SidekickCliDetach",
      modeline = false,
      data = { id = id },
    })

    Session.attached = original_attached
    Session.get = original_get
    Panel.active = original_active
    assert.is_true(ok, err)
    assert.are.equal("working", item.status)
    assert.is_true(item.active)
  end)
end)
