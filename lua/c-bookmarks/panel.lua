---Side window listing the active group in its explicit order.
local Config = require "c-bookmarks.config"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Notes = require "c-bookmarks.notes"
local Progress = require "c-bookmarks.ai.progress"
local Store = require "c-bookmarks.store"
local Text = require "c-bookmarks.text"

local M = {}

M.ns = vim.api.nvim_create_namespace "c-bookmarks-panel"
M.current_ns = vim.api.nvim_create_namespace "c-bookmarks-panel-current"

-- room a note needs before it is worth drawing
local MIN_NOTE_WIDTH = 4

local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = true,
  wrap = false,
  winfixwidth = true,
  list = false,
  spell = false,
  statuscolumn = "",
  colorcolumn = "",
}

local state = {
  win = nil, ---@type integer?
  buf = nil, ---@type integer?
  ids = {}, ---@type (string|false)[] bookmark id per line, false on header lines
  last_win = nil, ---@type integer? window that jumps land in
  current = nil, ---@type string? bookmark the editor cursor is in
}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

local function explain() return require "c-bookmarks.ai.explain" end

function M.is_open() return state.win ~= nil and vim.api.nvim_win_is_valid(state.win) end

---@return integer?
function M.win() return M.is_open() and state.win or nil end

---@return integer?
function M.buf() return state.buf end

---@return string? id of the bookmark under the panel cursor
function M.id_at_cursor()
  if not M.is_open() then return nil end

  return state.ids[vim.api.nvim_win_get_cursor(state.win)[1]] or nil
end

---@param id string?
---@return CBookmarks.Bookmark?
local function bookmark_for(id)
  local group = Groups.active()
  if not group or not id then return nil end

  return (Model.find_bookmark(group, id))
end

-- Rendering -----------------------------------------------------------------

---@param bookmark CBookmarks.Bookmark
---@return string
local function lines_suffix(bookmark)
  local suffix = ":" .. bookmark.lnum
  if bookmark.end_lnum > bookmark.lnum then suffix = suffix .. "-" .. bookmark.end_lnum end

  return suffix
end

---File name and lines, the name cut first and the lines dropped last.
---@param bookmark CBookmarks.Bookmark
---@param room integer display cells available
---@return string name, string suffix
local function where(bookmark, room)
  local name = vim.fs.basename(bookmark.path)
  local suffix = lines_suffix(bookmark)
  if vim.fn.strdisplaywidth(name .. suffix) <= room then return name, suffix end

  local name_room = room - vim.fn.strdisplaywidth(suffix)
  if name_room >= 2 then return Text.truncate(name, name_room), suffix end

  return Text.truncate(name, room), ""
end

---The name, else the first note line; nothing for a bare bookmark.
---@param bookmark CBookmarks.Bookmark
---@return string
local function caption(bookmark)
  if bookmark.name ~= "" then return bookmark.name end

  return Notes.first_line(bookmark.note)
end

