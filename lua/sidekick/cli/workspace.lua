local Config = require("sidekick.config")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

local M = { did_setup = false, restoring = false, partial = false }

local state_key = "cli-workspace"
local version = 1

---@class sidekick.cli.WorkspaceAgent
---@field key string
---@field tool string
---@field cwd string
---@field backend string
---@field mux_session? string
---@field instance_id string
---@field title? string
---@field conversation? sidekick.cli.Conversation
---@field status? sidekick.cli.ActivityStatus

---@class sidekick.cli.WorkspaceState
---@field version integer
---@field saved_at integer
---@field agents sidekick.cli.WorkspaceAgent[]
---@field panels sidekick.cli.WorkspacePanel[]

local function terminal_key(t)
  return require("sidekick.cli.panel").workspace_key(t)
end

local function logical(t)
  return t.parent or t
end

---@return sidekick.cli.WorkspaceState
function M.snapshot()
  local Panel = require("sidekick.cli.panel")
  local panels = Panel.snapshot()
  local wanted = {}
  for _, p in ipairs(panels) do
    for _, key in ipairs(p.order) do
      wanted[key] = true
    end
  end

  local agents = {}
  for _, t in pairs(require("sidekick.cli.terminal").terminals) do
    local key = terminal_key(t)
    if wanted[key] then
      local session = logical(t)
      agents[#agents + 1] = {
        key = key,
        tool = t.tool.name,
        cwd = t.cwd,
        backend = session.backend or t.mux_backend or "terminal",
        mux_session = session.mux_session or t.mux_session,
        instance_id = t.instance_id,
        title = t.title or session.title,
        conversation = Resume.capture(t),
        status = t.status,
      }
    end
  end
  table.sort(agents, function(a, b)
    return a.key < b.key
  end)
  return { version = version, saved_at = os.time(), agents = agents, panels = panels }
end

