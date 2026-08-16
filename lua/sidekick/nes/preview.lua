local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}
local state ---@type {source_win:integer,source_buf:integer,left_buf:integer,right_buf:integer,left_win:integer,right_win:integer,closing?:boolean,refreshing?:boolean,refresh_pending?:boolean,pending_content?:boolean,content_key?:string,source_tick?:integer,source_autocmd?:integer,win_autocmd?:integer,resize_autocmd?:integer}?

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

---@param buf integer
---@param cursor integer[]
---@return integer[]
local function clamp_cursor(buf, cursor)
  local row = math.max(1, math.min(cursor[1], vim.api.nvim_buf_line_count(buf)))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  return { row, math.min(cursor[2], #line) }
end

local function dimension(value, total, minimum)
  value = type(value) == "number" and value or 0
  value = value > 0 and value <= 1 and math.floor(total * value) or math.floor(value)
  return math.max(minimum, math.min(value, total))
end

local function window_configs()
  local preview = Config.nes.review and Config.nes.review.preview or {}
  local available_width = math.max(0, vim.o.columns - 4)
  local minimum_width = 18 * 2 + 1
  if available_width < minimum_width then
    return nil, "NES preview needs a wider editor"
  end
  local total_width = dimension(preview.width or 0.9, available_width, minimum_width)
  local pane_width = math.floor((total_width - 1) / 2)
  local available_height = math.max(0, vim.o.lines - 4)
  if available_height < 5 then
    return nil, "NES preview needs a taller editor"
  end
  local height = dimension(preview.height or 0.8, available_height, 5)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - total_width) / 2)
  local border = preview.border or "rounded"
  local base = {
    relative = "editor",
    style = "minimal",
    width = pane_width,
    height = height,
    row = row,
    border = border,
    zindex = 50,
  }
  return vim.tbl_extend("force", base, {
    col = col,
    title = " Current ",
    title_pos = "center",
  }), vim.tbl_extend("force", base, {
    col = col + pane_width + 1,
    title = " Suggested ",
    title_pos = "center",
  })
end

local function edit_key(edits)
  local ret = {}
  for _, edit in ipairs(edits) do
    ret[#ret + 1] = table.concat({
      edit.buf or -1,
      edit.from and edit.from[1] or -1,
      edit.from and edit.from[2] or -1,
      edit.to and edit.to[1] or -1,
      edit.to and edit.to[2] or -1,
      edit.text or "",
      edit.textDocument and edit.textDocument.version or -1,
    }, "\31")
  end
  return table.concat(ret, "\30")
end

local function content_key(buf, edits, client)
  return table.concat({
    vim.api.nvim_buf_get_changedtick(buf),
    edit_key(edits),
    client.offset_encoding or "utf-16",
  }, "\30")
end

local function apply_layout(current)
  local left_opts, right_opts = window_configs()
  if not left_opts then
    return false, right_opts
  end
  local ok = pcall(vim.api.nvim_win_set_config, current.left_win, left_opts)
  ok = pcall(vim.api.nvim_win_set_config, current.right_win, right_opts) and ok
  return ok
end

---@param buf integer
---@param lines string[]
---@param name string
local function prepare_buffer(buf, lines, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].sidekick_nes = false
  vim.bo[buf].filetype = vim.bo[vim.api.nvim_get_current_buf()].filetype
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
end

---@param buf integer
---@param win integer
local function configure_window(buf, win)
  vim.wo[win].wrap = false
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  vim.wo[win].scrollbind = true
  vim.wo[win].cursorbind = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winhl = table.concat({
    "Normal:NormalFloat",
    "NormalFloat:NormalFloat",
    "EndOfBuffer:NormalFloat",
    "FloatBorder:FloatBorder",
    "FloatTitle:FloatTitle",
  }, ",")

  local function close()
    M.close()
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true, desc = "Close NES preview" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true, desc = "Close NES preview" })
end

