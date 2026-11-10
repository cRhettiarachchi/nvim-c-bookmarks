---Default highlight groups, overridable because they are `default` links.
local M = {}

local LINKS = {
  CBookmarkSign = "DiagnosticSignInfo",
  CBookmarkRange = "CursorLine",
  CBookmarkPanelTitle = "Title",
  CBookmarkPanelIndex = "LineNr",
  CBookmarkPanelLocation = "Comment",
  CBookmarkPanelFile = "Normal",
  CBookmarkPanelCurrent = "Visual",
  CBookmarkPanelHint = "Comment",
  CBookmarkHint = "Comment",
  CBookmarkPanelBusy = "DiagnosticInfo",
  CBookmarkAskBusy = "DiagnosticInfo",
}

function M.define()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

function M.setup()
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CBookmarksHighlights", { clear = true }),
    callback = M.define,
  })
end

return M
