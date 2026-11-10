if vim.g.loaded_c_bookmarks then return end

vim.g.loaded_c_bookmarks = true

vim.api.nvim_create_user_command("CBookmarks", function(cmd) require("c-bookmarks.commands").run(cmd) end, {
  nargs = "*",
  range = true,
  desc = "Project bookmarks",
  complete = function(arg_lead, cmdline) return require("c-bookmarks.commands").complete(arg_lead, cmdline) end,
})
