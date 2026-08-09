---@type sidekick.cli.Config
return {
  cmd = { "codex" },
  is_proc = "\\<codex\\>",
  url = "https://github.com/openai/codex",
  usage = require("sidekick.cli.agent_usage").codex,
  resume = require("sidekick.cli.provider_sessions").adapter("codex", { "resume" }),
  fork = { "fork" },
  continue = { "resume", "--last" },
}
