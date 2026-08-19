local Config = require("sidekick.config")
local Icons = require("sidekick.cli.icons")
local Loc = require("sidekick.cli.context.location")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")

local M = {}

M.root = Config.state("agent-references")

---@param session sidekick.cli.Session
---@return sidekick.cli.Session
local function logical(session)
  return session.parent or session
end

---@param session sidekick.cli.Session
---@return sidekick.cli.Conversation?
local function conversation(session)
  local root = logical(session)
  return session.conversation or root.conversation
end

---@param session sidekick.cli.Session
---@return sidekick.cli.Conversation?
local function ensure_conversation(session)
  local current = conversation(session)
  if current and type(current.id) == "string" and current.id ~= "" then
    return current
  end
  pcall(require("sidekick.cli.resume").capture, session, { require_current = true })
  return conversation(session)
end

---@param value any
---@return string
local function one_line(value)
  return vim.trim(tostring(value or ""):gsub("[%c\r\n]+", " "):gsub("%s+", " "):gsub("`", "'"))
end

---@param session sidekick.cli.Session
---@return string
local function reference_id(session)
  local root = logical(session)
  local value = session.instance_id or root.instance_id
  if type(value) == "string" and value:match("^[%w_.%-]+$") then
    return value
  end
  return vim.fn.sha256(table.concat({ session.tool.name, root.id or session.id }, "\31")):sub(1, 16)
end

---@param session sidekick.cli.Session
---@return string
local function session_id(session)
  local current = conversation(session)
  return current and type(current.id) == "string" and current.id
    or session.instance_id
    or logical(session).instance_id
    or logical(session).id
    or session.id
end

---@param session sidekick.cli.Session
---@return boolean
local function running(session)
  local ok, ret = pcall(session.is_running, session)
  return ok and ret == true
end

---@param left sidekick.cli.Session
---@param right sidekick.cli.Session
---@return boolean
local function same(left, right)
  left, right = logical(left), logical(right)
  if left == right or (left.id ~= nil and left.id == right.id) then
    return true
  end
  return left.instance_id ~= nil and left.instance_id == right.instance_id
end

---@return sidekick.cli.Session[]
local function live()
  return vim.tbl_filter(running, Session.sessions())
end

---@param value? sidekick.cli.Session|string
---@param sessions? sidekick.cli.Session[]
---@return sidekick.cli.Session?
function M.resolve(value, sessions)
  if type(value) == "table" and value.session then
    return value.session
  elseif type(value) == "table" and value.tool then
    return value --[[@as sidekick.cli.Session]]
  elseif type(value) ~= "string" or value == "" then
    return
  end
  local terminal = Terminal.get(value)
  if terminal then
    return terminal
  end
  for _, session in ipairs(sessions or live()) do
    local current = conversation(session)
    if
      session.id == value
      or session.instance_id == value
      or logical(session).id == value
      or logical(session).instance_id == value
      or (current and current.id == value)
    then
      return session
    end
  end
end

---@param target sidekick.cli.Session
---@return sidekick.cli.Session[]
function M.sources(target)
  local ret = vim.tbl_filter(function(session)
    return not same(session, target)
  end, live())
  table.sort(ret, function(a, b)
    local a_name = table.concat({ a.tool.name, one_line(a.title), session_id(a) }, "\31")
    local b_name = table.concat({ b.tool.name, one_line(b.title), session_id(b) }, "\31")
    return a_name < b_name
  end)
  return ret
end

