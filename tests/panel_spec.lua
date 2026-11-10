local helpers = require "tests.helpers"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Panel = require "c-bookmarks.panel"
local Store = require "c-bookmarks.store"

local function lines() return vim.api.nvim_buf_get_lines(Panel.buf(), 0, -1, false) end

local function virt_text_on(row)
  local texts = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(Panel.buf(), Panel.ns, { row, 0 }, { row, -1 }, { details = true }))
  do
    local virt = mark[4].virt_text
    if virt then texts[#texts + 1] = virt[1][1] end
  end

  return table.concat(texts, " ")
end

describe("panel", function()
  local dir, file_buf

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
    file_buf = vim.api.nvim_get_current_buf()
    Marks.add { lnum = 2, name = "second" }
    Marks.add { lnum = 5, end_lnum = 6, note = "why here" }
  end)

  after_each(function()
    Panel.close()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("opens on the right showing the active group in order", function()
    Panel.open()
    assert.is_true(Panel.is_open())
    assert.equals(40, vim.api.nvim_win_get_width(Panel.win()))
    assert.equals(vim.fn.winnr "$", vim.fn.win_id2win(Panel.win()))
    assert.equals(Panel.win(), vim.api.nvim_get_current_win())

    local rows = lines()
    assert.equals(3, #rows)
    assert.truthy(rows[1]:find("default (2)", 1, true))
    assert.truthy(rows[2]:find("a.lua:2", 1, true))
    assert.truthy(rows[3]:find("a.lua:5-6", 1, true))
    assert.is_nil(rows[2]:find("src/", 1, true))
    assert.truthy(virt_text_on(1):find("second", 1, true))
    assert.truthy(virt_text_on(2):find("why here", 1, true))
    assert.equals(2, vim.api.nvim_win_get_cursor(Panel.win())[1])
  end)

  it("cuts the caption first, then the file name, and keeps the lines longest", function()
    helpers.write(dir, "src/validate-everything.lua", { "a", "b", "c" })
    vim.cmd.edit(dir .. "/src/validate-everything.lua")
    Marks.add { lnum = 2, end_lnum = 3, note = "a note that is long" }
    Panel.open()
    vim.api.nvim_win_set_width(Panel.win(), 40)
    Panel.refresh()
    assert.truthy(lines()[4]:find("validate-everything.lua:2-3", 1, true))
    assert.truthy(virt_text_on(3):find("a no…", 1, true))

    vim.api.nvim_win_set_width(Panel.win(), 22)
    Panel.refresh()
    assert.truthy(lines()[4]:find("validate-e…:2-3", 1, true))
    assert.equals("", virt_text_on(3))

    vim.api.nvim_win_set_width(Panel.win(), 9)
    Panel.refresh()
    assert.truthy(lines()[4]:find(" 3 ", 1, true))
    assert.truthy(lines()[4]:find("v…", 1, true))
    assert.is_nil(lines()[4]:find(":", 1, true))
  end)

  it("highlights the bookmark the editor cursor is in", function()
    local function current_rows()
      local rows = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(Panel.buf(), Panel.current_ns, 0, -1, {})) do
        rows[#rows + 1] = mark[2]
      end

      return rows
    end

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    Panel.open { focus = false }
    assert.same({ 2 }, current_rows())
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    Panel.track_cursor()
    assert.same({ 1 }, current_rows())
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    Panel.track_cursor()
    assert.same({}, current_rows())
    Panel.run "next_group"
    assert.same({}, current_rows())
  end)

  it("jumps on enter and keeps the panel open", function()
    Panel.open()
    vim.api.nvim_win_set_cursor(Panel.win(), { 3, 0 })
    Panel.run "jump"
    assert.equals(file_buf, vim.api.nvim_get_current_buf())
    assert.equals(5, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(Panel.is_open())
    assert.are_not.equal(Panel.win(), vim.api.nvim_get_current_win())
  end)

  it("moves, sorts and deletes from the panel", function()
    Panel.open()
    vim.api.nvim_win_set_cursor(Panel.win(), { 3, 0 })
    local moved = Panel.id_at_cursor()
    Panel.run "move_up"
    assert.equals(moved, Groups.active().bookmarks[1].id)
    assert.equals(2, vim.api.nvim_win_get_cursor(Panel.win())[1])
    assert.equals(moved, Panel.id_at_cursor())

    Panel.run "sort"
    assert.equals("second", Groups.active().bookmarks[1].name)

    vim.api.nvim_win_set_cursor(Panel.win(), { 2, 0 })
    Panel.run "delete"
    assert.equals(1, #Groups.active().bookmarks)
    assert.equals(2, #lines())
  end)

  it("refreshes line numbers as the file changes", function()
    Panel.open()
    vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { "new" })
    Marks.sync(file_buf, { persist = false })
    assert.truthy(lines()[2]:find("a.lua:3", 1, true))
    assert.truthy(lines()[3]:find("a.lua:6-7", 1, true))
  end)

  it("rotates groups from the panel", function()
    Groups.create "other"
    Panel.open()
    assert.truthy(lines()[1]:find("other (0)", 1, true))
    assert.truthy(lines()[2]:find("empty", 1, true))
    Panel.run "next_group"
    assert.truthy(lines()[1]:find("default (2)", 1, true))
    assert.equals(3, #lines())
  end)

  it("toggles and returns to the previous window", function()
    local before = vim.api.nvim_get_current_win()
    Panel.toggle()
    assert.is_true(Panel.is_open())
    Panel.toggle()
    assert.is_false(Panel.is_open())
    assert.equals(before, vim.api.nvim_get_current_win())
  end)
end)
