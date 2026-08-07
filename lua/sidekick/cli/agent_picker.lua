local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")
local Usage = require("sidekick.cli.agent_usage")

local M = {}
local preview_cache = {} ---@type table<string,{at:number,output?:string,pending?:boolean,ready?:boolean,waiter?:fun()}>
local PREVIEW_CACHE_MAX = 64
local RENAME_ICON = "󰏫"
local FILTERS = {
  { name = "all", label = "All" },
  { name = "open", label = "Open" },
  { name = "working", label = "Working" },
  { name = "done", label = "Done" },
  { name = "error", label = "Errors" },
  { name = "pinned", label = "Pinned" },
}

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
    search = table.concat({
      item.label,
      title,
      "@" .. t.tool.name,
      "#" .. (t.status or "idle"),
      "%" .. project,
      branch,
      table.concat(changed, " "),
      active and "active" or "",
      pinned and "pinned" or "",
    }, " "),
  }
end

local function resolve(item)
  local t = require("sidekick.cli.terminal").get(item.id)
  if t and not t.closed and (not item.instance_id or t.instance_id == item.instance_id) then
    return t
  end
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
  return {
    status = status,
    status_hl = "SidekickCliStatus" .. (terminal and status:gsub("^%l", string.upper) or "Error"),
    status_icon = status_icon,
    directory_icon = directory_icon,
    backend_icon = backend_icon,
    directory = vim.fn.fnamemodify(item.cwd, ":p:~"),
    backend = item.backend,
    context = context,
  }
end

---@param value any
local function escape_winbar(value)
  return tostring(value):gsub("%%", "%%%%")
end

---@param metadata table
---@return string
local function preview_winbar(metadata)
  local function highlight(group, text)
    return ("%%#%s#%s%%*"):format(group, escape_winbar(text))
  end
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
  local ret = {
    highlight(metadata.status_hl, metadata.status_icon),
    " ",
    highlight("Special", "Status:"),
    " ",
    highlight(metadata.status_hl, metadata.status),
    "  ",
  }
  if metadata.context then
    local context = metadata.context
    local text = ("Context: %s"):format(count(context.used))
    if context.max then
      text = ("Context: %s / %s"):format(count(context.used), count(context.max))
    end
    if context.percent then
      text = text .. (" (%d%%)"):format(context.percent)
    end
    vim.list_extend(ret, { highlight(context_hl(context), text), "  " })
  end
  vim.list_extend(ret, {
    highlight("Directory", metadata.directory_icon),
    " ",
    highlight("Special", "Directory:"),
    " ",
    highlight("Directory", metadata.directory),
    "  ",
    highlight("Identifier", metadata.backend_icon),
    " ",
    highlight("Special", "Backend:"),
    " ",
    highlight("Identifier", metadata.backend),
  })
  return table.concat(ret)
end

---@param ctx snacks.picker.preview.ctx
---@param metadata table
local function set_preview_winbar(ctx, metadata)
  if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then
    return
  end
  vim.api.nvim_set_option_value("winbar", preview_winbar(metadata), { win = ctx.win })
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
  vim.api.nvim_win_call(ctx.win, function()
    -- Keep the cursor on the first visible line. This shows the newest output
    -- without pinning the cursor to the final line or leaving empty rows below.
    local first = math.max(1, count - vim.api.nvim_win_get_height(ctx.win) + 1)
    vim.api.nvim_win_set_cursor(ctx.win, { first, 0 })
    vim.cmd("normal! zt")
  end)
end

---@param ctx snacks.picker.preview.ctx
---@param lines string[]
local function set_preview_lines(ctx, lines)
  if vim.api.nvim_buf_is_valid(ctx.buf) then
    local current = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
    if vim.deep_equal(current, lines) then
      return false
    end
  end
  ctx.preview:set_lines(lines)
  return true
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

