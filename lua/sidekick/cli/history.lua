local Util = require("sidekick.util")

local M = {}

local state_key = "cli-agent-selection"
local max_history = 100

---@alias sidekick.cli.HistoryKind "agents"|"tools"
---@alias sidekick.cli.HistoryEntry {count:integer,last:integer}
---@class sidekick.cli.HistoryState
---@field sequence integer
---@field latest table<sidekick.cli.HistoryKind,integer>
---@field agents table<string,sidekick.cli.HistoryEntry>
---@field tools table<string,sidekick.cli.HistoryEntry>
---@type sidekick.cli.HistoryState?
local state

local function number(value)
  return math.max(0, math.floor(tonumber(value) or 0))
end

---@param entries table<string,sidekick.cli.HistoryEntry>
---@return integer
local function latest_entry(entries)
  local latest = 0
  for _, entry in pairs(entries) do
    if type(entry) == "table" then
      latest = math.max(latest, number(entry.last))
    end
  end
  return latest
end

local function get_state()
  if state then
    return state
  end

  local saved = Util.get_state(state_key)
  saved = type(saved) == "table" and saved or {}
  local agents = type(saved.agents) == "table" and saved.agents or {}
  local tools = type(saved.tools) == "table" and saved.tools or {}
  local saved_latest = type(saved.latest) == "table" and saved.latest or {}
  local agents_latest = number(saved_latest.agents)
  local tools_latest = number(saved_latest.tools)

  -- Older versions stored one global sequence and only the agent entries.
  agents_latest = math.max(agents_latest, latest_entry(agents))
  tools_latest = math.max(tools_latest, latest_entry(tools))
  state = {
    sequence = math.max(number(saved.sequence), agents_latest, tools_latest),
    latest = { agents = agents_latest, tools = tools_latest },
    agents = agents,
    tools = tools,
  }
  return state
end

---@param kind sidekick.cli.HistoryKind
---@return table<string,sidekick.cli.HistoryEntry>
local function entries(kind)
  local current = get_state()
  current[kind] = type(current[kind]) == "table" and current[kind] or {}
  return current[kind]
end

---@param values table<string,sidekick.cli.HistoryEntry>
local function trim(values)
  local keys = vim.tbl_keys(values)
  if #keys <= max_history then
    return
  end
  table.sort(keys, function(a, b)
    local a_entry = type(values[a]) == "table" and values[a] or {}
    local b_entry = type(values[b]) == "table" and values[b] or {}
    local a_last = number(a_entry.last)
    local b_last = number(b_entry.last)
    if a_last ~= b_last then
      return a_last < b_last
    end
    return tostring(a) < tostring(b)
  end)
  for i = 1, #keys - max_history do
    values[keys[i]] = nil
  end
end

---@param kind sidekick.cli.HistoryKind
---@param key string
function M.record(kind, key)
  if (kind ~= "agents" and kind ~= "tools") or type(key) ~= "string" or key == "" then
    return
  end
  local current = get_state()
  local values = entries(kind)
  current.sequence = current.sequence + 1
  local entry = values[key]
  if type(entry) ~= "table" then
    entry = { count = 0, last = 0 }
  end
  entry.count = number(entry.count) + 1
  entry.last = current.sequence
  values[key] = entry
  current.latest[kind] = current.sequence
  trim(values)
  Util.set_state(state_key, current)
end

---@param kind sidekick.cli.HistoryKind
---@param key string
---@return sidekick.cli.HistoryEntry?
function M.get(kind, key)
  if (kind ~= "agents" and kind ~= "tools") or type(key) ~= "string" or key == "" then
    return nil
  end
  local entry = entries(kind)[key]
  if type(entry) ~= "table" then
    return nil
  end
  return { count = number(entry.count), last = number(entry.last) }
end

---@generic T
---@param items T[]
---@param kind sidekick.cli.HistoryKind
---@param key fun(item:T):string
function M.sort(items, kind, key)
  if kind ~= "agents" and kind ~= "tools" then
    return
  end
  local values = entries(kind)
  local latest = get_state().latest[kind]
  local indexed = {} ---@type {item:T,index:integer,count:integer,last:integer,latest:boolean}[]
  for index, item in ipairs(items) do
    local item_key = key(item)
    local entry = type(item_key) == "string" and values[item_key] or nil
    local count = type(entry) == "table" and number(entry.count) or 0
    local last = type(entry) == "table" and number(entry.last) or 0
    indexed[#indexed + 1] = {
      item = item,
      index = index,
      count = count,
      last = last,
      latest = latest > 0 and last == latest,
    }
  end
  table.sort(indexed, function(a, b)
    if a.latest ~= b.latest then
      return a.latest
    end
    if a.count ~= b.count then
      return a.count > b.count
    end
    if a.last ~= b.last then
      return a.last > b.last
    end
    return a.index < b.index
  end)
  for index, value in ipairs(indexed) do
    items[index] = value.item
  end
end

---@param terminal sidekick.cli.Terminal
---@return string
function M.agent_key(terminal)
  return terminal.sid or terminal.id or ""
end

return M
