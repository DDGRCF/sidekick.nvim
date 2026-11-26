local Status = require("sidekick.cli.status")

---@type sidekick.cli.Config
return {
  cmd = { "cursor-agent" },
  capabilities = {
    resume = true,
    fork = true,
    continue = false,
    managed_session = false,
  },
  docs = {
    description = "Cursor CLI agent",
    install = "See [Cursor docs](https://cursor.com/cli)",
  },
  is_proc = "\\<cursor-agent\\>",
  url = "https://cursor.com/cli",
  resume = require("sidekick.cli.provider_sessions").adapter("cursor", { "--resume" }),
  fork = {
    prepare = function(tool, conversation, source, done)
      return require("sidekick.cli.cursor_fork").prepare(tool, conversation, source, done)
    end,
  },
  -- Best effort: most agent TUIs print an interrupt hint in the footer while a
  -- turn runs. This only overrides the quiet-output heuristic when it matches.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
}
