local Util = require("sidekick.util")
local Config = require("sidekick.config")

---@alias sidekick.Pos {[1]:integer, [2]:integer}

---@class sidekick.lsp.NesEdit
---@field command lsp.Command
---@field range lsp.Range
---@field text string
---@field textDocument {uri: string, version: integer}

---@class sidekick.NesEdit: sidekick.lsp.NesEdit
---@field buf integer
---@field from sidekick.Pos
---@field to sidekick.Pos
---@field _diff sidekick.Diff
---@field _diff_key string
local M = {}
M.__index = M

---@param client vim.lsp.Client
---@param buf number
---@param p lsp.Position
---@return sidekick.Pos
local function pos(client, buf, p)
  local line = vim.api.nvim_buf_get_lines(buf, p.line, p.line + 1, false)[1] or ""
  return { p.line, vim.str_byteindex(line, client.offset_encoding, p.character, false) }
end

---@param client vim.lsp.Client
---@param edit sidekick.lsp.NesEdit
function M.new(client, edit)
  local self = setmetatable(edit, M) --[[@as sidekick.NesEdit]]

  local fname = vim.uri_to_fname(edit.textDocument.uri)
  self.buf = vim.fn.bufnr(fname, false)

  if self.buf ~= -1 and vim.api.nvim_buf_is_valid(self.buf) then
    self.from, self.to = pos(client, self.buf, self.range.start), pos(client, self.buf, self.range["end"])
    self.to = Util.fix_pos(self.buf, self.to)
  end
  return self
end

function M:valid()
  return self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and self.textDocument.version == vim.lsp.util.buf_versions[self.buf]
end

function M:diff()
  local tick = 0
  local filetype = ""
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    tick = vim.api.nvim_buf_get_changedtick(self.buf)
    filetype = vim.bo[self.buf].filetype
  end
  local key = table.concat({
    tick,
    self.from and self.from[1] or -1,
    self.from and self.from[2] or -1,
    self.to and self.to[1] or -1,
    self.to and self.to[2] or -1,
    self.text or "",
    filetype,
    tostring(Config.nes.diff.inline),
    vim.o.columns,
  }, "\31")
  if not self._diff or self._diff_key ~= key then
    self._diff = require("sidekick.nes.diff").diff(self)
    self._diff_key = key
  end
  return self._diff
end

function M:invalidate_diff()
  self._diff = nil
  self._diff_key = nil
end

function M:is_empty()
  return #self:diff().hunks == 0
end

return M
