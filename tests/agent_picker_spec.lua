---@module 'luassert'

local Config = require("sidekick.config")
local Picker = require("sidekick.cli.agent_picker")

describe("cli agent picker", function()
  local old_provider
  local old_select
  local old_snacks
  local old_picker
  local Terminal = require("sidekick.cli.terminal")
  local registered = {}

  local function register(t)
    t.instance_id = t.instance_id or "default"
    Terminal.terminals[t.id] = t
    registered[#registered + 1] = t
    return t
  end

  before_each(function()
    old_provider = Config.cli.agent_picker.provider
    old_picker = Config.cli.picker
    old_select = vim.ui.select
    old_snacks = package.loaded.snacks
  end)

  after_each(function()
    Config.cli.agent_picker.provider = old_provider
    Config.cli.picker = old_picker
    vim.ui.select = old_select
    package.loaded.snacks = old_snacks
    for _, t in ipairs(registered) do
      Terminal.terminals[t.id] = nil
      if t.test_timer and not t.test_timer:is_closing() then
        t.test_timer:close()
      end
    end
    registered = {}
  end)

  it("falls back to vim.ui.select and activates the chosen agent", function()
    Config.cli.agent_picker.provider = "native"
    local selected
    local old_panel_select = require("sidekick.cli.panel").select
    require("sidekick.cli.panel").select = function(id)
      selected = id
    end
    local calls = 0
    vim.ui.select = function(items, opts, cb)
      calls = calls + 1
      if calls == 1 then
        assert.are.equal("Agent one", opts.format_item(items[1]))
        cb(items[1])
      else
        assert.are.equal("Open agent", opts.format_item(items[1]))
        cb(items[1])
      end
    end

    local terminal = register({
      id = "one",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
    })

    Picker.open({
      {
        id = "one",
        key = "one",
        label = "Agent one",
        terminal = terminal,
      },
    })

    require("sidekick.cli.panel").select = old_panel_select
    assert.are.equal("one", selected)
  end)

  it("uses Snacks for searchable metadata and output preview", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
        end,
      },
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "older", "latest output" })
    local terminal = register({
      id = "one",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
      buf = buf,
      backend = "terminal",
      test_timer = vim.uv.new_timer(),
    })

    Picker.open({
      {
        id = "one",
        key = "one",
        label = "Codex: Agent one",
        terminal = terminal,
      },
    })

    local found = opts.finder()[1]
    assert.matches("@codex", found.text)
    assert.matches("#working", found.text)
    assert.matches("%%project", found.text)
    assert.is_nil(found.agent.terminal)
    assert.is_true(pcall(vim.deepcopy, found))
    terminal.status = "done"
    assert.matches("#done", opts.finder()[1].text)
    local lines
    opts.preview({
      item = found,
      preview = {
        reset = function() end,
        set_title = function() end,
        set_lines = function(_, value)
          lines = value
        end,
      },
    })
    assert.are.equal("latest output", lines[#lines])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
