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
  is_proc = "\\<omp\\>",
  url = "https://github.com/can1357/oh-my-pi",
  resume = Managed.adapter("omp"),
  fork = Managed.fork("omp"),
  continue = { "--continue" },
  native_scroll = false,
}
