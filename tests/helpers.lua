local M = {}

---Creates a throwaway git repo and points the plugin at it.
---@return string dir
function M.project()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.system({ "git", "init", "-q", dir }):wait()
  require("c-bookmarks.config").setup { storage = { root = function() return dir end } }
  require("c-bookmarks.store").reset()
  return dir
end

function M.write(dir, relative, lines)
  local path = vim.fs.joinpath(dir, relative)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

function M.read(path)
  local fd = assert(io.open(path, "r"))
  local text = fd:read "*a"
  fd:close()
  return text
end

function M.cleanup(dir) vim.fn.delete(dir, "rf") end

return M
