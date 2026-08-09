---@type sidekick.cli.Config
return {
  cmd = { "agy" },
  is_proc = "\\<agy\\>",
  url = "https://antigravity.google/download#antigravity-cli",
  resume = require("sidekick.cli.provider_sessions").adapter("antigravity", { "--conversation" }),
  fork = {
    command = function(tool, conversation)
      local cmd = vim.deepcopy(tool.cmd)
      vim.list_extend(cmd, { "--conversation", conversation.id })
      return cmd
    end,
    after_start = function(_, terminal, conversation)
      if type(terminal.send) ~= "function" or type(terminal.submit) ~= "function" then
        return false, "terminal input is unavailable"
      end
      local project_id = conversation.data and conversation.data.project_id
      local command = "/fork"
      if type(project_id) == "string" and project_id:match("^[%w_.%-]+$") then
        command = "/fork " .. project_id
      end
      terminal:send(command)
      terminal:submit()
      return true
    end,
  },
  continue = { "--continue" },
}
