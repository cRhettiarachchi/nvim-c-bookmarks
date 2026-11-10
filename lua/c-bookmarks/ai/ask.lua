---Quick questions: one prompt, one floating answer, no session to keep.
local Config = require "c-bookmarks.config"
local Explain = require "c-bookmarks.ai.explain"
local Groups = require "c-bookmarks.groups"
local Marks = require "c-bookmarks.marks"
local Progress = require "c-bookmarks.ai.progress"
local Providers = require "c-bookmarks.ai.providers"
local Store = require "c-bookmarks.store"
local Text = require "c-bookmarks.text"

local M = {}

local TIMEOUT_EXIT_CODE = 124

M.ns = vim.api.nvim_create_namespace "c-bookmarks-ask"

---@class CBookmarks.AskContext
---@field bufnr integer
---@field path string relative to the project root
---@field lnum integer
---@field end_lnum integer
---@field lines string[]
---@field filetype string

---@class CBookmarks.AskRequest
---@field id integer
---@field question string
---@field context CBookmarks.AskContext?
---@field answer string?
---@field error string?
---@field dismissed boolean? the float was closed before the reply came

---@type table<integer, { proc: vim.SystemObj, request: CBookmarks.AskRequest }>
local running = {}
local next_id = 0
local last = nil ---@type CBookmarks.AskRequest? most recent answered question
local float = nil ---@type { win: integer, buf: integer, request: CBookmarks.AskRequest }?

local function notify(message, level) vim.notify("c-bookmarks: " .. message, level or vim.log.levels.INFO) end

local function in_visual_mode()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

-- Context -------------------------------------------------------------------

---Code the question is about: an explicit range, the visual selection,
---the bookmark under the cursor, else the cursor line.
---@param opts? { bufnr?: integer, lnum?: integer, end_lnum?: integer }
---@return CBookmarks.AskContext?
function M.context(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = Marks.buf_path(bufnr)
  if not path then return nil end

  local lnum, end_lnum = opts.lnum, opts.end_lnum
  if not lnum then
    local bookmark = not in_visual_mode() and Marks.at_cursor(bufnr) or nil
    if bookmark then
      lnum, end_lnum = bookmark.lnum, bookmark.end_lnum
    else
      lnum, end_lnum = Marks.selected_lines()
    end
  end

  end_lnum = math.min(end_lnum or lnum, vim.api.nvim_buf_line_count(bufnr))
  return {
    bufnr = bufnr,
    path = path,
    lnum = lnum,
    end_lnum = end_lnum,
    lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, end_lnum, false),
    filetype = vim.bo[bufnr].filetype,
  }
end

---@param context CBookmarks.AskContext
---@return string
local function location(context) return string.format("%s:%d-%d", context.path, context.lnum, context.end_lnum) end

-- Prompt --------------------------------------------------------------------

---@param question string
---@param ctx { root: string, context?: CBookmarks.AskContext }
---@return string
function M.build_prompt(question, ctx)
  local parts = {
    "Answer a quick question asked from inside Neovim. Reply in GitHub-flavoured markdown: "
      .. "start with a one-line `#` heading that names the subject, then the answer, "
      .. "concise and under about 30 lines, with no preamble and no closing summary.",
    "Project root: "
      .. ctx.root
      .. ". Use Read, Glob and Grep only when the answer needs more than the code shown. Never write files.",
  }
  local context = ctx.context
  if context then
    local code = table.concat(context.lines, "\n")
    local fence = "```"
    while code:find(fence, 1, true) do
      fence = fence .. "`"
    end

    parts[#parts + 1] = string.format(
      "The user selected %s lines %d-%d:\n%s%s\n%s\n%s",
      context.path,
      context.lnum,
      context.end_lnum,
      fence,
      context.filetype,
      code,
      fence
    )
  end

  parts[#parts + 1] = "Question: " .. question
  return table.concat(parts, "\n\n")
end

-- Float ---------------------------------------------------------------------

local function float_open() return float ~= nil and vim.api.nvim_win_is_valid(float.win) end

---@param request CBookmarks.AskRequest
---@return string
local function footer(request)
  if request.answer then
    local keys = " y yank · q close "
    if request.context then keys = " b bookmark ·" .. keys end

    return keys
  end

  if request.error then return " q close " end

  return " q cancel "
end

---@param request CBookmarks.AskRequest
---@return string[] lines, string? line highlight
local function body(request)
  if request.answer then return vim.split(request.answer, "\n", { plain = true }) end
  if request.error then return { " " .. request.error }, "DiagnosticError" end

  local lines = { " " .. (Progress.status(request.id) or "") }
  if request.context then lines[2] = "   " .. location(request.context) end

  return lines, "CBookmarkAskBusy"
end

---Centers a float of the given size on the editor.
---@param width integer
---@param rows integer screen rows the content takes
---@return vim.api.keyset.win_config
local function geometry(width, rows)
  local cfg = Config.options.ai.ask
  local height = math.max(1, math.min(rows, cfg.max_height, vim.o.lines - 4))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.floor((vim.o.columns - width) / 2),
  }
