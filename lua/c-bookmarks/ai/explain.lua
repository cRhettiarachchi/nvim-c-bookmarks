---Headless walkthroughs: prompt, run a provider, check the result, store the group.
local Config = require "c-bookmarks.config"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Model = require "c-bookmarks.model"
local Prefs = require "c-bookmarks.ai.prefs"
local Progress = require "c-bookmarks.ai.progress"
local Providers = require "c-bookmarks.ai.providers"
local Skill = require "c-bookmarks.skill"
local Store = require "c-bookmarks.store"

local M = {}

local TIMEOUT_EXIT_CODE = 124
local DEFAULT_MODEL = "default"
local OTHER_MODEL = "other…"

---@type table<integer, vim.SystemObj>
local running = {}
local next_id = 0
local session = {} ---@type { provider: string?, model: string? } picked this session or restored

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

---The picked provider, else the configured one; ask shares it.
---@return CBookmarks.Provider
function M.provider()
  local cfg = Config.options.ai
  local name = session.provider or cfg.provider
  local found = Providers.get(name, cfg.providers)
  if not found then error("c-bookmarks: unknown ai provider " .. tostring(name)) end

  return found
end

local provider = M.provider

local function prefs_key() return "model:" .. provider().name end

-- Provider ------------------------------------------------------------------

