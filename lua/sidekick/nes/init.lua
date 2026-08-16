local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}
local PARTIAL_NS = vim.api.nvim_create_namespace("sidekick.nes.partial")

M._edits = {} ---@type sidekick.NesEdit[]
M._requests = {} ---@type table<number, number>
M._skip_update = {} ---@type table<integer, boolean>
M.enabled = false
M.did_setup = false

local function review_summary_enabled()
  return Config.nes.review and Config.nes.review.summary ~= false
end

---@type table<vim.lsp.Client, string>
M.focus_notified = setmetatable({}, {
  __mode = "k",
})

-- Copilot requires the custom didFocus notification
local function did_focus()
  if not M.enabled then
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return -- don't send for special buffer
  end
  local uri = vim.uri_from_bufnr(buf)

  for _, client in ipairs(Config.get_clients({ bufnr = buf })) do
    if M.focus_notified[client] ~= uri then
      M.focus_notified[client] = uri
      ---@diagnostic disable-next-line: param-type-mismatch
      client:notify("textDocument/didFocus", { textDocument = { uri = uri } })
    end
  end
end

---@param enable? boolean
function M.enable(enable)
  enable = enable ~= false
  if M.enabled == enable then
    return
  end
  M.enabled = enable ~= false
  if M.enabled then
    Config.nes.enabled = Config.nes.enabled == false and true or Config.nes.enabled
    M.setup()
    M.update()
  else
    M.clear()
  end
end

function M.toggle()
  M.enable(not M.enabled)
end

function M.disable()
  M.enable(false)
end

---@private
function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true
  ---@param events string[]
  ---@param fn fun(ev:vim.api.keyset.create_autocmd.callback_args)
  local function on(events, fn)
    for _, event in ipairs(events) do
      local name, pattern = event:match("^(%S+)%s*(.*)$") --[[@as string, string]]
      vim.api.nvim_create_autocmd(name, {
        pattern = pattern ~= "" and pattern or nil,
        group = Config.augroup,
        callback = fn,
      })
    end
  end

  on(Config.nes.clear.events, M.clear)
  on(
    Config.nes.trigger.events,
    Util.debounce(function()
      local buf = vim.api.nvim_get_current_buf()
      if type(M._skip_update) == "table" and M._skip_update[buf] then
        M._skip_update[buf] = nil
        return
      end
      M.update()
    end, Config.nes.debounce)
  )
  on({ "BufEnter", "WinEnter" }, Util.debounce(did_focus, 10))

  if Config.nes.diff.show == "cursor" or review_summary_enabled() then
    on(
      { "CursorMoved" },
      Util.debounce(function()
        if M.have() then
          local UI = require("sidekick.nes.ui")
          if Config.nes.diff.show == "cursor" then
            UI.update()
          else
            UI.update_summary()
          end
        end
      end, 50)
    )
  end

  if Config.nes.clear.esc then
    local ESC = vim.keycode("<Esc>")
    vim.on_key(function(_, typed)
      if typed == ESC then
        M.clear()
      end
    end, nil)
  end

  on({ "LspAttach" }, function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and Config.is_copilot(client) then
      did_focus()
    end
  end)

  did_focus()
end

---@param buf? integer
---@return boolean
local function is_enabled(buf)
  local enabled = M.enabled and Config.nes.enabled or false
  buf = buf or vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return false
  end
  if type(enabled) == "function" then
    return enabled(buf) or false
  end
  return enabled ~= false
end

-- Request new edits from the LSP server (if any)
function M.update()
  local buf = vim.api.nvim_get_current_buf()
  M.clear()

  if not is_enabled(buf) then
    return
  end

  local client = Config.get_client(buf)
  if not client then
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  ---@diagnostic disable-next-line: inject-field
  params.textDocument.version = vim.lsp.util.buf_versions[buf]
  params.context = { triggerKind = 2 }

  local done = false
  ---@diagnostic disable-next-line: param-type-mismatch
  local ok, request_id = client:request("textDocument/copilotInlineEdit", params, function(...)
    done = true
    M._handler(...)
  end)
  -- skip tracking if the request failed
  -- or is already done (in-process syncronous response)
  if ok and request_id and not done then
    M._requests[client.id] = request_id
  end
