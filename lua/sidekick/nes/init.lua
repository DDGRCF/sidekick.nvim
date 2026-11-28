local Config = require("sidekick.config")
local Util = require("sidekick.util")

local M = {}

M._edits = {} ---@type sidekick.NesEdit[]
M._requests = {} ---@type table<number, number>
M._skip_update = {} ---@type table<integer, boolean>
M._review_cache = {} ---@type table<integer,{key:string,edits:sidekick.NesEdit[],items:sidekick.NesReviewItem[],summary:table}>
M.enabled = false
M.did_setup = false

function M._invalidate_review()
  M._review_cache = {}
end

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
      -- For "TextChanged" we use LspNotify didChange events to ensure proper
      -- buffer versioning. This is because the LSP server may not have processed
      -- the change yet when the TextChanged event fires.
      local e = (event == "TextChanged" or event == "TextChangedI") and "LspNotify" or event
      local name, pattern = e:match("^(%S+)%s*(.*)$") --[[@as string, string]]
      vim.api.nvim_create_autocmd(name, {
        pattern = pattern ~= "" and pattern or nil,
        group = Config.augroup,
        callback = function(ev)
          if e == "LspNotify" then
            local data = ev.data
            ---@cast data vim.event.lspnotify.data
            local client = vim.lsp.get_client_by_id(data.client_id)

            if not (client and Config.is_copilot(client)) then
              return -- Not Copilot
            end

            if data.method ~= "textDocument/didChange" then
              return -- Not a didChange notification
            end

            if vim.lsp.util.buf_versions[ev.buf] ~= data.params.textDocument.version then
              return -- Outdated buffer version
            end

            local mode = event == "TextChanged" and "n" or "i"
            if vim.fn.mode() ~= mode then
              return -- Not in the correct mode
            end
          end
          fn(ev)
        end,
      })
    end
  end

  on(Config.nes.clear.events, M.clear)
  on(
    Config.nes.trigger.events,
    Util.debounce(function(ev)
      local buf = ev and ev.buf or vim.api.nvim_get_current_buf()
      if type(M._skip_update) == "table" and M._skip_update[buf] then
        M._skip_update[buf] = nil
        return
      end
      M.update(ev)
    end, Config.nes.debounce)
  )
  on({ "BufEnter", "WinEnter" }, Util.debounce(did_focus, 10))

  if Config.nes.diff.show == "cursor" or review_summary_enabled() then
    on(
      { "CursorMoved" },
      Util.debounce(function()
        local UI = require("sidekick.nes.ui")
        if Config.nes.diff.show == "cursor" then
          UI.update_cursor()
        elseif M.have() then
          UI.update_summary()
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
---@param ev? vim.api.keyset.create_autocmd.callback_args
function M.update(ev)
  local buf = ev and ev.buf or vim.api.nvim_get_current_buf()
  M.clear()

  if not is_enabled(buf) then
    return
  end

  local client = Config.get_client(buf)
  if not client then
    return
  end

  local evVersion = ev
    and ev.data
    and ev.data.params
    and ev.data.params.textDocument
    and ev.data.params.textDocument.version

  local version = vim.lsp.util.buf_versions[buf]
  if evVersion and evVersion ~= version then
    return -- outdated request
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  ---@diagnostic disable-next-line: inject-field
  params.textDocument.version = version
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
    if buf ~= nil and edit.buf ~= buf then
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
    return true
  end, M._edits)
end

-- Clear all active edits
function M.clear()
  M.cancel()
  M._skip_update = {}
  M._edits = {}
  M._invalidate_review()
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
      ---@diagnostic disable-next-line: param-type-mismatch
      client:notify("textDocument/didShowInlineEdit", {
        item = {
          command = {
            arguments = edit.command.arguments,
          },
        },
      })
      table.insert(M._edits, e)
    end
  end

  M._invalidate_review()

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
  return M._review_snapshot(buf).items
end

---@param items sidekick.NesReviewItem[]
---@param cursor sidekick.Pos
---@return integer?
local function current_review_index(items, cursor)
  for index, item in ipairs(items) do
    local cover = math.max(1, item.hunk.cover or 1)
    if not item.hunk.inline and item.hunk.kind == "add" and (item.hunk.cover or 0) == 0 then
      -- Pure insertions cover no source lines: their virtual lines render
      -- between this row and the next, so both rows accept the hunk.
      cover = 2
    end
    local end_row = item.pos[1] + cover - 1
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
---@return {key:string,edits:sidekick.NesEdit[],items:sidekick.NesReviewItem[],summary:table}
function M._review_snapshot(buf)
  local valid = vim.api.nvim_buf_is_valid(buf)
  local tick = valid and vim.api.nvim_buf_get_changedtick(buf) or 0
  local version = vim.lsp.util.buf_versions[buf] or -1
  local filetype = valid and vim.bo[buf].filetype or ""
  local row, col = 0, 0
  if buf == vim.api.nvim_get_current_buf() then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row, col = cursor[1], cursor[2]
  end
  local key = table.concat({
    tostring(M._edits),
    tick,
    version,
    filetype,
    tostring(is_enabled(buf)),
    row,
    col,
    tostring(Config.nes.diff.inline),
    vim.o.columns,
  }, "\31")
  local cached = M._review_cache[buf]
  if cached and cached.key == key then
    return cached
  end

  local edits = M.get(buf)
  local items = {} ---@type sidekick.NesReviewItem[]
  for _, edit in ipairs(edits) do
    for _, hunk in ipairs(edit:diff().hunks) do
      items[#items + 1] = {
        edit = edit,
        hunk = hunk,
        pos = vim.deepcopy(hunk.pos),
      }
    end
  end
  table.sort(items, function(a, b)
    return compare_pos(a.pos, b.pos) < 0
  end)

  local current
  if #items > 0 and buf == vim.api.nvim_get_current_buf() then
    current = current_review_index(items, { row - 1, col })
  end
  local snapshot = {
    key = key,
    edits = edits,
    items = items,
    summary = { edits = #edits, hunks = #items, current = current },
  }
  M._review_cache[buf] = snapshot
  return snapshot
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

--- Remap the positions of sibling edits across an accepted hunk using
--- deterministic arithmetic. The accepted hunk is an exact byte/line
--- mutation, so positions outside of it shift by a computable delta.
--- Positions inside the mutation no longer map to meaningful content, so
--- those edits are dropped instead of corrupting the buffer.
---@param client vim.lsp.Client
---@param buf integer
---@param item sidekick.NesReviewItem
---@param mutation sidekick.diff.Mutation
---@return table<sidekick.NesEdit, boolean>
local function remap_siblings(client, buf, item, mutation)
  local Diff = require("sidekick.nes.diff")
  local kept = {}
  local version = vim.lsp.util.buf_versions[buf]
  local mut_from, mut_to = Diff.mutation_range(mutation)
  for _, edit in ipairs(M._edits) do
    if edit.buf == buf and edit ~= item.edit and not ranges_overlap(edit.from, edit.to, mut_from, mut_to) then
      local from = Diff.transform_pos(edit.from, mutation)
      local to = Diff.transform_pos(edit.to, mutation)
      if from and to and compare_pos(from, to) <= 0 then
        edit.from = from
        edit.to = to
        edit.range = {
          start = lsp_position(client, buf, from),
          ["end"] = lsp_position(client, buf, to),
        }
        edit.textDocument.version = version or edit.textDocument.version
        if edit.invalidate_diff then
          edit:invalidate_diff()
        else
          edit._diff = nil
        end
        kept[edit] = true
      end
    end
  end
  return kept
end

--- Build the remaining edit after a partial accept/reject. The edit keeps the
--- precise columns of the original range instead of expanding to full lines,
--- so it never overlaps neighbouring edits sharing the first or last row.
---@param client vim.lsp.Client
---@param edit sidekick.NesEdit
---@param diff sidekick.Diff
---@param current string[]
---@param pending string[]
---@return sidekick.NesEdit
local function partial_edit(client, edit, diff, current, pending)
  local buf = edit.buf
  local start_row = edit.from[1]
  local end_row = start_row + #current - 1
  local end_line = current[#current] or ""

  -- The content before/after the original edit range is shared context that
  -- no hunk ever touches, so the first/last lines of both `current` and
  -- `pending` still carry those exact bytes.
  local prefix_len = edit.from[2]
  local last_from_line = diff.from.lines[#diff.from.lines] or ""
  local suffix_len = math.max(0, #last_from_line - edit.to[2])

  local end_col = math.max(0, #end_line - suffix_len)
  local from = { start_row, math.min(prefix_len, #(current[1] or "")) }
  local to = { end_row, end_col }
  if #current == 1 then
    from[2] = math.min(from[2], end_col)
  end
  local range = {
    start = lsp_position(client, buf, from),
    ["end"] = lsp_position(client, buf, to),
  }
  local version = vim.lsp.util.buf_versions[buf] or edit.textDocument.version or 0

  -- Strip the shared prefix/suffix from the proposal so applying the precise
  -- range does not duplicate them.
  local inner = vim.deepcopy(pending)
  if #inner == 1 then
    inner[1] = inner[1]:sub(prefix_len + 1, math.max(0, #inner[1] - suffix_len))
  else
    inner[1] = inner[1]:sub(prefix_len + 1)
    inner[#inner] = inner[#inner]:sub(1, math.max(0, #inner[#inner] - suffix_len))
  end

  local Edit = require("sidekick.nes.edit")
  local ret = setmetatable({
    buf = buf,
    from = from,
    to = to,
    range = range,
    text = table.concat(inner, "\n"),
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
  local mutation = action == "accept" and Diff.hunk_mutation(diff, item.hunk) or nil
  if action == "accept" then
    local start_row = diff.range.from[1]
    vim.api.nvim_buf_set_lines(buf, start_row, start_row + #diff.from.lines, false, current)
  end
  local siblings = mutation and remap_siblings(client, buf, item, mutation) or {}

  local next_edit = partial_edit(client, item.edit, diff, current, pending)
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
  M._invalidate_review()

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
  return M._review_snapshot(buf).summary
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
    local newlines = select(2, last.text:gsub("\n", ""))
    if newlines > 0 then
      pos[1] = pos[1] + newlines
      pos[2] = #(last.text:match("[^\n]*$") or "")
    else
      pos[2] = pos[2] + #last.text
    end
    M._jump(pos)
  end)
  M.clear()
  return true
end

return M
