# nvim-c-bookmarks

Neovim plugin (0.11+): project-scoped bookmarks with line ranges, named groups, markdown notes, a side panel, and an AI contract. The contract is the JSON file `.c-bookmarks.json` at the git root; any tool that writes it, including Claude Code, is a first-class client.

## Layout

- `lua/c-bookmarks/model.lua` pure data rules, no UI and no file access
- `lua/c-bookmarks/store.lua` the JSON file: atomic writes, git exclude, file watcher
- `lua/c-bookmarks/marks.lua` extmarks, signs, live position sync
- `lua/c-bookmarks/commands.lua` `:CBookmarks <subcommand>` dispatch
- `lua/c-bookmarks/init.lua` `setup()` and the public Lua API
- `plugin/c-bookmarks.lua` command registration only
- `tests/*_spec.lua` plenary busted specs, run by `make test`

## Commands

```bash
make test
make fmt
make lint
```

## Rules

- Every data rule lives in `model.lua` and has a spec.
- The JSON file is a public contract. Never change its shape without bumping `version` in `model.lua` and updating the skill.
- Banned words in code, comments, docs and replies: bake, baked, baking, wire, wired, wiring, slice, slices, leverage. Built-in APIs are exempt.
- Comment only intent, constraints and non-obvious reasons. One line, at most 7 words where possible.
- One blank line after each complete `if`/`else` chain, loop, and function. Never a blank line before `end` or a closing brace.
- Format with stylua and run `make test` before reporting a change as done.
