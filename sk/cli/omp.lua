local Managed = require("sidekick.cli.managed_sessions")

---@type sidekick.cli.Config
return {
  cmd = { "omp" },
  capabilities = {
    resume = true,
    fork = true,
    continue = true,
    managed_session = true,
  },
  docs = {
    description = "Oh My Pi CLI",
    install = "bun install -g @oh-my-pi/pi-coding-agent",
  },
  is_proc = "\\<omp\\>",
  url = "https://github.com/can1357/oh-my-pi",
  resume = Managed.adapter("omp"),
  fork = Managed.fork("omp"),
  continue = { "--continue" },
  native_scroll = false,
}
