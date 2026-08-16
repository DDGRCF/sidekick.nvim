local Config = require("sidekick.config")
local Nes = require("sidekick.nes")
local Util = require("sidekick.util")

local M = {}
local SUMMARY_NS = vim.api.nvim_create_namespace("sidekick.nes.summary")
local summary_marks = {} ---@type table<integer,{id:integer,row:integer,text:string}>
local cursor_buf ---@type integer?
local SIGN_HL = {
  add = "SidekickNesSignAdd",
  change = "SidekickNesSignChange",
  delete = "SidekickNesSignDelete",
}

local function summary_enabled()
  return Config.nes.review and Config.nes.review.summary ~= false
end

---@param buf integer
---@param summary? {edits:integer,hunks:integer,current:integer?}
---@return {icon:string,current:string,edits:string,hunks:string}
local function summary_parts(buf, summary)
  summary = summary or Nes.summary(buf)
  local current = summary.current and ("%d/%d"):format(summary.current, summary.hunks) or tostring(summary.hunks)
  local edit_word = summary.edits == 1 and "edit" or "edits"
  local hunk_word = summary.hunks == 1 and "hunk" or "hunks"
  local icon = type(Config.ui.icons.nes) == "string" and vim.trim(Config.ui.icons.nes) or "NES"
  return {
    icon = icon,
    current = current,
    edits = ("%d %s"):format(summary.edits, edit_word),
    hunks = ("%d %s"):format(summary.hunks, hunk_word),
  }
end

---@param buf integer
---@param summary? {edits:integer,hunks:integer,current:integer?}
---@return string
local function summary_text(buf, summary)
  local parts = summary_parts(buf, summary)
  return (" %s %s · %s · %s"):format(parts.icon, parts.current, parts.edits, parts.hunks)
end

---@param buf integer
---@param summary? {edits:integer,hunks:integer,current:integer?}
---@return sidekick.Text
local function summary_virt_text(buf, summary)
  local parts = summary_parts(buf, summary)
  return {
    { " " .. parts.icon .. " ", "SidekickNesSummaryIcon" },
    { parts.current, "SidekickNesSummaryCount" },
    { " · ", "SidekickNesSummaryMeta" },
    { parts.edits, "SidekickNesSummaryMeta" },
    { " · ", "SidekickNesSummaryMeta" },
    { parts.hunks, "SidekickNesSummaryMeta" },
  }
end

---@param edit sidekick.NesEdit
---@param summary? {edits:integer,hunks:integer,current:integer?}
local function update_summary(edit, summary)
  if not summary_enabled() or not vim.api.nvim_buf_is_valid(edit.buf) then
    return
  end
  local buf = edit.buf
  summary = summary or Nes.summary(buf)
  local previous = summary_marks[buf]
  if summary.hunks == 0 then
    if previous then
      pcall(vim.api.nvim_buf_del_extmark, buf, SUMMARY_NS, previous.id)
    end
    summary_marks[buf] = nil
    return
  end
  local row = edit.from[1]
  local text = summary_text(buf, summary)
  if previous and previous.row == row and previous.text == text then
    return
  end

  local opts = {
    virt_text = summary_virt_text(buf, summary),
    virt_text_pos = "eol",
  }
  if previous then
    opts.id = previous.id
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS, row, 0, opts)
    if ok then
      summary_marks[buf] = { id = id, row = row, text = text }
      return
    end
  end
  local id = vim.api.nvim_buf_set_extmark(buf, SUMMARY_NS, row, 0, opts)
  summary_marks[buf] = { id = id, row = row, text = text }
end

