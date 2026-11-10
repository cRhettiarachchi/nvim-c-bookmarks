---Pure data rules for groups and bookmarks. No UI, no file access.
local M = {}

M.VERSION = 1

---@class CBookmarks.Bookmark
---@field id string
---@field path string project-relative, absolute when outside the project
---@field lnum integer first line, 1-based
---@field end_lnum integer last line, 1-based, inclusive
---@field name string
---@field note string markdown
---@field anchor string text of the first line when last synced
---@field created_at integer
---@field updated_at integer

---@class CBookmarks.Group
---@field id string
---@field name string
---@field bookmarks CBookmarks.Bookmark[] explicit order
---@field created_at integer

---@class CBookmarks.Data
---@field version integer
---@field active string|nil id of the active group
---@field groups CBookmarks.Group[]

local function now() return os.time() end

local function to_str(value)
  if type(value) == "string" then return value end
  if value == nil or value == vim.NIL then return "" end

  return tostring(value)
end

local function to_lnum(value, default)
  local n = tonumber(value)
  if not n or n < 1 then return default end

  return math.floor(n)
end

---@param prefix string
---@return string
function M.new_id(prefix) return string.format("%s_%x%04x", prefix, os.time(), math.random(0, 0xffff)) end

---@return CBookmarks.Data
function M.empty() return { version = M.VERSION, active = nil, groups = {} } end

---Repairs a file written by hand or by an AI into the expected shape.
---@param raw any
---@return CBookmarks.Data
function M.normalize(raw)
  local data = M.empty()
  if type(raw) ~= "table" then return data end

  local seen = {}
  local function unique(id, prefix)
    while id == "" or seen[id] do
      id = M.new_id(prefix)
    end

    seen[id] = true
    return id
  end

  for _, g in ipairs(type(raw.groups) == "table" and raw.groups or {}) do
    if type(g) == "table" then
      local group = {
        id = unique(to_str(g.id), "g"),
        name = vim.trim(to_str(g.name)),
        created_at = to_lnum(g.created_at, now()),
        bookmarks = {},
      }
      if group.name == "" then group.name = "untitled" end

      for _, b in ipairs(type(g.bookmarks) == "table" and g.bookmarks or {}) do
        if type(b) == "table" and to_str(b.path) ~= "" then
          local lnum = to_lnum(b.lnum, 1)
          local end_lnum = to_lnum(b.end_lnum, lnum)
          if end_lnum < lnum then
            lnum, end_lnum = end_lnum, lnum
          end

          table.insert(group.bookmarks, {
            id = unique(to_str(b.id), "b"),
            path = to_str(b.path),
            lnum = lnum,
            end_lnum = end_lnum,
            name = vim.trim(to_str(b.name)),
            note = to_str(b.note),
            anchor = to_str(b.anchor),
            created_at = to_lnum(b.created_at, now()),
            updated_at = to_lnum(b.updated_at, now()),
          })
        end
      end

      table.insert(data.groups, group)
    end
  end

  local active = to_str(raw.active)
  if M.find_group(data, active) then
    data.active = active
  elseif data.groups[1] then
    data.active = data.groups[1].id
  end

  return data
end

---@param data CBookmarks.Data
---@param id string?
---@return CBookmarks.Group?, integer?
function M.find_group(data, id)
  for index, group in ipairs(data.groups) do
    if group.id == id then return group, index end
  end
end

---Case-insensitive lookup by name.
---@return CBookmarks.Group?, integer?
function M.find_group_by_name(data, name)
  local wanted = vim.trim(name or ""):lower()
  for index, group in ipairs(data.groups) do
    if group.name:lower() == wanted then return group, index end
  end
end

---@param data CBookmarks.Data
---@return CBookmarks.Group?
function M.active_group(data)
  if not data.active then return nil end

  return (M.find_group(data, data.active))
end

---@return CBookmarks.Group?, string? error
function M.add_group(data, name)
  name = vim.trim(name or "")
  if name == "" then return nil, "a group needs a name" end
  if M.find_group_by_name(data, name) then return nil, string.format("group %q already exists", name) end

  local group = { id = M.new_id "g", name = name, created_at = now(), bookmarks = {} }
  table.insert(data.groups, group)
  if not data.active then data.active = group.id end

  return group
end

