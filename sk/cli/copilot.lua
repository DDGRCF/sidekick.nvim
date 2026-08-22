local re = vim.regex("\\<copilot\\>")

---@type sidekick.cli.Config
return {
  cmd = { "copilot", "--banner" },
  capabilities = {
    resume = true,
    fork = false,
    continue = true,
    managed_session = true,
  },
  docs = {
    description = "GitHub Copilot CLI",
    install = "npm install -g @githubnext/github-copilot-cli",
  },
  is_proc = function(_, proc)
    return re:match_str(proc.cmd) and not proc.cmd:find("language%-server") or false
  end,
  url = "https://github.com/github/copilot-cli",
  resume = require("sidekick.cli.managed_sessions").adapter("copilot"),
  continue = { "--continue" },
}
