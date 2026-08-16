local Loc = require("sidekick.cli.context.location")
local Parser = require("sidekick.cli.context.parser")

local M = {}

local function scope_kind(type)
  type = type:lower()
  if
    type:match("body$")
    or type:match("block$")
    or type:match("parameters?$")
    or type:match("argument")
    or type:match("call")
    or type:match("function_type")
    or type:match("declarator$")
  then
    return
  end

  if type:match("function") or type:match("method") then
    return "function"
  elseif type:match("class") or type:match("interface") then
    return "class"
  elseif type:match("struct") then
    return "struct"
  end
end

---@param node userdata
---@param buf integer
---@return string?
local function node_name(node, buf)
  for _, field in ipairs({ "name", "identifier", "declarator", "type" }) do
    local named = node:field(field)[1]
    if named then
      local value = vim.treesitter.get_node_text(named, buf)
      if value and value ~= "" then
        return vim.trim(value:gsub("%s+", " "))
      end
    end
  end

  for child in node:iter_children() do
    local type = child:type()
    if type == "identifier" or type:match("name") then
      local value = vim.treesitter.get_node_text(child, buf)
      if value and value ~= "" then
        return vim.trim(value:gsub("%s+", " "))
      end
    end
  end
end

---@param node userdata
---@param buf integer
---@return userdata?, string?
local function outer_scope(node, buf)
  local ret, kind
  while node do
    local current = scope_kind(node:type())
    if current then
      -- Walking from the cursor towards the root means the last match is
      -- the outermost function/class/struct containing the cursor.
      ret, kind = node, current
    end
    node = node:parent()
  end
  return ret, kind
end

---@param ctx sidekick.context.ctx
---@return sidekick.Text[]?
function M.get(ctx)
  local buf = ctx.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local parser, nodes = Parser.get(buf)
  if not parser then
    return
  end

  local row, col = math.max(0, ctx.row - 1), math.max(0, ctx.col - 1)
  local node_key = row .. ":" .. col
  local node = nodes[node_key]
  local ok_node = true
  if node == nil then
    ok_node, node = pcall(vim.treesitter.get_node, {
      bufnr = buf,
      pos = { row, col },
    })
    if ok_node then
      nodes[node_key] = node or false
    end
  elseif node == false then
    node = nil
  end
  if not ok_node or not node then
    return
  end

  local scope, kind = outer_scope(node, buf)
  if not scope or not kind then
    return
  end

  local start_row, _, end_row, end_col = scope:range()
  local last_row = end_col == 0 and end_row - 1 or end_row
  last_row = math.max(start_row, last_row)
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, last_row + 1, false)
  if #lines == 0 then
    return
  end

  local location = Loc.get({
    buf = buf,
    cwd = ctx.cwd,
    range = {
      from = { start_row + 1, 0 },
      to = { last_row + 1, 0 },
      kind = "line",
    },
  }, { kind = "line" })

  local title = { { "Tree-sitter scope", "Title" }, { " " }, { kind, "Type" } } ---@type sidekick.Text
  local name = node_name(scope, buf)
  if name then
    title[#title + 1] = { " " }
    title[#title + 1] = { name, "Function" }
  end
  if location and location[1] then
    title[#title + 1] = { " " }
    vim.list_extend(title, location[1])
  end

  local width = #tostring(last_row + 1)
  local ret = { title } ---@type sidekick.Text[]
  for i, line in ipairs(lines) do
    ret[#ret + 1] = {
      { ("%" .. width .. "d "):format(start_row + i), "LineNr" },
      { line },
    }
  end
  return ret
end

return M
