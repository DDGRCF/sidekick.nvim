local Config = require("sidekick.config")
local History = require("sidekick.cli.history")
local Util = require("sidekick.util")

local M = {}

local layout_state_key = "cli-panel-layout"
local tabs_state_key = "cli-panel-tabs"
local max_tab_history = 100
local layouts = { "left", "right", "top", "bottom", "float" }
local layout_options = {
  { value = "left", label = "Left", icon = "←" },
  { value = "right", label = "Right", icon = "→" },
  { value = "top", label = "Top", icon = "↑" },
  { value = "bottom", label = "Bottom", icon = "↓" },
  { value = "float", label = "Float", icon = "□" },
}

---@class sidekick.cli.Panel
---@field tab integer
---@field win? integer
---@field active? string
---@field previous? string
---@field order string[]
---@field pinned table<string, boolean>
---@field layout string
---@field opts? sidekick.win.Opts
---@field sizes table<string, {width?:integer,height?:integer,row?:integer,col?:integer}>
---@field has_remembered_layout boolean

M.panels = {} ---@type table<integer, sidekick.cli.Panel>
M.clicks = {} ---@type table<integer, {action:string,id?:string,tab?:integer}>
M.synced_keys = {} ---@type table<integer, table<string, string>>
M.did_setup = false

local activity_blink_ms = 1000 -- one-second phases keep the working marker readable
local activity_blink_timer
local activity_blink_on = true

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win) or false
end

---@param win integer
---@param buf integer
---@param winfixbuf boolean
local function set_window_buf(win, buf, winfixbuf)
  local ok, err
  vim.wo[win].winfixbuf = false
  ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  vim.wo[win].winfixbuf = winfixbuf
  if not ok then
    error(err, 0)
  end
end

---@param p sidekick.cli.Panel
---@param buf integer
local function set_panel_buf(p, buf)
  if valid(p.win) then
    set_window_buf(p.win, buf, true)
  end
end

---@param win integer
---@param buf integer
function M.set_buf(win, buf)
  if valid(win) then
    set_window_buf(win, buf, vim.wo[win].winfixbuf)
  end
end

---@param p sidekick.cli.Panel
local function close_window(p)
  if not valid(p.win) then
    p.win = nil
    return
  end
  local panel_float = vim.api.nvim_win_get_config(p.win).relative ~= ""
  local normal_wins = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.api.nvim_tabpage_list_wins(p.tab))
  if panel_float or #normal_wins > 1 then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if valid(p.win) then
    local replacement
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].filetype ~= "sidekick_terminal" then
        replacement = buf
        break
      end
    end
    replacement = replacement or vim.api.nvim_create_buf(true, false)
    set_window_buf(p.win, replacement, false)
    vim.wo[p.win].winbar = ""
    vim.w[p.win].sidekick_panel = nil
    vim.w[p.win].sidekick_cli = nil
    vim.w[p.win].sidekick_session_id = nil
  end
  p.win = nil
end

local function terminal(id)
  return id and require("sidekick.cli.terminal").get(id) or nil
end

local function stop_activity_blink()
  local timer = activity_blink_timer
  activity_blink_timer = nil
  activity_blink_on = true
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function has_visible_working_tab()
  if Config.cli.win.tabs.enabled == false or Config.cli.win.tabs.show_status == false then
    return false
  end
  for _, p in pairs(M.panels) do
    if valid(p.win) then
      for _, id in ipairs(p.order) do
        local t = terminal(id)
        if t and t.status == "working" then
          return true
        end
      end
    end
  end
  return false
end

local function update_activity_blink()
  if not has_visible_working_tab() then
    stop_activity_blink()
    return
  end
  if activity_blink_timer then
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  activity_blink_on = true
  activity_blink_timer = timer
  timer:start(activity_blink_ms, activity_blink_ms, function()
    vim.schedule(function()
      if activity_blink_timer ~= timer then
        return
      end
      if not has_visible_working_tab() then
        stop_activity_blink()
        M.refresh()
        return
      end
      activity_blink_on = not activity_blink_on
      M.refresh()
    end)
  end)
end

local function usable(id)
  local t = terminal(id)
  return t and t.buf and vim.api.nvim_buf_is_valid(t.buf) and t or nil
end

local function current_tab()
  return vim.api.nvim_get_current_tabpage()
end

---@param tab? integer
---@return string
function M.cwd(tab)
  tab = tab or current_tab()
  local function editor_window(win)
    return valid(win)
      and vim.api.nvim_win_get_tabpage(win) == tab
      and vim.api.nvim_win_get_config(win).relative == ""
      and not vim.w[win].sidekick_panel
  end
  local current = vim.api.nvim_get_current_win()
  if editor_window(current) then
    return vim.api.nvim_win_call(current, vim.fn.getcwd)
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if editor_window(win) then
      return vim.api.nvim_win_call(win, vim.fn.getcwd)
    end
  end
  return vim.fn.getcwd()
end

---@param value any
---@return boolean
local function valid_layout(value)
  return type(value) == "string" and vim.tbl_contains(layouts, value)
end

---@return string?
local function remembered_layout()
  local value = Util.get_state(layout_state_key)
  return valid_layout(value) and value or nil
end

