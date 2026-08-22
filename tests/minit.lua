#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = ".tests"
vim.env.LAZY_PATH = vim.fs.normalize("~/projects/lazy.nvim")

if vim.fn.isdirectory(vim.env.LAZY_PATH) == 1 then
  loadfile(vim.env.LAZY_PATH .. "/bootstrap.lua")()
else
  load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"), "bootstrap.lua")()
end

-- nvim-treesitter main uses vim.list.unique while this plugin still supports
-- Neovim 0.11, where the vim.list namespace is unavailable.
vim.list = vim.list or {}
vim.list.unique = vim.list.unique
  or function(items)
    local seen, ret = {}, {}
    for _, item in ipairs(items) do
      if not seen[item] then
        seen[item] = true
        ret[#ret + 1] = item
      end
    end
    return ret
  end

-- Setup lazy.nvim
require("lazy.minit").setup({
  spec = {
    {
      dir = vim.uv.cwd(),
      opts = {},
    },
    { "nvim-treesitter/nvim-treesitter-textobjects", branch = "main" },
    { "folke/snacks.nvim" },
    {
      "nvim-treesitter/nvim-treesitter",
      branch = "main",
      build = ":TSUpdate",
      config = function()
        local TS = require("nvim-treesitter")
        TS.setup({})
        TS.install({ "python", "rust", "javascript", "typescript", "go", "lua" }, { summary = true }):wait()
      end,
    },
  },
})

-- TODO: check why this is needed
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
