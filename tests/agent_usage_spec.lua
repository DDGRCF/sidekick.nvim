---@module 'luassert'

local Usage = require("sidekick.cli.agent_usage")

describe("cli agent usage", function()
  local old_system

  before_each(function()
    old_system = vim.system
  end)

  after_each(function()
    vim.system = old_system
    Usage.clear()
  end)

  it("parses explicit context usage from terminal output", function()
    assert.are.same({ used = 12800, max = 128000, percent = 10 }, Usage.parse("Context: 12.8k / 128k tokens"))
    assert.are.same({ used = 23, max = 100, percent = 23 }, Usage.parse("Context left: 77%"))
    assert.is_nil(Usage.parse("Input tokens: 12.8k"))
  end)

  it("parses Codex token-count events", function()
    local event = vim.json.encode({
      type = "event_msg",
      payload = {
        type = "token_count",
        info = {
          model_context_window = 258400,
          total_token_usage = { total_tokens = 64700 },
        },
      },
    })
    assert.are.same({ used = 64700, max = 258400, percent = 25 }, Usage.parse_codex(event))
  end)

  it("parses Claude's latest native session usage", function()
    local first = vim.json.encode({
      type = "assistant",
      message = { usage = { input_tokens = 1000, cache_read_input_tokens = 2000, output_tokens = 300 } },
    })
    local latest = vim.json.encode({
      type = "assistant",
      message = {
        usage = {
          input_tokens = 12000,
          cache_read_input_tokens = 4000,
          cache_creation_input_tokens = 1000,
          output_tokens = 500,
        },
      },
    })
    assert.are.same({ used = 17500 }, Usage.parse_claude(first .. "\n" .. latest))
  end)

  it("parses OpenCode's latest native message usage", function()
    local messages = {
      {
        info = {
          role = "assistant",
          tokens = { input = 1000, output = 100, reasoning = 50, cache = { read = 2000, write = 300 } },
        },
      },
      {
        info = {
          role = "assistant",
          tokens = { input = 3000, output = 200, reasoning = 100, cache = { read = 4000, write = 500 } },
        },
      },
    }
    assert.are.same({ used = 7800 }, Usage.parse_opencode(messages))
    assert.are.same({ used = 7800 }, Usage.parse_opencode(vim.json.encode(messages)))
  end)

  it("loads native Claude usage from its captured session file", function()
    local path = vim.fn.tempname()
    local file = assert(io.open(path, "wb"))
    file:write(vim.json.encode({
      type = "assistant",
      message = { usage = { input_tokens = 12000, cache_read_input_tokens = 4000, output_tokens = 500 } },
    }))
    file:close()
    local value
    assert.is_true(Usage.claude(nil, { conversation = { data = { path = path } } }, function(usage)
      value = usage
    end))
    assert.is_true(vim.wait(100, function()
      return value ~= nil
    end, 10))
    assert.are.same({ used = 16500 }, value)
    vim.fn.delete(path)
  end)

  it("loads native OpenCode usage from the active local server", function()
    local called, value
    vim.system = function(cmd, opts, cb)
      called = { cmd = cmd, opts = opts }
      vim.schedule(function()
        cb({
          code = 0,
          stdout = vim.json.encode({
            {
              info = {
                role = "assistant",
                tokens = { input = 32000, output = 500, reasoning = 1000, cache = { read = 64000, write = 0 } },
              },
            },
          }),
        })
      end)
      return {}
    end
    assert.is_true(Usage.opencode(nil, {
      conversation = { id = "ses_1234567890abcdefghijklmnop" },
      base_url = "http://127.0.0.1:12345",
    }, function(usage)
      value = usage
    end))
    assert.are.same(
      { "curl", "-sS", "--max-time", "1", "http://127.0.0.1:12345/session/ses_1234567890abcdefghijklmnop/message" },
      called.cmd
    )
    assert.is_true(called.opts.text)
    assert.is_true(vim.wait(100, function()
      return value ~= nil
    end, 10))
    assert.are.same({ used = 97500 }, value)
    vim.system = old_system
  end)

  it("uses a tool-specific asynchronous adapter when available", function()
    local terminal = {
      id = "adapter",
      instance_id = "one",
      tool = {
        config = {
          usage = function(_, _, cb)
            vim.schedule(function()
              cb({ used = 64000, max = 128000 })
            end)
            return true
          end,
        },
      },
    }
    assert.is_nil(Usage.get(terminal))
    assert.is_true(vim.wait(100, function()
      local context = Usage.get(terminal)
      return context and context.percent == 50
    end, 10))
  end)

  it("updates terminal usage asynchronously and hides unavailable usage", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Context usage: 32k / 128k" })
    local terminal = {
      id = "usage",
      instance_id = "one",
      tool = { config = {} },
      buf = buf,
    }
    assert.is_nil(Usage.get(terminal))
    assert.is_true(vim.wait(100, function()
      local context = Usage.get(terminal)
      return context and context.percent == 25
    end, 10))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No context information" })
    vim.wait(1600)
    assert.is_not_nil(Usage.get(terminal))
    vim.wait(100)
    assert.is_nil(Usage.get(terminal))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
