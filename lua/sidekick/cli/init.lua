local Config = require("sidekick.config")
local Context = require("sidekick.cli.context")
local History = require("sidekick.cli.history")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.Prompt
---@field msg string
---@field cwd? string

---@class sidekick.cli.Message
---@field msg? string
---@field prompt? string
---@field text? sidekick.Text[]

---@class sidekick.cli.Capabilities
---@field resume boolean Supports restoring an exact persisted conversation.
---@field fork boolean Supports creating a native child conversation.
---@field continue boolean Supports resuming the provider's most recent conversation.
---@field managed_session boolean Sidekick creates and tracks the provider's conversation id.

---@class sidekick.cli.ProviderDocs
---@field description string
---@field install string

---@class sidekick.cli.Config
---@field cmd string[] Command to run the CLI tool
---@field env? table<string, string|false> Environment variables to set when running the command
---@field url? string Web URL to open when the tool is not installed
---@field keys? table<string, sidekick.cli.Keymap|false>
---@field is_proc? (fun(self:sidekick.cli.Tool, proc:sidekick.cli.Proc):boolean)|string Regex or function to identity a running process
---@field mux_focus? boolean wether the tool needs to be focused in order to receive input
---@field format? fun(text:sidekick.Text[], str:string):string?
---@field native_scroll? boolean whether the tool handles scrolling natively
---@field status? fun(self:sidekick.cli.Tool,event:sidekick.cli.ActivityEvent):sidekick.cli.ActivityStatus? exact activity status adapter
---@field usage? fun(self:sidekick.cli.Tool,session:sidekick.cli.Terminal,cb:fun(value?:sidekick.cli.ContextUsage)):sidekick.cli.ContextUsage?|boolean? async context-usage adapter; return `true` when it will invoke `cb`
---@field docs? sidekick.cli.ProviderDocs Provider metadata rendered in the README.
---@field capabilities? sidekick.cli.Capabilities Declared provider capabilities used by integrations and documentation.
---@field resume? string[]|sidekick.cli.ResumeAdapter|fun(self:sidekick.cli.Tool,conversation?:sidekick.cli.Conversation,saved:sidekick.cli.WorkspaceAgent):string[]?
---@field fork? false|string[]|sidekick.cli.ForkAdapter|fun(self:sidekick.cli.Tool,conversation:sidekick.cli.Conversation,source:sidekick.cli.Terminal):string[]?
---@field continue? string[] native CLI arguments for resuming the most recent conversation

---@class sidekick.cli.ResumeAdapter
---@field args? string[]
---@field prepare? fun(self:sidekick.cli.Tool,session:sidekick.cli.Session):{cmd:string[],env?:table<string,string>,conversation:sidekick.cli.Conversation}?
---@field env? fun(self:sidekick.cli.Tool,conversation:sidekick.cli.Conversation,saved:sidekick.cli.WorkspaceAgent):table<string,string>?
---@field capture? fun(self:sidekick.cli.Tool,session:sidekick.cli.Session):sidekick.cli.Conversation|string?
---@field command? fun(self:sidekick.cli.Tool,conversation?:sidekick.cli.Conversation,saved:sidekick.cli.WorkspaceAgent):string[]?
---@field preflight? fun(self:sidekick.cli.Tool,conversation:sidekick.cli.Conversation,saved:sidekick.cli.WorkspaceAgent):boolean,string?
---@field verify? fun(self:sidekick.cli.Tool,terminal:sidekick.cli.Terminal,conversation?:sidekick.cli.Conversation,saved:sidekick.cli.WorkspaceAgent):boolean?,string?

