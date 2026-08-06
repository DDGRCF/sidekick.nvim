---@module 'luassert'

local Managed = require("sidekick.cli.managed_sessions")
local Resume = require("sidekick.cli.resume")
local Util = require("sidekick.util")

describe("managed CLI conversations", function()
  it("generates deterministic valid version 4 UUIDs", function()
    local id = Managed.uuid("sidekick-test")
    assert.is_true(Managed.valid_id(id))
    assert.are.equal("4", id:sub(15, 15))
    assert.matches("[89ab]", id:sub(20, 20))
    assert.are.equal(id, Managed.uuid("sidekick-test"))
  end)

  it("uses exact provider resume arguments", function()
    local cases = {
      copilot = { "copilot", "--resume" },
      pi = { "pi", "--session" },
      qwen = { "qwen", "--resume" },
    }
    local id = Managed.uuid("resume-test")
    for provider, expected in pairs(cases) do
      local adapter = Managed.adapter(provider)
      local tool = {
        name = provider,
        cmd = { provider },
        config = { resume = adapter },
      }
      local cmd, mode = Resume.command(tool, {
        conversation = { id = id, provider = provider, resumable = true },
      })
      local wanted = vim.deepcopy(expected)
      wanted[#wanted + 1] = id
      assert.are.same(wanted, cmd)
      assert.are.equal("exact", mode)
    end
  end)

  it("preserves an explicit exact session id", function()
    local id = Managed.uuid("explicit-test")
    local adapter = Managed.adapter("qwen")
    local prepared = adapter.prepare({ cmd = { "qwen", "--session-id", id } }, { instance_id = "agent" })
    assert.are.same({ "qwen", "--session-id", id }, prepared.cmd)
    assert.are.equal(id, prepared.conversation.id)
  end)

  it("creates Pi sessions with the dedicated exact-id flag", function()
    local prepared = Managed.adapter("pi").prepare({ cmd = { "pi" } }, { instance_id = "agent" })
    assert.are.equal("--session-id", prepared.cmd[2])
    assert.are.equal(prepared.conversation.id, prepared.cmd[3])
    assert.are.equal("--extension", prepared.cmd[4])
    assert.are.equal(prepared.conversation.data.control, prepared.env.SIDEKICK_PI_SESSION_FILE)
  end)

  it("tracks Pi session switches through its session_start extension", function()
    local adapter = Managed.adapter("pi")
    local tool = { cmd = { "pi" }, config = { env = {} } }
    local prepared = adapter.prepare(tool, { instance_id = "agent" })
    local active = Managed.uuid("pi-active")
    local file = assert(io.open(prepared.conversation.data.control, "w"))
    file:write(vim.json.encode({ id = active }))
    file:close()

    local conversation = adapter.capture(tool, {
      tool = { cmd = prepared.cmd },
      conversation = prepared.conversation,
      pids = {},
    })

    vim.fn.delete(prepared.conversation.data.control)
    assert.are.equal(active, conversation.id)
    assert.are.equal(prepared.conversation.data.control, conversation.data.control)
  end)

  it("does not override an explicit interactive resume command", function()
    local adapter = Managed.adapter("pi")
    assert.is_nil(adapter.prepare({ cmd = { "pi", "--resume" } }, { instance_id = "agent" }))
  end)

  it("checks Qwen JSON Lines in the saved working directory", function()
    local old_exec = Util.exec
    local old_executable = vim.fn.executable
    local id = Managed.uuid("qwen-existing")
    local cwd
    Util.exec = function(_, opts)
      cwd = opts.cwd
      return {
        vim.json.encode({ sessionId = Managed.uuid("another") }),
        vim.json.encode({ sessionId = id }),
      }
    end
    vim.fn.executable = function(name)
      return name == "qwen" and 1 or old_executable(name)
    end

    local ok = Managed.adapter("qwen").preflight(nil, { id = id }, { cwd = "/tmp/qwen-project" })

    Util.exec = old_exec
    vim.fn.executable = old_executable
    assert.is_true(ok)
    assert.are.equal("/tmp/qwen-project", cwd)
  end)

  it("tracks Qwen's provider-owned active writer after an in-TUI resume", function()
    local root = vim.fn.tempname()
    local locks = root .. "/tmp/session-writer-locks"
    vim.fn.mkdir(locks, "p")
    local launched = Managed.uuid("qwen-launched")
    local active = Managed.uuid("qwen-active")
    local file = assert(io.open(locks .. "/" .. active .. ".lock", "w"))
    file:write(vim.json.encode({ state = "active", pid = vim.fn.getpid(), session_id = active }))
    file:close()
    local adapter = Managed.adapter("qwen")
    local tool = {
      cmd = { "qwen", "--session-id", launched },
      env = { QWEN_RUNTIME_DIR = root },
      config = { env = {} },
    }

    local conversation = adapter.capture(tool, { tool = tool, pids = { vim.fn.getpid() } })

    vim.fn.delete(root, "rf")
    assert.are.equal(active, conversation.id)
  end)

  it("never restores Copilot's old conversation after an ambiguous TUI switch", function()
    local adapter = Managed.adapter("copilot")
    local launched = Managed.uuid("copilot-launched")
    local active = Managed.uuid("copilot-active")
    local tool = { cmd = { "copilot", "--session-id", launched }, config = { env = {} } }
    local buf = vim.api.nvim_create_buf(false, true)
    local session = {
      tool = tool,
      buf = buf,
      conversation = { id = launched, provider = "copilot", resumable = true, data = { managed = true } },
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> /resume" })
    assert.is_false(adapter.capture(tool, session).resumable)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> /resume " .. active })
    local captured = adapter.capture(tool, session)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_true(captured.resumable)
    assert.are.equal(active, captured.id)
  end)
end)
