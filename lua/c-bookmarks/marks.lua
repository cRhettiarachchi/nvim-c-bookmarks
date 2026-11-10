---Extmarks keep bookmarks on their lines while a buffer is edited.
local Config = require "c-bookmarks.config"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"

local M = {}

M.ns = vim.api.nvim_create_namespace "c-bookmarks"

local SYNC_DELAY_MS = 200

---@type table<integer, table<string, integer>> bufnr -> bookmark id -> extmark id
local tracked = {}
---@type table<integer, uv.uv_timer_t>
local timers = {}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

---@param bufnr? integer
---@return integer
local function resolve(bufnr)
  if not bufnr or bufnr == 0 then return vim.api.nvim_get_current_buf() end

  return bufnr
end

---@param bufnr integer
---@return string? project-relative path of a file buffer
function M.buf_path(bufnr)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then return nil end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end

  return Store.relpath(vim.fs.normalize(name))
end

---One extmark spans the range so both ends track edits.
local function place(bufnr, bookmark)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local signs = Config.options.signs
  local opts = {
    end_row = math.min(bookmark.end_lnum, line_count),
    end_col = 0,
    hl_eol = true,
    priority = signs.priority,
    strict = false,
  }
  local range_hl = Config.options.highlights.range
  if range_hl then opts.hl_group = range_hl end
  if signs.enabled then
    opts.sign_text = bookmark.note ~= "" and signs.note or signs.mark
    opts.sign_hl_group = "CBookmarkSign"
  end

  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, math.min(bookmark.lnum, line_count) - 1, 0, opts)
end

---@return integer? lnum, integer? end_lnum
local function live_range(bufnr, mark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark_id, { details = true })
  if not mark or #mark == 0 then return nil end

  local lnum = mark[1] + 1
  local details = mark[3] or {}
  local end_lnum = lnum
  if details.end_row then
    -- end_col 0 means the range stops before end_row
    end_lnum = details.end_row + ((details.end_col or 0) > 0 and 1 or 0)
  end

  return lnum, math.max(end_lnum, lnum)
end

---Narrowest bookmark covering lnum, read from live extmarks without syncing.
---@param bufnr? integer
---@param lnum integer
---@return CBookmarks.Bookmark?
function M.bookmark_at(bufnr, lnum)
  bufnr = resolve(bufnr)
  local marks = tracked[bufnr]
  if not marks then return nil end

  local group = Model.active_group(Store.get())
  if not group then return nil end

  local ids = {}
  for id, mark_id in pairs(marks) do
    ids[mark_id] = id
  end

  local best, best_size
  local found = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { overlap = true })
  for _, mark in ipairs(found) do
    local bookmark = ids[mark[1]] and Model.find_bookmark(group, ids[mark[1]])
    local first, last = live_range(bufnr, mark[1])
    if bookmark and first and lnum >= first and lnum <= last then
      local size = last - first
      if not best or size < best_size then
        best, best_size = bookmark, size
      end
    end
  end

  return best
end

---Copies live extmark positions into the data.
---@param bufnr? integer
---@param opts? { persist?: boolean }
---@return boolean moved
function M.sync(bufnr, opts)
  bufnr = resolve(bufnr)
  local marks = tracked[bufnr]
  if not marks or not vim.api.nvim_buf_is_valid(bufnr) then return false end

  local group = Model.active_group(Store.get())
  if not group then return false end

  local changes = {}
  for id, mark_id in pairs(marks) do
    local bookmark = Model.find_bookmark(group, id)
    local lnum, end_lnum = live_range(bufnr, mark_id)
    if bookmark and lnum then
      local anchor = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      if bookmark.lnum ~= lnum or bookmark.end_lnum ~= end_lnum or bookmark.anchor ~= anchor then
        changes[#changes + 1] = { bookmark = bookmark, lnum = lnum, end_lnum = end_lnum, anchor = anchor }
      end
    end
  end

  if #changes == 0 then return false end

  Store.update(function()
    for _, change in ipairs(changes) do
      change.bookmark.lnum = change.lnum
      change.bookmark.end_lnum = change.end_lnum
      change.bookmark.anchor = change.anchor
      Model.touch(change.bookmark)
    end
  end, { persist = opts and opts.persist, source = "sync" })

  return true
end

---Places the active group's bookmarks for this buffer.
---@param bufnr? integer
---@param opts? { sync?: boolean } sync first so unsaved edits are not lost
function M.render(bufnr, opts)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not (opts and opts.sync == false) then M.sync(bufnr, { persist = false }) end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  tracked[bufnr] = nil

  local path = M.buf_path(bufnr)
  if not path or not vim.api.nvim_buf_is_loaded(bufnr) then return end

  local group = Model.active_group(Store.get())
  if not group then return end

  local marks = {}
  for _, bookmark in ipairs(Model.bookmarks_in(group, path)) do
    marks[bookmark.id] = place(bufnr, bookmark)
  end

  tracked[bufnr] = marks
end

---@param opts? { sync?: boolean }
function M.render_all(opts)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then M.render(bufnr, opts) end
  end
end

local function forget(bufnr)
  tracked[bufnr] = nil
  local timer = timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    timers[bufnr] = nil
  end
end

local function schedule_sync(bufnr)
  local timer = timers[bufnr]
  if not timer then
    timer = vim.uv.new_timer()
    timers[bufnr] = timer
  end

  timer:stop()
  timer:start(
    SYNC_DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then M.sync(bufnr, { persist = false }) end
    end)
  )
