---
name: diff-nvim-review
description: Collaborate with the human on a code review through diffview.nvim's shared review file. Use when asked to "review my diff", "address my review comments", "reply to my comments", or anything about the diffview review loop. Reads/writes <git-dir>/diffview-review.json — threads anchored to source lines that both the human (in Neovim) and you read and write.
---

# diff.nvim — the shared review loop

You and the human are reviewing the same diff. The human reads and writes
comments inside Neovim (diffview.nvim renders them on the unified diff); you
read and write the same JSON file. Neovim watches the file and re-renders the
moment you write it — your comments appear in the editor live.

## The file

```bash
REVIEW_FILE="$(git rev-parse --git-dir)/diffview-review.json"
```

Read it directly (`cat`, `jq`). If it doesn't exist, there are no threads yet.

## Schema (version 1) — read reference

```jsonc
{
  "version": 1,
  "review": {
    "summary": "Overall verdict of the latest review pass, or null.",
    "updated_at": "2026-07-06T12:00:00Z"
  },
  "threads": [
    {
      "id": "t-3fa2c1",                    // minted by the write helper
      "anchor": {
        "path": "src/foo.ts",              // repo-relative
        "side": "b",                        // "b" = new/right side, "a" = old/deleted lines
        "rev": "WORKING",                   // "WORKING" = working tree; ":0" = index; else full SHA
        "line": 42,
        "end_line": 42,
        "snippet": "const x = load(id)",    // EXACT text of the anchored line — REQUIRED
        "ctx_before": "…line 41 text…",     // optional but include when you can
        "ctx_after": "…line 43 text…"
      },
      "status": "open",                     // "open" | "resolved" | "applied"
      "created_at": "…", "updated_at": "…", // ISO-8601 UTC
      "comments": [
        { "id": "c-1a", "author": "sam",    "ts": "…", "body": "Why not async?" },
        { "id": "c-2b", "author": "claude", "ts": "…", "body": "Good catch — suggestion below.",
          "suggestion": {                   // optional: a concrete replacement the human can apply with one key
            "replace_lines": [42, 43],      // 1-indexed inclusive range in the anchored file (at comment time)
            "text": "const x = await load(id)\nif (!x) return"
          }
        }
      ]
    }
  ]
}
```

## Writing — ONLY through the helper

NEVER write `$REVIEW_FILE` yourself: no temp+`mv`, no in-place edits, no
`jq`/`sed` into the file. Neovim writes under a lock; the bundled helper
takes the SAME lock, re-reads the file fresh, merges your ops, and writes
atomically. A hand-rolled write races the human and silently loses their
comments.

The helper is bundled with this skill at `${CLAUDE_SKILL_DIR}/scripts/review_write.py`
(`${CLAUDE_SKILL_DIR}` is this skill's own directory). Requires `python3` on
PATH (stdlib only):

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/review_write.py" "$REVIEW_FILE" <<'EOF'
{"ops": [
  {"op": "set_summary", "summary": "Reviewed the working tree: 2 findings, none blocking."}
]}
EOF
```

Build your ops FIRST, then run the helper — it holds the lock only for the
instant of the write.

- **Exit 0**: the write landed. stdout is JSON listing the ids minted for
  your new threads/comments — use those ids in follow-up ops.
- **Nonzero exit**: NOTHING was written. stderr says why; fix the ops and
  retry. Never work around a rejection by writing the file directly.

The helper enforces the protocol mechanically: it mints every id, forces
`author: "claude"`, refuses to touch comments you don't own, and refuses
`set_status` to anything but `"applied"` (resolving is the human's call).

### Ops

| op | fields | effect |
|----|--------|--------|
| `add_thread` | `anchor`, `body`, `suggestion?` | new open thread + its first comment |
| `add_comment` | `thread_id`, `body`, `suggestion?` | append your reply to a thread |
| `edit_comment` | `comment_id`, `body` | amend one of YOUR OWN comments |
| `set_status` | `thread_id`, `status` (only `"applied"`) | mark a thread after you changed the code |
| `set_summary` | `summary` | overall verdict of the review pass |

Anchor fields for `add_thread`: `path`, `side`, `rev`, `line`, `end_line?`,
`snippet` (EXACT current text of the anchored line — REQUIRED; Neovim uses it
to keep the comment attached when the file changes), `ctx_before?`/`ctx_after?`
(include when the lines exist).

Example — reply with a concrete suggestion, and mark another thread applied:

```json
{"ops": [
  {"op": "add_comment", "thread_id": "t-3fa2c1",
   "body": "Good catch — suggestion below.",
   "suggestion": {"replace_lines": [42, 43],
                  "text": "const x = await load(id)\nif (!x) return"}},
  {"op": "set_status", "thread_id": "t-9b01d2", "status": "applied"}
]}
```

## Your work queue

An **open thread whose last comment is NOT authored by "claude"** is addressed
to you. For each one:

- Reply in that thread (`add_comment`).
- If the fix is concrete, attach a `suggestion` block — the human applies it
  with one keypress. Prefer suggestions over prose for mechanical changes.
- If you were asked to change code and you did it directly (edited the files),
  say so in the reply and `set_status` the thread to `"applied"`.
- Do NOT try to resolve threads — resolution is the human's call, and the
  helper will reject it. (`"applied"` after you actually changed code is fine.)
- Never re-litigate threads that are `resolved` — the human decided.

## Reviewing a diff yourself

When asked to review:

1. Read the actual changes: `git diff` (working tree), `git diff --cached`
   (index), or the range the human names. Read enough surrounding file
   context to judge correctness — the diff alone is not enough.
2. Leave one `add_thread` per distinct finding, anchored to the most relevant
   line (side `"b"`, rev `"WORKING"` for working-tree reviews; side `"a"` only
   for comments on deleted lines). Include `snippet` from the file's CURRENT
   text.
3. Write your overall verdict via `set_summary` (one paragraph: what you
   reviewed, what's blocking, what's nice-to-have).
4. Quality over quantity: real defects, risky edges, and concrete
   simplifications. Skip style nits unless asked.

## Live nudge (optional)

Neovim picks up your writes automatically via a file watcher. If you are
running inside Neovim's terminal (`$NVIM` is set), you can make it instant:

```bash
[ -n "$NVIM" ] && nvim --server "$NVIM" --remote-expr \
  'luaeval("(function() local c = package.loaded[\"diffview.comments\"] if c then c.reload() end return 1 end)()")' || true
```

Never treat a nudge failure as an error.
