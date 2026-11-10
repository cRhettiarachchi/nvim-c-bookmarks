local M = {}

local did_setup = false

---@param opts? table see `c-bookmarks.config`
function M.setup(opts)
  require("c-bookmarks.config").setup(opts)
  require("c-bookmarks.highlights").setup()
  require("c-bookmarks.store").setup()
  require("c-bookmarks.marks").setup()
  require("c-bookmarks.panel").setup()
  require("c-bookmarks.notes").setup()
  require("c-bookmarks.ai.explain").setup()
  require("c-bookmarks.ai.ask").setup()
  did_setup = true
end

---Commands and the API work without an explicit setup call.
function M.setup_once()
  if not did_setup then M.setup() end
end

local function marks()
  M.setup_once()
  return require "c-bookmarks.marks"
end

local function groups()
  M.setup_once()
  return require "c-bookmarks.groups"
end

local function panel()
  M.setup_once()
  return require "c-bookmarks.panel"
end

local function notes()
  M.setup_once()
  return require "c-bookmarks.notes"
end

-- Bookmarks -----------------------------------------------------------------

---Adds the cursor line or visual selection unless opts gives a range.
---@param opts? { lnum?: integer, end_lnum?: integer, name?: string, note?: string }
---@return CBookmarks.Bookmark?
function M.add(opts)
  opts = opts or {}
  if not opts.lnum then
    opts.lnum, opts.end_lnum = marks().selected_lines()
  end

  return marks().add(opts)
end

---Adds after prompting for an optional name.
function M.add_named() marks().add_named() end

---@return CBookmarks.Bookmark? added
function M.toggle() return marks().toggle() end

---@return boolean removed
function M.remove_at_cursor() return marks().remove_at_cursor() end

function M.save()
  M.setup_once()
  require("c-bookmarks.store").flush()
end

-- Groups --------------------------------------------------------------------

---@param name? string prompts when blank
function M.group_new(name) groups().create(name) end

---@param name? string prompts when blank
function M.group_rename(name) groups().rename(name) end

---@param opts? { force?: boolean }
function M.group_delete(opts) return groups().remove(opts) end

function M.group_next() return groups().next() end

function M.group_prev() return groups().prev() end

function M.group_pick() groups().pick() end

---@param opts? { force?: boolean }
function M.group_clear(opts) return groups().clear(opts) end

---@param opts? { force?: boolean }
function M.clear_all(opts) return groups().clear_all(opts) end

---Active group summary for a status line, empty when there is none.
---@return string
function M.status() return groups().status() end

-- Notes ---------------------------------------------------------------------

---Edits the note under the cursor in a float, adding a bookmark when needed.
---@return integer? win
function M.note_edit() return notes().edit() end

---Shows the rendered note under the cursor.
---@return integer? win
function M.note_view() return notes().view() end

-- AI ----------------------------------------------------------------------

---Links the shipped Claude Code skill into the skills directory.
---@return boolean
function M.skill_install()
  M.setup_once()
  return require("c-bookmarks.skill").install()
end

---@return "linked"|"missing"|"foreign"
function M.skill_status()
  M.setup_once()
  return require("c-bookmarks.skill").status()
end

---Asks the AI provider for a walkthrough; prompts when request is blank.
---@param request? string
function M.explain(request)
  M.setup_once()
  return require("c-bookmarks.ai.explain").explain(request)
end

---Stops running walkthrough requests.
---@return integer stopped
function M.explain_cancel()
  M.setup_once()
  return require("c-bookmarks.ai.explain").cancel()
end

---@return integer walkthrough requests in flight
function M.explain_running()
  M.setup_once()
  return require("c-bookmarks.ai.explain").running_count()
end

---Picks the model for walkthroughs, or sets it when a name is given.
---@param name? string "default" returns to the provider default
function M.explain_model(name)
  M.setup_once()
  local Explain = require "c-bookmarks.ai.explain"
  if name and vim.trim(name) ~= "" then return Explain.set_model(name) end

  Explain.pick_model()
end

---Spinner text while a walkthrough runs, empty otherwise. Made for status lines.
---@return string
function M.explain_status()
  M.setup_once()
  return require("c-bookmarks.ai.explain").status()
end

---Asks a quick question in a float; prompts when blank. A visual selection is attached.
---@param question? string
function M.ask(question)
  M.setup_once()
  return require("c-bookmarks.ai.ask").ask(question)
end

---Explains the selection, the bookmark under the cursor, or the cursor line in a float.
function M.ask_selection()
  M.setup_once()
  return require("c-bookmarks.ai.ask").explain_selection()
end

---Bookmarks the code the last answer was about, with the answer as its note.
---@return CBookmarks.Bookmark?
function M.ask_bookmark()
  M.setup_once()
  return require("c-bookmarks.ai.ask").bookmark()
end

---Stops running questions and closes the float.
function M.ask_cancel()
  M.setup_once()
  local Ask = require "c-bookmarks.ai.ask"
  Ask.close()
  return Ask.cancel()
end

-- Panel ---------------------------------------------------------------------

function M.panel_toggle() panel().toggle() end

function M.panel_open() panel().open() end

function M.panel_close() panel().close() end

return M
