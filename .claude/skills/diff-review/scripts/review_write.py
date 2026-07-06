#!/usr/bin/env python3
"""AI-side writer for diffview.nvim's shared review file.

The ONLY sanctioned way for the AI to write <git-dir>/diffview-review.json.
Neovim writes the same file under a lock (lua/diffview/comments/store.lua);
this helper takes the SAME lock, re-reads the file fresh, merges the caller's
ops, and writes atomically — so neither writer can lose the other's work.

Keep in sync with store.lua (both sides carry a matching comment):
  * lockfile protocol: <file>.lock, O_CREAT|O_EXCL, 5 tries x 40ms, steal
    locks staler than 10s
  * atomic write: <file>.tmp.<pid>, write-all + fsync, rename; never replace
    the target on a short write
  * pretty-printer: 2-space indent, KEY_ORDER-sorted keys

Deliberately NOT mirrored from store.lua: GC and last-written hashing. This
is an external writer — Neovim's watcher must see the write and reload; GC
runs on the Neovim side.

Usage:
    review_write.py <review-file>      # ops JSON on stdin

stdin is {"ops": [op, ...]} or a bare [op, ...]; each op is one of:
    {"op": "add_thread", "anchor": {...}, "body": "...", "suggestion": {...}?}
    {"op": "add_comment", "thread_id": "t-..", "body": "...", "suggestion": {...}?}
    {"op": "edit_comment", "comment_id": "c-..", "body": "..."}
    {"op": "set_status", "thread_id": "t-..", "status": "applied"}
    {"op": "set_summary", "summary": "..."}

Enforced invariants (violation = nonzero exit, NOTHING written):
    * every id is minted here — callers never supply ids
    * author is always "claude"; comments by anyone else are untouchable
    * status may only be set to "applied" — resolving is the human's call

Exit codes: 0 ok; 1 usage/ops error; 2 invariant violation; 3 unreadable
review file (left untouched); 4 lock timeout; 5 write failure.
On success stdout is JSON: {"ok": true, "minted": [...]}.
"""

import json
import os
import secrets
import sys
import time

VERSION = 1
LOCK_TRIES = 5
LOCK_SLEEP_S = 0.04
LOCK_STALE_S = 10

# Mirror of store.lua's KEY_ORDER — keep in sync.
KEY_ORDER = {
    "version": 1, "review": 2, "threads": 3,
    "id": 10, "anchor": 11, "status": 12, "created_at": 13, "updated_at": 14,
    "outdated_since": 15, "resolved_reason": 16, "comments": 17,
    "path": 20, "side": 21, "rev": 22, "line": 23, "end_line": 24,
    "snippet": 25, "ctx_before": 26, "ctx_after": 27,
    "author": 30, "ts": 31, "body": 32, "suggestion": 33,
    "replace_lines": 40, "text": 41,
    "summary": 50,
}


def die(code, msg):
    print("review_write: " + msg, file=sys.stderr)
    sys.exit(code)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# -- encoder (mirror of store.lua M.encode) ---------------------------------

def encode(value, indent=0):
    pad = "  " * indent
    pad_in = "  " * (indent + 1)

    if isinstance(value, list):
        if not value:
            return "[]"
        parts = [pad_in + encode(v, indent + 1) for v in value]
        return "[\n" + ",\n".join(parts) + "\n" + pad + "]"

    if isinstance(value, dict):
        if not value:
            return "{}"
        keys = sorted(value.keys(), key=lambda k: (KEY_ORDER.get(k, 99), str(k)))
        parts = [
            "%s%s: %s" % (pad_in, json.dumps(str(k), ensure_ascii=False),
                          encode(value[k], indent + 1))
            for k in keys
        ]
        return "{\n" + ",\n".join(parts) + "\n" + pad + "}"

    # Lua prints integral doubles without a decimal point.
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return json.dumps(value, ensure_ascii=False)


# -- lock + atomic write (mirror of store.lua lock()/write_atomic()) --------