---@param edit sidekick.NesEdit
---@param summaries? table<integer, boolean>
function M.render(edit, summaries)
  vim.b[edit.buf].sidekick_nes_ui = true
  local diff = edit:diff()

  if #diff.hunks == 0 then
    Util.debug("No hunks in edit", edit)
    return
  end

  local from, to = edit.from, edit.to

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local at_edit = vim.api.nvim_get_current_buf() == edit.buf and row >= from[1] and row <= to[1]

  local show_sign = Config.nes.signs or Config.nes.diff.show == "cursor"
  local show_diff = Config.nes.diff.show == "always" or at_edit

  if summary_enabled() and not (summaries or {})[edit.buf] then
    update_summary(edit)
    if summaries then
      summaries[edit.buf] = true
    end
  end

  if show_sign then
    -- Add the sign at the first position
    local sign_hl = SIGN_HL[diff.hunks[1].kind] or "SidekickNesSign"
    Util.set_extmark(edit.buf, Config.ns, from[1], 0, {
      sign_text = Config.ui.icons.nes,
      sign_hl_group = sign_hl,
    })
  end

  if not show_diff then
    return
  end

  local rows = {} ---@type table<number, true>
  for _, hunk in ipairs(diff.hunks) do
    if not hunk.inline then
      for r = hunk.pos[1], hunk.pos[1] + hunk.cover - 1 do
        rows[r] = true
      end
    end
    for _, extmark in ipairs(hunk.extmarks) do
      local opts = vim.tbl_extend("force", {}, extmark) ---@type sidekick.Extmark
      opts.row, opts.col = nil, nil
      Util.set_extmark(edit.buf, Config.ns, extmark.row, extmark.col, opts)
    end
  end

  -- Only add the context bg for lines not yet touched by the rest including inline
  -- This is to fix an issue with extmarks otherwise not displayig correctly
  -- Additionally line_hl_group seems broken in some cases, so don't use that.
  for r = from[1], math.min(vim.api.nvim_buf_line_count(edit.buf) - 1, to[1]) do
    if not rows[r] then
      Util.set_extmark(edit.buf, Config.ns, r, 0, {
        end_row = r + 1,
        hl_group = "SidekickDiffContext",
        hl_eol = true,
      })
    end
  end
end

---@param buf number
function M._hide(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    summary_marks[buf] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, SUMMARY_NS, 0, -1)
  summary_marks[buf] = nil
  if vim.b[buf].sidekick_nes_ui then
    vim.b[buf].sidekick_nes_ui = nil
    vim.api.nvim_buf_clear_namespace(buf, Config.ns, 0, -1)
  end
end

function M.update_summary()
  if not summary_enabled() then
    for buf in pairs(summary_marks) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, SUMMARY_NS, 0, -1)
      end
      summary_marks[buf] = nil
    end
    return
  end

  local seen = {}
  for _, edit in ipairs(Nes.get()) do
    if not seen[edit.buf] then
      update_summary(edit, Nes.summary(edit.buf))
      seen[edit.buf] = true
    end
  end
  for buf in pairs(summary_marks) do
    if not seen[buf] or not vim.api.nvim_buf_is_valid(buf) then
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, SUMMARY_NS, 0, -1)
      end
      summary_marks[buf] = nil
    end
  end
end

function M.update()
  local edits = Nes.get()
  M.hide()
  local summaries = {}
  vim.tbl_map(function(edit)
    M.render(edit, summaries)
  end, edits)

  vim.schedule(function()
    Util.emit("SidekickNes" .. (#edits == 0 and "Hide" or "Show"))
  end)
  cursor_buf = vim.api.nvim_get_current_buf()
end

-- Cursor-only updates are common when diff visibility is set to `cursor`.
-- Keep summaries and unrelated buffers intact instead of clearing every NES
-- namespace and rendering all edits again.
function M.update_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local previous = cursor_buf
  local summaries = {}

  ---@param target integer
  local function redraw(target)
    if not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if vim.b[target].sidekick_nes_ui then
      vim.api.nvim_buf_clear_namespace(target, Config.ns, 0, -1)
    end
    for _, edit in ipairs(Nes.get(target)) do
      M.render(edit, summaries)
    end
  end

  if previous and previous ~= buf then
    -- The previous buffer is no longer under the cursor, but it still needs
    -- its persistent NES sign after its cursor-only diff marks are cleared.
    redraw(previous)
  end
  cursor_buf = buf
  redraw(buf)
end

function M.hide()
  vim.tbl_map(M._hide, vim.api.nvim_list_bufs())
  cursor_buf = nil
end

return M
