local Panel = require("sidekick.cli.panel")
local Proposal = require("sidekick.cli.proposal")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.cli.ChangesItem
---@field path string
---@field current? string
---@field proposal? string
---@field kind "text"|"file"
---@field binary boolean
---@field status "A"|"M"|"D"
---@field stats sidekick.cli.ChangesStats
---@field key string
---@field diff? sidekick.Diff

---@class sidekick.cli.ChangesStats
---@field added integer
---@field deleted integer
---@field hunks integer

---@class sidekick.cli.ChangesView
---@field proposal sidekick.cli.Proposal
---@field terminal sidekick.cli.Terminal
---@field agent string
---@field tab integer
---@field group integer
---@field items sidekick.cli.ChangesItem[]
---@field index integer
---@field hunk integer
---@field notice? string
---@field list_buf integer
---@field current_buf integer
---@field empty_buf integer
---@field list_win integer
---@field current_win integer
---@field proposal_win integer
---@field proposal_buffers table<string, integer>
---@field mapped_buffers table<integer, boolean>
---@field timer? uv.uv_timer_t
local view ---@type sidekick.cli.ChangesView?
local ns = vim.api.nvim_create_namespace("sidekick_cli_changes")

local function valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab and vim.api.nvim_tabpage_is_valid(tab)
end

