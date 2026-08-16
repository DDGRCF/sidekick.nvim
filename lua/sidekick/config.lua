---@class sidekick.config: sidekick.Config
local M = {}

M.ns = vim.api.nvim_create_namespace("sidekick.ui")
local derived_highlights = {} ---@type table<string,{attrs:table,custom:boolean}>

---@class sidekick.Config
local defaults = {
  nes = {
    ---@type boolean|fun(buf:integer):boolean?
    enabled = function(buf)
      return vim.g.sidekick_nes ~= false and vim.b.sidekick_nes ~= false
    end,
    debounce = 100,
    trigger = {
      -- events that trigger sidekick next edit suggestions
      events = { "ModeChanged i:n", "TextChanged", "User SidekickNesDone" },
    },
    clear = {
      -- events that clear the current next edit suggestion
      events = { "TextChangedI", "InsertEnter" },
      esc = true, -- clear next edit suggestions when pressing <Esc>
    },
    ---@class sidekick.diff.Opts
    ---@field inline? "words"|"chars"|false Enable inline diffs
    ---@field show? "always"|"cursor" `cursor` will only show the diff when the cursor is at the edit position.
    diff = {
      inline = "words",
      show = "always",
    },
    review = {
      -- show a compact progress summary for active suggestions
      summary = true,
      -- floating side-by-side preview used by `:Sidekick nes review`
      preview = {
        width = 0.9,
        height = 0.8,
        border = "rounded",
        winblend = 0,
      },
    },
    signs = true, -- show signs for next edit suggestions
    jumplist = true, -- add an entry to the jumplist
  },
  -- Work with AI cli tools directly from within Neovim
  cli = {
    watch = true, -- notify Neovim of file changes done by AI CLI tools
    status = {
      -- With no tool-specific status adapter, output becoming quiet after this
      -- delay marks a working agent as done.
      quiet_ms = 2000,
    },
    workspace = {
      enabled = true,
      autosave = true,
      autorestore = true,
      restore_tabpages = true,
      resume_timeout_ms = 15000,
    },
    proposal = {
      --- Start new Git-backed agents in an isolated worktree so their changes can be reviewed.
      enabled = true,
    },
    agent_picker = {
      provider = "auto", ---@type "auto"|"snacks"|"native"
      preview_lines = 80,
      preview_bytes = 64 * 1024,
      preserve_pinned = true,
    },
    ---@class sidekick.win.Opts
    win = {
      --- This is run when a new terminal is created, before starting it.
      --- Here you can change window options `terminal.opts`.
      ---@param terminal sidekick.cli.Terminal
      config = function(terminal) end,
      wo = {}, ---@type vim.wo
      bo = {}, ---@type vim.bo
      layout = "right", ---@type "float"|"left"|"bottom"|"top"|"right"
      --- Options used when layout is "float"
      ---@type vim.api.keyset.win_config
      float = {
        width = 0.9,
        height = 0.9,
        border = "rounded",
      },
      -- Options used when layout is "left"|"bottom"|"top"|"right"
      ---@type vim.api.keyset.win_config
      split = {
        width = 80, -- set to 0 for default split width
        height = 20, -- set to 0 for default split height
      },
      --- Agent tabs shown in the shared Sidekick container. The renderer is
      --- standalone, but links to bufferline.nvim highlights when available.
      tabs = {
        enabled = true,
        max_name_length = 28,
        show_close = true,
        show_status = true, -- show the agent activity icon
        show_attention = true, -- show an unread output marker
        show_cwd = false, -- include the agent working directory in the title
        ---@type "thin"|"thick"|"slant"|"slope"|"padded_slant"|"padded_slope"|{left:string,right:string}
        separator_style = "thin",
        --- Set per-tool brand icons here. They are used throughout the CLI UI.
        --- Unconfigured tools use their name in tabs and omit the icon in pickers.
        --- Do not include surrounding whitespace; renderers add their own spacing.
        icons = {
          antigravity = "󱚣",
          claude = "󰚩",
          codex = "󱠡",
          copilot = "",
          crush = "󰛡",
          cursor = "󰅴",
          grok = "󱚥",
          opencode = "󰄛",
          pi = "󰠭",
          qwen = "󱚠",
        }, ---@type table<string, string>
        status = { ---@type table<sidekick.cli.ActivityStatus, string>
          idle = "○",
          starting = "◌",
          working = "●",
          waiting = "◐",
          done = "✓",
          error = "!",
        },
      },
      --- CLI Tool Keymaps (default mode is `t`)
      ---@type table<string, sidekick.cli.Keymap|false>
      -- stylua: ignore
      keys = {
        buffers       = { "<c-b>", "buffers"   , mode = "nt", desc = "open buffer picker" },
        files         = { "<c-f>", "files"     , mode = "nt", desc = "open file picker" },
        hide_n        = { "q"    , "hide"      , mode = "n" , desc = "hide the agent container" },
        hide_ctrl_q   = { "<c-q>", "hide"      , mode = "n" , desc = "hide the agent container" },
        hide_ctrl_dot = { "<c-.>", "hide"      , mode = "nt", desc = "hide the agent container" },
        hide_ctrl_z   = { "<c-z>", "blur"      , mode = "nt", desc = "go back to the previous window without hiding the agent container" },
        prompt        = { "<c-p>", "prompt"    , mode = "t" , desc = "insert prompt or context" },
        agent_fork_t  = { "<a-f>", "fork"       , mode = "t" , desc = "fork the current agent conversation" },
        stopinsert    = { "<c-q>", "stopinsert", mode = "t" , desc = "enter normal mode" },
        normal_cr     = { "<cr>" , "insert_cr" , mode = "n" , desc = "send <cr> to the terminal and enter normal mode" },
        agent_prev    = { "<s-h>"       , "prev"            , mode = "n", desc = "previous agent" },
        agent_prev_b  = { "[b"          , "prev"            , mode = "n", desc = "previous agent" },
        agent_next    = { "<s-l>"       , "next"            , mode = "n", desc = "next agent" },
        agent_next_b  = { "]b"          , "next"            , mode = "n", desc = "next agent" },
        agent_move_l  = { "[B"          , "move_prev"       , mode = "n", desc = "move agent tab left" },
        agent_move_r  = { "]B"          , "move_next"       , mode = "n", desc = "move agent tab right" },
        agent_pick    = { "<leader>bj"  , "pick"            , mode = "n", desc = "pick an agent" },
        agent_fork    = { "<leader>bf"  , "fork"            , mode = "n", desc = "fork the current agent conversation" },
        agent_back    = { "<leader>bb"  , "previous"        , mode = "n", desc = "previously active agent" },
        agent_back_bt = { "<leader>`"   , "previous"        , mode = "n", desc = "previously active agent" },
        agent_pin     = { "<leader>bp"  , "pin"             , mode = "n", desc = "pin agent" },
        agent_close   = { "<leader>bd"  , "close_current"   , mode = "n", desc = "close agent" },
        agent_others  = { "<leader>bo"  , "close_others"    , mode = "n", desc = "close other agents" },
        agent_left    = { "<leader>bl"  , "close_left"      , mode = "n", desc = "close agents to the left" },
        agent_right   = { "<leader>br"  , "close_right"     , mode = "n", desc = "close agents to the right" },
        agent_unused  = { "<leader>bP"  , "close_unpinned"  , mode = "n", desc = "close unpinned agents" },
        agent_hidden  = { "<leader>bi"  , "close_invisible" , mode = "n", desc = "close agents not in this native tab" },
        agent_delete  = { "<leader>bD"  , "close_panel"     , mode = "n", desc = "close agent and container" },
        panel_narrow  = { "<m-left>"    , "panel_narrow"    , mode = "n", desc = "make agent container narrower" },
        panel_widen   = { "<m-right>"   , "panel_widen"     , mode = "n", desc = "make agent container wider" },
        panel_shorter = { "<m-down>"    , "panel_shorter"   , mode = "n", desc = "make agent container shorter" },
        panel_taller  = { "<m-up>"      , "panel_taller"    , mode = "n", desc = "make agent container taller" },
        -- Navigate windows in terminal mode. Only active when:
        -- * layout is not "float"
        -- * there is another window in the direction
        -- With the default layout of "right", only `<c-h>` will be mapped
        nav_left      = { "<c-h>", "nav_left"  , expr = true, desc = "navigate to the left window" },
        nav_down      = { "<c-j>", "nav_down"  , expr = true, desc = "navigate to the below window" },
        nav_up        = { "<c-k>", "nav_up"    , expr = true, desc = "navigate to the above window" },
        nav_right     = { "<c-l>", "nav_right" , expr = true, desc = "navigate to the right window" },
      },
      ---@type fun(dir:"h"|"j"|"k"|"l")?
      --- Function that handles navigation between windows.
      --- Defaults to `vim.cmd.wincmd`. Used by the `nav_*` keymaps.
      nav = nil,
    },
    ---@class sidekick.cli.Mux
    ---@field backend? "tmux"|"zellij" Multiplexer backend to persist CLI sessions
    mux = {
      backend = vim.env.ZELLIJ and "zellij" or "tmux", -- default to tmux unless zellij is detected
      enabled = false,
      -- terminal: new sessions will be created for each CLI tool and shown in a Neovim terminal
      -- window: when run inside a terminal multiplexer, new sessions will be created in a new tab
      -- split: when run inside a terminal multiplexer, new sessions will be created in a new split
      -- NOTE: zellij only supports `terminal`
      create = "terminal", ---@type "terminal"|"window"|"split"
      split = {
        vertical = true, -- vertical or horizontal split
        size = 0.5, -- size of the split (0-1 for percentage)
      },
      -- max lines to capture when dumping a multiplexer pane for scrollback support
      -- more lines means slower loading of the scrollback
      dump = 2000,
    },
    --- Actual cli tool config is loaded from the runtime path `sk/cli/{tool}.lua` and merged with the config below.
    --- For default configs, see https://github.com/folke/sidekick.nvim/tree/main/sk/cli
    -- stylua: ignore
    ---@type table<string, sidekick.cli.Config|{}>
    tools = {
      antigravity = {},
      claude      = {},
      codex       = {},
      copilot     = {},
      crush       = {},
      cursor      = {},
      grok        = {},
      opencode    = {},
      pi          = {},
      qwen        = {},
    },
    --- Add custom context. See `lua/sidekick/context/init.lua`
    ---@type table<string, sidekick.context.Fn>
    context = {},
    -- stylua: ignore
    ---@type table<string, sidekick.Prompt|string|fun(ctx:sidekick.context.ctx):(string?)>
    prompts = {
      review_changes  = "Review the following Git changes for correctness, regressions, and missing tests.\n\n{git_diff}",
      diagnostics     = "Can you help me fix the diagnostics in {file}?\n{diagnostics}",
      diagnostics_all = "Can you help me fix these diagnostics?\n{diagnostics_all}",
      document        = "Add documentation to {function|line}",
      explain         = "Explain {this}",
      fix             = "Can you fix {this}?",
      optimize        = "How can {this} be optimized?",
      review          = "Can you review {file} for any issues or improvements?",
      tests           = "Can you write tests for {this}?",
      -- simple context prompts
      buffers         = "{buffers}",
      file            = "{file}",
      git_diff        = "{git_diff}",
      git_status      = "{git_status}",
      line            = "{line}",
      position        = "{position}",
      quickfix        = "{quickfix}",
      selection       = "{selection}",
      ["function"]    = "{function}",
      class           = "{class}",
      treesitter_scope = "{treesitter_scope}",
    },
    -- preferred picker for selecting files
    ---@alias sidekick.picker "snacks"|"telescope"|"fzf-lua"
    picker = "snacks", ---@type sidekick.picker
  },
  copilot = {
    -- track copilot's status with `didChangeStatus`
    status = {
      enabled = true,
      level = vim.log.levels.WARN,
      -- set to vim.log.levels.OFF to disable notifications
      -- level = vim.log.levels.OFF,
    },
  },
  ui = {
    -- stylua: ignore
    icons = {
      nes               = " ",
      attached          = " ",
      started           = " ",
      installed         = " ",
      missing           = " ",
      external_attached = "󰖩 ",
      external_started  = "󰖪 ",
      terminal_attached = " ",
      terminal_started  = " ",
      unread            = "• ",
      fork              = "↗ ",
      pin               = "󰐃 ",
      close             = " ",
    },
  },
  debug = false, -- enable debug logging
}