def acquire_lock(path):
    lockfile = path + ".lock"
    for _ in range(LOCK_TRIES):
        try:
            fd = os.open(lockfile, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            return lockfile
        except FileExistsError:
            pass
        try:
            if time.time() - os.stat(lockfile).st_mtime > LOCK_STALE_S:
                os.unlink(lockfile)  # steal a crashed writer's lock
                continue
        except OSError:
            continue  # lock vanished — retry immediately
        time.sleep(LOCK_SLEEP_S)
    return None


def write_atomic(path, content):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    data = content.encode("utf-8")
    fd = None
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
        off = 0
        while off < len(data):
            n = os.write(fd, data[off:])
            if n <= 0:
                raise OSError("short write")
            off += n
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(tmp, path)
        return True
    except OSError:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


# -- document ---------------------------------------------------------------

def load_doc(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raw = b""
    except OSError as e:
        die(3, "cannot read %s: %s" % (path, e))

    if not raw.strip():
        return {"version": VERSION, "review": {}, "threads": []}

    try:
        doc = json.loads(raw)
    except ValueError as e:
        die(3, "review file is not valid JSON (%s) — refusing to touch it; "
               "let Neovim repair it" % e)

    # Structural sanity: refuse rather than repair (repair is Neovim's job).
    if not isinstance(doc, dict) or not isinstance(doc.get("version"), int):
        die(3, "review file has no valid version field — refusing to touch it")
    if not isinstance(doc.get("review"), dict):
        doc["review"] = {}
    if not isinstance(doc.get("threads"), list):
        doc["threads"] = []
    return doc


def mint_id(prefix, used):
    while True:
        new = "%s-%s" % (prefix, secrets.token_hex(3))
        if new not in used:
            used.add(new)
            return new


# -- op validation ----------------------------------------------------------

def as_str(value, field, opi, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and value.strip() == ""):
        die(1, "op %d: %s must be a non-empty string" % (opi, field))
    return value


def as_int(value, field, opi, minimum=1):
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        die(1, "op %d: %s must be an integer >= %d" % (opi, field, minimum))
    return value


def check_suggestion(sug, opi):
    if sug is None:
        return None
    if not isinstance(sug, dict):
        die(1, "op %d: suggestion must be an object" % opi)
    rl = sug.get("replace_lines")
    if (not isinstance(rl, list) or len(rl) != 2
            or not all(isinstance(n, int) and not isinstance(n, bool) for n in rl)
            or rl[0] < 1 or rl[1] < rl[0]):
        die(1, "op %d: suggestion.replace_lines must be [first, last], "
               "1-indexed, first <= last" % opi)
    text = sug.get("text")
    if not isinstance(text, str):
        die(1, "op %d: suggestion.text must be a string" % opi)
    return {"replace_lines": [rl[0], rl[1]], "text": text}


def check_anchor(anchor, opi):
    if not isinstance(anchor, dict):
        die(1, "op %d: add_thread needs an anchor object" % opi)
    line = as_int(anchor.get("line"), "anchor.line", opi)
    side = anchor.get("side", "b")
    if side not in ("a", "b"):
        die(1, 'op %d: anchor.side must be "a" or "b"' % opi)
    snippet = anchor.get("snippet")
    if not isinstance(snippet, str):
        die(1, "op %d: anchor.snippet is required — the EXACT text of the "
               "anchored line (may be empty for a blank line)" % opi)

    out = {
        "path": as_str(anchor.get("path"), "anchor.path", opi),
        "side": side,
        "rev": as_str(anchor.get("rev", "WORKING"), "anchor.rev", opi),
        "line": line,
        "end_line": as_int(anchor.get("end_line", line), "anchor.end_line",
                           opi, minimum=line),
        "snippet": snippet,
    }
    for key in ("ctx_before", "ctx_after"):
        val = anchor.get(key)
        if val is not None:
            if not isinstance(val, str):
                die(1, "op %d: anchor.%s must be a string" % (opi, key))
            out[key] = val
    return out


def find_thread(doc, tid, opi):
    for t in doc["threads"]:
        if isinstance(t, dict) and t.get("id") == tid:
            return t
    die(1, "op %d: thread %s not found" % (opi, tid))


# -- op application (all-or-nothing: any die() happens before the write) ----

def apply_ops(doc, ops):
    used = set()
    for t in doc["threads"]:
        if isinstance(t, dict):
            used.add(t.get("id"))
            for c in t.get("comments") or []:
                if isinstance(c, dict):
                    used.add(c.get("id"))

    minted = []
    ts = now_iso()

    for i, op in enumerate(ops):
        if not isinstance(op, dict):
            die(1, "op %d: each op must be an object" % i)
        kind = op.get("op")

        if kind == "add_thread":
            anchor = check_anchor(op.get("anchor"), i)
            body = as_str(op.get("body"), "body", i)
            tid = mint_id("t", used)
            cid = mint_id("c", used)
            comment = {"id": cid, "author": "claude", "ts": ts, "body": body}
            sug = check_suggestion(op.get("suggestion"), i)
            if sug:
                comment["suggestion"] = sug
            doc["threads"].append({
                "id": tid,
                "anchor": anchor,
                "status": "open",
                "created_at": ts,
                "updated_at": ts,
                "comments": [comment],
            })
            minted.append({"op": i, "thread_id": tid, "comment_id": cid})

        elif kind == "add_comment":
            thread = find_thread(
                doc, as_str(op.get("thread_id"), "thread_id", i), i)
            body = as_str(op.get("body"), "body", i)
            cid = mint_id("c", used)
            comment = {"id": cid, "author": "claude", "ts": ts, "body": body}
            sug = check_suggestion(op.get("suggestion"), i)
            if sug:
                comment["suggestion"] = sug
            thread.setdefault("comments", []).append(comment)
            thread["updated_at"] = ts
            minted.append({"op": i, "comment_id": cid})

        elif kind == "edit_comment":
            cid = as_str(op.get("comment_id"), "comment_id", i)
            target, parent = None, None
            for t in doc["threads"]:
                for c in (t.get("comments") or []) if isinstance(t, dict) else []:
                    if isinstance(c, dict) and c.get("id") == cid:
                        target, parent = c, t
            if target is None:
                die(1, "op %d: comment %s not found" % (i, cid))
            if target.get("author") != "claude":
                die(2, "op %d: refusing to edit comment %s — its author is "
                       "%r, not claude. Others' comments are untouchable."
                       % (i, cid, target.get("author")))
            target["body"] = as_str(op.get("body"), "body", i)
            parent["updated_at"] = ts

        elif kind == "set_status":
            status = op.get("status")
            if status != "applied":
                die(2, 'op %d: set_status only accepts "applied" — '
                       "resolving (or reopening) is the human's call" % i)
            thread = find_thread(
                doc, as_str(op.get("thread_id"), "thread_id", i), i)
            thread["status"] = "applied"
            thread["updated_at"] = ts

        elif kind == "set_summary":
            doc["review"]["summary"] = as_str(
                op.get("summary"), "summary", i)

        else:
            die(1, "op %d: unknown op %r" % (i, kind))

    return minted


# -- main ---------------------------------------------------------------------

def main():
    if len(sys.argv) != 2:
        die(1, "usage: review_write.py <review-file>  (ops JSON on stdin)")
    path = sys.argv[1]

    try:
        payload = json.load(sys.stdin)
    except ValueError as e:
        die(1, "stdin is not valid JSON: %s" % e)

    ops = payload.get("ops") if isinstance(payload, dict) else payload
    if not isinstance(ops, list) or not ops:
        die(1, 'no ops: stdin must be {"ops": [...]} or a bare [...] '
               "with at least one op")

    lockfile = acquire_lock(path)
    if lockfile is None:
        die(4, "could not lock the review file (another writer is stuck? "
               "locks staler than %ds are stolen automatically)" % LOCK_STALE_S)

    try:
        doc = load_doc(path)
        minted = apply_ops(doc, ops)
        doc["version"] = VERSION
        doc["review"]["updated_at"] = now_iso()

        if not write_atomic(path, encode(doc) + "\n"):
            die(5, "atomic write failed — the review file was left untouched")

        print(json.dumps({"ok": True, "minted": minted}))
    finally:
        try:
            os.unlink(lockfile)
        except OSError:
            pass


if __name__ == "__main__":
    main()
