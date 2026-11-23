local M = {}

-- Setup Neovim visual defaults for a clean terminal demo
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "yes"
vim.opt.laststatus = 2

-- Configure and initialize Sidekick
local sidekick = require("sidekick")
local nes = require("sidekick.nes")
local ui = require("sidekick.nes.ui")
local preview = require("sidekick.nes.preview")

-- Create demo buffer
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "lua"

local initial_lines = {
  "local function calculate_discount(price, user_level)",
  "  local discount = 0",
  "  if user_level == 'vip' then",
  "    discount = price * 0.2",
  "  else",
  "    discount = 0",
  "  end",
  "  return price - discount",
  "end",
  "",
  "local total = calculate_discount(100, 'vip')",
  "print('Final price:', total)",
}

vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
vim.api.nvim_win_set_cursor(0, { 3, 2 })

-- Mock NES suggestion edit
local mock_edits = {
  {
    range = {
      start = { line = 2, character = 0 },
      ["end"] = { line = 7, character = 0 },
    },
    newText = table.concat({
      "  local discount_rates = { vip = 0.2, gold = 0.15, member = 0.05 }",
      "  local rate = discount_rates[user_level] or 0",
      "  local discount = price * rate",
    }, "\n") .. "\n",
  }
}

-- Render NES diff extmarks
nes._edits = mock_edits
ui.render(mock_edits[1])

print("Buffer initialized with NES suggestion.")
