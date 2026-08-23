---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")
local Picker = require("sidekick.cli.agent_picker")
local Resume = require("sidekick.cli.resume")
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
  local old_resume_capture
  local old_cli_new
  local old_cli_workspace
  local old_nvim_buf_get_lines
  local old_nvim_cmd
  local old_nvim_set_option_value
  local old_session_cwd
  local Terminal = require("sidekick.cli.terminal")
  local Session = require("sidekick.cli.session")
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
    old_resume_capture = Resume.capture
    old_cli_new = Cli.new
    old_cli_workspace = Cli.workspace
    old_nvim_buf_get_lines = vim.api.nvim_buf_get_lines
    old_nvim_cmd = vim.api.nvim_cmd
    old_nvim_set_option_value = vim.api.nvim_set_option_value
    old_session_cwd = Session.cwd
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
    Resume.capture = old_resume_capture
    Cli.new = old_cli_new
    Cli.workspace = old_cli_workspace
    vim.api.nvim_buf_get_lines = old_nvim_buf_get_lines
    vim.api.nvim_cmd = old_nvim_cmd
    vim.api.nvim_set_option_value = old_nvim_set_option_value
    Session.cwd = old_session_cwd
    Usage.clear()
    for _, t in ipairs(registered) do
      Terminal.terminals[t.id] = nil
      if t.test_timer and not t.test_timer:is_closing() then
        t.test_timer:close()
      end
    end
    registered = {}
  end)

  it("shows New, Resume, and Health actions when no agents are available", function()
    Config.cli.agent_picker.provider = "native"
    local select
    local new_calls = 0
    local cwd
    local workspace_action
    local health_cmd
    Session.cwd = function()
      return "/tmp/sidekick-source"
    end
    Cli.new = function(opts)
      new_calls = new_calls + 1
      cwd = opts.cwd
    end
    Cli.workspace = function(action)
      workspace_action = action
    end
    vim.api.nvim_cmd = function(cmd)
      health_cmd = cmd
    end
    vim.schedule = function(cb)
      cb()
    end
    vim.ui.select = function(items, opts, cb)
      select = { items = items, opts = opts, cb = cb }
    end

    Picker.open({})
    assert.matches("No Sidekick agents", select.opts.prompt)
    assert.are.same(
      { "New", "Resume", "Health" },
      vim.tbl_map(function(action)
        return action.label
      end, select.items)
    )

    select.cb(select.items[1])
    select.cb(select.items[2])
    select.cb(select.items[3])

    assert.are.equal(1, new_calls)
    assert.are.equal("/tmp/sidekick-source", cwd)
    assert.are.equal("restore", workspace_action)
    assert.are.same({ cmd = "checkhealth", args = { "sidekick" } }, health_cmd)
  end)

  it("uses a compact Snacks layout for the empty state", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
        end,
      },
    }

    Picker.open({})

    assert.are.equal("sidekick_empty", opts.source)
    assert.are.equal("Sidekick · No Agents", opts.title)
    assert.are.equal("select", opts.layout.preset)
    local items = opts.finder()
    assert.are.equal(3, #items)
    local formatted = opts.format(items[1])
    assert.are.equal("New", formatted[2][1])
    assert.matches("independent agent", formatted[3][1])
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

  it("offers a mark-read action in the native picker", function()
    Config.cli.agent_picker.provider = "native"
    local calls = 0
    local actions
    vim.ui.select = function(items, _, cb)
      calls = calls + 1
      if calls == 1 then
        cb(items[1])
      else
        actions = items
        cb(items[2])
      end
    end

    local terminal = register({
      id = "native-unread",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "done",
      _sidekick_unread = true,
    })

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Agent with unread output",
        terminal = terminal,
      },
    })

    assert.are.equal("Mark output read", actions[2].label)
    assert.is_false(terminal._sidekick_unread)
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
    assert.are.equal(found.agent.id, found._select_key)
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
    assert.are.same({ vim.trim(old_icons.codex) .. " ", "SidekickCliToolCodex" }, opts.format(found)[1])
    assert.are.equal("Identifier", opts.format(found)[2][2])
    Config.cli.win.tabs.icons = { codex = "C" }
    local with_icon = opts.format(found)
    assert.are.same({ "C ", "SidekickCliToolCodex" }, with_icon[1])
    assert.are.equal("Identifier", with_icon[2][2])
    terminal._sidekick_unread = true
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
    assert.matches("NEW", winbar)
    assert.matches("done", winbar)
    assert.matches("Directory:", winbar)
    assert.matches("/tmp/project", winbar)
    assert.matches("Backend:", winbar)
    assert.matches("terminal", winbar)
    assert.matches("%%#SidekickCliStatusDone#", winbar)
    assert.matches("%%#SidekickCliAttention#", winbar)
    opts.actions.agent_mark_read({
      selected = function()
        return {}
      end,
    }, found)
    assert.is_false(terminal._sidekick_unread)
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
    assert.matches("done", winbar)
    assert.matches("%%#SidekickCliStatusDone#", winbar)
    assert.matches("%%#Directory#", winbar)
    local _, highlight_runs = winbar:gsub("%%#[^#]+#", "")
    assert.is_true(highlight_runs <= 6)
    opts.on_close()
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("scopes agent state to the current panel", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return { closed = false, id = "panel-state-test" }
        end,
      },
    }

    local terminal = register({
      id = "panel-state-agent",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
    })
    local tab = vim.api.nvim_get_current_tabpage()
    local foreign = "sidekick-agent-picker-foreign-panel"
    local old_current = Panel.panels[tab]
    local old_foreign = Panel.panels[foreign]
    local ok, err = pcall(function()
      Panel.panels[tab] = { active = "another-agent", pinned = {} }
      Panel.panels[foreign] = { active = terminal.id, pinned = { [terminal.id] = true } }

      Picker.open({
        {
          id = terminal.id,
          key = terminal.id,
          label = "Codex: Panel state",
          terminal = terminal,
        },
      })

      local first = opts.finder()[1]
      assert.is_false(first.agent.active)
      assert.is_false(first.agent.pinned)
      terminal.status = "done"
      local refreshed = opts.finder()[1]
      assert.are.equal(first._select_key, refreshed._select_key)
      assert.are.equal(terminal.id, refreshed._select_key)
      opts.on_close()
    end)
    Panel.panels[tab] = old_current
    Panel.panels[foreign] = old_foreign
    assert.is_true(ok, err)
  end)

  it("cycles status filters without closing the Snacks picker", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local find_calls = 0
    local picker = { closed = false, id = "filter-test" }
    function picker:find()
      find_calls = find_calls + 1
    end
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return picker
        end,
      },
    }

    local working = register({
      id = "filter-working",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
    })
    local idle = register({
      id = "filter-idle",
      tool = { name = "claude" },
      cwd = "/tmp/project",
      status = "idle",
    })
    local done = register({
      id = "filter-done",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "done",
    })
    local failed = register({
      id = "filter-error",
      tool = { name = "claude" },
      cwd = "/tmp/project",
      status = "error",
      _sidekick_unread = true,
    })

    Picker.open(vim.tbl_map(function(terminal)
      return {
        id = terminal.id,
        key = terminal.id,
        label = terminal.tool.name .. ": " .. terminal.id,
        terminal = terminal,
      }
    end, { working, idle, done, failed }))

    local function ids()
      return vim.tbl_map(function(item)
        return item.agent.id
      end, opts.finder())
    end

    assert.are.same({ working.id, idle.id, done.id, failed.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("Open", picker.title)
    assert.are.same({ working.id, idle.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("Working", picker.title)
    assert.are.same({ working.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("Done", picker.title)
    assert.are.same({ done.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("Errors", picker.title)
    assert.are.same({ failed.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("New", picker.title)
    assert.are.same({ failed.id }, ids())
    opts.actions.agent_filter(picker)
    assert.matches("Attention", picker.title)
    assert.are.same({ failed.id }, ids())
    assert.are.equal(6, find_calls)
    opts.on_close()
  end)

  it("starts the Snacks picker on a requested attention filter", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local picker = { closed = false, id = "initial-filter-test" }
    function picker:find() end
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return picker
        end,
      },
    }
    local idle = register({
      id = "initial-filter-idle",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "idle",
    })
    local waiting = register({
      id = "initial-filter-waiting",
      tool = { name = "claude" },
      cwd = "/tmp/project",
      status = "waiting",
    })
    local items = vim.tbl_map(function(terminal)
      return {
        id = terminal.id,
        key = terminal.id,
        label = terminal.tool.name .. ": " .. terminal.id,
        terminal = terminal,
      }
    end, { idle, waiting })

    Picker.open(items, { filter = "attention" })

    assert.are.equal("Sidekick Agents · Attention", opts.title)
    assert.are.same(
      { waiting.id },
      vim.tbl_map(function(item)
        return item.agent.id
      end, opts.finder())
    )
    opts.actions.agent_filter(picker)
    assert.are.equal("Sidekick Agents · Pinned", picker.title)
    opts.on_close()
  end)

  it("filters the native picker before showing it", function()
    Config.cli.agent_picker.provider = "native"
    local selected
    local select_opts
    vim.ui.select = function(items, opts)
      selected = items
      select_opts = opts
    end
    local idle = register({
      id = "native-filter-idle",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "idle",
    })
    local unread = register({
      id = "native-filter-unread",
      tool = { name = "claude" },
      cwd = "/tmp/project",
      status = "done",
      _sidekick_unread = true,
    })

    Picker.open(
      vim.tbl_map(function(terminal)
        return {
          id = terminal.id,
          key = terminal.id,
          label = terminal.tool.name .. ": " .. terminal.id,
          terminal = terminal,
        }
      end, { idle, unread }),
      { filter = "attention" }
    )

    assert.are.equal(1, #selected)
    assert.are.equal(unread.id, selected[1].id)
    assert.are.equal("Select agent · Attention:", select_opts.prompt)
  end)

  it("reports invalid or empty requested filters without opening a picker", function()
    Config.cli.agent_picker.provider = "native"
    local Util = require("sidekick.util")
    local original_info, original_warn = Util.info, Util.warn
    local messages = {}
    Util.info = function(msg)
      messages[#messages + 1] = msg
    end
    Util.warn = function(msg)
      messages[#messages + 1] = msg
    end
    vim.ui.select = function()
      error("unexpected picker")
    end
    local idle = register({
      id = "empty-filter-idle",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "idle",
    })
    local items = {
      {
        id = idle.id,
        key = idle.id,
        label = "Codex: Idle",
        terminal = idle,
      },
    }

    Picker.open(items, { filter = "attention" })
    Picker.open(items, { filter = "bogus" })

    Util.info, Util.warn = original_info, original_warn
    assert.are.equal(2, #messages)
    assert.matches("No Sidekick agents match", messages[1])
    assert.matches("Invalid Sidekick agent filter", messages[2])
  end)

  it("defers fork discovery during refreshes and keeps the fork title", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local picker = { closed = false, id = "fork-filter-test" }
    function picker:find()
      self.find_calls = (self.find_calls or 0) + 1
    end
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return picker
        end,
      },
    }

    local captures = 0
    Resume.capture = function()
      captures = captures + 1
      return nil
    end
    local terminal = register({
      id = "fork-filter-agent",
      tool = { name = "codex" },
      cwd = "/tmp/project",
      status = "working",
    })

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Codex: Fork filter",
        terminal = terminal,
      },
    }, { fork = true })

    assert.are.equal("Fork Agent · All", opts.title)
    opts.finder()
    assert.are.equal(0, captures)

    opts.actions.agent_filter(picker)
    assert.are.equal("Fork Agent · Open", picker.title)
    assert.are.equal(0, captures)
    opts.on_close()
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

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Codex: Before rename",
        terminal = terminal,
      },
    })
    local item = opts.finder()[1]
    picker.item = item
    opts.actions.agent_rename(picker, item)

    assert.is_true(picker.focused)
    assert.are.equal("󰏫 Rename Agent", picker.title)
    assert.are.equal("󰏫 Rename agent: ", picker.opts.prompt)
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

  it("keeps polling previews that do not expose a local terminal buffer", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local output_callback
    local poll_callback
    local starts = {}
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return { closed = false, id = "mux-poll-test", find = function() end }
        end,
      },
    }
    local terminal = register({
      id = "mux-poll",
      tool = {
        name = "codex",
        config = {
          usage = function()
            return { used = 1, max = 10 }
          end,
        },
      },
      cwd = "/tmp/project",
      status = "working",
      backend = "tmux",
      parent = {
        dump_async = function(_, cb)
          output_callback = cb
        end,
      },
    })
    vim.uv.new_timer = function()
      return {
        close = function() end,
        is_closing = function()
          return false
        end,
        start = function(_, timeout, repeat_, callback)
          starts[#starts + 1] = { timeout = timeout, repeat_ = repeat_ }
          poll_callback = callback
        end,
        stop = function() end,
      }
    end

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Codex: Mux poll",
        terminal = terminal,
      },
    })

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 6,
      style = "minimal",
    })
    local lines
    opts.preview({
      item = opts.finder()[1],
      buf = preview_buf,
      win = preview_win,
      preview = {
        reset = function() end,
        set_title = function() end,
        set_lines = function(_, value)
          lines = value
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, value)
        end,
      },
    })

    assert.are.same({ { timeout = 500, repeat_ = 500 } }, starts)
    assert.is_function(poll_callback)
    assert.is_function(output_callback)
    output_callback("old mux output\nlatest mux output")
    assert.are.equal("latest mux output", lines[#lines])

    opts.on_close()
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end)

  it("moves local output listeners when the selected agent changes", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local timer
    local timer_starts = 0
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return { closed = false, id = "listener-switch-test", find = function() end }
        end,
      },
    }
    local first_buf = vim.api.nvim_create_buf(false, true)
    local second_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { "first initial" })
    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { "second initial" })
    local first = register({
      id = "listener-first",
      tool = { name = "codex", config = {} },
      cwd = "/tmp/project",
      status = "working",
      buf = first_buf,
      test_timer = vim.uv.new_timer(),
    })
    local second = register({
      id = "listener-second",
      tool = { name = "codex", config = {} },
      cwd = "/tmp/project",
      status = "working",
      buf = second_buf,
      test_timer = vim.uv.new_timer(),
    })
    vim.uv.new_timer = function()
      return {
        close = function() end,
        is_closing = function()
          return false
        end,
        start = function(_, timeout, repeat_, callback)
          assert.are.equal(50, timeout)
          assert.are.equal(0, repeat_)
          timer_starts = timer_starts + 1
          timer = callback
        end,
        stop = function() end,
      }
    end

    Picker.open({
      { id = first.id, key = first.id, label = "Codex: First", terminal = first },
      { id = second.id, key = second.id, label = "Codex: Second", terminal = second },
    })
    local found = {}
    for _, value in ipairs(opts.finder()) do
      found[value.agent.id] = value
    end
    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 6,
      style = "minimal",
    })
    local preview = {
      reset = function()
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
      end,
      set_title = function() end,
      set_lines = function(_, lines)
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
      end,
    }
    opts.preview({ item = found[first.id], buf = preview_buf, win = preview_win, preview = preview })
    opts.preview({ item = found[second.id], buf = preview_buf, win = preview_win, preview = preview })

    vim.api.nvim_buf_set_lines(first_buf, -1, -1, false, { "stale first output" })
    vim.wait(20)
    assert.are.equal(0, timer_starts)

    vim.api.nvim_buf_set_lines(second_buf, -1, -1, false, { "latest second output" })
    assert.are.equal(1, timer_starts)
    timer()
    assert.is_true(vim.wait(100, function()
      local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
      return lines[#lines] == "latest second output"
    end, 10))

    opts.on_close()
    vim.api.nvim_buf_set_lines(second_buf, -1, -1, false, { "output after close" })
    vim.wait(20)
    assert.are.equal(1, timer_starts)
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(first_buf, { force = true })
    vim.api.nvim_buf_delete(second_buf, { force = true })
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
    local initial_win_calls = 0
    local original_win_call = vim.api.nvim_win_call
    vim.api.nvim_win_call = function(...)
      initial_win_calls = initial_win_calls + 1
      return original_win_call(...)
    end
    local ok, err = pcall(opts.preview, {
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
    vim.api.nvim_win_call = original_win_call
    assert.is_true(ok, err)
    assert.are.equal(0, initial_win_calls)
    assert.is_false(vim.b[preview_buf].snacks_scroll)

    local line_count = vim.api.nvim_buf_line_count(preview_buf)
    local initial = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    assert.are.equal(line_count, initial.lnum)
    assert.is_true(initial.topline <= line_count)
    assert.is_true(initial.topline + vim.api.nvim_win_get_height(preview_win) > line_count)

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

  it("keeps large streaming previews live without redrawing unchanged content", function()
    Config.cli.agent_picker.provider = "snacks"
    local opts
    local timer
    local timer_starts = {}
    package.loaded.snacks = {
      picker = {
        pick = function(value)
          opts = value
          return { closed = false, id = "large-preview-test" }
        end,
      },
    }

    local output = {}
    for i = 1, 20000 do
      output[i] = ("output %05d %s"):format(i, string.rep("x", 160))
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
    local terminal = register({
      id = "large-preview",
      tool = {
        name = "codex",
        config = {
          usage = function()
            return { used = 1, max = 10 }
          end,
        },
      },
      cwd = "/tmp/project",
      status = "working",
      buf = buf,
      test_timer = vim.uv.new_timer(),
    })
    Usage.get(terminal)
    assert.is_true(vim.wait(100, function()
      return Usage.get(terminal) ~= nil
    end, 10))
    vim.uv.new_timer = function()
      return {
        close = function() end,
        is_closing = function()
          return false
        end,
        start = function(_, timeout, repeat_, callback)
          timer_starts[#timer_starts + 1] = { timeout = timeout, repeat_ = repeat_ }
          timer = callback
        end,
        stop = function() end,
      }
    end

    Picker.open({
      {
        id = terminal.id,
        key = terminal.id,
        label = "Codex: Large preview",
        terminal = terminal,
      },
    })

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 80,
      height = 10,
      style = "minimal",
    })
    local resets = 0
    local set_lines_calls = 0
    local set_title_calls = 0
    local winbar_sets = 0
    local source_reads = 0
    vim.api.nvim_buf_get_lines = function(target, ...)
      if target == buf then
        source_reads = source_reads + 1
      end
      return old_nvim_buf_get_lines(target, ...)
    end
    vim.api.nvim_set_option_value = function(name, value, option_opts)
      if name == "winbar" and option_opts.win == preview_win then
        winbar_sets = winbar_sets + 1
      end
      return old_nvim_set_option_value(name, value, option_opts)
    end
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
          set_lines_calls = set_lines_calls + 1
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
        end,
        set_title = function()
          set_title_calls = set_title_calls + 1
        end,
      },
    })

    local function drain()
      local done = false
      vim.schedule(function()
        done = true
      end)
      assert.is_true(vim.wait(200, function()
        return done
      end, 10))
    end

    local preview = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    assert.are.equal(Config.cli.agent_picker.preview_lines, #preview)
    assert.matches("output 20000", preview[#preview])
    assert.are.equal(0, #timer_starts)
    assert.are.equal(1, resets)
    assert.are.equal(1, set_lines_calls)
    assert.are.equal(1, set_title_calls)
    assert.are.equal(1, winbar_sets)
    assert.are.equal(1, source_reads)
    local initial_winbar = vim.api.nvim_get_option_value("winbar", { win = preview_win })
    assert.matches("working", initial_winbar)
    assert.matches("%%#SidekickCliStatusWorking#", initial_winbar)

    item.agent.label = "Codex: Renamed large preview"
    vim.api.nvim_exec_autocmds("User", { pattern = "SidekickCliPanel" })
    drain()
    assert.are.equal(1, set_lines_calls)
    assert.are.equal(2, set_title_calls)
    assert.are.equal(1, winbar_sets)

    old_nvim_set_option_value("winbar", "", { win = preview_win })
    vim.api.nvim_exec_autocmds("User", { pattern = "SidekickCliPanel" })
    drain()
    assert.are.equal(2, winbar_sets)
    assert.matches("working", vim.api.nvim_get_option_value("winbar", { win = preview_win }))
    assert.are.equal(1, source_reads)

    vim.api.nvim_win_set_cursor(preview_win, { 9, 0 })
    vim.api.nvim_win_call(preview_win, function()
      vim.cmd("normal! zt")
    end)
    local before = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    local last = 20000
    for batch = 1, 8 do
      local chunk = {}
      for i = 1, 1000 do
        last = last + 1
        chunk[i] = ("stream %05d batch %d %s"):format(last, batch, string.rep("y", 160))
      end
      if batch == 1 then
        for offset = 1, #chunk, 10 do
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.list_slice(chunk, offset, offset + 9))
        end
      else
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, chunk)
      end
      assert.are.equal(batch, #timer_starts)
      assert.are.same({ timeout = 50, repeat_ = 0 }, timer_starts[batch])
      timer()
      drain()
      preview = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
      assert.matches(("stream %05d"):format(last), preview[#preview])
      if batch == 1 then
        for _ = 1, 20 do
          timer()
        end
        drain()
        assert.are.equal(2, set_lines_calls)
        assert.are.equal(2, set_title_calls)
        assert.are.equal(2, winbar_sets)
        assert.are.equal(2, source_reads)
      end
    end

    local after = vim.api.nvim_win_call(preview_win, vim.fn.winsaveview)
    assert.are.equal(before.lnum, after.lnum)
    assert.are.equal(before.topline, after.topline)
    assert.are.equal(9, set_lines_calls)
    assert.are.equal(2, set_title_calls)
    assert.are.equal(2, winbar_sets)
    assert.are.equal(9, source_reads)

    terminal.status = "done"
    vim.api.nvim_exec_autocmds("User", { pattern = "SidekickCliStatus" })
    drain()
    local winbar = vim.api.nvim_get_option_value("winbar", { win = preview_win })
    assert.matches("done", winbar)
    assert.are.equal(9, set_lines_calls)
    assert.are.equal(3, winbar_sets)
    assert.are.equal(9, source_reads)

    opts.on_close()
    local starts = #timer_starts
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "output after close" })
    drain()
    assert.are.equal(starts, #timer_starts)
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
