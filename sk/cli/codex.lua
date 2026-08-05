---@type sidekick.cli.Config
return {
  cmd = { "codex" },
  is_proc = "\\<codex\\>",
  url = "https://github.com/openai/codex",
  resume = require("sidekick.cli.provider_sessions").adapter("codex", { "resume" }),
  continue = { "resume", "--last" },
}
