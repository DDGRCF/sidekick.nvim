local Git = require("sidekick.cli.context.git")

local M = {}

---@class sidekick.context.GitDiffOpts
---@field staged? boolean Include the staged index diff (default: true)
---@field unstaged? boolean Include the working tree diff (default: true)

local function format_line(line)
  local hl
  if line:match("^@@") then
    hl = "Special"
  elseif line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" or line:match("^diff %-%-git") then
    hl = "Comment"
  elseif line:sub(1, 1) == "+" then
    hl = "DiffAdd"
  elseif line:sub(1, 1) == "-" then
    hl = "DiffDelete"
  end
  return { { line, hl } }
end

---@param ret sidekick.Text[]
---@param label string
---@param output string?
local function add_section(ret, label, output)
  local lines = Git.lines(output)
  if #lines == 0 then
    return
  end

  if #ret > 0 then
    ret[#ret + 1] = { { "" } }
  end
  ret[#ret + 1] = { { ("Git diff (%s)"):format(label), "Title" } }
  for _, line in ipairs(lines) do
    ret[#ret + 1] = format_line(line)
  end
end

---@param ctx sidekick.context.ctx
---@param opts? sidekick.context.GitDiffOpts
---@return sidekick.Text[]?
function M.get(ctx, opts)
  opts = opts or {}
  local include_unstaged = opts.unstaged ~= false
  local include_staged = opts.staged ~= false
  local ret = {} ---@type sidekick.Text[]

  if include_unstaged then
    add_section(
      ret,
      "unstaged",
      Git.run(ctx.cwd, {
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--unified=3",
      })
    )
  end

  if include_staged then
    add_section(
      ret,
      "staged",
      Git.run(ctx.cwd, {
        "diff",
        "--cached",
        "--no-ext-diff",
        "--no-color",
        "--unified=3",
      })
    )
  end

  return #ret > 0 and ret or nil
end

return M
