local Model = require "c-bookmarks.model"

local function sample()
  local data = Model.empty()
  local walk = Model.add_group(data, "walk")
  Model.add_group(data, "bugs")
  Model.add_group(data, "later")
  Model.add_bookmark(walk, { path = "src/b.lua", lnum = 10, end_lnum = 20, name = "wide" })
  Model.add_bookmark(walk, { path = "src/a.lua", lnum = 5 })
  Model.add_bookmark(walk, { path = "src/b.lua", lnum = 12, end_lnum = 14, note = "narrow" })
  return data, walk
end

describe("model", function()
  it("repairs a hand-written file", function()
    local data = Model.normalize {
      active = "missing",
      groups = {
        {
          name = "  walk ",
          bookmarks = {
            { path = "a.lua", lnum = 9, end_lnum = 3 },
            { lnum = 1 },
            { id = "dup", path = "b.lua", lnum = "4" },
            { id = "dup", path = "c.lua", note = vim.NIL },
          },
        },
        "junk",
        { bookmarks = "nope" },
      },
    }
    assert.equals(2, #data.groups)
    assert.equals("walk", data.groups[1].name)
    assert.equals("untitled", data.groups[2].name)
    assert.equals(data.groups[1].id, data.active)

    local marks = data.groups[1].bookmarks
    assert.equals(3, #marks)
    assert.same({ 3, 9 }, { marks[1].lnum, marks[1].end_lnum })
    assert.same({ 4, 4 }, { marks[2].lnum, marks[2].end_lnum })
    assert.equals("dup", marks[2].id)
    assert.are_not.equal("dup", marks[3].id)
    assert.equals("", marks[3].note)
  end)

  it("starts empty for anything that is not a table", function()
    assert.same(Model.empty(), Model.normalize "nope")
    assert.same(Model.empty(), Model.normalize(nil))
  end)

  it("keeps group names unique and the first group active", function()
    local data = Model.empty()
    local first = assert(Model.add_group(data, "walk"))
    assert.equals(first.id, data.active)

    local dup, err = Model.add_group(data, " WALK ")
    assert.is_nil(dup)
    assert.matches("already exists", err)

    local blank, blank_err = Model.add_group(data, "  ")
    assert.is_nil(blank)
    assert.matches("needs a name", blank_err)

    assert.is_true(Model.rename_group(data, first.id, "tour"))
    assert.equals("tour", Model.find_group_by_name(data, "tour").name)
  end)

  it("moves the active group when the active one is removed", function()
    local data = sample()
    local active = Model.active_group(data)
    assert.is_true(Model.remove_group(data, active.id))
    assert.equals("bugs", Model.active_group(data).name)
    assert.is_false(Model.remove_group(data, "nope"))
  end)

  it("rotates through groups and wraps", function()
    local data = sample()
    assert.equals("bugs", Model.rotate(data, 1).name)
    assert.equals("later", Model.rotate(data, 1).name)
    assert.equals("walk", Model.rotate(data, 1).name)
    assert.equals("later", Model.rotate(data, -1).name)
    assert.is_nil(Model.rotate(Model.empty(), 1))
  end)

  it("keeps explicit order and sorts only on demand", function()
    local _, walk = sample()
    local ids = vim.tbl_map(function(b) return b.name ~= "" and b.name or b.path end, walk.bookmarks)
    assert.same({ "wide", "src/a.lua", "src/b.lua" }, ids)

    assert.equals(1, Model.move_bookmark(walk, walk.bookmarks[2].id, -5))
    assert.equals("src/a.lua", walk.bookmarks[1].path)
    assert.is_nil(Model.move_bookmark(walk, "nope", 1))

    Model.sort_bookmarks(walk)
    assert.same({ 5, 10, 12 }, vim.tbl_map(function(b) return b.lnum end, walk.bookmarks))
  end)

  it("finds the narrowest bookmark covering a line", function()
    local _, walk = sample()
    assert.equals("narrow", Model.find_at(walk, "src/b.lua", 13).note)
    assert.equals("wide", Model.find_at(walk, "src/b.lua", 18).name)
    assert.is_nil(Model.find_at(walk, "src/b.lua", 21))
    assert.equals(2, #Model.bookmarks_in(walk, "src/b.lua"))
  end)

  it("labels by name, then note, then anchor", function()
    local _, walk = sample()
    local b = walk.bookmarks[2]
    assert.equals("src/a.lua", b.path)
    assert.equals("untitled", Model.label(b))
    b.anchor = "  local x = 1"
    assert.equals("local x = 1", Model.label(b))
    b.note = "## Why here\nmore"
    assert.equals("Why here", Model.label(b))
    b.name = "start"
    assert.equals("start", Model.label(b))
  end)

  it("clears a group or everything", function()
    local data, walk = sample()
    Model.clear_group(walk)
    assert.equals(0, #walk.bookmarks)
    Model.clear_all(data)
    assert.same({ version = 1, groups = {} }, data)
  end)
end)
