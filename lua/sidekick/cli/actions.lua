local Config = require("sidekick.config")

---@alias sidekick.cli.Action fun(terminal: sidekick.cli.Terminal):string?
---@type table<string, sidekick.cli.Action>
local M = {}

local function panel()
  return require("sidekick.cli.panel")
end

function M.prompt(t)
  vim.cmd.stopinsert() -- needed, since otherwise Neovim will do this

  vim.schedule(function()
    local Cli = require("sidekick.cli")
    Cli.prompt(function(prompt)
      vim.schedule(function()
        vim.cmd.startinsert()
      end)
      if prompt then
        Cli.title(t, prompt)
        t:send(prompt .. "\n")
      end
    end)
  end)
end

function M.insert_cr()
  vim.schedule(function()
    vim.cmd.startinsert() -- needed, since otherwise Neovim will do this
    vim.api.nvim_input("<cr>")
  end)
end

---@param source string
---@param t sidekick.cli.Terminal
local function picker(source, t)
  vim.cmd.stopinsert()
  vim.schedule(function()
    require("sidekick.cli.picker").open(source, { filter = { session = t.id } }, {
      on_show = function()
        t.normal_mode = false
      end,
    })
  end)
end

function M.files(t)
  picker("files", t)
end

function M.buffers(t)
  picker("buffers", t)
end

---@param t sidekick.cli.Terminal
function M.fork(t)
  vim.cmd.stopinsert()
  vim.schedule(function()
    require("sidekick.cli").fork({ source = t, focus = true })
  end)
end

---@param t sidekick.cli.Terminal
function M.reference(t)
  vim.cmd.stopinsert()
  vim.schedule(function()
    require("sidekick.cli").reference({ target = t, focus = true })
  end)
end

function M.prev()
  panel().cycle(-1)
end

function M.next()
  panel().cycle(1)
end

function M.move_prev()
  panel().reorder(-1)
end

function M.move_next()
  panel().reorder(1)
end

function M.pick()
  panel().pick()
end

function M.previous()
  panel().previous()
end

function M.pin()
  panel().pin()
end

function M.close_current()
  panel().close()
end

function M.close_unpinned()
  panel().close_many("unpinned")
end

function M.close_others()
  panel().close_many("others")
end

function M.close_left()
  panel().close_many("left")
end

function M.close_right()
  panel().close_many("right")
end

function M.close_invisible()
  panel().close_many("invisible")
end

function M.close_panel()
  panel().close_panel()
end

function M.panel_narrow()
  panel().adjust(-2, 0)
end

function M.panel_widen()
  panel().adjust(2, 0)
end

function M.panel_shorter()
  panel().adjust(0, -1)
end

function M.panel_taller()
  panel().adjust(0, 1)
end

---@param dir "h"|"j"|"k"|"l"
local function nav(dir)
  ---@type sidekick.cli.Action
  return function(terminal)
    local at_edge = vim.fn.winnr() == vim.fn.winnr(dir)
    if at_edge or terminal:is_float() then
      return ("<c-%s>"):format(dir)
    end
    vim.schedule(function()
      (Config.cli.win.nav or vim.cmd.wincmd)(dir)
    end)
  end
end

M.nav_left = nav("h")
M.nav_down = nav("j")
M.nav_up = nav("k")
M.nav_right = nav("l")

return M
