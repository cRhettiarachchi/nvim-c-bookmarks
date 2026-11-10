---The JSON file at the project root: single source of truth and the AI contract.
local Config = require "c-bookmarks.config"
local Model = require "c-bookmarks.model"

local M = {}
local uv = vim.uv

local RELOAD_DELAY_MS = 150

local state = {
  root = nil, ---@type string?
  path = nil, ---@type string?
  data = nil, ---@type CBookmarks.Data?
  dirty = false,
  known_text = nil, ---@type string? file content this process last wrote or read
  watcher = nil, ---@type uv.uv_fs_event_t?
  timer = nil, ---@type uv.uv_timer_t?
}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

function M.root() return vim.fs.normalize(Config.options.storage.root()) end

function M.path() return vim.fs.joinpath(M.root(), Config.options.storage.filename) end

-- JSON ----------------------------------------------------------------------

local KEY_ORDER = {
  version = 1,
  active = 2,
  groups = 3,
  id = 1,
  name = 2,
  path = 3,
  lnum = 4,
  end_lnum = 5,
  note = 6,
  anchor = 7,
  created_at = 8,
  updated_at = 9,
  bookmarks = 10,
}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(text)
  local escaped = text:gsub('[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", c:byte()) end)
  return '"' .. escaped .. '"'
end

local function sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys, function(a, b)
    local order_a, order_b = KEY_ORDER[a] or 100, KEY_ORDER[b] or 100
    if order_a ~= order_b then return order_a < order_b end

    return tostring(a) < tostring(b)
  end)
  return keys
end

local encode_value

