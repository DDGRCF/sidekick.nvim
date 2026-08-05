---@type sidekick.cli.Config
return {
  cmd = { "grok" },
  is_proc = "\\<grok\\>",
  url = "https://github.com/superagent-ai/grok-cli",
  resume = require("sidekick.cli.provider_sessions").adapter("grok", { "--session" }),
}
