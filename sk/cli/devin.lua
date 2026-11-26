local Status = require("sidekick.cli.status")
local Util = require("sidekick.util")

-- `devin list` talks to the Devin API and takes seconds on every call, so the
-- answer is cached and refreshed in the background (stale-while-revalidate):
-- nothing on the editor's render, snapshot or restore path may block on it.
local CACHE_TTL_MS = 30000

---@type table<string, { at: number, list: table[] }>
local cache = {}

---@type table<string, (fun(list: table[]))[]>
local inflight = {}

local function now()
  return vim.uv.hrtime() / 1e6
end

---@param stdout string?
---@return table[]
local function decode(stdout)
  if type(stdout) == "string" and stdout ~= "" then
    local ok, decoded = pcall(vim.json.decode, stdout)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return {}
end

--- Fetch the session list without blocking. Concurrent requests for the same
--- working directory collapse into a single `devin list` call, and every
--- waiting callback still receives the answer.
---@param cwd? string
---@param cb fun(list: table[])
local function fetch(cwd, cb)
  local key = cwd or ""
  local pending = inflight[key]
  if pending then
    pending[#pending + 1] = cb
    return
  end
  pending = { cb }
  inflight[key] = pending
  vim.system({ "devin", "list", "--format", "json" }, { cwd = cwd, text = true }, function(result)
    inflight[key] = nil
    -- A failed call must not turn into an authoritative empty list: keep the
    -- previous answer so the session stays `unknown` rather than `missing`.
    if result.code == 0 then
      cache[key] = { at = now(), list = decode(result.stdout) }
    end
    local list = cache[key] and cache[key].list or {}
    vim.schedule(function()
      for _, fn in ipairs(pending) do
        fn(list)
      end
    end)
  end)
end

--- Blocking lookup. Only user-initiated capture paths may use this; the
--- editor's render/snapshot/restore paths must go through `cached_session`.
---@param cwd? string
---@return table[]
local function sessions(cwd)
  local key = cwd or ""
  local hit = cache[key]
  if hit then
    if now() - hit.at >= CACHE_TTL_MS then
      fetch(cwd, function() end)
    end
    return hit.list
  end
  local _, stdout = Util.exec({ "devin", "list", "--format", "json" }, { cwd = cwd, notify = false })
  local list = decode(stdout)
  if type(stdout) == "string" then
    -- Only a real answer may become authoritative; a failed call keeps the
    -- session `unknown` instead of persistently `missing`.
    cache[key] = { at = now(), list = list }
  end
  return list
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
---@param cwd? string
---@param list table[]
---@param id? string
---@return { id: string, at: number, cwd?: string }?
local function pick(cwd, list, id)
  local best
  for _, item in ipairs(list) do
    local found = entry(item)
    -- `devin list` is scoped to the working directory it runs in, but guard
    -- against cross-project leakage anyway.
    local same_cwd = not (cwd and found and found.cwd) or vim.fs.normalize(found.cwd) == vim.fs.normalize(cwd)
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

--- Cache-only lookup. Never blocks: a stale or missing cache is refreshed in
--- the background and reported as `unknown` so callers can stay permissive.
---@param cwd? string
---@param id? string
---@return { id: string, at: number, cwd?: string }? found
---@return boolean unknown
local function cached_session(cwd, id)
  local key = cwd or ""
  local hit = cache[key]
  local stale = not hit or now() - hit.at >= CACHE_TTL_MS
  if stale then
    fetch(cwd, function() end)
  end
  local found = hit and pick(cwd, hit.list, id) or nil
  -- A stale list may predate the session we were asked about, so a miss is
  -- only authoritative while the cache is fresh.
  return found, stale and found == nil
end

---@param cwd? string
---@return sidekick.cli.Conversation?
local function conversation(cwd)
  local found = pick(cwd, sessions(cwd))
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

--- Same as `conversation`, but never blocks on the Devin API.
---@param cwd? string
---@param cb fun(conversation: sidekick.cli.Conversation?)
local function capture_async(cwd, cb)
  local function report(found)
    cb(found and {
      id = found.id,
      provider = "devin",
      resumable = true,
      data = { cwd = found.cwd },
    } or nil)
  end
  local found, unknown = cached_session(cwd)
  if found or not unknown then
    return report(found)
  end
  fetch(cwd, function(list)
    report(pick(cwd, list))
  end)
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
    capture_async = function(_, session, cb)
      capture_async(session.cwd, cb)
    end,
    capture_cached = function(_, session)
      -- Read the cache directly: a workspace snapshot must not even schedule a
      -- refresh, because that would reorder autosave work behind a fetch.
      local hit = cache[session.cwd or ""]
      local found = hit and pick(session.cwd, hit.list) or nil
      return found
          and {
            id = found.id,
            provider = "devin",
            resumable = true,
            data = { cwd = found.cwd },
          }
        or nil
    end,
    -- `nil` means "the cached list cannot answer yet"; `resume.verify` only
    -- blocks on an explicit `false`, so an unverified id never costs a freeze.
    verify = function(tool, terminal, conversation, saved)
      local cwd = (terminal and terminal.cwd) or (saved and saved.cwd) or tool.cwd
      local found, unknown = cached_session(cwd, conversation and conversation.id)
      if unknown then
        return nil
      end
      return found ~= nil
    end,
    -- Devin exposes no writer lock, so preflight has no writer conflict to
    -- report. Existence is `verify`'s job, and the CLI itself rejects a stale
    -- id on resume, which is visible instead of a frozen editor.
    preflight = function()
      return true
    end,
  },
  continue = { "--continue" },
  -- Devin prints the interrupt shortcut while working; it exposes no stable
  -- idle footer, so `done` still comes from the quiet-output fallback.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
}