end

-- Editing -------------------------------------------------------------------

---Lines covered by the visual selection, else the cursor line.
---@return integer lnum, integer end_lnum
function M.selected_lines()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local first, last = vim.fn.line "v", vim.fn.line "."
    if first > last then
      first, last = last, first
    end

    vim.cmd.normal { "\27", bang = true }
    return first, last
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return lnum, lnum
end

---@param opts? { lnum?: integer, end_lnum?: integer, name?: string, note?: string, bufnr?: integer }
---@return CBookmarks.Bookmark?
function M.add(opts)
  opts = opts or {}
  local bufnr = resolve(opts.bufnr)
  local path = M.buf_path(bufnr)
  if not path then
    notify("this buffer has no file to bookmark", vim.log.levels.WARN)
    return nil
  end

  M.sync(bufnr, { persist = false })
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local end_lnum = opts.end_lnum or lnum
  local anchor = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

  return Store.update(function(data)
    local group = Model.active_group(data)
    if not group then
      local name = Config.options.default_group
      group = Model.find_group_by_name(data, name) or Model.add_group(data, name)
      data.active = group.id
    end

    return Model.add_bookmark(group, {
      path = path,
      lnum = lnum,
      end_lnum = end_lnum,
      name = opts.name,
      note = opts.note,
      anchor = anchor,
    })
  end)
end

---Adds the selection or cursor line after asking for an optional name.
function M.add_named()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, end_lnum = M.selected_lines()
  vim.ui.input({ prompt = "Bookmark name (optional): " }, function(name)
    if name == nil then return end

    M.add { bufnr = bufnr, lnum = lnum, end_lnum = end_lnum, name = name }
  end)
end

---@param bufnr? integer
---@return CBookmarks.Bookmark?
function M.at_cursor(bufnr)
  bufnr = resolve(bufnr)
  local path = M.buf_path(bufnr)
  if not path then return nil end

  M.sync(bufnr, { persist = false })
  local group = Model.active_group(Store.get())
  if not group then return nil end

  return Model.find_at(group, path, vim.api.nvim_win_get_cursor(0)[1])
end

---@param id string
---@return boolean removed
function M.remove(id)
  return Store.update(function(data)
    local group = Model.active_group(data)
    return group ~= nil and Model.remove_bookmark(group, id)
  end)
end

---@return boolean removed
function M.remove_at_cursor()
  local bookmark = M.at_cursor()
  if not bookmark then
    notify "no bookmark under the cursor"
    return false
  end

  return M.remove(bookmark.id)
end

---Removes the bookmark under the cursor, else adds one.
---@return CBookmarks.Bookmark? added
function M.toggle()
  local bookmark = M.at_cursor()
  if bookmark then
    M.remove(bookmark.id)
    return nil
  end

  local lnum, end_lnum = M.selected_lines()
  return M.add { lnum = lnum, end_lnum = end_lnum }
end

-- Setup ---------------------------------------------------------------------

function M.setup()
  local augroup = vim.api.nvim_create_augroup("CBookmarksMarks", { clear = true })
  local function autocmd(event, opts)
    opts.group = augroup
    vim.api.nvim_create_autocmd(event, opts)
  end

  autocmd("BufReadPost", { callback = function(ev) M.render(ev.buf, { sync = false }) end })
  autocmd({ "TextChanged", "TextChangedI" }, {
    callback = function(ev)
      if tracked[ev.buf] and next(tracked[ev.buf]) then schedule_sync(ev.buf) end
    end,
  })
  autocmd("BufWritePost", {
    callback = function(ev)
      M.sync(ev.buf, { persist = false })
      Store.flush()
    end,
  })
  autocmd("BufUnload", {
    callback = function(ev)
      -- discarded edits must not move bookmarks
      if not vim.bo[ev.buf].modified then M.sync(ev.buf, { persist = false }) end

      forget(ev.buf)
    end,
  })
  autocmd("BufWipeout", { callback = function(ev) forget(ev.buf) end })
  autocmd("VimLeavePre", {
    callback = function()
      for _, bufnr in ipairs(vim.tbl_keys(tracked)) do
        M.sync(bufnr, { persist = false })
      end

      Store.flush()
    end,
  })
  autocmd("User", {
    pattern = "CBookmarksChanged",
    callback = function(ev)
      local source = ev.data and ev.data.source
      if source == "sync" then return end

      -- an outside write is the truth; local edits keep live positions
      M.render_all { sync = source ~= "file" }
    end,
  })
  M.render_all { sync = false }
end

return M
