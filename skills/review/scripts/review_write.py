#!/usr/bin/env python3
"""CLI for diff.nvim's review loop — a thin wrapper over review_core.py.

This is the PORTABLE FALLBACK writer/reader for agents without MCP support
(Claude Code sessions normally use the bundled MCP server, review_mcp.py,
which imports the same core). All protocol logic — locking, atomic writes,
the canonical encoder, id-minting, invariant enforcement — lives in
review_core.py, the single source of truth shared with the server and kept
in sync with the Neovim writer (lua/diffview/comments/store.lua).

Usage:
    review_write.py OPSFILE                    # ops JSON from a file
    review_write.py - < ops.json               # ops JSON on stdin
    review_write.py OPSFILE --review-file P    # explicit review-file override
    review_write.py --queue                    # print open threads awaiting claude
    review_write.py --list                     # print the full review document

The review file is derived automatically: `git rev-parse --git-dir` from the
current directory -> <git-dir>/diffview-review.json. Use --review-file PATH
to override (e.g. when running outside the repo).

The ops payload is {"ops": [op, ...]} or a bare [op, ...]; each op is one of:
    {"op": "add_thread", "anchor": {...}, "body": "...", "suggestion": {...}?}
    {"op": "add_comment", "thread_id": "t-..", "body": "...", "suggestion": {...}?}
    {"op": "edit_comment", "comment_id": "c-..", "body": "..."}
    {"op": "set_status", "thread_id": "t-..", "status": "applied"}
    {"op": "set_summary", "summary": "..."}

Exit codes: 0 ok; 1 usage/ops error; 2 invariant violation; 3 unreadable
review file (left untouched); 4 lock timeout; 5 write failure.
On success stdout is JSON: {"ok": true, "minted": [...]}.
"""

import json
import sys

import review_core as core


def die(code, msg):
    print("review_write: " + msg, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    ops_file, review_path, mode = None, None, "write"
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--review-file":
            i += 1
            if i >= len(argv):
                die(1, "--review-file needs a path")
            review_path = argv[i]
        elif arg.startswith("--review-file="):
            review_path = arg.split("=", 1)[1]
        elif arg in ("--list", "--queue"):
            if mode != "write":
                die(1, "--list and --queue are mutually exclusive")
            mode = arg[2:]
        elif arg in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        elif ops_file is None:
            ops_file = arg
        else:
            die(1, "unexpected argument: %s" % arg)
        i += 1
    if mode != "write" and ops_file is not None:
        die(1, "--%s is read-only — don't pass an ops file with it" % mode)
    return ops_file, review_path, mode


def main():
    ops_file, review_path, mode = parse_args(sys.argv[1:])

    try:
        path = review_path if review_path is not None else core.derive_review_file()

        if mode == "queue":
            print(json.dumps(core.read_queue(path), indent=2, ensure_ascii=False))
            return
        if mode == "list":
            print(json.dumps(core.read_list(path), indent=2, ensure_ascii=False))
            return

        if ops_file is None or ops_file == "-":
            try:
                payload = json.load(sys.stdin)
            except ValueError as e:
                die(1, "stdin is not valid JSON: %s" % e)
        else:
            try:
                with open(ops_file, "r", encoding="utf-8") as f:
                    payload = json.load(f)
            except OSError as e:
                die(1, "cannot read ops file %s: %s" % (ops_file, e))
            except ValueError as e:
                die(1, "ops file %s is not valid JSON: %s" % (ops_file, e))

        ops = payload.get("ops") if isinstance(payload, dict) else payload
        print(json.dumps(core.write_ops(path, ops)))
    except core.ReviewError as e:
        die(e.code, e.message)


if __name__ == "__main__":
    main()
