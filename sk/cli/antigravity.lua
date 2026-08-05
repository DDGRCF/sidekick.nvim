---@type sidekick.cli.Config
return {
  cmd = { "agy" },
  is_proc = "\\<agy\\>",
  url = "https://antigravity.google/download#antigravity-cli",
  resume = require("sidekick.cli.provider_sessions").adapter("antigravity", { "--conversation" }),
  continue = { "--continue" },
}
