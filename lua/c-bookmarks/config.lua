local M = {}

---@class CBookmarks.StorageConfig
---@field filename string JSON file created at the project root
---@field git_exclude boolean add the file to .git/info/exclude on first write
---@field root fun(): string resolves the project root

---@class CBookmarks.SignsConfig
---@field enabled boolean
---@field mark string sign for a bookmark without a note
---@field note string sign for a bookmark with a note
---@field priority integer

---@class CBookmarks.HighlightsConfig
---@field range string|false highlight group tinting bookmarked lines

---@alias CBookmarks.PanelAction fun(ctx: { id: string?, bookmark: CBookmarks.Bookmark? })

---@class CBookmarks.PanelConfig
---@field width integer
---@field position "right"|"left"
---@field keys table<string, string|CBookmarks.PanelAction> key -> built-in action name or function

---@class CBookmarks.NotesConfig
---@field editor { width: integer, height: integer, border: string }
---@field viewer { max_width: integer, max_height: integer, border: string }
---@field hint { enabled: boolean, max_width: integer }

---@class CBookmarks.AiConfig
---@field skills_dir string where `skill install` links the shipped Claude Code skill
---@field provider string "claude", "codex", "opencode" or a custom provider
---@field model string? provider model id, nil for its default
---@field extra_args string[] extra command-line arguments for the provider
---@field timeout_ms integer kill the provider after this long
---@field open_panel boolean show the panel when a walkthrough lands
---@field providers table<string, CBookmarks.Provider> custom providers by name
---@field models string[]? picker choices, nil uses the provider's list
---@field state_file string? where the picked model is remembered, nil uses stdpath("state")

---@class CBookmarks.Config
---@field default_group string group created by the first add
---@field storage CBookmarks.StorageConfig
---@field signs CBookmarks.SignsConfig
---@field highlights CBookmarks.HighlightsConfig
---@field panel CBookmarks.PanelConfig
---@field notes CBookmarks.NotesConfig
---@field ai CBookmarks.AiConfig

---@type CBookmarks.Config
M.defaults = {
  default_group = "default",
  storage = {
    filename = ".c-bookmarks.json",
    git_exclude = true,
    root = function() return vim.fs.root(vim.uv.cwd(), ".git") or vim.uv.cwd() end,
  },
  signs = {
    enabled = true,
    mark = "󰃃",
    note = "󰃀",
    priority = 20,
  },
  highlights = {
    range = "CBookmarkRange",
  },
  panel = {
    width = 40,
    position = "right",
    keys = {
      ["<CR>"] = "jump",
      ["q"] = "close",
      ["d"] = "delete",
      ["r"] = "rename",
      ["e"] = "edit_note",
      ["v"] = "view_note",
      ["K"] = "move_up",
      ["J"] = "move_down",
      ["s"] = "sort",
      ["<Tab>"] = "next_group",
      ["<S-Tab>"] = "prev_group",
      ["p"] = "pick_group",
      ["n"] = "new_group",
      ["R"] = "rename_group",
      ["D"] = "delete_group",
      ["X"] = "clear_group",
      ["x"] = "explain",
      ["<C-c>"] = "cancel_explain",
      ["m"] = "pick_model",
      ["P"] = "pick_provider",
      ["?"] = "help",
    },
  },
  notes = {
    editor = { width = 72, height = 16, border = "rounded" },
    viewer = { max_width = 72, max_height = 24, border = "rounded" },
    hint = { enabled = true, max_width = 48 },
  },
  ai = {
    skills_dir = "~/.claude/skills",
    provider = "claude",
    model = nil,
    extra_args = {},
    timeout_ms = 5 * 60 * 1000,
    open_panel = true,
    models = nil,
    state_file = nil,
    ask = { width = 80, max_height = 30, border = "rounded", default_question = "Explain this code" },
  },
}

---@type CBookmarks.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
---@return CBookmarks.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
