local M = {}

---@param cwd string?
---@param args string[]
---@return string?
function M.run(cwd, args)
  if not cwd or cwd == "" or vim.fn.executable("git") ~= 1 or vim.fn.isdirectory(cwd) ~= 1 then
    return
  end

  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)

  local ok, result = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or not result or result.code ~= 0 then
    return
  end

  return result.stdout or ""
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
