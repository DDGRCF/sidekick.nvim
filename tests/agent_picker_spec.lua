---@module 'luassert'

local Config = require("sidekick.config")
local Picker = require("sidekick.cli.agent_picker")
local Cli = require("sidekick.cli")
local Panel = require("sidekick.cli.panel")
local Usage = require("sidekick.cli.agent_usage")

describe("cli agent picker", function()
  local old_provider
  local old_select
  local old_snacks
  local old_picker
  local old_new_timer
  local old_panel_rename
  local old_schedule
  local old_icons
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
    old_panel_rename = Panel.rename
    old_schedule = vim.schedule
    old_icons = Config.cli.win.tabs.icons
  end)

  after_each(function()
    Config.cli.agent_picker.provider = old_provider
    Config.cli.picker = old_picker
    vim.ui.select = old_select
    package.loaded.snacks = old_snacks
    vim.uv.new_timer = old_new_timer
    Panel.rename = old_panel_rename
    vim.schedule = old_schedule
    Config.cli.win.tabs.icons = old_icons
    Usage.clear()
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
    local focused
    local old_panel_select = require("sidekick.cli.panel").select
    require("sidekick.cli.panel").select = function(id, focus)
      selected = id
      focused = focus
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
    assert.is_true(focused)
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
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Context: 12k / 128k", "older", "latest output" })
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
    found.agent.branch = "main"
    found.agent.changed_files = { "lua/a.lua", "tests/a.lua" }
    local formatted = table.concat(vim.tbl_map(function(part)
      return part[1]
    end, opts.format(found)))
    assert.matches("codex", formatted)
    assert.matches("Agent one", formatted)
    assert.matches("done", formatted)
    assert.matches("project", formatted)
    assert.matches("main", formatted)
    assert.matches("%+2", formatted)
    assert.are.equal("SidekickCliToolCodex", opts.format(found)[1][2])
    Config.cli.win.tabs.icons = { codex = "C" }
    local with_icon = opts.format(found)
    assert.are.same({ "C ", "SidekickCliToolCodex" }, with_icon[1])
    assert.are.equal("Identifier", with_icon[2][2])
    local lines
    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 30,
      height = 4,
      style = "minimal",
    })
    opts.preview({
      item = found,
      buf = preview_buf,
      win = preview_win,
      preview = {
        reset = function()
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
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
    local winbar = vim.api.nvim_get_option_value("winbar", { win = preview_win })
    assert.matches("Status:", winbar)
    assert.matches("done", winbar)
    assert.matches("Directory:", winbar)
    assert.matches("/tmp/project", winbar)
    assert.matches("Backend:", winbar)
    assert.matches("terminal", winbar)
    assert.is_true(vim.wait(100, function()
      local context = Usage.get(terminal)
      return context and context.percent == 9
    end, 10))
    opts.preview({
      item = found,
      buf = preview_buf,
      win = preview_win,
      preview = {
        reset = function()
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
        end,
        set_title = function() end,
        set_lines = function(_, value)
          lines = value
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, value)
        end,
      },
    })
    winbar = vim.api.nvim_get_option_value("winbar", { win = preview_win })
    assert.matches("Context:", winbar)
    assert.matches("12k / 128k", winbar)
    assert.matches("SidekickCliStatusDone", winbar)
    opts.on_close()
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renames an agent in the Snacks picker without closing it", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local find_calls = 0
    local picker = {
      closed = false,
      id = "rename-test",
      opts = { live = false },
      input = {
        filter = { pattern = "old filter", search = "" },
      },
    }
    function picker.input:get()
      return self.text
    end
    function picker.input:set(pattern, search)
      self.filter.pattern = pattern or self.filter.pattern
      self.filter.search = search or self.filter.search
      self.text = picker.opts.live and self.filter.search or self.filter.pattern
    end
    function picker:find()
      find_calls = find_calls + 1
    end
    local original_find = picker.find
    function picker:focus()
      self.focused = true
    end
    function picker:update_titles() end
    function picker:selected()
      return { self.item }
    end
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return picker
        end,
      },
    }
    local terminal = register({
      id = "rename-one",
      tool = { name = "codex" },
      title = "Before rename",
      cwd = "/tmp/project",
      status = "working",
    })
    local renamed
    Panel.rename = function(value, id)
      renamed = { value = value, id = id }
      terminal.title = value
    end
    vim.schedule = function(callback)
      callback()
    end

    Picker.open({ {
      id = terminal.id,
      key = terminal.id,
      label = "Codex: Before rename",
      terminal = terminal,
    } })
    local item = opts.finder()[1]
    picker.item = item
    opts.actions.agent_rename(picker, item)

    assert.is_true(picker.focused)
    assert.are.equal("Rename Agent", picker.title)
    assert.are.equal("Rename agent: ", picker.opts.prompt)
    assert.are.equal("Before rename", picker.input:get())
    assert.are_not.equal(original_find, picker.find)

    picker.input.text = "After rename"
    opts.actions.agent_confirm(picker, item)

    assert.are.same({ value = "After rename", id = terminal.id }, renamed)
    assert.are.equal(original_find, picker.find)
    assert.are.equal("old filter", picker.input.filter.pattern)
    assert.is_nil(picker.opts.prompt)
    assert.is_nil(picker.title)
    assert.are.equal(1, find_calls)
    assert.is_false(picker.closed)
    opts.on_close()
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