---@param opts? {silent?:boolean}
---@return sidekick.cli.WorkspaceState?
---@return string? error
function M.save(opts)
  local state = M.snapshot()
  local ok, err = Util.set_state(state_key, state)
  if not ok then
    Util.error("Failed to save Sidekick workspace: " .. tostring(err))
    return nil, err
  end
  M.partial = false
  if not (opts and opts.silent) then
    Util.info(("Saved Sidekick workspace with %d agent(s)"):format(#state.agents))
  end
  return state
end

local function matches(session, saved)
  local base = logical(session)
  return session.tool.name == saved.tool
    and session.instance_id == saved.instance_id
    and Session.cwd({ cwd = session.cwd }) == Session.cwd({ cwd = saved.cwd })
    and base.backend == saved.backend
end

local function as_terminal(session)
  session.hidden = true
  local state = require("sidekick.cli.state").get_state(session)
  state = require("sidekick.cli.state").attach(state, { show = false, focus = false })
  return state.terminal
end

---@param saved sidekick.cli.WorkspaceAgent
---@param discovered sidekick.cli.Session[]
---@return sidekick.cli.Terminal?
---@return string? error
---@return string? mode
local function restore_agent(saved, discovered)
  for _, field in ipairs({ "key", "tool", "cwd", "backend", "instance_id" }) do
    if type(saved[field]) ~= "string" or saved[field] == "" then
      return nil, ("invalid saved agent field `%s`"):format(field)
    end
  end
  for _, terminal in pairs(require("sidekick.cli.terminal").terminals) do
    if matches(terminal, saved) then
      if not terminal.closed and terminal:is_running() then
        local tool = Config.tools()[saved.tool]
        if saved.conversation and (not tool or Resume.verify(tool, terminal, saved) == false) then
          return nil, "attached terminal conversation does not match the saved workspace"
        end
        return terminal, nil, "attached"
      end
      terminal:close()
    end
  end
  for _, session in ipairs(discovered) do
    if matches(session, saved) and (not saved.mux_session or session.mux_session == saved.mux_session) then
      local terminal = as_terminal(session)
      if terminal and terminal:is_running() then
        local tool = Config.tools()[saved.tool]
        if saved.conversation and (not tool or Resume.verify(tool, terminal, saved) == false) then
          terminal:close()
          return nil, "live multiplexer session conversation could not be verified"
        end
        return terminal, nil, "mux"
      end
      return nil, "live session cannot be attached inside the Sidekick panel"
    end
  end

  local tool = Config.tools()[saved.tool]
  if not tool or vim.fn.executable(tool.cmd[1]) ~= 1 then
    return nil, ("CLI tool `%s` is not installed"):format(saved.tool)
  end
  local cmd, mode = Resume.command(tool, saved)
  if not cmd then
    return nil, ("CLI tool `%s` has no exact resumable conversation id"):format(saved.tool), mode
  end
  if not Resume.preflight(tool, saved) then
    return nil, ("CLI tool `%s` could not verify the saved conversation id"):format(saved.tool)
  end
  if vim.fn.isdirectory(saved.cwd) ~= 1 then
    return nil, ("saved working directory no longer exists: %s"):format(saved.cwd)
  end
  local backend = Session.backends[saved.backend] and saved.backend or "terminal"
  local session = Session.new({
    tool = tool:clone({
      cmd = cmd,
      env = vim.tbl_extend("force", vim.deepcopy(tool.env or {}), Resume.env(tool, saved) or {}),
    }),
    cwd = saved.cwd,
    backend = backend,
    instance_id = saved.instance_id,
    title = saved.title,
    conversation = saved.conversation,
    hidden = true,
  })
  local terminal = as_terminal(session)
  if not terminal or not terminal:is_running() then
    if terminal then
      terminal:close()
    end
    return nil, ("failed to start native `%s` resume command"):format(saved.tool)
  end
  if Resume.verify(tool, terminal, saved) == false then
    terminal:close()
    return nil, ("native `%s` resume verification failed"):format(saved.tool)
  end
  return terminal, nil, mode
end

local function panel_tab(saved, original, claimed)
  local tabs = vim.api.nvim_list_tabpages()
  for _, tab in ipairs(tabs) do
    if not claimed[tab] and vim.t[tab].sidekick_workspace_id == saved.tab.id then
      return tab
    end
  end
  local cwd_matches = {}
  if type(saved.tab.cwd) == "string" then
    local wanted = Session.cwd({ cwd = saved.tab.cwd })
    for _, tab in ipairs(tabs) do
      if not claimed[tab] then
        local win = vim.api.nvim_tabpage_list_wins(tab)[1]
        local cwd = win and vim.api.nvim_win_call(win, vim.fn.getcwd) or nil
        if cwd and Session.cwd({ cwd = cwd }) == wanted then
          cwd_matches[#cwd_matches + 1] = tab
        end
      end
    end
  end
  if #cwd_matches == 1 then
    return cwd_matches[1]
  end
  if not Config.cli.workspace.restore_tabpages then
    return not claimed[original] and original or nil
  end
  vim.cmd.tabnew()
  local tab = vim.api.nvim_get_current_tabpage()
  vim.t[tab].sidekick_workspace_id = saved.tab.id
  if type(saved.tab.cwd) == "string" and vim.fn.isdirectory(saved.tab.cwd) == 1 then
    vim.cmd.tcd(vim.fn.fnameescape(saved.tab.cwd))
  end
  return tab
end

local function validate(saved)
  if type(saved) ~= "table" or saved.version ~= version then
    return "incompatible workspace version"
  end
  if not vim.islist(saved.agents) or not vim.islist(saved.panels) then
    return "agents and panels must be arrays"
  end
  local keys, referenced = {}, {}
  for _, agent in ipairs(saved.agents) do
    if type(agent) ~= "table" then
      return "agent must be an object"
    end
    for _, field in ipairs({ "key", "tool", "cwd", "backend", "instance_id" }) do
      if type(agent[field]) ~= "string" or agent[field] == "" then
        return ("invalid agent field `%s`"):format(field)
      end
    end
    if keys[agent.key] then
      return "duplicate agent key"
    end
    keys[agent.key] = true
  end
  for _, panel in ipairs(saved.panels) do
    if
      type(panel) ~= "table"
      or type(panel.tab) ~= "table"
      or type(panel.tab.id) ~= "string"
      or not vim.islist(panel.order)
      or (panel.pinned ~= nil and type(panel.pinned) ~= "table")
    then
      return "invalid panel"
    end
    for _, key in ipairs(panel.order) do
      if type(key) ~= "string" or not keys[key] then
        return "panel references an unknown agent"
      end
      referenced[key] = true
    end
  end
  for key in pairs(keys) do
    if not referenced[key] then
      return "workspace contains an agent without a panel"
    end
  end
end

---@param agent sidekick.cli.WorkspaceAgent
local function lacks_exact_conversation(agent)
  local conversation = agent.conversation
  return type(conversation) ~= "table"
    or conversation.provider ~= agent.tool
    or conversation.resumable ~= true
    or type(conversation.id) ~= "string"
    or conversation.id == ""
    or conversation.id:sub(1, 1) == "-"
    or #conversation.id > 4096
    or conversation.id:find("[%c%s]")
end

---@param saved sidekick.cli.WorkspaceState
---@param keys table<string,boolean>
local function discard_agents(saved, keys)
  if vim.tbl_isempty(keys) then
    return true
  end
  saved.agents = vim.tbl_filter(function(agent)
    return not keys[agent.key]
  end, saved.agents)
  for _, panel in ipairs(saved.panels) do
    panel.order = vim.tbl_filter(function(key)
      return not keys[key]
    end, panel.order)
    if panel.pinned then
      for key in pairs(keys) do
        panel.pinned[key] = nil
      end
    end
  end
  local ok, err = Util.set_state(state_key, saved)
  if not ok then
    Util.error("Failed to discard unresumable Sidekick agents: " .. tostring(err))
  end
  return ok
end

---@return {restored:integer,failed:{agent:sidekick.cli.WorkspaceAgent,error:string}[],modes:table<string,integer>} result
function M.restore()
  if M.restoring then
    return { restored = 0, failed = {}, modes = {} }
  end
  local saved = Util.get_state(state_key)
  local invalid = validate(saved)
  if invalid then
    Util.warn("No compatible Sidekick workspace was saved: " .. invalid)
    return { restored = 0, failed = {}, modes = {} }
  end
  M.restoring = true
  local original = vim.api.nvim_get_current_tabpage()
  local restored, restore_modes = {}, {}
  local ok, result = xpcall(function()
    Session.setup()
    local discovered = Session.sessions()

    local failed, modes, discarded = {}, {}, {}
    for _, agent in ipairs(saved.agents or {}) do
      local agent_ok, terminal, err, mode = pcall(restore_agent, agent, discovered)
      if agent_ok and terminal then
        restored[agent.key] = terminal
        restore_modes[agent.key] = mode
        modes[mode] = (modes[mode] or 0) + 1
      else
        if mode == "unsupported" and lacks_exact_conversation(agent) then
          discarded[agent.key] = true
        end
        failed[#failed + 1] = {
          agent = agent,
          error = agent_ok and (err or "unknown restore error") or tostring(terminal),
        }
      end
    end

    local panel_failures = {}
    local claimed, used = {}, {}
    for _, p in ipairs(saved.panels or {}) do
      local panel_ok, panel_err = pcall(function()
        local tab = panel_tab(p, original, claimed)
        if tab and vim.api.nvim_tabpage_is_valid(tab) then
          claimed[tab] = true
          vim.api.nvim_set_current_tabpage(tab)
          vim.t[tab].sidekick_workspace_id = p.tab.id
          if type(p.tab.cwd) == "string" and vim.fn.isdirectory(p.tab.cwd) == 1 then
            vim.cmd.tcd(vim.fn.fnameescape(p.tab.cwd))
          end
          require("sidekick.cli.panel").restore(p, restored)
          for _, key in ipairs(p.order) do
            used[key] = true
          end
        else
          error("no native tabpage is available for the saved panel")
        end
      end)
      if not panel_ok then
        panel_failures[#panel_failures + 1] = tostring(panel_err)
      end
    end
    for key, terminal in pairs(restored) do
      if not used[key] and restore_modes[key] ~= "attached" then
        terminal:close()
        restored[key] = nil
        failed[#failed + 1] = { agent = { key = key, tool = terminal.tool.name }, error = "panel restore failed" }
      end
    end
    local restored_count = vim.tbl_count(restored)
    if #failed == 0 then
      Util.info(("Restored %d Sidekick agent conversation(s)"):format(restored_count))
    else
      local lines = { ("Restored %d agent(s); %d failed:"):format(restored_count, #failed) }
      for _, failure in ipairs(failed) do
        lines[#lines + 1] = ("- %s (%s): %s"):format(
          failure.agent.title or failure.agent.tool,
          failure.agent.tool,
          failure.error
        )
      end
      Util.warn(lines)
    end
    if #panel_failures > 0 then
      Util.warn(("%d Sidekick panel(s) could not be restored"):format(#panel_failures))
    end
    local discarded_ok = discard_agents(saved, discarded)
    M.partial = (#failed > vim.tbl_count(discarded)) or #panel_failures > 0 or not discarded_ok
    return { restored = restored_count, failed = failed, modes = modes, panel_failures = panel_failures }
  end, debug.traceback)
  M.restoring = false
  if vim.api.nvim_tabpage_is_valid(original) then
    vim.api.nvim_set_current_tabpage(original)
  end
  if not ok then
    for key, terminal in pairs(restored) do
      if restore_modes[key] ~= "attached" then
        terminal:close()
      end
    end
    M.partial = true
    Util.error("Failed to restore Sidekick workspace: " .. tostring(result))
    return { restored = 0, failed = {}, modes = {} }
  end
  return result
end

function M.status()
  local state = Util.get_state(state_key)
  if type(state) ~= "table" or state.version ~= version then
    Util.info("No Sidekick workspace is saved")
    return
  end
  Util.info(
    ("Sidekick workspace: %d agent(s), %d panel(s), saved %s"):format(
      #(state.agents or {}),
      #(state.panels or {}),
      os.date("%Y-%m-%d %H:%M:%S", state.saved_at or 0)
    )
  )
  return state
end

function M.clear()
  Util.del_state(state_key)
  M.partial = false
  Util.info("Cleared the saved Sidekick workspace")
end

function M.setup()
  if M.did_setup or not Config.cli.workspace.enabled then
    return
  end
  M.did_setup = true
  local autosave = Util.debounce(function()
    if Config.cli.workspace.autosave and not M.restoring and not M.partial then
      M.save({ silent = true })
    end
  end, 100)
  vim.api.nvim_create_autocmd("User", {
    group = Config.augroup,
    pattern = {
      "SidekickCliActivate",
      "SidekickCliAttach",
      "SidekickCliDetach",
      "SidekickCliStatus",
      "SidekickCliTitle",
      "SidekickCliPanel",
    },
    callback = function()
      -- Do not enqueue a delayed save during restore: by the time the timer
      -- fires `restoring` may already be false and failed agents would be
      -- silently removed from the only retryable snapshot.
      if not M.restoring then
        autosave()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = Config.augroup,
    callback = function()
      if Config.cli.workspace.autosave and not M.restoring and not M.partial then
        M.save({ silent = true })
      end
    end,
  })
  if Config.cli.workspace.autorestore then
    vim.schedule(function()
      if not M.restoring and Util.get_state(state_key) then
        M.restore()
      end
    end)
  end
end

return M
