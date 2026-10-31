local Util = require("sidekick.util")

---@param cwd? string
---@return table[]
local function sessions(cwd)
  local _, stdout = Util.exec({ "devin", "list", "--format", "json" }, { cwd = cwd, notify = false })
  if type(stdout) ~= "string" or stdout == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, stdout)
  return ok and type(decoded) == "table" and decoded or {}
end

---@param item table
---@return { id: string, at: number, cwd?: string }?
local function entry(item)
  if type(item) ~= "table" then
    return
  end
  local id = item.id or item.session_id
  if type(id) ~= "string" or id == "" or item.hidden == true or item.is_hidden == true then
    return
  end
  local at = tonumber(item.last_activity_at or item.updated_at or item.last_activity or 0) or 0
  return { id = id, at = at, cwd = item.working_directory }
end

---@param cwd? string
---@param id? string
---@return { id: string, at: number, cwd?: string }?
local function find_session(cwd, id)
  local best
  for _, item in ipairs(sessions(cwd)) do
    local found = entry(item)
    -- `devin list` is scoped to the working directory it runs in, but guard
    -- against cross-project leakage anyway.
    local same_cwd = not (cwd and found and found.cwd)
      or vim.fs.normalize(found.cwd) == vim.fs.normalize(cwd)
    if found and same_cwd then
      if id and found.id == id then
        return found
      end
      if not id and (not best or found.at >= best.at) then
        best = found
      end
    end
  end
  return best
end

---@param cwd? string
---@return sidekick.cli.Conversation?
local function conversation(cwd)
  local found = find_session(cwd)
  if not found then
    return
  end
  return {
    id = found.id,
    provider = "devin",
    resumable = true,
    data = { cwd = found.cwd },
  }
end

---@type sidekick.cli.Config
return {
  cmd = { "devin" },
  capabilities = {
    resume = true,
    fork = false,
    continue = true,
    managed_session = false,
  },
  docs = {
    description = "Devin CLI",
    install = "curl -fsSL https://cli.devin.ai/install.sh | bash",
  },
  is_proc = "\\<devin\\>",
  keys = {
    prompt = { "<a-p>", "prompt" },
  },
  url = "https://devin.ai",
  resume = {
    args = { "--resume" },
    capture = function(_, session)
      return conversation(session.cwd)
    end,
    verify = function(tool, terminal, conversation, saved)
      local cwd = (terminal and terminal.cwd) or (saved and saved.cwd) or tool.cwd
      return find_session(cwd, conversation and conversation.id) ~= nil
    end,
    preflight = function(tool, conversation, saved)
      local cwd = (saved and saved.cwd) or tool.cwd
      return find_session(cwd, conversation and conversation.id) ~= nil
    end,
  },
  continue = { "--continue" },
}
