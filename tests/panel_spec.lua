---@module 'luassert'

local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")
local Scrollback = require("sidekick.cli.scrollback")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")

describe("cli agent panel", function()
  local ids = {} ---@type string[]
  local bufs = {} ---@type integer[]
  local previous_layout
  local previous_tabs
  local previous_icons

  local function fake(id, tool, title, status)
    local buf = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = buf
    ids[#ids + 1] = id
    local ret = {
      id = id,
      buf = buf,
      tool = { name = tool },
      title = title,
      status = status or "idle",
      backend = "terminal",
      cwd = vim.fs.normalize(vim.fn.getcwd()),
      started = true,
      is_attached = function(self)
        return Session._attached[self.id] ~= nil
      end,
      is_running = function()
        return true
      end,
      wo = function() end,
      close = function(self)
        if self.closed then
          return self
        end
        self.closed = true
        Terminal.terminals[self.id] = nil
        Panel.remove(self.id)
        return self
      end,
    }
    Terminal.terminals[id] = ret
    return ret
  end

  before_each(function()
    previous_layout = Util.get_state("cli-panel-layout")
    previous_tabs = Util.get_state("cli-panel-tabs")
    previous_icons = Config.cli.win.tabs.icons
    Config.cli.win.tabs.icons = {}
  end)

  it("selects refresh targets by session or native tab", function()
    local Refresh = require("sidekick.cli.panel.refresh")
    local panels = {
      [11] = { tab = 11, order = { "one", "shared" } },
      [22] = { tab = 22, order = { "two", "shared" } },
      [33] = { tab = 33, order = { "three" }, active = "active-only" },
    }
    local function selected(target)
      local ret = {}
      Refresh.each(panels, target, function(tab)
        ret[#ret + 1] = tab
      end)
      table.sort(ret)
      return ret
    end

    assert.are.same({ 11 }, selected("one"))
    assert.are.same({ 11, 22 }, selected("shared"))
    assert.are.same({ 33 }, selected("active-only"))
    assert.are.same({ 22 }, selected(22))
    assert.are.same({ 11, 22, 33 }, selected())
  end)

  after_each(function()
    Panel.hide()
    Panel.panels[vim.api.nvim_get_current_tabpage()] = nil
    for _, id in ipairs(ids) do
      Terminal.terminals[id] = nil
      Session._attached[id] = nil
    end
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    ids, bufs = {}, {}
    if previous_layout == nil then
      Util.del_state("cli-panel-layout")
    else
      Util.set_state("cli-panel-layout", previous_layout)
    end
    if previous_tabs == nil then
      Util.del_state("cli-panel-tabs")
    else
      Util.set_state("cli-panel-tabs", previous_tabs)
    end
    previous_layout = nil
    previous_tabs = nil
    Config.cli.win.tabs.icons = previous_icons
    previous_icons = nil
  end)

  it("reuses one window for multiple agent buffers", function()
    local codex = fake("codex-1", "codex", "Implement panel")
    local claude = fake("claude-1", "claude", "Review panel")

    Panel.show(codex)
    local win = Panel.win(codex)
    Panel.show(claude)

    assert.are.equal(win, Panel.win(claude))
    assert.are.equal(claude, Panel.active())
    assert.are.equal(claude.buf, vim.api.nvim_win_get_buf(win))
    assert.are.same({ "codex-1", "claude-1" }, Panel.panels[vim.api.nvim_get_current_tabpage()].order)
  end)

  it("locks the panel buffer against external window switches", function()
    local first = fake("winfix-one", "codex", "One")
    local second = fake("winfix-two", "claude", "Two")
    Panel.show(first, true)
    vim.cmd.stopinsert()
    local win = Panel.win(first)
    local other = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = other

    assert.is_true(vim.wo[win].winfixbuf)
    local ok = pcall(vim.api.nvim_set_current_buf, other)
    assert.is_false(ok)
    assert.are.equal(first.buf, vim.api.nvim_win_get_buf(win))

    Panel.select(second.id)
    assert.are.equal(second.buf, vim.api.nvim_win_get_buf(win))
    assert.is_true(vim.wo[win].winfixbuf)
  end)

  it("closes duplicate splits created from the panel window", function()
    for _, command in ipairs({ "split", "vsplit" }) do
      local first = fake("split-one-" .. command, "codex", "One")
      Panel.show(first)
      local tab = vim.api.nvim_get_current_tabpage()
      local panel_win = Panel.win(first)

      vim.api.nvim_set_current_win(panel_win)
      vim.cmd(command)

      local panel_buffers = vim.tbl_filter(function(win)
        return vim.api.nvim_win_get_buf(win) == first.buf
      end, vim.api.nvim_tabpage_list_wins(tab))
      assert.are.equal(1, #panel_buffers)
      assert.are.equal(panel_win, Panel.win(first))

      Panel.hide()
      Panel.remove(first.id)
    end
  end)

  it("cleans duplicate panel splits during refresh", function()
    local first = fake("refresh-split", "codex", "Refresh split")
    Panel.show(first)
    local tab = vim.api.nvim_get_current_tabpage()
    local panel_win = Panel.win(first)

    vim.api.nvim_set_current_win(panel_win)
    vim.cmd("noautocmd split")

    local panel_buffers = vim.tbl_filter(function(win)
      return vim.api.nvim_win_get_buf(win) == first.buf
    end, vim.api.nvim_tabpage_list_wins(tab))
    assert.are.equal(2, #panel_buffers)

    Panel.refresh()

    panel_buffers = vim.tbl_filter(function(win)
      return vim.api.nvim_win_get_buf(win) == first.buf
    end, vim.api.nvim_tabpage_list_wins(tab))
    assert.are.equal(1, #panel_buffers)
    assert.are.equal(panel_win, Panel.win(first))
  end)

  it("keeps a floating window that reuses the panel buffer", function()
    local first = fake("popup-one", "codex", "One")
    Panel.show(first)
    local panel_win = Panel.win(first)
    local popup = vim.api.nvim_open_win(first.buf, true, {
      relative = "editor",
      width = 10,
      height = 2,
      row = 1,
      col = 1,
    })

    assert.is_true(vim.api.nvim_win_is_valid(popup))
    assert.are.equal(panel_win, Panel.win(first))

    vim.api.nvim_win_close(popup, true)
  end)

  it("focuses an explicitly selected agent", function()
    local first = fake("codex-1", "codex", "Implement panel")
    local second = fake("claude-1", "claude", "Review panel")

    Panel.show(first)
    Panel.show(second)
    Panel.select(first.id, true)

    assert.are.equal(Panel.win(first), vim.api.nvim_get_current_win())
    assert.are.equal(first.buf, vim.api.nvim_win_get_buf(Panel.win(first)))
    vim.cmd.stopinsert()
  end)

  it("renders tool names and activity state without brand icons", function()
    local codex = fake("codex-1", "codex", "Implement panel")
    Panel.show(codex)
    codex.status = "done"
    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("Implement panel", line)
    assert.matches("codex", line)
    assert.matches("SidekickCliTabSelectedToolCodex", line)
    assert.matches("SidekickCliTabSelectedTitle#: Implement panel", line)
    assert.matches("SidekickCliTabSelected", line)
    assert.matches("SidekickCliTabSelectedStatusDone", line)
  end)

  it("renders the configured brand icon alongside the tool name in agent tabs", function()
    local codex = fake("codex-icon", "codex", "Implement panel")
    Config.cli.win.tabs.icons = { codex = "C" }
    Panel.show(codex)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("C", line)
    assert.is_not_nil(line:find("codex", 1, true))
  end)

  it("uses the green diagnostic highlight for working and done tabs", function()
    Config.set_hl()

    local working = vim.api.nvim_get_hl(0, { name = "SidekickCliStatusWorking", link = true })
    local done = vim.api.nvim_get_hl(0, { name = "SidekickCliStatusDone", link = true })

    assert.are.equal("DiagnosticOk", working.link)
    assert.are.equal("DiagnosticOk", done.link)
  end)

  it("keeps tab decorations on their tab surface", function()
    Config.set_hl()
    local tab = vim.api.nvim_get_hl(0, { name = "SidekickCliTab", link = false })
    local selected = vim.api.nvim_get_hl(0, { name = "SidekickCliTabSelected", link = false })
    local inactive_pin = vim.api.nvim_get_hl(0, { name = "SidekickCliTabPin", link = false })
    local active_pin = vim.api.nvim_get_hl(0, { name = "SidekickCliTabSelectedPin", link = false })
    local inactive_tool = vim.api.nvim_get_hl(0, { name = "SidekickCliTabToolCodex", link = false })
    local active_tool = vim.api.nvim_get_hl(0, { name = "SidekickCliTabSelectedToolCodex", link = false })
    local inactive_title = vim.api.nvim_get_hl(0, { name = "SidekickCliTabTitle", link = false })
    local active_title = vim.api.nvim_get_hl(0, { name = "SidekickCliTabSelectedTitle", link = false })

    assert.is_true(next(inactive_pin) ~= nil)
    assert.is_true(next(active_pin) ~= nil)
    assert.is_true(next(inactive_tool) ~= nil)
    assert.is_true(next(active_tool) ~= nil)
    assert.is_true(next(inactive_title) ~= nil)
    assert.is_true(next(active_title) ~= nil)
    assert.are.equal(tab.bg, inactive_pin.bg)
    assert.are.equal(tab.ctermbg, inactive_pin.ctermbg)
    assert.are.equal(tab.bg, inactive_tool.bg)
    assert.are.equal(tab.ctermbg, inactive_tool.ctermbg)
    assert.are.equal(selected.bg, active_pin.bg)
    assert.are.equal(selected.ctermbg, active_pin.ctermbg)
    assert.are.equal(selected.bg, active_tool.bg)
    assert.are.equal(selected.ctermbg, active_tool.ctermbg)
    assert.are.equal(tab.bg, inactive_title.bg)
    assert.are.equal(tab.ctermbg, inactive_title.ctermbg)
    assert.are.equal(selected.bg, active_title.bg)
    assert.are.equal(selected.ctermbg, active_title.ctermbg)
  end)

  it("rebuilds tab decorations after a colorscheme change", function()
    local previous = vim.g.colors_name
    local ok, err = pcall(function()
      for _, scheme in ipairs({ "default", "habamax" }) do
        vim.cmd.colorscheme(scheme)
        Config.set_hl()
        for _, surface_name in ipairs({ "SidekickCliTab", "SidekickCliTabSelected" }) do
          local surface = vim.api.nvim_get_hl(0, { name = surface_name, link = false })
          for _, suffix in ipairs({ "Pin", "ToolCodex", "StatusDone", "Title", "Close" }) do
            local decoration = vim.api.nvim_get_hl(0, { name = surface_name .. suffix, link = false })
            assert.is_true(next(decoration) ~= nil)
            assert.are.equal(surface.bg, decoration.bg)
            assert.are.equal(surface.ctermbg, decoration.ctermbg)
          end
        end
      end
    end)
    if previous then
      pcall(function()
        vim.cmd.colorscheme(previous)
      end)
    else
      vim.cmd.colorscheme("default")
    end
    Config.set_hl()
    assert.is_true(ok, err)
  end)

  it("slowly blinks working markers and stops when work is done", function()
    local old_new_timer = vim.uv.new_timer
    local old_schedule = vim.schedule
    local old_show_status = Config.cli.win.tabs.show_status
    local timer_callback
    local timer = { closed = false }
    function timer:is_closing()
      return self.closed
    end
    function timer:stop() end
    function timer:close()
      self.closed = true
    end
    function timer:start(delay, interval, callback)
      self.delay = delay
      self.interval = interval
      timer_callback = callback
    end

    vim.uv.new_timer = function()
      return timer
    end
    vim.schedule = function(callback)
      callback()
    end
    Config.cli.win.tabs.show_status = true
    local codex = fake("blink", "codex", "Blinking agent", "working")

    local ok, err = pcall(function()
      Panel.show(codex)
      local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
      local status = Config.cli.win.tabs.status

      assert.are.equal(1000, timer.delay)
      assert.are.equal(1000, timer.interval)
      assert.is_not_nil(timer_callback)
      assert.is_not_nil(Panel.render(p):find(status.working, 1, true))

      timer_callback()
      assert.is_not_nil(Panel.render(p):find(status.idle, 1, true))

      codex.status = "done"
      Panel.refresh()
      assert.is_true(timer.closed)
      assert.is_not_nil(Panel.render(p):find(status.done, 1, true))
    end)

    codex.status = "done"
    pcall(Panel.refresh)
    Config.cli.win.tabs.show_status = old_show_status
    vim.schedule = old_schedule
    vim.uv.new_timer = old_new_timer
    if not ok then
      error(err)
    end
  end)

  it("shows an attention marker for unread agent output", function()
    local old_attention = Config.cli.win.tabs.show_attention
    local codex = fake("unread", "codex", "Unread output")
    Panel.show(codex)
    codex._sidekick_unread = true
    Config.cli.win.tabs.show_attention = true

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    Config.cli.win.tabs.show_attention = old_attention
    assert.matches("SidekickCliTabSelectedAttention", line)
  end)

  it("keeps priority agents visible when tabs overflow", function()
    local first = fake("priority-one", "codex", "Working agent", "working")
    local second = fake("quiet-two", "codex", "Quiet two")
    local third = fake("quiet-three", "codex", "Quiet three")
    local fourth = fake("active-four", "codex", "Active agent")
    Panel.show(first)
    Panel.show(second)
    Panel.show(third)
    Panel.show(fourth)
    Panel.resize({ width = 50 })

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("Work", line)
    assert.matches("Acti", line)
    assert.matches("SidekickCliTabStatusWorking", line)
    assert.matches("SidekickCliTabSelected", line)
  end)

  it("keeps tool highlights on the active agent tab only", function()
    local codex = fake("codex-1", "codex", "Implement panel")
    local claude = fake("claude-1", "claude", "Review panel")
    Panel.show(codex)
    Panel.show(claude)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.is_nil(line:find("SidekickCliTabToolCodex", 1, true))
    assert.matches("SidekickCliTabSelectedToolClaude", line)
  end)

  it("uses configured agent icons alongside tool names", function()
    local old = Config.cli.win.tabs.icons
    local codex = fake("codex-1", "codex", "Implement panel")
    Panel.show(codex)

    Config.cli.win.tabs.icons = {}
    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
    assert.is_not_nil(line:find(vim.trim(Config.ui.icons.installed), 1, true))
    assert.is_not_nil(line:find("codex", 1, true))

    Config.cli.win.tabs.icons = { codex = "X", default = "D" }
    line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
    assert.is_not_nil(line:find("X", 1, true))
    assert.is_not_nil(line:find("codex", 1, true))
    assert.is_nil(line:find(" D", 1, true))
    assert.is_nil(line:find(vim.trim(Config.ui.icons.installed), 1, true))

    Config.cli.win.tabs.icons = old
  end)

  it("uses configurable pin and close icons", function()
    local old_pin, old_close = Config.ui.icons.pin, Config.ui.icons.close
    local codex = fake("codex-1", "codex", "Decorated panel")
    Panel.show(codex)
    Panel.panels[vim.api.nvim_get_current_tabpage()].pinned[codex.id] = true

    Config.ui.icons.pin = "PIN"
    Config.ui.icons.close = "CLOSE"
    local ok, line = pcall(Panel.render, Panel.panels[vim.api.nvim_get_current_tabpage()])

    Config.ui.icons.pin, Config.ui.icons.close = old_pin, old_close
    assert.is_true(ok)
    assert.is_not_nil(line:find("PIN", 1, true))
    assert.is_not_nil(line:find("CLOSE", 1, true))
  end)

  it("escapes configurable tab icons for winbar rendering", function()
    local old_pin, old_close = Config.ui.icons.pin, Config.ui.icons.close
    local codex = fake("codex-1", "codex", "Escaped panel")
    Panel.show(codex)

    Config.ui.icons.pin = "%"
    Config.ui.icons.close = "%"
    Panel.panels[vim.api.nvim_get_current_tabpage()].pinned[codex.id] = true
    local ok, line = pcall(Panel.render, Panel.panels[vim.api.nvim_get_current_tabpage()])

    Config.ui.icons.pin, Config.ui.icons.close = old_pin, old_close
    assert.is_true(ok)
    assert.is_not_nil(line:find("SidekickCliTabSelectedPin# %% ", 1, true))
    assert.is_not_nil(line:find("SidekickCliTabSelectedClose#%% %T", 1, true))
  end)

  it("supports configurable tab separators", function()
    local old = Config.cli.win.tabs.separator_style
    local first = fake("one", "codex", "One")
    Panel.show(first)

    local cases = {
      { style = "thin", left = "▏", right = "▕" },
      { style = "thick", left = "▌", right = "▐" },
      { style = "slant", left = "", right = "" },
      { style = "slope", left = "", right = "" },
      { style = "padded_slant", left = " ", right = " " },
      { style = "padded_slope", left = " ", right = " " },
    }
    for _, case in ipairs(cases) do
      Config.cli.win.tabs.separator_style = case.style
      local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
      assert.is_not_nil(line:find(case.left, 1, true))
      assert.is_not_nil(line:find(case.right, 1, true))
    end

    Config.cli.win.tabs.separator_style = { left = "<", right = ">" }
    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
    assert.is_not_nil(line:find("<", 1, true))
    assert.is_not_nil(line:find(">", 1, true))

    Config.cli.win.tabs.separator_style = old
  end)

  it("keeps the active tab visible while truncating overflowing tabs", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "codex", "Two")
    local third = fake("three", "codex", "Three")
    local fourth = fake("four", "codex", "Four")
    Panel.show(first)
    Panel.show(second)
    Panel.show(third)
    Panel.show(fourth)
    Panel.resize({ width = 50 })

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("Three", line)
    assert.matches("Four", line)
    assert.matches("…2", line)
    assert.is_nil(line:find("One", 1, true))
    assert.is_nil(line:find("Two", 1, true))
    assert.are.equal(fourth, Panel.active())
  end)

  it("shows hidden tabs after widening the panel window", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "codex", "Two")
    local third = fake("three", "codex", "Three")
    local fourth = fake("four", "codex", "Four")
    Panel.show(first)
    Panel.show(second)
    Panel.show(third)
    Panel.show(fourth)
    local win = Panel.win(fourth)

    Panel.resize({ width = 50 })
    assert.is_nil(vim.wo[win].winbar:find("One", 1, true))

    vim.api.nvim_win_set_width(win, vim.o.columns - 2)
    vim.api.nvim_exec_autocmds("WinResized", {})

    assert.is_not_nil(vim.wo[win].winbar:find("One", 1, true))
  end)

  it("opens the agent picker from a hidden-tab marker", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "codex", "Two")
    local third = fake("three", "codex", "Three")
    local fourth = fake("four", "codex", "Four")
    Panel.show(first)
    Panel.show(second)
    Panel.show(third)
    Panel.show(fourth)
    Panel.resize({ width = 50 })
    Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    local token
    for id, item in pairs(Panel.clicks) do
      if item.action == "pick" then
        token = id
        break
      end
    end
    assert.is_not_nil(token)

    local original_pick = Panel.pick
    local calls = 0
    Panel.pick = function()
      calls = calls + 1
    end
    _G.SidekickCliTabClick(token)
    Panel.pick = original_pick

    assert.are.equal(1, calls)
  end)

  it("focuses the panel when selecting a tab from its winbar", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
    local code_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(p.win, code_win)

    Panel.render(p)
    local token
    for id, item in pairs(Panel.clicks) do
      if item.action == "select" and item.id == first.id then
        token = id
        break
      end
    end
    assert.is_not_nil(token)

    _G.SidekickCliTabClick(token)

    assert.are.equal(p.win, vim.api.nvim_get_current_win())
    assert.are.equal(first, Panel.active())
  end)

  it("disambiguates duplicate tab titles", function()
    local first = fake("one", "codex", "Same title")
    local second = fake("two", "codex", "Same title")
    Panel.show(first)
    Panel.show(second)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("Same title · #one", line)
    assert.matches("Same title · #two", line)
  end)

  it("keeps duplicate title identifiers visible when titles are truncated", function()
    local old_max_name_length = Config.cli.win.tabs.max_name_length
    Config.cli.win.tabs.max_name_length = 5
    local first = fake("one", "codex", "Same title")
    local second = fake("two", "codex", "Same title")
    Panel.show(first)
    Panel.show(second)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
    Config.cli.win.tabs.max_name_length = old_max_name_length

    assert.matches("#one", line)
    assert.matches("#two", line)
  end)

  it("optionally includes cwd and status metadata in tabs", function()
    local old_cwd = Config.cli.win.tabs.show_cwd
    local old_status = Config.cli.win.tabs.show_status
    local first = fake("metadata", "codex", "Metadata", "working")
    first.cwd = "/tmp/sidekick"
    Config.cli.win.tabs.show_cwd = true
    Config.cli.win.tabs.show_status = false
    Panel.show(first)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])
    Config.cli.win.tabs.show_cwd = old_cwd
    Config.cli.win.tabs.show_status = old_status

    assert.matches("/tmp/sidekick", line)
    assert.is_nil(line:find(Config.cli.win.tabs.status.working, 1, true))
  end)

  it("omits the status spacer from picker labels when status is hidden", function()
    local old_status = Config.cli.win.tabs.show_status
    local old_picker = Config.cli.picker
    local old_agent_picker = Config.cli.agent_picker.provider
    local old_select = vim.ui.select
    local first = fake("picker-status", "codex", "Picker status")
    local seen_items
    Config.cli.win.tabs.show_status = false
    Config.cli.picker = "telescope"
    Config.cli.agent_picker.provider = "native"
    vim.ui.select = function(items)
      seen_items = items
    end

    Panel.show(first)
    Panel.pick()

    Config.cli.win.tabs.show_status = old_status
    Config.cli.picker = old_picker
    Config.cli.agent_picker.provider = old_agent_picker
    vim.ui.select = old_select

    assert.are.equal("codex: Picker status", seen_items[1].label)
  end)

  it("keeps a middle active tab visible while truncating both sides", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "codex", "Two")
    local third = fake("three", "codex", "Three")
    local fourth = fake("four", "codex", "Four")
    local fifth = fake("five", "codex", "Five")
    Panel.show(first)
    Panel.show(second)
    Panel.show(third)
    Panel.show(fourth)
    Panel.show(fifth)
    Panel.select(third.id)
    Panel.resize({ width = 50 })

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    assert.matches("Three", line)
    assert.matches("Two", line)
    assert.matches("…1", line)
    assert.matches("…2", line)
    assert.is_nil(line:find("One", 1, true))
    assert.is_nil(line:find("Four", 1, true))
    assert.is_nil(line:find("Five", 1, true))
    assert.are.equal(third, Panel.active())
  end)

  it("escapes percent signs after display-width title truncation", function()
    local old = Config.cli.win.tabs.max_name_length
    Config.cli.win.tabs.max_name_length = 5
    local codex = fake("codex-1", "codex", "100%好")

    local ok = pcall(Panel.show, codex)
    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    Config.cli.win.tabs.max_name_length = old
    assert.is_true(ok)
    assert.matches("100%%%%…", line)
  end)

  it("does not split a grapheme while truncating a title", function()
    local old = Config.cli.win.tabs.max_name_length
    Config.cli.win.tabs.max_name_length = 2
    local codex = fake("codex-1", "codex", "☀️X")
    Panel.show(codex)

    local line = Panel.render(Panel.panels[vim.api.nvim_get_current_tabpage()])

    Config.cli.win.tabs.max_name_length = old
    assert.is_nil(line:find("☀", 1, true))
    assert.matches("…", line)
  end)

  it("cycles and remembers the previously active agent", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    Panel.cycle(-1)
    assert.are.equal(first, Panel.active())
    Panel.previous()
    assert.are.equal(second, Panel.active())
  end)

  it("puts the most recently selected agent first in the picker", function()
    local old_picker = Config.cli.picker
    local old_agent_picker = Config.cli.agent_picker.provider
    local old_select = vim.ui.select
    Config.cli.picker = "telescope"
    Config.cli.agent_picker.provider = "native"

    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    Panel.select(first.id)

    local order
    vim.ui.select = function(items)
      order = vim.tbl_map(function(item)
        return item.id
      end, items)
    end
    Panel.pick()

    Config.cli.picker = old_picker
    Config.cli.agent_picker.provider = old_agent_picker
    vim.ui.select = old_select
    assert.are.same({ first.id, second.id }, order)
  end)

  it("forwards an initial filter to the agent picker", function()
    local AgentPicker = require("sidekick.cli.agent_picker")
    local original_open = AgentPicker.open
    local opened
    AgentPicker.open = function(items, opts)
      opened = { items = items, opts = opts }
    end
    local first = fake("attention-route", "codex", "Attention route", "waiting")
    Panel.show(first)

    Panel.pick({ filter = "attention" })

    AgentPicker.open = original_open
    assert.are.equal(first.id, opened.items[1].id)
    assert.are.same({ filter = "attention" }, opened.opts)
  end)

  it("persists agent selection frequency", function()
    local first = fake("persist-one", "codex", "Persisted")
    local saved = Util.get_state("cli-agent-selection")
    local agents = type(saved) == "table" and saved.agents or {}
    local previous = type(agents) == "table" and agents[first.id] or nil
    local previous_count = type(previous) == "table" and tonumber(previous.count) or 0

    Panel.show(first)

    saved = Util.get_state("cli-agent-selection")
    assert.is_true(type(saved) == "table")
    assert.is_true(type(saved.sequence) == "number")
    assert.is_true(type(saved.agents) == "table")
    assert.are.equal(previous_count + 1, tonumber(saved.agents[first.id].count))
    assert.is_true(saved.agents[first.id].last <= saved.sequence)
  end)

  it("updates window metadata when the active agent is removed", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    local win = Panel.win(second)

    Panel.remove(second.id)

    assert.are.equal(first, Panel.active())
    assert.are.equal(first.buf, vim.api.nvim_win_get_buf(win))
    assert.are.equal(first.tool.name, vim.w[win].sidekick_cli.name)
    assert.are.equal(first.id, vim.w[win].sidekick_session_id)
  end)

  it("does not hide the active panel when hiding an inactive agent", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    local win = Panel.win(second)

    Terminal.hide(first)

    assert.are.equal(win, Panel.win(second))
    assert.is_true(vim.api.nvim_win_is_valid(win))
  end)

  it("keeps a hidden panel hidden when its active agent is removed", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)
    Panel.hide()

    Panel.remove(second.id)

    local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
    assert.is_nil(p.win)
    assert.are.equal(first.id, p.active)
  end)

  it("hides every native-tab container showing an agent", function()
    local first = fake("one", "codex", "One")
    local first_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(first)

    vim.cmd.tabnew()
    local second_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(first)

    Terminal.hide(first)

    assert.is_nil(Panel.panels[first_tab].win)
    assert.is_nil(Panel.panels[second_tab].win)
    Panel.panels[second_tab] = nil
    vim.cmd.tabclose()
  end)

  it("keeps an independent container in each native tabpage", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    local first_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(first)
    local first_win = Panel.win(first)

    vim.cmd.tabnew()
    local second_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(second)
    local second_win = Panel.win(second)

    assert.are_not.equal(first_win, second_win)
    assert.are.same({ "one" }, Panel.panels[first_tab].order)
    assert.are.same({ "two" }, Panel.panels[second_tab].order)

    Panel.hide()
    Panel.panels[second_tab] = nil
    vim.cmd.tabclose()
  end)

  it("resolves scrollback against the panel in the current native tabpage", function()
    local first = fake("one", "codex", "One")
    first.window = Terminal.window
    first.is_open = Terminal.is_open
    local first_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(first)
    local first_win = Panel.win(first)

    vim.cmd.tabnew()
    local second_tab = vim.api.nvim_get_current_tabpage()
    Panel.show(first)
    assert.are_not.equal(first_win, first.win)

    vim.api.nvim_set_current_tabpage(first_tab)
    local scroll_buf = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = scroll_buf
    Panel.set_buf(first_win, scroll_buf)
    local scrollback = setmetatable({
      terminal = function()
        return first
      end,
      buf = scroll_buf,
    }, { __index = Scrollback })

    assert.is_true(scrollback:is_open())

    Panel.set_buf(first_win, first.buf)
    vim.api.nvim_set_current_tabpage(second_tab)
    Panel.hide()
    Panel.panels[second_tab] = nil
    vim.cmd.tabclose()
  end)

  it("routes actions to the active agent without opening a picker", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "codex", "Two")
    Session._attached[first.id] = first
    Session._attached[second.id] = second
    Panel.show(first)
    Panel.show(second)

    local selected
    State.with(function(state)
      selected = state.session
    end, { attach = true })

    vim.wait(1000, function()
      return selected ~= nil
    end)
    assert.are.equal(second, selected)
  end)

  it("syncs custom bufferline command mappings into the agent buffer", function()
    vim.keymap.set("n", "g]", "<cmd>BufferLineCycleNext<cr>", { desc = "custom bufferline next" })
    local first = fake("one", "codex", "One")
    Panel.show(first)

    local maps = vim.api.nvim_buf_get_keymap(first.buf, "n")
    assert.is_true(vim.iter(maps):any(function(map)
      return map.lhs == "g]" and map.desc == "Sidekick agent: next"
    end))
    vim.keymap.del("n", "g]")

    vim.keymap.set("n", "g[", "<cmd>BufferLineCycleNext<cr>", { desc = "replacement bufferline next" })
    Panel.keys(first.buf)
    maps = vim.api.nvim_buf_get_keymap(first.buf, "n")
    assert.is_false(vim.iter(maps):any(function(map)
      return map.lhs == "g]"
    end))
    assert.is_true(vim.iter(maps):any(function(map)
      return map.lhs == "g[" and map.desc == "Sidekick agent: next"
    end))
    vim.keymap.del("n", "g[")
  end)

  it("keeps explicit agent-local mappings over BufferLine mappings", function()
    vim.keymap.set("n", "g]", "<cmd>BufferLineCycleNext<cr>", { desc = "custom bufferline next" })
    local first = fake("one", "codex", "One")
    vim.keymap.set("n", "g]", "<nop>", { buffer = first.buf, desc = "tool mapping" })

    Panel.show(first)

    local map = vim.iter(vim.api.nvim_buf_get_keymap(first.buf, "n")):find(function(km)
      return km.lhs == "g]"
    end)
    assert.are.equal("tool mapping", map.desc)
    vim.keymap.del("n", "g]")
  end)

  it("does not replace a custom winbar when agent tabs are disabled", function()
    local old = Config.cli.win.tabs.enabled
    Config.cli.win.tabs.enabled = false
    local first = fake("one", "codex", "One")
    Panel.show(first)
    local win = Panel.win(first)
    vim.wo[win].winbar = "CUSTOM"

    Panel.refresh()

    Config.cli.win.tabs.enabled = old
    assert.are.equal("CUSTOM", vim.wo[win].winbar)
  end)

  it("restores absolute float geometry after moving the container", function()
    local first = fake("one", "codex", "One")
    Panel.show(first)
    Panel.move("float")
    Panel.resize({ width = 20, height = 5, row = 1, col = 1 })
    Panel.move("right")
    Panel.move("float")

    local cfg = vim.api.nvim_win_get_config(Panel.win(first))
    assert.are.equal(20, cfg.width)
    assert.are.equal(5, cfg.height)
    assert.are.equal(1, cfg.row)
    assert.are.equal(1, cfg.col)
  end)

  it("shows icons in the panel layout picker", function()
    local old_provider = Config.cli.agent_picker.provider
    local old_select = vim.ui.select
    local seen_items
    local seen_opts
    Config.cli.agent_picker.provider = "native"
    local select_callback
    vim.ui.select = function(items, opts, cb)
      seen_items = items
      seen_opts = opts
      select_callback = cb
    end

    local first = fake("layout-picker", "codex", "Layout picker")
    Panel.show(first)
    Panel.move()
    select_callback(seen_items[5])

    Config.cli.agent_picker.provider = old_provider
    vim.ui.select = old_select
    assert.are.same(
      { "left", "right", "top", "bottom", "float" },
      vim.tbl_map(function(item)
        return item.value
      end, seen_items)
    )
    assert.matches("^← Left$", seen_opts.format_item(seen_items[1]))
    assert.matches("^□ Float$", seen_opts.format_item(seen_items[5]))
    assert.are.equal("float", Panel.layout())
  end)

  it("preserves layout icons in the Snacks picker formatter", function()
    local Snacks = require("snacks")
    local old_provider = Config.cli.agent_picker.provider
    local old_select = Snacks.picker.select
    local seen_items
    local seen_opts
    Config.cli.agent_picker.provider = "snacks"
    Snacks.picker.select = function(items, opts)
      seen_items = items
      seen_opts = opts
    end

    local first = fake("layout-picker-snacks", "codex", "Layout picker Snacks")
    Panel.show(first)
    Panel.move()

    Config.cli.agent_picker.provider = old_provider
    Snacks.picker.select = old_select
    assert.are.same({ { "← ", "Special" }, { "Left" } }, seen_opts.format_item(seen_items[1], true))
    assert.are.same({ { "□ ", "Special" }, { "Float" } }, seen_opts.format_item(seen_items[5], true))
  end)

  it("restores tab order and pin state", function()
    local first = fake("order-one", "codex", "One")
    local second = fake("order-two", "codex", "Two")
    Panel.show(first)
    Panel.show(second)
    Panel.reorder(-1)
    Panel.pin()

    Panel.hide()
    Panel.panels[vim.api.nvim_get_current_tabpage()] = nil
    Panel.show(first)
    Panel.show(second)

    local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
    assert.are.same({ second.id, first.id }, p.order)
    assert.is_true(p.pinned[second.id])
  end)

  it("places a remembered tab before a new tab during restore", function()
    local first = fake("remembered", "codex", "Remembered")
    local second = fake("new", "codex", "New")
    Panel.show(first)
    Panel.hide()
    Panel.panels[vim.api.nvim_get_current_tabpage()] = nil

    Panel.show(second)
    Panel.show(first)

    local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
    assert.are.same({ first.id, second.id }, p.order)
  end)

  it("remembers the last panel layout", function()
    local first = fake("remember-layout", "codex", "Remember layout")

    Panel.show(first)
    Panel.move("float")

    assert.are.equal("float", Util.get_state("cli-panel-layout"))

    Panel.hide()
    Panel.panels[vim.api.nvim_get_current_tabpage()] = nil
    local second = fake("remember-layout-next", "codex", "Remembered layout")
    Panel.show(second)
    assert.are.equal("float", Panel.layout())
  end)

  it("does not start a new agent when moving layout without an agent", function()
    local old_cli = package.loaded["sidekick.cli"]
    local calls = 0
    package.loaded["sidekick.cli"] = {
      new = function()
        calls = calls + 1
      end,
    }

    local ok, err = pcall(function()
      Panel.move("float")
      assert.are.equal(0, calls)
    end)

    package.loaded["sidekick.cli"] = old_cli
    if not ok then
      error(err)
    end
  end)

  it("rejects invalid resize dimensions without changing the panel", function()
    local first = fake("one", "codex", "One")
    Panel.show(first)
    local win = Panel.win(first)
    local width = vim.api.nvim_win_get_width(win)

    local ok = pcall(Panel.resize, { width = 0, height = -1 })

    assert.is_true(ok)
    assert.are.equal(width, vim.api.nvim_win_get_width(win))
  end)

  it("preserves explicit float window options", function()
    local first = fake("one", "codex", "One")
    first.opts = vim.deepcopy(Config.cli.win)
    first.opts.layout = "float"
    first.opts.float = {
      relative = "cursor",
      focusable = false,
      width = 20,
      height = 5,
      row = 1,
      col = 1,
    }

    Panel.show(first)

    local cfg = vim.api.nvim_win_get_config(Panel.win(first))
    assert.are.equal("win", cfg.relative) -- Neovim normalizes cursor-relative floats to their window.
    assert.is_false(cfg.focusable)
  end)

  it("closes a terminal whose buffer is wiped externally and activates its neighbor", function()
    local first = fake("one", "codex", "One")
    local second = fake("two", "claude", "Two")
    Panel.show(first)
    Panel.show(second)

    vim.api.nvim_buf_delete(second.buf, { force = true })
    vim.wait(1000, function()
      local win = Panel.win(first)
      return Panel.active() == first and win and vim.api.nvim_win_get_buf(win) == first.buf
    end)

    local win = Panel.win(first)
    assert.are.equal(first, Panel.active())
    assert.are.equal(first.id, vim.w[win].sidekick_session_id)
  end)
end)
