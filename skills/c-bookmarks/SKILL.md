---
name: c-bookmarks
description: Write code explanations into the user's editor as an ordered, annotated walkthrough through nvim-c-bookmarks (.c-bookmarks.json at the git root), and read bookmarks back. Use this skill instead of a prose answer whenever the user asks to walk through, tour, trace, or explain the flow of code, or to bookmark anything. Also use it when they ask about "the group", "my bookmarks" or "the stops", or when a .c-bookmarks.json file exists in the project.
---

# c-bookmarks

The user runs Neovim with nvim-c-bookmarks. Bookmarks live in `.c-bookmarks.json` at the git root. The plugin watches that file, so anything you write appears in the editor at once: gutter marks on the lines, and the group in the side panel. Never ask the user to reload.

## The file

```json
{
  "version": 1,
  "active": "g_auth-flow",
  "groups": [
    {
      "id": "g_auth-flow",
      "name": "auth flow",
      "created_at": 1762300000,
      "bookmarks": [
        {
          "id": "b_login-handler",
          "name": "Login handler",
          "path": "src/auth/login.ts",
          "lnum": 12,
          "end_lnum": 41,
          "note": "Entry point for every login request.\n\nValidates the body, then hands off to `createSession` (stop 2). Errors here become 400s through the shared handler.",
          "anchor": "export async function handleLogin(req: Request) {",
          "created_at": 1762300000,
          "updated_at": 1762300000
        }
      ]
    }
  ]
}
```

- `version` is always 1.
- `active` is the id of the group the editor shows. Set it to the group the user should see now.
- `groups` and each group's `bookmarks` are ordered arrays. Array order is reading order; the panel numbers stops from 1 in that order.
- `id` is any string unique within the file. Use `g_<slug>` for groups and `b_<slug>` for bookmarks. Never change an existing id.
- `path` is relative to the git root with forward slashes. Use an absolute path only for a file outside the repository.
- `lnum` and `end_lnum` are 1-based and inclusive. A single line has `end_lnum` equal to `lnum`.
- `name` is a short label, or `""` when unused.
- `note` is markdown. Its first line is shown inline next to the code and stands in for the label when `name` is empty, so make it a one-sentence summary.
- `anchor` is the exact text of line `lnum`. The plugin keeps it to recognise the line later.
- `created_at` and `updated_at` are unix seconds. Use the current time for anything you create or change.

## Writing a walkthrough

When the user asks you to walk through, tour, or explain how some part of the code works:

1. Read `.c-bookmarks.json` if it exists. Keep every existing group and bookmark unless the user asks to change them.
2. Find the code and read every file you will cite, so line numbers and anchors are exact. Never guess a line number.
3. Create a group named after the request, for example `auth flow`. Reuse an existing group with that name only when the user refers to it.
4. Add one bookmark per stop, in the order a reader should follow: entry point first, then each hand-off. Cover the whole unit the note talks about (a function, a block, a config section), not just its first line.
5. Write a note per stop: first line a one-sentence summary, then at most eight short lines on what happens here, why it matters, and where control goes next. Refer to other stops by number, for example "see stop 3".
6. Set `active` to the new group's id.
7. Write the whole file as valid JSON with two-space indentation. Check that every `lnum` and `end_lnum` lies within its file.
8. Reply with the group name and the number of stops in one or two sentences. The panel already shows the rest.

## Reading bookmarks

When the user refers to a group, "my bookmarks", or "the stops":

1. Read `.c-bookmarks.json`. The group they mean is `active` unless they name another.
2. Read each bookmark's range from its file.
3. Explain the stops in order, numbered as the panel numbers them, quoting names and notes where they help.
4. When asked to extend or correct the notes, edit the bookmarks in place and keep their ids and order.

## Never

- Reorder, rename, or delete the user's bookmarks or groups without being asked.
- Write single-line stops for explanations that cover a block.
- Add the file to `.gitignore` or commit it. The plugin keeps it out of `git status` on its own.
- Leave the file as anything but complete, valid JSON.
