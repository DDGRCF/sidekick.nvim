local Config = require("sidekick.config")
local Nes = require("sidekick.nes")
local Edit = require("sidekick.nes.edit")
local Preview = require("sidekick.nes.preview")

vim.opt.termguicolors = true
vim.opt.number = true

-- Setup sidekick
Config.setup({})

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, "auth.lua")
vim.bo[buf].filetype = "lua"

local code = {
  "local M = {}",
  "",
  "function M.login(user, pass)",
  "  if not user or not pass then",
  "    return false, 'missing fields'",
  "  end",
  "  -- check database credentials",
  "  local record = db:lookup(user)",
  "  if record and record.pass == pass then",
  "    return true, record.id",
  "  end",
  "  return false, 'invalid credentials'",
  "end",
  "",
  "return M",
}

vim.api.nvim_buf_set_lines(buf, 0, -1, false, code)
vim.api.nvim_set_current_buf(buf)
vim.lsp.util.buf_versions[buf] = 1

Nes.enabled = true
Config.nes.enabled = true
Config.get_client = function()
  return { offset_encoding = "utf-16" }
end

local suggested = table.concat({
  "  -- check database credentials securely",
  "  local record = db:lookup(user)",
  "  if record and bcrypt.verify(pass, record.hash) then",
  "    local token = jwt.sign({ sub = record.id })",
  "    return true, token",
  "  end",
}, "\n") .. "\n"

Nes._edits = {
  setmetatable({
    buf = buf,
    from = { 6, 0 },
    to = { 11, 0 },
    range = {
      start = { line = 6, character = 0 },
      ["end"] = { line = 11, character = 0 },
    },
    text = suggested,
    textDocument = { uri = "auth.lua", version = 1 },
    command = { title = "Secure auth with bcrypt and jwt" },
  }, Edit),
}

-- Print terminal greeting and trigger review
vim.cmd("redraw")
Preview.open()
vim.cmd("redraw")
