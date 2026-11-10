---Choices that outlive the session, kept under stdpath("state").
local Config = require "c-bookmarks.config"

local M = {}

---@return string
function M.path()
  return Config.options.ai.state_file or vim.fs.joinpath(vim.fn.stdpath "state", "c-bookmarks", "ai.json")
end

---@return table
function M.load()
  local fd = io.open(M.path(), "r")
  if not fd then return {} end

  local text = fd:read "*a"
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return (ok and type(data) == "table") and data or {}
end

---@param data table
function M.save(data)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if not fd then return false end

  fd:write(vim.json.encode(data), "\n")
  fd:close()
  return true
end

---@param key string
---@return any
function M.get(key) return M.load()[key] end

---@param key string
---@param value any nil removes the key
function M.set(key, value)
  local data = M.load()
  data[key] = value
  return M.save(data)
end

return M
