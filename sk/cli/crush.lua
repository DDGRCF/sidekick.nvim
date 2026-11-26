local Status = require("sidekick.cli.status")

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
  -- Best effort: most agent TUIs print an interrupt hint in the footer while a
  -- turn runs. This only overrides the quiet-output heuristic when it matches.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
}