---@return {order:string[],pinned:table<string,boolean>}
local function remembered_tabs()
  local value = Util.get_state(tabs_state_key)
  local order = {}
  local pinned = {}
  if type(value) ~= "table" then
    return { order = order, pinned = pinned }
  end
  if type(value.order) == "table" then
    for _, key in ipairs(value.order) do
      if type(key) == "string" and key ~= "" and not vim.list_contains(order, key) then
        order[#order + 1] = key
      end
    end
  end
  if type(value.pinned) == "table" then
    for key, is_pinned in pairs(value.pinned) do
      if type(key) == "string" and is_pinned == true then
        pinned[key] = true
      end
    end
  end
  return { order = order, pinned = pinned }
end

---@param create? boolean
---@return sidekick.cli.Panel?
local function panel(create)
  local tab = current_tab()
  local ret = M.panels[tab]
  if not ret and create then
    local saved = remembered_layout()
    ret = {
      tab = tab,
      order = {},
      pinned = {},
      layout = saved or Config.cli.win.layout,
      sizes = {},
      has_remembered_layout = saved ~= nil,
    }
    M.panels[tab] = ret
  end
  return ret
end

local function clean(p)
  p.order = vim.tbl_filter(function(id)
    local t = terminal(id)
    if t and not usable(id) and not t.closed and not t._sidekick_close_scheduled then
      t._sidekick_close_scheduled = true
      vim.schedule(function()
        if terminal(id) == t then
          t:close()
        end
      end)
    end
    return t ~= nil
  end, p.order)
  if p.active and not vim.list_contains(p.order, p.active) then
    p.active = p.order[1]
  end
end

---@param t sidekick.cli.Terminal
---@return string
local function agent_key(t)
  return History.agent_key(t)
end

---@param t sidekick.cli.Terminal
---@return string
function M.workspace_key(t)
  return t.sid or table.concat({ t.tool.name, t.cwd or "", t.instance_id or t.id }, "\31")
end

---@param p sidekick.cli.Panel
local function persist_tabs(p)
  local saved = remembered_tabs()
  local current = {} ---@type string[]
  local current_set = {} ---@type table<string,boolean>
  local pinned = saved.pinned

  for _, id in ipairs(p.order) do
    local t = terminal(id)
    local key = t and agent_key(t) or nil
    if key and key ~= "" and not current_set[key] then
      current_set[key] = true
      current[#current + 1] = key
      pinned[key] = p.pinned[id] == true or nil
    end
  end

  local retained = {} ---@type string[]
  local first_saved_index
  for _, key in ipairs(saved.order) do
    if current_set[key] then
      if not first_saved_index then
        first_saved_index = #retained + 1
      end
    else
      retained[#retained + 1] = key
    end
  end
  local insert_at = #retained + 1
  if first_saved_index then
    insert_at = first_saved_index
  end
  local order = {} ---@type string[]
  for index, key in ipairs(retained) do
    if index == insert_at then
      vim.list_extend(order, current)
    end
    order[#order + 1] = key
  end
  if insert_at > #retained then
    vim.list_extend(order, current)
  end
  if #order > max_tab_history then
    local dropped = #order - max_tab_history
    local trimmed = {} ---@type string[]
    for _, key in ipairs(order) do
      if dropped > 0 and not current_set[key] then
        dropped = dropped - 1
      else
        trimmed[#trimmed + 1] = key
      end
    end
    while #trimmed > max_tab_history do
      table.remove(trimmed, 1)
    end
    order = trimmed
  end
  local active = {} ---@type table<string,boolean>
  for _, key in ipairs(order) do
    active[key] = true
  end
  for key in pairs(pinned) do
    if not active[key] then
      pinned[key] = nil
    end
  end
  Util.set_state(tabs_state_key, { order = order, pinned = pinned })
end

---@param p sidekick.cli.Panel
---@param t sidekick.cli.Terminal
local function add_ordered(p, t)
  local saved = remembered_tabs()
  local ranks = {} ---@type table<string,integer>
  for index, key in ipairs(saved.order) do
    ranks[key] = index
  end

  local key = agent_key(t)
  local target = ranks[key]
  local index = #p.order + 1
  if target then
    for i, id in ipairs(p.order) do
      local current = terminal(id)
      local rank = current and ranks[agent_key(current)] or nil
      if not rank or rank > target then
        index = i
        break
      end
    end
  end
  table.insert(p.order, index, t.id)
  p.pinned[t.id] = saved.pinned[key] == true or nil
end

local function contains(list, value)
  return vim.list_contains(list, value)
end

local function escape(value)
  return tostring(value):gsub("%%", "%%%%")
end

local separator_styles = {
  thin = { "▏", "▕" },
  thick = { "▌", "▐" },
  slant = { "", "" },
  slope = { "", "" },
  padded_slant = { " ", " " },
  padded_slope = { " ", " " },
}

local function separators()
  local style = Config.cli.win.tabs.separator_style
  if type(style) == "table" then
    return style.left or "▏", style.right or "▕"
  end
  local ret = separator_styles[style] or separator_styles.thin
  return ret[1], ret[2]
end

---@param value string
---@param max_width integer
---@return string
local function truncate_text(value, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.api.nvim_strwidth(value) <= max_width then
    return value
  end
  local ellipsis = "…"
  if vim.api.nvim_strwidth(ellipsis) > max_width then
    return ""
  end
  local ret = ""
  for _, char in ipairs(Util.split_graphemes(value)) do
    local next = ret .. char
    if vim.api.nvim_strwidth(next .. ellipsis) > max_width then
      break
    end
    ret = next
  end
  return ret .. ellipsis
end

---@param t sidekick.cli.Terminal
---@return string
local function raw_title(t)
  local value = t.title or t.tool.name
  return tostring(value):gsub("[%c\r\n]+", " ")
end

---@param t sidekick.cli.Terminal
---@return string
local function cwd_text(t)
  if Config.cli.win.tabs.show_cwd ~= true or type(t.cwd) ~= "string" or t.cwd == "" then
    return ""
  end
  local cwd = vim.fn.fnamemodify(t.cwd, ":~")
  return cwd ~= "" and (" · " .. cwd) or ""
end

---@param t sidekick.cli.Terminal
---@param max_width? integer
---@param suffix? string
local function title_text(t, max_width, suffix)
  local value = raw_title(t)
  local suffix_text = suffix and suffix ~= "" and (" · " .. suffix) or ""
  local width = max_width or Config.cli.win.tabs.max_name_length
  if suffix_text ~= "" then
    local suffix_width = vim.api.nvim_strwidth(suffix_text)
    if suffix_width >= width then
      return truncate_text(suffix, width)
    end
    return truncate_text(value .. cwd_text(t), width - suffix_width) .. suffix_text
  end
  return truncate_text(value .. cwd_text(t), width)
end

---@param items {id:string,t:sidekick.cli.Terminal}[]
---@return table<string,string>
local function duplicate_suffixes(items)
  local counts = {} ---@type table<string,integer>
  for _, item in ipairs(items) do
    local key = raw_title(item.t)
    counts[key] = (counts[key] or 0) + 1
  end
  local ret = {} ---@type table<string,string>
  for _, item in ipairs(items) do
    local key = raw_title(item.t)
    if counts[key] > 1 then
      local id = tostring(item.t.instance_id or item.t.sid or item.t.id or "")
      ret[item.id] = "#" .. id:sub(-8)
    end
  end
  return ret
end

---@param t sidekick.cli.Terminal
---@param value? string
local function title(t, value)
  return escape(value or title_text(t))
end

local function agent_icon_text(t)
  local icons = Config.cli.win.tabs.icons
  return icons[t.tool.name] or icons.default or t.tool.name
end

local function agent_icon(t)
  return escape(agent_icon_text(t))
end

local tool_highlights = {
  antigravity = "SidekickCliToolAntigravity",
  claude = "SidekickCliToolClaude",
  codex = "SidekickCliToolCodex",
  copilot = "SidekickCliToolCopilot",
  crush = "SidekickCliToolCrush",
  cursor = "SidekickCliToolCursor",
  grok = "SidekickCliToolGrok",
  opencode = "SidekickCliToolOpencode",
  pi = "SidekickCliToolPi",
  qwen = "SidekickCliToolQwen",
}

local function tool_highlight(t)
  return tool_highlights[t.tool.name] or "SidekickCliTool"
end

local function agent_marker_text()
  local icon = Config.ui.icons.installed
  return type(icon) == "string" and vim.trim(icon) or ""
end

local function agent_marker()
  return escape(agent_marker_text())
end

local function icon_text(name, fallback)
  local icon = Config.ui.icons[name]
  return type(icon) == "string" and vim.trim(icon) or fallback
end

local function pin_icon_text()
  return icon_text("pin", "󰐃")
end

local function close_icon_text()
  return icon_text("close", "")
end

local function status_icon_text(t)
  if Config.cli.win.tabs.show_status == false then
    return ""
  end
  local status = t.status or "idle"
  if status == "working" and not activity_blink_on then
    return Config.cli.win.tabs.status.idle or "○"
  end
  return Config.cli.win.tabs.status[status] or "○"
end

local function status_icon(t)
  return escape(status_icon_text(t))
end

local function attention_text(t)
  if Config.cli.win.tabs.show_attention == false or t._sidekick_unread ~= true then
    return ""
  end
  local icon = Config.ui.icons.unread
  return type(icon) == "string" and vim.trim(icon) or "•"
end

local function attention(t)
  return escape(attention_text(t))
end

local function priority(t, pinned)
  return pinned
    or t._sidekick_unread == true
    or t.status == "starting"
    or t.status == "working"
    or t.status == "waiting"
    or t.status == "error"
end

local function click(action, p, id)
  local token = #M.clicks + 1
  M.clicks[token] = { action = action, id = id, tab = p.tab }
  return ("%%%d@v:lua.SidekickCliTabClick@"):format(token)
end

local function truncation_marker(count)
  return count > 0 and (" …%d "):format(count) or ""
end

---@param p sidekick.cli.Panel
---@param t sidekick.cli.Terminal
---@param left_separator string
---@param right_separator string
---@param title_value? string
local function tab_width(p, t, left_separator, right_separator, title_value)
  local marker = agent_marker_text()
  local text = " "
    .. (marker ~= "" and (marker .. " ") or "")
    .. agent_icon_text(t)
    .. status_icon_text(t)
    .. ": "
    .. (attention_text(t) ~= "" and (attention_text(t) .. " ") or "")
    .. (title_value or title_text(t))
  if p.pinned[t.id] then
    text = text .. " " .. pin_icon_text()
  end
  text = text .. " "
  if Config.cli.win.tabs.show_close then
    text = text .. close_icon_text() .. " "
  end
  return vim.api.nvim_strwidth(left_separator .. text .. right_separator)
end

---@param items {id:string,t:sidekick.cli.Terminal,width:integer,min_width:integer,priority:boolean}[]
---@param visible table<integer,boolean>
---@param width_field? string
---@return integer
local function visible_width(items, visible, width_field)
  local width, hidden = 0, 0
  for index, item in ipairs(items) do
    if visible[index] then
      if hidden > 0 then
        width = width + vim.api.nvim_strwidth(truncation_marker(hidden))
        hidden = 0
      end
      width = width + item[width_field or "width"]
    else
      hidden = hidden + 1
    end
  end
  if hidden > 0 then
    width = width + vim.api.nvim_strwidth(truncation_marker(hidden))
  end
  return width
end

---@param items {id:string,t:sidekick.cli.Terminal,width:integer,min_width:integer,priority:boolean}[]
---@param active integer
---@param available integer
---@return table<integer,boolean>
local function visible_range(items, active, available)
  local has_priority = false
  for index, item in ipairs(items) do
    if index ~= active and item.priority then
      has_priority = true
      break
    end
  end

  -- Keep the established contiguous layout when there is no attention state
  -- to surface. This avoids making quiet tabs jump around as the panel width
  -- changes, while the priority path below can deliberately surface work
  -- that would otherwise be hidden behind an overflow marker.
  if not has_priority then
    local left, right, hidden_left, hidden_right = 1, #items, 0, 0
    local function range_width()
      local width = vim.api.nvim_strwidth(truncation_marker(hidden_left))
        + vim.api.nvim_strwidth(truncation_marker(hidden_right))
      for index = left, right do
        width = width + items[index].width
      end
      return width
    end
    while range_width() > available do
      local can_left = left < active
      local can_right = right > active
      if not can_left and not can_right then
        break
      end
      local left_width
      if can_left then
        left_width = vim.api.nvim_strwidth(truncation_marker(hidden_left + 1))
          + vim.api.nvim_strwidth(truncation_marker(hidden_right))
        for index = left + 1, right do
          left_width = left_width + items[index].width
        end
      end
      local right_width
      if can_right then
        right_width = vim.api.nvim_strwidth(truncation_marker(hidden_left))
          + vim.api.nvim_strwidth(truncation_marker(hidden_right + 1))
        for index = left, right - 1 do
          right_width = right_width + items[index].width
        end
      end
      if left_width and right_width then
        if left_width <= right_width then
          left, hidden_left = left + 1, hidden_left + 1
        else
          right, hidden_right = right - 1, hidden_right + 1
        end
      elseif left_width then
        left, hidden_left = left + 1, hidden_left + 1
      else
        right, hidden_right = right - 1, hidden_right + 1
      end
    end
    if range_width() > available then
      left, right, hidden_left, hidden_right = active, active, 0, 0
    end
    local visible = {}
    for index = left, right do
      visible[index] = true
    end
    return visible
  end

  local visible = { [active] = true }
  local candidates = {}
  for index, item in ipairs(items) do
    if index ~= active then
      candidates[#candidates + 1] = {
        index = index,
        priority = item.priority == true,
        distance = math.abs(index - active),
      }
    end
  end
  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then
      return a.priority
    end
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.index < b.index
  end)

  for _, candidate in ipairs(candidates) do
    visible[candidate.index] = true
    if visible_width(items, visible, "min_width") > available then
      visible[candidate.index] = nil
    end
  end
  return visible
end

---@param items {id:string,t:sidekick.cli.Terminal,width:integer,min_width:integer,priority:boolean}[]
---@param visible table<integer,boolean>
---@param available integer
---@param titles table<string,string>
---@param suffixes table<string,string>
---@return table<integer,string>
local function compact_titles(items, visible, available, titles, suffixes)
  local values = {}
  if visible_width(items, visible) <= available then
    for index, item in ipairs(items) do
      if visible[index] then
        values[index] = titles[item.id]
      end
    end
    return values
  end

  local remaining = math.max(0, available - visible_width(items, visible, "min_width"))
  local visible_count = vim.tbl_count(visible)
  for index, item in ipairs(items) do
    if visible[index] then
      local desired = vim.api.nvim_strwidth(titles[item.id])
      local share = visible_count > 0 and math.floor(remaining / visible_count) or 0
      local width = math.min(desired, share)
      values[index] = title_text(item.t, width, suffixes[item.id])
      remaining = math.max(0, remaining - vim.api.nvim_strwidth(values[index]))
      visible_count = visible_count - 1
    end
  end
  return values
end

---@param p sidekick.cli.Panel
---@param t sidekick.cli.Terminal
---@param left_separator string
---@param right_separator string
---@param title_value? string
local function render_tab(p, t, left_separator, right_separator, title_value)
  local parts = {} ---@type string[]
  local selected = t.id == p.active
  local base = selected and "SidekickCliTabSelected" or "SidekickCliTab"
  local state = (t.status or "idle"):gsub("^%l", string.upper)
  local marker = agent_marker_text()
  local tool_hl = selected and tool_highlight(t) or base
  local marker_hl = selected and "SidekickCliInstalled" or base
  if selected then
    parts[#parts + 1] = "%<"
  end
  parts[#parts + 1] = ("%%#SidekickCliTabSeparator#%s"):format(escape(left_separator))
  parts[#parts + 1] = click("select", p, t.id)
  if marker ~= "" then
    parts[#parts + 1] = ("%%#%s# %s "):format(marker_hl, agent_marker())
  end
  parts[#parts + 1] = ("%%#%s#%s%s"):format(tool_hl, marker == "" and " " or "", agent_icon(t))
  parts[#parts + 1] = ("%%#SidekickCliStatus%s#%s"):format(state, status_icon(t))
  if attention_text(t) ~= "" then
    parts[#parts + 1] = ("%%#SidekickCliAttention#%s "):format(attention(t))
  end
  parts[#parts + 1] = ("%%#%s#: %s"):format(base, title(t, title_value))
  if p.pinned[t.id] then
    parts[#parts + 1] = ("%%#SidekickCliPin# %s"):format(pin_icon_text())
  end
  parts[#parts + 1] = " "
  parts[#parts + 1] = "%T"
  if Config.cli.win.tabs.show_close then
    parts[#parts + 1] = click("close", p, t.id)
    local close_hl = selected and base or "SidekickCliClose"
    parts[#parts + 1] = ("%%#%s#%s %%T"):format(close_hl, close_icon_text())
  end
  parts[#parts + 1] = ("%%#SidekickCliTabSeparator#%s"):format(escape(right_separator))
  return table.concat(parts)
end

---@param count integer
---@param p sidekick.cli.Panel
local function render_truncation(count, p)
  if count == 0 then
    return ""
  end
  return click("pick", p) .. ("%%#SidekickCliTabSeparator#%s%%T"):format(escape(truncation_marker(count)))
end

---@param p sidekick.cli.Panel
function M.render(p)
  if not valid(p.win) or not Config.cli.win.tabs.enabled then
    return ""
  end
  clean(p)
  local parts = {} ---@type string[]
  local left_separator, right_separator = separators()
  local items = {} ---@type {id:string,t:sidekick.cli.Terminal,width:integer,min_width:integer,priority:boolean}[]
  for _, id in ipairs(p.order) do
    local t = terminal(id)
    if t then
      items[#items + 1] = {
        id = id,
        t = t,
        width = 0,
        min_width = 0,
        priority = priority(t, p.pinned[id] == true),
      }
    end
  end
  local suffixes = duplicate_suffixes(items)
  local titles = {} ---@type table<string,string>
  for _, item in ipairs(items) do
    titles[item.id] = title_text(item.t, nil, suffixes[item.id])
    item.width = tab_width(p, item.t, left_separator, right_separator, titles[item.id])
    item.min_width = tab_width(p, item.t, left_separator, right_separator, "")
  end

  local active = 1
  for i, item in ipairs(items) do
    if item.id == p.active then
      active = i
      break
    end
  end
  local visible = {}
  local available
  local title_values = {}
  if #items > 0 then
    available = math.max(1, vim.api.nvim_win_get_width(p.win) - vim.api.nvim_strwidth("+ "))
    visible = visible_range(items, active, available)
    title_values = compact_titles(items, visible, available, titles, suffixes)
  end
  local hidden = 0
  for index, item in ipairs(items) do
    if visible[index] then
      parts[#parts + 1] = render_truncation(hidden, p)
      hidden = 0
      local title_value = title_values[index] ~= nil and title_values[index] or titles[item.id]
      parts[#parts + 1] = render_tab(p, item.t, left_separator, right_separator, title_value)
    else
      hidden = hidden + 1
    end
  end
  parts[#parts + 1] = render_truncation(hidden, p)
  parts[#parts + 1] = "%="
  parts[#parts + 1] = click("new", p)
  parts[#parts + 1] = "%#SidekickCliTab#+ %T"
  return table.concat(parts)
end

---@param p sidekick.cli.Panel
local function refresh_panel(p)
  clean(p)
  if valid(p.win) and Config.cli.win.tabs.enabled then
    vim.wo[p.win].winbar = M.render(p)
  end
end

local function close_duplicate_window()
  local p = panel()
  if not p or not valid(p.win) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if win == p.win or not valid(win) then
    return
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  if vim.api.nvim_win_get_buf(win) == vim.api.nvim_win_get_buf(p.win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param id? string
function M.refresh(_)
  M.clicks = {}
  update_activity_blink()
  for tab, p in pairs(M.panels) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      M.panels[tab] = nil
    else
      refresh_panel(p)
    end
  end
end

---@param p sidekick.cli.Panel
---@param buf integer
local function open(p, buf)
  if valid(p.win) then
    set_panel_buf(p, buf)
    return
  end
  local base = p.opts or Config.cli.win
  local layout = p.layout
  local is_float = layout == "float"
  local opts = vim.deepcopy(is_float and base.float or base.split) ---@type vim.api.keyset.win_config
  local saved = p.sizes[layout]
  opts = vim.tbl_extend("force", opts, saved or {})
  if is_float then
    opts.relative = opts.relative or "editor"
    opts.style = opts.style or "minimal"
    opts.focusable = opts.focusable == nil and true or opts.focusable
    opts.width = not saved and opts.width <= 1 and math.floor(vim.o.columns * opts.width) or opts.width
    opts.height = not saved and opts.height <= 1 and math.floor(vim.o.lines * opts.height) or opts.height
    opts.width = math.max(20, math.min(opts.width, vim.o.columns - 2))
    opts.height = math.max(5, math.min(opts.height, vim.o.lines - 2))
    opts.row = opts.row == nil and math.floor((vim.o.lines - opts.height) / 2)
      or not saved and opts.row <= 1 and math.floor((vim.o.lines - opts.height) * opts.row)
      or opts.row
    opts.col = opts.col == nil and math.floor((vim.o.columns - opts.width) / 2)
      or not saved and opts.col <= 1 and math.floor((vim.o.columns - opts.width) * opts.col)
      or opts.col
    opts.title = opts.title or " Sidekick Agents "
    opts.title_pos = opts.title_pos or "center"
    opts.border = opts.border or "rounded"
  else
    opts.style = opts.style or "minimal"
    opts.split = ({ top = "above", left = "left", bottom = "below", right = "right" })[layout]
    opts.win = opts.win == nil and -1 or opts.win
    opts.width = opts.width and opts.width > 0 and opts.width or nil
    opts.height = opts.height and opts.height > 0 and opts.height or nil
  end
  local function create()
    p.win = vim.api.nvim_open_win(buf, false, opts)
  end
  local target = vim.api.nvim_tabpage_list_wins(p.tab)[1]
  if p.tab ~= current_tab() and target and valid(target) then
    vim.api.nvim_win_call(target, create)
  else
    create()
  end
  vim.wo[p.win].winfixwidth = layout == "left" or layout == "right"
  vim.wo[p.win].winfixheight = layout == "top" or layout == "bottom"
  vim.wo[p.win].winfixbuf = true
  vim.w[p.win].sidekick_panel = true
end

---@param p sidekick.cli.Panel
---@param t sidekick.cli.Terminal
local function activate_window(p, t)
  if not valid(p.win) then
    return
  end
  set_panel_buf(p, t.buf)
  vim.w[p.win].sidekick_cli = t.tool
  vim.w[p.win].sidekick_session_id = t.id
  t.win = p.win -- backwards compatibility for window callbacks
  t:wo()
  M.keys(t.buf)
end

---@param t sidekick.cli.Terminal
---@param focus? boolean
function M.show(t, focus)
  if not (t.buf and vim.api.nvim_buf_is_valid(t.buf)) then
    return t
  end
  local p = panel(true) --[[@as sidekick.cli.Panel]]
  clean(p)
  if #p.order == 0 and t.opts then
    p.opts = vim.deepcopy(t.opts)
    if not p.has_remembered_layout or t.opts.layout ~= Config.cli.win.layout then
      p.layout = t.opts.layout
    end
  end
  if not contains(p.order, t.id) then
    add_ordered(p, t)
    persist_tabs(p)
  end
  local changed = p.active ~= t.id
  if changed then
    p.previous, p.active = p.active, t.id
    History.record("agents", History.agent_key(t))
  end
  local buf = t.buf --[[@as integer]]
  open(p, buf)
  activate_window(p, t)
  Config.set_hl()
  if changed or focus then
    require("sidekick.cli.activity").ack(t)
  end
  M.refresh()
  if changed then
    Util.emit("SidekickCliActivate", { id = t.id, tab = p.tab })
  end
  if focus then
    vim.api.nvim_set_current_win(p.win)
    vim.cmd.startinsert()
    t.normal_mode = false
  end
  return t
end

local function hide_panel(p)
  if vim.api.nvim_get_current_win() == p.win then
    vim.cmd.wincmd("p")
    vim.cmd.stopinsert()
  end
  close_window(p)
end

---@param t? sidekick.cli.Terminal
function M.hide(t)
  if t then
    for _, p in pairs(M.panels) do
      if p.active == t.id and valid(p.win) then
        hide_panel(p)
      end
    end
    update_activity_blink()
    return
  end
  local p = panel()
  if p and valid(p.win) then
    hide_panel(p)
  end
  update_activity_blink()
end

---@param t? sidekick.cli.Terminal
function M.win(t)
  local p = panel()
  return p and valid(p.win) and (not t or p.active == t.id) and p.win or nil
end

function M.active()
  local p = panel()
  clean(p or { order = {} })
  return p and usable(p.active) or nil
end

function M.layout()
  local p = panel()
  return p and p.layout or Config.cli.win.layout
end

---@param id string
---@param focus? boolean
function M.select(id, focus)
  local t = usable(id)
  if t then
    require("sidekick.cli.activity").ack(t)
    M.show(t, focus)
  end
end

---@param step integer
function M.cycle(step)
  local p = panel()
  if not p then
    return
  end
  clean(p)
  local idx = vim.fn.index(p.order, p.active)
  if idx >= 0 and #p.order > 1 then
    M.select(p.order[((idx + step) % #p.order) + 1])
  end
end

function M.previous()
  local p = panel()
  if p and p.previous and terminal(p.previous) then
    M.select(p.previous)
  end
end

---@param step integer
function M.reorder(step)
  local p = panel()
  if not p then
    return
  end
  local idx = vim.fn.index(p.order, p.active) + 1
  local to = math.max(1, math.min(#p.order, idx + step))
  if idx > 0 and idx ~= to then
    local id = table.remove(p.order, idx)
    table.insert(p.order, to, id)
    persist_tabs(p)
    M.refresh()
    Util.emit("SidekickCliPanel", { tab = p.tab, order = vim.deepcopy(p.order) })
  end
end

---@param id? string
function M.pin(id)
  local p = panel()
  id = id or (p and p.active)
  if p and id and contains(p.order, id) then
    p.pinned[id] = not p.pinned[id] or nil
    persist_tabs(p)
    M.refresh()
    Util.emit("SidekickCliPanel", { tab = p.tab, pinned = vim.deepcopy(p.pinned) })
  end
end

---@param id? string
function M.close(id)
  local t = terminal(id or (panel() or {}).active)
  if t then
    t:close()
  end
end

---@param id string
function M.remove(id)
  for _, p in pairs(M.panels) do
    local idx = vim.fn.index(p.order, id) + 1
    if idx > 0 then
      table.remove(p.order, idx)
      p.pinned[id] = nil
      if p.active == id then
        p.previous = id
        p.active = p.order[math.min(idx, #p.order)] or p.order[#p.order]
        local next = terminal(p.active)
        if next then
          if valid(p.win) then
            activate_window(p, next)
          elseif p.win ~= nil then
            open(p, next.buf)
            activate_window(p, next)
          end
          Util.emit("SidekickCliActivate", { id = next.id, tab = p.tab })
        elseif valid(p.win) then
          close_window(p)
        end
      end
      persist_tabs(p)
    end
  end
  M.refresh()
end

---@param which "others"|"left"|"right"|"unpinned"|"invisible"
function M.close_many(which)
  local p = panel()
  if not p then
    return
  end
  local active = vim.fn.index(p.order, p.active) + 1
  local ids = {} ---@type string[]
  if which == "invisible" then
    for id in pairs(require("sidekick.cli.terminal").terminals) do
      if not contains(p.order, id) then
        ids[#ids + 1] = id
      end
    end
  else
    for i, id in ipairs(vim.deepcopy(p.order)) do
      local close = which == "others" and id ~= p.active
        or which == "left" and i < active
        or which == "right" and i > active
        or which == "unpinned" and not p.pinned[id]
      if close then
        ids[#ids + 1] = id
      end
    end
  end
  for _, id in ipairs(ids) do
    M.close(id)
  end
end

function M.close_panel()
  M.close()
  M.hide()
end

---@return {id:string,label:string,key:string,terminal:sidekick.cli.Terminal,unread:boolean}[]
function M.picker_items()
  local p = panel()
  if not p then
    return {}
  end
  clean(p)
  local items = {} ---@type {id:string,label:string,key:string,unread:boolean}[]
  local tab_items = {} ---@type {id:string,t:sidekick.cli.Terminal}[]
  for _, id in ipairs(p.order) do
    local t = terminal(id)
    if t then
      tab_items[#tab_items + 1] = { id = id, t = t }
    end
  end
  local suffixes = duplicate_suffixes(tab_items)
  for _, item in ipairs(tab_items) do
    local t = item.t
    local status = status_icon(t)
    -- The installed marker is useful beside the activity icon in the panel,
    -- but becomes a confusing spacer when activity icons are disabled.
    local prefix = Config.cli.win.tabs.show_status == false and "" or agent_marker()
    prefix = prefix ~= "" and (prefix .. " ") or ""
    prefix = prefix .. agent_icon(t) .. (status ~= "" and (" " .. status) or "")
    items[#items + 1] = {
      id = item.id,
      label = ("%s: %s"):format(prefix, title_text(t, nil, suffixes[item.id])),
      key = agent_key(t),
      terminal = t,
      unread = t._sidekick_unread == true,
    }
  end
  History.sort(items, "agents", function(item)
    return item.key
  end)
  return items
end

function M.pick()
  require("sidekick.cli.agent_picker").open(M.picker_items())
end

local function pick_layout()
  local select = vim.ui.select
  local ok, Snacks = pcall(require, "snacks")
  if Config.cli.picker == "snacks" and ok and Snacks.picker and Snacks.picker.select then
    select = Snacks.picker.select
  end
  select(layout_options, {
    prompt = "Select panel layout:",
    kind = "sidekick_cli_layout",
    format_item = function(item)
      return ("%s %s"):format(item.icon, item.label)
    end,
  }, function(item)
    if item then
      M.move(item.value)
    end
  end)
end

---@param value? string|{layout?:string}
function M.move(value)
  local layout = type(value) == "table" and value.layout or value --[[@as string?]]
  if not layout then
    return pick_layout()
  end
  if not valid_layout(layout) then
    return Util.error("Invalid Sidekick panel layout: " .. tostring(layout))
  end
  local p = panel(true)
  if not p then
    return
  end
  p.layout = layout
  p.has_remembered_layout = true
  Util.set_state(layout_state_key, layout)
  Util.emit("SidekickCliPanel", { tab = p.tab, layout = layout })
  clean(p)
  local active = usable(p.active)
  if active then
    local was_focused = valid(p.win) and vim.api.nvim_get_current_win() == p.win
    M.hide()
    M.show(active, was_focused)
  end
end

---@param opts? {width?:integer,height?:integer,row?:integer,col?:integer}
function M.resize(opts)
  opts = opts or {}
  local p = panel()
  if not p or not valid(p.win) then
    return
  end
  for _, key in ipairs({ "width", "height" }) do
    local value = opts[key]
    if value ~= nil and (type(value) ~= "number" or value < 1 or value % 1 ~= 0) then
      return Util.error(("Sidekick panel %s must be a positive integer"):format(key))
    end
  end
  local size = vim.deepcopy(p.sizes[p.layout] or {})
  local ok, err
  if p.layout == "float" then
    local cfg = vim.api.nvim_win_get_config(p.win)
    size.width = opts.width or cfg.width
    size.height = opts.height or cfg.height
    size.row = opts.row or tonumber(cfg.row) or 0
    size.col = opts.col or tonumber(cfg.col) or 0
    ok, err = pcall(vim.api.nvim_win_set_config, p.win, vim.tbl_extend("force", cfg, size))
  elseif p.layout == "left" or p.layout == "right" then
    size.width = opts.width or vim.api.nvim_win_get_width(p.win)
    ok, err = pcall(vim.api.nvim_win_set_width, p.win, size.width)
  else
    size.height = opts.height or vim.api.nvim_win_get_height(p.win)
    ok, err = pcall(vim.api.nvim_win_set_height, p.win, size.height)
  end
  if not ok then
    return Util.error("Failed to resize Sidekick panel: " .. tostring(err))
  end
  p.sizes[p.layout] = size
  M.refresh()
  Util.emit("SidekickCliPanel", { tab = p.tab, layout = p.layout, size = size })
end

---@param dw integer
---@param dh integer
function M.adjust(dw, dh)
  local p = panel()
  if not p or not valid(p.win) then
    return
  end
  if p.layout == "float" then
    M.resize({
      width = math.max(20, vim.api.nvim_win_get_width(p.win) + dw),
      height = math.max(5, vim.api.nvim_win_get_height(p.win) + dh),
    })
  elseif p.layout == "left" or p.layout == "right" then
    M.resize({ width = math.max(20, vim.api.nvim_win_get_width(p.win) + dw) })
  else
    M.resize({ height = math.max(5, vim.api.nvim_win_get_height(p.win) + dh) })
  end
end

---@param value? string|{title?:string}
function M.rename(value, id)
  local t = id and terminal(id) or M.active()
  if not t then
    return
  end
  local new = type(value) == "table" and value.title or value
  local function set_title(v)
    if v and vim.trim(v) ~= "" then
      t.title = vim.trim(v)
      require("sidekick.cli.session").persist(t)
      M.refresh(t.id)
      Util.emit("SidekickCliTitle", { id = t.id, title = t.title })
    end
  end
  if new then
    set_title(new)
  else
    vim.ui.input({ prompt = "Agent title: ", default = t.title or t.tool.name }, set_title)
  end
end

local bufferline_actions = {
  BufferLineCyclePrev = "prev",
  BufferLineCycleNext = "next",
  BufferLineMovePrev = "move_prev",
  BufferLineMoveNext = "move_next",
  BufferLinePick = "pick",
  BufferLineTogglePin = "pin",
  BufferLineCloseOthers = "close_others",
  BufferLineCloseLeft = "close_left",
  BufferLineCloseRight = "close_right",
}

local bufferline_desc = {
  ["prev buffer"] = "prev",
  ["next buffer"] = "next",
  ["move buffer prev"] = "move_prev",
  ["move buffer next"] = "move_next",
  ["pick buffer"] = "pick",
  ["toggle pin"] = "pin",
  ["delete non-pinned buffers"] = "close_unpinned",
  ["delete buffers to the left"] = "close_left",
  ["delete buffers to the right"] = "close_right",
}

local function remember_live_size(p)
  if not valid(p.win) then
    return
  end
  local size = vim.deepcopy(p.sizes[p.layout] or {})
  if p.layout == "float" then
    local cfg = vim.api.nvim_win_get_config(p.win)
    size.width, size.height = cfg.width, cfg.height
    size.row, size.col = tonumber(cfg.row) or 0, tonumber(cfg.col) or 0
  elseif p.layout == "left" or p.layout == "right" then
    size.width = vim.api.nvim_win_get_width(p.win)
  else
    size.height = vim.api.nvim_win_get_height(p.win)
  end
  p.sizes[p.layout] = size
end

---@class sidekick.cli.WorkspacePanel
---@field tab {id:string,index:integer,cwd:string}
---@field order string[]
---@field active? string
---@field pinned table<string,boolean>
---@field layout string
---@field sizes table

---@return sidekick.cli.WorkspacePanel[]
function M.snapshot()
  local ret = {}
  local tabs = vim.api.nvim_list_tabpages()
  local tab_index = {}
  for index, tab in ipairs(tabs) do
    tab_index[tab] = index
  end
  for tab, p in pairs(M.panels) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      clean(p)
      remember_live_size(p)
      local id = vim.t[tab].sidekick_workspace_id
      if type(id) ~= "string" or id == "" then
        id = require("sidekick.cli.session").instance(tostring(vim.uv.hrtime()))
        vim.t[tab].sidekick_workspace_id = id
      end
      local cwd = M.cwd(tab)
      local order, pinned = {}, {}
      for _, terminal_id in ipairs(p.order) do
        local t = terminal(terminal_id)
        if t then
          local key = M.workspace_key(t)
          order[#order + 1] = key
          pinned[key] = p.pinned[terminal_id] == true or nil
        end
      end
      local active = terminal(p.active)
      ret[#ret + 1] = {
        tab = { id = id, index = tab_index[tab] or 1, cwd = cwd },
        order = order,
        active = active and M.workspace_key(active) or nil,
        pinned = pinned,
        layout = p.layout,
        sizes = vim.deepcopy(p.sizes),
      }
    end
  end
  table.sort(ret, function(a, b)
    return a.tab.index < b.tab.index
  end)
  return ret
end

---@param saved sidekick.cli.WorkspacePanel
---@param agents table<string,sidekick.cli.Terminal>
function M.restore(saved, agents)
  local p = panel(true) --[[@as sidekick.cli.Panel]]
  p.layout = valid_layout(saved.layout) and saved.layout or Config.cli.win.layout
  p.sizes = type(saved.sizes) == "table" and vim.deepcopy(saved.sizes) or {}
  p.has_remembered_layout = true
  local order = {}
  for _, key in ipairs(saved.order or {}) do
    local t = agents[key]
    if t and not t.closed then
      M.show(t, false)
      order[#order + 1] = t.id
      p.pinned[t.id] = saved.pinned and saved.pinned[key] == true or nil
    end
  end
  p.order = order
  local active = saved.active and agents[saved.active] or nil
  p.active = active and active.id or order[1]
  if p.active then
    M.select(p.active)
  end
  persist_tabs(p)
  M.refresh()
end

---@param buf integer
function M.keys(buf)
  local Actions = require("sidekick.cli.actions")
  local local_maps = {} ---@type table<string, vim.api.keyset.get_keymap>
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    local_maps[km.lhs] = km
  end
  for lhs, name in pairs(M.synced_keys[buf] or {}) do
    local km = local_maps[lhs]
    if km and km.desc == "Sidekick agent: " .. name then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      local_maps[lhs] = nil
    end
  end
  local found = {} ---@type table<string, string>
  for _, km in ipairs(vim.api.nvim_get_keymap("n")) do
    local value = (km.rhs or "") .. " " .. (km.desc or "")
    local by_desc = bufferline_desc[(km.desc or ""):lower()]
    if by_desc then
      found[km.lhs] = by_desc
    end
    for command, action in pairs(bufferline_actions) do
      if value:find(command, 1, true) and Actions[action] then
        found[km.lhs] = action
        break
      end
    end
  end
  M.synced_keys[buf] = {}
  for lhs, name in pairs(found) do
    if Actions[name] and not local_maps[lhs] then
      vim.keymap.set("n", lhs, function()
        local active = M.active()
        if active then
          Actions[name](active)
        end
      end, { buffer = buf, silent = true, desc = "Sidekick agent: " .. name })
      M.synced_keys[buf][lhs] = name
    end
  end
end

function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true
  _G.SidekickCliTabClick = function(minwid)
    local item = M.clicks[minwid]
    if not item then
      return
    end
    if item.action == "select" then
      local t = usable(item.id)
      if t then
        M.show(t, true)
      end
    elseif item.action == "close" then
      M.close(item.id)
    elseif item.action == "pick" then
      M.pick()
    elseif item.action == "new" then
      require("sidekick.cli").new()
    end
  end
  local function refresh_activation()
    M.refresh()
    local active = M.active()
    local p = panel()
    if active and p and valid(p.win) then
      active.win = p.win
    end
    Util.emit("SidekickCliActivate", { id = active and active.id or nil, tab = current_tab() })
  end
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = Config.augroup,
    callback = refresh_activation,
  })
  vim.api.nvim_create_autocmd("WinNew", {
    group = Config.augroup,
    callback = close_duplicate_window,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = Config.augroup,
    callback = M.refresh,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = Config.augroup,
    callback = function(ev)
      M.synced_keys[ev.buf] = nil
      local id = vim.b[ev.buf].sidekick_session_id
      if id then
        vim.schedule(function()
          local t = terminal(id)
          if t then
            t:close()
          end
        end)
      end
    end,
  })
  vim.on_key(function(key)
    if key ~= "\r" or vim.fn.mode() ~= "t" then
      return
    end
    local id = vim.b.sidekick_session_id
    local t = id and terminal(id) or nil
    if t then
      require("sidekick.cli.activity").input(t, key)
    end
  end, vim.api.nvim_create_namespace("sidekick.cli.activity"))
end

M.setup()

return M
