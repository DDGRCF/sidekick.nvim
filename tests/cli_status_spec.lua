---@module 'luassert'

local Activity = require("sidekick.cli.activity")
local Config = require("sidekick.config")
local Status = require("sidekick.cli.status")

describe("cli status markers", function()
  local bufs = {} ---@type integer[]
  local original_notifications

  before_each(function()
    original_notifications = Config.cli.status.notify
    Config.cli.status.notify = false
  end)

  after_each(function()
    Config.cli.status.notify = original_notifications
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    bufs = {}
  end)

  ---@param lines string[]
  ---@param status? sidekick.cli.ActivityStatus
  local function terminal(lines, status)
    local buf = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return {
      id = "status-test",
      buf = buf,
      status = status or "idle",
      tool = { config = {} },
      is_running = function()
        return true
      end,
    }
  end

  local claude = Status.markers({
    busy = { "esc to interrupt" },
    waiting = { "Do you want to proceed" },
    idle = { "? for shortcuts" },
  })

  ---@param t any
  ---@param output? string
  local function output(t, output)
    return claude(t.tool, { type = "output", data = output, terminal = t })
  end

  it("detects working from the interrupt footer", function()
    local t = terminal({ "> fix the tests", "", "✻ Wrangling… (12s · esc to interrupt)", "" })
    assert.are.equal("working", output(t, "✻ Wrangling… (12s · esc to interrupt)"))
  end)

  it("detects done from the idle prompt footer", function()
    local t = terminal({ "Done. 3 files changed.", "", "> ", "? for shortcuts" })
    assert.are.equal("done", output(t, "? for shortcuts"))
  end)

  it("detects waiting from a permission prompt", function()
    local t = terminal({ "Do you want to proceed?", "❯ 1. Yes", "", "Esc to cancel" })
    assert.are.equal("waiting", output(t, "Do you want to proceed?"))
  end)

  it("treats the lowest matching line as the current state", function()
    local t = terminal({ "esc to interrupt", "", "Done.", "> ", "? for shortcuts" })
    assert.are.equal("done", output(t, "? for shortcuts"))
  end)

  it("latches done until the next submit", function()
    local t = terminal({ "Done.", "? for shortcuts" })
    assert.are.equal("done", output(t, "Done."))
    t.status = "done"
    vim.api.nvim_buf_set_lines(t.buf, -1, -1, false, { "redrawn footer" })
    assert.are.equal("done", output(t, "redrawn footer"))
    assert.is_nil(claude(t.tool, { type = "input", data = "next\n", terminal = t }))
    vim.api.nvim_buf_set_lines(t.buf, -1, -1, false, { "✻ Noodling… (2s · esc to interrupt)" })
    assert.are.equal("working", output(t, "esc to interrupt"))
  end)

  it("falls back to the generic heuristic without a marker hit", function()
    local t = terminal({ "some transcript line" })
    assert.is_nil(output(t, "some transcript line"))
  end)

  it("exposes the marker spec for verification", function()
    assert.are.same({ "esc to interrupt" }, Status.spec(claude).busy)
    assert.is_nil(Status.spec(Status.markers({})).idle)
  end)

  it("ignores the echo of a submitted prompt", function()
    local t = terminal({ "" })
    t.is_focused = function()
      return false
    end
    Activity.input(t, "explain the diff\n")
    assert.is_false(Activity.unread(t))
    Activity.output(t, "explain the diff")
    assert.is_false(Activity.unread(t))
    Activity.output(t, "Here is the diff")
    assert.is_true(Activity.unread(t))
    Activity.close(t)
  end)
end)
