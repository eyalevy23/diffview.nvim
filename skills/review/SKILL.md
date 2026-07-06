---
name: diff-nvim-review
description: Collaborate with the human on a code review through diffview.nvim's shared review file. Use when asked to "review my diff", "address my review comments", "reply to my comments", or anything about the diffview review loop. Reads/writes <git-dir>/diffview-review.json — threads anchored to source lines that both the human (in Neovim) and you read and write.
allowed-tools: mcp__diff-nvim__*, Bash(python3 *review_write.py *)
---

# diff.nvim — the shared review loop

You and the human are reviewing the same diff. The human writes comments on
diff lines in Neovim; you answer through the `review_*` MCP tools (the
`diff-nvim` server). Both sides share one JSON file per repo inside `.git` —
the tools handle locking and file location. NEVER edit that file directly:
Neovim writes it under a lock, and a hand-rolled write silently loses the
human's comments.

## Workflow

1. `review_queue` — every thread it returns is addressed to you (open, last
   comment not yours).
2. Reply in-thread with `review_reply`. If the fix is concrete, attach a
   `suggestion` (exact replacement lines) — the human applies it with one
   keypress; prefer suggestions over prose for mechanical changes.
3. If you were asked to change code and you did it directly, say so in the
   reply and mark the thread with `review_set_status` (applied).
4. Resolving threads is the human's call — never yours. Never re-litigate
   resolved threads.

## Reviewing a diff yourself

Read the actual changes (`git diff`) plus enough surrounding file context to
judge correctness. One `review_add_thread` per distinct finding, anchored to
the most relevant line with that line's EXACT current text as `snippet`
(anchors survive edits through it). Overall verdict via `review_set_summary`.
Quality over quantity: real defects, risky edges, and concrete
simplifications — skip style nits unless asked.

## No review_* tools available?

You are on an agent without the diff.nvim MCP server. Use the bundled CLI
instead — same protocol, same lock, same file: run `scripts/review_write.py`
(next to this SKILL.md) with python3 — `--queue` to read your work queue,
`--help` for the ops-file write flow.
