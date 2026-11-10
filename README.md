# nvim-c-bookmarks

Project-scoped bookmarks for Neovim 0.11+ with line ranges, named groups, markdown notes, a side panel, and a file format that AI tools can read and write.

Status: complete for the locked design: storage, marks, groups, panel, notes, the Claude Code skill and the explain command.

`CHEATSHEET.md` lists every action with its key, command and Lua call.

## Install

```lua
-- lazy.nvim
{
  dir = "~/Documents/projects/nvim-c-bookmarks",
  lazy = false,
  opts = {},
}
```

## How it works

- Bookmarks live in `.c-bookmarks.json` at the git root (cwd when there is no repo). Paths are relative to that root.
- On first write the file is added to `.git/info/exclude`, so the repo stays clean. Remove that line to commit the file.
- A bookmark covers a line range. Add from a visual selection to cover several lines.
- Groups hold bookmarks in an explicit order. One group is active; marks and the panel show only that group.
- While a file is open, extmarks keep every bookmark on its lines. Positions are written back on save and on exit.
- Any process may write the file. The plugin notices and refreshes the marks and the panel.

## Commands

| Command | Effect |
| --- | --- |
| `:CBookmarks add [name]` | Bookmark the cursor line, the visual selection, or a `:range` |
| `:CBookmarks toggle` | Add a bookmark here, or remove the one under the cursor |
| `:CBookmarks remove` | Remove the bookmark under the cursor |
| `:CBookmarks clear` | Remove every bookmark in the active group |
| `:CBookmarks clear all` | Remove every group and bookmark |
| `:CBookmarks group` | Pick the active group |
| `:CBookmarks group new [name]` | Create a group and make it active |
| `:CBookmarks group rename [name]` | Rename the active group |
| `:CBookmarks group delete` | Delete the active group |
| `:CBookmarks group next` / `prev` | Rotate the active group |
| `:CBookmarks note` | Edit the note of the bookmark under the cursor in a float, adding a bookmark when there is none |
| `:CBookmarks note view` | Show the rendered note in a hover window |
| `:CBookmarks skill install` | Link the shipped Claude Code skill into `~/.claude/skills` (`skill uninstall`, `skill path`, bare `skill` reports) |
| `:CBookmarks explain [request]` | Ask the AI provider for a walkthrough in the background; prompts when no request is given. `explain cancel` stops running requests |
| `:CBookmarks explain model [name]` | Pick the model for walkthroughs, or set it directly; `default` returns to the provider default. The choice is remembered across sessions |
| `:CBookmarks ask [question]` | Ask a quick question and read the answer in a float; prompts when no question is given. A `:range` or visual selection attaches that code, and with no question it is explained |
| `:CBookmarks ask bookmark` | Bookmark the code of the last answer in the active group, with the answer as its note |
| `:CBookmarks ask cancel` | Stop running questions and close the float |
| `:CBookmarks panel` | Toggle the side panel (`panel open`, `panel close` also work) |
| `:CBookmarks save` | Write pending position changes now |
| `:CBookmarks reload` | Drop pending changes and re-read the file |

## Panel

Opens as a fixed-width split on the right (`panel.position = "left"` moves it). It lists the active group in its explicit order and refreshes live as lines move. Each row shows the file name with its lines, and on the right the bookmark's name, else the first line of its note. When the panel is narrow the caption goes first, then the file name is shortened, and the line numbers are dropped last. The row of the bookmark the editor cursor sits in is highlighted (`CBookmarkPanelCurrent`, a `Visual` link by default), the way a file tree marks the open file. Default keys inside the panel:

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the bookmark, panel stays open |
| `q` | Close |
| `d` | Delete the bookmark |
| `r` | Rename the bookmark |
| `e` | Edit the note |
| `v` | View the note |
| `K` / `J` | Move the bookmark up / down |
| `s` | Sort the group by file and line |
| `<Tab>` / `<S-Tab>` | Next / previous group |
| `p` | Pick a group |
| `n` / `R` / `D` / `X` | New / rename / delete / clear group |
| `x` | Ask the AI provider for a walkthrough |
| `<C-c>` | Cancel running walkthrough requests |
| `m` | Pick the AI model |
| `?` | Show these keys |

Every key maps to an action name in `panel.keys`; a function value gets `{ id, bookmark }` and makes a custom action.

## Lua API

```lua
local cb = require "c-bookmarks"
cb.add({ name = "optional" })  -- cursor line or visual selection
cb.add_named()                  -- prompts for a name
cb.toggle()
cb.remove_at_cursor()
cb.note_edit()                  -- float editor, every close saves
cb.note_view()                  -- hover window, press again to focus it
cb.group_new("walk")           -- prompts when no name is given
cb.group_rename()
cb.group_delete()
cb.group_next()
cb.group_prev()
cb.group_pick()
cb.group_clear()
cb.clear_all()
cb.panel_toggle()
cb.status()                     -- "󰃃 walk (3) 2/5" for a status line
cb.skill_install()              -- link the Claude Code skill
cb.explain("how does login work") -- background walkthrough, prompts when blank
cb.explain_cancel()
cb.explain_model()              -- picker; cb.explain_model("sonnet") sets it
cb.explain_status()             -- spinner text while a run is active, "" when idle
cb.ask("is this cached?")       -- floating answer, prompts when blank; a selection is attached
cb.ask_selection()              -- explain the selection, the bookmark under the cursor, or the line
cb.ask_bookmark()               -- bookmark the code of the last answer, answer as note
cb.ask_cancel()
```

