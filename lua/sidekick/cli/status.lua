--- Exact agent activity detection from terminal screen markers.
---
--- The generic activity adapter in `sidekick.cli.activity` infers `done` from
--- output going quiet, which cannot tell "the agent is thinking" from "the
--- agent finished". A tool that renders a stable footer can be detected
--- exactly instead: while it works the footer shows the interrupt shortcut,
--- when it hands control back the footer shows the idle prompt hint.
---
--- Add markers to a tool in `sk/cli/<tool>.lua`:
---
--- ```lua
--- status = require("sidekick.cli.status").markers({
---   busy = { "esc to interrupt" },
---   idle = { "? for shortcuts" },
--- }),
--- ```
---
--- Only the last `lines` rows of the terminal buffer are scanned, because the
--- footer is always rendered at the bottom of the screen. When several
--- markers match, the one closest to the bottom wins: the current state is the
--- lowest thing on screen, and older transcript lines above it are history.
local M = {}

--- Rows of the terminal tail scanned for markers. Kept small on purpose: the
--- footer is always the last thing on screen, and a wider window could match a
--- stale footer row from a previous turn.
local DEFAULT_LINES = 6

--- Footer hint most agent TUIs render while a turn is running.
M.INTERRUPT_HINT = { "to interrupt" }

---@class sidekick.cli.StatusMarkers
---@field busy? string[] Plain-text markers that only show while the agent works.
---@field waiting? string[] Plain-text markers that show while the agent wants user input.
---@field idle? string[] Plain-text markers that show while the agent waits for a new prompt.
---@field lines? integer Rows of the terminal tail to scan (default 6).

---@param lines string[]
---@param patterns? string[]
---@return integer? index
local function lowest_hit(lines, patterns)
  if not patterns then
    return nil
  end
  for i = #lines, 1, -1 do
    local line = lines[i]
    for _, pattern in ipairs(patterns) do
      if line:find(pattern, 1, true) then
        return i
      end
    end
  end
end

---@param terminal sidekick.cli.Terminal
---@param count integer
---@return string[]?
function M.tail(terminal, count)
  local buf = terminal.buf
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then
    return nil
  end
  local first = math.max(1, total - count + 1)
  return vim.api.nvim_buf_get_lines(buf, first - 1, total, false)
end

---@param terminal sidekick.cli.Terminal
---@param spec sidekick.cli.StatusMarkers
---@return sidekick.cli.ActivityStatus?
function M.resolve(terminal, spec)
  local lines = M.tail(terminal, spec.lines or DEFAULT_LINES)
  if not lines then
    return nil
  end
  local waiting = lowest_hit(lines, spec.waiting)
  local busy = lowest_hit(lines, spec.busy)
  local idle = lowest_hit(lines, spec.idle)
  if waiting and (not busy or waiting > busy) and (not idle or waiting > idle) then
    return "waiting"
  end
  -- A footer can carry the idle hint and the interrupt hint on the same row
  -- (claude renders `… · esc to interrupt · ← for agents`). The interrupt hint
  -- is the more specific one, so a tie counts as working.
  if busy and (not idle or busy >= idle) then
    return "working"
  end
  if idle then
    return "done"
  end
end

--- Marker specs are kept next to the generated adapter so tool introspection
--- (`:Sidekick cli status`) can show which markers are configured.
---@type table<function, sidekick.cli.StatusMarkers>
local specs = setmetatable({}, { __mode = "k" })

---@param fn? function
---@return sidekick.cli.StatusMarkers?
function M.spec(fn)
  return fn and specs[fn] or nil
end

---@param spec sidekick.cli.StatusMarkers
---@return fun(tool: sidekick.cli.Tool, ev: sidekick.cli.ActivityEvent):sidekick.cli.ActivityStatus?
function M.markers(spec)
  local fn = function(_, ev)
    local terminal = ev.terminal
    if not terminal then
      return nil
    end
    local state = terminal._sidekick_markers
    if not state then
      state = { done = false }
      terminal._sidekick_markers = state
    end
    if ev.type == "input" then
      state.done = false
      return nil
    end
    if ev.type ~= "output" then
      return nil
    end
    local status = M.resolve(terminal, spec)
    if status then
      -- Latch `done` so a late redraw cannot flip a finished agent back to
      -- `working` while it waits for the next prompt.
      state.done = status == "done"
      return status
    end
    if state.done then
      return "done"
    end
    -- No marker: fall back to the generic quiet-output heuristic.
    return nil
  end
  specs[fn] = spec
  return fn
end

---@param spec? sidekick.cli.StatusMarkers
---@param lines string[]
---@return string
local function describe_hits(spec, lines)
  local ret = {}
  for _, kind in ipairs({ "waiting", "busy", "idle" }) do
    local patterns = spec and spec[kind] --[[@as string[]?]]
    if patterns then
      local hits = {}
      for _, pattern in ipairs(patterns) do
        local at = lowest_hit(lines, { pattern })
        hits[#hits + 1] = at and ("line %d: %q"):format(at, pattern) or ("-: %q"):format(pattern)
      end
      ret[#ret + 1] = ("  %-7s %s"):format(kind, table.concat(hits, ", "))
    end
  end
  return table.concat(ret, "\n")
end

--- Dump the marker state of every attached agent so markers can be verified
--- against a real screen. Run while the agent shows the state you care about.
function M.report()
  local State = require("sidekick.cli.state")
  local ret = {}
  for _, st in ipairs(State.get({ attached = true, terminal = true })) do
    local terminal = st.terminal
    if terminal then
      local status_fn = terminal.tool.config.status
      local spec = type(status_fn) == "function" and M.spec(status_fn) or nil
      local lines = M.tail(terminal, (spec and spec.lines) or DEFAULT_LINES) or {}
      ret[#ret + 1] = ("%s · %s [%s]"):format(st.tool and st.tool.name or "?", terminal.id, terminal.status or "?")
      if spec then
        ret[#ret + 1] = describe_hits(spec, lines)
        ret[#ret + 1] = ("  => %s"):format(tostring(M.resolve(terminal, spec)) or "nil")
      else
        ret[#ret + 1] = "  no markers (generic quiet-output heuristic)"
      end
      ret[#ret + 1] = "  tail:"
      for _, line in ipairs(lines) do
        ret[#ret + 1] = "  | " .. line
      end
    end
  end
  if #ret == 0 then
    ret[1] = "No attached agents."
  end
  vim.notify(table.concat(ret, "\n"), vim.log.levels.INFO)
end

return M
