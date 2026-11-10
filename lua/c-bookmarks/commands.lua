---`:CBookmarks <subcommand> [verb] [args]` dispatch.
local M = {}

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.WARN) end

local function marks() return require "c-bookmarks.marks" end

local function groups() return require "c-bookmarks.groups" end

local function panel() return require "c-bookmarks.panel" end

local function notes() return require "c-bookmarks.notes" end

local function skill() return require "c-bookmarks.skill" end

local function explain() return require "c-bookmarks.ai.explain" end

local function ask() return require "c-bookmarks.ai.ask" end

---@class CBookmarks.Command
---@field desc string
---@field run? fun(cmd: table, rest: string)
---@field children? table<string, CBookmarks.Command>
---@field text? boolean words that are no verb go to run as free text

---@type table<string, CBookmarks.Command>
local commands = {
  add = {
    desc = "Bookmark the cursor line, selection, or :range; a name may follow",
    run = function(cmd, rest)
      local lnum, end_lnum
      if cmd.range > 0 then
        lnum, end_lnum = cmd.line1, cmd.line2
      else
        lnum, end_lnum = marks().selected_lines()
      end

      marks().add { lnum = lnum, end_lnum = end_lnum, name = rest }
    end,
  },
  toggle = {
    desc = "Add a bookmark here, or remove the one under the cursor",
    run = function() marks().toggle() end,
  },
  remove = {
    desc = "Remove the bookmark under the cursor",
    run = function() marks().remove_at_cursor() end,
  },
  clear = {
    desc = "Remove every bookmark in the active group; `clear all` removes every group",
    run = function(_, rest)
      if rest == "" then
        groups().clear()
      elseif rest == "all" then
        groups().clear_all()
      else
        notify "clear takes no argument, or `all`"
      end
    end,
  },
  explain = {
    desc = "Ask the AI provider for a walkthrough; `explain cancel` stops running ones",
    text = true,
    run = function(_, rest) explain().explain(rest) end,
    children = {
      cancel = { desc = "Stop running walkthrough requests", run = function() explain().cancel() end },
      model = {
        desc = "Pick the model, or set it: `explain model sonnet`; `explain model default` resets",
        run = function(_, rest)
          if rest == "" then
            explain().pick_model()
          else
            explain().set_model(rest)
          end
        end,
      },
      provider = {
        desc = "Pick the provider, or set it: `explain provider codex`",
        run = function(_, rest)
          if rest == "" then
            explain().pick_provider()
          else
            explain().set_provider(rest)
          end
        end,
      },
    },
  },
  ask = {
    desc = "Ask a quick question in a float; a :range or selection attaches the code. `ask bookmark` keeps the last answer",
    text = true,
    run = function(cmd, rest)
      local context = cmd.range > 0 and ask().context { lnum = cmd.line1, end_lnum = cmd.line2 } or nil
      if context and rest == "" then return ask().explain_selection(context) end

      ask().ask(rest, { context = context })
    end,
    children = {
      bookmark = {
        desc = "Bookmark the code of the last answer, answer as note",
        run = function() ask().bookmark() end,
      },
      cancel = {
        desc = "Stop running questions and close the float",
        run = function()
          ask().close()
          ask().cancel()
        end,
      },
    },
  },
  group = {
    desc = "Pick the active group; verbs: new, rename, delete, next, prev, pick",
    run = function() groups().pick() end,
    children = {
      new = { desc = "Create a group and make it active", run = function(_, rest) groups().create(rest) end },
      rename = { desc = "Rename the active group", run = function(_, rest) groups().rename(rest) end },
      delete = { desc = "Delete the active group", run = function() groups().remove() end },
      next = { desc = "Activate the next group", run = function() groups().next() end },
      prev = { desc = "Activate the previous group", run = function() groups().prev() end },
      pick = { desc = "Choose the active group", run = function() groups().pick() end },
    },
  },
  note = {
    desc = "Edit the note of the bookmark under the cursor; `note view` shows it",
    run = function() notes().edit() end,
    children = {
      edit = { desc = "Edit the note in a float, adding a bookmark when needed", run = function() notes().edit() end },
      view = { desc = "Show the rendered note by the cursor", run = function() notes().view() end },
    },
  },
  panel = {
    desc = "Toggle the side panel; verbs: open, close, toggle",
    run = function() panel().toggle() end,
    children = {
      open = { desc = "Open or focus the panel", run = function() panel().open() end },
      close = { desc = "Close the panel", run = function() panel().close() end },
      toggle = { desc = "Toggle the panel", run = function() panel().toggle() end },
    },
  },
  skill = {
    desc = "Report the Claude Code skill; verbs: install, uninstall, path",
    run = function() skill().report() end,
    children = {
      install = { desc = "Link the skill into the skills directory", run = function() skill().install() end },
      uninstall = { desc = "Remove the link", run = function() skill().uninstall() end },
      path = { desc = "Print the path of the shipped SKILL.md", run = function() print(skill().path()) end },
    },
  },
  save = {
    desc = "Write pending position changes now",
    run = function() require("c-bookmarks.store").flush() end,
  },
  reload = {
    desc = "Drop pending changes and re-read the file",
    run = function() require("c-bookmarks.store").discard() end,
  },
}

local function names(node)
  local list = vim.tbl_keys(node.children or {})
  table.sort(list)
  return list
end

---@param cmd table argument of the user command callback
function M.run(cmd)
  require("c-bookmarks").setup_once()
  local args = vim.split(cmd.args, "%s+", { trimempty = true })
  local node, path = { children = commands }, {}
  while node.children and args[1] and node.children[args[1]] do
    path[#path + 1] = args[1]
    node = node.children[table.remove(args, 1)]
  end

  local expected = table.concat(names(node), ", ")
  if node.children and args[1] and not node.text then
    local what = #path == 0 and "subcommand" or (table.concat(path, " ") .. " verb")
    notify(string.format("unknown %s %q, expected one of: %s", what, args[1], expected))
    return
  end

  if not node.run then
    notify("expected one of: " .. expected)
    return
  end

  node.run(cmd, table.concat(args, " "))
end

---@param arg_lead string
---@param cmdline string
---@return string[]
function M.complete(arg_lead, cmdline)
  local tail = cmdline:match "CBookmarks%s*(.*)$" or ""
  local words = vim.split(tail, "%s+", { trimempty = true })
  if arg_lead ~= "" then table.remove(words) end

  local node = { children = commands }
  for _, word in ipairs(words) do
    node = node.children and node.children[word]
    if not node then return {} end
  end

  return vim.tbl_filter(function(name) return vim.startswith(name, arg_lead) end, names(node))
end

return M
