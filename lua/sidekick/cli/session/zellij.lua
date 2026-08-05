local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Zellij: sidekick.cli.Session
---@field zellij_pane_id string
---@field zellij string
local M = {}
M.__index = M
M.priority = 50
M.external = false

M.tpl = [[
layout {
    pane command="{cmd}" {
      borderless true
      focus true
      name "{name}"
      close_on_exit true
      {args}
   }
}
session_serialization false
]]

---@return sidekick.cli.terminal.Cmd?
---@param create boolean
function M:terminal(create)
  local layout = M.tpl
  layout = layout:gsub("{cmd}", self.tool.cmd[1])
  layout = layout:gsub("{name}", self.tool.name)
  if #self.tool.cmd == 1 then
    layout = layout:gsub("{args}", "")
  else
    local args = vim.list_slice(self.tool.cmd, 2)
    layout = layout:gsub("{args}", "args " .. table.concat(
      vim.tbl_map(function(a)
        return ("%q"):format(a)
      end, args),
      " "
    )) --[[@as string]]
  end

  local session = self.started and self.mux_session or self.sid

  local layout_file = Config.state("zellij-layout-" .. session .. ".kdl")
  vim.fn.writefile(vim.split(layout, "\n"), layout_file)
  Util.set_state(session, {
    tool = self.tool.name,
    cwd = self.cwd,
    instance_id = self.instance_id,
    title = self.title,
    conversation = self.conversation,
  })

  local cmd = { "zellij", "--layout", layout_file, "attach" }
  if create then
    cmd[#cmd + 1] = "--create"
  end
  cmd[#cmd + 1] = session
  return {
    cmd = cmd,
    env = {
      ZELLIJ = false,
      ZELLIJ_SESSION_NAME = false,
      ZELLIJ_PANE_ID = false,
    },
  }
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if vim.env.ZELLIJ and Config.cli.mux.create ~= "terminal" then
    Util.warn({
      ("Zellij does not support `opts.cli.mux.create = %q`."):format(Config.cli.mux.create),
      ("Falling back to `%q`."):format("terminal"),
      "Please update your config.",
    })
  end
  -- Zellij's scripting API is too limited, so
  -- always run embedded sessions
  return self:terminal(true)
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  -- Zellij's scripting API is too limited, so
  -- always run embedded sessions
  return self:terminal(false)
end

function M.sessions()
  local sessions = Util.exec({ "zellij", "list-sessions", "-ns" }, { notify = false }) or {}
  local ret = {} ---@type sidekick.cli.session.State[]
  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()
  local pid_cache = {}

  local function find_pids(state, session_name)
    local cwd = require("sidekick.cli.session").cwd({ cwd = state.cwd })
    local key = table.concat({ state.tool, cwd, session_name }, "\31")
    if not pid_cache[key] then
      local tool = Config.tools()[state.tool]
      pid_cache[key] = {}
      if tool then
        for _, proc in ipairs(procs:list()) do
          local env = proc.env or {}
          if
            tool:is_proc(proc)
            and proc.cwd
            and require("sidekick.cli.session").cwd({ cwd = proc.cwd }) == cwd
            and env.ZELLIJ_SESSION_NAME == session_name
          then
            pid_cache[key][#pid_cache[key] + 1] = proc.pid
          end
        end
      end
    end
    return pid_cache[key]
  end

  for _, s in ipairs(sessions) do
    local state = Util.get_state(s)
    if state then
      local pids = find_pids(state, s)
      -- A surviving Zellij session is not sufficient: the agent pane may
      -- already have exited while another pane keeps the session alive.
      if #pids > 0 then
        ret[#ret + 1] = {
          id = "zellij: " .. s,
          cwd = state.cwd,
          tool = state.tool,
          mux_session = s,
          pids = pids,
          instance_id = state.instance_id,
          title = state.title,
          conversation = state.conversation,
        }
      end
    end
  end

  return ret
end

-- function M:dump()
--   do
--     -- sigh, another broken zellij feature
--     -- dump-screen doesn't include ansi escape sequences
--     -- just the raw text
--     return
--   end
--   local tmp = Config.state("zellij-dump.txt")
--   local ok = Util.exec({ "zellij", "-s", self.mux_session, "action", "dump-screen", "-f", tmp }, {
--     notify = true,
--   })
--   if not ok then
--     return
--   end
--   local f = io.open(tmp, "r")
--   if not f then
--     return
--   end
--   vim.fn.delete(tmp)
--   local content = f:read("*a")
--   f:close()
--   return content
-- end

return M
