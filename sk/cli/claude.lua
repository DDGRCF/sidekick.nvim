local Managed = require("sidekick.cli.managed_sessions")
local Provider = require("sidekick.cli.provider_sessions")

local function arg_value(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return cmd[i + 1]
    end
    local value = arg:match("^" .. vim.pesc(flag) .. "=(.+)$")
    if value then
      return value
    end
  end
end

local function has_arg(cmd, flags)
  for _, arg in ipairs(cmd) do
    for _, flag in ipairs(flags) do
      if arg == flag or arg:find("^" .. vim.pesc(flag) .. "=") then
        return true
      end
    end
  end
  return false
end

local function without_arg(cmd, flag)
  local ret = {}
  local skip = false
  for i, arg in ipairs(cmd) do
    if skip then
      skip = false
    elseif arg == flag then
      local value = cmd[i + 1]
      if type(value) == "string" and not value:match("^%-") then
        skip = true
      end
    elseif not arg:find("^" .. vim.pesc(flag) .. "=") then
      ret[#ret + 1] = arg
    end
  end
  return ret
end

local function conversation(id)
  return { id = id, provider = "claude", resumable = true, data = { managed = true } }
end

local resume = Provider.adapter("claude", { "--resume" })
local discover = resume.capture

local function explicit_session_id(cmd)
  if has_arg(cmd, { "--no-session-persistence" }) then
    return
  end
  local id = arg_value(cmd, "--session-id")
  return id and Managed.valid_id(id) and id or nil
end

-- A session id explicitly passed to Claude is authoritative. This avoids
-- replacing the parent id with a nested transcript if Claude has several
-- session files open at once.
resume.capture = function(tool, session)
  local id = explicit_session_id(tool.cmd)
  if id then
    local discovered = discover(tool, session)
    local cached = session.conversation and session.conversation.data or {}
    local data = discovered and discovered.id == id and vim.deepcopy(discovered.data) or vim.deepcopy(cached)
    data.managed = true
    return { id = id, provider = "claude", resumable = true, data = data }
  end
  return discover(tool, session)
end

resume.prepare = function(tool)
  local cmd = vim.deepcopy(tool.cmd)

  -- These modes either select an existing conversation or explicitly disable
  -- persistence. Let provider discovery handle them instead of inventing an
  -- id that Claude cannot resume.
  if has_arg(cmd, { "--continue", "-c", "--resume", "-r", "--no-session-persistence" }) then
    return
  end

  local explicit = arg_value(cmd, "--session-id")
  if explicit then
    return Managed.valid_id(explicit) and { cmd = cmd, conversation = conversation(explicit) } or nil
  end
  if has_arg(cmd, { "--session-id" }) then
    return
  end

  local id = Managed.uuid()
  vim.list_extend(cmd, { "--session-id", id })
  return { cmd = cmd, conversation = conversation(id) }
end

---@type sidekick.cli.Config
return {
  cmd = { "claude" },
  capabilities = {
    resume = true,
    fork = true,
    continue = true,
    managed_session = false,
  },
  is_proc = "\\<claude\\>",
  url = "https://github.com/anthropics/claude-code",
  usage = require("sidekick.cli.agent_usage").claude,
  resume = resume,
  fork = {
    command = function(tool, conversation)
      -- `--fork-session` creates a new id from the resumed conversation. Do
      -- not carry the parent's managed `--session-id` into the child command.
      -- Assign a fresh id so the child remains identifiable while Claude is
      -- still showing startup or workspace-trust prompts.
      local cmd = without_arg(vim.deepcopy(tool.cmd), "--session-id")
      vim.list_extend(cmd, { "--resume", conversation.id, "--fork-session", "--session-id", Managed.uuid() })
      return cmd
    end,
  },
  continue = { "--continue" },
  format = function(text)
    local Text = require("sidekick.text")

    Text.transform(text, function(str)
      return str:find("[^%w/_%.%-]") and ('"' .. str .. '"') or str
    end, "SidekickLocFile")

    local ret = Text.to_string(text)

    -- transform line ranges to a format that Claude understands
    ret = ret:gsub("@([^@]-) :L(%d+)%-L(%d+)", "@%1#L%2-%3")

    return ret
  end,
}