## Notes

Notes are markdown. `note` opens a centered float with the note; `q`, `:w`, or closing the window saves it. `note view` shows the rendered note in the same hover window LSP uses, so it follows your border and highlight settings; moving the cursor closes it, pressing the key again focuses it. While the cursor rests on a bookmarked line that has a note, the first line of the note appears after the line, ellipsized to `notes.hint.max_width`.

## AI integration

The JSON file is the contract. Any tool that writes it, including Claude Code, shows up in the editor at once: the watcher reloads the file, places the marks, and refreshes the panel.

The repo ships a Claude Code skill at `skills/c-bookmarks/SKILL.md`. It teaches the file format and one convention: when asked to walk through or explain some code, create a group named after the request with one ordered stop per place, a markdown note on each, and make it active. Run `:CBookmarks skill install` once to link it into `~/.claude/skills` (the link follows this checkout, so updates need no reinstall). Then, from the claudecode.nvim terminal:

```
bookmark a walkthrough of how a login request becomes a session
```

The group fills in the panel while Claude writes. The skill also covers the other direction: "explain the group I just made" reads the active group and its ranges.

Files written by other tools may omit `id`, `anchor` and timestamps; the plugin repairs them on load.

### The explain command

`:CBookmarks explain` (or `<leader>mx`) asks for a request, then runs the provider in the background from the project root. The prompt points the model at the shipped `SKILL.md` for the rules, names the file and lines you are looking at, lists the stops of the active group, and asks for the group back as JSON instead of a file write. The claude provider runs `claude -p` with a JSON schema for the reply and only `Read`, `Glob` and `Grep` allowed, so the background process never writes anything. The plugin checks every stop against the real files, drops stops whose file or line does not exist, fills missing anchors, stores the group, makes it active, and shows the panel without stealing focus. A reply whose group name matches an existing group replaces that group's stops, which is how "extend the active group with the error path" works.

**Model.** `:CBookmarks explain model` opens a picker with the provider's models plus an "other…" entry for typing one; the choice is stored under `stdpath("state")` and survives restarts. `explain model default` goes back to the provider default. `ai.models` replaces the picker list, `ai.model` sets a fallback in config.

**Loading state.** A run shows a spinner line at the top of the panel with the provider, elapsed seconds and the request, and the panel opens at the start of a run (without taking focus) so the state is visible. `require("c-bookmarks").explain_status()` returns the same text for a status line; add it as a lualine component and it animates. `<C-c>` in the panel or `:CBookmarks explain cancel` stops the run.

`ai.provider` picks the provider, `ai.model` the model (nil keeps the CLI default), `ai.extra_args` adds flags, `ai.timeout_ms` bounds the run, and `ai.open_panel` controls the panel. A custom provider is a table in `ai.providers` with a `name`, a `command(ctx)` returning the argv (`ctx.schema` is set for walkthroughs and nil for questions), a `parse(stdout)` returning the group object, and an `answer(stdout)` returning the reply text; `require("c-bookmarks.ai.providers").claude` is the reference.

### Quick questions

`:CBookmarks ask` (or `<leader>mq`) takes a question and opens a centered float at once with a spinner, the provider and the elapsed seconds; the answer replaces the spinner when it lands, rendered as markdown. There is no session: each question stands alone, and the float is the whole interface. `q`, `<Esc>` or leaving the window dismisses it, which also cancels a run still in flight. `y` yanks the answer.

In visual mode the selection goes with the question, and an empty question becomes `ai.ask.default_question` ("Explain this code"). `<leader>ms` skips the prompt and explains the selection directly; in normal mode it takes the bookmark under the cursor, else the cursor line. From the command line, `:'<,'>CBookmarks ask` explains the range and `:'<,'>CBookmarks ask why is this slow` asks about it.

When the answer was about some code, `b` in the float bookmarks that range in the active group with the answer as the note, and `<leader>mb` (`:CBookmarks ask bookmark`) does the same for the last answer after the float is gone. The model asked for a one-line `#` heading first, so the heading becomes the bookmark's label in the panel.

The question runs through the same provider and model as walkthroughs; the panel's busy line and `explain_status()` show it as "asking" while it runs. `ai.ask` sets the float's `width`, `max_height`, `border` and `default_question`.

## Configuration

Defaults live in `lua/c-bookmarks/config.lua`. The highlight groups `CBookmarkSign`, `CBookmarkRange`, `CBookmarkPanelTitle`, `CBookmarkPanelIndex`, `CBookmarkPanelLocation`, `CBookmarkPanelFile`, `CBookmarkPanelCurrent`, `CBookmarkPanelHint`, `CBookmarkPanelBusy`, `CBookmarkAskBusy` and `CBookmarkHint` are default links, so a colorscheme or `nvim_set_hl` call overrides them.

## Development

```bash
make test
make fmt
make lint
```
