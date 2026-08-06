---@module 'luassert'

local Config = require("sidekick.config")
local Picker = require("sidekick.cli.agent_picker")
local Cli = require("sidekick.cli")

describe("cli agent picker", function()
  local old_provider
  local old_select
  local old_snacks
  local old_picker
  local old_new_timer
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
    old_new_timer = vim.uv.new_timer
  end)

  after_each(function()
    Config.cli.agent_picker.provider = old_provider
    Config.cli.picker = old_picker
    vim.ui.select = old_select
    package.loaded.snacks = old_snacks
    vim.uv.new_timer = old_new_timer
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

  it("shows terminal preview tails and preserves a custom view while output updates", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local timer
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return { closed = false, id = "preview-test" }
        end,
      },
    }
    local output = {}
    for i = 1, 12 do
      output[i] = "output " .. i
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
    local terminal = register({
      id = "preview-one",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
      buf = buf,
      test_timer = vim.uv.new_timer(),
    })
    vim.uv.new_timer = function()
      return {
        close = function() end,
        is_closing = function()
          return false
        end,
        start = function(_, _, _, callback)
          timer = callback
        end,
        stop = function() end,
      }
    end

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Codex: Preview",
        terminal = terminal,
      },
    })

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 30,
      height = 4,
      style = "minimal",
    })
    local resets = 0
    local item = opts.finder()[1]
    opts.preview({
      item = item,
      buf = preview_buf,
      win = preview_win,
      preview = {
        reset = function()
          resets = resets + 1
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
        end,
        set_lines = function(_, lines)
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
        end,
        set_title = function() end,
      },
    })

    local line_count = vim.api.nvim_buf_line_count(preview_buf)
    local initial = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    assert.are.equal(math.max(1, line_count - vim.api.nvim_win_get_height(preview_win) + 1), initial.lnum)
    assert.are.equal(initial.lnum, initial.topline)

    vim.api.nvim_win_set_cursor(preview_win, { 9, 0 })
    vim.api.nvim_win_call(preview_win, function()
      vim.cmd("normal! zt")
    end)
    local before = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "latest output" })
    timer()
    assert.is_true(vim.wait(100, function()
      local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
      return lines[#lines] == "latest output"
    end, 10))

    local after = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    assert.are.equal(1, resets)
    assert.are.equal(before.lnum, after.lnum)
    assert.are.equal(before.topline, after.topline)
    opts.on_close()
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
