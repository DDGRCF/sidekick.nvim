local M = {}

local Config = require("sidekick.config")

local function environment(tool)
  local env = vim.tbl_extend("force", {}, vim.uv.os_environ(), tool.config.env or {}, tool.env or {})
  for key, value in pairs(env) do
    if value == false then
      env[key] = nil
    end
  end
  return env
end

---@param tool sidekick.cli.Tool
---@param conversation sidekick.cli.Conversation
---@param source sidekick.cli.Terminal
---@param done fun(cmd?:string[],reason?:string)
---@return boolean started
---@return string? reason
function M.prepare(tool, conversation, source, done)
  if vim.fn.executable(tool.cmd[1]) ~= 1 then
    return false, ("`%s` is not installed"):format(tool.cmd[1])
  end

  local finished = false
  local job = -1
  local request_id = 0
  local pending = {}
  local buffer = ""
  local stderr = {}

  local function finish(cmd, reason)
    if finished then
      return
    end
    finished = true
    if job > 0 then
      vim.fn.jobstop(job)
    end
    vim.schedule(function()
      done(cmd, reason)
    end)
  end

  local function fail(reason)
    finish(nil, reason or (#stderr > 0 and stderr[1]) or "Cursor ACP did not return a forked session")
  end

  local function send(method, params, callback)
    request_id = request_id + 1
    pending[request_id] = callback
    local message = vim.json.encode({
      jsonrpc = "2.0",
      id = request_id,
      method = method,
      params = params,
    })
    if vim.fn.chansend(job, message .. "\n") <= 0 then
      fail("Cursor ACP connection closed while sending " .. method)
    end
  end

  local function handle(message)
    if type(message) ~= "table" or message.id == nil then
      return
    end
    local callback = pending[message.id]
    pending[message.id] = nil
    if not callback then
      return
    end
    if message.error then
      local error_message = type(message.error.message) == "string" and message.error.message or "request failed"
      return callback(nil, error_message)
    end
    callback(message.result)
  end

  local function on_stdout(_, data)
    for i, line in ipairs(data or {}) do
      buffer = buffer .. line
      if i < #data then
        local ok, message = pcall(vim.json.decode, buffer)
        buffer = ""
        if ok then
          handle(message)
        end
      end
    end
  end

  local function on_stderr(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        stderr[#stderr + 1] = line
      end
    end
  end

  local function on_exit(_, code)
    if not finished and code ~= 0 then
      fail()
    elseif not finished then
      fail()
    end
  end

  job = vim.fn.jobstart({ tool.cmd[1], "acp" }, {
    cwd = source.cwd,
    stdin = "pipe",
    stdout = "pipe",
    stderr = "pipe",
    clear_env = true,
    env = environment(tool),
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
  })
  if job <= 0 then
    return false, "failed to start the Cursor ACP server"
  end

  local timeout = math.max(1000, Config.cli.workspace.resume_timeout_ms)
  vim.defer_fn(function()
    if not finished then
      fail("timed out waiting for Cursor ACP")
    end
  end, timeout)

  send("initialize", {
    protocolVersion = 1,
    clientCapabilities = {},
    clientInfo = {
      name = "sidekick.nvim",
      version = "dev",
    },
  }, function(_, reason)
    if reason then
      return fail("Cursor ACP initialization failed: " .. reason)
    end
    send("authenticate", { methodId = "cursor_login" }, function(_, auth_reason)
      if auth_reason then
        return fail("Cursor ACP authentication failed: " .. auth_reason)
      end
      send("session/fork", {
        cwd = source.cwd,
        sessionId = conversation.id,
      }, function(result, fork_reason)
        if fork_reason then
          return fail("Cursor ACP fork failed: " .. fork_reason)
        end
        local id = type(result) == "string" and result
          or type(result) == "table" and (result.sessionId or result.session_id or result.id)
        if type(id) ~= "string" or id == "" or id == conversation.id then
          return fail("Cursor ACP returned no independent session id")
        end
        local cmd = vim.deepcopy(tool.cmd)
        vim.list_extend(cmd, { "--resume", id })
        finish(cmd)
      end)
    end)
  end)

  return true
end

return M