local state_dir = vim.fn.stdpath("state") .. "/sidekick"

local config = vim.deepcopy(defaults) --[[@as sidekick.Config]]
M.augroup = vim.api.nvim_create_augroup("sidekick", { clear = true })

---@param name string
function M.state(name)
  return state_dir .. "/" .. name
end

---@param opts? sidekick.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", {}, vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("Sidekick", function(args)
    require("sidekick.commands").cmd(args)
  end, {
    range = true,
    nargs = "?",
    desc = "Sidekick",
    complete = function(_, line)
      return require("sidekick.commands").complete(line)
    end,
  })

  vim.fn.mkdir(state_dir, "p")
  require("sidekick.cli.workspace").setup()

  vim.schedule(function()
    M.set_hl()

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = M.augroup,
      callback = M.set_hl,
    })

    -- Track when a window was last focused
    vim.api.nvim_create_autocmd({ "WinEnter" }, {
      group = M.augroup,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        vim.w[win].sidekick_visit = vim.uv.hrtime()
      end,
    })

    if M.nes.enabled ~= false then
      require("sidekick.nes").enable()
    end

    require("sidekick.status").setup()

    M.validate("cli.win.layout", { "float", "left", "bottom", "top", "right" })
    M.validate("cli.status.quiet_ms", "number")
    M.validate("cli.agent_picker.provider", { "auto", "snacks", "native" })
    M.validate("cli.agent_picker.preview_lines", "number")
    M.validate("cli.agent_picker.preview_bytes", "number")
    M.validate("cli.workspace.resume_timeout_ms", "number")
    M.validate("cli.mux.backend", { "tmux", "zellij" })
    M.validate("cli.mux.create", { "terminal", "window", "split" })
    M.validate("nes.diff.show", { "always", "cursor" })
  end)
