local Activity = require("sidekick.cli.activity")
local Config = require("sidekick.config")
local Fork = require("sidekick.cli.fork")
local Icons = require("sidekick.cli.icons")
local Panel = require("sidekick.cli.panel")
local Usage = require("sidekick.cli.agent_usage")
local Util = require("sidekick.util")

local M = {}
local preview_cache = {} ---@type table<string,{at:number,output?:string,pending?:boolean,ready?:boolean,waiter?:fun()}>
local PREVIEW_CACHE_MAX = 64
local RENAME_ICON = "󰏫"

local function unread_icon()
  local icon = Config.ui.icons.unread
  return type(icon) == "string" and vim.trim(icon) or "•"
end

---@alias sidekick.cli.AgentFilter "all"|"open"|"working"|"done"|"error"|"new"|"attention"|"pinned"
---@class sidekick.cli.AgentPickerOpts
---@field fork? boolean
---@field filter? sidekick.cli.AgentFilter

local FILTERS = {
  { name = "all", label = "All" },
  { name = "open", label = "Open" },
  { name = "working", label = "Working" },
  { name = "done", label = "Done" },
  { name = "error", label = "Errors" },
  { name = "new", label = "New" },
  { name = "attention", label = "Attention" },
  { name = "pinned", label = "Pinned" },
}

---@param name? string
---@return integer?
local function find_filter(name)
  name = name or "all"
  for index, filter in ipairs(FILTERS) do
    if filter.name == name then
      return index
    end
  end
end

---@return string[]
function M.filter_names()
  return vim.tbl_map(function(filter)
    return filter.name
  end, FILTERS)
end

local function agent_title(item, terminal)
  local title = terminal.title
  if type(title) ~= "string" or vim.trim(title) == "" then
    title = item.label:match("^[^:]+:%s*(.+)$") or terminal.tool.name
  end
  return vim.trim(tostring(title):gsub("[%c\r\n]+", " "):gsub("%s+", " "))
end

---@param id string
---@return boolean active, boolean pinned
local function panel_state(id)
  local p = Panel.panels[vim.api.nvim_get_current_tabpage()]
  if not p then
    return false, false
  end
  return p.active == id, p.pinned and p.pinned[id] == true or false
end

---@param agent table
---@param filter string
---@return boolean
local function matches_filter(agent, filter)
  if filter == "all" then
    return true
  elseif filter == "open" then
    return agent.status ~= "done" and agent.status ~= "error"
  elseif filter == "working" then
    return agent.status == "starting" or agent.status == "working" or agent.status == "waiting"
  elseif filter == "done" or filter == "error" then
    return agent.status == filter
  elseif filter == "new" then
    return agent.unread == true
  elseif filter == "attention" then
    return agent.unread == true or agent.status == "waiting" or agent.status == "error"
  elseif filter == "pinned" then
    return agent.pinned == true
  end
  return true
end

local function enrich(item, git)
  local t = item.terminal
  local project = vim.fn.fnamemodify(t.cwd or "", ":t")
  local metadata = git[t.cwd or ""] or {}
  local branch = metadata.branch or ""
  local changed = metadata.changed_files or {}
  local title = agent_title(item, t)
  local active, pinned = panel_state(item.id)
  local forkable, fork_reason, fork_status = Fork.ready(t.tool, t, { capture = false })
  local forked_from = vim.deepcopy(t.forked_from)
  return {
    id = item.id,
    instance_id = t.instance_id,
    key = item.key,
    label = item.label,
    title = title,
    tool = t.tool.name,
    status = t.status or "idle",
    cwd = t.cwd or "",
    project = project,
    backend = t.mux_backend or t.backend or "terminal",
    branch = branch,
    changed_files = vim.deepcopy(changed),
    active = active,
    pinned = pinned,
    unread = t._sidekick_unread == true,
    forkable = forkable,
    fork_reason = fork_reason,
    fork_status = fork_status,
    forked_from = forked_from,
    search = table.concat({
      item.label,
      title,
      "@" .. t.tool.name,
      "#" .. (t.status or "idle"),
      "%" .. project,
      branch,
      table.concat(changed, " "),
      active and "active" or "",
      t._sidekick_unread and "unread" or "",
      pinned and "pinned" or "",
      forkable and "forkable" or "",
      fork_status == "pending" and "fork-pending" or "",
      forked_from and ("forked-from " .. (forked_from.title or forked_from.id)) or "",
    }, " "),
  }
end

local function resolve(item)
  local t = require("sidekick.cli.terminal").get(item.id)
  if t and not t.closed and (not item.instance_id or t.instance_id == item.instance_id) then
    return t
  end
end

---@param items {id:string,terminal:sidekick.cli.Terminal}[]
---@param filter sidekick.cli.AgentFilter
local function has_filter_match(items, filter)
  for _, item in ipairs(items) do
    local terminal = resolve(item)
    if terminal then
      local _, pinned = panel_state(item.id)
      if
        matches_filter({
          status = terminal.status or "idle",
          unread = terminal._sidekick_unread == true,
          pinned = pinned,
        }, filter)
      then
        return true
      end
    end
  end
  return false
