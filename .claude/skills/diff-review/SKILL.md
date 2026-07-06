---
name: diff-review
description: Collaborate with the human on a code review through diffview.nvim's shared review file. Use when asked to "review my diff", "address my review comments", "reply to my comments", or anything about the diffview review loop. Reads/writes <git-dir>/diffview-review.json — threads anchored to source lines that both the human (in Neovim) and you read and write.
---

# diff-review — the shared review loop

You and the human are reviewing the same diff. The human reads and writes
comments inside Neovim (diffview.nvim renders them on the unified diff); you
read and write the same JSON file. Neovim watches the file and re-renders the
moment you write it — your comments appear in the editor live.

## The file

```bash
REVIEW_FILE="$(git rev-parse --git-dir)/diffview-review.json"
```

If it doesn't exist, treat it as `{"version": 1, "review": {}, "threads": []}`.

## Schema (version 1)

```jsonc
{
  "version": 1,
  "review": {
    "summary": "Overall verdict of the latest review pass, or null.",
    "updated_at": "2026-07-06T12:00:00Z"
  },
  "threads": [
    {
      "id": "t-3fa2c1",                    // unique; you mint your own for new threads
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
        { "id": "c-1a", "author": "eyal",   "ts": "…", "body": "Why not async?" },
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

## Write rules (non-negotiable)

1. **Delta-only, merge-on-write.** Read the current file, add/modify only what
   is yours, keep everything else byte-identical. NEVER regenerate the file
   from your memory of it, and NEVER edit or delete a comment whose `author`
   is not `"claude"`.
2. **Atomic write.** Write to a temp file in the same directory, then
   `mv` it over `$REVIEW_FILE`. Never write the target in place.
3. **Fresh ids.** New threads: `t-` + 6 random hex chars; new comments `c-` +
   6 hex. Set `author` to `"claude"` and `ts` to ISO-8601 UTC.
4. **Anchors must carry the snippet.** `snippet` is the exact current text of
   the anchored line — Neovim uses it to keep your comment attached when the
   file changes. Include `ctx_before`/`ctx_after` when the lines exist.
5. **Self-check after writing.** Re-read the file, confirm it parses as JSON
   and your new ids are present. If not, fix it before reporting done.

## Your work queue

An **open thread whose last comment is NOT authored by "claude"** is addressed
to you. For each one:

- Reply in that thread (append to `comments`).
- If the fix is concrete, attach a `suggestion` block — the human applies it
  with one keypress. Prefer suggestions over prose for mechanical changes.
- If you were asked to change code and you did it directly (edited the files),
  say so in the reply and set the thread's `status` to `"applied"`.
- Do NOT flip threads to `"resolved"` yourself — resolution is the human's
  call. (`"applied"` after you actually changed code is fine.)
- Never re-litigate threads that are `resolved` — the human decided.

## Reviewing a diff yourself

When asked to review:

1. Read the actual changes: `git diff` (working tree), `git diff --cached`
   (index), or the range the human names. Read enough surrounding file
   context to judge correctness — the diff alone is not enough.
2. Leave one thread per distinct finding, anchored to the most relevant line
   (side `"b"`, rev `"WORKING"` for working-tree reviews; side `"a"` only for
   comments on deleted lines). Include `snippet` from the file's CURRENT text.
3. Write your overall verdict to `review.summary` (one paragraph: what you
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
