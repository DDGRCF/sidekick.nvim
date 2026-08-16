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
---@field agent string
---@field items sidekick.cli.ChangesItem[]
---@field index integer
---@field hunk integer
---@field notice? string
---@field compact boolean
---@field list_buf integer
---@field current_buf integer
---@field proposal_buf integer
---@field list_win integer
---@field current_win integer
---@field proposal_win integer
---@field timer? uv.uv_timer_t
local view ---@type sidekick.cli.ChangesView?
local ns = vim.api.nvim_create_namespace("sidekick_cli_changes")

local function valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
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

local function close()
  if not view then
    return
  end
  if view.timer and not view.timer:is_closing() then
    view.timer:stop()
    view.timer:close()
  end
  for _, win in ipairs({ view.list_win, view.current_win, view.proposal_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  view = nil
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
---@param title string
local function set_title(win, title)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, { title = title, title_pos = "center" })
  end
end

---@param win integer
---@param value string
local function set_winbar(win, value)
  if win and vim.api.nvim_win_is_valid(win) then
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
  set_title(view.list_win, title)

  local changed = item()
  if not changed then
    set_title(view.current_win, " Current ")
    set_title(view.proposal_win, " Proposal ")
    set_winbar(view.current_win, "All proposal changes are reviewed")
    set_winbar(view.proposal_win, "[q] Close")
    return
  end

  local location = ("%s %s"):format(changed.status, changed.path)
  local progress = changed.kind == "file" and "File change" or ("Hunk %d/%d"):format(view.hunk, hunk_count(changed))
  local notice = view.notice and (" | %s"):format(view.notice) or ""
  local actions = view.compact and "[a] Accept [r] Reject [q] Close" or "[a] Accept [r] Reject [A/R] All [q] Close"
  set_title(view.current_win, " Current ")
  set_title(view.proposal_win, " Proposal ")
  set_winbar(view.current_win, ("%s | %s%s"):format(location, progress, notice))
  set_winbar(view.proposal_win, actions)
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
    set_buffer(view.proposal_buf, "", "Proposal")
    render_chrome()
    return
  end
  set_buffer(view.current_buf, changed.current or "", changed.path)
  set_buffer(view.proposal_buf, changed.proposal or "", changed.path)
  if vim.api.nvim_win_is_valid(view.list_win) then
    vim.api.nvim_win_set_cursor(view.list_win, { view.index, 0 })
  end
  render_chrome()
  M.jump()
end

---@param force? boolean
---@param notice? string
function M.refresh(force, notice)
  if not view then
    return
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
    return
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
end

local function buffers_modified(changed)
  if not view then
    return false
  end
  local target = vim.fs.normalize(vim.fs.joinpath(view.proposal.root, changed.path))
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
  local current = read(vim.fs.joinpath(view.proposal.root, changed.path))
  local suggested = read(vim.fs.joinpath(view.proposal.cwd, changed.path))
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

---@param action "accept"|"reject"
---@param all? boolean
local function act(action, all)
  if not view then
    return false
  end
  local changed = item()
  if not changed then
    return false
  end
  if buffers_modified(changed) then
    return Util.warn("Save the current buffer before accepting proposal changes")
  end
  if not fresh(changed) then
    return false
  end
  local hunk = changed.diff and changed.diff.hunks[view.hunk] or nil
  if not M.apply(view.proposal, changed, action, hunk) then
    return false
  end
  M.refresh(true)
  if all then
    return true
  end
  return true
end

function M.accept()
  return act("accept")
end

function M.reject()
  return act("reject")
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
    return
  end
  view.index = index
  view.hunk = 1
  render()
end

function M.jump()
  local changed = item()
  local hunk = changed and changed.diff and changed.diff.hunks[view.hunk]
  if not hunk then
    return
  end
  local row = math.max(1, hunk.pos[1] + 1)
  for _, win in ipairs({ view.current_win, view.proposal_win }) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    end
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
    view.index = view.index + 1
    view.hunk = 1
    render()
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
    view.index = view.index - 1
    local changed = item()
    view.hunk = changed and changed.diff and #changed.diff.hunks or 1
    render()
    return
  end
  render_chrome()
  M.jump()
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
        close()
      else
        Util.error(err or "Failed to discard proposal")
      end
    end
  end)
