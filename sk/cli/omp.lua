local Managed = require("sidekick.cli.managed_sessions")
local Status = require("sidekick.cli.status")

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
  -- OMP prints the interrupt shortcut while working and an `esc to cancel`
  -- footer while it waits for a choice.
  status = Status.markers({ busy = Status.INTERRUPT_HINT, waiting = { "esc to cancel" } }),
}