function M.close()
  if not state then
    return false
  end
  if state.closing then
    return false
  end
  state.closing = true
  local closing = state
  local restore = valid_win(closing.source_win) and closing.source_win or vim.api.nvim_get_current_win()
  for _, id in ipairs({ closing.source_autocmd, closing.win_autocmd, closing.resize_autocmd }) do
    if id then
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  for _, win in ipairs({ closing.left_win, closing.right_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local Nes = package.loaded["sidekick.nes"]
  for _, buf in ipairs({ closing.left_buf, closing.right_buf }) do
    if Nes and type(Nes._skip_update) == "table" then
      Nes._skip_update[buf] = nil
    end
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state = nil
  if valid_win(restore) then
    pcall(vim.api.nvim_set_current_win, restore)
  end
  return true
end

---@return boolean opened
function M.open()
  if state then
    if
      valid_win(state.left_win)
      and valid_win(state.right_win)
      and valid_buf(state.left_buf)
      and valid_buf(state.right_buf)
    then
      return M.refresh()
    end
    M.close()
  end
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local Nes = require("sidekick.nes")
  local edits = Nes.get(source_buf)
  local client = Config.get_client(source_buf)
  if #edits == 0 or not client then
    return false
  end

  local preview = Config.nes.review and Config.nes.review.preview or {}
  local left_opts, right_opts = window_configs()
  if not left_opts then
    Util.warn(right_opts)
    return false
  end
  local current_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local left_buf, right_buf, left_win, right_win
  local function cleanup()
    for _, win in ipairs({ left_win, right_win }) do
      if valid_win(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    for _, buf in ipairs({ left_buf, right_buf }) do
      if valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  local ok, err = pcall(function()
    left_buf = vim.api.nvim_create_buf(false, true)
    right_buf = vim.api.nvim_create_buf(false, true)
    prepare_buffer(left_buf, current_lines, "[NES current]")
    prepare_buffer(right_buf, current_lines, "[NES suggested]")

    vim.bo[right_buf].modifiable = true
    vim.lsp.util.apply_text_edits(
      vim.tbl_map(function(edit)
        return { range = edit.range, newText = edit.text }
      end, edits),
      right_buf,
      client.offset_encoding
    )
    vim.bo[right_buf].modifiable = false

    left_win = vim.api.nvim_open_win(left_buf, true, left_opts)
    right_win = vim.api.nvim_open_win(right_buf, false, right_opts)
    configure_window(left_buf, left_win)
    configure_window(right_buf, right_win)
    if preview.winblend then
      vim.wo[left_win].winblend = preview.winblend
      vim.wo[right_win].winblend = preview.winblend
    end
    vim.wo[left_win].diff = true
    vim.wo[right_win].diff = true

    local source_cursor = vim.api.nvim_win_get_cursor(source_win)
    vim.api.nvim_win_set_cursor(left_win, clamp_cursor(left_buf, source_cursor))
    vim.api.nvim_win_set_cursor(right_win, clamp_cursor(right_buf, source_cursor))
  end)
  if not ok then
    cleanup()
    Util.warn(("Failed to open NES preview: %s"):format(err))
    return false
  end

  state = {
    source_win = source_win,
    source_buf = source_buf,
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    content_key = content_key(source_buf, edits, client),
    source_tick = vim.api.nvim_buf_get_changedtick(source_buf),
  }
  local autocmd_ok, autocmd_err = pcall(function()
    state.source_autocmd = vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
      buffer = source_buf,
      once = true,
      callback = function()
        if state and state.source_buf == source_buf then
          M.close()
        end
      end,
    })
    state.win_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
      callback = function()
        if state and not state.closing and (not valid_win(state.left_win) or not valid_win(state.right_win)) then
          M.close()
        end
      end,
    })
    state.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        if state and not state.closing then
          M.refresh({ content = false })
        end
      end,
    })
  end)
  if not autocmd_ok then
    M.close()
    Util.warn(("Failed to initialize NES preview: %s"):format(autocmd_err))
    return false
  end
  return true
end

