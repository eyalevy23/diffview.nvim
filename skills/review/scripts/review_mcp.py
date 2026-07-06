#!/usr/bin/env python3
"""diff.nvim MCP server — stdio JSON-RPC 2.0, stdlib only (no SDK).

Hand-rolled after the same pattern as recon's mcp.rs: newline-delimited
JSON-RPC on stdin/stdout, fully synchronous (one message per line, so tool
calls are serialized in-process by construction), diagnostics to stderr.

All protocol logic is imported from review_core.py — the same lockfile +
canonical encoder the CLI uses, kept byte-in-sync with the Neovim writer
(lua/diffview/comments/store.lua). Writes therefore serialize against Neovim
through the same on-disk lock; this server adds NO second concurrency
mechanism.

Repo location: derived per call via `git rev-parse --git-dir` from this
process's cwd (Claude Code spawns the server with the session's project
directory as cwd). Every tool accepts an optional `repo` argument (any path
inside the target repo) for multi-root sessions.
"""

import json
import sys

import review_core as core

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "diff-nvim"

# Injected into every session via MCP `instructions` (Claude Code truncates
# at 2KB — keep this well under). Workflow etiquette lives here; mechanical
# invariants live in the tool descriptions.
INSTRUCTIONS = """\
diff.nvim review loop: the human writes review comments anchored to diff \
lines in Neovim; you read and answer them with the review_* tools. Both \
sides share one file per repo (under .git) — the tools handle locking and \
location; never edit that file directly.

Etiquette: when asked about review comments, start from review_queue — \
every thread it returns is addressed to you. Reply in-thread with \
review_reply. For concrete fixes attach a suggestion (exact replacement \
lines) — the human applies it with one keypress; prefer suggestions over \
prose for mechanical changes. If you were asked to change code and did it \
directly, say so in your reply and mark the thread with review_set_status \
(applied). Resolving threads is the human's call, never yours, and never \
re-litigate resolved threads.

Reviewing a diff yourself: read the actual changes plus enough surrounding \
context to judge correctness, then one review_add_thread per distinct \
finding, anchored to the most relevant line with that line's EXACT current \
text as the snippet (anchors survive edits through it). Write your overall \
verdict with review_set_summary. Quality over quantity: real defects, risky \
edges, concrete simplifications — skip style nits unless asked."""


def tool(name, description, props, required):
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": props,
            "required": required,
        },
    }


REPO = {
    "repo": {
        "type": "string",
        "description": "Any path inside the target git repo. Defaults to the server's working directory (the session's project).",
    },
}

SUGGESTION = {
    "suggestion": {
        "type": "object",
        "description": "Optional concrete replacement the human can apply with one keypress.",
        "properties": {
            "replace_lines": {
                "type": "array", "items": {"type": "integer"},
                "description": "[first, last] 1-indexed inclusive line range in the anchored file at comment time",
            },
            "text": {"type": "string", "description": "Replacement text (newline separated)"},
        },
        "required": ["replace_lines", "text"],
    },
}

