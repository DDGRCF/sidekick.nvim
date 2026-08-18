---@module 'luassert'

local Fork = require("sidekick.cli.fork")
local Managed = require("sidekick.cli.managed_sessions")
local Resume = require("sidekick.cli.resume")

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
        conversation = { id = id, provider = provider, resumable = true, data = {} },
      })
      local wanted = vim.deepcopy(expected)
      wanted[#wanted + 1] = id
      assert.are.same(wanted, cmd)
      assert.are.equal("exact", mode)
    end
  end)

  it("captures Oh My Pi's provider-generated session id", function()
    local adapter = Managed.adapter("omp")
    local prepared = adapter.prepare({ cmd = { "omp" } }, { instance_id = "agent" })
    assert.are.equal("omp", prepared.cmd[1])
    assert.are.equal("--extension", prepared.cmd[2])
    assert.are.equal("--sidekick-session-file", prepared.cmd[4])
    assert.are.equal(prepared.env.SIDEKICK_OMP_SESSION_FILE, prepared.cmd[5])
    assert.is_nil(prepared.conversation)
    assert.is_not_nil(prepared.env.SIDEKICK_OMP_SESSION_FILE)

    local id = "1f9d2a6b9c0d1234"
    local path = "/tmp/omp-session.jsonl"
    local control = assert(io.open(prepared.env.SIDEKICK_OMP_SESSION_FILE, "w"))
    control:write(vim.json.encode({ id = id, file = path }))
    control:close()
    local tool = { cmd = prepared.cmd, env = prepared.env, config = { env = {} } }

    local conversation = adapter.capture(tool, { tool = tool, pids = {} })

    vim.fn.delete(prepared.env.SIDEKICK_OMP_SESSION_FILE)
    assert.are.equal(id, conversation.id)
    assert.are.equal("omp", conversation.provider)
    assert.are.equal(path, conversation.data.path)
    assert.are.equal(prepared.env.SIDEKICK_OMP_SESSION_FILE, conversation.data.control)
  end)

  it("resumes Oh My Pi by exact id with session tracking enabled", function()
    local adapter = Managed.adapter("omp")
    local id = "1f9d2a6b9c0d1234"
    local control = vim.fn.tempname()
    local tool = { name = "omp", cmd = { "omp" }, config = { resume = adapter } }

    local cmd, mode = Resume.command(tool, {
      conversation = {
        id = id,
        provider = "omp",
        resumable = true,
        data = { control = control },
      },
    })

    assert.are.equal("exact", mode)
    assert.are.equal("omp", cmd[1])
    assert.are.equal("--extension", cmd[2])
    assert.are.equal("--sidekick-session-file", cmd[4])
    assert.are.equal(control, cmd[5])
    assert.are.same({ "--resume", id }, { cmd[6], cmd[7] })
  end)

  it("tracks Oh My Pi continue commands without replacing them", function()
    local adapter = Managed.adapter("omp")
    local prepared = adapter.prepare({ cmd = { "omp", "--continue" } }, { instance_id = "continue-agent" })

    assert.are.equal("--continue", prepared.cmd[2])
    assert.are.equal("--extension", prepared.cmd[3])
    assert.are.equal("--sidekick-session-file", prepared.cmd[5])
    assert.is_nil(prepared.conversation)
  end)

  it("loads the Oh My Pi tracker when extension discovery is disabled", function()
    local adapter = Managed.adapter("omp")
    local prepared = adapter.prepare({ cmd = { "omp", "--no-extensions" } }, { instance_id = "explicit-extension" })
    local config = assert(loadfile("sk/cli/omp.lua"))()
    local available = Fork.available({
      name = "omp",
      cmd = { "omp", "--no-extensions" },
      config = config,
    })

    assert.are.equal("--no-extensions", prepared.cmd[2])
    assert.are.equal("--extension", prepared.cmd[3])
    assert.is_true(available)
  end)

  it("disables Oh My Pi session features when persistence is disabled", function()
    local adapter = Managed.adapter("omp")
    local config = assert(loadfile("sk/cli/omp.lua"))()
    local available = Fork.available({
      name = "omp",
      cmd = { "omp", "--no-session" },
      config = config,
    })

    assert.is_nil(adapter.prepare({ cmd = { "omp", "--no-session" } }, { instance_id = "no-session" }))
    assert.is_false(available)
  end)

  it("forks Oh My Pi from an exact id with independent session tracking", function()
    local config = assert(loadfile("sk/cli/omp.lua"))()
    local tool = { name = "omp", cmd = config.cmd, config = config }

    local cmd, mode = Fork.command(tool, {
      id = "1f9d2a6b9c0d1234",
      provider = "omp",
      resumable = true,
    })

    assert.are.equal("exact", mode)
    assert.are.equal("omp", cmd[1])
    assert.are.equal("--extension", cmd[2])
    assert.are.equal("--sidekick-session-file", cmd[4])
    assert.are.same({ "--fork", "1f9d2a6b9c0d1234" }, { cmd[6], cmd[7] })
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

  it("verifies Oh My Pi sessions by their JSONL header", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/project", "p")
    local id = "1f9d2a6b9c0d1234"
    local path = root .. "/project/2026-08-19_" .. id .. ".jsonl"
    local file = assert(io.open(path, "w"))
    file:write(vim.json.encode({ type = "session", version = 3, id = id, cwd = "/tmp/omp-project" }) .. "\n")
    file:close()

    local adapter = Managed.adapter("omp")
    local tool = { cmd = { "omp", "--session-dir", root }, config = { env = {} } }
    local ok = adapter.preflight(tool, { id = id, data = { path = path } }, { cwd = "/tmp/omp-project" })

    vim.fn.delete(root, "rf")
    assert.is_true(ok)
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