---@param group CBookmarks.Group?
---@param width integer
---@return string[] lines, (string|false)[] ids, table[] marks
local function build(group, width)
  local lines, ids, marks = {}, {}, {}
  local signs = Config.options.signs

  local function plain(text, hl_group)
    lines[#lines + 1] = text
    ids[#lines] = false
    marks[#marks + 1] = { row = #lines - 1, col = 0, opts = { line_hl_group = hl_group } }
  end

  local busy = Progress.status()
  if busy then
    plain(" " .. busy, "CBookmarkPanelBusy")
    local job = Progress.current()
    if job then plain("   " .. Text.truncate(job.request, width - 4), "CBookmarkPanelHint") end
  end

  if not group then
    plain("  no groups yet", "CBookmarkPanelHint")
    return lines, ids, marks
  end

  local data = Store.get()
  local _, index = Model.find_group(data, group.id)
  plain(string.format(" %s %s (%d)", signs.mark, group.name, #group.bookmarks), "CBookmarkPanelTitle")
  marks[#marks].opts.virt_text = { { string.format("%d/%d ", index, #data.groups), "CBookmarkPanelLocation" } }
  marks[#marks].opts.virt_text_pos = "right_align"
  if #group.bookmarks == 0 then plain("  empty", "CBookmarkPanelHint") end

  for i, bookmark in ipairs(group.bookmarks) do
    local icon = bookmark.note ~= "" and signs.note or signs.mark
    local prefix = string.format(" %2d %s ", i, icon)
    local name, suffix = where(bookmark, width - vim.fn.strdisplaywidth(prefix) - 1)
    lines[#lines + 1] = prefix .. name .. suffix
    ids[#lines] = bookmark.id

    local row = #lines - 1
    local name_col = #prefix
    local suffix_col = name_col + #name
    marks[#marks + 1] = { row = row, col = 0, opts = { end_col = 3, hl_group = "CBookmarkPanelIndex" } }
    marks[#marks + 1] = { row = row, col = 4, opts = { end_col = 4 + #icon, hl_group = "CBookmarkSign" } }
    marks[#marks + 1] = { row = row, col = name_col, opts = { end_col = suffix_col, hl_group = "CBookmarkPanelFile" } }
    marks[#marks + 1] =
      { row = row, col = suffix_col, opts = { end_col = suffix_col + #suffix, hl_group = "CBookmarkPanelLocation" } }

    local room = width - vim.fn.strdisplaywidth(lines[#lines]) - 2
    local text = caption(bookmark)
    if text ~= "" and room >= MIN_NOTE_WIDTH then
      marks[#marks + 1] = {
        row = row,
        col = 0,
        opts = {
          virt_text = { { Text.truncate(text, room) .. " ", "CBookmarkPanelHint" } },
          virt_text_pos = "right_align",
        },
      }
    end
  end

  return lines, ids, marks
end

---@param win integer
---@return string? id of the bookmark under that window's cursor
local function bookmark_in(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local bookmark = Marks.bookmark_at(bufnr, vim.api.nvim_win_get_cursor(win)[1])
  return bookmark and bookmark.id or nil
end

---The bookmark under the cursor of the editor window the panel serves.
---@return string?
local function current_id()
  local win = state.last_win
  if not win or not vim.api.nvim_win_is_valid(win) or win == state.win then win = vim.api.nvim_get_current_win() end
  if win == state.win then return nil end

  return bookmark_in(win)
end

---Marks the row of the bookmark the editor cursor is in.
local function paint_current()
  if not M.is_open() then return end

  local buf = state.buf
  vim.api.nvim_buf_clear_namespace(buf, M.current_ns, 0, -1)
  if not state.current then return end

  for row, id in ipairs(state.ids) do
    if id == state.current then
      vim.api.nvim_buf_set_extmark(buf, M.current_ns, row - 1, 0, { line_hl_group = "CBookmarkPanelCurrent" })
      return
    end
  end
end

---Follows the editor cursor: the bookmark it sits in gets highlighted.
function M.track_cursor()
  if not M.is_open() or vim.api.nvim_get_current_win() == state.win then return end

  local id = bookmark_in(vim.api.nvim_get_current_win())
  if id == state.current then return end

  state.current = id
  paint_current()
end

local function first_item_row(ids)
  for row, id in ipairs(ids) do
    if id then return row end
  end

  return 1
end

---Redraws the panel, keeping the cursor on the same bookmark.
function M.refresh()
  if not M.is_open() then return end

  local buf = state.buf
  local keep = M.id_at_cursor()
  local lines, ids, marks = build(Groups.active(), vim.api.nvim_win_get_width(state.win))

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, mark.row, mark.col, mark.opts)
  end

  local was_on_item = state.ids[vim.api.nvim_win_get_cursor(state.win)[1]] ~= nil
  state.ids = ids
  state.current = current_id()
  paint_current()

  local row
  for i, id in ipairs(ids) do
    if id == keep then row = i end
  end

  if not row then
    local current = vim.api.nvim_win_get_cursor(state.win)[1]
    local first = first_item_row(ids)
    row = (was_on_item or current < first) and math.max(current, first) or current
  end

  vim.api.nvim_win_set_cursor(state.win, { math.min(row, #lines), 0 })
end

-- Window --------------------------------------------------------------------

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "c-bookmarks"
  for lhs, action in pairs(Config.options.panel.keys) do
    local desc = type(action) == "string" and action or "custom action"
    vim.keymap.set(
      "n",
      lhs,
      function() M.run(action) end,
      { buffer = buf, nowait = true, desc = "c-bookmarks: " .. desc }
    )
  end

  state.buf = buf
  return buf
end

---Opens the panel, or focuses it when already open.
---@param opts? { focus?: boolean } false keeps the cursor where it is
function M.open(opts)
  local focus = not (opts and opts.focus == false)
  if M.is_open() then
    if focus then vim.api.nvim_set_current_win(state.win) end

    return
  end

  state.last_win = vim.api.nvim_get_current_win()
  local buf = ensure_buf()
  vim.cmd(Config.options.panel.position == "left" and "topleft vsplit" or "botright vsplit")

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, Config.options.panel.width)
  for name, value in pairs(WINDOW_OPTIONS) do
    vim.wo[win][name] = value
  end

  state.win = win
  state.ids = {}
  M.refresh()
  vim.api.nvim_win_set_cursor(win, { first_item_row(state.ids), 0 })
  if not focus then vim.api.nvim_set_current_win(state.last_win) end
end

function M.close()
  if not M.is_open() then return end

  local win = state.win
  state.win = nil
  -- the last window cannot close, so empty it instead
  if not pcall(vim.api.nvim_win_close, win, true) then vim.cmd.enew() end
  if state.last_win and vim.api.nvim_win_is_valid(state.last_win) then vim.api.nvim_set_current_win(state.last_win) end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

---A normal window beside the panel, created when none exists.
---@return integer win
local function other_window()
  if state.last_win and vim.api.nvim_win_is_valid(state.last_win) and state.last_win ~= state.win then
    return state.last_win
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local floating = vim.api.nvim_win_get_config(win).relative ~= ""
    if win ~= state.win and not floating and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then return win end
  end

  vim.api.nvim_set_current_win(state.win)
  vim.cmd(Config.options.panel.position == "left" and "rightbelow vsplit" or "leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  -- the split copied the panel's window options
  for name in pairs(WINDOW_OPTIONS) do
    vim.wo[win][name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end

  vim.api.nvim_win_set_width(state.win, Config.options.panel.width)
  return win
end

---Opens the bookmark in a normal window and leaves the panel open.
---@param id string
---@return boolean
function M.jump(id)
  local bookmark = bookmark_for(id)
  if not bookmark then return false end

  vim.api.nvim_set_current_win(other_window())
  local path = Store.abspath(bookmark.path)
  if vim.fn.bufnr(path) ~= vim.api.nvim_get_current_buf() then
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
  end

  Marks.sync(0, { persist = false })
  vim.api.nvim_win_set_cursor(0, { math.min(bookmark.lnum, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd "normal! zz"
  return true
end

-- Actions -------------------------------------------------------------------

local function with_bookmark(fn)
  return function(ctx)
    if not ctx.id or not ctx.bookmark then
      notify "no bookmark on this line"
      return
    end

    fn(ctx.id, ctx.bookmark)
  end
end

local function update_active(fn)
  Store.update(function(data)
    local group = Model.active_group(data)
    if group then fn(group) end
  end)
end

---@type table<string, CBookmarks.PanelAction>
M.actions = {
  jump = with_bookmark(function(id) M.jump(id) end),
  close = function() M.close() end,
  delete = with_bookmark(function(id) Marks.remove(id) end),
  edit_note = with_bookmark(function(id) Notes.edit(id) end),
  view_note = with_bookmark(function(id) Notes.view(id) end),
  rename = with_bookmark(function(id, bookmark)
    vim.ui.input({ prompt = "Bookmark name: ", default = bookmark.name }, function(name)
      if name == nil then return end

      update_active(function(group)
        local target = Model.find_bookmark(group, id)
        if not target then return end

        target.name = vim.trim(name)
        Model.touch(target)
      end)
    end)
  end),
  move_up = with_bookmark(function(id)
    update_active(function(group) Model.move_bookmark(group, id, -1) end)
  end),
  move_down = with_bookmark(function(id)
    update_active(function(group) Model.move_bookmark(group, id, 1) end)
  end),
  sort = function() update_active(Model.sort_bookmarks) end,
  next_group = function() Groups.next { silent = true } end,
  prev_group = function() Groups.prev { silent = true } end,
  pick_group = function() Groups.pick() end,
  new_group = function() Groups.create() end,
  rename_group = function() Groups.rename() end,
  delete_group = function() Groups.remove() end,
  clear_group = function() Groups.clear() end,
  explain = function() explain().explain() end,
  cancel_explain = function() explain().cancel() end,
  pick_model = function() explain().pick_model() end,
  help = function() M.help() end,
}

---@param action string|CBookmarks.PanelAction
function M.run(action)
  local fn = type(action) == "function" and action or M.actions[action]
  if not fn then
    notify("unknown panel action " .. tostring(action), vim.log.levels.WARN)
    return
  end

  local id = M.id_at_cursor()
  fn { id = id, bookmark = bookmark_for(id) }
end

function M.help()
  local rows = {}
  for lhs, action in pairs(Config.options.panel.keys) do
    rows[#rows + 1] = string.format("%-8s %s", lhs, type(action) == "string" and action or "custom action")
  end

  table.sort(rows)
  notify("panel keys\n" .. table.concat(rows, "\n"))
end

function M.setup()
  local augroup = vim.api.nvim_create_augroup("CBookmarksPanel", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "CBookmarksChanged", "CBookmarksProgress" },
    callback = function() M.refresh() end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      if state.win and tonumber(ev.match) == state.win then state.win = nil end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, { group = augroup, callback = M.track_cursor })
end

return M
