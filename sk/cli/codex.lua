---@type sidekick.cli.Config
return {
  cmd = { "codex" },
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
  url = "https://github.com/openai/codex",
  usage = require("sidekick.cli.agent_usage").codex,
  resume = require("sidekick.cli.provider_sessions").adapter("codex", { "resume" }),
  fork = { "fork" },
  continue = { "resume", "--last" },
}
