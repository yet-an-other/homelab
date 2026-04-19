vim.opt.clipboard = "unnamedplus"

local map = vim.keymap.set
local opts = { noremap = true, silent = true }

map({ "v", "x" }, "<D-c>", '"+y', opts)
map({ "v", "x" }, "<D-x>", '"+x', opts)
map("n", "<D-c>", '"+yy', opts)
map("n", "<D-x>", '"+dd', opts)

map("n", "<D-v>", '"+p', opts)
map({ "v", "x" }, "<D-v>", '"+P', opts)
map({ "i", "c" }, "<D-v>", '<C-r>+', opts)
map("t", "<D-v>", [[<C-\><C-n>"+pi]], opts)

map("n", "<D-z>", "u", opts)
map("i", "<D-z>", "<Esc>ui", opts)
map({ "v", "x" }, "<D-z>", "<Esc>u", opts)

map("n", "<D-Z>", "<C-r>", opts)
map("i", "<D-Z>", "<Esc><C-r>i", opts)
map({ "v", "x" }, "<D-Z>", "<Esc><C-r>", opts)