end

---Redraws the float for its request: spinner, answer or error.
local function render()
  if not float_open() then return end

  local request, buf, win = float.request, float.buf, float.win
  local lines, hl_group = body(request)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if hl_group then vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, { line_hl_group = hl_group }) end

  local config = geometry(vim.api.nvim_win_get_width(win), vim.api.nvim_win_text_height(win, {}).all)
  if Config.options.ai.ask.border ~= "none" then
    config.footer = footer(request)
    config.footer_pos = "right"
  end

  vim.api.nvim_win_set_config(win, config)
end

---Forgets the float and stops its run; the window may already be closing.
local function release()
  if not float then return end

  local request = float.request
  float = nil
  local job = running[request.id]
  if job then
    request.dismissed = true
    job.proc:kill(15)
  end
end

---Closes the float, cancelling a run still in flight.
function M.close()
  if not float then return end

  local win = float.win
  release()
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
end

local function yank()
  local request = float and float.request
  if not request or not request.answer then return end

  vim.fn.setreg('"', request.answer, "l")
  notify "answer yanked"
end

---@param request CBookmarks.AskRequest
local function open_float(request)
  M.close()
  local cfg = Config.options.ai.ask
  local width = math.min(cfg.width, vim.o.columns - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"

  local config = geometry(width, 1)
  config.style = "minimal"
  config.border = cfg.border
  config.zindex = 60
  if cfg.border ~= "none" then
    config.title = " 󰘥 " .. Text.truncate(request.question, width - 6) .. " "
    config.title_pos = "center"
    config.footer = footer(request)
    config.footer_pos = "right"
  end

  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "n"
  float = { win = win, buf = buf, request = request }
  pcall(vim.treesitter.start, buf, "markdown")
  render()

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "c-bookmarks: " .. desc })
  end

  map("q", M.close, "close the answer")
  map("<Esc>", M.close, "close the answer")
  map("<C-c>", M.close, "close the answer")
  map("b", function() M.bookmark() end, "bookmark the code with this answer")
  map("y", yank, "yank the answer")
  local augroup = vim.api.nvim_create_augroup("CBookmarksAsk" .. buf, { clear = true })
  vim.api.nvim_create_autocmd(
    "WinClosed",
    { group = augroup, pattern = tostring(win), once = true, callback = release }
  )
  vim.api.nvim_create_autocmd("BufLeave", { group = augroup, buffer = buf, callback = M.close })
end

-- Running -------------------------------------------------------------------

---@param request CBookmarks.AskRequest
---@param result vim.SystemCompleted
local function finish(request, result)
  running[request.id] = nil
  Progress.stop(request.id)
  if result.signal ~= 0 then
    request.error = "cancelled"
  elseif result.code == TIMEOUT_EXIT_CODE then
    request.error = "timed out"
  elseif result.code ~= 0 then
    local detail = Providers.failure(Explain.provider(), result)
    request.error = string.format("failed (exit %d): %s", result.code, detail)
  else
    local answer, err = Explain.provider().answer(result.stdout or "")
    if answer then
      request.answer = answer
      last = request
    else
      request.error = err
    end
  end

  if request.error and request.error ~= "cancelled" then notify("ask " .. request.error, vim.log.levels.ERROR) end
  if float_open() and float.request == request then
    render()
  elseif request.answer and not request.dismissed then
    open_float(request)
  end