---@class sidekick.cli.ForkAdapter
---@field args? string[]
---@field available? fun(self:sidekick.cli.Tool,source?:sidekick.cli.Terminal):boolean,string?
---@field command? fun(self:sidekick.cli.Tool,conversation:sidekick.cli.Conversation,source?:sidekick.cli.Terminal):string[]?
---@field after_start? fun(self:sidekick.cli.Tool,terminal:sidekick.cli.Terminal,conversation:sidekick.cli.Conversation,source:sidekick.cli.Terminal):boolean,string?
---@field prepare? fun(self:sidekick.cli.Tool,conversation:sidekick.cli.Conversation,source:sidekick.cli.Terminal,done:fun(cmd?:string[],reason?:string)):boolean,string?

---@class sidekick.cli.Show
---@field name? string
---@field focus? boolean
---@field filter? sidekick.cli.Filter
---@field all? boolean
---@field cwd? string

---@class sidekick.cli.Hide
---@field name? string
---@field filter? sidekick.cli.Filter
---@field all? boolean

---@class sidekick.cli.Send: sidekick.cli.Show,sidekick.cli.Message
---@field submit? boolean

---@class sidekick.cli.ForkOpts
---@field source? sidekick.cli.Terminal
---@field focus? boolean
---@field title? string

---@class sidekick.cli.AgentReferenceOpts
---@field source? sidekick.cli.Session|string Source agent, Sidekick session/instance id, or native conversation id
---@field target? sidekick.cli.Session|string Target agent; defaults to the current panel agent
---@field focus? boolean Focus the target after sending the reference
---@field submit? boolean Submit the reference immediately; defaults to true

--- Keymap options similar to `vim.keymap.set` and `lazy.nvim` mappings
---@class sidekick.cli.Keymap: vim.keymap.set.Opts
---@field [1] string keymap
---@field [2] string|sidekick.cli.Action
---@field mode? string|string[]

---@generic T: {name?:string, filter?:sidekick.cli.Filter}
---@param opts? T|string
---@return T
local function filter_opts(opts)
  opts = type(opts) == "string" and { name = opts } or opts or {}
  ---@cast opts {name?:string, filter?:sidekick.cli.Filter}
  opts.filter = opts.filter or {}
  opts.filter.name = opts.name or opts.filter.name or nil
  return opts
end

--- Select a prompt to send
---@param opts? sidekick.cli.Prompt|{cb:nil}
---@overload fun(cb:fun(msg?:string))
function M.prompt(opts)
  opts = opts or {}
  opts = type(opts) == "function" and { cb = opts } or opts --[[@as sidekick.cli.Prompt]]
  local cwd = Session.cwd({ cwd = opts.cwd })
  opts.cb = opts.cb
    or function(msg, text)
      if text then
        M.send({ msg = msg, text = text, cwd = cwd })
      end
    end
  require("sidekick.cli.ui.prompt").select(opts)
end

--- Start or attach to a CLI tool
---@param opts? sidekick.cli.Select|{cb:nil}|{focus?:boolean,cwd?:string}
---@overload fun(cb:fun(state?:sidekick.cli.State))
function M.select(opts)
  opts = opts or {}
  opts = type(opts) == "function" and { cb = opts } or opts --[[@as sidekick.cli.Select]]
  local cwd = Session.cwd({ cwd = opts.cwd })
  opts.cb = opts.cb
    or function(state)
      if state then
        -- UI select providers may finish restoring the previous window and
        -- mode after invoking their callback. Defer focusing the terminal so
        -- that cleanup cannot leave a selected conversation in normal mode.
        vim.schedule(function()
          State.attach(state, { show = true, focus = opts.focus, cwd = cwd })
        end)
      end
    end
  require("sidekick.cli.ui.select").select(opts)
end

--- Start a new independent agent, even when the same tool is already running.
---@param opts? {name?:string,focus?:boolean,cwd?:string}
function M.new(opts)
  opts = opts or {}
  local cwd = Session.cwd({ cwd = opts.cwd })
  local function start(state)
    if state then
      State.attach(state, { show = true, focus = opts.focus ~= false, cwd = cwd })
    end
  end
  if opts.name then
    local tool = Config.tools()[opts.name]
    if not tool then
      return Util.error("Unknown CLI tool: " .. opts.name)
    end
    local state = { tool = tool, installed = vim.fn.executable(tool.cmd[1]) == 1 }
    if not state.installed then
      return require("sidekick.cli.ui.select").on_missing(tool)
    end
    History.record("tools", tool.name)
    return start(state)
  end
  require("sidekick.cli.ui.select").select({ new = true, cb = start })
