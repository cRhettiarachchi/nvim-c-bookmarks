local Config = require "c-bookmarks.config"
local Prefs = require "c-bookmarks.ai.prefs"

describe("ai prefs", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    Config.setup { ai = { state_file = dir .. "/nested/ai.json" } }
  end)

  after_each(function()
    Config.setup()
    vim.fn.delete(dir, "rf")
  end)

  it("round-trips values through the state file", function()
    assert.is_nil(Prefs.get "model:claude")
    assert.is_true(Prefs.set("model:claude", "sonnet"))
    assert.equals("sonnet", Prefs.get "model:claude")
    assert.truthy(vim.uv.fs_stat(dir .. "/nested/ai.json"))
    Prefs.set("model:claude", nil)
    assert.is_nil(Prefs.get "model:claude")
    assert.same({}, Prefs.load())
  end)

  it("ignores a broken state file", function()
    vim.fn.mkdir(dir .. "/nested", "p")
    vim.fn.writefile({ "{ nope" }, dir .. "/nested/ai.json")
    assert.same({}, Prefs.load())
  end)
end)