end

---@private
---@param buf? number
function M.get(buf)
  ---@param edit sidekick.NesEdit
  return vim.tbl_filter(function(edit)
    if not vim.api.nvim_buf_is_valid(edit.buf) then
      return false
    end
    if edit.textDocument.version ~= vim.lsp.util.buf_versions[edit.buf] then
      return false
    end
    if not is_enabled(edit.buf) then
      return false
    end
    if edit:is_empty() then
      return false
    end
    return buf == nil or edit.buf == buf
  end, M._edits)
end

-- Clear all active edits
function M.clear()
  M.cancel()
  M._skip_update = {}
  M._edits = {}
  require("sidekick.nes.ui").update()
  local Preview = package.loaded["sidekick.nes.preview"]
  if Preview then
    Preview.close()
  end
end

--- Cancel pending requests
---@private
function M.cancel()
  for client_id, request_id in pairs(M._requests) do
    M._requests[client_id] = nil
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client:cancel_request(request_id)
    end
  end
end

---@param res {edits: sidekick.lsp.NesEdit[]}
---@type lsp.Handler
function M._handler(err, res, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if err or not client then
    return
  end

  if M._requests[ctx.client_id] ~= ctx.request_id then
    return -- stale response from a cancelled request
  end
  M._requests[ctx.client_id] = nil

  M._edits = {}

  res = res or { edits = {} }

  for _, edit in ipairs(res.edits or {}) do
    local e = require("sidekick.nes.edit").new(client, edit)
    if e:valid() and is_enabled(e.buf) then
      table.insert(M._edits, e)
    end
  end

  require("sidekick.nes.ui").update()
end

---@class sidekick.NesReviewItem
---@field edit sidekick.NesEdit
---@field hunk sidekick.diff.Hunk
---@field pos sidekick.Pos

---@param a sidekick.Pos
---@param b sidekick.Pos
---@return integer
local function compare_pos(a, b)
  if a[1] ~= b[1] then
    return a[1] < b[1] and -1 or 1
  end
  if a[2] == b[2] then
    return 0
  end
  return a[2] < b[2] and -1 or 1
end

---@param buf? integer
---@return sidekick.NesReviewItem[]
function M.review_items(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ret = {} ---@type sidekick.NesReviewItem[]
  for _, edit in ipairs(M.get(buf)) do
    for _, hunk in ipairs(edit:diff().hunks) do
      ret[#ret + 1] = {
        edit = edit,
        hunk = hunk,
        pos = vim.deepcopy(hunk.pos),
      }
    end
  end
  table.sort(ret, function(a, b)
    return compare_pos(a.pos, b.pos) < 0
  end)
  return ret
end

---@param items sidekick.NesReviewItem[]
---@param cursor sidekick.Pos
---@return integer?
local function current_review_index(items, cursor)
  for index, item in ipairs(items) do
    local end_row = item.pos[1] + math.max(1, item.hunk.cover or 1) - 1
    if cursor[1] >= item.pos[1] and cursor[1] <= end_row then
      if not item.hunk.inline then
        return index
      end
      local from_col = item.hunk.from_col or item.pos[2]
      local to_col = item.hunk.from_end_col or from_col
      if cursor[2] == from_col or (to_col > from_col and cursor[2] < to_col) then
        return index
      end
    end
  end
end

---@param buf integer
---@return sidekick.NesReviewItem?
local function current_review_item(buf)
  if buf ~= vim.api.nvim_get_current_buf() then
    return
  end
  local items = M.review_items(buf)
  if #items == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local index = current_review_index(items, { cursor[1] - 1, cursor[2] })
  return index and items[index] or nil
end

---@param client vim.lsp.Client
---@param buf integer
---@param pos sidekick.Pos
---@return lsp.Position
local function lsp_position(client, buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ""
  return {
    line = pos[1],
    character = vim.str_utfindex(line, client.offset_encoding or "utf-16", pos[2], false),
  }
end

---@param a_from sidekick.Pos
---@param a_to sidekick.Pos
---@param b_from sidekick.Pos
---@param b_to sidekick.Pos
---@return boolean
local function ranges_overlap(a_from, a_to, b_from, b_to)
  local a_empty = compare_pos(a_from, a_to) == 0
  local b_empty = compare_pos(b_from, b_to) == 0
  if a_empty and b_empty then
    return compare_pos(a_from, b_from) == 0
  elseif a_empty then
    return compare_pos(b_from, a_from) < 0 and compare_pos(a_from, b_to) < 0
  elseif b_empty then
    return compare_pos(a_from, b_from) < 0 and compare_pos(b_from, a_to) < 0
  end
  return compare_pos(a_from, b_to) < 0 and compare_pos(b_from, a_to) < 0
end

---@param edit sidekick.NesEdit
---@param diff sidekick.Diff
---@param hunk sidekick.diff.Hunk
---@return sidekick.Pos from
---@return sidekick.Pos to
local function hunk_range(edit, diff, hunk)
  if hunk.inline then
    return vim.deepcopy(hunk.pos), { hunk.pos[1], hunk.from_end_col or hunk.pos[2] }
  end
  local from = { hunk.pos[1], 0 }
  local count = hunk.from_count or hunk.cover or 0
  if count == 0 then
    if edit.from[1] == from[1] then
      from[2] = edit.from[2]
    end
    return from, from
  end
  local from_index = hunk.from_index or 1
  local last = diff.from.lines[from_index + count - 1] or ""
  local to = { hunk.pos[1] + count - 1, #last }
  if edit.from[1] == from[1] then
    from[2] = edit.from[2]
  end
  if edit.to[1] == to[1] then
    to[2] = edit.to[2]
  end
  return from, to
end

---@param buf integer
---@param item sidekick.NesReviewItem
---@param diff sidekick.Diff
---@return {edit:sidekick.NesEdit,start:integer,finish:integer}[]
local function mark_siblings(buf, item, diff)
  local changed_from, changed_to = hunk_range(item.edit, diff, item.hunk)
  local ret = {}
  vim.api.nvim_buf_clear_namespace(buf, PARTIAL_NS, 0, -1)
  for _, edit in ipairs(M._edits) do
    if edit.buf == buf and edit ~= item.edit and not ranges_overlap(edit.from, edit.to, changed_from, changed_to) then
      local ok_start, start = pcall(vim.api.nvim_buf_set_extmark, buf, PARTIAL_NS, edit.from[1], edit.from[2], {
        right_gravity = true,
      })
      local ok_finish, finish = pcall(vim.api.nvim_buf_set_extmark, buf, PARTIAL_NS, edit.to[1], edit.to[2], {
        right_gravity = true,
      })
      if ok_start and ok_finish then
        ret[#ret + 1] = { edit = edit, start = start, finish = finish }
      elseif ok_start then
        pcall(vim.api.nvim_buf_del_extmark, buf, PARTIAL_NS, start)
      end
    end
  end
  return ret
end

---@param client vim.lsp.Client
---@param buf integer
---@param marks {edit:sidekick.NesEdit,start:integer,finish:integer}[]
---@return table<sidekick.NesEdit, boolean>
local function remap_siblings(client, buf, marks)
  local kept = {}
  local version = vim.lsp.util.buf_versions[buf]
  for _, mark in ipairs(marks) do
    local from = vim.api.nvim_buf_get_extmark_by_id(buf, PARTIAL_NS, mark.start, {})
    local to = vim.api.nvim_buf_get_extmark_by_id(buf, PARTIAL_NS, mark.finish, {})
    if #from == 2 and #to == 2 then
      mark.edit.from = { from[1], from[2] }
      mark.edit.to = { to[1], to[2] }
      mark.edit.range = {
        start = lsp_position(client, buf, mark.edit.from),
        ["end"] = lsp_position(client, buf, mark.edit.to),
      }
      mark.edit.textDocument.version = version or mark.edit.textDocument.version
      mark.edit._diff = nil
      kept[mark.edit] = true
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, PARTIAL_NS, 0, -1)
  return kept
end

---@param client vim.lsp.Client
---@param edit sidekick.NesEdit
---@param current string[]
---@param pending string[]
---@return sidekick.NesEdit
local function partial_edit(client, edit, current, pending)
  local buf = edit.buf
  local start_row = edit.from[1]
  local end_row = start_row + #current - 1
  local end_line = current[#current] or ""
  local from = { start_row, 0 }
  local to = { end_row, #end_line }
  local range = {
    start = lsp_position(client, buf, from),
    ["end"] = lsp_position(client, buf, to),
  }
  local version = vim.lsp.util.buf_versions[buf] or edit.textDocument.version or 0
  vim.lsp.util.buf_versions[buf] = version

  local Edit = require("sidekick.nes.edit")
  local ret = setmetatable({
    buf = buf,
    from = from,
    to = to,
    range = range,
    text = table.concat(pending, "\n"),
    command = edit.command,
    textDocument = {
      uri = edit.textDocument.uri,
      version = version,
    },
  }, Edit) ---@type sidekick.NesEdit
  return ret
end

---@param action "accept"|"reject"
---@return boolean acted
local function act_on_current_hunk(action)
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    return false
  end
  local client = Config.get_client(buf)
  local item = current_review_item(buf)
  if not client or not item then
    return false
  end

  local Diff = require("sidekick.nes.diff")
  local diff = item.edit:diff()
  local current, pending = Diff.apply_hunk(diff, item.hunk, action)
  if #current == 0 then
    current = { "" }
  end
  local sibling_marks = action == "accept" and mark_siblings(buf, item, diff) or {}
  if action == "accept" then
    local start_row = diff.range.from[1]
    vim.api.nvim_buf_set_lines(buf, start_row, start_row + #diff.from.lines, false, current)
  end
  local siblings = action == "accept" and remap_siblings(client, buf, sibling_marks) or {}

  local next_edit = partial_edit(client, item.edit, current, pending)
  local remaining = #next_edit:diff().hunks > 0 and next_edit or nil
  local edits = {}
  for _, edit in ipairs(M._edits) do
    if edit.buf ~= buf or (action == "reject" and edit ~= item.edit) or (action == "accept" and siblings[edit]) then
      edits[#edits + 1] = edit
    end
  end
  if remaining then
    edits[#edits + 1] = next_edit
  end
  M._edits = edits

  local completed = not remaining
  local keep_buffer_edits = vim.tbl_contains(
    vim.tbl_map(function(edit)
      return edit.buf
    end, edits),
    buf
  )
  if completed and action == "accept" and item.edit.command then
    vim.schedule(function()
      if client then
        client:exec_cmd(item.edit.command, { bufnr = buf })
      end
      Util.emit("SidekickNesDone", { client_id = client.id, buffer = buf })
    end)
  end

  M._skip_update[buf] = action == "accept" and keep_buffer_edits or nil
  require("sidekick.nes.ui").update()
  local Preview = package.loaded["sidekick.nes.preview"]
  if Preview then
    Preview.refresh()
  end
  return true
end

---@param buf? integer
---@return {edits:integer,hunks:integer,current:integer?}
function M.summary(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local edits = M.get(buf)
  local items = M.review_items(buf)
  local current
  if #items > 0 and buf == vim.api.nvim_get_current_buf() then
    local cursor = vim.api.nvim_win_get_cursor(0)
    current = current_review_index(items, { cursor[1] - 1, cursor[2] })
  end
  return {
    edits = #edits,
    hunks = #items,
    current = current,
  }
end

---@param buf? integer
---@param direction 1|-1
---@return boolean jumped
local function navigate(buf, direction)
  buf = buf or vim.api.nvim_get_current_buf()
  local items = M.review_items(buf)
  if #items == 0 or buf ~= vim.api.nvim_get_current_buf() then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current = { cursor[1] - 1, cursor[2] }
  local target
  if direction > 0 then
    for _, item in ipairs(items) do
      if compare_pos(item.pos, current) > 0 then
        target = item
        break
      end
    end
    target = target or items[1]
  else
    for index = #items, 1, -1 do
      if compare_pos(items[index].pos, current) < 0 then
        target = items[index]
        break
      end
    end
    target = target or items[#items]
  end
  return M._jump(target.pos)
end

--- Jump to the next active edit hunk, wrapping at the end.
---@return boolean jumped
function M.next()
  return navigate(nil, 1)
end

--- Jump to the previous active edit hunk, wrapping at the beginning.
---@return boolean jumped
function M.prev()
  return navigate(nil, -1)
end

--- Toggle the side-by-side review preview, falling back to a compact summary.
---@return boolean shown
function M.review()
  local Preview = require("sidekick.nes.preview")
  if Preview.toggle() then
    return true
  end
  local summary = M.summary()
  if summary.hunks == 0 then
    return false
  end
  local current = summary.current and ("%d/%d"):format(summary.current, summary.hunks) or ("%d"):format(summary.hunks)
  Util.info(
    ("NES %s · %d edit%s · %d hunk%s"):format(
      current,
      summary.edits,
      summary.edits == 1 and "" or "s",
      summary.hunks,
      summary.hunks == 1 and "" or "s"
    )
  )
  return true
end

--- Accept the edit hunk under the cursor.
---@return boolean accepted
function M.accept()
  local Preview = package.loaded["sidekick.nes.preview"]
  if Preview then
    Preview.focus_source()
  end
  return act_on_current_hunk("accept")
end

--- Reject the edit hunk under the cursor.
---@return boolean rejected
function M.reject()
  local Preview = package.loaded["sidekick.nes.preview"]
  if Preview then
    Preview.focus_source()
  end
  return act_on_current_hunk("reject")
end

--- Open the active edits in a side-by-side floating diff.
---@return boolean opened
function M.preview()
  return require("sidekick.nes.preview").open()
end

--- Jump to the start of the active edit
---@return boolean jumped
function M.jump()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    return false
  end
  local item = M.review_items(buf)[1]
  if not item then
    return false
  end
  return M._jump(item.pos)
end

---@param pos sidekick.Pos
function M._jump(pos)
  pos = vim.deepcopy(pos)
  pos = Util.fix_pos(0, pos)

  local win = vim.api.nvim_get_current_win()

  -- check if we need to jump
  pos[1] = pos[1] + 1
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] == pos[1] and cursor[2] == pos[2] then
    return false
  end

  -- schedule jump
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- add to jump list
    if Config.nes.jumplist then
      vim.cmd("normal! m'")
    end
    vim.api.nvim_win_set_cursor(win, pos)
  end)
  return true
end

-- Check if any edits are active in the current buffer
function M.have()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    return false
  end
  return #M.get(buf) > 0
end

--- Apply active text edits
---@return boolean applied
function M.apply()
  local buf = vim.api.nvim_get_current_buf()
  if not is_enabled(buf) then
    M.clear()
    return false
  end
  local client = Config.get_client(buf)
  local edits = M.get(buf)
  if not client or #edits == 0 then
    return false
  end
  ---@param edit sidekick.NesEdit
  local text_edits = vim.tbl_map(function(edit)
    return {
      range = edit.range,
      newText = edit.text,
    }
  end, edits) --[[@as lsp.TextEdit[] ]]
  vim.schedule(function()
    local last = edits[#edits]
    local diff = last:diff()

    -- apply the edits
    vim.lsp.util.apply_text_edits(text_edits, buf, client.offset_encoding)

    -- let the LSP server know
    vim.schedule(function()
      for _, edit in ipairs(edits) do
        if edit.command then
          client:exec_cmd(edit.command, { bufnr = buf })
        end
      end

      -- notify that we're done
      Util.emit("SidekickNesDone", { client_id = client.id, buffer = buf })
    end)

    -- jump to end of last edit
    local pos = vim.deepcopy(last.from)
    if #diff.to.lines >= 1 then
      pos[1] = pos[1] + (#diff.to.lines - 1)
      pos[2] = pos[2] + #diff.to.text
    end
    M._jump(pos)
  end)
  M.clear()
  return true
end

return M
