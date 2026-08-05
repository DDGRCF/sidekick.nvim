local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}

M.backends = {} ---@type table<string,sidekick.cli.Session>
M.did_setup = false
M._attached = {} ---@type table<string,sidekick.cli.Session>

---@class sidekick.cli.session.State
---@field id string unique id of the running tool (typically pid of tool)
---@field cwd string
---@field tool sidekick.cli.Tool|string
---@field pids? integer[] list of pids associated with this session
---@field backend? string
---@field started? boolean
---@field external? boolean external sessions won't be opened in a terminal
---@field parent? sidekick.cli.Session
---@field mux_session? string
---@field mux_backend? string
---@field instance_id? string unique agent instance id
---@field title? string user-facing agent title
---@field conversation? sidekick.cli.Conversation native CLI conversation metadata
---@field hidden? boolean start without adding the terminal to a panel

---@class sidekick.cli.Conversation
---@field id? string stable provider conversation id
---@field provider? string
---@field resumable? boolean
---@field data? table<string,any> provider-owned serializable metadata

---@alias sidekick.cli.session.Opts sidekick.cli.session.State|{cwd?:string,id?:string}

---@class sidekick.cli.Session: sidekick.cli.session.State
---@field sid string unique id based on tool, cwd, and instance
---@field tool sidekick.cli.Tool
---@field backend string
---@field dump? fun(self:sidekick.cli.Session):string?
local B = {}
B.__index = B
B.priority = 0

--- Send text to the session
---@param text string
function B:send(text)
  error("Backend:send() not implemented")
end

--- Initialize the session backend (optional hook)
function B:init() end

--- Submit the current input to the session
function B:submit()
  error("Backend:submit() not implemented")
end

--- Attach to an existing session
--- If the backend returns a Cmd, a new terminal session will be spawned
---@return sidekick.cli.terminal.Cmd?
function B:attach() end

--- Detach from an existing session
function B:detach() end

--- Start a new session
--- If the backend returns a Cmd, a new terminal session will be spawned
---@return sidekick.cli.terminal.Cmd?
function B:start()
  error("Backend:start() not implemented")
end

--- Check if the session is still running
--- @return boolean
function B:is_running()
  error("Backend:is_running() not implemented")
end

function B:is_attached()
  return M._attached[self.id] ~= nil
end

--- List all active sessions for this backend
---@return sidekick.cli.session.State[]
function B.sessions()
  error("Backend:sessions() not implemented")
end

---@param state sidekick.cli.session.Opts
function M.new(state)
  M.setup()
  local tool = state.tool
  tool = type(tool) == "string" and Config.get_tool(tool) or tool --[[@as sidekick.cli.Tool]]
  local backend = state.backend or (Config.cli.mux.enabled and Config.cli.mux.backend or "terminal")
  local super = assert(M.backends[backend], "unknown backend: " .. backend)
  local meta = getmetatable(state)
  local self = setmetatable(state, super) --[[@as sidekick.cli.Session]]
  self.tool = tool
  self.cwd = M.cwd(state)
  -- self.cmd = state.cmd or { cmd = tool.cmd, env = tool.env }
  self.backend = backend
  local saved = self.id and Util.get_state(self.id) or nil
  if saved and saved.tool == tool.name and M.cwd({ cwd = saved.cwd }) == self.cwd then
    self.instance_id = self.instance_id or saved.instance_id
    self.title = self.title or saved.title
    self.conversation = self.conversation or saved.conversation
  end
  self.instance_id = self.instance_id or M.instance(self.id)
  self.sid = M.sid({ tool = tool.name, cwd = self.cwd, instance_id = self.instance_id })
  self.id = self.id or self.sid
  M.persist(self)
  if meta ~= super and self.init then
    self:init()
  end
  return self
end

---@param seed? string
---@return string
function M.instance(seed)
  local value = seed or table.concat({ vim.uv.hrtime(), vim.fn.getpid(), math.random() }, ":")
  return vim.fn.sha256(value):sub(1, 8)
end

---@param opts? {cwd?:string}
function M.cwd(opts)
  return vim.fs.normalize(vim.fn.fnamemodify(opts and opts.cwd or vim.fn.getcwd(0), ":p"))
