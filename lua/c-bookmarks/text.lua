---Display-width helpers shared by the panel, the notes and the ask float.
local M = {}

---Cuts text to max display cells, ending with an ellipsis when cut.
---@param text string
---@param max integer
---@return string
function M.truncate(text, max)
  if max < 1 then return "" end
  if vim.fn.strdisplaywidth(text) <= max then return text end

  return vim.fn.strcharpart(text, 0, max - 1) .. "…"
end

return M
