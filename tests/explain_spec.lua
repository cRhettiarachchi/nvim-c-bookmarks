local helpers = require "tests.helpers"
local Config = require "c-bookmarks.config"
local Explain = require "c-bookmarks.ai.explain"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Panel = require "c-bookmarks.panel"
local Providers = require "c-bookmarks.ai.providers"
local Skill = require "c-bookmarks.skill"
local Store = require "c-bookmarks.store"

---A provider that prints a canned claude envelope.
local function fake_provider(envelope, capture)
  return {
    name = "fake",
    command = function(ctx)
      if capture then capture.ctx = ctx end

      return { "printf", "%s", vim.json.encode(envelope) }
    end,
    parse = Providers.claude.parse,
  }
end

local function use_provider(provider)
  Config.options.ai.providers = { fake = provider }
  Config.options.ai.provider = "fake"
  Config.options.ai.open_panel = true
  Config.options.ai.state_file = vim.fn.tempname() .. "/ai.json"
end

local function capture_notifications()
  local messages = {}
  vim.notify = function(message) messages[#messages + 1] = message end
  return messages
end

describe("explain", function()
  local dir, original_notify

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
    original_notify = vim.notify
  end)

  after_each(function()
    vim.notify = original_notify
    Explain.cancel()
    require("c-bookmarks.ai.progress").reset()
    Explain.set_model "default"
    Panel.close()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("builds a prompt with the skill, the root, the focus and the active group", function()
    Marks.add { lnum = 2, name = "second" }
    local prompt = Explain.build_prompt("how does a become b", {
      root = dir,
      focus = { path = "src/a.lua", lnum = 3, end_lnum = 4 },
      group = Groups.active(),
    })
    assert.truthy(prompt:find(Skill.path(), 1, true))
    assert.truthy(prompt:find("relative to " .. dir, 1, true))
    assert.truthy(prompt:find("src/a.lua lines 3-4", 1, true))
    assert.truthy(prompt:find('"default" with these stops:\n1. second (src/a.lua:2-2)', 1, true))
    assert.truthy(prompt:find("do not write .c-bookmarks.json", 1, true))
    assert.truthy(prompt:find("Request: how does a become b", 1, true))
  end)

  it("stores a returned group, fills anchors, skips bad stops and shows the panel", function()
    local capture = {}
    use_provider(fake_provider({
      type = "result",
      is_error = false,
      structured_output = {
        name = "tour",
        bookmarks = {
          { path = "src/a.lua", lnum = 2, end_lnum = 3, note = "# Entry\nhere" },
          { path = "src/a.lua", lnum = 6, end_lnum = 40, name = "Tail", note = "end" },
          { path = "src/missing.lua", lnum = 1, end_lnum = 1, note = "gone" },
          { path = "src/a.lua", lnum = 90, end_lnum = 91, note = "past the end" },
        },
      },
    }, capture))
    local messages = capture_notifications()
    local before = vim.api.nvim_get_current_win()

    Explain.run "tour it"
    assert.truthy(vim.wait(5000, function() return Groups.active() and Groups.active().name == "tour" end, 50))

    assert.equals(dir, capture.ctx.root)
    local group = Groups.active()
    assert.equals(2, #group.bookmarks)
    assert.equals("two", group.bookmarks[1].anchor)
    assert.same({ 6, 7 }, { group.bookmarks[2].lnum, group.bookmarks[2].end_lnum })
    assert.matches("group tour with 2 stops", messages[#messages])
    assert.matches("src/missing.lua: file not found", messages[#messages])
    assert.matches("src/a.lua:90: past the last line %(7%)", messages[#messages])
    assert.is_true(Panel.is_open())
    assert.equals(before, vim.api.nvim_get_current_win())
    assert.equals(0, Explain.running_count())
  end)

  it("replaces a group with the same name and keeps its id", function()
    Groups.create "tour"
    local id = Groups.active().id
    Marks.add { lnum = 7, name = "old" }
    local stored = Explain.apply(assert(Explain.validate {
      name = "Tour",
      bookmarks = { { path = "src/a.lua", lnum = 1, end_lnum = 1, note = "new" } },
    }))
    assert.equals(id, stored.id)
    assert.equals(1, #stored.bookmarks)
    assert.equals("new", stored.bookmarks[1].note)
    assert.equals(id, Store.get().active)
  end)

  it("rejects replies without usable stops", function()
    local group, skipped = Explain.validate { name = "x", bookmarks = { { path = "nope.lua", lnum = 1, note = "" } } }
    assert.is_nil(group)
    assert.same({ "nope.lua: file not found" }, skipped)
    assert.is_nil(Explain.validate "garbage")
  end)

  it("reports provider errors and unreadable replies", function()
    use_provider(fake_provider { type = "result", is_error = true, result = "quota exceeded" })
    local messages = capture_notifications()
    Explain.run "x"
    assert.truthy(vim.wait(5000, function() return #messages >= 2 end, 50))
    assert.matches("quota exceeded", messages[2])
    assert.is_nil(Groups.active())
  end)

  it("uses the picked model, remembers it, and resets on default", function()
    local capture = {}
    local envelope = {
      structured_output = { name = "m", bookmarks = { { path = "src/a.lua", lnum = 1, end_lnum = 1, note = "" } } },
    }
    use_provider(fake_provider(envelope, capture))
    Explain.set_model "sonnet"
    assert.equals("sonnet", Explain.model())
    assert.equals("sonnet", require("c-bookmarks.ai.prefs").get "model:fake")
    Explain.run "x"
    assert.truthy(vim.wait(5000, function() return Groups.active() ~= nil end, 50))
    assert.equals("sonnet", capture.ctx.model)
    Explain.set_model "default"
    assert.is_nil(Explain.model())
    assert.is_nil(require("c-bookmarks.ai.prefs").get "model:fake")
  end)

  it("offers the provider models in the picker and accepts a typed one", function()
    use_provider {
      name = "fake",
      models = { "fast", "slow" },
      command = function() return { "true" } end,
      parse = Providers.claude.parse,
    }
    local seen
    local select, input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, _, callback)
      seen = items
      callback(items[3])
    end
    Explain.pick_model()
    assert.same({ "default", "fast", "slow", "other…" }, seen)
    assert.equals("slow", Explain.model())
    vim.ui.select = function(items, _, callback) callback(items[#items]) end
    vim.ui.input = function(_, callback) callback "typed-model" end
    Explain.pick_model()
    assert.equals("typed-model", Explain.model())
    vim.ui.select, vim.ui.input = select, input
  end)

  it("shows a busy line in the panel while a request runs", function()
    use_provider { name = "slow", command = function() return { "sleep", "30" } end, parse = Providers.claude.parse }
    capture_notifications()
    Explain.run "trace the checkout flow"
    assert.is_true(Panel.is_open())
    local lines = vim.api.nvim_buf_get_lines(Panel.buf(), 0, -1, false)
    assert.matches("explaining with slow", lines[1])
    assert.truthy(lines[2]:find("trace the checkout flow", 1, true))
    assert.are_not.equal("", Explain.status())
    Explain.cancel()
    assert.truthy(vim.wait(5000, function() return Explain.running_count() == 0 end, 50))
    assert.equals("", Explain.status())
    assert.is_nil(vim.api.nvim_buf_get_lines(Panel.buf(), 0, 1, false)[1]:find("explaining", 1, true))
  end)

  it("cancels a running request", function()
    use_provider { name = "slow", command = function() return { "sleep", "30" } end, parse = Providers.claude.parse }
    local messages = capture_notifications()
    Explain.run "x"
    assert.equals(1, Explain.running_count())
    assert.equals(1, Explain.cancel())
    assert.truthy(vim.wait(5000, function() return Explain.running_count() == 0 end, 50))
    assert.matches("cancelled", messages[#messages])
    assert.is_nil(Groups.active())
  end)
end)

describe("claude provider", function()
  it("puts the prompt before the variadic flags and asks for the schema", function()
    local cmd = Providers.claude.command {
      root = "/r",
      prompt = "hello",
      model = "sonnet",
      extra_args = { "--verbose" },
      schema = Providers.group_schema,
    }
    assert.same({ "claude", "-p", "hello" }, { cmd[1], cmd[2], cmd[3] })
    assert.truthy(vim.list_contains(cmd, "--json-schema"))
    assert.truthy(vim.list_contains(cmd, "Read,Glob,Grep"))
    assert.equals("--verbose", cmd[#cmd])
    assert.truthy(vim.list_contains(cmd, "sonnet"))
  end)

  it("leaves the schema out for text answers and reads the result text", function()
    local cmd = Providers.claude.command { root = "/r", prompt = "hello", extra_args = {} }
    assert.is_false(vim.list_contains(cmd, "--json-schema"))
    assert.equals("# Hi\nthere", (Providers.claude.answer(vim.json.encode { result = "  # Hi\nthere  " })))
    local answer, err = Providers.claude.answer(vim.json.encode { is_error = true, result = "nope" })
    assert.is_nil(answer)
    assert.equals("nope", err)
    assert.is_nil(Providers.claude.answer(vim.json.encode { result = "" }))
    assert.is_nil(Providers.claude.answer "garbage")
  end)

  it("prefers structured output, then JSON in the text", function()
    local structured =
      Providers.claude.parse(vim.json.encode { structured_output = { name = "s", bookmarks = {} }, result = "ignored" })
    assert.equals("s", structured.name)
    local fenced =
      Providers.claude.parse(vim.json.encode { result = 'Here you go:\n```json\n{"name": "f", "bookmarks": []}\n```' })
    assert.equals("f", fenced.name)
    local bare = Providers.claude.parse(vim.json.encode { result = 'sure {"name": "b", "bookmarks": []} done' })
    assert.equals("b", bare.name)
    local none, err = Providers.claude.parse(vim.json.encode { result = "no json here" })
    assert.is_nil(none)
    assert.matches("no JSON object", err)
    local garbage, garbage_err = Providers.claude.parse "not json"
    assert.is_nil(garbage)
    assert.matches("unreadable", garbage_err)
  end)
end)
