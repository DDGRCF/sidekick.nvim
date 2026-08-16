local Git = require("sidekick.cli.context.git")

local M = {}

local function status_highlight(status)
  if status == "??" then
    return "DiffAdd"
  elseif status:sub(1, 1) ~= " " and status:sub(2, 2) ~= " " then
    return "DiffChange"
  elseif status:sub(1, 1) ~= " " then
    return "DiffChange"
  end
  return "DiffAdd"
end

---@param branch string
---@return string
local function branch_name(branch)
  if branch == "HEAD (no branch)" or branch == "HEAD" then
    return "detached HEAD"
  end
  branch = branch:gsub("^No commits yet on ", "")
  branch = branch:gsub("^Initial commit on ", "")
  return branch ~= "" and branch or "detached HEAD"
end

---@param ctx sidekick.context.ctx
---@return sidekick.Text[]?
---@return boolean? pending
function M.get(ctx)
  local output, pending = Git.run(ctx.cwd, {
    "status",
    "--short",
    "--branch",
    "--untracked-files=all",
  }, ctx.on_update)
  local lines = Git.lines(output)
  if #lines == 0 then
    return nil, pending
  end

  local branch = ""
  local files = {} ---@type {status:string,path:string}[]
  for _, line in ipairs(lines) do
    if line:sub(1, 3) == "## " then
      branch = line:sub(4):match("^(.-)%.%.%.") or line:sub(4)
      branch = branch:match("^([^%[]+)") or branch
      branch = vim.trim(branch)
    elseif #line >= 3 then
      files[#files + 1] = {
        status = line:sub(1, 2),
        path = line:sub(4),
      }
    end
  end

  if #files == 0 then
    return nil, pending
  end

  local ret = {
    { { "Git status", "Title" }, { ": " }, { branch_name(branch), "Special" } },
  } ---@type sidekick.Text[]
  for _, file in ipairs(files) do
    ret[#ret + 1] = {
      { "- ", "@markup.list.markdown" },
      { file.status:gsub(" ", "·"), status_highlight(file.status) },
      { " " },
      { file.path, "Directory" },
    }
  end
  return ret, pending
end

return M
