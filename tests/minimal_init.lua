local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = os.getenv "PLENARY_DIR" or vim.fn.expand "~/.local/share/nvim/lazy/plenary.nvim"

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
package.path = root .. "/?.lua;" .. package.path
vim.o.swapfile = false
-- keep the user's remembered AI picks out of the specs
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.cmd "runtime! plugin/plenary.vim"
