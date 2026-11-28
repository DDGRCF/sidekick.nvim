---@module 'luassert'

local RemoteBridge = require("sidekick.cli.remote_bridge")

describe("cli remote_bridge", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    local cur = vim.api.nvim_get_current_buf()
    vim.diagnostic.reset(nil, cur)
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("snapshots relative file, cursor line, open buffers, and sorted diagnostics", function()
    local file_path = vim.fs.joinpath(tmp_dir, "src", "main.lua")
    vim.fn.mkdir(vim.fs.dirname(file_path), "p")
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, file_path)

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, file_path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 1", "local b = 2", "local c = 3" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 4 })

    local ns = vim.api.nvim_create_namespace("test_remote_bridge")
    vim.diagnostic.set(ns, buf, {
      { lnum = 2, col = 0, severity = vim.diagnostic.severity.WARN, message = "unused c", source = "lua_ls" },
      { lnum = 0, col = 6, severity = vim.diagnostic.severity.ERROR, message = "bad a", source = "lua_ls" },
    })

    local snap = RemoteBridge.snapshot(tmp_dir)
    vim.diagnostic.reset(ns, buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    assert.are.equal(vim.fs.normalize(tmp_dir), snap.cwd)
    assert.are.equal("src/main.lua", snap.file)
    assert.are.equal(2, snap.line)
    assert.are.equal(5, snap.col)
    assert.is_true(vim.tbl_contains(snap.open_buffers, "src/main.lua"))
    assert.are.equal(2, #snap.diagnostics)
    assert.are.equal("error", snap.diagnostics[1].severity)
    assert.are.equal(1, snap.diagnostics[1].line)
    assert.are.equal("bad a", snap.diagnostics[1].message)
    assert.are.equal("warn", snap.diagnostics[2].severity)
    assert.are.equal("unused c", snap.diagnostics[2].message)
  end)

  it("falls back to normal code window when active buffer is a terminal", function()
    local file_path = vim.fs.joinpath(tmp_dir, "lib", "app.lua")
    vim.fn.mkdir(vim.fs.dirname(file_path), "p")
    vim.fn.writefile({ "return { ok = true }", "local x = 1" }, file_path)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(code_buf, file_path)
    vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "return { ok = true }", "local x = 1" })
    vim.api.nvim_set_current_buf(code_buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    vim.cmd("vsplit")
    local term_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[term_buf].buftype = "nofile"
    vim.api.nvim_set_current_buf(term_buf)

    local snap = RemoteBridge.snapshot(tmp_dir)
    pcall(vim.api.nvim_win_close, 0, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })

    assert.are.equal("lib/app.lua", snap.file)
    assert.are.equal(2, snap.line)
  end)

  it("rejects unknown or missing tools in open_conversation", function()
    local empty_res = RemoteBridge.open_conversation({})
    assert.is_false(empty_res.ok)
    assert.is_string(empty_res.error)

    local unknown_res = RemoteBridge.open_conversation({ tool = "unknown_agent_xyz", cwd = tmp_dir })
    assert.is_false(unknown_res.ok)
    assert.is_truthy(unknown_res.error:find("unknown tool", 1, true))
  end)
end)
