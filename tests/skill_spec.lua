local helpers = require "tests.helpers"
local Model = require "c-bookmarks.model"
local Skill = require "c-bookmarks.skill"

describe("skill", function()
  it("ships a skill file named after the plugin", function()
    local text = helpers.read(Skill.path())
    assert.matches("^%-%-%-\nname: c%-bookmarks\ndescription: ", text)
    assert.truthy(text:find("## Writing a walkthrough", 1, true))
    assert.truthy(text:find("## Reading bookmarks", 1, true))
  end)

  it("documents an example the plugin accepts unchanged", function()
    local text = helpers.read(Skill.path())
    local json = assert(text:match "```json\n(.-)```")
    local raw = vim.json.decode(json)
    local data = Model.normalize(raw)
    assert.same(raw, data)
    assert.equals(Model.VERSION, data.version)
    assert.equals(data.groups[1].id, data.active)
    assert.equals(
      "Entry point for every login request.",
      Model.label { name = "", note = data.groups[1].bookmarks[1].note, anchor = "" }
    )
  end)

  it("links into a skills directory once and unlinks cleanly", function()
    local dir = vim.fn.tempname()
    assert.equals("missing", Skill.status { dir = dir })
    assert.is_true(Skill.install { dir = dir })
    assert.equals("linked", Skill.status { dir = dir })
    assert.is_true(Skill.install { dir = dir })
    assert.truthy(vim.uv.fs_stat(dir .. "/c-bookmarks/SKILL.md"))
    assert.is_true(Skill.uninstall { dir = dir })
    assert.equals("missing", Skill.status { dir = dir })
    assert.is_false(Skill.uninstall { dir = dir })
    vim.fn.delete(dir, "rf")
  end)

  it("leaves a foreign directory alone", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/c-bookmarks", "p")
    assert.equals("foreign", Skill.status { dir = dir })
    assert.is_false(Skill.install { dir = dir })
    assert.is_false(Skill.uninstall { dir = dir })
    assert.truthy(vim.uv.fs_stat(dir .. "/c-bookmarks"))
    vim.fn.delete(dir, "rf")
  end)
end)