end

--- Fork the active agent's native conversation into a new independent agent.
---@param opts? sidekick.cli.ForkOpts
function M.fork(opts)
  opts = opts or {}
  local Panel = require("sidekick.cli.panel")
  local source = opts.source or Panel.active()
  if source then
    return require("sidekick.cli.fork").start(source, opts)
  end
  local items = Panel.picker_items()
  if #items > 0 then
    return require("sidekick.cli.agent_picker").open(items, { fork = true })
  end
  return Util.warn("No live agent is available to fork")
end

--- Reference another running agent in the current agent without copying its conversation.
--- The target receives a small file reference containing the source agent and session ids,
--- plus a command it can use to query that live agent when needed.
--- By default, `<a-a>` opens the source picker in terminal mode and `<leader>ba`
--- opens it in normal mode. The current panel agent is always the default target.
---@param opts? sidekick.cli.AgentReferenceOpts
function M.reference(opts)
  return require("sidekick.cli.agent_reference").select(opts)
end

--- Fuzzy-select an agent tab in the current Sidekick container.
--- Use `filter = "attention"` to show only unread, waiting, or failed agents.
--- From the command line, use `:Sidekick cli switch filter=attention`.
---@param opts? {filter?:sidekick.cli.AgentFilter}
function M.switch(opts)
  require("sidekick.cli.panel").pick(opts)
end

--- Save or restore persistent agent conversations and panel layout.
---
--- ```vim
--- :Sidekick cli workspace save
--- :Sidekick cli workspace restore
--- :Sidekick cli workspace status
--- :Sidekick cli workspace clear
--- ```
---@param action "save"|"restore"|"status"|"clear"
function M.workspace(action)
  local Workspace = require("sidekick.cli.workspace")
  return assert(Workspace[action], "Unknown workspace action: " .. tostring(action))()
end

--- Select the next agent tab.
function M.next()
  require("sidekick.cli.panel").cycle(1)
end

--- Select the previous agent tab.
function M.prev()
  require("sidekick.cli.panel").cycle(-1)
end

--- Rename the active agent tab.
---@param opts? string|{title?:string}
function M.rename(opts)
  require("sidekick.cli.panel").rename(opts)
end

--- Move the shared agent container.
---@param opts? "left"|"right"|"top"|"bottom"|"float"|{layout?:"left"|"right"|"top"|"bottom"|"float"}
function M.move(opts)
  require("sidekick.cli.panel").move(opts)
end

--- Resize or reposition the active agent container.
---@param opts? {width?:integer,height?:integer,row?:integer,col?:integer}
function M.resize(opts)
  require("sidekick.cli.panel").resize(opts)
end

--- Re-read bufferline.nvim-style global keymaps for agent tabs.
function M.sync()
  local active = require("sidekick.cli.panel").active()
  if active and active.buf then
    require("sidekick.cli.panel").keys(active.buf)
  end
end

---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.show(opts)
  opts = filter_opts(opts)
  State.with(function() end, {
    all = opts.all,
    attach = true,
    filter = opts.filter,
    focus = opts.focus,
    show = true,
  })
end

---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.toggle(opts)
  opts = filter_opts(opts)
  State.with(function(state, attached)
    if not state.terminal then
      return
    end
    if not attached then
      state.terminal:toggle()
    end
    if state.terminal:is_open() and opts.focus ~= false then
      state.terminal:focus()
    end
  end, {
    attach = true,
    filter = opts.filter,
  })
end

