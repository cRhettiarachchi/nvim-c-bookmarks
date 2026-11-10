# Cheatsheet

Keys in the first column are the `<leader>m` mappings from the lazy spec; the plugin itself sets none outside the panel and its floats. `n,v` means the key also works on a Visual selection.

## Editor

| Action | Key | Command | Lua (`require("c-bookmarks")`) |
| --- | --- | --- | --- |
| Toggle a bookmark on the cursor line or selection | `<leader>mm` n,v | `:CBookmarks toggle` | `toggle()` |
| Add a bookmark and name it | `<leader>ma` n,v | `:[range]CBookmarks add [name]` | `add_named()`, `add { lnum, end_lnum, name }` |
| Remove the bookmark under the cursor | `<leader>md` | `:CBookmarks remove` | `remove_at_cursor()` |
| Edit the note (adds a bookmark when needed) | `<leader>me` n,v | `:CBookmarks note` | `note_edit()` |
| View the rendered note | `<leader>mv` | `:CBookmarks note view` | `note_view()` |
| Toggle the side panel | `<leader>mp` | `:CBookmarks panel` | `panel_toggle()` |
| Open or focus / close the panel | | `:CBookmarks panel open` / `close` | `panel_open()` / `panel_close()` |
| Write pending position changes now | | `:CBookmarks save` | `save()` |
| Drop pending changes and re-read the file | | `:CBookmarks reload` | |

## Groups

| Action | Key | Command | Lua |
| --- | --- | --- | --- |
| Pick the active group | `<leader>mg` | `:CBookmarks group` | `group_pick()` |
| New group, make it active | `<leader>mn` | `:CBookmarks group new [name]` | `group_new(name)` |
| Next / previous group | `<leader>m]` / `<leader>m[` | `:CBookmarks group next` / `prev` | `group_next()` / `group_prev()` |
| Rename the active group | | `:CBookmarks group rename [name]` | `group_rename(name)` |
| Delete the active group (confirms when it has bookmarks) | | `:CBookmarks group delete` | `group_delete()` |
| Remove every bookmark in the active group | | `:CBookmarks clear` | `group_clear()` |
| Remove every group and bookmark | | `:CBookmarks clear all` | `clear_all()` |
| Group name and count for a statusline | | | `status()` |

## AI

| Action | Key | Command | Lua |
| --- | --- | --- | --- |
| Ask for a walkthrough group (prompts for the request) | `<leader>mx` n,v | `:CBookmarks explain [request]` | `explain(request)` |
| Stop running walkthroughs | | `:CBookmarks explain cancel` | `explain_cancel()` |
| Pick or set the model (`default` resets) | `<leader>mo` | `:CBookmarks explain model [name]` | `explain_model(name)` |
| Ask a quick question in a float; a selection or `:range` attaches the code | `<leader>mq` n,v | `:[range]CBookmarks ask [question]` | `ask(question)` |
| Explain the selection, else the bookmark under the cursor, else the line | `<leader>ms` n,v | `:'<,'>CBookmarks ask` | `ask_selection()` |
| Bookmark the code of the last answer, answer as note | `<leader>mb` | `:CBookmarks ask bookmark` | `ask_bookmark()` |
| Stop questions and close the float | | `:CBookmarks ask cancel` | `ask_cancel()` |
| Spinner text and running count for a statusline | | | `explain_status()`, `explain_running()` |

## Claude Code skill

| Action | Command | Lua |
| --- | --- | --- |
| Report whether the skill is linked | `:CBookmarks skill` | `skill_status()` |
| Link / unlink the skill in `~/.claude/skills` | `:CBookmarks skill install` / `uninstall` | `skill_install()` |
| Print the shipped `SKILL.md` path | `:CBookmarks skill path` | |

## Inside the panel

Defaults from `panel.keys`; `?` lists the live mapping.

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `<CR>` | Jump to the bookmark | `<Tab>` / `<S-Tab>` | Next / previous group |
| `d` | Delete the bookmark | `p` | Pick a group |
| `r` | Rename the bookmark | `n` | New group |
| `e` | Edit its note | `R` | Rename the group |
| `v` | View its note | `D` | Delete the group |
| `K` / `J` | Move it up / down | `X` | Clear the group |
| `s` | Sort by file and line | `x` | Explain with AI |
| `q` | Close the panel | `<C-c>` | Cancel the explain run |
| `?` | Show these keys | `m` | Pick the AI model |

## Inside the floats

| Float | Keys |
| --- | --- |
| Note editor | `:w` saves, `q` saves and closes, leaving the window saves |
| Note viewer | Closes when the cursor moves or the buffer changes |
| Ask answer | `q` / `<Esc>` / `<C-c>` close (and cancel a running question), `b` bookmarks the code with the answer, `y` yanks the answer |
