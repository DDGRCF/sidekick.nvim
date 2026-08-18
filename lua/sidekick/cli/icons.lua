local Config = require("sidekick.config")

local M = {}

local highlights = {
  antigravity = "SidekickCliToolAntigravity",
  claude = "SidekickCliToolClaude",
  codex = "SidekickCliToolCodex",
  copilot = "SidekickCliToolCopilot",
  crush = "SidekickCliToolCrush",
  cursor = "SidekickCliToolCursor",
  grok = "SidekickCliToolGrok",
  omp = "SidekickCliToolOmp",
  opencode = "SidekickCliToolOpencode",
  pi = "SidekickCliToolPi",
}

---@param name string
---@return string?
function M.tool(name)
  local icons = Config.cli.win.tabs.icons
  local icon = icons[name] or icons.default
  if type(icon) ~= "string" then
    return nil
  end
  icon = vim.trim(icon)
  return icon ~= "" and icon or nil
end

---@param name string
---@return string
function M.text(name)
  return M.tool(name) or name
end

---@param name string
---@return string
function M.highlight(name)
  return highlights[name] or "SidekickCliTool"
end

return M