--- Toggle focus of the active agent container if it is already open.
---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.focus(opts)
  opts = filter_opts(opts)
  State.with(function(state)
    if not state.terminal then
      return
    end
    if state.terminal:is_focused() then
      state.terminal:blur()
    else
      state.terminal:focus()
    end
  end, {
    attach = true,
    filter = opts.filter,
    focus = false,
    show = true,
  })
end

---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
function M.hide(opts)
  opts = filter_opts(opts)
  State.with(function(state)
    return state.terminal and state.terminal:hide()
  end, {
    all = opts.all,
    filter = Util.merge(opts.filter, { terminal = true }),
  })
end

---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
function M.close(opts)
  opts = filter_opts(opts)
  State.with(State.detach, {
    all = opts.all,
    filter = Util.merge(opts.filter),
  })
end

-- Render a message template or prompt
---@param opts? sidekick.cli.Message|string
function M.render(opts)
  return Context.get():render(opts or "")
end

---@private
---@param session sidekick.cli.Session
---@param value string
function M.title(session, value)
  if session.title then
    return
  end
  value = vim.trim(value:gsub("[%c\r\n]+", " "):gsub("%s+", " "))
  if value == "" then
    return
  end
  local max = math.max(1, Config.cli.win.tabs.max_name_length)
  local title = ""
  for _, char in ipairs(Util.split_graphemes(value)) do
    if vim.api.nvim_strwidth(title .. char) > max then
      break
    end
    title = title .. char
  end
  session.title = title
  require("sidekick.cli.session").persist(session)
  require("sidekick.cli.panel").refresh(session.id)
  Util.emit("SidekickCliTitle", { id = session.id, title = title })
end

--- Send a message or prompt to a CLI
---@param opts? sidekick.cli.Send
---@overload fun(msg:string)
function M.send(opts)
  opts = type(opts) == "string" and { msg = opts } or opts
  opts = filter_opts(opts)
  opts.cwd = Session.cwd({ cwd = opts.cwd })

  if not opts.msg and not opts.prompt and Util.visual_mode() then
    opts.msg = "{selection}"
  end

  local finished = false

  ---@param msg string?
  ---@param text sidekick.Text[]?
  local function send(msg, text)
    if finished then
      return
    end
    if msg == "" or not text then
      finished = true
      Util.warn("Nothing to send.")
      return
    elseif msg == "\n" then
      msg = "" -- allow sending a new line
      text = {}
    end
    finished = true

    local prompt_title = msg
    State.with(function(state)
      Util.exit_visual_mode()
      vim.schedule(function()
        M.title(state.session, prompt_title or "")
        local formatted = state.tool:format(text)
        state.session:send(formatted .. "\n")
        if opts.submit then
          state.session:submit()
        end
      end)
    end, {
      attach = true,
      cwd = opts.cwd,
      filter = opts.filter,
      focus = opts.focus,
      show = true,
    })
  end

  local msg, text = opts.msg or "", opts.text ---@type string?, sidekick.Text[]?
  if text then
    return send(msg, text)
  end

  local context
  local refresh_pending = false
  local function render()
    refresh_pending = false
    local rendered_msg, rendered_text, pending = context:render(opts)
    if pending then
      return
    end
    send(rendered_msg, rendered_text)
  end
  context = Context.get({
    on_update = function()
      if finished or refresh_pending then
        return
      end
      refresh_pending = true
      vim.schedule(render)
    end,
  })
  return render()
end

---@deprecated use `require("sidekick.cli").prompt()`
function M.select_prompt(...)
  Util.deprecate('require("sidekick.cli").select_prompt()', 'require("sidekick.cli").prompt()')
  return M.prompt(...)
end

---@deprecated use `require("sidekick.cli").select()`
function M.select_tool(...)
  Util.deprecate('require("sidekick.cli").select_tool()', 'require("sidekick.cli").select()')
  return M.select(...)
end

---@deprecated use `require("sidekick.cli").send()`
function M.ask(...)
  Util.deprecate('require("sidekick.cli").ask()', 'require("sidekick.cli").send()')
  return M.send(...)
end

return M
