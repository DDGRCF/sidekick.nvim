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

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win) or false
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
    vim.api.nvim_win_set_buf(p.win, replacement)
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

local function usable(id)
  local t = terminal(id)
  return t and t.buf and vim.api.nvim_buf_is_valid(t.buf) and t or nil
end

local function current_tab()
  return vim.api.nvim_get_current_tabpage()
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

local function status_icon_text(t)
  if Config.cli.win.tabs.show_status == false then
    return ""
  end
  return Config.cli.win.tabs.status[t.status or "idle"] or "○"
end

local function status_icon(t)
  return escape(status_icon_text(t))
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
  local text = " " .. agent_icon_text(t) .. status_icon_text(t) .. ": " .. (title_value or title_text(t))
  if p.pinned[t.id] then
    text = text .. " 󰐃"
  end
  text = text .. " "
  if Config.cli.win.tabs.show_close then
    text = text .. " "
  end
  return vim.api.nvim_strwidth(left_separator .. text .. right_separator)
end

---@param items {id:string,t:sidekick.cli.Terminal,width:integer}[]
---@param left integer
---@param right integer
---@param hidden_left integer
---@param hidden_right integer
local function range_width(items, left, right, hidden_left, hidden_right)
  local width = vim.api.nvim_strwidth(truncation_marker(hidden_left))
    + vim.api.nvim_strwidth(truncation_marker(hidden_right))
  for i = left, right do
    width = width + items[i].width
  end
  return width
end

---@param items {id:string,t:sidekick.cli.Terminal,width:integer}[]
---@param active integer
---@param available integer
---@return integer left, integer right, integer hidden_left, integer hidden_right
local function visible_range(items, active, available)
  local left, right = 1, #items
  local hidden_left, hidden_right = 0, 0
  while range_width(items, left, right, hidden_left, hidden_right) > available do
    local can_left = left < active
    local can_right = right > active
    if not can_left and not can_right then
      break
    end

    local left_width = can_left and range_width(items, left + 1, right, hidden_left + 1, hidden_right) or nil
    local right_width = can_right and range_width(items, left, right - 1, hidden_left, hidden_right + 1) or nil
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

  -- Keep the active tab visible even when the markers themselves do not fit.
  if range_width(items, left, right, hidden_left, hidden_right) > available then
    return active, active, 0, 0
  end
  return left, right, hidden_left, hidden_right
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
  if selected then
    parts[#parts + 1] = "%<"
  end
  parts[#parts + 1] = ("%%#SidekickCliTabSeparator#%s"):format(escape(left_separator))
  parts[#parts + 1] = click("select", p, t.id)
  parts[#parts + 1] = ("%%#%s# %s"):format(base, agent_icon(t))
  parts[#parts + 1] = ("%%#SidekickCliStatus%s#%s"):format(state, status_icon(t))
  parts[#parts + 1] = ("%%#%s#: %s%s "):format(base, title(t, title_value), p.pinned[t.id] and " 󰐃" or "")
  parts[#parts + 1] = "%T"
  if Config.cli.win.tabs.show_close then
    parts[#parts + 1] = click("close", p, t.id)
    parts[#parts + 1] = ("%%#%s# %%T"):format(base)
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
  local items = {} ---@type {id:string,t:sidekick.cli.Terminal,width:integer}[]
  for _, id in ipairs(p.order) do
    local t = terminal(id)
    if t then
      items[#items + 1] = {
        id = id,
        t = t,
        width = 0,
      }
    end
  end
  local suffixes = duplicate_suffixes(items)
  local titles = {} ---@type table<string,string>
  for _, item in ipairs(items) do
    titles[item.id] = title_text(item.t, nil, suffixes[item.id])
    item.width = tab_width(p, item.t, left_separator, right_separator, titles[item.id])
  end

  local active = 1
  for i, item in ipairs(items) do
    if item.id == p.active then
      active = i
      break
    end
  end
  local first, last, hidden_left, hidden_right = 1, 0, 0, 0
  local available
  local active_title
  if #items > 0 then
    available = math.max(1, vim.api.nvim_win_get_width(p.win) - vim.api.nvim_strwidth("+ "))
    first, last, hidden_left, hidden_right = visible_range(items, active, available)
    if first == active and last == active and items[active].width > available then
      local t = items[active].t
      local fixed_width = tab_width(p, t, left_separator, right_separator, "")
      active_title = title_text(t, math.max(0, available - fixed_width), suffixes[items[active].id])
    end
  end
  parts[#parts + 1] = render_truncation(hidden_left, p)
  for i = first, last do
    local title_value = i == active and (active_title or titles[items[i].id]) or titles[items[i].id]
    parts[#parts + 1] = render_tab(p, items[i].t, left_separator, right_separator, title_value)
  end
  parts[#parts + 1] = render_truncation(hidden_right, p)
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

---@param id? string
function M.refresh(_)
  M.clicks = {}
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
    vim.api.nvim_win_set_buf(p.win, buf)
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
  vim.w[p.win].sidekick_panel = true
end

---@param p sidekick.cli.Panel
---@param t sidekick.cli.Terminal
local function activate_window(p, t)
  if not valid(p.win) then
    return
  end
  vim.api.nvim_win_set_buf(p.win, t.buf)
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
    return
  end
  local p = panel()
  if p and valid(p.win) then
    hide_panel(p)
  end
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
function M.select(id)
  local t = usable(id)
  if t then
    require("sidekick.cli.activity").ack(t)
    M.show(t, false)
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
  end
end

function M.pin()
  local p = panel()
  if p and p.active then
    p.pinned[p.active] = not p.pinned[p.active] or nil
    persist_tabs(p)
    M.refresh()
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

function M.pick()
  local p = panel()
  if not p then
    return
  end
  clean(p)
  local items = {} ---@type {id:string,label:string,key:string}[]
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
    local prefix = agent_icon(t) .. (status ~= "" and (" " .. status) or "")
    items[#items + 1] = {
      id = item.id,
      label = ("%s: %s"):format(prefix, title_text(t, nil, suffixes[item.id])),
      key = agent_key(t),
    }
  end
  History.sort(items, "agents", function(item)
    return item.key
  end)
  local select = vim.ui.select
  local ok, Snacks = pcall(require, "snacks")
  if Config.cli.picker == "snacks" and ok and Snacks.picker and Snacks.picker.select then
    select = Snacks.picker.select
  end
  select(items, {
    prompt = "Select agent:",
    kind = "sidekick_agent",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      M.select(item.id)
    end
  end)
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
  clean(p)
  local active = usable(p.active)
  if active then
    local was_focused = valid(p.win) and vim.api.nvim_get_current_win() == p.win
    M.hide()
    M.show(active, was_focused)
  else
    vim.schedule(function()
      require("sidekick.cli").new()
    end)
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
function M.rename(value)
  local t = M.active()
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
