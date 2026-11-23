local Config = require("sidekick.config")
local Nes = require("sidekick.nes")
local Edit = require("sidekick.nes.edit")
local Preview = require("sidekick.nes.preview")

-- Set colorscheme & size
vim.opt.termguicolors = true
vim.opt.columns = 110
vim.opt.lines = 32

Config.setup({
  nes = {
    review = {
      preview = {
        width = 0.95,
        height = 0.85,
        border = "rounded",
      },
    },
  },
})

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, "src/auth.lua")
vim.bo[buf].filetype = "lua"

local current_code = {
  "local M = {}",
  "",
  "function M.login(req, res)",
  "  local username = req.body.username",
  "  local password = req.body.password",
  "  if not username or not password then",
  "    return res.status(400):send('Missing credentials')",
  "  end",
  "  local user = db.find_user(username)",
  "  if user and user.password == password then",
  "    return res.send({ token = 'mock-token' })",
  "  end",
  "  return res.status(401):send('Unauthorized')",
  "end",
  "",
  "return M",
}

vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_code)
vim.api.nvim_set_current_buf(buf)
vim.lsp.util.buf_versions[buf] = 1

Nes.enabled = true
Config.nes.enabled = true
Config.get_client = function()
  return { offset_encoding = "utf-16" }
end

local suggested_code = table.concat({
  "  local user = db.find_user(username)",
  "  if user and bcrypt.verify(password, user.hash) then",
  "    local claims = { sub = user.id, exp = os.time() + 3600 }",
  "    local token = jwt.sign(claims, env.SECRET_KEY)",
  "    return res.send({ token = token, expires_in = 3600 })",
  "  end",
}, "\n") .. "\n"

Nes._edits = {
  setmetatable({
    buf = buf,
    from = { 8, 0 },
    to = { 12, 0 },
    range = {
      start = { line = 8, character = 0 },
      ["end"] = { line = 12, character = 0 },
    },
    text = suggested_code,
    textDocument = { uri = "src/auth.lua", version = 1 },
    command = { title = "Apply secure bcrypt & JWT auth" },
  }, Edit),
}

-- Open real floating preview split
Preview.open()

-- Dump TOhtml
vim.g.html_no_progress = 1
vim.cmd("TOhtml")
local html_buf = vim.api.nvim_get_current_buf()
local html_lines = vim.api.nvim_buf_get_lines(html_buf, 0, -1, false)

local out = io.open("assets/real_nes_preview.html", "w")
if out then
  out:write(table.concat(html_lines, "\n"))
  out:close()
  print("Exported assets/real_nes_preview.html successfully")
end
