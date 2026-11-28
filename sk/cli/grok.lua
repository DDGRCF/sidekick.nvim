local Status = require("sidekick.cli.status")
---@type sidekick.cli.Config
return {
  -- Grok defaults to fullscreen mode: the composer stays pinned to the
  -- bottom of the panel and popups open right above it. Session capture is
  -- process-file-scan based, so the alternate screen breaks neither resume
  -- nor fork verification; scrolling is Grok's own.
  cmd = { "grok" },
  capabilities = {
    resume = true,
    fork = true,
    continue = false,
    managed_session = false,
  },
  docs = {
    description = "Grok Build CLI",
    install = "curl -fsSL https://x.ai/cli/install.sh | bash",
  },
  is_proc = "\\<grok\\>",
  native_scroll = true,
  url = "https://github.com/xai-org/grok-build",
  resume = require("sidekick.cli.provider_sessions").adapter("grok", { "--resume" }),
  fork = {
    command = function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      vim.list_extend(cmd, { "--resume", conversation.id, "--fork-session" })
      return cmd
    end,
  },
  -- Grok prints the interrupt shortcut while working; there is no stable idle
  -- footer, so `done` still comes from the quiet-output fallback.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
}
