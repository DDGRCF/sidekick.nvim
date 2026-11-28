local Config = require("sidekick.config")
local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

local M = { did_setup = false }

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warn",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

---@param pid any
---@return boolean
local function pid_alive(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  local killed, _, err_name = vim.uv.kill(pid, 0)
  return killed == 0 or err_name == "EPERM"
end

---@return boolean
function M.register_server()
  local srv = vim.v.servername
  if type(srv) ~= "string" or srv == "" then
    return false
  end
  local map = Util.get_state("nvim-servers")
  if type(map) ~= "table" or vim.islist(map) then
    map = {}
  end
  for k, rec in pairs(map) do
    if type(rec) ~= "table" or not pid_alive(rec.pid) or type(rec.server) ~= "string" or rec.server == "" then
      map[k] = nil
    end
  end
  map[srv] = {
    server = srv,
    cwd = Session.cwd(),
    pid = vim.fn.getpid(),
    updated_at = os.time(),
  }
  return Util.set_state("nvim-servers", map) == true
end

---@return boolean
function M.unregister_server()
  local srv = vim.v.servername
  if type(srv) ~= "string" or srv == "" then
    return false
  end
  local map = Util.get_state("nvim-servers")
  if type(map) ~= "table" or vim.islist(map) then
    return false
  end
  map[srv] = nil
  return Util.set_state("nvim-servers", map) == true
end

function M.setup()
  if M.did_setup or vim.g.sidekick_disable_remote_bridge then
    return
  end
  M.did_setup = true
  local group = vim.api.nvim_create_augroup("sidekick_remote_bridge", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      pcall(M.register_server)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(M.unregister_server)
    end,
  })
  pcall(M.register_server)
end

---@param path string
---@param root string
---@return boolean
local function in_cwd(path, root)
  if root == "" then
    return true
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

---@param path string
---@param root string
---@return string
local function rel_path(path, root)
  local norm = vim.fs.normalize(path)
  if root ~= "" and norm == root then
    return "."
  end
  if root ~= "" and norm:sub(1, #root + 1) == root .. "/" then
    return norm:sub(#root + 2)
  end
  return vim.fn.fnamemodify(norm, ":~")
end

---@param cwd? string
---@return table
function M.snapshot(cwd)
  local target_cwd = (type(cwd) == "string" and cwd ~= "") and Session.cwd({ cwd = cwd }) or Session.cwd()
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_win = 0
  local cur_name = vim.api.nvim_buf_is_valid(cur_buf) and vim.api.nvim_buf_get_name(cur_buf) or ""
  if cur_name == "" or vim.bo[cur_buf].buftype ~= "" then
    local fb_win, fb_buf = nil, nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local b = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "" then
          local bname = vim.api.nvim_buf_get_name(b)
          if bname ~= "" then
            if in_cwd(vim.fs.normalize(bname), target_cwd) then
              cur_win = win
              cur_buf = b
              cur_name = bname
              break
            elseif not fb_win then
              fb_win = win
              fb_buf = b
            end
          end
        end
      end
    end
    if (cur_name == "" or vim.bo[cur_buf].buftype ~= "") and fb_win then
      cur_win = fb_win
      cur_buf = fb_buf
      cur_name = vim.api.nvim_buf_get_name(fb_buf)
    end
  end
  local cur_file = ""
  local cur_line = 0
  local cur_col = 0
  if cur_name ~= "" and vim.bo[cur_buf].buftype == "" then
    cur_file = rel_path(cur_name, target_cwd)
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, cur_win)
    if ok and type(pos) == "table" then
      cur_line = pos[1] or 0
      cur_col = (pos[2] or 0) + 1
    end
  end

  local open_buffers = {}
  local seen_bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local norm = vim.fs.normalize(name)
        if in_cwd(norm, target_cwd) or b == cur_buf then
          local rel = rel_path(norm, target_cwd)
          if not seen_bufs[rel] then
            seen_bufs[rel] = true
            open_buffers[#open_buffers + 1] = rel
            if #open_buffers >= 20 then
              break
            end
          end
        end
      end
    end
  end

  local diags = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
      local bname = vim.api.nvim_buf_get_name(d.bufnr)
      if bname ~= "" then
        local norm = vim.fs.normalize(bname)
        if in_cwd(norm, target_cwd) or d.bufnr == cur_buf then
          local sev = tonumber(d.severity) or vim.diagnostic.severity.INFO
          diags[#diags + 1] = {
            _sev = sev,
            file = rel_path(norm, target_cwd),
            line = (d.lnum or 0) + 1,
            col = (d.col or 0) + 1,
            severity = SEVERITY_NAMES[sev] or "info",
            message = tostring(d.message or ""),
            source = tostring(d.source or ""),
          }
        end
      end
    end
  end
  table.sort(diags, function(a, b)
    if a._sev ~= b._sev then
      return a._sev < b._sev
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col < b.col
  end)
  while #diags > 50 do
    table.remove(diags)
  end
  for _, d in ipairs(diags) do
    d._sev = nil
  end

  return {
    server = vim.v.servername or "",
    cwd = target_cwd,
    file = cur_file,
    line = cur_line,
    col = cur_col,
    open_buffers = open_buffers,
    diagnostics = diags,
  }
end

---@param opts? {tool?:string,cwd?:string,conversation_id?:string,sid?:string,title?:string}
---@return table
function M.open_conversation(opts)
  opts = type(opts) == "table" and opts or {}
  local tool_name = type(opts.tool) == "string" and opts.tool or ""
  if tool_name == "" then
    return { ok = false, error = "missing tool" }
  end
  local ok_tool, tool = pcall(Config.get_tool, tool_name)
  if not ok_tool or not tool or type(tool.cmd) ~= "table" or #tool.cmd == 0 then
    return { ok = false, error = "unknown tool: " .. tool_name }
  end
  local cwd = Session.cwd({ cwd = (type(opts.cwd) == "string" and opts.cwd ~= "") and opts.cwd or nil })
  local conv_id = type(opts.conversation_id) == "string" and opts.conversation_id or ""
  local mode = conv_id ~= "" and "resume" or "show"

  vim.schedule(function()
    if conv_id ~= "" then
      for _, s in pairs(Session._attached) do
        local scid = s.conversation and s.conversation.id
        if s.tool and s.tool.name == tool.name and (scid == conv_id or (opts.sid and s.id == opts.sid)) then
          State.attach(State.get_state(s), { show = true, focus = true, cwd = cwd })
          return
        end
      end
      local conv = { id = conv_id, provider = tool.name, resumable = true }
      local saved = { tool = tool.name, cwd = cwd, conversation = conv }
      local cmd, res_mode = Resume.command(tool, saved)
      local env = Resume.env(tool, saved)
      local effective_tool = tool
      if res_mode == "exact" and type(cmd) == "table" and #cmd > 0 then
        effective_tool = tool:clone({
          cmd = cmd,
          env = type(env) == "table" and vim.tbl_extend("force", vim.deepcopy(tool.env or {}), env) or tool.env,
        })
      end
      local sess = Session.new({
        tool = effective_tool,
        cwd = cwd,
        conversation = conv,
        title = type(opts.title) == "string" and opts.title ~= "" and opts.title or nil,
        skip_resume_prepare = true,
      })
      State.attach(State.get_state(sess), { show = true, focus = true, cwd = cwd })
      return
    end
    require("sidekick.cli").show({ name = tool.name, cwd = cwd, focus = true })
  end)

  return { ok = true, mode = mode, cwd = cwd }
end

return M
