local M = {}

---@class sidekick.context.ParserCache
---@field tick integer
---@field filetype string
---@field lang string
---@field parser userdata
---@field nodes table<string, userdata|false>

---@type table<integer, sidekick.context.ParserCache>
local cache = {}
---@type table<integer, boolean>
local attached = {}

---@param buf integer
function M.clear(buf)
  cache[buf] = nil
  attached[buf] = nil
end

---@param buf integer
local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_detach = function(_, detached_buf)
      M.clear(detached_buf)
    end,
  })
end

---@param buf integer
---@return userdata?, table<string, userdata|false>?
function M.get(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    M.clear(buf)
    return
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local filetype = vim.bo[buf].filetype
  local lang = filetype
  if vim.treesitter.language and vim.treesitter.language.get_lang then
    lang = vim.treesitter.language.get_lang(filetype) or filetype
  end
  local cached = cache[buf]
  if cached and cached.tick == tick and cached.filetype == filetype and cached.lang == lang then
    return cached.parser, cached.nodes
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_parser or not parser then
    cache[buf] = nil
    return
  end
  local ok_parse = pcall(function()
    parser:parse()
  end)
  if not ok_parse then
    cache[buf] = nil
    return
  end

  local nodes = {}
  cache[buf] = {
    tick = tick,
    filetype = filetype,
    lang = lang,
    parser = parser,
    nodes = nodes,
  }
  attach(buf)
  return parser, nodes
end

return M
