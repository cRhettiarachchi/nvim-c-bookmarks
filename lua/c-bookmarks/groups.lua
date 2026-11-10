---Group commands: create, rename, delete, switch, rotate, clear.
local Config = require "c-bookmarks.config"
local Model = require "c-bookmarks.model"
local Store = require "c-bookmarks.store"

local M = {}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

local function confirm(question) return vim.fn.confirm(question, "&Yes\n&No", 2) == 1 end

---Runs callback with value, asking for one first when it is blank.
local function with_input(value, prompt, default, callback)
  if value and vim.trim(value) ~= "" then return callback(vim.trim(value)) end

  vim.ui.input({ prompt = prompt, default = default }, function(input)
    if input == nil or vim.trim(input) == "" then return end

    callback(vim.trim(input))
  end)
end

---@return CBookmarks.Group[]
function M.list() return Store.get().groups end

---@return CBookmarks.Group?
function M.active() return Model.active_group(Store.get()) end

---Active group name, size and position, for status lines.
---@return string
function M.status()
  local data = Store.get()
  local group, index = Model.find_group(data, data.active)
  if not group then return "" end

  return string.format("%s %s (%d) %d/%d", Config.options.signs.mark, group.name, #group.bookmarks, index, #data.groups)
end

---Creates a group and makes it active.
---@param name? string prompts when blank
---@param callback? fun(group: CBookmarks.Group)
function M.create(name, callback)
  with_input(name, "New group: ", nil, function(value)
    if Model.find_group_by_name(Store.get(), value) then
      notify(string.format("group %q already exists", value), vim.log.levels.WARN)
      return
    end

    local group = Store.update(function(data)
      local created = assert(Model.add_group(data, value))
      data.active = created.id
      return created
    end)
    notify("group " .. group.name)
    if callback then callback(group) end
  end)
end

---Renames the active group.
---@param name? string prompts when blank
function M.rename(name)
  local group = M.active()
  if not group then
    notify("no active group", vim.log.levels.WARN)
    return
  end

  with_input(name, "Rename group: ", group.name, function(value)
    local ok, err
    Store.update(function(data)
      ok, err = Model.rename_group(data, group.id, value)
    end)
    if not ok then notify(err, vim.log.levels.WARN) end
  end)
end

---Deletes the active group, asking first when it holds bookmarks.
---@param opts? { force?: boolean }
---@return boolean deleted
function M.remove(opts)
  local group = M.active()
  if not group then
    notify("no active group", vim.log.levels.WARN)
    return false
  end

  local count = #group.bookmarks
  local force = opts and opts.force
  if
    count > 0
    and not force
    and not confirm(string.format("Delete group %q and its %d bookmarks?", group.name, count))
  then
    return false
  end

  Store.update(function(data) Model.remove_group(data, group.id) end)
  notify("deleted group " .. group.name)
  return true
end

---@param id string
---@return boolean
function M.set_active(id)
  local ok = Store.update(function(data) return Model.set_active(data, id) end)
  if ok then notify(M.status()) end

  return ok
end

---@param step integer 1 forward, -1 backward
---@param opts? { silent?: boolean }
---@return CBookmarks.Group?
function M.rotate(step, opts)
  local group = Store.update(function(data) return Model.rotate(data, step) end)
  if not group then
    notify "no groups yet"
    return nil
  end

  if not (opts and opts.silent) then notify(M.status()) end

  return group
end

function M.next(opts) return M.rotate(1, opts) end

function M.prev(opts) return M.rotate(-1, opts) end

---Chooses the active group through vim.ui.select.
function M.pick()
  local data = Store.get()
  if #data.groups == 0 then
    notify "no groups yet"
    return
  end

  vim.ui.select(data.groups, {
    prompt = "Bookmark group",
    format_item = function(group)
      local marker = group.id == data.active and "● " or "  "
      return string.format("%s%s (%d)", marker, group.name, #group.bookmarks)
    end,
  }, function(choice)
    if choice then M.set_active(choice.id) end
  end)
end

---Removes every bookmark in the active group.
---@param opts? { force?: boolean }
---@return boolean cleared
function M.clear(opts)
  local group = M.active()
  if not group then
    notify("no active group", vim.log.levels.WARN)
    return false
  end

  local count = #group.bookmarks
  if count == 0 then
    notify "group is already empty"
    return false
  end

  local force = opts and opts.force
  if not force and not confirm(string.format("Remove all %d bookmarks in %q?", count, group.name)) then return false end

  Store.update(function(data) Model.clear_group(assert(Model.find_group(data, group.id))) end)
  return true
end

---Removes every group and bookmark in the project.
---@param opts? { force?: boolean }
---@return boolean cleared
function M.clear_all(opts)
  local data = Store.get()
  if #data.groups == 0 then
    notify "nothing to clear"
    return false
  end

  local total = 0
  for _, group in ipairs(data.groups) do
    total = total + #group.bookmarks
  end

  local force = opts and opts.force
  if not force and not confirm(string.format("Delete all %d groups and %d bookmarks?", #data.groups, total)) then
    return false
  end

  Store.update(Model.clear_all)
  return true
end

return M
