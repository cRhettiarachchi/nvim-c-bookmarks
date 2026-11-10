local helpers = require "tests.helpers"
local Config = require "c-bookmarks.config"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"

local function extmarks(bufnr) return vim.api.nvim_buf_get_extmarks(bufnr, Marks.ns, 0, -1, { details = true }) end

local function stored(id) return (Model.find_bookmark(Model.active_group(Store.get()), id)) end

describe("marks", function()
  local dir

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
  end)

  after_each(function()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("adds a range and places one extmark with a sign", function()
    local bookmark = Marks.add { lnum = 3, end_lnum = 5, name = "mid" }
    assert.equals("src/a.lua", bookmark.path)
    assert.equals("three", bookmark.anchor)
    assert.equals("default", Model.active_group(Store.get()).name)

    local marks = extmarks(0)
    assert.equals(1, #marks)
    assert.equals(2, marks[1][2])
    assert.equals(5, marks[1][4].end_row)
    assert.equals(Config.options.signs.mark, vim.trim(marks[1][4].sign_text))
  end)

  it("follows inserted and deleted lines", function()
    local bookmark = Marks.add { lnum = 3, end_lnum = 5 }
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new", "new" })
    assert.is_true(Marks.sync(0, { persist = false }))
    assert.same({ 5, 7 }, { stored(bookmark.id).lnum, stored(bookmark.id).end_lnum })

    vim.api.nvim_buf_set_lines(0, 5, 6, false, {})
    Marks.sync(0, { persist = false })
    assert.same({ 5, 6 }, { stored(bookmark.id).lnum, stored(bookmark.id).end_lnum })
    assert.equals("three", stored(bookmark.id).anchor)
    assert.is_false(Marks.sync(0, { persist = false }))
  end)

  it("writes positions back on save", function()
    local bookmark = Marks.add { lnum = 3 }
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
    vim.cmd "silent write"
    local text = helpers.read(dir .. "/.c-bookmarks.json")
    assert.truthy(text:find('"lnum": 4', 1, true), text)
    assert.equals(4, stored(bookmark.id).lnum)
  end)

  it("toggles the bookmark under the cursor", function()
    Marks.add { lnum = 2, end_lnum = 3 }
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    assert.is_nil(Marks.toggle())
    assert.equals(0, #Model.active_group(Store.get()).bookmarks)
    assert.equals(0, #extmarks(0))

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    local added = Marks.toggle()
    assert.same({ 6, 6 }, { added.lnum, added.end_lnum })
    assert.is_true(Marks.remove_at_cursor())
    assert.is_false(Marks.remove_at_cursor())
  end)

  it("uses the visual selection for the range", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("Vjj", "x", false)
    assert.equals("V", vim.fn.mode())
    local first, last = Marks.selected_lines()
    assert.same({ 2, 4 }, { first, last })
    assert.equals("n", vim.fn.mode())
  end)

  it("refuses buffers without a file", function()
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    assert.is_nil(Marks.add { lnum = 1 })
  end)

  it("shows a different sign when a note exists", function()
    Marks.add { lnum = 1, note = "why" }
    assert.equals(Config.options.signs.note, vim.trim(extmarks(0)[1][4].sign_text))
  end)

  it("renders the active group only", function()
    Marks.add { lnum = 1 }
    Store.update(function(data)
      local other = assert(Model.add_group(data, "other"))
      Model.set_active(data, other.id)
    end)
    assert.equals(0, #extmarks(0))
    Store.update(function(data) Model.rotate(data, 1) end)
    assert.equals(1, #extmarks(0))
  end)

  it("takes outside writes as the truth", function()
    local bookmark = Marks.add { lnum = 2 }
    local outside = vim.deepcopy(Store.get())
    outside.groups[1].bookmarks[1].lnum = 6
    outside.groups[1].bookmarks[1].end_lnum = 6
    vim.fn.writefile(vim.split(Store.encode(outside), "\n"), dir .. "/.c-bookmarks.json")
    assert.truthy(vim.wait(3000, function() return stored(bookmark.id) and stored(bookmark.id).lnum == 6 end, 50))
    assert.equals(5, extmarks(0)[1][2])
  end)
end)
