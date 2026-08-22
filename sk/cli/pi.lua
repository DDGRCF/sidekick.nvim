---@type sidekick.cli.Config
return {
  cmd = { "pi" },
  capabilities = {
    resume = true,
    fork = false,
    continue = true,
    managed_session = true,
  },
  docs = {
    description = "Pi coding agent",
    install = "See [installation](https://github.com/badlogic/pi-mono)",
  },
  is_proc = "\\<pi\\>",
  url = "https://github.com/badlogic/pi-mono",
  resume = require("sidekick.cli.managed_sessions").adapter("pi"),
  continue = { "--continue" },
  native_scroll = false,
}
