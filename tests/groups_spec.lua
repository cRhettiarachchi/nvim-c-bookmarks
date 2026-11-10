local helpers = require "tests.helpers"
local Groups = require "c-bookmarks.groups"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"

describe("groups", function()
  local dir

  before_each(function() dir = helpers.project() end)

  after_each(function()
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("creates a group and makes it active", function()
    Groups.create "walk"
    Groups.create "bugs"
    assert.equals("bugs", Groups.active().name)
    assert.equals(2, #Groups.list())
    Groups.create "walk"
    assert.equals(2, #Groups.list())
    assert.truthy(vim.uv.fs_stat(dir .. "/.c-bookmarks.json"))
  end)

  it("prompts for a name when none is given", function()
    local original = vim.ui.input
    vim.ui.input = function(_, callback) callback "typed" end
    Groups.create()
    vim.ui.input = original
    assert.equals("typed", Groups.active().name)
  end)

  it("renames the active group", function()
    Groups.create "walk"
    Groups.rename "tour"
    assert.equals("tour", Groups.active().name)
  end)

  it("deletes the active group and falls back to the first", function()
    Groups.create "walk"
    Groups.create "bugs"
    Model.add_bookmark(Groups.active(), { path = "a.lua", lnum = 1 })
    assert.is_true(Groups.remove { force = true })
    assert.equals("walk", Groups.active().name)
  end)

  it("rotates and picks", function()
    Groups.create "walk"
    Groups.create "bugs"
    Groups.create "later"
    assert.equals("walk", Groups.next({ silent = true }).name)
    assert.equals("later", Groups.prev({ silent = true }).name)

    local original = vim.ui.select
    vim.ui.select = function(items, _, callback) callback(items[2]) end
    Groups.pick()
    vim.ui.select = original
    assert.equals("bugs", Groups.active().name)
    assert.matches("bugs %(0%) 2/3", Groups.status())
  end)

  it("clears the active group or everything", function()
    Groups.create "walk"
    Store.update(function(data) Model.add_bookmark(Model.active_group(data), { path = "a.lua", lnum = 1 }) end)
    assert.is_true(Groups.clear { force = true })
    assert.equals(0, #Groups.active().bookmarks)
    assert.is_false(Groups.clear { force = true })
    assert.is_true(Groups.clear_all { force = true })
    assert.is_nil(Groups.active())
    assert.equals("", Groups.status())
  end)
end)
