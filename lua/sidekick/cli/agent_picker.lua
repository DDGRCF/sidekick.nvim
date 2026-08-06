local Config = require("sidekick.config")
local Panel = require("sidekick.cli.panel")

local M = {}
local preview_cache = {} ---@type table<string,{at:number,output?:string,pending?:boolean,ready?:boolean,waiter?:fun()}>
local PREVIEW_CACHE_MAX = 64
local preview_ns = vim.api.nvim_create_namespace("sidekick.cli.agent_picker.preview")

local function enrich(item, git)
  local t = item.terminal
  local project = vim.fn.fnamemodify(t.cwd or "", ":t")
  local metadata = git[t.cwd or ""] or {}
  local branch = metadata.branch or ""
  local changed = metadata.changed_files or {}
  return {
    id = item.id,
    instance_id = t.instance_id,
    key = item.key,
    label = item.label,
    tool = t.tool.name,
    status = t.status or "idle",
    cwd = t.cwd or "",
    backend = t.mux_backend or t.backend or "terminal",
    branch = branch,
    changed_files = vim.deepcopy(changed),
    search = table.concat({
      item.label,
      "@" .. t.tool.name,
      "#" .. (t.status or "idle"),
      "%" .. project,
      branch,
      table.concat(changed, " "),
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
  return {
    ("%s · %s"):format(item.tool, item.label),
    ("%s Status: %s"):format(status_icon, status),
    ("%s Directory: %s"):format(directory_icon, vim.fn.fnamemodify(item.cwd, ":p:~")),
    ("%s Backend: %s"):format(backend_icon, item.backend),
    "",
    status = status,
    status_hl = "SidekickCliStatus" .. (terminal and status:gsub("^%l", string.upper) or "Error"),
    status_icon = status_icon,
    directory_icon = directory_icon,
    backend_icon = backend_icon,
  }
end

---@param buf number
---@param metadata table
local function highlight_metadata(buf, metadata)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local function highlight(row, col, end_col, hl_group)
    vim.api.nvim_buf_set_extmark(buf, preview_ns, row, col, { end_col = end_col, hl_group = hl_group })
  end

  highlight(0, 0, #metadata[1], "Title")
  local function highlight_field(row, icon, label, value_hl)
    local label_col = #icon + 1
    highlight(row, 0, #icon, value_hl)
    highlight(row, label_col, label_col + #label, "Special")
    highlight(row, label_col + #label + 1, #metadata[row + 1], value_hl)
  end
  highlight_field(1, metadata.status_icon, "Status:", metadata.status_hl)
  highlight_field(2, metadata.directory_icon, "Directory:", "Directory")
  highlight_field(3, metadata.backend_icon, "Backend:", "Identifier")
end

local function preview_lines(item, on_update, Snacks)
  local t = resolve(item)
  local lines = preview_metadata(item, t, Snacks)
  if not t then
    lines[#lines + 1] = "This agent is no longer available."
    return lines, lines
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
  return trim(lines), lines
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
  picker = Snacks.picker.pick({
    source = "sidekick_agents",
    title = "Sidekick Agents",
    finder = function()
      return vim.tbl_map(function(agent)
        return { text = agent.search, agent = agent }
      end, M.items(items, refresh))
    end,
    format = function(item)
      local t = resolve(item.agent)
      local status = t and t.status or "error"
      local state = status:gsub("^%l", string.upper)
      return {
        { item.agent.label, "SidekickCliStatus" .. state },
        { "  " .. vim.fn.fnamemodify(item.agent.cwd, ":p:~"), "Directory" },
      }
    end,
    preview = function(ctx)
      preview_generation = preview_generation + 1
      local generation = preview_generation
      local function render()
        if (not picker or not picker.closed) and generation == preview_generation then
          ctx.preview:reset()
          ctx.preview:set_title(ctx.item.agent.label)
          local lines, metadata = preview_lines(ctx.item.agent, render, Snacks)
          ctx.preview:set_lines(lines)
          highlight_metadata(ctx.buf, metadata)
        end
      end
      render()
      if picker then
        preview_timer = preview_timer or assert(vim.uv.new_timer())
        preview_timer:stop()
        preview_timer:start(500, 500, vim.schedule_wrap(render))
      end
    end,
    confirm = function(picker, item)
      picker:close()
      if item and item.agent and resolve(item.agent) then
        Panel.select(item.agent.id)
      end
    end,
    actions = {
      agent_pin = function(picker, item)
        for _, agent in ipairs(selected(picker, item)) do
          if resolve(agent) then
            Panel.pin(agent.id)
          end
        end
        reopen(picker)
      end,
      agent_rename = function(picker, item)
        local agent = selected(picker, item)[1]
        picker:close()
        if agent and resolve(agent) then
          vim.schedule(function()
            Panel.rename(nil, agent.id)
          end)
        end
      end,
      agent_close = function(picker, item)
        for _, agent in ipairs(selected(picker, item)) do
          if resolve(agent) then
            Panel.close(agent.id)
          end
        end
        reopen(picker)
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
          ["<c-p>"] = { "agent_pin", mode = { "n", "i" }, desc = "pin/unpin agent" },
          ["<c-r>"] = { "agent_rename", mode = { "n", "i" }, desc = "rename agent" },
          ["<c-x>"] = { "agent_close", mode = { "n", "i" }, desc = "close agent" },
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
      pattern = "SidekickCliStatus",
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
          Panel.select(item.id)
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
