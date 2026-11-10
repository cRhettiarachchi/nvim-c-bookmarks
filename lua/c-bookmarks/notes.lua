---Markdown notes: edit in a float, read in a hover window, hint at the cursor.
local Config = require "c-bookmarks.config"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"
local Text = require "c-bookmarks.text"

local M = {}

M.hint_ns = vim.api.nvim_create_namespace "c-bookmarks-hint"

---@type table<string, { win: integer, buf: integer }> open editors by bookmark id
local editors = {}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

---@param id string?
---@return CBookmarks.Bookmark?
local function find(id)
  local group = Groups.active()
  if not group or not id then return nil end

  return (Model.find_bookmark(group, id))
end

---The bookmark for id, else the one under the cursor; create adds one there.
---@return CBookmarks.Bookmark?
local function target(id, create)
  if id then return find(id) end

  local bookmark = Marks.at_cursor()
  if bookmark or not create then return bookmark end

  local lnum, end_lnum = Marks.selected_lines()
  return Marks.add { lnum = lnum, end_lnum = end_lnum }
end

---@param note string
---@return string first line without heading marks
function M.first_line(note)
  local line = (note:match "^[^\n]*" or ""):gsub("^#+%s*", "")
  return vim.trim(line)
end

---Stores the note text, trailing blank lines dropped.
---@param id string
---@param lines string[]
---@return boolean changed
function M.save(id, lines)
  local note = (table.concat(lines, "\n"):gsub("%s+$", ""))
  local current = find(id)
  if not current or current.note == note then return false end

  Store.update(function(data)
    local group = Model.active_group(data)
    local bookmark = group and Model.find_bookmark(group, id)
    if not bookmark then return end

    bookmark.note = note
    Model.touch(bookmark)
  end)
  return true
end

-- Editor --------------------------------------------------------------------

---Opens the note in a floating markdown buffer. Every close saves.
---@param id? string defaults to the bookmark under the cursor, created when missing
---@return integer? win
function M.edit(id)
  local bookmark = target(id, true)
  if not bookmark then return nil end

  local open = editors[bookmark.id]
  if open and vim.api.nvim_win_is_valid(open.win) then
    vim.api.nvim_set_current_win(open.win)
    return open.win
  end

  local opts = Config.options.notes.editor
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "c-bookmarks://note/" .. bookmark.id)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(bookmark.note, "\n", { plain = true }))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modified = false

  local width = math.min(opts.width, vim.o.columns - 4)
  local height = math.min(opts.height, vim.o.lines - 4)
  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = opts.border,
  }
  if opts.border ~= "none" then
    config.title = " " .. Model.label(bookmark) .. " "
    config.title_pos = "center"
    config.footer = " q saves and closes "
    config.footer_pos = "right"
  end

  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  editors[bookmark.id] = { win = win, buf = buf }

  local function save()
    if M.save(bookmark.id, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then notify "note saved" end

    vim.bo[buf].modified = false
  end

  local augroup = vim.api.nvim_create_augroup("CBookmarksNote" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = augroup, buffer = buf, callback = save })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = augroup,
    buffer = buf,
    callback = function()
      save()
      editors[bookmark.id] = nil
    end,
  })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf, nowait = true, desc = "c-bookmarks: save and close the note" })
  if bookmark.note == "" then vim.cmd.startinsert() end

  return win
end

-- Viewer --------------------------------------------------------------------

---Shows the rendered note in a hover window by the cursor.
---@param id? string defaults to the bookmark under the cursor
---@return integer? win
function M.view(id)
  local bookmark = target(id, false)
  if not bookmark then
    notify "no bookmark under the cursor"
    return nil
  end

  if bookmark.note == "" then
    notify "this bookmark has no note"
    return nil
  end

  local opts = Config.options.notes.viewer
  local _, win = vim.lsp.util.open_floating_preview(vim.split(bookmark.note, "\n", { plain = true }), "markdown", {
    border = opts.border,
    max_width = opts.max_width,
    max_height = opts.max_height,
    wrap = true,
    focusable = true,
    focus_id = "c-bookmarks-note",
    title = " " .. Model.label(bookmark) .. " ",
  })
  return win
end

-- Hint ----------------------------------------------------------------------

---Shows the first note line after the bookmarked line under the cursor.
---@param bufnr? integer
function M.hint(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, M.hint_ns, 0, -1)
  local cfg = Config.options.notes.hint
  if not cfg.enabled or vim.api.nvim_get_current_buf() ~= bufnr then return end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local bookmark = Marks.bookmark_at(bufnr, lnum)
  if not bookmark or bookmark.note == "" then return end

  local text = Text.truncate(M.first_line(bookmark.note), cfg.max_width)
  if text == "" then return end

  vim.api.nvim_buf_set_extmark(bufnr, M.hint_ns, lnum - 1, 0, {
    virt_text = { { " " .. Config.options.signs.note .. " " .. text, "CBookmarkHint" } },
    virt_text_pos = "eol",
    priority = Config.options.signs.priority + 1,
  })
end

function M.setup()
  local augroup = vim.api.nvim_create_augroup("CBookmarksNotes", { clear = true })
  local function refresh_hint() M.hint() end

  vim.api.nvim_create_autocmd(
    { "CursorMoved", "BufEnter", "InsertLeave" },
    { group = augroup, callback = refresh_hint }
  )
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    callback = function(ev) vim.api.nvim_buf_clear_namespace(ev.buf, M.hint_ns, 0, -1) end,
  })
  vim.api.nvim_create_autocmd("User", { group = augroup, pattern = "CBookmarksChanged", callback = refresh_hint })
end

return M
