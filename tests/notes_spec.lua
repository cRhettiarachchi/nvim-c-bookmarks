local helpers = require "tests.helpers"
local Config = require "c-bookmarks.config"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Notes = require "c-bookmarks.notes"
local Store = require "c-bookmarks.store"

local function note_of(id) return assert(Model.find_bookmark(Groups.active(), id)).note end

local function hints(bufnr) return vim.api.nvim_buf_get_extmarks(bufnr, Notes.hint_ns, 0, -1, { details = true }) end

local function close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
  end
end

describe("notes", function()
  local dir, file_buf, file_win, plain, noted

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
    file_buf = vim.api.nvim_get_current_buf()
    file_win = vim.api.nvim_get_current_win()
    plain = Marks.add { lnum = 2, name = "second" }
    noted = Marks.add { lnum = 5, end_lnum = 6, note = "# Why here\nbecause" }
  end)

  after_each(function()
    close_floats()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("edits a note in a float and saves on close", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local win = assert(Notes.edit())
    local buf = vim.api.nvim_win_get_buf(win)
    assert.equals("markdown", vim.bo[buf].filetype)
    assert.equals("editor", vim.api.nvim_win_get_config(win).relative)
    assert.equals(win, vim.api.nvim_get_current_win())

    vim.cmd.stopinsert()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## Start", "", "the entry point", "" })
    vim.api.nvim_win_close(win, true)
    assert.equals("## Start\n\nthe entry point", note_of(plain.id))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))

    local icons = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(file_buf, Marks.ns, 0, -1, { details = true })) do
      icons[#icons + 1] = vim.trim(mark[4].sign_text)
    end

    assert.same({ Config.options.signs.note, Config.options.signs.note }, icons)
  end)

  it("creates a bookmark when editing on a bare line", function()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local win = assert(Notes.edit())
    assert.equals(3, #Groups.active().bookmarks)
    local created = Groups.active().bookmarks[3]
    assert.same({ 4, 4 }, { created.lnum, created.end_lnum })
    vim.api.nvim_win_close(win, true)
    assert.equals("", note_of(created.id))
  end)

  it("saves with :w, keeps the float open and reuses it", function()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local win = assert(Notes.edit())
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
    vim.cmd "silent write"
    assert.equals("changed", note_of(noted.id))
    assert.is_false(vim.bo[buf].modified)
    assert.is_true(vim.api.nvim_win_is_valid(win))

    vim.api.nvim_set_current_win(file_win)
    vim.api.nvim_win_set_cursor(file_win, { 6, 0 })
    assert.equals(win, Notes.edit())
  end)

  it("shows the rendered note in a hover window", function()
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    local win = assert(Notes.view())
    local config = vim.api.nvim_win_get_config(win)
    assert.are_not.equal("", config.relative)
    assert.truthy(config.title)
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    assert.truthy(text:find("Why here", 1, true))
    assert.truthy(text:find("because", 1, true))
    assert.equals(file_win, vim.api.nvim_get_current_win())

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_nil(Notes.view())
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    assert.is_nil(Notes.view())
  end)

  it("hints the first note line while the cursor rests on the range", function()
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    Notes.hint()
    local marks = hints(file_buf)
    assert.equals(1, #marks)
    assert.equals(5, marks[1][2])
    local text = marks[1][4].virt_text[1][1]
    assert.truthy(text:find("Why here", 1, true))
    assert.is_nil(text:find("#", 1, true))

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    Notes.hint()
    assert.equals(0, #hints(file_buf))
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    Notes.hint()
    assert.equals(0, #hints(file_buf))
  end)

  it("truncates long hints", function()
    Store.update(function(data) data.groups[1].bookmarks[1].note = string.rep("x", 100) end)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    Notes.hint()
    local text = hints(file_buf)[1][4].virt_text[1][1]
    assert.truthy(text:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(text) <= Config.options.notes.hint.max_width + 4)
  end)

  it("finds the narrowest live bookmark at a line", function()
    assert.is_nil(Marks.bookmark_at(file_buf, 7))
    Marks.add { lnum = 1, end_lnum = 7, name = "wide" }
    assert.equals(noted.id, Marks.bookmark_at(file_buf, 5).id)
    assert.equals("wide", Marks.bookmark_at(file_buf, 3).name)
    assert.equals("wide", Marks.bookmark_at(file_buf, 7).name)
  end)
end)
