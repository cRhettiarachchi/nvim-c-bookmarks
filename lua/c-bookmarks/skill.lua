---Ships the Claude Code skill and links it into the user's skills directory.
local Config = require "c-bookmarks.config"

local M = {}

M.NAME = "c-bookmarks"

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

---Root of this plugin checkout.
---@return string
function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(source, ":p:h:h:h"))
end

---@return string directory holding SKILL.md
function M.source_dir() return vim.fs.joinpath(M.plugin_root(), "skills", M.NAME) end

---@return string
function M.path() return vim.fs.joinpath(M.source_dir(), "SKILL.md") end

---@param opts? { dir?: string } skills directory, default from config
---@return string link path
function M.target(opts)
  local dir = opts and opts.dir or Config.options.ai.skills_dir
  return vim.fs.joinpath(vim.fs.normalize(dir), M.NAME)
end

---@param opts? { dir?: string }
---@return "linked"|"missing"|"foreign"
function M.status(opts)
  local target = M.target(opts)
  if not vim.uv.fs_lstat(target) then return "missing" end

  local real = vim.uv.fs_realpath(target)
  if real and real == vim.uv.fs_realpath(M.source_dir()) then return "linked" end

  return "foreign"
end

---Symlinks the skill so Claude Code loads it in every project.
---@param opts? { dir?: string }
---@return boolean installed
function M.install(opts)
  local target = M.target(opts)
  local status = M.status(opts)
  if status == "linked" then
    notify("skill already linked at " .. target)
    return true
  end

  if status == "foreign" then
    notify("something else is at " .. target .. ", remove it first", vim.log.levels.WARN)
    return false
  end

  vim.fn.mkdir(vim.fs.dirname(target), "p")
  local ok, err = vim.uv.fs_symlink(M.source_dir(), target, { dir = true })
  if not ok then
    notify("could not link the skill: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  notify("skill linked at " .. target)
  return true
end

---Removes the link, never a foreign directory.
---@param opts? { dir?: string }
---@return boolean removed
function M.uninstall(opts)
  local target = M.target(opts)
  local status = M.status(opts)
  if status == "missing" then
    notify "skill is not installed"
    return false
  end

  if status == "foreign" then
    notify(target .. " was not created by this plugin, leaving it alone", vim.log.levels.WARN)
    return false
  end

  local ok, err = vim.uv.fs_unlink(target)
  if not ok then
    notify("could not remove the link: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  notify("skill unlinked from " .. target)
  return true
end

---Reports where the skill is and whether it is linked.
function M.report() notify(string.format("skill %s (%s)\nsource: %s", M.status(), M.target(), M.path())) end

return M
