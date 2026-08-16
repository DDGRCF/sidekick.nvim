local Config = require("sidekick.config")

local M = {}

---@class sidekick.lsp.Status
---@field busy boolean
---@field kind "Normal" | "Error" | "Warning" | "Inactive"
---@field message? string

---@class sidekick.cli.Status
---@field id string
---@field tool string
---@field cwd string
---@field instance_id? string
---@field title? string
---@field status? sidekick.cli.ActivityStatus
---@field active? boolean Whether this is the active agent in the current native tabpage
---@field unread? boolean Whether the agent has output that has not been viewed
---@field last_activity? integer Timestamp of the last activity in milliseconds

---@class sidekick.cli.Summary
---@field total integer
---@field active integer
---@field starting integer
---@field working integer
---@field waiting integer
---@field done integer
---@field error integer
---@field unread integer
---@field attention integer Sessions that need user attention

local status = {} ---@type table<integer, sidekick.lsp.Status>
local cli_sessions = {} ---@type table<string, sidekick.cli.Status>
local cli_last_update = 0

local levels = {
  Normal = vim.log.levels.INFO,
  Warning = vim.log.levels.WARN,
  Error = vim.log.levels.ERROR,
  Inactive = vim.log.levels.WARN,
}

---@param session sidekick.cli.Session
---@param active? sidekick.cli.Session
---@return sidekick.cli.Status
local function session_status(session, active)
  return {
    id = session.id,
    tool = session.tool.name,
    cwd = session.cwd,
    instance_id = session.instance_id,
    title = session.title,
    status = session.status,
    active = active == session,
    unread = session._sidekick_unread == true,
    last_activity = session.last_activity,
  }
end

local function update_cli_status()
  local Session = require("sidekick.cli.session")
  local active = require("sidekick.cli.panel").active()
  cli_sessions = {}
  for id, session in pairs(Session.attached()) do
    cli_sessions[id] = session_status(session, active)
  end
  cli_last_update = vim.uv.now()
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function update_cli_event(ev)
  local data = ev.data or {}
  local id = data.id
  if not id then
    return update_cli_status()
  end
  if ev.match == "SidekickCliDetach" then
    cli_sessions[id] = nil
  elseif ev.match == "SidekickCliActivate" then
    for session_id, item in pairs(cli_sessions) do
      item.active = session_id == id
    end
  elseif ev.match == "SidekickCliActivity" and cli_sessions[id] then
    cli_sessions[id].last_activity = data.last_activity
  else
    local session = require("sidekick.cli.session").get(id)
    if session then
      cli_sessions[id] = session_status(session, require("sidekick.cli.panel").active())
    else
      cli_sessions[id] = nil
    end
  end
end

---@param res sidekick.lsp.Status
---@type lsp.Handler
function M.on_status(err, res, ctx)
  if err then
    return
  end
  status[ctx.client_id] = vim.deepcopy(res)
  local level = levels[res.kind or "Normal"] or vim.log.levels.INFO

  if res.message and level >= Config.copilot.status.level then
    local msg = "**Copilot:** " .. res.message
    if msg:find("not signed") then
      if package.loaded.copilot then
        msg = msg .. "\nPlease use `:Copilot auth` to sign in."
      else
        msg = msg .. "\nPlease use `:LspCopilotSignIn` to sign in."
      end
    end
    require("sidekick.util").notify(msg, res.kind == "Error" and vim.log.levels.ERROR or vim.log.levels.WARN)
  end
end

---@param client vim.lsp.Client
function M.attach(client)
  client.handlers.didChangeStatus = M.on_status
end

---@param buf? integer
---@return sidekick.lsp.Status?
function M.get(buf)
  if not Config.copilot.status.enabled then
    return
  end
  local client = Config.get_client(buf)
  return client and (status[client.id] or { busy = false, kind = "Normal" }) or nil
end

function M.setup()
  if Config.copilot.status.enabled then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = Config.augroup,
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if client and Config.is_copilot(client) then
          M.attach(client)
        end
      end,
    })
    for _, client in ipairs(Config.get_clients()) do
      M.attach(client)
    end
  end

  vim.api.nvim_create_autocmd("User", {
    group = Config.augroup,
    pattern = {
      "SidekickCliActivate",
      "SidekickCliAttach",
      "SidekickCliDetach",
      "SidekickCliStatus",
      "SidekickCliActivity",
      "SidekickCliAttention",
      "SidekickCliTitle",
    },
    callback = update_cli_event,
  })

  update_cli_status()
end

--- Get CLI session status
---@return sidekick.cli.Status[]
function M.cli()
  local now = vim.uv.now()
  if now - cli_last_update > 5000 then
    -- update periodically to detect sessions where `is_running()` returns false
    -- can happen when an external process stopped
    update_cli_status()
    cli_last_update = now
  end
  return vim.tbl_values(cli_sessions)
end

--- Get an aggregate view of attached CLI activity.
---@return sidekick.cli.Summary
function M.summary()
  local ret = {
    total = 0,
    active = 0,
    starting = 0,
    working = 0,
    waiting = 0,
    done = 0,
    error = 0,
    unread = 0,
    attention = 0,
  }
  for _, item in ipairs(M.cli()) do
    ret.total = ret.total + 1
    if item.active then
      ret.active = ret.active + 1
    end
    local state = item.status or "idle"
    if ret[state] ~= nil then
      ret[state] = ret[state] + 1
    end
    if item.unread then
      ret.unread = ret.unread + 1
    end
    if item.unread or state == "waiting" or state == "error" then
      ret.attention = ret.attention + 1
    end
  end
  return ret
end

return M
