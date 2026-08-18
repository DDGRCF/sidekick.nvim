local keymaps = {
  claude = {
    ["<Esc><Esc>"] = "Rewind the code and conversation to a previous checkpoint",
    ["<Tab>"] = "Toggle extended thinking mode On/Off",
    ["<S-Tab>"] = "Toggle permission mode (cycle Auto-Accept, Plan, normal mode)",
    ["<Up>"] = "Recall previous command from history",
    ["<Down>"] = "Recall next command from history",
    ["<C-c>"] = "Cancel the current generation (interrupt Claude)",
    ["<C-d>"] = "Exit the Claude CLI session (EOF)",
    ["<C-l>"] = "Clear the terminal screen (history is retained)",
    ["<C-r>"] = "Search backward through command history",
  },
  codex = {
    ["<CR>"] = "Submit the prompt (send message to Codex)",
    ["<C-j>"] = "Insert a newline in the prompt without sending",
    ["<Up>"] = "Navigate to previous input in history",
    ["<Down>"] = "Navigate to next input in history",
    ["<C-h>"] = "Delete the character to the left (Backspace)",
    ["<C-b>"] = "Move cursor one character to the left",
    ["<C-f>"] = "Move cursor one character to the right",
    ["<C-a>"] = "Move cursor to the beginning of the line",
    ["<C-e>"] = "Move cursor to the end of the line",
    ["<C-d>"] = "Exit the Codex CLI (if input is empty) or delete char under cursor",
    ["<C-c>"] = "Cancel the current AI response",
    ["<C-l>"] = "Clear the screen (conversation state persists)",
    ["<C-r>"] = "Reverse-search through previous prompts/commands",
    ["<Tab>"] = "Auto-complete file paths or commands",
    ["<C-t>"] = "Toggle response detail level (switch between concise and detailed mode)",
  },
  copilot = {
    ["<Up>"] = "Move selection up (navigate through suggestion options)",
    ["<Down>"] = "Move selection down (navigate through suggestion options)",
    ["<CR>"] = "Confirm selection (execute chosen suggestion or action)",
    ["<Esc>"] = "Cancel the current Copilot CLI prompt or suggestion",
  },
  crush = {
    ["<C-p>"] = "Open the command palette (show available commands and actions)",
    ["<C-g>"] = "Focus the chat input (return focus to prompt)",
    ["<C-s>"] = "Open session management (list or switch sessions)",
    ["<C-f>"] = "Attach a file to the conversation context",
    ["<C-o>"] = "Open the current file or snippet in your editor",
    ["<C-c>"] = "Exit Crush (quit the CLI)",
    ["<Tab>"] = "Trigger auto-completion for paths or commands",
  },
  cursor = {
    ["<C-r>"] = "Preview the proposed changes or plan (toggle preview mode)",
    ["i"] = "Insert a follow-up message (exit preview or file navigation to type input)",
    ["<Up>"] = "Move up in the file list or suggestion list",
    ["<Down>"] = "Move down in the file list or suggestion list",
    ["<Esc>"] = "Close the current dialog or exit shell/tool mode back to chat",
    ["<C-c>"] = "Interrupt the current operation or generation",
    ["<C-d>"] = "Exit the Cursor CLI (if pressed on empty prompt, acts as EOF)",
  },
  grok = {
    ["<Up>"] = "Recall the previous prompt from history",
    ["<Down>"] = "Recall the next prompt from history",
    ["<C-c>"] = "Cancel the current query or exit Grok Build CLI",
  },
  opencode = {
    ["<C-x>"] = "Leader key for multi-key shortcuts (press before other keys)",
    ["<C-x>h"] = "Show the help menu (list available commands and keybinds)",
    ["<C-c>"] = "Interrupt generation or clear current input (press at empty prompt to exit)",
    ["<C-x>q"] = "Quit OpenCode (exit the CLI)",
    ["<C-x>e"] = "Open an external editor for the next message input",
    ["<C-x>t"] = "Open theme selector (choose a visual theme)",
    ["<C-x>i"] = "Initialize project (set up OpenCode in current directory)",
    ["<C-x>d"] = "Show details for available tools",
    ["<C-x>b"] = "Toggle display of AI thinking process (reasoning blocks)",
    ["<C-x>x"] = "Export the current session state to a file",
    ["<C-x>n"] = "Start a new chat session",
    ["<C-x>l"] = "List all sessions",
    ["<C-x>s"] = "Share the current session (generate sharable link or ID)",
    ["<Esc>"] = "Stop the current response (interrupt OpenCode's output)",
    ["<C-x>c"] = "Compact the session (reduce context size by summarizing)",
    ["<C-Right>"] = "Switch to the next child session or branch",
    ["<C-Left>"] = "Switch to the previous child session or branch",
    ["<PageUp>"] = "Scroll up one page in the conversation history",
    ["<PageDown>"] = "Scroll down one page in the conversation history",
    ["<C-M-u>"] = "Scroll up by half a page in history",
    ["<C-M-d>"] = "Scroll down by half a page in history",
    ["<C-g>"] = "Jump to the first message in the conversation",
    ["<C-M-g>"] = "Jump to the latest message in the conversation",
    ["<C-x>y"] = "Copy the last assistant reply to clipboard",
    ["<C-x>u"] = "Undo the last automated code edit",
    ["<C-x>r"] = "Redo an undone code edit",
    ["<C-x>m"] = "Open the model selection menu",
    ["<F2>"] = "Switch to the most recent model used",
    ["<S-F2>"] = "Switch to the previous model in use",
    ["<C-x>a"] = "Open the agent selection menu (if multiple agents are available)",
    ["<Tab>"] = "Cycle to the next active agent",
    ["<S-Tab>"] = "Cycle to the previous active agent",
    ["<C-v>"] = "Paste from clipboard into the input",
    ["<CR>"] = "Submit the current input message",
    ["<S-CR>"] = "Insert a newline in the input (when multiline mode is off)",
  },
}

local all = {} ---@type table<string, string>
for _, km in pairs(keymaps) do
  for k, v in pairs(km) do
    all[k] = v
  end
end

local sorted = vim.tbl_keys(all)
table.sort(sorted)
print(table.concat(sorted, "\n"))

return keymaps
