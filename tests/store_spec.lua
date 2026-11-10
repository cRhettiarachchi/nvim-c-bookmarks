local helpers = require "tests.helpers"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"

local function capture_sources()
  local sources = {}
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("CBookmarksSpec", { clear = true }),
    pattern = "CBookmarksChanged",
    callback = function(ev) sources[#sources + 1] = ev.data.source end,
  })
  return sources
end

describe("store", function()
  local dir

  before_each(function() dir = helpers.project() end)

  after_each(function()
    Store.reset()
    helpers.cleanup(dir)
  end)

  it("writes readable json and reads it back", function()
    Store.update(function(data)
      local walk = Model.add_group(data, "walk")
      Model.add_bookmark(walk, { path = "src/a.lua", lnum = 2, end_lnum = 4, name = "start", note = '# hi\nsay "two"' })
    end)

    local text = helpers.read(dir .. "/.c-bookmarks.json")
    assert.truthy(text:find('"version": 1', 1, true))
    assert.truthy(text:find('"path": "src/a.lua"', 1, true))
    assert.truthy(text:find('"note": "# hi\\nsay \\"two\\""', 1, true))
    assert.truthy(text:find('"id": "b_', 1, true) < text:find('"path":', 1, true))
    assert.same(Store.get(), Model.normalize(vim.json.decode(text)))
  end)

  it("adds the file to .git/info/exclude once", function()
    Store.update(function(data) Model.add_group(data, "walk") end)
    Store.update(function(data) Model.add_group(data, "other") end)

    local exclude = helpers.read(dir .. "/.git/info/exclude")
    local _, count = exclude:gsub("/%.c%-bookmarks%.json\n", "")
    assert.equals(1, count)
    assert.truthy(exclude:find("/.c-bookmarks.json.tmp", 1, true))
  end)

  it("reloads when another process writes the file", function()
    Store.update(function(data) Model.add_group(data, "walk") end)
    local sources = capture_sources()

    local outside = Model.empty()
    Model.add_bookmark(assert(Model.add_group(outside, "from-ai")), { path = "x.lua", lnum = 1 })
    vim.fn.writefile(vim.split(Store.encode(outside), "\n"), dir .. "/.c-bookmarks.json")

    assert.truthy(vim.wait(3000, function() return sources[1] == "file" end, 50))
    assert.equals("from-ai", Model.active_group(Store.get()).name)
  end)

  it("ignores its own writes", function()
    local sources = capture_sources()
    Store.update(function(data) Model.add_group(data, "walk") end)
    vim.wait(500)
    assert.same({ "local" }, sources)
  end)

  it("keeps the last good data when the file breaks", function()
    Store.update(function(data) Model.add_group(data, "walk") end)
    local sources = capture_sources()
    vim.fn.writefile({ "{ not json" }, dir .. "/.c-bookmarks.json")
    vim.wait(500)
    assert.same({}, sources)
    assert.equals("walk", Model.active_group(Store.get()).name)
  end)

  it("maps paths against the root", function()
    assert.equals("src/a.lua", Store.relpath(dir .. "/src/a.lua"))
    assert.equals("/elsewhere/b.lua", Store.relpath "/elsewhere/b.lua")
    assert.equals(dir .. "/src/a.lua", Store.abspath "src/a.lua")
    assert.equals("/elsewhere/b.lua", Store.abspath "/elsewhere/b.lua")
  end)

  it("only writes pending changes on flush", function()
    Store.update(function(data) Model.add_group(data, "walk") end, { persist = false })
    assert.is_nil(vim.uv.fs_stat(dir .. "/.c-bookmarks.json"))
    Store.flush()
    assert.truthy(vim.uv.fs_stat(dir .. "/.c-bookmarks.json"))
  end)
end)