end

---Runs the provider for a question and shows the float at once.
---@param question string
---@param context? CBookmarks.AskContext
---@return integer id
function M.run(question, context)
  local prov = Explain.provider()
  local cfg = Config.options.ai
  local root = Store.root()
  local prompt = M.build_prompt(question, { root = root, context = context })
  local cmd = prov.command { root = root, prompt = prompt, model = Explain.model(), extra_args = cfg.extra_args or {} }

  next_id = next_id + 1
  local request = { id = next_id, question = question, context = context }
  running[request.id] = {
    request = request,
    proc = vim.system(
      cmd,
      { cwd = root, text = true, timeout = cfg.timeout_ms },
      vim.schedule_wrap(function(result) finish(request, result) end)
    ),
  }
  Progress.start(request.id, { request = question, provider = prov.name, verb = "asking" })
  open_float(request)
  return request.id
end

---Asks a question; prompts when none is given. A visual selection is attached.
---@param question? string
---@param opts? { context?: CBookmarks.AskContext|false } false asks without code
function M.ask(question, opts)
  opts = opts or {}
  local context = opts.context
  if context == nil and in_visual_mode() then context = M.context() end
  if context == false then context = nil end

  question = vim.trim(question or "")
  if question ~= "" then return M.run(question, context) end

  local prompt = context and ("Ask about " .. location(context) .. ": ") or "Ask: "
  vim.ui.input({ prompt = prompt }, function(input)
    if input == nil then return end

    input = vim.trim(input)
    if input == "" then
      if not context then return end

      input = Config.options.ai.ask.default_question
    end

    M.run(input, context)
  end)
end

---Explains the selection, the bookmark under the cursor, or the cursor line.
---@param context? CBookmarks.AskContext
---@return integer? id
function M.explain_selection(context)
  context = context or M.context()
  if not context then
    notify("this buffer has no file to explain", vim.log.levels.WARN)
    return nil
  end

  return M.run(Config.options.ai.ask.default_question, context)
end

---Bookmarks the code an answer was about, with the answer as the note.
---@param request? CBookmarks.AskRequest defaults to the open float, else the last answer
---@return CBookmarks.Bookmark?
function M.bookmark(request)
  request = request or (float and float.request) or last
  if not request or not request.answer then
    notify("no answer to bookmark yet", vim.log.levels.WARN)
    return nil
  end

  local context = request.context
  if not context then
    notify("that question had no code selection", vim.log.levels.WARN)
    return nil
  end

  local bufnr = context.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.fn.bufadd(Store.abspath(context.path))
    vim.fn.bufload(bufnr)
  end

  local bookmark = Marks.add { bufnr = bufnr, lnum = context.lnum, end_lnum = context.end_lnum, note = request.answer }
  if not bookmark then return nil end

  local group = Groups.active()
  notify(string.format("bookmarked %s in %s", location(context), group and group.name or "?"))
  if float and float.request == request then M.close() end

  return bookmark
end

---@return integer count of runs stopped
function M.cancel()
  local count = 0
  for _, job in pairs(running) do
    job.proc:kill(15)
    count = count + 1
  end

  if count == 0 then notify "nothing to cancel" end

  return count
end

---@return integer
function M.running_count() return vim.tbl_count(running) end

---@return CBookmarks.AskRequest? the most recent answered question
function M.last() return last end

---@return integer? win of the open float
function M.win() return float_open() and float.win or nil end

---Closes the float, stops every run and forgets the last answer. Tests use it.
function M.reset()
  M.close()
  for _, job in pairs(running) do
    job.proc:kill(15)
  end

  last = nil
end

function M.setup()
  local augroup = vim.api.nvim_create_augroup("CBookmarksAsk", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CBookmarksProgress",
    callback = function()
      if float_open() and not float.request.answer and not float.request.error then render() end
    end,
  })
end

return M