end

local function trim(lines)
  local bytes = math.max(1024, Config.cli.agent_picker.preview_bytes)
  local ret, used = {}, 0
  for _, line in ipairs(lines) do
    if used >= bytes then
      break
    end
    line = #line > bytes - used and line:sub(1, bytes - used) or line
    ret[#ret + 1] = line
    used = used + #line + 1
  end
  return ret
end

local function append_output(lines, output, max)
  if output then
    local output_lines = vim.split(output, "\n", { plain = true })
    vim.list_extend(lines, vim.list_slice(output_lines, math.max(1, #output_lines - max + 1)))
  end
end

local function cache_output(output)
  if not output then
    return
  end
  local max = math.max(1, Config.cli.agent_picker.preview_lines)
  local lines = vim.split(output, "\n", { plain = true })
  lines = vim.list_slice(lines, math.max(1, #lines - max + 1))
  return table.concat(trim(lines), "\n")
end

local function prune_cache(limit)
  limit = limit or PREVIEW_CACHE_MAX
  while vim.tbl_count(preview_cache) > limit do
    local oldest_key, oldest_at
    for key, cached in pairs(preview_cache) do
      if not oldest_at or cached.at < oldest_at then
        oldest_key, oldest_at = key, cached.at
      end
    end
    if not oldest_key then
      return
    end
    preview_cache[oldest_key].waiter = nil
    preview_cache[oldest_key] = nil
  end
end

---@param item {tool:string,label:string,cwd:string,backend:string}
---@param terminal? sidekick.cli.Terminal
---@param Snacks? table
local function preview_metadata(item, terminal, Snacks)
  local status = terminal and terminal.status or "closed"
  local function configured_icon(icon, fallback)
    icon = type(icon) == "string" and vim.trim(icon) or ""
    return icon ~= "" and icon or fallback
  end
  local directory_icon = "[dir]"
  if Snacks and Snacks.util and Snacks.util.icon then
    local ok, icon = pcall(Snacks.util.icon, item.cwd, "directory", { fallback = { dir = directory_icon } })
    directory_icon = ok and configured_icon(icon, directory_icon) or directory_icon
  end
  local status_icon = configured_icon(Config.cli.win.tabs.status[status], "*")
  local backend_source = item.backend == "terminal" and Config.ui.icons.terminal_attached
    or Config.ui.icons.external_attached
  local backend_icon = configured_icon(backend_source, ">_")
  local context = terminal and Usage.get(terminal)
  local forkable = item.forkable
  local fork_reason = item.fork_reason
  local fork_status = item.fork_status
  local forked_from = item.forked_from
  return {
    tool = item.tool,
    tool_icon = Icons.tool(item.tool),
    tool_hl = Icons.highlight(item.tool),
    title = item.title,
    status = status,
    unread = terminal and terminal._sidekick_unread == true,
    status_hl = "SidekickCliStatus" .. (terminal and status:gsub("^%l", string.upper) or "Error"),
    status_icon = status_icon,
    directory_icon = directory_icon,
    backend_icon = backend_icon,
    directory = vim.fn.fnamemodify(item.cwd, ":p:~"),
    backend = item.backend,
    context = context,
    forkable = forkable,
    fork_reason = fork_reason,
    fork_status = fork_status,
    forked_from = forked_from,
  }
end

---@param metadata table
---@return {title:table[],footer:table[],text:string,key:string}
local function preview_header(metadata)
  local function count(value)
    if value >= 1e6 then
      return ("%.1fm"):format(value / 1e6):gsub("%.0m$", "m")
    elseif value >= 1e3 then
      return ("%.1fk"):format(value / 1e3):gsub("%.0k$", "k")
    end
    return tostring(math.floor(value + 0.5))
  end
  local function context_hl(context)
    if not context.percent then
      return "Number"
    elseif context.percent >= 85 then
      return "SidekickCliStatusError"
    elseif context.percent >= 60 then
      return "SidekickCliStatusWorking"
    end
    return "SidekickCliStatusDone"
  end
  local function add(ret, group, text)
    if text == nil or text == "" then
      return
    end
    if #ret > 0 then
      -- Non-breaking spaces survive Snacks' title-template normalization.
      ret[#ret + 1] = { " │ ", "FloatBorder" }
    end
    ret[#ret + 1] = { tostring(text), group }
  end

  local top = {}
  local bottom = {}
  local tool = tostring(metadata.tool or "")
  local title = tostring(metadata.title or "")
  local agent = metadata.tool_icon and (metadata.tool_icon .. " " .. tool) or tool
  if title ~= "" and title:lower() ~= tool:lower() then
    agent = agent .. ": " .. title
  end
  add(top, metadata.tool_hl, agent)
  add(top, metadata.status_hl, table.concat({ metadata.status_icon, metadata.status }, " "))
  if metadata.unread then
    add(top, "SidekickCliAttention", "NEW")
  end
  if metadata.context then
    local context = metadata.context
    local text = ("Context %s"):format(count(context.used))
    if context.max then
      text = ("Context %s / %s"):format(count(context.used), count(context.max))
    end
    if context.percent then
      text = text .. (" (%d%%)"):format(context.percent)
    end
    add(bottom, context_hl(context), text)
  end
  add(bottom, "Directory", table.concat({ metadata.directory_icon, metadata.directory }, " "))
  add(bottom, "Identifier", table.concat({ metadata.backend_icon, metadata.backend }, " "))
  if metadata.forked_from then
    add(bottom, "Title", "Forked from " .. (metadata.forked_from.title or metadata.forked_from.id))
  else
    local status = metadata.fork_status or (metadata.forkable and "ready" or "unavailable")
    local status_hl = status == "ready" and "DiagnosticOk" or status == "pending" and "DiagnosticWarn" or "Comment"
    local status_text = status == "ready" and "ready" or status == "pending" and "pending" or "unavailable"
    add(bottom, status_hl, "Fork " .. status_text)
  end

  local function pad(chunks)
    table.insert(chunks, 1, { " ", "FloatTitle" })
    chunks[#chunks + 1] = { " ", "FloatTitle" }
    return chunks
  end
  local function chunk_text(chunks)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, chunks))
  end
  local function chunk_key(chunks)
    return table.concat(
      vim.tbl_map(function(chunk)
        return chunk[1] .. "\0" .. chunk[2]
      end, chunks),
      "\0"
    )
  end

  top = pad(top)
  bottom = pad(bottom)
  return {
    title = top,
    footer = bottom,
    text = chunk_text(top) .. "  " .. chunk_text(bottom),
    key = chunk_key(top) .. "\1" .. chunk_key(bottom),
  }
end

---@param ctx snacks.picker.preview.ctx
---@param metadata table
---@param previous? string
---@return string?
local function set_preview_header(ctx, metadata, previous)
  if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then
    return previous
  end
  local header = preview_header(metadata)
  local config = vim.api.nvim_win_get_config(ctx.win)
  local bordered_float = config.relative ~= "" and type(config.border) == "table" and #config.border > 0
  local key = (bordered_float and "border:" or "winbar:") .. header.key
  if previous == key then
    return previous
  end

  if bordered_float then
    -- Border text accepts native highlighted chunks. Unlike `%#Group#` in a
    -- winbar, these are not reparsed as a statusline on every terminal redraw.
    local preview_win = ctx.preview and ctx.preview.win
    if preview_win and preview_win.opts then
      preview_win.opts.title = header.title
      preview_win.opts.title_pos = "left"
      preview_win.opts.footer = header.footer
      preview_win.opts.footer_pos = "left"
    end
    if
      not vim.deep_equal(config.title, header.title)
      or not vim.deep_equal(config.footer, header.footer)
      or config.title_pos ~= "left"
      or config.footer_pos ~= "left"
    then
      vim.api.nvim_win_set_config(ctx.win, {
        title = header.title,
        title_pos = "left",
        footer = header.footer,
        footer_pos = "left",
      })
    end
    if vim.api.nvim_get_option_value("winbar", { win = ctx.win }) ~= "" then
      vim.api.nvim_set_option_value("winbar", "", { win = ctx.win })
    end
    return key
  end

  -- Borderless picker layouts keep a compact fallback. It deliberately has
  -- no embedded highlight directives, so redraw stays on the cheap path.
  local value = header.text:gsub("%%", "%%%%")
  if vim.api.nvim_get_option_value("winbar", { win = ctx.win }) ~= value then
    vim.api.nvim_set_option_value("winbar", value, { win = ctx.win })
  end
  local current_hl = vim.api.nvim_get_option_value("winhighlight", { win = ctx.win })
  local highlights = vim.tbl_filter(function(value_hl)
    return not value_hl:match("^WinBar:") and not value_hl:match("^WinBarNC:")
  end, vim.split(current_hl, ",", { plain = true, trimempty = true }))
  local group = metadata.unread and "SidekickCliAttention" or metadata.status_hl
  highlights[#highlights + 1] = "WinBar:" .. group
  highlights[#highlights + 1] = "WinBarNC:" .. group
  local next_hl = table.concat(highlights, ",")
  if current_hl ~= next_hl then
    vim.api.nvim_set_option_value("winhighlight", next_hl, { win = ctx.win })
  end
  return key
end

local function preview_lines(item, on_update, Snacks)
  local t = resolve(item)
  local metadata = preview_metadata(item, t, Snacks)
  local lines = {}
  if not t then
    lines[#lines + 1] = "This agent is no longer available."
    return lines, metadata
  end
  local max = math.max(1, Config.cli.agent_picker.preview_lines)
  if t.buf and vim.api.nvim_buf_is_valid(t.buf) then
    local count = vim.api.nvim_buf_line_count(t.buf)
    vim.list_extend(lines, vim.api.nvim_buf_get_lines(t.buf, math.max(0, count - max), count, false))
  else
    local source = type(t.dump_async) == "function" and t
      or (t.parent and type(t.parent.dump_async) == "function" and t.parent or nil)
    if source then
      local key = table.concat({ item.tool, item.id, item.instance_id or "" }, ":")
      local cached = preview_cache[key]
      if not cached then
        prune_cache(PREVIEW_CACHE_MAX - 1)
        cached = { at = 0 }
        preview_cache[key] = cached
      end
      if on_update then
        cached.waiter = on_update
      end
      if cached.output then
        append_output(lines, cached.output, max)
      elseif cached.ready then
        lines[#lines + 1] = "No terminal output is available."
      else
        lines[#lines + 1] = "Loading terminal output…"
      end
      if vim.uv.now() - cached.at > 500 and not cached.pending then
        cached.pending = true
        cached.at = vim.uv.now()
        source:dump_async(function(output)
          cached.pending = false
          cached.output = cache_output(output)
          cached.ready = true
          cached.at = vim.uv.now()
          prune_cache()
          local waiter = cached.waiter
          cached.waiter = nil
          if waiter then
            waiter()
          end
        end)
      end
    else
      lines[#lines + 1] = "No terminal output is available."
    end
  end
  return trim(lines), metadata
end

---@param ctx snacks.picker.preview.ctx
local function save_preview_view(ctx)
  if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then
    return
  end
  return vim.api.nvim_win_call(ctx.win, vim.fn.winsaveview)
end

---@param ctx snacks.picker.preview.ctx
---@param view? vim.fn.winsaveview.ret
local function restore_preview_view(ctx, view)
  if not (view and ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_buf_is_valid(ctx.buf)) then
    return
  end
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  if count == 0 then
    return
  end
  view = vim.deepcopy(view)
  view.lnum = math.min(math.max(view.lnum, 1), count)
  view.topline = math.min(math.max(view.topline, 1), count)
  vim.api.nvim_win_call(ctx.win, function()
    vim.fn.winrestview(view)
  end)
end

---@param ctx snacks.picker.preview.ctx
local function show_preview_tail(ctx)
  if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_buf_is_valid(ctx.buf)) then
    return
  end
  local count = vim.api.nvim_buf_line_count(ctx.buf)
  if count == 0 then
    return
  end
  -- Moving to the last line makes Neovim reveal the tail without temporarily
  -- entering the preview window. `nvim_win_call()` plus `normal! zt` can force
  -- a synchronous window redraw while an active terminal is still flushing,
  -- which may block the whole UI for seconds or longer on the first preview.
  vim.api.nvim_win_set_cursor(ctx.win, { count, 0 })
end

local function selected(picker, item)
  local ret = {}
  for _, selected_item in ipairs(picker:selected({ fallback = true })) do
    local value = selected_item.agent or selected_item.item
    if value then
      ret[#ret + 1] = value
    end
  end
  if #ret == 0 and item then
    ret[1] = item.agent or item.item
  end
  return ret
end

local function reopen(picker)
  picker:close()
  vim.schedule(function()
    M.open()
  end)
end

---@param opts? sidekick.cli.AgentPickerOpts
local function snacks(items, Snacks, opts)
  local picker, group
  local preview_poll_timer
  local preview_debounce_timer
  local preview_debounce_pending = false
  local preview_debounce_generation
  local preview_polling = false
  local preview_source ---@type {buf:integer,generation:integer}?
  local preview_render
  local preview_invalidate
  local preview_refresh_pending = false
  local preview_generation = 0
  local refresh_pending = false
  local filter_index = find_filter(opts and opts.filter) or 1
  local renaming ---@type {agent:table,find:function,prompt:string|nil,title:string,pattern:string,search:string}|nil
  local function current_filter()
    return FILTERS[filter_index]
  end
  local function picker_title()
    local prefix = opts and opts.fork and "Fork Agent" or "Sidekick Agents"
    return ("%s · %s"):format(prefix, current_filter().label)
  end
  local function update_filter_title()
    if not picker or picker.closed then
      return
    end
    picker.title = picker_title()
    if picker.update_titles then
      picker:update_titles()
    end
  end
  local function filter_agents(agents)
    local filter = current_filter().name
    if filter == "all" then
      return agents
    end
    return vim.tbl_filter(function(agent)
      return matches_filter(agent, filter)
    end, agents)
  end
  local function refresh()
    if refresh_pending or not picker or picker.closed then
      return
    end
    refresh_pending = true
    vim.schedule(function()
      refresh_pending = false
      if picker and not picker.closed and type(picker.find) == "function" then
        -- `Picker:refresh()` clears multi-selection. Re-run only the finder
        -- so background metadata/status updates preserve selected agents.
        picker:find({ refresh = true })
      end
    end)
  end
  local function refresh_preview()
    if preview_invalidate then
      preview_invalidate()
    end
    if preview_refresh_pending or not preview_render or not picker or picker.closed then
      return
    end
    preview_refresh_pending = true
    vim.schedule(function()
      preview_refresh_pending = false
      if preview_render and picker and not picker.closed then
        preview_render()
      end
    end)
  end
  local function stop_timer(timer)
    if timer and not timer:is_closing() then
      timer:stop()
    end
  end
  local function close_timer(timer)
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  local function detach_preview_source()
    local source = preview_source
    preview_source = nil
    if source and vim.api.nvim_buf_is_valid(source.buf) then
      pcall(vim.api.nvim_buf_detach, source.buf)
    end
  end
  local function stop_preview_updates()
    preview_polling = false
    preview_debounce_pending = false
    preview_debounce_generation = nil
    stop_timer(preview_poll_timer)
    stop_timer(preview_debounce_timer)
    detach_preview_source()
  end
  local function status_icon(status)
    local icon = Config.cli.win.tabs.status[status]
    return type(icon) == "string" and vim.trim(icon) or "*"
  end
  local function agent_icon()
    local icon = Config.ui.icons.installed
    return type(icon) == "string" and vim.trim(icon) or ""
  end
  local function pin_icon()
    local icon = Config.ui.icons.pin
    return type(icon) == "string" and vim.trim(icon) or "󰐃"
  end
  local function fork_icon()
    local icon = Config.ui.icons.fork
    return type(icon) == "string" and vim.trim(icon) or "↗"
  end
  local function finish_rename(commit)
    if not renaming or not picker or picker.closed then
      return false
    end
    local state = renaming
    local value = picker.input:get()
    renaming = nil
    picker.find = state.find
    picker.opts.prompt = state.prompt
    picker.title = state.title
    picker.input:set(state.pattern, state.search)
    picker:update_titles()
    if commit and value and vim.trim(value) ~= "" and resolve(state.agent) then
      Panel.rename(value, state.agent.id)
      refresh()
    end
    return true
  end
  local function start_rename(agent)
    if renaming or not picker or picker.closed or not agent then
      return
    end
    local terminal = resolve(agent)
    if not terminal then
      return
    end
    local input = picker.input
    if not input then
      return
    end
    renaming = {
      agent = agent,
      find = picker.find,
      prompt = picker.opts.prompt,
      title = picker.title,
      pattern = input.filter.pattern,
      search = input.filter.search,
    }
    -- The picker input doubles as the title editor. Ignore its normal
    -- filtering while editing so the selected row and preview stay in place.
    picker.find = function() end
    picker.opts.prompt = RENAME_ICON .. " Rename agent: "
    picker.title = RENAME_ICON .. " Rename Agent"
    if picker.opts.live then
      input:set(nil, agent_title(agent, terminal))
    else
      input:set(agent_title(agent, terminal))
    end
    picker:focus("input")
    if input.win and input.win:valid() then
      vim.schedule(function()
        if picker and not picker.closed and renaming then
          picker:focus("input")
          vim.cmd("startinsert!")
        end
      end)
    end
  end
  local function confirm(picker, item)
    picker:close()
    local terminal = item and item.agent and resolve(item.agent)
    if not terminal then
      return
    end
    if opts and opts.fork then
      return vim.schedule(function()
        require("sidekick.cli").fork({ source = terminal, focus = true })
      end)
    end
    Panel.select(item.agent.id, true)
  end
  picker = Snacks.picker.pick({
    source = "sidekick_agents",
    title = picker_title(),
    finder = function()
      return vim.tbl_map(function(agent)
        return { text = agent.search, _select_key = agent.id, agent = agent }
      end, filter_agents(M.items(items, refresh)))
    end,
    format = function(item)
      local t = resolve(item.agent)
      local status = t and t.status or "error"
      local state = status:gsub("^%l", string.upper)
      local agent = item.agent
      local icon = Icons.tool(agent.tool)
      local tool_hl = Icons.highlight(agent.tool)
      local ret = {}
      if agent.active then
        ret[#ret + 1] = { "◆ ", "SidekickCliTabSelected" }
      end
      if agent.forked_from then
        ret[#ret + 1] = { fork_icon() .. " ", "Special" }
      end
      if agent.pinned then
        ret[#ret + 1] = { pin_icon() .. " ", "SidekickCliPin" }
      end
      if agent.unread then
        ret[#ret + 1] = { unread_icon() .. " ", "SidekickCliAttention" }
      end
      local agent_marker = agent_icon()
      if agent_marker ~= "" and not icon then
        ret[#ret + 1] = { agent_marker .. " ", "SidekickCliInstalled" }
      end
      if icon then
        ret[#ret + 1] = { icon .. " ", tool_hl }
        ret[#ret + 1] = { agent.tool, tool_hl }
      else
        ret[#ret + 1] = { agent.tool, tool_hl }
      end
      if agent.title ~= agent.tool then
        ret[#ret + 1] = { "  " .. agent.title, "Title" }
      end
      ret[#ret + 1] = { "  " .. status_icon(status) .. " " .. status, "SidekickCliStatus" .. state }
      if agent.project ~= "" then
        ret[#ret + 1] = { "  " .. agent.project, "Directory" }
      end
      if agent.branch ~= "" then
        ret[#ret + 1] = { "   " .. agent.branch, "Special" }
      end
      local changed = #agent.changed_files
      if changed > 0 then
        ret[#ret + 1] = { "  +" .. changed, "DiffChange" }
      end
      return ret
    end,
    preview = function(ctx)
      preview_generation = preview_generation + 1
      local generation = preview_generation
      local initialized = false
      local title
      local last_header
      local last_lines
      local last_source_buf
      local last_source_tick
      local ensure_updates
      stop_preview_updates()
      preview_invalidate = function()
        if generation == preview_generation then
          last_header = nil
        end
      end
      local function source_buffer()
        local terminal = resolve(ctx.item.agent)
        return terminal and terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) and terminal.buf or nil
      end
      local function render()
        if (not picker or not picker.closed) and generation == preview_generation then
          if not initialized then
            ctx.preview:reset()
            if vim.api.nvim_buf_is_valid(ctx.buf) then
              -- Programmatic tail positioning should not start a Snacks smooth
              -- scroll animation for this generated preview buffer.
              vim.b[ctx.buf].snacks_scroll = false
            end
          end
          local next_title = ctx.item.agent.label
          if title ~= next_title then
            ctx.preview:set_title(next_title)
            title = next_title
          end
          local buf = source_buffer()
          local tick = buf and vim.api.nvim_buf_get_changedtick(buf) or nil
          local lines, metadata
          if initialized and buf and buf == last_source_buf and tick == last_source_tick then
            lines = last_lines
            metadata = preview_metadata(ctx.item.agent, resolve(ctx.item.agent), Snacks)
          else
            lines, metadata = preview_lines(ctx.item.agent, render, Snacks)
            last_source_buf = buf
            last_source_tick = buf and vim.api.nvim_buf_get_changedtick(buf) or nil
          end
          local changed = not initialized or not vim.deep_equal(last_lines, lines)
          local view = initialized and changed and save_preview_view(ctx) or nil
          if changed then
            ctx.preview:set_lines(lines)
            last_lines = lines
          end
          last_header = set_preview_header(ctx, metadata, last_header)
          if changed then
            if view then
              restore_preview_view(ctx, view)
            else
              show_preview_tail(ctx)
            end
          end
          initialized = true
        end
      end
      local function debounce_render()
        if preview_debounce_pending or generation ~= preview_generation or not picker or picker.closed then
          return
        end
        preview_debounce_pending = true
        preview_debounce_generation = generation
        preview_debounce_timer = preview_debounce_timer or assert(vim.uv.new_timer())
        preview_debounce_timer:stop()
        preview_debounce_timer:start(
          50,
          0,
          vim.schedule_wrap(function()
            if preview_debounce_generation ~= generation then
              return
            end
            preview_debounce_pending = false
            preview_debounce_generation = nil
            if generation == preview_generation and picker and not picker.closed then
              render()
              ensure_updates()
            end
          end)
        )
      end
      local function attach_source(buf)
        local source = { buf = buf, generation = generation }
        preview_source = source
        local ok, attached = pcall(vim.api.nvim_buf_attach, buf, false, {
          on_lines = function()
            if preview_source ~= source or generation ~= preview_generation then
              return true
            end
            debounce_render()
          end,
          on_detach = function()
            if preview_source == source then
              preview_source = nil
              vim.schedule(function()
                if generation == preview_generation and picker and not picker.closed then
                  ensure_updates()
                end
              end)
            end
          end,
        })
        if not ok or not attached then
          if preview_source == source then
            preview_source = nil
          end
          return false
        end
        return true
      end
      local function start_polling()
        preview_poll_timer = preview_poll_timer or assert(vim.uv.new_timer())
        preview_polling = true
        preview_poll_timer:stop()
        preview_poll_timer:start(
          500,
          500,
          vim.schedule_wrap(function()
            if generation == preview_generation and picker and not picker.closed then
              render()
              ensure_updates()
            end
          end)
        )
      end
      ensure_updates = function()
        if generation ~= preview_generation or not picker or picker.closed then
          return
        end
        local buf = source_buffer()
        if buf then
          if not preview_source or preview_source.buf ~= buf or preview_source.generation ~= generation then
            preview_polling = false
            stop_timer(preview_poll_timer)
            detach_preview_source()
            if not attach_source(buf) then
              start_polling()
            end
          end
        else
          detach_preview_source()
          if not preview_polling then
            start_polling()
          end
        end
      end
      preview_render = render
      render()
      ensure_updates()
    end,
    confirm = confirm,
    actions = {
      agent_confirm = function(picker, item)
        if not finish_rename(true) then
          confirm(picker, item)
        end
      end,
      agent_fork = function(picker, item)
        local agents = selected(picker, item)
        if #agents ~= 1 then
          return Util.warn("Select exactly one agent to fork")
        end
        local terminal = resolve(agents[1])
        if not terminal then
          return Util.warn("The selected agent is no longer available")
        end
        picker:close()
        vim.schedule(function()
          require("sidekick.cli").fork({ source = terminal, focus = true })
        end)
      end,
      agent_cancel = function(picker)
        if not finish_rename(false) then
          picker:norm(function()
            picker:close()
          end)
        end
      end,
      agent_pin = function(picker, item)
        for _, agent in ipairs(selected(picker, item)) do
          if resolve(agent) then
            Panel.pin(agent.id)
          end
        end
        reopen(picker)
      end,
      agent_rename = function(picker, item)
        start_rename(selected(picker, item)[1])
      end,
      agent_close = function(picker, item)
        for _, agent in ipairs(selected(picker, item)) do
          if resolve(agent) then
            Panel.close(agent.id)
          end
        end
        reopen(picker)
      end,
      agent_filter = function(picker)
        if renaming then
          return
        end
        filter_index = filter_index % #FILTERS + 1
        update_filter_title()
        picker:find({ refresh = true })
      end,
      agent_mark_read = function(picker, item)
        for _, agent in ipairs(selected(picker, item)) do
          local terminal = resolve(agent)
          if terminal then
            Activity.read(terminal)
          end
        end
        refresh()
      end,
      agent_cleanup = function(picker)
        picker:close()
        vim.schedule(function()
          M.cleanup()
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<CR>"] = { "agent_confirm", mode = { "n", "i" }, desc = "open agent" },
          ["<c-f>"] = { "agent_fork", mode = { "n", "i" }, desc = "fork agent conversation" },
          ["<Esc>"] = { "agent_cancel", mode = { "n", "i" }, desc = "close picker" },
          ["<c-p>"] = { "agent_pin", mode = { "n", "i" }, desc = "pin/unpin agent" },
          ["<c-r>"] = { "agent_rename", mode = { "n", "i" }, desc = "rename agent" },
          ["<c-x>"] = { "agent_close", mode = { "n", "i" }, desc = "close agent" },
          ["<a-t>"] = { "agent_filter", mode = { "n", "i" }, desc = "cycle agent filter" },
          ["<c-a>"] = { "agent_mark_read", mode = { "n", "i" }, desc = "mark agent output read" },
          ["<c-d>"] = { "agent_cleanup", mode = { "n", "i" }, desc = "clean completed agents" },
        },
      },
    },
    on_close = function()
      preview_render = nil
      preview_invalidate = nil
      stop_preview_updates()
      close_timer(preview_poll_timer)
      close_timer(preview_debounce_timer)
      for _, cached in pairs(preview_cache) do
        cached.waiter = nil
      end
      if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end
    end,
  })
  if picker then
    group =
      vim.api.nvim_create_augroup("sidekick_agent_picker_" .. tostring(picker.id or vim.uv.hrtime()), { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = {
        "SidekickCliStatus",
        "SidekickCliAttention",
        "SidekickCliActivate",
        "SidekickCliPanel",
        "SidekickCliFork",
        "SidekickCliUsage",
      },
      callback = function(ev)
        if ev.match ~= "SidekickCliUsage" then
          refresh()
        end
        refresh_preview()
      end,
    })
  end
end

M.preview_lines = preview_lines

---@param id string
function M.is_pinned(id)
  for _, p in pairs(Panel.panels) do
    if p.pinned[id] then
      return true
    end
  end
  return false
end

---@param opts? sidekick.cli.AgentPickerOpts
local function native(items, opts)
  if opts and opts.filter and opts.filter ~= "all" then
    items = vim.tbl_filter(function(item)
      return matches_filter(item, opts.filter)
    end, items)
  end
  local filter_index = find_filter(opts and opts.filter)
  local prompt = filter_index and filter_index ~= 1 and ("Select agent · %s:"):format(FILTERS[filter_index].label)
    or "Select agent:"
  vim.ui.select(items, {
    prompt = prompt,
    kind = "sidekick_agent",
    format_item = function(item)
      return (item.unread and (unread_icon() .. " ") or "") .. item.label
    end,
  }, function(item)
    local terminal = item and resolve(item)
    if not terminal then
      return
    end
    if opts and opts.fork then
      return require("sidekick.cli").fork({ source = terminal, focus = true })
    end
    local actions = {
      {
        label = "Open agent",
        action = function()
          Panel.select(item.id, true)
        end,
      },
      {
        label = "Fork conversation",
        action = function()
          local terminal = resolve(item)
          if terminal then
            require("sidekick.cli").fork({ source = terminal, focus = true })
          end
        end,
      },
      {
        label = M.is_pinned(item.id) and "Unpin agent" or "Pin agent",
        action = function()
          Panel.pin(item.id)
        end,
      },
      {
        label = "Rename agent",
        action = function()
          Panel.rename(nil, item.id)
        end,
      },
      {
        label = "Close agent",
        action = function()
          Panel.close(item.id)
        end,
      },
      { label = "Clean completed agents", action = M.cleanup },
    }
    local fork_action_index = 2
    if item.unread then
      table.insert(actions, 2, {
        label = "Mark output read",
        action = function()
          local terminal = resolve(item)
          if terminal then
            Activity.read(terminal)
          end
        end,
      })
      fork_action_index = 3
    end
    local forkable, fork_reason, fork_status = Fork.ready(terminal.tool, terminal)
    if not forkable then
      actions[fork_action_index] = {
        label = (fork_status == "pending" and "Fork pending: " or "Fork unavailable: ")
          .. (fork_reason or "unsupported"),
        action = function()
          Util.warn(fork_reason or "This agent does not support native conversation fork")
        end,
      }
    end
    vim.ui.select(actions, {
      prompt = item.label .. ":",
      kind = "sidekick_agent_action",
      format_item = function(action)
        return action.label
      end,
    }, function(action)
      if action and resolve(item) then
        action.action()
      end
    end)
  end)
end

function M.cleanup()
  local done = vim.tbl_filter(function(item)
    local t = resolve(item)
    return t and t.status == "done" and (not Config.cli.agent_picker.preserve_pinned or not M.is_pinned(t.id))
  end, M.items())
  if #done == 0 then
    return require("sidekick.util").info("No completed unpinned agents to clean up")
  end
  vim.ui.select({ "Cancel", ("Stop and close %d completed agents"):format(#done) }, {
    prompt = "Stop completed Sidekick agents? This terminates native CLI processes.",
  }, function(choice)
    if choice and choice ~= "Cancel" then
      for _, agent in ipairs(done) do
        local t = resolve(agent)
        if t and t.status == "done" and (not Config.cli.agent_picker.preserve_pinned or not M.is_pinned(t.id)) then
          Panel.close(agent.id)
        end
      end
    end
  end)
end

function M.items(items, on_update)
  items = items or Panel.picker_items()
  local cwds = vim.tbl_map(function(item)
    return item.terminal.cwd or ""
  end, items)
  local git = require("sidekick.cli.agent_git").collect(cwds, on_update)
  return vim.tbl_map(function(item)
    return enrich(item, git)
  end, items)
end

---@class sidekick.cli.EmptyAction
---@field icon string
---@field label string
---@field description string
---@field hl string
---@field run fun()

---@param cwd string
---@return sidekick.cli.EmptyAction[]
local function empty_actions(cwd)
  return {
    {
      icon = "󰐕",
      label = "New",
      description = "Start a new independent agent",
      hl = "SidekickCliInstalled",
      run = function()
        require("sidekick.cli").new({ cwd = cwd })
      end,
    },
    {
      icon = "󰑓",
      label = "Resume",
      description = "Restore the saved agent workspace",
      hl = "SidekickCliStarted",
      run = function()
        require("sidekick.cli").workspace("restore")
      end,
    },
    {
      icon = "󰋼",
      label = "Health",
      description = "Check Sidekick and its dependencies",
      hl = "DiagnosticInfo",
      run = function()
        vim.api.nvim_cmd({ cmd = "checkhealth", args = { "sidekick" } }, {})
      end,
    },
  }
end

---@param action? sidekick.cli.EmptyAction
local function run_empty_action(action)
  if action then
    vim.schedule(action.run)
  end
end

---@param actions sidekick.cli.EmptyAction[]
local function empty_native(actions)
  vim.ui.select(actions, {
    prompt = "No Sidekick agents are running:",
    kind = "sidekick_cli_empty",
    ---@param action sidekick.cli.EmptyAction
    format_item = function(action)
      return ("%s  %s  ·  %s"):format(action.icon, action.label, action.description)
    end,
  }, run_empty_action)
end

---@param Snacks snacks
---@param actions sidekick.cli.EmptyAction[]
local function empty_snacks(Snacks, actions)
  Snacks.picker.pick({
    source = "sidekick_empty",
    title = "Sidekick · No Agents",
    finder = function()
      return vim.tbl_map(function(action)
        return {
          text = action.label .. " " .. action.description,
          action = action,
        }
      end, actions)
    end,
    format = function(item)
      local action = item.action
      return {
        { action.icon .. "  ", action.hl },
        { action.label, "Title" },
        { "  " .. action.description, "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      run_empty_action(item and item.action)
    end,
    layout = {
      preset = "select",
      layout = { max_width = 72 },
    },
  })
end

---@param items? {id:string,label:string,key:string,terminal:sidekick.cli.Terminal}[]
---@param opts? sidekick.cli.AgentPickerOpts
function M.open(items, opts)
  opts = opts or {}
  items = items or Panel.picker_items()
  if opts.filter and not find_filter(opts.filter) then
    return Util.warn(
      ("Invalid Sidekick agent filter `%s`; expected one of: %s"):format(
        opts.filter,
        table.concat(M.filter_names(), ", ")
      )
    )
  end
  if opts.filter and opts.filter ~= "all" and not has_filter_match(items, opts.filter) then
    return Util.info(("No Sidekick agents match the `%s` filter"):format(opts.filter))
  end
  if #items == 0 then
    if opts.fork then
      return Util.warn("No live agent is available to fork")
    end
    local cwd = require("sidekick.cli.session").cwd()
    local actions = empty_actions(cwd)
    local provider = Config.cli.agent_picker.provider
    local ok, Snacks = pcall(require, "snacks")
    if provider ~= "native" and ok and Snacks.picker and Snacks.picker.pick then
      return empty_snacks(Snacks, actions)
    end
    return empty_native(actions)
  end
  local provider = Config.cli.agent_picker.provider
  local ok, Snacks = pcall(require, "snacks")
  local use_snacks = provider ~= "native" and ok and Snacks.picker and Snacks.picker.pick
  if use_snacks then
    return snacks(items, Snacks, opts)
  end
  return native(M.items(items), opts)
end

return M
