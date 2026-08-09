---@module 'luassert'

local Provider = require("sidekick.cli.provider_sessions")

describe("cli provider sessions", function()
  local function sqlite(path, marker, ids)
    local file = assert(io.open(path, "wb"))
    file:write("SQLite format 3\0", string.rep("\0", 84), "CREATE TABLE ", marker, " ", table.concat(ids, " "))
    file:flush()
    return file
  end

  local function buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("captures and verifies an open Codex session file by process identity", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local path = root .. "/rollout-conversation.jsonl"
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({ type = "session_meta", payload = { id = "conversation-42" } }) .. "\n")
    file:flush()
    local old_root = Provider.roots.codex
    Provider.roots.codex = vim.fs.normalize(root)

    local conversation = Provider.capture("codex", { pids = { vim.fn.getpid() } })

    assert.are.equal("conversation-42", conversation.id)
    assert.are.equal("codex", conversation.provider)
    assert.is_true(Provider.verify("codex", conversation))
    file:close()
    Provider.roots.codex = old_root
    vim.fn.delete(root, "rf")
  end)

  it("uses CODEX_HOME from the Codex tool environment", function()
    local home = vim.fn.tempname()
    local root = home .. "/sessions"
    vim.fn.mkdir(root, "p")
    local id = "019fd4cb-881f-74a2-bb84-571584e30dd4"
    local path = root .. "/rollout-conversation.jsonl"
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({ type = "session_meta", payload = { id = id } }) .. "\n")
    file:flush()

    local conversation = Provider.capture("codex", {
      pids = { vim.fn.getpid() },
      cwd = home,
      tool = { env = { CODEX_HOME = home } },
    })

    assert.are.equal(id, conversation.id)
    assert.is_true(Provider.verify("codex", conversation, { env = { CODEX_HOME = home } }, home))
    file:close()
    vim.fn.delete(home, "rf")
  end)

  it("uses CODEX_HOME from the configured tool environment", function()
    local home = vim.fn.tempname()
    local root = home .. "/sessions"
    vim.fn.mkdir(root, "p")
    local id = "019fd4cb-881f-74a2-bb84-571584e30dd5"
    local path = root .. "/rollout-conversation.jsonl"
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({ type = "session_meta", payload = { id = id } }) .. "\n")
    file:flush()

    local tool = { config = { env = { CODEX_HOME = home } } }
    local conversation = Provider.capture("codex", {
      pids = { vim.fn.getpid() },
      cwd = home,
      tool = tool,
    })

    assert.are.equal(id, conversation.id)
    assert.is_true(Provider.verify("codex", conversation, tool, home))
    file:close()
    vim.fn.delete(home, "rf")
  end)

  it("reads Codex session metadata larger than the prefix buffer", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "019fd4cb-881f-74a2-bb84-571584e30dd4"
    local path = root .. "/rollout-conversation.jsonl"
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({
      type = "session_meta",
      payload = { id = id, instructions = string.rep("x", 128 * 1024) },
    }) .. "\n")
    file:flush()
    local old_root = Provider.roots.codex
    Provider.roots.codex = vim.fs.normalize(root)

    local conversation = Provider.capture("codex", { pids = { vim.fn.getpid() } })

    assert.are.equal(id, conversation.id)
    file:close()
    Provider.roots.codex = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures and verifies an open Antigravity conversation database", function()
    local state_root = vim.fn.tempname()
    local root = state_root .. "/conversations"
    vim.fn.mkdir(root, "p")
    local id = "b98bb537-9e1f-4780-8fb4-2f4f0a3b9712"
    local path = root .. "/" .. id .. ".db"
    vim.fn.mkdir(state_root .. "/cache", "p")
    local metadata = assert(io.open(state_root .. "/cache/conversation_metadata.json", "wb"))
    metadata:write(vim.json.encode({ conversations = { [id] = { summary = { ProjectID = "project-42" } } } }))
    metadata:flush()
    local file = assert(io.open(path, "wb"))
    file:write("not a database")
    file:flush()
    local old_root = Provider.roots.antigravity
    Provider.roots.antigravity = vim.fs.normalize(root)

    local invalid = {
      id = id,
      provider = "antigravity",
      resumable = true,
      data = { path = path },
    }
    assert.is_false(Provider.verify("antigravity", invalid))

    file:seek("set", 0)
    file:write("SQLite format 3\0", string.rep("\0", 84), "CREATE TABLE trajectory_meta")
    file:flush()
    local conversation = Provider.capture("antigravity", { pids = { vim.fn.getpid() } })

    assert.are.equal(id, conversation.id)
    assert.are.equal("antigravity", conversation.provider)
    assert.are.equal("project-42", conversation.data.project_id)
    assert.is_true(Provider.verify("antigravity", conversation))

    file:close()
    metadata:close()
    Provider.roots.antigravity = old_root
    vim.fn.delete(state_root, "rf")
  end)

  it("captures and verifies the Grok session id rendered by its process", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "a1b2c3d4e5f6"
    local path = root .. "/grok.db"
    local file = sqlite(path, "sessions", { id })
    local buf = buffer({ "Grok Code", id })
    local old_root = Provider.roots.grok
    Provider.roots.grok = vim.fs.normalize(root)

    local conversation = Provider.capture("grok", {
      pids = { vim.fn.getpid() },
      buf = buf,
      tool = { cmd = { "grok" } },
    })

    assert.are.equal(id, conversation.id)
    assert.are.equal("grok", conversation.provider)
    assert.is_true(Provider.verify("grok", conversation))

    vim.api.nvim_buf_delete(buf, { force = true })
    file:close()
    Provider.roots.grok = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures UUID-shaped Grok session ids from newer clients", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "019fe6a3-e835-7772-8959-fd1213bf1391"
    local path = root .. "/grok.db"
    local file = sqlite(path, "sessions", { id })
    local buf = buffer({ "Grok Code", "Session ID: " .. id })
    local old_root = Provider.roots.grok
    Provider.roots.grok = vim.fs.normalize(root)

    local conversation = Provider.capture("grok", {
      pids = { vim.fn.getpid() },
      buf = buf,
      tool = { cmd = { "grok" } },
    })

    assert.are.equal(id, conversation.id)
    assert.is_true(Provider.verify("grok", conversation))

    vim.api.nvim_buf_delete(buf, { force = true })
    file:close()
    Provider.roots.grok = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures Grok Build sessions from their UUID directory", function()
    local root = vim.fn.tempname()
    local id = "019fe6a3-e835-7772-8959-fd1213bf1391"
    local path = root .. "/sessions/%2Ftmp%2Fproject/" .. id .. "/updates.jsonl"
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "wb"))
    file:write("{}\n")
    file:flush()
    local buf = buffer({ "Grok Build", "Session ID: " .. id })
    local old_root = Provider.roots.grok
    Provider.roots.grok = vim.fs.normalize(root)

    local conversation = Provider.capture("grok", {
      pids = { vim.fn.getpid() },
      buf = buf,
      cwd = "/tmp/project",
      tool = { cmd = { "grok" } },
    })

    assert.are.equal(id, conversation.id)
    assert.is_true(Provider.verify("grok", conversation))

    vim.api.nvim_buf_delete(buf, { force = true })
    file:close()
    Provider.roots.grok = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures a Cursor chat store opened by the running agent", function()
    local root = vim.fn.tempname()
    local workspace = root .. "/workspace"
    local id = "019fe6a3-e835-7772-8959-fd1213bf1392"
    local path = workspace .. "/" .. id .. "/store.db"
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = sqlite(path, "messages", { id })
    local old_root = Provider.roots.cursor
    Provider.roots.cursor = vim.fs.normalize(root)

    local conversation = Provider.capture("cursor", {
      pids = { vim.fn.getpid() },
      tool = { cmd = { "cursor-agent" } },
    })

    assert.are.equal(id, conversation.id)
    assert.are.equal("cursor", conversation.provider)
    assert.is_true(Provider.verify("cursor", conversation))

    file:close()
    Provider.roots.cursor = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures and verifies an open Crush session database", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "019fe6a3-e835-7772-8959-fd1213bf1392"
    local path = root .. "/crush.db"
    local file = sqlite(path, "sessions", { id })
    local cli = assert(io.open(root .. "/crush", "wb"))
    cli:write('#!/bin/sh\nprintf \'%s\\n\' \'[{"id":"abcdef1234567890","uuid":"', id, '","title":"Review"}]\'\n')
    cli:close()
    vim.fn.setfperm(root .. "/crush", "rwx------")
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local old_root = Provider.roots.crush
    Provider.roots.crush = vim.fs.normalize(root)

    local conversation = Provider.capture("crush", {
      pids = { vim.fn.getpid() },
      tool = { cmd = { "crush" } },
    })

    assert.are.equal(id, conversation.id)
    assert.are.equal("crush", conversation.provider)
    assert.are.equal(vim.fs.normalize(path), conversation.data.path)
    assert.is_true(Provider.verify("crush", conversation))

    file:close()
    vim.env.PATH = old_path
    Provider.roots.crush = old_root
    vim.fn.delete(root, "rf")
  end)

  it("captures and structurally verifies an OpenCode session id", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "ses_abcdef1234567890ABCDEFGHIJ"
    local path = root .. "/opencode.db"
    local file = sqlite(path, "session", { id })
    local cli = assert(io.open(root .. "/opencode", "wb"))
    cli:write("#!/bin/sh\nprintf '%s\\n' '[{\"id\":\"", id, "\"}]'\n")
    cli:close()
    vim.fn.setfperm(root .. "/opencode", "rwx------")
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local old_root = Provider.roots.opencode
    Provider.roots.opencode = vim.fs.normalize(root)
    local session = {
      pids = { vim.fn.getpid() },
      buf = buffer({ id }),
      tool = { cmd = { "opencode" } },
    }

    local conversation = Provider.capture("opencode", session)

    assert.are.equal(id, conversation.id)
    assert.are.equal("opencode", conversation.provider)
    assert.is_true(Provider.verify("opencode", conversation))

    vim.api.nvim_buf_delete(session.buf, { force = true })
    file:close()
    vim.env.PATH = old_path
    Provider.roots.opencode = old_root
    vim.fn.delete(root, "rf")
  end)

  it("binds an active OpenCode id to that process server", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local id = "ses_abcdef1234567890ABCDEFGHIJ"
    local curl = assert(io.open(root .. "/curl", "wb"))
    curl:write("#!/bin/sh\nprintf '%s\\n' '{\"", id, '":{"type":"busy"}}\'\n')
    curl:close()
    vim.fn.setfperm(root .. "/curl", "rwx------")
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local Session = require("sidekick.cli.session")
    local old_backend = Session.backends.opencode
    Session.backends.opencode = {
      sessions = function()
        return {
          {
            pid = vim.fn.getpid(),
            pids = { vim.fn.getpid() },
            base_url = "http://127.0.0.1:12345",
          },
        }
      end,
    }

    local conversation = Provider.capture("opencode", { pids = { vim.fn.getpid() } })

    assert.are.equal(id, conversation.id)
    assert.are.equal("opencode", conversation.provider)
    Session.backends.opencode = old_backend
    vim.env.PATH = old_path
    vim.fn.delete(root, "rf")
  end)

  it("rejects ambiguous OpenCode ids instead of guessing", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local first = "ses_1234567890abcdefghijklmnop"
    local second = "ses_abcdef1234567890ABCDEFGHIJ"
    local path = root .. "/opencode-beta.db"
    local file = sqlite(path, "session", { first, second })
    local buf = buffer({ first, second })
    local old_root = Provider.roots.opencode
    Provider.roots.opencode = vim.fs.normalize(root)

    local conversation = Provider.capture("opencode", {
      pids = { vim.fn.getpid() },
      buf = buf,
      tool = { cmd = { "opencode" } },
    })

    assert.is_nil(conversation)
    vim.api.nvim_buf_delete(buf, { force = true })
    file:close()
    Provider.roots.opencode = old_root
    vim.fn.delete(root, "rf")
  end)
end)