---@param opts? {content?:boolean,layout?:boolean}
function M.refresh(opts)
  opts = opts or {}
  local current = state
  if not current then
    return false
  end
  local want_content = opts.content ~= false
  local want_layout = opts.layout ~= false
  if current.refreshing then
    current.refresh_pending = true
    current.pending_content = current.pending_content or want_content
    return true
  end
  current.refreshing = true
  local source_win, source_buf = current.source_win, current.source_buf

  local function finish(ok)
    if state == current then
      current.refreshing = false
      if current.refresh_pending then
        local pending_content = current.pending_content == true
        current.refresh_pending = nil
        current.pending_content = nil
        vim.schedule(function()
          if state == current then
            M.refresh({ content = pending_content, layout = true })
          end
        end)
      end
    end
    return ok
  end

  if not valid_buf(source_buf) or not valid_buf(current.left_buf) or not valid_buf(current.right_buf) then
    M.close()
    return false
  end
  if not valid_win(current.left_win) or not valid_win(current.right_win) then
    M.close()
    return M.open()
  end

  if want_layout then
    local ok_layout, layout_err = apply_layout(current)
    if not ok_layout then
      M.close()
      Util.warn(layout_err or "Failed to resize NES preview")
      return false
    end
  end
  if not want_content then
    return finish(true)
  end

  local Nes = require("sidekick.nes")
  local ok_data, edits, client = pcall(function()
    return Nes.get(source_buf), Config.get_client(source_buf)
  end)
  if not ok_data then
    M.close()
    Util.warn(("Failed to refresh NES preview: %s"):format(edits))
    return false
  end
  if #edits == 0 or not client then
    M.close()
    return false
  end

  local next_content_key = content_key(source_buf, edits, client)
  if current.content_key == next_content_key then
    return finish(true)
  end

  local source_cursor = valid_win(source_win) and vim.api.nvim_win_get_cursor(source_win)
    or { 1, 0 }
  local current_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local left_buf, right_buf = current.left_buf, current.right_buf
  -- Buffer updates below can emit TextChanged while a preview pane is
  -- focused. Consume that event without clearing the real NES edits.
  Nes._skip_update[left_buf] = true
  Nes._skip_update[right_buf] = true
  local ok, err = pcall(function()
    vim.bo[left_buf].modifiable = true
    vim.bo[right_buf].modifiable = true
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, current_lines)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, current_lines)
    vim.lsp.util.apply_text_edits(
      vim.tbl_map(function(edit)
        return { range = edit.range, newText = edit.text }
      end, edits),
      right_buf,
      client.offset_encoding
    )
  end)
  if valid_buf(left_buf) then
    vim.bo[left_buf].modifiable = false
  end
  if valid_buf(right_buf) then
    vim.bo[right_buf].modifiable = false
  end

  if not ok then
    M.close()
    Util.warn(("Failed to refresh NES preview: %s"):format(err))
    return false
  end
  if state ~= current then
    return false
  end

  current.content_key = next_content_key
  current.source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
  finish(true)
  for _, win in ipairs({ current.left_win, current.right_win }) do
    if valid_win(win) then
      vim.api.nvim_win_set_cursor(win, clamp_cursor(vim.api.nvim_win_get_buf(win), source_cursor))
    end
  end
  return true
end

---Focus the source window, carrying the preview cursor back to it.
---@return boolean focused
function M.focus_source()
  if not state or not valid_win(state.source_win) then
    return false
  end
  local current = vim.api.nvim_get_current_win()
  if current == state.left_win or current == state.right_win then
    local cursor = vim.api.nvim_win_get_cursor(current)
    vim.api.nvim_win_set_cursor(state.source_win, clamp_cursor(state.source_buf, cursor))
  end
  vim.api.nvim_set_current_win(state.source_win)
  return true
end

function M.toggle()
  if state then
    if valid_win(state.left_win) and valid_win(state.right_win) then
      M.close()
      return true
    end
    M.close()
  end
  return M.open()
end

return M
