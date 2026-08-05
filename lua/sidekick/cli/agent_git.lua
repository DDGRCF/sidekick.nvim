local M = {}

local cache = {}
local pending = {}
local ttl = 2 * 1e9

local function parse(output)
  local ret = { branch = "", changed_files = {} }
  local records = vim.split(output or "", "\0", { plain = true, trimempty = true })
  local i = 1
  while i <= #records do
    local record = records[i]
    if record:sub(1, 3) == "## " then
      ret.branch = record:sub(4):match("^(.-)%.%.%.") or record:sub(4)
      ret.branch = ret.branch:gsub("^No commits yet on ", ""):gsub("^Initial commit on ", "")
    elseif #record > 3 then
      ret.changed_files[#ret.changed_files + 1] = record:sub(4)
      if record:sub(1, 1):find("[RC]") or record:sub(2, 2):find("[RC]") then
        i = i + 1
        if records[i] then
          ret.changed_files[#ret.changed_files + 1] = records[i]
        end
      end
    end
    i = i + 1
  end
  return ret
end

---@param cwds string[]
---@param on_update? fun(cwd:string)
---@return table<string,{branch:string,changed_files:string[]}>
function M.collect(cwds, on_update)
  if vim.fn.executable("git") ~= 1 then
    return {}
  end
  local now = vim.uv.hrtime()
  local ret = {}
  for _, cwd in ipairs(cwds) do
    local entry = cache[cwd]
    if entry and now - entry.at < ttl then
      ret[cwd] = vim.deepcopy(entry.value)
    elseif vim.fn.isdirectory(cwd) == 1 then
      local first = pending[cwd] == nil
      pending[cwd] = pending[cwd] or {}
      if on_update then
        pending[cwd][#pending[cwd] + 1] = on_update
      end
      if first then
        vim.system({ "git", "-C", cwd, "status", "--porcelain=v1", "--branch", "-z" }, { text = true }, function(result)
          vim.schedule(function()
            local value = result.code == 0 and parse(result.stdout) or { branch = "", changed_files = {} }
            cache[cwd] = { at = vim.uv.hrtime(), value = value }
            local callbacks = pending[cwd] or {}
            pending[cwd] = nil
            for _, callback in ipairs(callbacks) do
              callback(cwd)
            end
          end)
        end)
      end
    end
  end
  return ret
end

M.parse = parse

return M