---@param cmd string[]
---@return string?
local function output(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result.code == 0 and result.stdout or nil
end

---@param root string
---@return string[]
local function files(root)
  local value = output({ "git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z" }) or ""
  return vim.split(value, "\0", { plain = true, trimempty = true })
end

---@param path string
---@return string?
local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local value = file:read("*a")
  file:close()
  return value
end

---@param path string
---@param value string?
local function write(path, value)
  if value == nil then
    vim.fn.delete(path)
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(value)
  file:close()
end

---@param value string
---@return string[]
local function lines(value)
  if value == "" then
    return {}
  end
  return vim.split(value, "\n", { plain = true })
end

---@param value string
---@return string[]
local function content_lines(value)
  local ret = lines(value)
  if value:sub(-1) == "\n" then
    table.remove(ret)
  end
  return ret
end

---@param item sidekick.cli.ChangesItem
---@return sidekick.Diff?
local function diff(item)
  if item.kind ~= "text" then
    return nil
  end
  local Diff = require("sidekick.nes.diff")
  local from = lines(item.current or "")
  local to = lines(item.proposal or "")
  local ret = {
    hunks = {},
    range = { from = { 0, 0 }, to = { math.max(0, #from - 1), 0 } },
    from = {
      text = item.current or "",
      lines = from,
      virt_lines = vim.tbl_map(function(line)
        return { { line } }
      end, from),
    },
    to = {
      text = item.proposal or "",
      lines = to,
      virt_lines = vim.tbl_map(function(line)
        return { { line } }
      end, to),
    },
  }
  Diff.diff_lines(ret)
  return ret
end

---@param value string?
---@return boolean
local function binary(value)
  return value ~= nil and value:find("\0", 1, true) ~= nil
end

---@param item sidekick.cli.ChangesItem
---@return sidekick.cli.ChangesStats
local function stats(item)
  if item.binary then
    return { added = 0, deleted = 0, hunks = 1 }
  end
  local Diff = require("sidekick.nes.diff")
  local hunks = Diff._diff(content_lines(item.current or ""), content_lines(item.proposal or ""), {
    algorithm = "patience",
    ctxlen = 0,
    indent_heuristic = true,
    interhunkctxlen = 0,
    linematch = 10,
    result_type = "indices",
  })
  local added, deleted = 0, 0
  for _, hunk in ipairs(hunks) do
    deleted = deleted + hunk[2]
    added = added + hunk[4]
  end
  return { added = added, deleted = deleted, hunks = #hunks }
end

---@param current? string
---@param suggested? string
---@return string
local function fingerprint(current, suggested)
  return vim.fn.sha256(vim.json.encode({
    current = current and vim.base64.encode(current) or vim.NIL,
    proposal = suggested and vim.base64.encode(suggested) or vim.NIL,
  }))
end

---@param proposal sidekick.cli.Proposal
---@return sidekick.cli.ChangesItem[]
local function collect(proposal)
  local paths = {} ---@type table<string, boolean>
  for _, root in ipairs({ proposal.root, proposal.cwd }) do
    for _, path in ipairs(files(root)) do
      paths[path] = true
    end
  end
  local ret = {} ---@type sidekick.cli.ChangesItem[]
  for path in pairs(paths) do
    local current = read(vim.fs.joinpath(proposal.root, path))
    local suggested = read(vim.fs.joinpath(proposal.cwd, path))
    if current ~= suggested then
      local is_binary = binary(current) or binary(suggested)
      local kind = (current == nil or suggested == nil or is_binary) and "file" or "text"
      local item = {
        path = path,
        current = current,
        proposal = suggested,
        kind = kind,
        binary = is_binary,
        status = current == nil and "A" or suggested == nil and "D" or "M",
        key = fingerprint(current, suggested),
      }
      item.diff = diff(item)
      item.stats = stats(item)
      item.stats.hunks = item.diff and #item.diff.hunks or 1
      ret[#ret + 1] = item
    end
  end
  table.sort(ret, function(a, b)
    return a.path < b.path
  end)
  return ret
end

---@param buf integer
---@param content string
---@param filename string
local function set_buffer(buf, content, filename)
  local shown = binary(content) and { "[binary file]" } or lines(content)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, shown)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = filename }) or ""
end

local function item()
  return view and view.items[view.index] or nil
end

---@param changed sidekick.cli.ChangesItem
---@return string
local function proposal_path(changed)
  return vim.fs.joinpath(view.proposal.cwd, changed.path)
end

---@param changed sidekick.cli.ChangesItem
---@return string
local function current_path(changed)
  return vim.fs.joinpath(view.proposal.root, changed.path)
end

---@param changed sidekick.cli.ChangesItem
---@return integer
local function hunk_count(changed)
  return changed.diff and #changed.diff.hunks or 1
end

---@param items sidekick.cli.ChangesItem[]
---@return sidekick.cli.ChangesStats
local function summary(items)
  local ret = { added = 0, deleted = 0, hunks = 0 }
  for _, changed in ipairs(items) do
    ret.added = ret.added + changed.stats.added
    ret.deleted = ret.deleted + changed.stats.deleted
    ret.hunks = ret.hunks + hunk_count(changed)
  end
  return ret
end

---@param changed sidekick.cli.ChangesItem
---@return string
local function status_highlight(changed)
  return changed.status == "A" and "DiffAdd" or changed.status == "D" and "DiffDelete" or "DiffChange"
end

---@param changed sidekick.cli.ChangesItem
---@return string
local function item_suffix(changed)
  if changed.binary then
    return "  binary"
  elseif changed.kind == "file" then
    return "  file"
  end
  local hunks = hunk_count(changed)
  return ("  +%d -%d  %d %s"):format(
    changed.stats.added,
    changed.stats.deleted,
    hunks,
    hunks == 1 and "hunk" or "hunks"
  )
end

---@param win integer
---@param value string
local function set_winbar(win, value)
  if valid_win(win) then
    vim.api.nvim_set_option_value("winbar", value:gsub("%%", "%%%%"), { win = win })
  end
end

local function render_chrome()
  if not view then
    return
  end
  local totals = summary(view.items)
  local title = (" Changes | %s | %d %s | +%d -%d | %d %s "):format(
    view.agent,
    #view.items,
    #view.items == 1 and "file" or "files",
    totals.added,
    totals.deleted,
    totals.hunks,
    totals.hunks == 1 and "hunk" or "hunks"
  )
  set_winbar(view.list_win, title)

  local changed = item()
  if not changed then
    set_winbar(view.current_win, "Current | All proposal changes are reviewed")
    set_winbar(view.proposal_win, "Proposal | [q] Close review tab")
    return
  end

  local location = ("%s %s"):format(changed.status, changed.path)
  local progress = changed.kind == "file" and "File change" or ("Hunk %d/%d"):format(view.hunk, hunk_count(changed))
  local notice = view.notice and (" | %s"):format(view.notice) or ""
  set_winbar(view.current_win, ("Current | %s | %s%s"):format(location, progress, notice))
  set_winbar(view.proposal_win, "Proposal | [:w] Save  [dp] Accept hunk  [do] Restore current  [gd] Definition")
end

---@param buf integer
---@param name string
local function setup_scratch(buf, name)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
end

---@param win integer
---@param list? boolean
local function setup_window(win, list)
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = not list
  vim.wo[win].relativenumber = false
end

---@return boolean
local function proposal_buffers_modified()
  if not view then
    return false
  end
  local cwd = vim.fs.normalize(view.proposal.cwd) .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified and vim.startswith(vim.fs.normalize(name), cwd) then
      return true
    end
  end
  return false
end

local function cleanup()
  local current = view
  if not current then
    return
  end
  if current.timer and not current.timer:is_closing() then
    current.timer:stop()
    current.timer:close()
  end
  for buf in pairs(current.mapped_buffers) do
    if valid(buf) then
      pcall(vim.keymap.del, "n", "dp", { buffer = buf })
    end
  end
  pcall(vim.api.nvim_clear_autocmds, { group = current.group })
  pcall(vim.api.nvim_del_augroup_by_id, current.group)
  view = nil
end

---@param force? boolean
---@return boolean closed
local function close(force)
  if not view then
    return false
  end
  if not force and proposal_buffers_modified() then
    return Util.warn("Save or discard Proposal edits before closing the review")
  end
  local tab = view.tab
  if valid_tab(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd(force and "tabclose!" or "tabclose")
  end
  if view and not valid_tab(tab) then
    cleanup()
  end
  return true
end

local hunk_at_row

---@param changed sidekick.cli.ChangesItem
---@return integer?
local function proposal_buffer(changed)
  if not view or changed.binary then
    return
  end
  local path = proposal_path(changed)
  local buf = view.proposal_buffers[path]
  if not valid(buf) then
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    view.proposal_buffers[path] = buf
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype
      or vim.filetype.match({ filename = changed.path })
      or ""
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = view.group,
      buffer = buf,
      callback = function()
        if view and view.proposal_buffers[path] == buf then
          M.refresh(true, "Proposal saved; review refreshed")
        end
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = view.group,
      buffer = buf,
      callback = function()
        if view and valid_win(view.proposal_win) and vim.api.nvim_win_get_buf(view.proposal_win) == buf then
          local changed_item = item()
          if changed_item and changed_item.diff then
            local row = vim.api.nvim_win_get_cursor(view.proposal_win)[1]
            local hunk = hunk_at_row(changed_item, row, "proposal")
            for index, candidate in ipairs(changed_item.diff.hunks) do
              if hunk == candidate and view.hunk ~= index then
                view.hunk = index
                render_chrome()
                break
              end
            end
          end
        end
      end,
    })
    vim.keymap.set("n", "dp", function()
      M.accept_at_cursor()
    end, { buffer = buf, silent = true, desc = "Sidekick changes: accept hunk" })
    view.mapped_buffers[buf] = true
  elseif not vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! checktime")
    end)
  end
  return buf
end

local function diff_windows()
  if not view or not valid_win(view.current_win) or not valid_win(view.proposal_win) then
    return
  end
  for _, win in ipairs({ view.current_win, view.proposal_win }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  vim.api.nvim_win_call(view.proposal_win, function()
    vim.cmd("silent! diffupdate")
  end)
end

---@param path string
local function reload_clean_buffers(path)
  local target = vim.fs.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if valid(buf) and not vim.bo[buf].modified and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == target then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! checktime")
      end)
    end
  end
end

local function render()
  if not view or not valid(view.list_buf) then
    return
  end
  if view.index > #view.items then
    view.index = #view.items
  end
  if view.index < 1 then
    view.index = 1
  end
  local list = {} ---@type string[]
  for index, changed in ipairs(view.items) do
    list[#list + 1] = (index == view.index and "> " or "  ")
      .. changed.status
      .. " "
      .. changed.path
      .. item_suffix(changed)
  end
  if #list == 0 then
    list = { "No pending changes" }
  end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, list)
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.list_buf, ns, 0, -1)
  for index, changed in ipairs(view.items) do
    local prefix = 4
    vim.api.nvim_buf_add_highlight(view.list_buf, ns, status_highlight(changed), index - 1, 2, 3)
    vim.api.nvim_buf_add_highlight(view.list_buf, ns, "Comment", index - 1, prefix + #changed.path, -1)
  end
  local changed = item()
  if not changed then
    set_buffer(view.current_buf, "", "Current")
    if valid_win(view.proposal_win) then
      vim.api.nvim_win_set_buf(view.proposal_win, view.empty_buf)
    end
    render_chrome()
    return
  end
  set_buffer(view.current_buf, changed.current or "", changed.path)
  pcall(
    vim.api.nvim_buf_set_name,
    view.current_buf,
    ("sidekick://changes/current/%s/%s"):format(view.proposal.id, changed.path)
  )
  vim.bo[view.current_buf].filetype = vim.filetype.match({ filename = changed.path }) or ""
  if valid_win(view.current_win) then
    vim.api.nvim_win_set_buf(view.current_win, view.current_buf)
  end
  local buf = proposal_buffer(changed)
  if buf and valid_win(view.proposal_win) then
    vim.api.nvim_win_set_buf(view.proposal_win, buf)
  else
    vim.api.nvim_win_set_buf(view.proposal_win, view.empty_buf)
  end
  if valid_win(view.list_win) then
    vim.api.nvim_win_set_cursor(view.list_win, { view.index, 0 })
  end
  diff_windows()
  render_chrome()
  M.jump()
end

---@param force? boolean
---@param notice? string
function M.refresh(force, notice)
  if not view then
    return
  end
  if proposal_buffers_modified() then
    view.notice = "Proposal has unsaved edits; save before refreshing"
    render_chrome()
    return false
  end
  local previous = item() and item().path
  local previous_hunk = view.hunk
  local items = collect(view.proposal)
  local changed = force or #items ~= #view.items
  if not changed then
    for index, value in ipairs(items) do
      if not view.items[index] or view.items[index].key ~= value.key then
        changed = true
        break
      end
    end
  end
  if not changed then
    return false
  end
  view.items = items
  view.index = 1
  for index, value in ipairs(items) do
    if value.path == previous then
      view.index = index
      break
    end
  end
  local changed_item = item()
  view.hunk = changed_item and math.min(previous == changed_item.path and previous_hunk or 1, hunk_count(changed_item))
    or 1
  view.notice = notice or (not force and "Changes updated; review refreshed" or nil)
  render()
  return true
end

local function root_buffer_modified(changed)
  if not view then
    return false
  end
  local target = vim.fs.normalize(current_path(changed))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == target then
      return true
    end
  end
  return false
end

---@param changed sidekick.cli.ChangesItem
---@return boolean
local function fresh(changed)
  local current = read(current_path(changed))
  local suggested = read(proposal_path(changed))
  local key = fingerprint(current, suggested)
  if key == changed.key then
    return true
  end
  M.refresh(true, "Changes updated; retry the action")
  Util.warn("Changes were updated while reviewing. The view was refreshed; retry the action.")
  return false
end

---@param proposal sidekick.cli.Proposal
---@param changed sidekick.cli.ChangesItem
---@param action "accept"|"reject"
---@param hunk? sidekick.diff.Hunk
---@return boolean
function M.apply(proposal, changed, action, hunk)
  if changed.kind == "file" then
    local target = action == "accept" and vim.fs.joinpath(proposal.root, changed.path)
      or vim.fs.joinpath(proposal.cwd, changed.path)
    write(target, action == "accept" and changed.proposal or changed.current)
    return true
  end
  local value = changed.diff
  hunk = hunk or value and value.hunks[1]
  if not value or not hunk then
    return false
  end
  local Diff = require("sidekick.nes.diff")
  local current, pending = Diff.apply_hunk(value, hunk, action)
  if action == "accept" then
    write(vim.fs.joinpath(proposal.root, changed.path), table.concat(current, "\n"))
  else
    write(vim.fs.joinpath(proposal.cwd, changed.path), table.concat(pending, "\n"))
  end
  return true
end

---@param changed sidekick.cli.ChangesItem
---@param row integer
---@param side "current"|"proposal"
---@return sidekick.diff.Hunk?
hunk_at_row = function(changed, row, side)
  if not changed.diff then
    return
  end
  local source = side == "current" and changed.diff.from.lines or changed.diff.to.lines
  for _, hunk in ipairs(changed.diff.hunks) do
    local from = side == "current" and hunk.from_index or hunk.to_index
    local count = side == "current" and hunk.from_count or hunk.to_count
    from = math.min(math.max(1, from or 1), math.max(1, #source))
    local to = from + math.max(1, count or 0) - 1
    if row >= from and row <= to then
      return hunk
    end
  end
end

---@param action "accept"|"reject"
---@param all? boolean
---@param hunk? sidekick.diff.Hunk
local function act(action, all, hunk)
  if not view then
    return false
  end
  local changed = item()
  if not changed then
    return false
  end
  if proposal_buffers_modified() then
    return Util.warn("Save Proposal edits before accepting changes")
  end
  if action == "accept" and root_buffer_modified(changed) then
    return Util.warn("Save the current buffer before accepting proposal changes")
  end
  if not fresh(changed) then
    return false
  end
  hunk = hunk or changed.diff and changed.diff.hunks[view.hunk] or nil
  if not M.apply(view.proposal, changed, action, hunk) then
    return false
  end
  reload_clean_buffers(action == "accept" and current_path(changed) or proposal_path(changed))
  M.refresh(true)
  if all then
    return true
  end
  return true
end

function M.accept()
  return act("accept")
end

function M.accept_at_cursor()
  if not view then
    return false
  end
  local changed = item()
  if not changed or not changed.diff or not valid_win(view.proposal_win) then
    return Util.warn("Place the cursor on a text hunk in the Proposal window")
  end
  local buf = proposal_buffer(changed)
  if not buf or vim.api.nvim_win_get_buf(view.proposal_win) ~= buf then
    return Util.warn("Place the cursor on a text hunk in the Proposal window")
  end
  local row = vim.api.nvim_win_get_cursor(view.proposal_win)[1]
  local hunk = hunk_at_row(changed, row, "proposal")
  if not hunk then
    return Util.warn("Cursor is not on a pending hunk")
  end
  return act("accept", false, hunk)
end

function M.reject()
  return act("reject")
end

function M.close()
  return close()
end

---@param action "accept"|"reject"
local function act_all(action)
  if not view then
    return
  end
  local paths = vim.tbl_map(function(value)
    return value.path
  end, view.items)
  for _, path in ipairs(paths) do
    M.refresh(true)
    for index, value in ipairs(view.items) do
      if value.path == path then
        view.index = index
        view.hunk = 1
        while item() and item().path == path do
          if not act(action, true) then
            break
          end
          M.refresh(true)
          if not item() or item().path ~= path then
            break
          end
        end
        break
      end
    end
  end
end

function M.accept_all()
  return act_all("accept")
end

function M.reject_all()
  return act_all("reject")
end

---@param index integer
function M.select(index)
  if not view or not view.items[index] or index == view.index then
    return false
  end
  local current = item()
  if current then
    local buf = proposal_buffer(current)
    if buf and vim.bo[buf].modified then
      return Util.warn("Save or discard Proposal edits before switching files")
    end
  end
  view.index = index
  view.hunk = 1
  render()
  return true
end

function M.jump()
  local changed = item()
  local hunk = changed and changed.diff and changed.diff.hunks[view.hunk]
  if not hunk then
    return
  end
  if valid_win(view.current_win) then
    pcall(vim.api.nvim_win_set_cursor, view.current_win, { math.max(1, hunk.from_index or 1), 0 })
  end
  if valid_win(view.proposal_win) then
    pcall(vim.api.nvim_win_set_cursor, view.proposal_win, { math.max(1, hunk.to_index or 1), 0 })
  end
end

function M.next()
  if not view then
    return
  end
  local changed = item()
  if changed and changed.diff and view.hunk < #changed.diff.hunks then
    view.hunk = view.hunk + 1
  elseif view.index < #view.items then
    M.select(view.index + 1)
    return
  end
  render_chrome()
  M.jump()
end

function M.prev()
  if not view then
    return
  end
  if view.hunk > 1 then
    view.hunk = view.hunk - 1
  elseif view.index > 1 then
    if M.select(view.index - 1) then
      local changed = item()
      view.hunk = changed and changed.diff and #changed.diff.hunks or 1
      render()
    end
    return
  end
  render_chrome()
  M.jump()
end

---@param changed sidekick.cli.ChangesItem
---@param hunk? sidekick.diff.Hunk
---@return string
local function request_context(changed, hunk)
  if not hunk then
    return ("File: %s\nChange: file-level %s"):format(changed.path, changed.status)
  end
  local current = vim.list_slice(changed.diff.from.lines, hunk.from_index, hunk.from_index + (hunk.from_count or 0) - 1)
  local proposal = vim.list_slice(changed.diff.to.lines, hunk.to_index, hunk.to_index + (hunk.to_count or 0) - 1)
  local body = {
    ("File: %s"):format(changed.path),
    ("Current lines: %d-%d"):format(hunk.from_index, hunk.from_index + math.max(1, hunk.from_count or 0) - 1),
    ("Proposal lines: %d-%d"):format(hunk.to_index, hunk.to_index + math.max(1, hunk.to_count or 0) - 1),
    "Current:",
  }
  for _, line in ipairs(current) do
    body[#body + 1] = "- " .. line
  end
  body[#body + 1] = "Proposal:"
  for _, line in ipairs(proposal) do
    body[#body + 1] = "+ " .. line
  end
  return table.concat(body, "\n")
end

function M.request()
  if not view then
    return Util.warn("Open a proposal review before requesting changes")
  end
  local changed = item()
  if not changed then
    return Util.warn("There is no pending change to send to the agent")
  end
  local hunk
  if changed.diff and valid_win(view.proposal_win) then
    hunk = hunk_at_row(changed, vim.api.nvim_win_get_cursor(view.proposal_win)[1], "proposal")
      or changed.diff.hunks[view.hunk]
  end
  vim.ui.input({ prompt = "Request agent revision: " }, function(request)
    request = request and vim.trim(request) or ""
    if request == "" or not view then
      return
    end
    local terminal = view.terminal
    if not terminal or not terminal.is_running or not terminal:is_running() then
      return Util.warn("The proposal agent is no longer running")
    end
    local message = table.concat({
      "Please revise the proposal based on this review feedback.",
      "",
      request_context(changed, hunk),
      "",
      "Reviewer request:",
      request,
      "",
      "Edit the proposal worktree only, then leave the revised changes ready for review.",
    }, "\n")
    terminal:send(message .. "\n", { show = false })
    terminal:submit({ show = false })
    if view then
      view.notice = "Revision request sent to agent"
      render_chrome()
    end
  end)
end

function M.discard()
  if not view then
    return
  end
  local proposal = view.proposal
  vim.ui.select({ "Discard proposal", "Cancel" }, { prompt = "Discard this agent proposal?" }, function(choice)
    if choice == "Discard proposal" then
      local ok, err = Proposal.discard(proposal)
      if ok then
        close(true)
      else
        Util.error(err or "Failed to discard proposal")
      end
    end
  end)
end

function M.open()
  local active = Panel.active()
  local terminal = active and (active.parent or active)
  local proposal = terminal and terminal.proposal
  if not proposal then
    return Util.warn("The active agent is not running in proposal mode")
  end
  if view and view.proposal.id == proposal.id and valid_tab(view.tab) then
    vim.api.nvim_set_current_tabpage(view.tab)
    return true
  end
  local cwd = vim.fs.normalize(proposal.cwd) .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and vim.startswith(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), cwd) then
      return Util.warn("Save or discard Proposal edits before opening the review")
    end
  end
  if view and not close() then
    return false
  end
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tcd " .. vim.fn.fnameescape(proposal.cwd))
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = vim.api.nvim_get_current_buf()
  setup_scratch(list_buf, "sidekick://changes/list/" .. proposal.id)
  vim.bo[list_buf].filetype = "sidekick_changes"
  setup_window(list_win, true)
  local current_buf = vim.api.nvim_create_buf(false, true)
  local empty_buf = vim.api.nvim_create_buf(false, true)
  setup_scratch(current_buf, "sidekick://changes/current/" .. proposal.id)
  setup_scratch(empty_buf, "sidekick://changes/empty/" .. proposal.id)
  vim.bo[empty_buf].bufhidden = "hide"
  local wide = vim.o.columns >= 100
  local current_win, proposal_win
  if wide then
    vim.cmd("rightbelow vsplit")
    current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(current_win, current_buf)
    vim.cmd("rightbelow vsplit")
    proposal_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(proposal_win, empty_buf)
    vim.api.nvim_win_set_width(list_win, math.min(30, math.max(24, math.floor(vim.o.columns * 0.22))))
  else
    vim.api.nvim_set_current_win(list_win)
    vim.cmd("belowright split")
    current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(current_win, current_buf)
    vim.cmd("rightbelow vsplit")
    proposal_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(proposal_win, empty_buf)
    vim.api.nvim_win_set_height(list_win, math.min(10, math.max(5, math.floor(vim.o.lines * 0.25))))
  end
  setup_window(current_win)
  setup_window(proposal_win)
  view = {
    proposal = proposal,
    terminal = terminal,
    agent = type(terminal.title) == "string" and terminal.title ~= "" and terminal.title or terminal.tool.name,
    tab = tab,
    group = vim.api.nvim_create_augroup("sidekick_cli_changes_" .. proposal.id, { clear = true }),
    items = {},
    index = 1,
    hunk = 1,
    list_buf = list_buf,
    current_buf = current_buf,
    empty_buf = empty_buf,
    list_win = list_win,
    current_win = current_win,
    proposal_win = proposal_win,
    proposal_buffers = {},
    mapped_buffers = {},
  }
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = view.group,
    buffer = view.list_buf,
    callback = function()
      if not view or view.list_buf ~= list_buf or not vim.api.nvim_win_is_valid(list_win) then
        return
      end
      local index = vim.api.nvim_win_get_cursor(list_win)[1]
      if not M.select(index) then
        vim.api.nvim_win_set_cursor(list_win, { view.index, 0 })
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = view.group,
    buffer = view.current_buf,
    callback = function()
      if not view or not valid_win(view.current_win) or vim.api.nvim_win_get_buf(view.current_win) ~= current_buf then
        return
      end
      local changed = item()
      if not changed or not changed.diff then
        return
      end
      local hunk = hunk_at_row(changed, vim.api.nvim_win_get_cursor(view.current_win)[1], "current")
      for index, candidate in ipairs(changed.diff.hunks) do
        if hunk == candidate and view.hunk ~= index then
          view.hunk = index
          render_chrome()
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = view.group,
    callback = function()
      if view and view.tab == tab and not valid_tab(tab) then
        cleanup()
      end
    end,
  })
  vim.keymap.set("n", "q", close, { buffer = view.list_buf, silent = true, desc = "Close proposal review" })
  vim.keymap.set("n", "<Esc>", close, { buffer = view.list_buf, silent = true, desc = "Close proposal review" })
  vim.keymap.set("n", "<CR>", function()
    if view and valid_win(view.proposal_win) then
      vim.api.nvim_set_current_win(view.proposal_win)
    end
  end, { buffer = view.list_buf, silent = true, desc = "Edit proposal file" })
  local timer = assert(vim.uv.new_timer())
  view.timer = timer
  timer:start(
    300,
    500,
    vim.schedule_wrap(function()
      M.refresh()
    end)
  )
  M.refresh(true)
  if valid_win(view.proposal_win) then
    vim.api.nvim_set_current_win(view.proposal_win)
  end
  return true
end

M._collect = collect
M._diff = diff

return M