end

---@param key string
---@param t "string"|"number"|"boolean"|"table"|"function"|any[]
function M.validate(key, t)
  local value = vim.tbl_get(config, unpack(vim.split(key, "%.")))
  local err ---@type string?
  if type(t) == "table" then
    if not vim.tbl_contains(t, value) then
      err = ("Invalid value for option `opts.%s`\n- found: `%s`\n- expected: `%s`"):format(
        key,
        tostring(value),
        table.concat(vim.tbl_map(tostring, t), " | ")
      )
    end
  elseif type(value) ~= t then
    err = ("Expected `opts.%s` to be a `%s`, got `%s`"):format(key, t, type(value))
  end
  if err then
    require("sidekick.util").error(err)
    return false
  end
  return true
end

---@param client vim.lsp.Client|string
function M.is_copilot(client)
  local name = type(client) == "table" and client.name or client --[[@as string]]
  return name and name:lower():find("copilot")
end

---@param filter? vim.lsp.get_clients.Filter
---@return vim.lsp.Client[]
function M.get_clients(filter)
  return vim.tbl_filter(M.is_copilot, vim.lsp.get_clients(filter))
end

---@param buf? number
function M.get_client(buf)
  return M.get_clients({ bufnr = buf or 0 })[1]
end

---@param name string
function M.get_tool(name)
  return require("sidekick.cli.tool").get(name)
