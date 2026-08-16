local Config = require("sidekick.config")

local M = {}

local TTL_NS = 2 * 1e9
local TIMEOUT_MS = 1000

---@alias sidekick.context.git.Callback fun(cwd:string,key:string)
---@class sidekick.context.git.CacheEntry
---@field cwd string
---@field value string?
---@field at integer
---@field ready boolean
---@field invalidated boolean?

---@type table<string,sidekick.context.git.CacheEntry>
local cache = {}
---@type table<string,{cwd:string,callbacks:sidekick.context.git.Callback[],generation:string,finishing?:boolean}>
local pending = {}
local global_generation = 0
local cwd_generations = {} ---@type table<string, integer>
local autocmds_ready = false

-- A context may be rendered before the first asynchronous Git result arrives.
-- This sentinel is intentionally not a Text value: Context can omit only the
-- pending fragment while preserving the rest of the prompt.
M.PENDING = {}

local function cache_key(cwd, args)
  return cwd .. "\0" .. table.concat(args, "\0")
end

local function generation(cwd)
  return global_generation .. ":" .. (cwd_generations[cwd] or 0)
end

local function add_callback(request, callback)
  if not callback or vim.tbl_contains(request.callbacks, callback) then
    return
  end
  request.callbacks[#request.callbacks + 1] = callback
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function notify(callbacks, cwd, key)
  for _, callback in ipairs(callbacks) do
    pcall(callback, cwd, key)
  end
end

local function finish(key, result)
  local request = pending[key]
  if not request or request.finishing then
    return
  end
  request.finishing = true

  vim.schedule(function()
    -- Keep the request coalesced until its result is installed. This avoids
    -- starting a duplicate Git process in the small callback-to-schedule gap.
    if pending[key] ~= request then
      return
    end
    pending[key] = nil
    local old = cache[key]
    local invalidated = request.generation ~= generation(request.cwd)
    if result and result.code == 0 then
      cache[key] = {
        cwd = request.cwd,
        value = result.stdout or "",
        at = vim.uv.hrtime(),
        ready = true,
        invalidated = invalidated or nil,
      }
    elseif old and old.ready and old.value ~= nil then
      -- Keep a usable stale value after a transient Git failure. The next
      -- request after the TTL can retry without making the editor blank.
      old.at = vim.uv.hrtime()
      old.invalidated = invalidated or nil
    else
      cache[key] = {
        cwd = request.cwd,
        value = nil,
        at = vim.uv.hrtime(),
        ready = true,
        invalidated = invalidated or nil,
      }
    end
    notify(request.callbacks, request.cwd, key)
  end)
end

local function start(cwd, args, key, on_update)
  if pending[key] then
    return
  end

  pending[key] = {
    cwd = cwd,
    callbacks = on_update and { on_update } or {},
    generation = generation(cwd),
  }
  local timer = assert(vim.uv.new_timer())
  local job
  local completed = false
  local exited = false

  local function complete(result)
    if completed then
      return
    end
    completed = true
    close_timer(timer)
    finish(key, result)
  end

  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  local ok, err = pcall(function()
    job = vim.system(cmd, { text = true }, function(result)
      exited = true
      complete(result)
    end)
  end)
  if not ok then
    complete({ code = -1, stderr = tostring(err) })
    return
  end
  if completed then
    return
  end

  timer:start(
    TIMEOUT_MS,
    0,
    vim.schedule_wrap(function()
      if completed then
        return
      end
      complete({ code = -1, stderr = "timeout" })
      if not exited and job and type(job.kill) == "function" then
        pcall(job.kill, job, 15)
        vim.defer_fn(function()
          if not exited and type(job.kill) == "function" then
            pcall(job.kill, job, 9)
          end
        end, 250)
      end
    end)
  )
end

function M.setup()
  if autocmds_ready then
    return
  end
  autocmds_ready = true
  for _, event in ipairs({ "BufWritePost", "DirChanged", "FocusGained" }) do
    vim.api.nvim_create_autocmd(event, {
      group = Config.augroup,
      callback = function()
        M.invalidate()
      end,
    })
  end
end

---@param cwd string?
function M.invalidate(cwd)
  if cwd then
    cwd_generations[cwd] = (cwd_generations[cwd] or 0) + 1
  else
    global_generation = global_generation + 1
  end
  for _, entry in pairs(cache) do
    if not cwd or entry.cwd == cwd then
      entry.invalidated = true
    end
  end
end

---@param cwd string?
---@param args string[]
---@param on_update? sidekick.context.git.Callback
---@return string? output
---@return boolean? pending
function M.run(cwd, args, on_update)
  if not cwd or cwd == "" or vim.fn.executable("git") ~= 1 or vim.fn.isdirectory(cwd) ~= 1 then
    return
  end
  M.setup()

  local key = cache_key(cwd, args)
  local now = vim.uv.hrtime()
  local entry = cache[key]
  if entry and entry.ready and not entry.invalidated and now - entry.at < TTL_NS then
    return entry.value, false
  end

  if not pending[key] then
    start(cwd, args, key, on_update)
  elseif on_update then
    local request = pending[key]
    if request then
      add_callback(request, on_update)
    end
  end

  -- Serve stale data immediately while the asynchronous refresh runs.
  if entry and entry.ready and entry.value ~= nil then
    return entry.value, true
  end
  return nil, true
end

---@param output string?
---@return string[]
function M.lines(output)
  if not output or output == "" then
    return {}
  end

  local lines = vim.split(output:gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

return M