end

---@param opts {tool:string, cwd?:string, instance_id?:string}
function M.sid(opts)
  local tool = assert(opts and opts.tool, "missing tool")
  local cwd = M.cwd(opts)
  local base = ("%s %s"):format(tool, vim.fn.sha256(cwd):sub(1, 16 - #tool))
  return opts.instance_id and (base .. " " .. opts.instance_id) or base
end

---@param session sidekick.cli.Session
function M.persist(session)
  if session.parent and (session.title ~= nil or session.conversation ~= nil) then
    session.parent.title = session.title or session.parent.title
    session.parent.conversation = session.conversation or session.parent.conversation
    M.persist(session.parent)
  end
  local data = {
    tool = session.tool.name,
    cwd = session.cwd,
    instance_id = session.instance_id,
    title = session.title,
    conversation = session.conversation,
  }
  Util.set_state(session.sid, data)
  if session.id and session.id ~= session.sid then
    Util.set_state(session.id, data)
  end
  if session.backend == "zellij" and session.mux_session then
    Util.set_state(session.mux_session, data)
  end
end

--- Record the native provider conversation id as soon as an adapter discovers it.
---@param session sidekick.cli.Session
---@param conversation sidekick.cli.Conversation|string
function M.set_conversation(session, conversation)
  conversation = type(conversation) == "string" and { id = conversation } or vim.deepcopy(conversation)
  conversation.provider = conversation.provider or session.tool.name
  conversation.resumable = conversation.resumable ~= false
  session.conversation = conversation
  M.persist(session)
  return conversation
end

---@param name string
---@param backend sidekick.cli.Session
function M.register(name, backend)
  setmetatable(backend, B)
  backend.backend = name
  M.backends[name] = backend
end

function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true
  Config.tools() -- load tools, since they may register session backends
  local session_backends = { tmux = "sidekick.cli.session.tmux", zellij = "sidekick.cli.session.zellij" }
  for name, mod in pairs(session_backends) do
    if vim.fn.executable(name) == 1 then
      M.register(name, require(mod))
    end
  end
  M.register("terminal", require("sidekick.cli.terminal"))
end

function M.sessions()
  M.setup()
  local ret = {} ---@type sidekick.cli.Session[]
  local ids = {} ---@type table<string,boolean>
  for name, backend in pairs(M.backends) do
    for _, s in pairs(backend:sessions()) do
      s.backend = name
      s.started = true
      ret[#ret + 1] = M.new(s)
      assert(not ids[s.id], "duplicate session id: " .. s.id)
      ids[s.id] = true
      if M._attached[s.id] then
        M._attached[s.id] = ret[#ret] -- update to latest session instance
      end
    end
  end
  for id in pairs(M._attached) do
    if not ids[id] then -- session is no longer running
      M.detach(M._attached[id])
    end
  end
  return ret
end

---@param session sidekick.cli.Session
function M.detach(session)
  if M._attached[session.id] then
    M._attached[session.id] = nil
    session:detach()
    vim.schedule(function()
      Util.emit("SidekickCliDetach", { id = session.id })
    end)
  end
  return session
end

---@param session sidekick.cli.Session
function M.attach(session)
  if M._attached[session.id] then
    return session
  end
  ---@type sidekick.cli.terminal.Cmd?
  local cmd
  if session.started then
    cmd = session:attach()
  else
    cmd = session:start()
  end
  if cmd then
    session = M.new({
      tool = session.tool:clone({ cmd = cmd.cmd, env = cmd.env }),
      cwd = session.cwd,
      id = "terminal: " .. session.sid,
      backend = "terminal",
      mux_backend = session.backend,
      mux_session = session.mux_session,
      parent = session,
      instance_id = session.instance_id,
      title = session.title,
      conversation = session.conversation,
      hidden = session.hidden,
    })
    session:start()
  end
  M._attached[session.id] = session
  Util.emit("SidekickCliAttach", { id = session.id })
  return session
end

function M.attached()
  local ret = {} ---@type table<string,sidekick.cli.Session>
  for id, s in pairs(M._attached) do
    if s:is_running() then
      ret[id] = s
    else
      M.detach(s)
    end
  end
  return ret
end

return M
