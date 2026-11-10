local helpers = require "tests.helpers"
local Ask = require "c-bookmarks.ai.ask"
local Config = require "c-bookmarks.config"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Providers = require "c-bookmarks.ai.providers"
local Store = require "c-bookmarks.store"
local Commands = require "c-bookmarks.commands"

---A provider that prints a canned claude envelope.
local function fake_provider(envelope, capture)
  return {
    name = "fake",
    command = function(ctx)
      if capture then capture.ctx = ctx end

      return { "printf", "%s", vim.json.encode(envelope) }
    end,
    parse = Providers.claude.parse,
    answer = Providers.claude.answer,
  }
end

local slow_provider = {
  name = "slow",
  command = function() return { "sleep", "30" } end,
  parse = Providers.claude.parse,
  answer = Providers.claude.answer,
}

local function use_provider(provider)
  Config.options.ai.providers = { fake = provider }
  Config.options.ai.provider = "fake"
  Config.options.ai.state_file = vim.fn.tempname() .. "/ai.json"
end

local function capture_notifications()
  local messages = {}
  vim.notify = function(message) messages[#messages + 1] = message end
  return messages
end

local function float_lines()
  local win = Ask.win()
  assert.truthy(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function wait_for_answer()
  return vim.wait(5000, function() return Ask.last() ~= nil end, 50)
end

local function wait_for_idle()
  return vim.wait(5000, function() return Ask.running_count() == 0 end, 50)
end

describe("ask", function()
  local dir, original_notify, original_input

  before_each(function()
    dir = helpers.project()
    helpers.write(dir, "src/a.lua", { "one", "two", "three", "four", "five", "six", "seven" })
    require("c-bookmarks").setup { storage = { root = function() return dir end } }
    vim.cmd.edit(dir .. "/src/a.lua")
    original_notify, original_input = vim.notify, vim.ui.input
  end)

  after_each(function()
    vim.notify, vim.ui.input = original_notify, original_input
    Ask.reset()
    wait_for_idle()
    require("c-bookmarks.ai.progress").reset()
    vim.cmd "silent! %bwipeout!"
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("builds a prompt with the root and the selected code", function()
    local context = Ask.context { lnum = 2, end_lnum = 3 }
    assert.equals("src/a.lua", context.path)
    assert.same({ "two", "three" }, context.lines)
    local prompt = Ask.build_prompt("what is this", { root = dir, context = context })
    assert.truthy(prompt:find("Project root: " .. dir, 1, true))
    assert.truthy(prompt:find("src/a.lua lines 2-3:\n```" .. context.filetype .. "\ntwo\nthree\n```", 1, true))
    assert.truthy(prompt:find("Question: what is this", 1, true))
    assert.is_nil(Ask.build_prompt("x", { root = dir }):find("selected", 1, true))
  end)

  it("lengthens the fence when the code holds one", function()
    local context = Ask.context { lnum = 1, end_lnum = 1 }
    context.lines = { "```lua", "x", "```" }
    local prompt = Ask.build_prompt("q", { root = dir, context = context })
    assert.truthy(prompt:find("\n````" .. context.filetype .. "\n```lua\nx\n```\n````\n", 1, true))
  end)

  it("shows the answer in a float and bookmarks the code with the answer as note", function()
    local capture = {}
    use_provider(fake_provider({ type = "result", is_error = false, result = "# Two and three\nThey count." }, capture))
    local messages = capture_notifications()
    local source = vim.api.nvim_get_current_win()
    Ask.run("what is this", Ask.context { lnum = 2, end_lnum = 3 })
    local win = Ask.win()
    assert.truthy(win)
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.matches("asking with fake", float_lines()[1])
    assert.truthy(float_lines()[2]:find("src/a.lua:2-3", 1, true))
    assert.truthy(wait_for_answer())
    assert.is_nil(capture.ctx.schema)
    assert.equals(win, Ask.win())
    assert.same({ "# Two and three", "They count." }, float_lines())
    assert.truthy(vim.inspect(vim.api.nvim_win_get_config(win).footer):find("b bookmark", 1, true))

    local bookmark = Ask.bookmark()
    assert.truthy(bookmark)
    assert.same({ 2, 3 }, { bookmark.lnum, bookmark.end_lnum })
    assert.equals("# Two and three\nThey count.", bookmark.note)
    assert.equals("Two and three", Model.label(bookmark))
    assert.equals("default", Groups.active().name)
    assert.is_nil(Ask.win())
    assert.equals(source, vim.api.nvim_get_current_win())
    assert.matches("bookmarked src/a.lua:2%-3 in default", messages[#messages])
  end)

  it("bookmarks the last answer after the float is gone", function()
    use_provider(fake_provider { result = "# Later\nstill here" })
    capture_notifications()
    Ask.run("q", Ask.context { lnum = 5, end_lnum = 5 })
    assert.truthy(wait_for_answer())
    Ask.close()
    local bookmark = Ask.bookmark()
    assert.truthy(bookmark)
    assert.same({ 5, 5, "# Later\nstill here" }, { bookmark.lnum, bookmark.end_lnum, bookmark.note })
  end)

  it("answers a plain question and refuses to bookmark it", function()
    use_provider(fake_provider { result = "# Hi\nhello" })
    local messages = capture_notifications()
    Ask.run "hello?"
    assert.truthy(wait_for_answer())
    assert.is_nil(Ask.last().context)
    assert.is_nil(Ask.bookmark())
    assert.matches("no code selection", messages[#messages])
    assert.truthy(Ask.win())
    assert.is_nil(vim.inspect(vim.api.nvim_win_get_config(Ask.win()).footer):find("bookmark", 1, true))
  end)

  it("closing the float cancels the run and keeps the reply away", function()
    use_provider(slow_provider)
    Ask.run "x"
    assert.equals(1, Ask.running_count())
    Ask.close()
    assert.is_nil(Ask.win())
    assert.truthy(wait_for_idle())
    assert.is_nil(Ask.last())
    assert.is_nil(Ask.win())
  end)

  it("q closes the float", function()
    use_provider(slow_provider)
    Ask.run "x"
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_nil(Ask.win())
    assert.truthy(wait_for_idle())
  end)

  it("a new question replaces the float and cancels the old run", function()
    use_provider(slow_provider)
    Ask.run "first"
    local first = Ask.win()
    assert.truthy(first)
    Ask.run "second"
    assert.are_not.equal(first, Ask.win())
    assert.is_false(vim.api.nvim_win_is_valid(first))
    assert.truthy(vim.wait(5000, function() return Ask.running_count() == 1 end, 50))
  end)

  it("shows provider errors in the float", function()
    use_provider(fake_provider { is_error = true, result = "quota exceeded" })
    local messages = capture_notifications()
    Ask.run "x"
    assert.truthy(wait_for_idle())
    assert.matches("quota exceeded", float_lines()[1])
    assert.matches("quota exceeded", messages[#messages])
    assert.is_nil(Ask.last())
  end)

  it("attaches a visual selection and turns an empty input into the default question", function()
    local capture = {}
    use_provider(fake_provider({ result = "# ok\nfine" }, capture))
    local prompt
    vim.ui.input = function(opts, callback)
      prompt = opts.prompt
      callback ""
    end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd "normal! Vj"
    Ask.ask()
    assert.equals("Ask about src/a.lua:2-3: ", prompt)
    assert.truthy(wait_for_answer())
    assert.equals("Explain this code", Ask.last().question)
    assert.truthy(capture.ctx.prompt:find("lines 2-3", 1, true))
    assert.equals("n", vim.fn.mode())
  end)

  it("drops an empty question that has no code", function()
    use_provider(fake_provider { result = "# no" })
    vim.ui.input = function(opts, callback)
      assert.equals("Ask: ", opts.prompt)
      callback ""
    end
    Ask.ask()
    assert.is_nil(Ask.win())
    assert.equals(0, Ask.running_count())
  end)

  it("explains the bookmark under the cursor, else the cursor line", function()
    local capture = {}
    use_provider(fake_provider({ result = "# b\nx" }, capture))
    Marks.add { lnum = 4, end_lnum = 6 }
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    Ask.explain_selection()
    assert.truthy(wait_for_answer())
    assert.truthy(capture.ctx.prompt:find("lines 4-6", 1, true))
    assert.same({ 4, 6 }, { Ask.last().context.lnum, Ask.last().context.end_lnum })
    Ask.close()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    Ask.explain_selection()
    assert.truthy(vim.wait(5000, function() return Ask.last().context.lnum == 1 end, 50))
    assert.truthy(capture.ctx.prompt:find("lines 1-1", 1, true))
  end)

  it("runs from the command with a range", function()
    local capture = {}
    use_provider(fake_provider({ result = "# r\ny" }, capture))
    Commands.run { args = "ask", range = 2, line1 = 2, line2 = 3 }
    assert.truthy(wait_for_answer())
    assert.equals("Explain this code", Ask.last().question)
    assert.truthy(capture.ctx.prompt:find("lines 2-3", 1, true))
    Ask.close()
    Commands.run { args = "ask why six", range = 1, line1 = 6, line2 = 6 }
    assert.truthy(vim.wait(5000, function() return Ask.last().question == "why six" end, 50))
    assert.truthy(capture.ctx.prompt:find("lines 6-6", 1, true))
  end)
end)
