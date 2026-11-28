local Managed = require("sidekick.cli.managed_sessions")
local Status = require("sidekick.cli.status")

---@return string?
local function extension()
  return vim.api.nvim_get_runtime_file("sk/extensions/pi-sidekick.ts", false)[1]
end

---@type sidekick.cli.Config
return {
  -- Pi defaults to fullscreen mode: the input dock stays pinned to the bottom
  -- of the panel and dropdowns open right above it. Session-id capture and
  -- fork verification flow through the bundled extension's control file, so
  -- losing the terminal scrollback to the alternate screen breaks neither;
  -- scrolling is Pi's own (it enables full mouse tracking).
  cmd = { "pi" },
  capabilities = {
    resume = true,
    fork = true,
    continue = true,
    managed_session = true,
  },
  docs = {
    description = "Pi coding agent",
    install = "See [installation](https://github.com/badlogic/pi-mono)",
  },
  is_proc = "\\<pi\\>",
  url = "https://github.com/badlogic/pi-mono",
  resume = Managed.adapter("pi"),
  fork = {
    -- Forking relies on the bundled extension to report the child's session
    -- id into the control file; without it the fork can never be verified.
    available = function()
      if not extension() then
        return false, "the bundled pi session extension is unavailable"
      end
      return true
    end,
    -- A forked Pi process writes its new session id into the control file the
    -- bundled extension watches. Use a fresh file so the parent session keeps
    -- reporting its own id.
    env = function()
      local control = vim.fs.joinpath(vim.fn.stdpath("state"), "sidekick", "pi", Managed.uuid() .. ".json")
      vim.fn.mkdir(vim.fs.dirname(control), "p")
      return { SIDEKICK_PI_SESSION_FILE = control }
    end,
    command = function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      local ext = extension()
      if ext then
        vim.list_extend(cmd, { "--extension", ext })
      end
      vim.list_extend(cmd, { "--fork", conversation.id })
      return cmd
    end,
  },
  continue = { "--continue" },
  native_scroll = true,
  -- Pi renders the `app.interrupt` shortcut in its footer while a turn runs.
  status = Status.markers({ busy = Status.INTERRUPT_HINT }),
}