---@return boolean, string? error
function M.rename_group(data, id, name)
  local group = M.find_group(data, id)
  name = vim.trim(name or "")
  if not group then return false, "no such group" end
  if name == "" then return false, "a group needs a name" end

  local clash = M.find_group_by_name(data, name)
  if clash and clash ~= group then return false, string.format("group %q already exists", name) end

  group.name = name
  return true
end

---@return boolean removed
function M.remove_group(data, id)
  local _, index = M.find_group(data, id)
  if not index then return false end

  table.remove(data.groups, index)
  if data.active == id then data.active = data.groups[1] and data.groups[1].id or nil end

  return true
end

---@return boolean
function M.set_active(data, id)
  if not M.find_group(data, id) then return false end

  data.active = id
  return true
end

---Moves the active group forward (step 1) or backward (step -1), wrapping.
---@return CBookmarks.Group?
function M.rotate(data, step)
  local count = #data.groups
  if count == 0 then return nil end

  local _, index = M.find_group(data, data.active)
  if not index then
    data.active = data.groups[1].id
    return data.groups[1]
  end

  local target = data.groups[((index - 1 + step) % count) + 1]
  data.active = target.id
  return target
end

---@param group CBookmarks.Group
---@param fields { path: string, lnum: integer, end_lnum?: integer, name?: string, note?: string, anchor?: string }
---@return CBookmarks.Bookmark
function M.add_bookmark(group, fields)
  local lnum = to_lnum(fields.lnum, 1)
  local end_lnum = to_lnum(fields.end_lnum, lnum)
  if end_lnum < lnum then
    lnum, end_lnum = end_lnum, lnum
  end

  local bookmark = {
    id = M.new_id "b",
    path = fields.path,
    lnum = lnum,
    end_lnum = end_lnum,
    name = vim.trim(to_str(fields.name)),
    note = to_str(fields.note),
    anchor = to_str(fields.anchor),
    created_at = now(),
    updated_at = now(),
  }
  table.insert(group.bookmarks, bookmark)
  return bookmark
end

---@return CBookmarks.Bookmark?, integer?
function M.find_bookmark(group, id)
  for index, bookmark in ipairs(group.bookmarks) do
    if bookmark.id == id then return bookmark, index end
  end
end

---@return boolean removed
function M.remove_bookmark(group, id)
  local _, index = M.find_bookmark(group, id)
  if not index then return false end

  table.remove(group.bookmarks, index)
  return true
end

---Shifts a bookmark by delta places, clamped to the list.
---@return integer? new index
function M.move_bookmark(group, id, delta)
  local _, index = M.find_bookmark(group, id)
  if not index then return nil end

  local target = math.min(math.max(index + delta, 1), #group.bookmarks)
  if target == index then return index end

  local bookmark = table.remove(group.bookmarks, index)
  table.insert(group.bookmarks, target, bookmark)
  return target
end

---Replaces the explicit order with file-then-line order.
function M.sort_bookmarks(group)
  table.sort(group.bookmarks, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end

    return a.end_lnum < b.end_lnum
  end)
end

---@return CBookmarks.Bookmark[]
function M.bookmarks_in(group, path)
  return vim.tbl_filter(function(bookmark) return bookmark.path == path end, group.bookmarks)
end

---The narrowest bookmark covering lnum in path.
---@return CBookmarks.Bookmark?
function M.find_at(group, path, lnum)
  local best
  for _, bookmark in ipairs(group.bookmarks) do
    if bookmark.path == path and lnum >= bookmark.lnum and lnum <= bookmark.end_lnum then
      if not best or (bookmark.end_lnum - bookmark.lnum) < (best.end_lnum - best.lnum) then best = bookmark end
    end
  end

  return best
end

function M.clear_group(group) group.bookmarks = {} end

function M.clear_all(data)
  data.groups = {}
  data.active = nil
end

function M.touch(bookmark) bookmark.updated_at = now() end

---Name, else the first note line, else the anchored text.
---@return string
function M.label(bookmark)
  if bookmark.name ~= "" then return bookmark.name end

  local first = (bookmark.note:match "^[^\n]*" or ""):gsub("^#+%s*", "")
  first = vim.trim(first)
  if first ~= "" then return first end

  local anchor = vim.trim(bookmark.anchor)
  if anchor ~= "" then return anchor end

  return "untitled"
end

return M
