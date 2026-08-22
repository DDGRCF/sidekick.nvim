local M = {}

local DEFAULT_TTL_MS = 1000

M._snapshot = nil ---@type sidekick.cli.Session[]?
M._updated_at = 0
M._generation = 0
M._dirty = true

--- Mark the current discovery snapshot as stale.
function M.invalidate()
  M._dirty = true
end

--- Drop all cached discovery state.
function M.clear()
  M._snapshot = nil
  M._updated_at = 0
  M._generation = 0
  M._dirty = true
end

---@return integer
function M.generation()
  return M._generation
end

---@param discover fun():sidekick.cli.Session[]
---@param opts? {refresh?:boolean,ttl_ms?:integer} Set ttl_ms=0 to disable time-based expiry.
---@return sidekick.cli.Session[], integer generation, boolean refreshed
function M.get(discover, opts)
  opts = opts or {}
  local now = vim.uv.now()
  local ttl = opts.ttl_ms == nil and DEFAULT_TTL_MS or math.max(0, opts.ttl_ms)
  if M._snapshot and not opts.refresh and not M._dirty and (ttl == 0 or now - M._updated_at <= ttl) then
    return M._snapshot, M._generation, false
  end

  M._snapshot = discover()
  M._updated_at = now
  M._generation = M._generation + 1
  M._dirty = false
  return M._snapshot, M._generation, true
end

return M
