local Status = require("sidekick.cli.status")

---@type sidekick.cli.Config
return {
  -- Keep the TUI inline so output stays in the terminal buffer and Neovim
  -- scrolling/resume work instead of the alternate screen owning the viewport.
  cmd = { "codex", "--no-alt-screen" },
  capabilities = {
    resume = true,
    fork = true,
    continue = true,
    managed_session = false,
  },
  docs = {
    description = "OpenAI Codex CLI",
    install = "See [OpenAI docs](https://github.com/openai/codex)",
  },
  is_proc = "\\<codex\\>",
  -- Codex prints the interrupt shortcut next to the elapsed timer while a
  -- turn runs. There is no stable idle footer, so `done` still comes from the
  -- generic quiet-output fallback.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
  url = "https://github.com/openai/codex",
  usage = require("sidekick.cli.agent_usage").codex,
  resume = require("sidekick.cli.provider_sessions").adapter("codex", { "resume" }),
  fork = { "fork" },
  continue = { "resume", "--last" },
}
