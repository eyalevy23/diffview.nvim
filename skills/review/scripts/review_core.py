"""Shared core for diff.nvim's review loop — the single Python source of
truth for the AI side of <git-dir>/diffview-review.json.

Both the MCP server (review_mcp.py) and the CLI (review_write.py) import this
module; nothing else may write the review file from the AI side.

Keep in sync with the Neovim writer, lua/diffview/comments/store.lua (both
sides carry matching comments):
  * lockfile protocol: <file>.lock, O_CREAT|O_EXCL, 5 tries x 40ms, steal
    locks staler than 10s
  * atomic write: <file>.tmp.<pid>, write-all + fsync, rename; never replace
    the target on a short write
  * pretty-printer: 2-space indent, KEY_ORDER-sorted keys

Deliberately NOT mirrored from store.lua: GC and last-written hashing. This
is an external writer — Neovim's watcher must see the writes and reload; GC
runs on the Neovim side.

Enforced invariants (violations raise ReviewError; nothing is written):
  * every id is minted here — callers never supply ids
  * author is always "claude"; comments by anyone else are untouchable
  * status may only be set to "applied" — resolving is the human's call

Error contract: operations raise ReviewError(code, message). Codes match the
CLI's exit codes: 1 usage/ops error, 2 invariant violation, 3 unreadable
review file (left untouched), 4 lock timeout, 5 write failure.
"""

import json
import os
import secrets
import subprocess
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


