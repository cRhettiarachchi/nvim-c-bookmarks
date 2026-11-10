local helpers = require "tests.helpers"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Panel = require "c-bookmarks.panel"
local Store = require "c-bookmarks.store"

describe("a walkthrough written by another tool", function()
  local dir, file_buf

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
    file_buf = vim.api.nvim_get_current_buf()
    Marks.add { lnum = 7, name = "mine" }
    Panel.open()
  end)

  after_each(function()
    Panel.close()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("appears in the panel and the gutter without a reload", function()
    local written = vim.deepcopy(Store.get())
    written.active = "g_tour"
    written.groups[#written.groups + 1] = {
      id = "g_tour",
      name = "tour",
      bookmarks = {
        { path = "src/a.lua", lnum = 2, end_lnum = 3, note = "# Entry\nstarts here", anchor = "two" },
        { path = "src/a.lua", lnum = 5, name = "Hand-off" },
      },
    }
    vim.fn.writefile(vim.split(Store.encode(written), "\n"), dir .. "/.c-bookmarks.json")

    local header = function() return vim.api.nvim_buf_get_lines(Panel.buf(), 0, 1, false)[1] end
    assert.truthy(vim.wait(3000, function() return header():find("tour (2)", 1, true) ~= nil end, 50))

    local group = Groups.active()
    assert.equals("tour", group.name)
    assert.equals("Entry", require("c-bookmarks.notes").first_line(group.bookmarks[1].note))
    assert.truthy(group.bookmarks[1].id ~= "" and group.bookmarks[2].id ~= "")
    assert.are_not.equal(group.bookmarks[1].id, group.bookmarks[2].id)

    local rows = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(file_buf, Marks.ns, 0, -1, {})) do
      rows[#rows + 1] = mark[2]
    end

    table.sort(rows)
    assert.same({ 1, 4 }, rows)
    assert.equals(2, #Store.get().groups)
    assert.equals("mine", Store.get().groups[1].bookmarks[1].name)
  end)
end)
