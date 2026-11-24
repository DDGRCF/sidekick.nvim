---@module 'luassert'

local Util = require("sidekick.util")

describe("cli remote launch helper", function()
  local repo_root = vim.fn.getcwd()
  local script_path = vim.fs.joinpath(repo_root, "sk", "cli", "remote.lua")
  local tmp_state

  local function run_remote(args)
    local cmd = {
      "nvim",
      "--headless",
      "-u",
      "NONE",
      "--cmd",
      "set rtp^=" .. repo_root,
      "-l",
      script_path,
    }
    vim.list_extend(cmd, args)
    local res = vim
      .system(cmd, {
        text = true,
        env = {
          XDG_STATE_HOME = tmp_state,
        },
      })
      :wait()
    return res
  end

  before_each(function()
    tmp_state = vim.fn.tempname()
    vim.fn.mkdir(tmp_state, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_state, "rf")
  end)

  it("prepares fresh codex launch and writes state json", function()
    local res = run_remote({ "codex", repo_root, "--instance", "a947bb91" })
    assert.are.equal(0, res.code, res.stderr)

    local out = vim.json.decode(vim.trim(res.stdout))
    assert.are.equal("codex 59bb842411d a947bb91", out.sid)
    assert.are.equal(repo_root, out.cwd)
    assert.are.equal("a947bb91", out.instance_id)
    assert.are.same({ "codex", "--no-alt-screen" }, out.cmd)
    assert.is_false(out.mux_focus)
    assert.are.same({}, out.env)

    local state_file = vim.fs.joinpath(tmp_state, "nvim", "sidekick", out.sid .. ".json")
    assert.is_not_nil(vim.uv.fs_stat(state_file))
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
    assert.are.equal("codex", decoded.tool)
    assert.are.equal("a947bb91", decoded.instance_id)
  end)

  it("prepares managed claude session and preserves env", function()
    local res = run_remote({ "claude", repo_root, "--instance", "11223344" })
    assert.are.equal(0, res.code, res.stderr)

    local out = vim.json.decode(vim.trim(res.stdout))
    assert.are.equal("claude 59bb842411 11223344", out.sid)
    assert.are.equal("claude", out.cmd[1])
    assert.are.equal("--session-id", out.cmd[2])
    assert.is_string(out.cmd[3])
    assert.are.equal("1", out.env.CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN)
    assert.are.equal(out.cmd[3], out.conversation.id)
  end)

  it("prepares resume commands for codex and pi", function()
    local codex_res = run_remote({ "codex", repo_root, "--resume", "conv-123", "--instance", "deadbeef" })
    assert.are.equal(0, codex_res.code, codex_res.stderr)
    local codex_out = vim.json.decode(vim.trim(codex_res.stdout))
    assert.are.same({ "codex", "--no-alt-screen", "resume", "conv-123" }, codex_out.cmd)

    local pi_res =
      run_remote({ "pi", repo_root, "--resume", "019fe6a3-e835-7772-8959-fd1213bf1392", "--instance", "cafebabe" })
    assert.are.equal(0, pi_res.code, pi_res.stderr)
    local pi_out = vim.json.decode(vim.trim(pi_res.stdout))
    assert.are.equal("pi", pi_out.cmd[1])
    assert.is_string(pi_out.env.SIDEKICK_PI_SESSION_FILE)
    assert.are.equal("--session", pi_out.cmd[#pi_out.cmd - 1])
    assert.are.equal("019fe6a3-e835-7772-8959-fd1213bf1392", pi_out.cmd[#pi_out.cmd])
  end)

  it("cleans up persisted state with --cleanup", function()
    local launch_res = run_remote({ "codex", repo_root, "--instance", "face1234" })
    assert.are.equal(0, launch_res.code, launch_res.stderr)
    local out = vim.json.decode(vim.trim(launch_res.stdout))
    local state_file = vim.fs.joinpath(tmp_state, "nvim", "sidekick", out.sid .. ".json")
    assert.is_not_nil(vim.uv.fs_stat(state_file))

    local clean_res = run_remote({ "--cleanup", out.sid })
    assert.are.equal(0, clean_res.code, clean_res.stderr)
    assert.is_nil(vim.uv.fs_stat(state_file))
  end)

  it("exits non-zero for unknown tool", function()
    local res = run_remote({ "nonexistent_tool_xyz", repo_root })
    assert.are_not.equal(0, res.code)
  end)
end)
