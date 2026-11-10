local helpers = require "tests.helpers"
local Commands = require "c-bookmarks.commands"
local Groups = require "c-bookmarks.groups"
local Store = require "c-bookmarks.store"

local function run(args) Commands.run { args = args, range = 0, line1 = 1, line2 = 1 } end

describe("commands", function()
  local dir

  before_each(function()
    dir = helpers.project()
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
  end)

  after_each(function()
    require("c-bookmarks.panel").close()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("dispatches nested group verbs", function()
    run "group new walk"
    run "group new bugs"
    assert.equals("bugs", Groups.active().name)
    run "group prev"
    assert.equals("walk", Groups.active().name)
    run "group rename tour"
    assert.equals("tour", Groups.active().name)
  end)

  it("adds with a range and a name", function()
    helpers.write(dir, "f.lua", { "a", "b", "c" })
    vim.cmd.edit(dir .. "/f.lua")
    Commands.run { args = "add hello there", range = 2, line1 = 2, line2 = 3 }
    local bookmark = Groups.active().bookmarks[1]
    assert.same({ 2, 3, "hello there" }, { bookmark.lnum, bookmark.end_lnum, bookmark.name })
  end)

  it("opens the note editor through the command", function()
    helpers.write(dir, "f.lua", { "a", "b", "c" })
    vim.cmd.edit(dir .. "/f.lua")
    run "note"
    local win = vim.api.nvim_get_current_win()
    assert.are_not.equal("", vim.api.nvim_win_get_config(win).relative)
    assert.equals("markdown", vim.bo.filetype)
    vim.cmd.stopinsert()
    vim.api.nvim_win_close(win, true)
    assert.equals(1, #Groups.active().bookmarks)
  end)

  it("passes free text to explain and ask, verbs still win", function()
    local Explain, Ask = require "c-bookmarks.ai.explain", require "c-bookmarks.ai.ask"
    local seen = {}
    local explain, ask, cancel = Explain.explain, Ask.ask, Ask.cancel
    Explain.explain = function(request) seen.explain = request end
    Ask.ask = function(question) seen.ask = question end
    Ask.cancel = function() seen.cancelled = true end
    run "explain how does login work"
    run "ask what is a closure"
    run "ask cancel"
    Explain.explain, Ask.ask, Ask.cancel = explain, ask, cancel
    assert.same({ explain = "how does login work", ask = "what is a closure", cancelled = true }, seen)
  end)

  it("reports unknown subcommands and verbs", function()
    local messages = {}
    local original = vim.notify
    vim.notify = function(message) messages[#messages + 1] = message end
    run "bogus"
    run "group bogus"
    run ""
    vim.notify = original
    assert.matches("unknown subcommand", messages[1])
    assert.matches("unknown group verb", messages[2])
    assert.matches("expected one of", messages[3])
  end)

  it("completes subcommands and verbs", function()
    assert.same(
      { "add", "ask", "clear", "explain", "group", "note", "panel", "reload", "remove", "save", "skill", "toggle" },
      Commands.complete("", "CBookmarks ")
    )
    assert.same({ "new", "next" }, Commands.complete("ne", "CBookmarks group ne"))
    assert.same({}, Commands.complete("", "CBookmarks add "))
    assert.same({ "group" }, Commands.complete("gr", "'<,'>CBookmarks gr"))
  end)
end)
