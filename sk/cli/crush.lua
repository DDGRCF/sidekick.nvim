---@type sidekick.cli.Config
return {
  cmd = { "crush" },
  capabilities = {
    resume = true,
    fork = false,
    continue = false,
    managed_session = false,
  },
  is_proc = "\\<crush\\>",
  keys = {
    prompt = { "<a-p>", "prompt" },
  },
  -- Crush exposes exact session resume, but no native conversation fork API.
  resume = require("sidekick.cli.provider_sessions").adapter("crush", { "--session" }),
  url = "https://github.com/charmbracelet/crush",
}