local function encode_table(tbl, indent, out)
  local pad = indent .. "  "
  if vim.islist(tbl) then
    if #tbl == 0 then
      out[#out + 1] = "[]"
      return
    end

    out[#out + 1] = "[\n"
    for i, value in ipairs(tbl) do
      out[#out + 1] = pad
      encode_value(value, pad, out)
      out[#out + 1] = i < #tbl and ",\n" or "\n"
    end

    out[#out + 1] = indent .. "]"
    return
  end

  local keys = sorted_keys(tbl)
  if #keys == 0 then
    out[#out + 1] = "{}"
    return
  end

  out[#out + 1] = "{\n"
  for i, key in ipairs(keys) do
    out[#out + 1] = pad .. encode_string(tostring(key)) .. ": "
    encode_value(tbl[key], pad, out)
    out[#out + 1] = i < #keys and ",\n" or "\n"
  end

  out[#out + 1] = indent .. "}"
end

encode_value = function(value, indent, out)
  local kind = type(value)
  if kind == "table" then
    encode_table(value, indent, out)
  elseif kind == "string" then
    out[#out + 1] = encode_string(value)
  elseif kind == "number" then
    out[#out + 1] = value % 1 == 0 and string.format("%d", value) or string.format("%.14g", value)
  elseif kind == "boolean" then
    out[#out + 1] = tostring(value)
  else
    out[#out + 1] = "null"
  end
end

---Stable, indented JSON so diffs and AI edits stay readable.
---@param data CBookmarks.Data
---@return string
function M.encode(data)
  local out = {}
  encode_value(data, "", out)
  return table.concat(out) .. "\n"
end

---@return CBookmarks.Data?, string? error
local function parse(text)
  local ok, raw = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then return nil, raw end

  return Model.normalize(raw)
end

-- Files ---------------------------------------------------------------------

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then return nil end

  local text = fd:read "*a"
  fd:close()
  return text
end

---Writes through a temp file so readers never see a partial file.
local function write_file(path, text)
  local tmp = path .. ".tmp"
  local fd, err = io.open(tmp, "w")
  if not fd then return false, err end

  fd:write(text)
  fd:close()
  return os.rename(tmp, path)
end

---Keeps the file out of git status without touching the tracked .gitignore.
---@param root string
function M.exclude_from_git(root)
  if not Config.options.storage.git_exclude then return end

  local result = vim
    .system({ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true })
    :wait()
  if result.code ~= 0 then return end

  local info_dir = vim.fs.joinpath(vim.trim(result.stdout), "info")
  local exclude_path = vim.fs.joinpath(info_dir, "exclude")
  local existing = read_file(exclude_path) or ""
  local present = {}
  for line in existing:gmatch "[^\n]+" do
    present[vim.trim(line)] = true
  end

  local filename = Config.options.storage.filename
  local missing = {}
  for _, pattern in ipairs { "/" .. filename, "/" .. filename .. ".tmp" } do
    if not present[pattern] then missing[#missing + 1] = pattern end
  end

  if #missing == 0 then return end

  vim.fn.mkdir(info_dir, "p")
  local fd = io.open(exclude_path, "a")
  if not fd then return end

  if existing ~= "" and not existing:match "\n$" then fd:write "\n" end
  fd:write(table.concat(missing, "\n"), "\n")
  fd:close()
end

-- State ---------------------------------------------------------------------

---Reads the file for the current root, or starts empty.
---@return CBookmarks.Data
function M.load()
  state.root = M.root()
  state.path = M.path()
  state.dirty = false

  local text = read_file(state.path)
  state.known_text = text
  if text == nil then
    state.data = Model.empty()
  else
    local data, err = parse(text)
    if data then
      state.data = data
    else
      notify("could not read " .. state.path .. ": " .. tostring(err), vim.log.levels.ERROR)
      state.data = state.data or Model.empty()
    end
  end

  M.watch(state.root)
  return state.data
end

---@return CBookmarks.Data
function M.get()
  if not state.data or state.path ~= M.path() then
    M.flush()
    M.load()
  end

  return state.data
end

---@return boolean
function M.save()
  if not state.data then return false end

  local existed = uv.fs_stat(state.path) ~= nil
  local text = M.encode(state.data)
  state.known_text = text
  local ok, err = write_file(state.path, text)
  if not ok then
    notify("could not write " .. state.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  state.dirty = false
  if not existed then M.exclude_from_git(state.root) end

  return true
end

---Writes only when in-memory changes are pending.
function M.flush()
  if state.dirty then M.save() end
end

---Drops pending changes and re-reads the file.
function M.discard()
  state.dirty = false
  M.load()
  M.emit "file"
end

---Applies fn to the data, then persists unless opts.persist is false.
---@generic T
---@param fn fun(data: CBookmarks.Data): T
---@param opts? { persist?: boolean, source?: string }
---@return T
function M.update(fn, opts)
  opts = opts or {}
  local results = vim.F.pack_len(fn(M.get()))
  if opts.persist == false then
    state.dirty = true
  else
    M.save()
  end

  M.emit(opts.source or "local")
  return vim.F.unpack_len(results)
end

---@param source "local"|"sync"|"file"
function M.emit(source)
  vim.api.nvim_exec_autocmds("User", { pattern = "CBookmarksChanged", data = { source = source }, modeline = false })
end

---@param absolute string
---@return string project-relative, or absolute when outside the project
function M.relpath(absolute)
  M.get()
  return vim.fs.relpath(state.root, absolute) or absolute
end

---@param path string
---@return string absolute
function M.abspath(path)
  M.get()
  if vim.startswith(path, "/") then return path end

  return vim.fs.joinpath(state.root, path)
end

-- Watching ------------------------------------------------------------------

function M.unwatch()
  if not state.watcher then return end

  state.watcher:stop()
  state.watcher:close()
  state.watcher = nil
end

---Reloads once the file settles after an outside write.
function M.schedule_reload()
  if not state.timer then state.timer = uv.new_timer() end

  state.timer:stop()
  state.timer:start(RELOAD_DELAY_MS, 0, vim.schedule_wrap(function() M.reload_if_changed() end))
end

---Watches the root directory, because atomic writes replace the file.
---@param root string
function M.watch(root)
  M.unwatch()
  local handle = uv.new_fs_event()
  if not handle then return end

  local filename = Config.options.storage.filename
  local ok = handle:start(root, {}, function(err, fname)
    if err or (fname and fname ~= filename) then return end

    M.schedule_reload()
  end)
  if not ok then
    handle:close()
    return
  end

  state.watcher = handle
end

function M.reload_if_changed()
  if not state.path then return end

  local text = read_file(state.path)
  if text == state.known_text then return end

  if text == nil then
    state.data = Model.empty()
  else
    local data, err = parse(text)
    if not data then
      notify("ignoring " .. state.path .. ": " .. tostring(err), vim.log.levels.WARN)
      state.known_text = text
      return
    end

    state.data = data
  end

  state.known_text = text
  state.dirty = false
  M.emit "file"
end

---Forgets everything. Tests and reconfiguration use it.
function M.reset()
  M.unwatch()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  state.root, state.path, state.data, state.known_text = nil, nil, nil, nil
  state.dirty = false
end

function M.setup()
  local augroup = vim.api.nvim_create_augroup("CBookmarksStore", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      if state.data and state.path ~= M.path() then
        M.get()
        M.emit "file"
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = augroup, callback = M.flush })
end

return M
