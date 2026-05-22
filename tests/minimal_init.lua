-- Minimal nvim init for running plenary tests headlessly.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
local plugin_path  = vim.fn.getcwd()

vim.opt.rtp:prepend(plenary_path)
vim.opt.rtp:prepend(plugin_path)

require("plenary")
