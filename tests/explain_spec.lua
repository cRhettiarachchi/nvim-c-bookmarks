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
    require("c-bookmarks.ai.prefs").set("provider", nil)
    Explain.setup()
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

  it("switches provider, remembers it, and keeps a model per provider", function()
    use_provider(fake_provider {})
    Config.options.ai.providers.other = { name = "other", command = function() return { "true" } end }
    Config.options.ai.model = "fake-model"
    assert.same({ "claude", "codex", "opencode", "fake", "other" }, Explain.providers())
    assert.equals("fake-model", Explain.model())
    assert.is_true(Explain.set_provider "other")
    assert.equals("other", Explain.provider().name)
    assert.is_nil(Explain.model())
    Explain.set_model "big"
    assert.is_true(Explain.set_provider "fake")
    assert.equals("fake-model", Explain.model())
    assert.is_false(Explain.set_provider "nope")
    assert.equals("fake", Explain.provider().name)
    Explain.set_provider "other"
    Explain.setup()
    assert.equals("other", Explain.provider().name)
    assert.equals("big", Explain.model())
    Explain.set_model "default"
  end)

  it("reports the provider's own error over stderr when the run fails", function()
    local messages = capture_notifications()
    use_provider {
      name = "fake",
      command = function()
        return {
          "sh",
          "-c",
          [[printf '{"type":"turn.failed","error":{"message":"quota gone"}}'; echo noise >&2; exit 1]],
        }
      end,
      parse = Providers.codex.parse,
      error = Providers.codex.error,
    }
    Explain.run "x"
    assert.truthy(vim.wait(5000, function() return Explain.running_count() == 0 end, 50))
    assert.matches("exit 1%): quota gone", messages[#messages])
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
    local braces = Providers.extract_json 'Done: {"name": "x", "note": "use `}` or `{`"} ok'
    assert.equals("use `}` or `{`", braces.note)
    local none, err = Providers.claude.parse(vim.json.encode { result = "no json here" })
    assert.is_nil(none)
    assert.matches("no JSON object", err)
    local garbage, garbage_err = Providers.claude.parse "not json"
    assert.is_nil(garbage)
    assert.matches("unreadable", garbage_err)
  end)
end)

---@param events table[]
---@return string
local function jsonl(events) return table.concat(vim.tbl_map(vim.json.encode, events), "\n") end

describe("codex provider", function()
  it("runs read-only with a strict schema file and the prompt last", function()
    local cmd = Providers.codex.command {
      root = "/r",
      prompt = "-hello",
      model = "gpt-5.5",
      extra_args = { "--verbose" },
      schema = Providers.group_schema,
    }
    assert.same({ "codex", "exec", "--json" }, { cmd[1], cmd[2], cmd[3] })
    assert.truthy(vim.list_contains(cmd, "read-only"))
    assert.truthy(vim.list_contains(cmd, "gpt-5.5"))
    assert.same({ "--verbose", "--", "-hello" }, { cmd[#cmd - 2], cmd[#cmd - 1], cmd[#cmd] })
    local flag = assert(vim.iter(ipairs(cmd)):find(function(_, arg) return arg == "--output-schema" end))
    local path = cmd[flag + 1]
    local schema = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.same({ "anchor", "end_lnum", "lnum", "name", "note", "path" }, schema.properties.bookmarks.items.required)
    assert.is_false(vim.list_contains(Providers.codex.command { root = "/r", prompt = "q" }, "--output-schema"))
  end)

  it("reads the last agent message and reports failures", function()
    local stdout = jsonl {
      { type = "thread.started" },
      { type = "item.completed", item = { type = "error", message = "just a warning" } },
      { type = "item.completed", item = { type = "agent_message", text = "looking" } },
      { type = "item.completed", item = { type = "agent_message", text = '  {"name": "c", "bookmarks": []}  ' } },
      { type = "turn.completed" },
    }
    assert.equals("c", Providers.codex.parse(stdout).name)
    assert.equals('{"name": "c", "bookmarks": []}', (Providers.codex.answer(stdout)))
    assert.is_nil(Providers.codex.error(stdout))
    local api_error = vim.json.encode { type = "error", error = { message = "model not supported" } }
    local failed =
      jsonl { { type = "error", message = api_error }, { type = "turn.failed", error = { message = api_error } } }
    local answer, err = Providers.codex.answer(failed)
    assert.is_nil(answer)
    assert.equals("model not supported", err)
    assert.equals("model not supported", Providers.codex.error(failed))
    assert.matches("no result", select(2, Providers.codex.answer(jsonl { { type = "turn.completed" } })))
    assert.matches("unreadable", select(2, Providers.codex.answer "garbage"))
  end)
end)

describe("opencode provider", function()
  it("runs the read-only plan agent and puts the schema in the prompt", function()
    local cmd = Providers.opencode.command {
      root = "/r",
      prompt = "hello",
      model = "openai/gpt-5.5",
      extra_args = {},
      schema = Providers.group_schema,
    }
    assert.same({ "opencode", "run", "--format", "json", "--agent", "plan" }, vim.list_slice(cmd, 1, 6))
    assert.truthy(vim.list_contains(cmd, "openai/gpt-5.5"))
    assert.equals("--", cmd[#cmd - 1])
    assert.matches("^hello\n\nReply with only a JSON object", cmd[#cmd])
    local plain = Providers.opencode.command { root = "/r", prompt = "hello" }
    assert.equals("hello", plain[#plain])
  end)

  it("reads the last text part and reports error events", function()
    local stdout = jsonl {
      { type = "step_start", part = { type = "step-start" } },
      { type = "text", part = { type = "text", text = "let me look" } },
      { type = "tool_use", part = { type = "tool" } },
      { type = "text", part = { type = "text", text = '```json\n{"name": "o", "bookmarks": []}\n```' } },
      { type = "step_finish" },
    }
    assert.equals("o", Providers.opencode.parse(stdout).name)
    assert.is_nil(Providers.opencode.error(stdout))
    local failed = jsonl { { type = "error", error = { name = "UnknownError", data = { message = "server error" } } } }
    local answer, err = Providers.opencode.answer(failed)
    assert.is_nil(answer)
    assert.equals("server error", err)
    assert.equals("server error", Providers.opencode.error(failed))
  end)
end)

describe("provider failures", function()
  it("prefer the reported error, then stderr, then stdout", function()
    local failed = vim.json.encode { is_error = true, result = "auth expired" }
    assert.equals("auth expired", Providers.failure(Providers.claude, { stdout = failed, stderr = "noise" }))
    assert.equals("boom", Providers.failure(Providers.claude, { stdout = "", stderr = " boom\n" }))
    assert.equals("out", Providers.failure({ name = "x" }, { stdout = "out", stderr = "" }))
  end)

  it("strict_schema requires every property and leaves the original alone", function()
    local strict = Providers.strict_schema(Providers.group_schema)
    assert.same({ "bookmarks", "name" }, strict.required)
    assert.same({ "path", "lnum", "end_lnum", "note" }, Providers.group_schema.properties.bookmarks.items.required)
  end)
end)