TOOLS = [
    tool("review_queue",
         "Open review threads awaiting your reply (their last comment is not yours). Start here.",
         {**REPO}, []),
    tool("review_list",
         "The full review document: every thread plus the review summary.",
         {**REPO}, []),
    tool("review_add_thread",
         "Start a new review thread anchored to a source line. Ids are minted for you; the comment author is always 'claude'.",
         {**REPO,
          "file": {"type": "string", "description": "Repo-relative path of the file"},
          "line": {"type": "integer", "description": "1-indexed line the thread anchors to"},
          "snippet": {"type": "string", "description": "EXACT current text of the anchored line (required — anchors survive drift through it)"},
          "body": {"type": "string", "description": "The comment text"},
          "end_line": {"type": "integer", "description": "Last line of the anchored range (defaults to line)"},
          "side": {"type": "string", "enum": ["a", "b"], "description": "'b' = new/right side (default), 'a' = old/deleted lines"},
          "rev": {"type": "string", "description": "'WORKING' (default) = working tree; ':0' = index; else a full SHA"},
          "ctx_before": {"type": "string", "description": "Text of the line above (include when it exists)"},
          "ctx_after": {"type": "string", "description": "Text of the line below (include when it exists)"},
          **SUGGESTION},
         ["file", "line", "snippet", "body"]),
    tool("review_reply",
         "Append your reply to an existing thread. The author is always 'claude'.",
         {**REPO,
          "thread_id": {"type": "string"},
          "body": {"type": "string"},
          **SUGGESTION},
         ["thread_id", "body"]),
    tool("review_edit_comment",
         "Amend one of YOUR OWN comments. Refused for any comment whose author is not 'claude'.",
         {**REPO,
          "comment_id": {"type": "string"},
          "body": {"type": "string", "description": "Replacement body"}},
         ["comment_id", "body"]),
    tool("review_set_status",
         "Mark a thread 'applied' after you actually changed the code. Only 'applied' is accepted — resolving is the human's call.",
         {**REPO,
          "thread_id": {"type": "string"},
          "status": {"type": "string", "enum": ["applied"]}},
         ["thread_id", "status"]),
    tool("review_set_summary",
         "Set the overall verdict of the review pass (one paragraph).",
         {**REPO, "summary": {"type": "string"}},
         ["summary"]),
]


def handle_tool(name, args):
    path = core.derive_review_file(cwd=args.get("repo"))

    if name == "review_queue":
        return core.read_queue(path)
    if name == "review_list":
        return core.read_list(path)

    if name == "review_add_thread":
        anchor = {"path": args.get("file"), "line": args.get("line"),
                  "snippet": args.get("snippet")}
        for key in ("side", "rev", "end_line", "ctx_before", "ctx_after"):
            if args.get(key) is not None:
                anchor[key] = args[key]
        op = {"op": "add_thread", "anchor": anchor, "body": args.get("body")}
    elif name == "review_reply":
        op = {"op": "add_comment", "thread_id": args.get("thread_id"),
              "body": args.get("body")}
    elif name == "review_edit_comment":
        op = {"op": "edit_comment", "comment_id": args.get("comment_id"),
              "body": args.get("body")}
    elif name == "review_set_status":
        op = {"op": "set_status", "thread_id": args.get("thread_id"),
              "status": args.get("status")}
    elif name == "review_set_summary":
        op = {"op": "set_summary", "summary": args.get("summary")}
    else:
        raise core.ReviewError(1, "unknown tool: %s" % name)

    if args.get("suggestion") is not None and op["op"] in ("add_thread", "add_comment"):
        op["suggestion"] = args["suggestion"]

    return core.write_ops(path, [op])


def send(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def reply(mid, result):
    send({"jsonrpc": "2.0", "id": mid, "result": result})


def rpc_error(mid, code, message):
    send({"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}})


def run():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            print("review_mcp: ignoring non-JSON line", file=sys.stderr)
            continue

        method = msg.get("method")
        mid = msg.get("id")

        if method == "initialize":
            reply(mid, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": "0.1.0"},
                "instructions": INSTRUCTIONS,
            })
        elif method == "notifications/initialized":
            pass
        elif method == "ping" and mid is not None:
            reply(mid, {})
        elif method == "tools/list" and mid is not None:
            reply(mid, {"tools": TOOLS})
        elif method == "tools/call" and mid is not None:
            params = msg.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            try:
                result = handle_tool(name, args)
                reply(mid, {"content": [{
                    "type": "text",
                    "text": json.dumps(result, indent=2, ensure_ascii=False),
                }]})
            except core.ReviewError as e:
                reply(mid, {"content": [{
                    "type": "text",
                    "text": "error(%d): %s" % (e.code, e.message),
                }], "isError": True})
            except Exception as e:  # never let one call kill the server
                reply(mid, {"content": [{
                    "type": "text",
                    "text": "internal error: %s" % e,
                }], "isError": True})
        elif mid is not None:
            rpc_error(mid, -32601, "method not found: %s" % method)


if __name__ == "__main__":
    run()