---Providers offered by the picker: built-ins, then custom ones.
---@return string[]
function M.providers()
  local names = vim.deepcopy(Providers.names)
  local custom = vim.tbl_keys(Config.options.ai.providers or {})
  table.sort(custom)
  for _, name in ipairs(custom) do
    if not vim.list_contains(names, name) then names[#names + 1] = name end
  end

  return names
end

---Model remembered for the active provider.
local function restore_model()
  local ok, saved = pcall(Prefs.get, prefs_key())
  session.model = ok and saved or nil
end

---Switches and remembers the provider; its own model choice comes back with it.
---@param name? string
---@return boolean switched
function M.set_provider(name)
  name = vim.trim(name or "")
  if not Providers.get(name, Config.options.ai.providers) then
    notify("unknown ai provider " .. name, vim.log.levels.WARN)
    return false
  end

  session.provider = name
  Prefs.set("provider", name)
  restore_model()
  notify(string.format("provider: %s (%s)", name, M.model() or DEFAULT_MODEL))
  return true
end

---Chooses the provider through vim.ui.select.
function M.pick_provider()
  local current = provider().name
  vim.ui.select(M.providers(), {
    prompt = "AI provider",
    format_item = function(item) return (item == current and "● " or "  ") .. item end,
  }, function(choice)
    if choice ~= nil then M.set_provider(choice) end
  end)
end

-- Model ---------------------------------------------------------------------

---Models offered by the picker: the configured list, else the provider's.
---@return string[]
function M.models()
  local configured = Config.options.ai.models
  if configured and #configured > 0 then return configured end

  local models = provider().models
  if type(models) == "function" then models = models() end

  return models or {}
end

---The model for the next run: picked choice, else config, else the provider default.
---@return string?
function M.model()
  if session.model then return session.model end
  -- ai.model belongs to the configured provider only
  if provider().name == Config.options.ai.provider then return Config.options.ai.model end

  return nil
end

---Sets and remembers the model; "default" or blank returns to the provider default.
---@param name? string
function M.set_model(name)
  name = vim.trim(name or "")
  if name == "" or name == DEFAULT_MODEL then name = nil end

  session.model = name
  Prefs.set(prefs_key(), name)
  notify("model: " .. (M.model() or DEFAULT_MODEL))
end

---Chooses the model through vim.ui.select.
function M.pick_model()
  local current = M.model() or DEFAULT_MODEL
  local items = { DEFAULT_MODEL }
  vim.list_extend(items, M.models())
  items[#items + 1] = OTHER_MODEL
  vim.ui.select(items, {
    prompt = "Model for " .. provider().name,
    format_item = function(item) return (item == current and "● " or "  ") .. item end,
  }, function(choice)
    if choice == nil then return end
    if choice ~= OTHER_MODEL then return M.set_model(choice) end

    vim.ui.input({ prompt = "Model: ", default = session.model }, function(input)
      if input ~= nil then M.set_model(input) end
    end)
  end)
end

-- Prompt --------------------------------------------------------------------

---@class CBookmarks.Focus
---@field path string
---@field lnum integer
---@field end_lnum integer

---What the user is looking at, as a hint for the model.
---@return CBookmarks.Focus?
function M.focus()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = Marks.buf_path(bufnr)
  if not path then return nil end

  local lnum, end_lnum = Marks.selected_lines()
  return { path = path, lnum = lnum, end_lnum = end_lnum }
end

---@param request string
---@param ctx { root: string, focus?: CBookmarks.Focus, group?: CBookmarks.Group }
---@return string
function M.build_prompt(request, ctx)
  local parts = {
    "You are producing a code walkthrough for the nvim-c-bookmarks Neovim plugin.",
    "Read the format rules in " .. Skill.path() .. " first.",
    "Follow its 'Writing a walkthrough' section to choose the stops, their order, their ranges and their notes, "
      .. "with one exception: do not write .c-bookmarks.json or any other file. "
      .. "Return the group as JSON matching the schema you were given: "
      .. '{"name", "bookmarks": [{"name", "path", "lnum", "end_lnum", "note", "anchor"}]}.',
    "Use only Read, Glob and Grep. Paths are relative to "
      .. ctx.root
      .. ". Read every file you cite so lnum, end_lnum and anchor are exact.",
  }
  if ctx.focus then
    parts[#parts + 1] =
      string.format("The user is looking at %s lines %d-%d.", ctx.focus.path, ctx.focus.lnum, ctx.focus.end_lnum)
  end

  if ctx.group and #ctx.group.bookmarks > 0 then
    local stops = {}
    for i, bookmark in ipairs(ctx.group.bookmarks) do
      stops[#stops + 1] =
        string.format("%d. %s (%s:%d-%d)", i, Model.label(bookmark), bookmark.path, bookmark.lnum, bookmark.end_lnum)
    end

    parts[#parts + 1] =
      string.format("The active group is %q with these stops:\n%s", ctx.group.name, table.concat(stops, "\n"))
    parts[#parts + 1] = "Create a new group unless the request is about this group; "
      .. "then return its name with the complete updated list of stops."
  end

  parts[#parts + 1] = "Request: " .. request
  return table.concat(parts, "\n\n")
end

-- Result --------------------------------------------------------------------

---Repairs the returned group against the real files.
---@param raw any
---@return CBookmarks.Group?, string[] skipped reasons
function M.validate(raw)
  local group = type(raw) == "table" and Model.normalize({ groups = { raw } }).groups[1] or nil
  if not group then return nil, { "no group in the reply" } end

  local kept, skipped, cache = {}, {}, {}
  for _, bookmark in ipairs(group.bookmarks) do
    local absolute = Store.abspath(bookmark.path)
    local lines = cache[absolute]
    if lines == nil then
      lines = vim.uv.fs_stat(absolute) and vim.fn.readfile(absolute) or false
      cache[absolute] = lines
    end

    if not lines then
      skipped[#skipped + 1] = bookmark.path .. ": file not found"
    elseif bookmark.lnum > #lines then
      skipped[#skipped + 1] = string.format("%s:%d: past the last line (%d)", bookmark.path, bookmark.lnum, #lines)
    else
      bookmark.end_lnum = math.min(bookmark.end_lnum, #lines)
      if bookmark.anchor == "" then bookmark.anchor = lines[bookmark.lnum] end

      kept[#kept + 1] = bookmark
    end
  end

  group.bookmarks = kept
  if #kept == 0 then return nil, skipped end

  return group, skipped
end

---Stores the group, replacing one with the same name, and makes it active.
---@param group CBookmarks.Group
---@return CBookmarks.Group stored
function M.apply(group)
  return Store.update(function(data)
    local existing = Model.find_group_by_name(data, group.name)
    if existing then
      existing.bookmarks = group.bookmarks
      data.active = existing.id
      return existing
    end

    while Model.find_group(data, group.id) do
      group.id = Model.new_id "g"
    end

    table.insert(data.groups, group)
    data.active = group.id
    return group
  end)
end

-- Running -------------------------------------------------------------------

local function finish(id, result)
  local proc = running[id]
  running[id] = nil
  Progress.stop(id)
  if not proc then return end

  if result.code == TIMEOUT_EXIT_CODE then
    notify("explain timed out", vim.log.levels.ERROR)
    return
  end

  if result.signal ~= 0 then
    notify "explain cancelled"
    return
  end

  if result.code ~= 0 then
    local detail = Providers.failure(provider(), result)
    notify(string.format("explain failed (exit %d): %s", result.code, detail), vim.log.levels.ERROR)
    return
  end

  local raw, err = provider().parse(result.stdout or "")
  if not raw then
    notify("explain: " .. err, vim.log.levels.ERROR)
    return
  end

  local group, skipped = M.validate(raw)
  if not group then
    notify("explain: nothing usable in the reply\n" .. table.concat(skipped, "\n"), vim.log.levels.ERROR)
    return
  end

  local stored = M.apply(group)
  local message = string.format("group %s with %d stops", stored.name, #stored.bookmarks)
  if #skipped > 0 then message = message .. "\nskipped: " .. table.concat(skipped, "\n") end

  notify(message)
end

---Runs the provider in the background for a request.
---@param request string
---@param opts? { focus?: CBookmarks.Focus }
---@return integer id
function M.run(request, opts)
  local prov = provider()
  local cfg = Config.options.ai
  local root = Store.root()
  local prompt = M.build_prompt(request, { root = root, focus = opts and opts.focus, group = Groups.active() })
  local model = M.model()
  local cmd = prov.command {
    root = root,
    prompt = prompt,
    model = model,
    extra_args = cfg.extra_args or {},
    schema = Providers.group_schema,
  }

  next_id = next_id + 1
  local id = next_id
  running[id] = vim.system(
    cmd,
    { cwd = root, text = true, timeout = cfg.timeout_ms },
    vim.schedule_wrap(function(result) finish(id, result) end)
  )
  Progress.start(id, { request = request, provider = prov.name })
  notify(string.format("explaining with %s (%s)…", prov.name, model or DEFAULT_MODEL))
  if cfg.open_panel then require("c-bookmarks.panel").open { focus = false } end

  return id
end

---Asks for a request when none is given, then runs it.
---@param request? string
function M.explain(request)
  local focus = M.focus()
  if request and vim.trim(request) ~= "" then return M.run(vim.trim(request), { focus = focus }) end

  vim.ui.input({ prompt = "Explain: " }, function(input)
    if input and vim.trim(input) ~= "" then M.run(vim.trim(input), { focus = focus }) end
  end)
end

---@return integer count of runs stopped
function M.cancel()
  local count = 0
  for _, proc in pairs(running) do
    proc:kill(15)
    count = count + 1
  end

  if count == 0 then notify "nothing to cancel" end

  return count
end

---@return integer
function M.running_count() return vim.tbl_count(running) end

---Spinner text for a status line, empty when idle.
---@return string
function M.status() return Progress.status() or "" end

function M.setup()
  local ok, saved = pcall(Prefs.get, "provider")
  local known = ok and type(saved) == "string" and Providers.get(saved, Config.options.ai.providers)
  session.provider = known and saved or nil
  restore_model()
end

return M