end

function M.tools()
  local ret = {} ---@type table<string, sidekick.cli.Tool>
  for name in pairs(M.cli.tools) do
    ret[name] = M.get_tool(name)
  end
  return ret
end

function M.set_hl()
  local function available(name, fallback)
    return vim.fn.hlexists(name) == 1 and name or fallback
  end
  local function available_surface(name, fallback)
    local attrs = vim.api.nvim_get_hl(0, { name = name, link = false })
    if attrs.bg or attrs.ctermbg then
      return name
    end
    return fallback
  end
  local function with_background(name, source, background)
    local attrs = vim.api.nvim_get_hl(0, { name = source, link = false })
    local surface = vim.api.nvim_get_hl(0, { name = background, link = false })
    for key, value in pairs(surface) do
      if key ~= "fg" and key ~= "ctermfg" and key ~= "default" then
        attrs[key] = value
      end
    end
    attrs.bg = surface.bg or "NONE"
    attrs.ctermbg = surface.ctermbg or "NONE"

    local current = vim.api.nvim_get_hl(0, { name = name, link = false })
    local state = derived_highlights[name]
    local custom = state and state.custom or false
    if next(current) == nil then
      if custom then
        vim.api.nvim_set_hl(0, name, state.attrs)
        current = vim.api.nvim_get_hl(0, { name = name, link = false })
      else
        custom = false
      end
    elseif not custom and state and not vim.deep_equal(current, state.attrs) then
      custom = true
    elseif not state and vim.fn.hlexists(name) == 1 and next(current) ~= nil then
      custom = true
    end
    if not custom then
      vim.api.nvim_set_hl(0, name, attrs)
      current = vim.api.nvim_get_hl(0, { name = name, link = false })
    end
    derived_highlights[name] = { attrs = vim.deepcopy(current), custom = custom }
  end
  local links = {
    DiffContext = available_surface("CursorLine", "DiffChange"),
    DiffAdd = "DiffText",
    DiffDelete = "DiffDelete",
    Sign = "Special",
    NesSummary = "Special",
    NesSummaryIcon = "Special",
    NesSummaryCount = "Title",
    NesSummaryMeta = "Comment",
    NesSign = "Special",
    NesSignAdd = "DiffAdd",
    NesSignChange = "DiffChange",
    NesSignDelete = "DiffDelete",
    Chat = "NormalFloat",
    FloatBorder = available("FloatBorder", "WinSeparator"),
    FloatTitle = available("FloatTitle", "Title"),
    CliMissing = "DiagnosticError",
    CliAttached = "Special",
    CliStarted = "DiagnosticWarn",
    CliInstalled = "DiagnosticOk",
    CliUnavailable = "DiagnosticError",
    CliStatusIdle = "Comment",
    CliStatusStarting = "DiagnosticInfo",
    CliStatusWorking = "DiagnosticOk",
    CliStatusWaiting = "DiagnosticHint",
    CliStatusDone = "DiagnosticOk",
    CliStatusError = "DiagnosticError",
    CliAttention = "DiagnosticInfo",
    CliTitle = "Comment",
    CliClose = "Comment",
    CliPin = "Special",
    CliTool = "Special",
    CliToolAntigravity = "Special",
    CliToolClaude = "Constant",
    CliToolCodex = "String",
    CliToolCopilot = "Statement",
    CliToolCrush = "Type",
    CliToolCursor = "Function",
    CliToolGrok = "Keyword",
    CliToolOpencode = "PreProc",
    CliToolPi = "Number",
    CliToolQwen = "Label",
    LocDelim = "Delimiter",
    LocFile = "@markup.link",
    LocNum = "@attribute",
    LocRow = "SidekickLocDelim",
    LocCol = "SidekickLocDelim",
  }
  for from, to in pairs(links) do
    vim.api.nvim_set_hl(0, "Sidekick" .. from, { link = to, default = true })
  end
  local tabs = {
    CliTab = available("BufferLineBackground", "TabLine"),
    CliTabSelected = available("BufferLineBufferSelected", "TabLineSel"),
    CliTabSeparator = available("BufferLineSeparator", "TabLineFill"),
  }
  for from, to in pairs(tabs) do
    local bufferline = to:find("^BufferLine") ~= nil
    vim.api.nvim_set_hl(0, "Sidekick" .. from, { link = to, default = not bufferline })
  end

  -- Keep semantic tab decorations on the same surface as their tab. The
  -- original groups remain foreground-only for pickers and other contexts.
  for from in pairs(links) do
    local decoration = from:match("^Cli(.+)$")
    if decoration then
      local source = "SidekickCli" .. decoration
      with_background("SidekickCliTab" .. decoration, source, "SidekickCliTab")
      with_background("SidekickCliTabSelected" .. decoration, source, "SidekickCliTabSelected")
    end
  end
end

setmetatable(M, {
  __index = function(_, key)
    return config[key]
  end,
})

return M
