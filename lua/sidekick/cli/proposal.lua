local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

local M = {}

local state_key = "proposals"

---@class sidekick.cli.Proposal
---@field id string
---@field root string User worktree that receives accepted changes
---@field cwd string Isolated worktree used by the agent
---@field branch string Internal proposal branch
---@field base string Commit the proposal was initialized from

---@param cmd string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
local function run(cmd, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  return vim.system(cmd, opts):wait()
end

---@param root string
---@return string?
local function git_root(root)
  local result = run({ "git", "-C", root, "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil
  end
  return vim.fs.normalize(vim.trim(result.stdout or ""))
end

---@param path string
---@return string?
local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local ret = file:read("*a")
  file:close()
  return ret
end

---@param path string
---@param data string
local function write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end

---@param root string
---@return string[]
local function untracked(root)
  local result = run({ "git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z" })
  if result.code ~= 0 then
    return {}
  end
  return vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
end

---@param root string
---@param cwd string
---@return boolean, string?
local function seed(root, cwd)
  local diff = run({ "git", "-C", root, "diff", "--binary", "HEAD" })
  if diff.code ~= 0 then
    return false, diff.stderr
  end
  if diff.stdout and diff.stdout ~= "" then
    local applied = run({ "git", "-C", cwd, "apply", "--binary", "-" }, { stdin = diff.stdout })
    if applied.code ~= 0 then
      return false, applied.stderr
    end
  end
  for _, relpath in ipairs(untracked(root)) do
    local source = vim.fs.joinpath(root, relpath)
    local target = vim.fs.joinpath(cwd, relpath)
    local data = read(source)
    if data then
      write(target, data)
    end
  end
  return true
end

---@param cwd string
---@return string?
local function head(cwd)
  local result = run({ "git", "-C", cwd, "rev-parse", "HEAD" })
  return result.code == 0 and vim.trim(result.stdout or "") or nil
end

---@param cwd string
---@param branch string
---@return boolean, string?
local function commit_baseline(cwd, branch)
  local status = run({ "git", "-C", cwd, "status", "--porcelain" })
  if status.code ~= 0 then
    return false, status.stderr
  end
  if status.stdout == "" then
    return true
  end
  local added = run({ "git", "-C", cwd, "add", "-A" })
  if added.code ~= 0 then
    return false, added.stderr
  end
  local committed = run({
    "git",
    "-C",
    cwd,
    "-c",
    "user.name=Sidekick",
    "-c",
    "user.email=sidekick@localhost",
    "-c",
    "commit.gpgSign=false",
    "commit",
    "--no-verify",
    "-m",
    "sidekick: proposal baseline",
  })
  if committed.code ~= 0 then
    return false, committed.stderr
  end
  return true
end

---@param proposal sidekick.cli.Proposal
function M.save(proposal)
  local state = Util.get_state(state_key) or {}
  state[proposal.id] = proposal
  return Util.set_state(state_key, state)
end

---@param id string?
---@return sidekick.cli.Proposal?
function M.get(id)
  local state = Util.get_state(state_key) or {}
  return id and state[id] or nil
end

---@param id string
function M.remove(id)
  local state = Util.get_state(state_key) or {}
  state[id] = nil
  return Util.set_state(state_key, state)
end

---@param root string
---@param id string
---@return sidekick.cli.Proposal?, string?
function M.create(root, id)
  root = git_root(root) or ""
  if root == "" then
    return nil, "Proposal mode requires a Git worktree. Start with `proposal=false` to edit directly."
  end
  local repo = vim.fn.sha256(root):sub(1, 12)
  local cwd = vim.fs.joinpath(Config.state("proposals"), repo, id)
  local branch = "sidekick/proposal/" .. id
  if vim.fn.isdirectory(cwd) == 1 then
    return nil, "A proposal worktree already exists for this agent."
  end
  vim.fn.mkdir(vim.fs.dirname(cwd), "p")
  local added = run({ "git", "-C", root, "worktree", "add", "-b", branch, cwd, "HEAD" })
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr or "Failed to create proposal worktree")
  end
  local ok, err = seed(root, cwd)
  if not ok then
    run({ "git", "-C", root, "worktree", "remove", "--force", cwd })
    run({ "git", "-C", root, "branch", "-D", branch })
    return nil, vim.trim(err or "Failed to copy current changes into proposal worktree")
  end
  ok, err = commit_baseline(cwd, branch)
  if not ok then
    run({ "git", "-C", root, "worktree", "remove", "--force", cwd })
    run({ "git", "-C", root, "branch", "-D", branch })
    return nil, vim.trim(err or "Failed to create proposal baseline")
  end
  local proposal = { id = id, root = root, cwd = cwd, branch = branch, base = head(cwd) or "" }
  M.save(proposal)
  return proposal
end

---@param proposal sidekick.cli.Proposal
---@return boolean, string?
function M.discard(proposal)
  local removed = run({ "git", "-C", proposal.root, "worktree", "remove", "--force", proposal.cwd })
  if removed.code ~= 0 and vim.fn.isdirectory(proposal.cwd) == 1 then
    return false, vim.trim(removed.stderr or "Failed to remove proposal worktree")
  end
  run({ "git", "-C", proposal.root, "branch", "-D", proposal.branch })
  M.remove(proposal.id)
  return true
end

---@param root string
---@return boolean
function M.has_modified_buffers(root)
  root = vim.fs.normalize(root) .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified and name:sub(1, #root) == root then
      return true
    end
  end
  return false
end

return M
