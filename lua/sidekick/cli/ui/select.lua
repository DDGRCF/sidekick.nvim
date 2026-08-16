local Config = require("sidekick.config")
local History = require("sidekick.cli.history")
local Icons = require("sidekick.cli.icons")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select if only one tool matches the filter
---@field new? boolean Select a tool for a new independent agent

local M = {}

local function display_title(value)
  value = vim.trim(value:gsub("[%c\r\n]+", " "):gsub("%s+", " "))
  local max = math.max(1, Config.cli.win.tabs.max_name_length)
  if vim.api.nvim_strwidth(value) <= max then
    return value
  end
  local ret = ""
  for _, char in ipairs(Util.split_graphemes(value)) do
    if vim.api.nvim_strwidth(ret .. char .. "…") > max then
      break
    end
    ret = ret .. char
  end
  return ret .. "…"
end

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  if require("sidekick.cli.workspace").after_restore(function()
    M.select(opts)
  end) then
    return
  end
  local tools
  if opts.new then
    tools = vim.tbl_map(function(tool)
      return {
        tool = tool,
        installed = vim.fn.executable(tool.cmd[1]) == 1,
        new = true,
      }
    end, vim.tbl_values(Config.tools()))
    table.sort(tools, function(a, b)
      return a.tool.name < b.tool.name
    end)
  else
    tools = require("sidekick.cli.state").get(opts.filter)
  end
  History.sort(tools, "tools", function(state)
    return state.tool.name
  end)

  ---@param state? sidekick.cli.State
  local on_select = function(state)
    if state and not state.installed then
      M.on_missing(state.tool)
      state = nil
    end
    if state then
      History.record("tools", state.tool.name)
    end
    opts.cb(state)
  end

  if #tools == 0 then
    Util.warn("No tools match the given filter")
    return
  elseif #tools == 1 and opts.auto then
    on_select(tools[1])
    return
  end

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = "Select CLI tool:",
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = { format = M.format },
  }

  vim.ui.select(tools, select_opts, on_select)
end

---@param tool sidekick.cli.Tool
function M.on_missing(tool)
  Util.error(("Tool `%s` is not installed"):format(tool.name))
  if tool.url then
    local ok, err = vim.ui.open(tool.url)
    if ok then
      Util.info(("Opening %s in your browser..."):format(tool.url))
    else
      Util.error(("Failed to open %s: %s"):format(tool.url, err))
    end
  end
end

---@param state sidekick.cli.State|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  local sw = vim.api.nvim_strwidth
  local ret = {} ---@type snacks.picker.Highlight[]

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"

  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end
  local icon = Icons.tool(state.tool.name)
  ret[#ret + 1] = { icon or Config.ui.icons[status], status_hl }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { state.tool.name }
  local len = sw(state.tool.name) + 2
  if state.new or not state.session then
    ret[#ret + 1] = { " · new", "Special" }
    len = len + 6
  elseif state.session then
    local identity = state.session.title
    if not identity or identity == "" then
      identity = "#" .. (state.session.instance_id or state.session.id):sub(-8)
    end
    identity = display_title(identity)
    ret[#ret + 1] = { " · " .. identity, "Title" }
    len = len + 3 + sw(identity)
  end
  if state.session then
    ret[#ret + 1] = { string.rep(" ", math.max(1, 12 - len)) }

    if state.external then
      ret[#ret + 1] = { Config.ui.icons["external_" .. status], status_hl }
    else
      ret[#ret + 1] = { Config.ui.icons["terminal_" .. status], status_hl }
    end
    len = len + 2

    -- Keep this for debugging purposes
    -- ret[#ret + 1] = { table.concat(state.session.pids or {}, ",") }

    local backends = {} ---@type string[]
    backends[#backends + 1] = state.session.mux_backend or state.session.backend
    if state.external then
      backends[#backends + 1] = state.session.mux_session
    end
    local backend = ("[%s]"):format(table.concat(backends, ":"))

    ret[#ret + 1] = { backend, "Special" }
    len = 12 + sw(backend)
    ret[#ret + 1] = { string.rep(" ", math.max(1, 40 - len)) }
    if picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = state.session.cwd
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      ret[#ret + 1] = { vim.fn.fnamemodify(state.session.cwd, ":p:~"), "Directory" }
    end
  end
  return ret
end

return M