---@param session sidekick.cli.Session
---@param supports_chunks? boolean
---@return string|snacks.picker.Highlight[]
function M.format(session, supports_chunks)
  local root = logical(session)
  local name = session.tool.name
  local title = one_line(session.title or root.title)
  local status = one_line(session.status or root.status or "idle")
  local state = status:gsub("^%l", string.upper)
  local status_hl = "SidekickCliStatus" .. state
  local status_icon = Config.cli.win.tabs.status[status]
  status_icon = type(status_icon) == "string" and vim.trim(status_icon) or ""
  status_icon = status_icon ~= "" and status_icon or "•"
  local icon = Icons.tool(name)
  local icon_hl = icon and Icons.highlight(name) or "SidekickCliInstalled"
  icon = icon or Config.ui.icons.installed
  icon = type(icon) == "string" and vim.trim(icon) or ""
  local backend = one_line(session.mux_backend or root.mux_backend or root.backend or session.backend or "terminal")
  local cwd = vim.fn.fnamemodify(session.cwd or root.cwd or "", ":p:~")
  cwd = cwd:gsub("/$", "")
  local identity = one_line(session_id(session))
  local ret = {} ---@type snacks.picker.Highlight[]
  if icon ~= "" then
    ret[#ret + 1] = { icon .. " ", icon_hl }
  end
  ret[#ret + 1] = { name, Icons.highlight(name) }
  if title ~= "" then
    ret[#ret + 1] = { " · " .. title, "Title" }
  end
  ret[#ret + 1] = { "  " .. status_icon .. " " .. status, status_hl }
  ret[#ret + 1] = { "  [" .. backend .. "]", "Special" }
  ret[#ret + 1] = { "  session " .. identity, "Comment" }
  if cwd ~= "" then
    ret[#ret + 1] = { "  " .. cwd, "Directory" }
  end
  if supports_chunks then
    return ret
  end
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, ret))
end

---@param session sidekick.cli.Session
---@return string
function M.label(session)
  return M.format(session, false) --[[@as string]]
end

local function query_command(ref)
  local server = vim.v.servername
  if server == "" then
    local ok, address = pcall(vim.fn.serverstart)
    server = ok and address or ""
  end
  if server == "" then
    return
  end
  local expression = ("luaeval('require(\"sidekick.cli.agent_reference\").query(_A)', %s)"):format(vim.fn.string(ref))
  return table.concat(
    vim.tbl_map(vim.fn.shellescape, {
      vim.v.progpath,
      "--server",
      server,
      "--remote-expr",
      expression,
    }),
    " "
  )
end

---@param source sidekick.cli.Session
---@return string? path
---@return string? error
function M.create(source)
  if not source or not source.tool then
    return nil, "invalid source agent"
  end
  local ref = reference_id(source)
  local root = vim.fs.normalize(M.root)
  if vim.fn.mkdir(root, "p") == 0 and vim.fn.isdirectory(root) ~= 1 then
    return nil, "could not create the agent reference directory"
  end
  local path = vim.fs.joinpath(root, ref .. ".md")
  local current = ensure_conversation(source)
  local provider = current and one_line(current.provider) or source.tool.name
  local native_id = current and one_line(current.id) or ""
  local lines = {
    "# Sidekick Running Agent Reference",
    "",
    "This file identifies a running agent. It intentionally contains no conversation content.",
    "",
    ("- Agent: `%s`"):format(one_line(source.tool.name)),
    ("- Provider: `%s`"):format(provider),
    ("- Session: `%s`"):format(one_line(session_id(source))),
    ("- Sidekick session: `%s`"):format(one_line(logical(source).id or source.id)),
    ("- Instance: `%s`"):format(ref),
    ("- Working directory: `%s`"):format(one_line(source.cwd)),
  }
  local title = one_line(source.title or logical(source).title)
  if title ~= "" then
    table.insert(lines, 6, ("- Title: `%s`"):format(title))
  end
  if native_id ~= "" then
    lines[#lines + 1] = ("- Native conversation: `%s:%s`"):format(provider, native_id)
  end
  local data_path = current and current.data and current.data.path
  if type(data_path) == "string" and data_path ~= "" then
    lines[#lines + 1] = ("- Provider conversation data: `%s`"):format(one_line(data_path))
  end
  local command = query_command(ref)
  if command then
    vim.list_extend(lines, {
      "",
      "Query the running agent only when its information is needed:",
      "",
      "```sh",
      command,
      "```",
    })
  end
  local ok, result = pcall(vim.fn.writefile, lines, path)
  if not ok or result ~= 0 then
    return nil, "could not write the agent reference: " .. tostring(result)
  end
  return path
end

local function strip_terminal_sequences(text)
  return text
    :gsub("\27%][^\7]*\7", "")
    :gsub("\27%][^\27]*\27\\", "")
    :gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
    :gsub("\27%([%w]", "")
    :gsub("\r", "")
    :gsub("[%z\1-\8\11\12\14-\31\127]", "")
end

---@param source sidekick.cli.Session
---@return string?
local function output(source)
  if source.buf and vim.api.nvim_buf_is_valid(source.buf) then
    return table.concat(vim.api.nvim_buf_get_lines(source.buf, 0, -1, false), "\n")
  end
  local root = logical(source)
  local owner = type(source.dump) == "function" and source or type(root.dump) == "function" and root or nil
  if owner then
    local ok, ret = pcall(owner.dump, owner)
    return ok and type(ret) == "string" and ret or nil
  end
end

local function trim_output(text)
  local opts = Config.cli.agent_reference or {}
  local max_lines = math.max(1, tonumber(opts.max_lines) or 2000)
  local max_bytes = math.max(1024, tonumber(opts.max_bytes) or 256 * 1024)
  local lines = vim.split(strip_terminal_sequences(text), "\n", { plain = true })
  lines = vim.list_slice(lines, math.max(1, #lines - max_lines + 1))
  local ret, bytes = {}, 0
  for i = #lines, 1, -1 do
    local line = lines[i]
    local remaining = max_bytes - bytes
    if remaining <= 0 then
      break
    end
    if #line + 1 > remaining then
      local start = math.max(1, #line - remaining + 2)
      while start <= #line do
        local byte = line:byte(start)
        if not byte or byte < 0x80 or byte >= 0xC0 then
          break
        end
        start = start + 1
      end
      line = line:sub(start)
    end
    table.insert(ret, 1, line)
    bytes = bytes + #line + 1
  end
  return vim.trim(table.concat(ret, "\n"))
end

--- Query a referenced running agent. Intended for `nvim --remote-expr` from a CLI.
---@param ref string Sidekick agent instance id
---@return string
function M.query(ref)
  local source = M.resolve(ref)
  if not source or not running(source) then
    return ("Sidekick agent reference `%s` is no longer running."):format(one_line(ref))
  end
  local current = ensure_conversation(source)
  local identity = current and current.id or session_id(source)
  local header = ("Agent: %s\nSession: %s\nWorking directory: %s"):format(source.tool.name, identity, source.cwd or "")
  local text = output(source)
  text = text and trim_output(text) or ""
  if text == "" then
    return header .. "\n\nLive terminal output is unavailable for this session backend."
  end
  return header .. "\n\n" .. text
end

---@param source sidekick.cli.Session
---@param target sidekick.cli.Session
---@param opts? sidekick.cli.AgentReferenceOpts
---@return string? path
function M.send(source, target, opts)
  opts = opts or {}
  if not running(source) then
    return Util.warn("The source agent is no longer running")
  elseif not running(target) then
    return Util.warn("The target agent is no longer running")
  elseif same(source, target) then
    return Util.warn("Select a different source agent")
  end
  local path, err = M.create(source)
  if not path then
    return Util.error("Failed to create agent reference: " .. tostring(err))
  end
  local location = assert(Loc.get({ name = path, cwd = target.cwd }, { kind = "file" })[1])
  local line = {
    { "Continue using the running agent reference " },
  }
  vim.list_extend(line, location)
  line[#line + 1] = {
    (" (agent: %s, session: %s). Inspect and query it when needed."):format(source.tool.name, session_id(source)),
  }
  local formatted = target.tool:format({ line })
  target:send(formatted .. "\n")
  if opts.submit ~= false then
    target:submit()
  end
  if type(target.show) == "function" then
    target:show()
  end
  if opts.focus ~= false and type(target.focus) == "function" then
    target:focus()
  end
  Util.emit("SidekickCliReference", {
    source_id = logical(source).id or source.id,
    target_id = logical(target).id or target.id,
    agent = source.tool.name,
    session = session_id(source),
    path = path,
  })
  return path
end

---@param opts? sidekick.cli.AgentReferenceOpts
function M.select(opts)
  opts = opts or {}
  local target = opts.target ~= nil and M.resolve(opts.target) or require("sidekick.cli.panel").active()
  if not target then
    return Util.warn(
      opts.target ~= nil and "The requested target agent is not running"
        or "No current agent is available to receive a reference"
    )
  end
  local sessions = live()
  local source = M.resolve(opts.source, sessions)
  if opts.source ~= nil then
    if not source then
      return Util.warn("The requested source agent is not running")
    end
    return M.send(source, target, opts)
  end
  local sources = vim.tbl_filter(function(session)
    return not same(session, target)
  end, sessions)
  table.sort(sources, function(a, b)
    local a_name = table.concat({ a.tool.name, one_line(a.title), session_id(a) }, "\31")
    local b_name = table.concat({ b.tool.name, one_line(b.title), session_id(b) }, "\31")
    return a_name < b_name
  end)
  if #sources == 0 then
    return Util.warn("No other running agent is available to reference")
  end
  vim.ui.select(sources, {
    prompt = "Reference running agent:",
    kind = "sidekick_agent_reference",
    format_item = M.format,
    snacks = {
      format = function(session)
        return M.format(session, true)
      end,
    },
  }, function(selected)
    if selected then
      M.send(selected, target, opts)
    end
  end)
end

return M
