---Spinner state for background runs, shared by the panel and status lines.
local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL_MS = 80

---@class CBookmarks.Job
---@field request string
---@field provider string
---@field verb string "explaining" or "asking"
---@field started integer

---@type table<integer, CBookmarks.Job>
local jobs = {}
local frame = 1
local timer = nil ---@type uv.uv_timer_t?

local function emit()
  vim.api.nvim_exec_autocmds("User", { pattern = "CBookmarksProgress", modeline = false })
  vim.cmd.redrawstatus()
end

local function tick()
  frame = frame % #FRAMES + 1
  emit()
end

local function ensure_timer()
  if timer then return end

  timer = vim.uv.new_timer()
  timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(tick))
end

local function stop_timer()
  if not timer then return end

  timer:stop()
  timer:close()
  timer = nil
end

---@param id integer
---@param info { request: string, provider: string, verb?: string }
function M.start(id, info)
  jobs[id] = {
    request = info.request,
    provider = info.provider,
    verb = info.verb or "explaining",
    started = vim.uv.hrtime(),
  }
  ensure_timer()
  emit()
end

---@param id integer
function M.stop(id)
  jobs[id] = nil
  if next(jobs) == nil then stop_timer() end

  emit()
end

---@return integer
function M.count() return vim.tbl_count(jobs) end

---Oldest running job, if any.
---@return CBookmarks.Job?
function M.current()
  local oldest
  for _, job in pairs(jobs) do
    if not oldest or job.started < oldest.started then oldest = job end
  end

  return oldest
end

---One line for a status line or a panel header, nil when idle.
---@param id? integer a specific job instead of the oldest
---@return string?
function M.status(id)
  local job = id and jobs[id] or M.current()
  if not job then return nil end

  local elapsed = math.floor((vim.uv.hrtime() - job.started) / 1e9)
  local text = string.format("%s %s with %s · %ds", FRAMES[frame], job.verb, job.provider, elapsed)
  local count = M.count()
  if not id and count > 1 then text = text .. string.format(" · %d running", count) end

  return text
end

---Forgets every job. Tests use it.
function M.reset()
  jobs = {}
  stop_timer()
end

return M
