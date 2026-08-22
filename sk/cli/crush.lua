---@type sidekick.cli.Config
return {
  cmd = { "crush" },
  capabilities = {
    resume = true,
    fork = false,
    continue = false,
    managed_session = false,
  },
  docs = {
    description = "Charm's AI assistant",
    install = "See [installation](https://github.com/charmbracelet/crush)",
  },
  is_proc = "\\<crush\\>",
  keys = {
    prompt = { "<a-p>", "prompt" },
  },
  -- Crush exposes exact session resume, but no native conversation fork API.
  resume = require("sidekick.cli.provider_sessions").adapter("crush", { "--session" }),
  url = "https://github.com/charmbracelet/crush",
}