end

---@param buf integer
local function maps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "]c", M.next, opts)
  vim.keymap.set("n", "[c", M.prev, opts)
  vim.keymap.set("n", "a", M.accept, opts)
  vim.keymap.set("n", "r", M.reject, opts)
  vim.keymap.set("n", "A", M.accept_all, opts)
  vim.keymap.set("n", "R", M.reject_all, opts)
end

---@param title string
---@param config vim.api.keyset.win_config
---@param opts? {number?:boolean}
---@return integer, integer
local function window(title, config, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", config, { title = title, title_pos = "center" }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.wo[win].number = not opts or opts.number ~= false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  maps(buf)
  return buf, win
end

function M.open()
  local terminal = Panel.active()
  local proposal = terminal and (terminal.proposal or terminal.parent and terminal.parent.proposal)
  if not proposal then
    return Util.warn("The active agent is not running in proposal mode")
  end
  if view and view.proposal.id == proposal.id then
    close()
    return false
  end
  close()
  local width = vim.o.columns - 4
  local height = vim.o.lines - 4
  if width < 66 or height < 9 then
    return Util.warn("Changes preview needs a wider editor")
  end
  local compact = width < 96
  local list_width = math.min(30, math.max(20, math.floor(width * (compact and 0.3 or 0.22))))
  local row, col = 1, 2
  local common = { relative = "editor", border = "rounded", style = "minimal", zindex = 50 }
  local list_buf, list_win = window(
    " Changes ",
    vim.tbl_extend("force", common, { row = row, col = col, width = list_width, height = height }),
    { number = false }
  )
  local current_buf, current_win, proposal_buf, proposal_win
  local pane_col = col + list_width + 2
  if compact then
    local pane_width = width - list_width - 4
    local current_height = math.floor((height - 2) / 2)
    local proposal_height = height - current_height - 2
    current_buf, current_win = window(
      " Current ",
      vim.tbl_extend("force", common, { row = row, col = pane_col, width = pane_width, height = current_height })
    )
    proposal_buf, proposal_win = window(
      " Proposal ",
      vim.tbl_extend(
        "force",
        common,
        { row = row + current_height + 2, col = pane_col, width = pane_width, height = proposal_height }
      )
    )
  else
    local pane_width = math.floor((width - list_width - 6) / 2)
    current_buf, current_win = window(
      " Current ",
      vim.tbl_extend("force", common, { row = row, col = pane_col, width = pane_width, height = height })
    )
    proposal_buf, proposal_win = window(
      " Proposal ",
      vim.tbl_extend(
        "force",
        common,
        { row = row, col = pane_col + pane_width + 2, width = pane_width, height = height }
      )
    )
  end
  vim.wo[current_win].diff = true
  vim.wo[proposal_win].diff = true
  vim.wo[current_win].scrollbind = true
  vim.wo[proposal_win].scrollbind = true
  view = {
    proposal = proposal,
    agent = type(terminal.title) == "string" and terminal.title ~= "" and terminal.title or terminal.tool.name,
    items = {},
    index = 1,
    hunk = 1,
    compact = compact,
    list_buf = list_buf,
    current_buf = current_buf,
    proposal_buf = proposal_buf,
    list_win = list_win,
    current_win = current_win,
    proposal_win = proposal_win,
  }
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = list_buf,
    callback = function()
      if not view or view.list_buf ~= list_buf or not vim.api.nvim_win_is_valid(list_win) then
        return
      end
      local index = vim.api.nvim_win_get_cursor(list_win)[1]
      M.select(index)
    end,
  })
  vim.api.nvim_set_current_win(list_win)
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
  return true
end

M._collect = collect
M._diff = diff

return M
