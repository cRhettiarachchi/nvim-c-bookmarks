local Progress = require "c-bookmarks.ai.progress"

describe("ai progress", function()
  after_each(function() Progress.reset() end)

  it("reports the oldest job with a spinner and elapsed time", function()
    assert.is_nil(Progress.status())
    Progress.start(1, { request = "first", provider = "claude" })
    Progress.start(2, { request = "second", provider = "claude" })
    assert.equals(2, Progress.count())
    assert.equals("first", Progress.current().request)
    assert.matches("^[^ ]+ explaining with claude · %d+s · 2 running$", Progress.status())
    Progress.stop(1)
    assert.matches("^[^ ]+ explaining with claude · %d+s$", Progress.status())
    Progress.stop(2)
    assert.is_nil(Progress.status())
  end)

  it("ticks an autocmd while jobs run", function()
    local ticks = 0
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("CBookmarksProgressSpec", { clear = true }),
      pattern = "CBookmarksProgress",
      callback = function() ticks = ticks + 1 end,
    })
    Progress.start(1, { request = "x", provider = "p" })
    assert.truthy(vim.wait(1000, function() return ticks >= 3 end, 20))
    Progress.stop(1)
    local settled = ticks
    vim.wait(200)
    assert.equals(settled, ticks)
  end)
end)
