---@type sidekick.cli.Config
return {
  cmd = { "grok" },
  capabilities = {
    resume = true,
    fork = true,
    continue = false,
    managed_session = false,
  },
  is_proc = "\\<grok\\>",
  url = "https://github.com/xai-org/grok-build",
  resume = require("sidekick.cli.provider_sessions").adapter("grok", { "--resume" }),
  fork = {
    command = function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      vim.list_extend(cmd, { "--resume", conversation.id, "--fork-session" })
      return cmd
    end,
  },
}