class ReviewError(Exception):
    """A protocol/IO failure. `code` matches the CLI exit-code contract."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


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


# -- repo / review-file location --------------------------------------------

def derive_review_file(cwd=None):
    """<git-dir>/diffview-review.json for the repo containing `cwd` (or the
    process cwd). Raises ReviewError(1) outside a repo or without git."""
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            capture_output=True, text=True, check=True, cwd=cwd)
    except FileNotFoundError:
        raise ReviewError(1, "git not found on PATH")
    except subprocess.CalledProcessError:
        where = cwd or os.getcwd()
        raise ReviewError(
            1, "not in a git repository (%s) — run from inside the repo, "
               "or pass an explicit repo/--review-file" % where)
    git_dir = proc.stdout.strip()
    # rev-parse may print a RELATIVE path (".git") — relative to the
    # directory it ran in, which is not necessarily this process's cwd.
    if not os.path.isabs(git_dir):
        git_dir = os.path.join(cwd or os.getcwd(), git_dir)
    return os.path.join(git_dir, "diffview-review.json")


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
    raise ReviewError(
        4, "could not lock the review file (another writer is stuck? "
           "locks staler than %ds are stolen automatically)" % LOCK_STALE_S)


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
        raise ReviewError(5, "atomic write failed — the review file was left untouched")


# -- document ---------------------------------------------------------------

def load_doc(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raw = b""
    except OSError as e:
        raise ReviewError(3, "cannot read %s: %s" % (path, e))

    if not raw.strip():
        return {"version": VERSION, "review": {}, "threads": []}

    try:
        doc = json.loads(raw)
    except ValueError as e:
        raise ReviewError(
            3, "review file is not valid JSON (%s) — refusing to touch it; "
               "let Neovim repair it" % e)

    # Structural sanity: refuse rather than repair (repair is Neovim's job).
    if not isinstance(doc, dict) or not isinstance(doc.get("version"), int):
        raise ReviewError(3, "review file has no valid version field — refusing to touch it")
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
        raise ReviewError(1, "op %d: %s must be a non-empty string" % (opi, field))
    return value


def as_int(value, field, opi, minimum=1):
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise ReviewError(1, "op %d: %s must be an integer >= %d" % (opi, field, minimum))
    return value


def check_suggestion(sug, opi):
    if sug is None:
        return None
    if not isinstance(sug, dict):
        raise ReviewError(1, "op %d: suggestion must be an object" % opi)
    rl = sug.get("replace_lines")
    if (not isinstance(rl, list) or len(rl) != 2
            or not all(isinstance(n, int) and not isinstance(n, bool) for n in rl)
            or rl[0] < 1 or rl[1] < rl[0]):
        raise ReviewError(
            1, "op %d: suggestion.replace_lines must be [first, last], "
               "1-indexed, first <= last" % opi)
    text = sug.get("text")
    if not isinstance(text, str):
        raise ReviewError(1, "op %d: suggestion.text must be a string" % opi)
    return {"replace_lines": [rl[0], rl[1]], "text": text}


def check_anchor(anchor, opi):
    if not isinstance(anchor, dict):
        raise ReviewError(1, "op %d: add_thread needs an anchor object" % opi)
    line = as_int(anchor.get("line"), "anchor.line", opi)
    side = anchor.get("side", "b")
    if side not in ("a", "b"):
        raise ReviewError(1, 'op %d: anchor.side must be "a" or "b"' % opi)
    snippet = anchor.get("snippet")
    if not isinstance(snippet, str):
        raise ReviewError(
            1, "op %d: anchor.snippet is required — the EXACT text of the "
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
                raise ReviewError(1, "op %d: anchor.%s must be a string" % (opi, key))
            out[key] = val
    return out


def find_thread(doc, tid, opi):
    for t in doc["threads"]:
        if isinstance(t, dict) and t.get("id") == tid:
            return t
    raise ReviewError(1, "op %d: thread %s not found" % (opi, tid))


# -- op application (all-or-nothing: any raise happens before the write) ----

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
            raise ReviewError(1, "op %d: each op must be an object" % i)
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
                raise ReviewError(1, "op %d: comment %s not found" % (i, cid))
            if target.get("author") != "claude":
                raise ReviewError(
                    2, "op %d: refusing to edit comment %s — its author is "
                       "%r, not claude. Others' comments are untouchable."
                       % (i, cid, target.get("author")))
            target["body"] = as_str(op.get("body"), "body", i)
            parent["updated_at"] = ts

        elif kind == "set_status":
            status = op.get("status")
            if status != "applied":
                raise ReviewError(
                    2, 'op %d: set_status only accepts "applied" — '
                       "resolving (or reopening) is the human's call" % i)
            thread = find_thread(
                doc, as_str(op.get("thread_id"), "thread_id", i), i)
            thread["status"] = "applied"
            thread["updated_at"] = ts

        elif kind == "set_summary":
            doc["review"]["summary"] = as_str(op.get("summary"), "summary", i)

        else:
            raise ReviewError(1, "op %d: unknown op %r" % (i, kind))

    return minted


# -- transactions -----------------------------------------------------------

def write_ops(path, ops):
    """The full locked write: lock, fresh read, apply, atomic write, unlock.
    Returns {"ok": True, "minted": [...]}. Raises ReviewError on any failure
    (nothing is written)."""
    if not isinstance(ops, list) or not ops:
        raise ReviewError(1, 'no ops: expected {"ops": [...]} or a bare [...] '
                             "with at least one op")
    lockfile = acquire_lock(path)
    try:
        doc = load_doc(path)
        minted = apply_ops(doc, ops)
        doc["version"] = VERSION
        doc["review"]["updated_at"] = now_iso()
        write_atomic(path, encode(doc) + "\n")
        return {"ok": True, "minted": minted}
    finally:
        try:
            os.unlink(lockfile)
        except OSError:
            pass


def awaiting_claude(thread):
    """Open thread whose last comment is not claude's (or has no comments)."""
    if not isinstance(thread, dict) or thread.get("status", "open") != "open":
        return False
    comments = thread.get("comments") or []
    last = comments[-1] if comments else None
    return not (isinstance(last, dict) and last.get("author") == "claude")


def read_list(path):
    """The full review document. Reads take no lock: the atomic rename both
    writers use makes any on-disk state a consistent snapshot."""
    return load_doc(path)


def read_queue(path):
    """Open threads awaiting claude — the work queue."""
    return [t for t in load_doc(path)["threads"] if awaiting_claude(t)]
