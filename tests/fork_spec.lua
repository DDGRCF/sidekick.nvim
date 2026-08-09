---@module 'luassert'

local Config = require("sidekick.config")
local Fork = require("sidekick.cli.fork")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("cli conversation fork", function()
  local restore

  after_each(function()
    if restore then
      restore()
      restore = nil
    end
  end)

  local function tool(name, config)
    return {
      name = name or "agent",
      cmd = { name or "agent", "--ui" },
      config = config or {},
    }
  end

  local function conversation(provider, id)
    return { provider = provider or "agent", id = id or "conversation-42", resumable = true }
  end

  local function stub_start(child_conversation, config)
    local old = {
      get_tool = Config.get_tool,
      capture = Resume.capture,
      new = Session.new,
      persist = Session.persist,
      get_state = State.get_state,
      attach = State.attach,
      emit = Util.emit,
      error = Util.error,
      warn = Util.warn,
      new_timer = vim.uv.new_timer,
      schedule_wrap = vim.schedule_wrap,
    }
    local events, errors, child_opts = {}, {}, nil
    local captures = 0
    local base = tool("agent", config or { fork = { "fork" } })
    function base:clone(opts)
      local cloned = vim.deepcopy(self)
      for key, value in pairs(opts or {}) do
        cloned[key] = value
      end
      return cloned
    end

    local source = {
      id = "source-agent",
      title = "Parent agent",
      cwd = "/tmp/project",
      closed = false,
      tool = { name = "agent", env = { SIDEKICK_TEST = "1" } },
      is_running = function()
        return true
      end,
    }
    local child = {
      id = "child-session",
      close = function(self)
        self.closed = true
      end,
    }
    local terminal = {
      id = "child-terminal",
      tool = base,
      cwd = source.cwd,
      closed = false,
      sent = {},
      is_running = function()
        return true
      end,
      close = function(self)
        self.closed = true
      end,
      send = function(self, input)
        self.sent[#self.sent + 1] = input
      end,
      submit = function(self)
        self.submitted = (self.submitted or 0) + 1
      end,
    }

    Config.get_tool = function()
      return base
    end
    Resume.capture = function(session)
      captures = captures + 1
      return session == source and conversation() or child_conversation
    end
    Session.new = function(opts)
      child_opts = opts
      return child
    end
    Session.persist = function() end
    State.get_state = function()
      return { session = child }
    end
    State.attach = function()
      return { terminal = terminal }
    end
    Util.emit = function(event, data)
      events[#events + 1] = { event = event, data = data }
    end
    Util.error = function(message)
      errors[#errors + 1] = message
    end
    Util.warn = function(message)
      errors[#errors + 1] = message
    end
    vim.schedule_wrap = function(fn)
      return fn
    end
    vim.uv.new_timer = function()
      local timer = { closed = false }
      function timer:is_closing()
        return self.closed
      end
      function timer:stop() end
      function timer:close()
        self.closed = true
      end
      function timer:start(_, _, callback)
        callback()
      end
      return timer
    end

    restore = function()
      Config.get_tool = old.get_tool
      Resume.capture = old.capture
      Session.new = old.new
      Session.persist = old.persist
      State.get_state = old.get_state
      State.attach = old.attach
      Util.emit = old.emit
      Util.error = old.error
      Util.warn = old.warn
      vim.uv.new_timer = old.new_timer
      vim.schedule_wrap = old.schedule_wrap
    end

    return source, terminal, function()
      return child_opts, captures, events, errors
    end
  end

  it("uses an exact fork command without falling back to latest", function()
    local cmd, mode = Fork.command(tool("agent", { fork = { "fork" }, continue = { "--last" } }), conversation())

    assert.are.same({ "agent", "--ui", "fork", "conversation-42" }, cmd)
    assert.are.equal("exact", mode)
  end)

  it("matches the native Codex and Claude fork command shapes", function()
    for _, case in ipairs({
      { name = "codex", expected = { "codex", "fork", "conversation-42" } },
      { name = "claude", expected = { "claude", "--resume", "conversation-42", "--fork-session" } },
      {
        name = "opencode",
        expected = { "opencode", "--port", "0", "--session", "conversation-42", "--fork" },
      },
      { name = "grok", expected = { "grok", "--resume", "conversation-42", "--fork-session" } },
      { name = "antigravity", expected = { "agy", "--conversation", "conversation-42" } },
    }) do
      local config = assert(loadfile("sk/cli/" .. case.name .. ".lua"))()
      local current = {
        name = case.name,
        cmd = config.cmd,
        config = config,
      }
      local cmd, mode = Fork.command(current, conversation(case.name))
      assert.are.same(case.expected, cmd)
      assert.are.equal("exact", mode)
    end
  end)

  it("does not advertise unsupported Crush conversation forks", function()
    local config = assert(loadfile("sk/cli/crush.lua"))()
    local available, reason = Fork.available({
      name = "crush",
      cmd = config.cmd,
      config = config,
    })

    assert.is_false(available)
    assert.matches("does not support native conversation fork", reason)
  end)

  it("passes Antigravity's project id to its documented /fork command", function()
    local config = assert(loadfile("sk/cli/antigravity.lua"))()
    local sent, submitted = {}, 0
    local terminal = {
      send = function(_, input)
        sent[#sent + 1] = input
      end,
      submit = function()
        submitted = submitted + 1
      end,
    }

    local ok = config.fork.after_start({}, terminal, {
      data = { project_id = "project-42" },
    })

    assert.is_true(ok)
    assert.are.same({ "/fork project-42" }, sent)
    assert.are.equal(1, submitted)

    sent, submitted = {}, 0
    ok = config.fork.after_start({}, terminal, {})
    assert.is_true(ok)
    assert.are.same({ "/fork" }, sent)
    assert.are.equal(1, submitted)
  end)

  it("supports provider-owned fork command adapters", function()
    local cmd, mode = Fork.command(
      tool("agent", {
        fork = {
          command = function(_, current, source)
            return { "custom", current.id, source.cwd }
          end,
        },
      }),
      conversation(),
      { cwd = "/tmp/project" }
    )

    assert.are.same({ "custom", "conversation-42", "/tmp/project" }, cmd)
    assert.are.equal("exact", mode)
  end)

  it("rejects missing, mismatched, and unsafe conversation ids", function()
    local t = tool("agent", { fork = { "fork" } })
    for _, current in ipairs({
      {},
      { provider = "other", id = "conversation-42", resumable = true },
      { provider = "agent", id = "--last", resumable = true },
      { provider = "agent", id = "has space", resumable = true },
      { provider = "agent", id = "conversation-42", resumable = false },
    }) do
      local cmd, mode = Fork.command(t, current)
      assert.is_nil(cmd)
      assert.are.equal("unsupported", mode)
    end
  end)

  it("reports providers without a native fork command", function()
    local available, reason = Fork.available(tool("agent"))

    assert.is_false(available)
    assert.matches("does not support native conversation fork", reason)
  end)

  it("accepts deferred provider fork adapters", function()
    local t = tool("cursor", { fork = { prepare = function() end } })
    local ready, reason, status = Fork.ready(t, {
      closed = false,
      conversation = conversation("cursor"),
      is_running = function()
        return true
      end,
    }, { capture = false })

    assert.is_true(Fork.available(t))
    assert.is_true(ready)
    assert.is_nil(reason)
    assert.are.equal("ready", status)
  end)

  it("asks Cursor ACP for a child session before launching it", function()
    local CursorFork = require("sidekick.cli.cursor_fork")
    local old = {
      chansend = vim.fn.chansend,
      executable = vim.fn.executable,
      jobstart = vim.fn.jobstart,
      jobstop = vim.fn.jobstop,
      defer_fn = vim.defer_fn,
      schedule = vim.schedule,
    }
    local callbacks
    local child_cmd
    vim.fn.executable = function()
      return 1
    end
    vim.fn.jobstart = function(_, opts)
      callbacks = opts
      return 42
    end
    vim.fn.jobstop = function() end
    vim.defer_fn = function() end
    vim.schedule = function(fn)
      fn()
    end
    vim.fn.chansend = function(_, payload)
      local request = vim.json.decode(vim.trim(payload))
      local result = request.method == "session/fork" and { sessionId = "cursor-child" } or {}
      callbacks.on_stdout(42, { vim.json.encode({ jsonrpc = "2.0", id = request.id, result = result }), "" })
      return #payload
    end
    restore = function()
      vim.fn.chansend = old.chansend
      vim.fn.executable = old.executable
      vim.fn.jobstart = old.jobstart
      vim.fn.jobstop = old.jobstop
      vim.defer_fn = old.defer_fn
      vim.schedule = old.schedule
    end

    local started, reason = CursorFork.prepare(
      { cmd = { "cursor-agent" }, config = {}, env = {} },
      conversation("cursor", "cursor-source"),
      { cwd = "/tmp/project" },
      function(cmd, error_message)
        child_cmd = cmd
        assert.is_nil(error_message)
      end
    )

    assert.is_true(started)
    assert.is_nil(reason)
    assert.are.same({ "cursor-agent", "--resume", "cursor-child" }, child_cmd)
  end)

  it("reports a pending state until an exact source conversation id is captured", function()
    local old_capture = Resume.capture
    restore = function()
      Resume.capture = old_capture
    end
    Resume.capture = function()
      return nil
    end

    local ready, reason, status = Fork.ready(tool("agent", { fork = { "fork" } }), {})

    assert.is_false(ready)
    assert.are.equal("pending", status)
    assert.matches("exact conversation id", reason)
  end)

  it("can report pending without probing the provider", function()
    local captures = 0
    local old_capture = Resume.capture
    restore = function()
      Resume.capture = old_capture
    end
    Resume.capture = function()
      captures = captures + 1
      return conversation()
    end

    local ready, reason, status = Fork.ready(tool("agent", { fork = { "fork" } }), {
      closed = false,
      is_running = function()
        return true
      end,
    }, { capture = false })

    assert.is_false(ready)
    assert.are.equal("pending", status)
    assert.matches("exact conversation id", reason)
    assert.are.equal(0, captures)
  end)

  it("supports conditional provider capabilities", function()
    local t = tool("agent", {
      fork = {
        available = function()
          return false, "provider version is too old"
        end,
      },
    })

    local available, reason = Fork.available(t)
    local cmd, mode = Fork.command(t, conversation())

    assert.is_false(available)
    assert.are.equal("provider version is too old", reason)
    assert.is_nil(cmd)
    assert.are.equal("unsupported", mode)
  end)

  it("fails closed when a capability check does not return true", function()
    local t = tool("agent", {
      fork = {
        available = function() end,
        args = { "fork" },
      },
    })

    local available, reason = Fork.available(t)

    assert.is_false(available)
    assert.matches("cannot fork this conversation", reason)
  end)

  it("starts a focused child and persists its verified relationship", function()
    local source, terminal, state = stub_start(conversation("agent", "child-conversation"))

    local result = Fork.start(source, { focus = true })
    local opts, captures, events = state()

    assert.are.equal(terminal, result)
    assert.are.same({ "agent", "--ui", "fork", "conversation-42" }, opts.tool.cmd)
    assert.are.same({ SIDEKICK_TEST = "1" }, opts.tool.env)
    assert.are.equal("↗ Fork · Parent agent", opts.title)
    assert.are.same({ provider = "agent", id = "conversation-42", title = "Parent agent" }, opts.forked_from)
    assert.is_true(opts.skip_resume_prepare)
    assert.are.equal(2, captures)
    assert.are.same({ event = "SidekickCliFork", data = { id = terminal.id, source_id = source.id } }, events[1])
    assert.is_nil(source._sidekick_forking)
    assert.is_false(source.closed)
  end)

  it("runs a provider post-start fork action before verification", function()
    local source, terminal = stub_start(conversation("agent", "child-conversation"), {
      fork = {
        command = function(_, current)
          return { "agent", "--resume", current.id }
        end,
        after_start = function(_, child_terminal)
          child_terminal:send("/fork")
          child_terminal:submit()
          return true
        end,
      },
    })

    Fork.start(source)

    assert.are.same({ "/fork" }, terminal.sent)
    assert.are.equal(1, terminal.submitted)
    assert.is_nil(source._sidekick_forking)
  end)

  it("closes an unverified child when the provider reuses the source id", function()
    local source, terminal, state = stub_start(conversation())

    Fork.start(source)
    local _, _, events, errors = state()

    assert.is_true(terminal.closed)
    assert.is_nil(source._sidekick_forking)
    assert.are.same({}, events)
    assert.matches("reused the source conversation id", errors[1])
    assert.is_false(source.closed)
  end)
end)
