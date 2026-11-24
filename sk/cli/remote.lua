local Resume = require("sidekick.cli.resume")
local Session = require("sidekick.cli.session")
local Tool = require("sidekick.cli.tool")
local Util = require("sidekick.util")

local function fail(msg)
  io.stderr:write(tostring(msg) .. "\n")
  os.exit(1)
end

local function parse_args(argv)
  local positional = {}
  local opts = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--cleanup" then
      i = i + 1
      opts.cleanup = argv[i]
      if not opts.cleanup or opts.cleanup == "" then
        fail("missing sid after --cleanup")
      end
    elseif a == "--resume" then
      i = i + 1
      opts.resume = argv[i]
      if not opts.resume or opts.resume == "" then
        fail("missing conversation id after --resume")
      end
    elseif a == "--instance" then
      i = i + 1
      opts.instance = argv[i]
      if not opts.instance or opts.instance == "" then
        fail("missing instance id after --instance")
      end
    elseif a:sub(1, 2) == "--" then
      fail("unknown option: " .. a)
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end
  return positional, opts
end

local argv = {}
for i = 1, #(_G.arg or {}) do
  argv[i] = _G.arg[i]
end

local positional, opts = parse_args(argv)

if opts.cleanup then
  Util.del_state(opts.cleanup)
  io.stdout:write(vim.json.encode({ ok = true, cleaned = opts.cleanup }) .. "\n")
  io.stdout:flush()
  vim.cmd("qa!")
end

local tool_name = positional[1]
local raw_cwd = positional[2]
if not tool_name or tool_name == "" or not raw_cwd or raw_cwd == "" then
  fail("usage: remote.lua <tool> <cwd> [--resume <conv_id>] [--instance <iid>] | --cleanup <sid>")
end

local tool = Tool.get(tool_name)
if type(tool.cmd) ~= "table" or #tool.cmd == 0 then
  fail("unknown or unconfigured tool: " .. tool_name)
end

local cwd = Session.cwd({ cwd = raw_cwd })
local instance_id = opts.instance or Session.instance()

local cmd = vim.deepcopy(tool.cmd)
local env = vim.deepcopy(tool.env or {})
local conversation

if opts.resume then
  local data
  if tool_name == "pi" then
    local control = vim.fs.joinpath(vim.fn.stdpath("state"), "sidekick", "pi", opts.resume .. ".json")
    vim.fn.mkdir(vim.fs.dirname(control), "p")
    data = { managed = true, control = control }
  end
  conversation = {
    id = opts.resume,
    provider = tool_name,
    resumable = true,
    data = data,
  }
  local saved = {
    tool = tool_name,
    cwd = cwd,
    conversation = conversation,
  }
  local resume_cmd, mode = Resume.command(tool, saved)
  if mode ~= "exact" or type(resume_cmd) ~= "table" then
    fail("tool does not support exact resume: " .. tool_name)
  end
  cmd = resume_cmd
  local resume_env = Resume.env(tool, saved)
  if type(resume_env) == "table" then
    env = vim.tbl_extend("force", env, resume_env)
  end
else
  local adapter = tool.config and tool.config.resume
  if type(adapter) == "table" and not vim.islist(adapter) and type(adapter.prepare) == "function" then
    local ok, prepared = pcall(adapter.prepare, tool, {
      tool = tool,
      cwd = cwd,
      instance_id = instance_id,
    })
    if ok and type(prepared) == "table" then
      if type(prepared.cmd) == "table" then
        cmd = prepared.cmd
      end
      if type(prepared.env) == "table" then
        env = vim.tbl_extend("force", env, prepared.env)
      end
      if type(prepared.conversation) == "table" then
        conversation = vim.deepcopy(prepared.conversation)
      end
    end
  end
end

local sid = Session.sid({
  tool = tool_name,
  cwd = cwd,
  instance_id = instance_id,
})

local ok, state_err = Util.set_state(sid, {
  tool = tool_name,
  cwd = cwd,
  instance_id = instance_id,
  conversation = conversation,
})
if not ok then
  fail(state_err or "failed to persist state")
end

local json_env = next(env) ~= nil and env or vim.empty_dict()
local out = {
  cmd = cmd,
  env = json_env,
  mux_focus = tool.mux_focus == true,
  sid = sid,
  cwd = cwd,
  instance_id = instance_id,
  conversation = conversation,
}

io.stdout:write(vim.json.encode(out) .. "\n")
io.stdout:flush()
vim.cmd("qa!")
