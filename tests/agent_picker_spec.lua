---@module 'luassert'

local Config = require("sidekick.config")
local Picker = require("sidekick.cli.agent_picker")
local Cli = require("sidekick.cli")

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

  it("opens the new-agent picker when no agents are available", function()
    local original_new = Cli.new
    local original_schedule = vim.schedule
    local original_cwd = require("sidekick.cli.session").cwd
    local new_calls = 0
    local cwd
    require("sidekick.cli.session").cwd = function()
      return "/tmp/sidekick-source"
    end
    Cli.new = function(opts)
      new_calls = new_calls + 1
      cwd = opts.cwd
    end
    vim.schedule = function(cb)
      cb()
    end

    Picker.open({})

    Cli.new = original_new
    vim.schedule = original_schedule
    require("sidekick.cli.session").cwd = original_cwd
    assert.are.equal(1, new_calls)
    assert.are.equal("/tmp/sidekick-source", cwd)
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
    local directory_icon_calls = 0
    package.loaded.snacks = {
      util = {
        icon = function(_, category)
          directory_icon_calls = directory_icon_calls + 1
          assert.are.equal("directory", category)
          return "D", "Directory"
        end,
      },
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
    local preview_buf = vim.api.nvim_create_buf(false, true)
    opts.preview({
      item = found,
      buf = preview_buf,
      preview = {
        reset = function()
          vim.api.nvim_buf_clear_namespace(preview_buf, -1, 0, -1)
        end,
        set_title = function() end,
        set_lines = function(_, value)
          lines = value
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, value)
        end,
      },
    })
    assert.are.equal("latest output", lines[#lines])
    assert.are.equal(1, directory_icon_calls)
    local extmarks = vim.api.nvim_buf_get_extmarks(preview_buf, -1, 0, -1, { details = true })
    local highlights = vim.tbl_map(function(extmark)
      return {
        row = extmark[2],
        col = extmark[3],
        end_col = extmark[4].end_col,
        hl_group = extmark[4].hl_group,
      }
    end, extmarks)
    local status_label_col = assert(lines[2]:find("Status:", 1, true)) - 1
    local directory_label_col = assert(lines[3]:find("Directory:", 1, true)) - 1
    local backend_label_col = assert(lines[4]:find("Backend:", 1, true)) - 1
    assert.are.same({
      { row = 0, col = 0, end_col = #lines[1], hl_group = "Title" },
      { row = 1, col = 0, end_col = status_label_col - 1, hl_group = "SidekickCliStatusDone" },
      { row = 1, col = status_label_col, end_col = status_label_col + #"Status:", hl_group = "Special" },
      { row = 1, col = status_label_col + #"Status: ", end_col = #lines[2], hl_group = "SidekickCliStatusDone" },
      { row = 2, col = 0, end_col = directory_label_col - 1, hl_group = "Directory" },
      { row = 2, col = directory_label_col, end_col = directory_label_col + #"Directory:", hl_group = "Special" },
      { row = 2, col = directory_label_col + #"Directory: ", end_col = #lines[3], hl_group = "Directory" },
      { row = 3, col = 0, end_col = backend_label_col - 1, hl_group = "Identifier" },
      { row = 3, col = backend_label_col, end_col = backend_label_col + #"Backend:", hl_group = "Special" },
      { row = 3, col = backend_label_col + #"Backend: ", end_col = #lines[4], hl_group = "Identifier" },
    }, highlights)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("loads mux previews asynchronously without calling synchronous dump", function()
    local callback
    local sync_calls = 0
    local terminal = register({
      id = "mux-one",
      instance_id = "mux-instance",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
      backend = "terminal",
      parent = {
        dump = function()
          sync_calls = sync_calls + 1
        end,
        dump_async = function(_, cb)
          callback = cb
        end,
      },
    })
    local item = {
      id = terminal.id,
      instance_id = terminal.instance_id,
      tool = "codex",
      label = "Mux agent",
      cwd = terminal.cwd,
      backend = "tmux",
    }
    local stale_updates, updates = 0, 0
    local initial = Picker.preview_lines(item, function()
      stale_updates = stale_updates + 1
    end)
    Picker.preview_lines(item, function()
      updates = updates + 1
    end)

    assert.are.equal("Loading terminal output…", initial[#initial])
    assert.are.equal(0, sync_calls)
    assert.is_function(callback)

    callback("old output\nlatest mux output")
    local loaded = Picker.preview_lines(item)
    assert.are.equal("latest mux output", loaded[#loaded])
    assert.are.equal(1, updates)
    assert.are.equal(0, stale_updates)
    assert.are.equal(0, sync_calls)
  end)
end)