local function snacks(items, Snacks)
  local picker, group
  local preview_timer
  local preview_generation = 0
  local refresh_pending = false
  local filter_index = 1
  local renaming ---@type {agent:table,find:function,prompt:string|nil,title:string,pattern:string,search:string}|nil
  local function current_filter()
    return FILTERS[filter_index]
  end
  local function update_filter_title()
    if not picker or picker.closed then
      return
    end
    picker.title = ("Sidekick Agents · %s"):format(current_filter().label)
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
      if picker and not picker.closed then
        -- `Picker:refresh()` clears multi-selection. Re-run only the finder
        -- so background metadata/status updates preserve selected agents.
        picker:find({ refresh = true })
      end
    end)
  end
  local function tool_icon(tool)
    local icons = Config.cli.win.tabs.icons
    local icon = icons[tool] or icons.default
    return type(icon) == "string" and vim.trim(icon) or ""
  end
  local function status_icon(status)
    local icon = Config.cli.win.tabs.status[status]
    return type(icon) == "string" and vim.trim(icon) or "*"
  end
  local function agent_icon()
    local icon = Config.ui.icons.installed
    return type(icon) == "string" and vim.trim(icon) or ""
  end
  local tool_highlights = {
    aider = "SidekickCliToolAider",
    amazon_q = "SidekickCliToolAmazonQ",
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
  local function tool_highlight(tool)
    return tool_highlights[tool] or "SidekickCliTool"
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
    if item and item.agent and resolve(item.agent) then
      Panel.select(item.agent.id, true)
    end
  end
  picker = Snacks.picker.pick({
    source = "sidekick_agents",
    title = "Sidekick Agents · All",
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
      local icon = tool_icon(agent.tool)
      local tool_hl = tool_highlight(agent.tool)
      local ret = {}
      if agent.active then
        ret[#ret + 1] = { "◆ ", "SidekickCliTabSelected" }
      end
      if agent.pinned then
        ret[#ret + 1] = { "󰐃 ", "Special" }
      end
      local agent_marker = agent_icon()
      if agent_marker ~= "" then
        ret[#ret + 1] = { agent_marker .. " ", "SidekickCliInstalled" }
      end
      if icon ~= "" then
        ret[#ret + 1] = { icon .. " ", tool_hl }
        ret[#ret + 1] = { agent.tool, "Identifier" }
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
      local function render()
        if (not picker or not picker.closed) and generation == preview_generation then
          local view = initialized and save_preview_view(ctx) or nil
          if not initialized then
            ctx.preview:reset()
          end
          ctx.preview:set_title(ctx.item.agent.label)
          local lines, metadata = preview_lines(ctx.item.agent, render, Snacks)
          set_preview_lines(ctx, lines)
          set_preview_winbar(ctx, metadata)
          if view then
            restore_preview_view(ctx, view)
          else
            show_preview_tail(ctx)
          end
          initialized = true
        end
      end
      render()
      if picker then
        preview_timer = preview_timer or assert(vim.uv.new_timer())
        preview_timer:stop()
        preview_timer:start(500, 500, vim.schedule_wrap(render))
      end
    end,
    confirm = confirm,
    actions = {
      agent_confirm = function(picker, item)
        if not finish_rename(true) then
          confirm(picker, item)
        end
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
          ["<Esc>"] = { "agent_cancel", mode = { "n", "i" }, desc = "close picker" },
          ["<c-p>"] = { "agent_pin", mode = { "n", "i" }, desc = "pin/unpin agent" },
          ["<c-r>"] = { "agent_rename", mode = { "n", "i" }, desc = "rename agent" },
          ["<c-x>"] = { "agent_close", mode = { "n", "i" }, desc = "close agent" },
          ["<a-t>"] = { "agent_filter", mode = { "n", "i" }, desc = "cycle agent filter" },
          ["<c-d>"] = { "agent_cleanup", mode = { "n", "i" }, desc = "clean completed agents" },
        },
      },
    },
    on_close = function()
      if preview_timer and not preview_timer:is_closing() then
        preview_timer:stop()
        preview_timer:close()
      end
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
      pattern = { "SidekickCliStatus", "SidekickCliActivate", "SidekickCliPanel" },
      callback = refresh,
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

local function native(items)
  vim.ui.select(items, {
    prompt = "Select agent:",
    kind = "sidekick_agent",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item or not resolve(item) then
      return
    end
    local actions = {
      {
        label = "Open agent",
        action = function()
          Panel.select(item.id, true)
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

---@param items? {id:string,label:string,key:string,terminal:sidekick.cli.Terminal}[]
function M.open(items)
  items = items or Panel.picker_items()
  if #items == 0 then
    local cwd = require("sidekick.cli.session").cwd()
    return vim.schedule(function()
      require("sidekick.cli").new({ cwd = cwd })
    end)
  end
  local provider = Config.cli.agent_picker.provider
  local ok, Snacks = pcall(require, "snacks")
  local use_snacks = provider ~= "native" and ok and Snacks.picker and Snacks.picker.pick
  if use_snacks then
    return snacks(items, Snacks)
  end
  return native(M.items(items))
end

return M
