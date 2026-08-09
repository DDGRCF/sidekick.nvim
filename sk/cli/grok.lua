---@type sidekick.cli.Config
return {
  cmd = { "grok" },
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
