-- The review store: one JSON file per repo (inside the git dir) holding all
-- comment threads. Both Neovim and the AI read/write it; there is no daemon.
--
-- Write discipline (both writers follow it):
--   * merge-on-write: read the file fresh, apply your delta, write — never
--     serialize stale in-memory state over the file.
--   * atomic replace: write a temp file, then rename over the target.
--   * self-event suppression: remember the hash of what you wrote so the
--     fs-watcher can ignore your own writes.
--
-- The file is capped: GC runs on every write, dropping old resolved/outdated
-- threads first. Open threads are never dropped silently.

local lazy = require("diffview.lazy")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local uv = vim.uv or vim.loop
local M = {}

M.VERSION = 1
M.FILENAME = "diffview-review.json"

M.MAX_THREADS = 200
M.MAX_BYTES = 512 * 1024
M.TTL_RESOLVED = 7 * 24 * 3600 -- seconds a resolved/applied thread survives
M.TTL_OUTDATED = 2 * 24 * 3600 -- seconds an outdated thread survives

---Content hash of our last write, for self-event suppression.
---@type table<string, string>
M.last_written = {}

---@class ReviewSuggestion
---@field replace_lines { [1]: integer, [2]: integer } 1-indexed inclusive range in the anchored file
---@field text string Replacement text (newline separated)

---@class ReviewComment
---@field id string
---@field author string e.g. "eyal" | "claude"
---@field ts string ISO-8601 UTC
---@field body string
---@field suggestion? ReviewSuggestion

---@class ReviewAnchor
---@field path string Repo-relative file path
---@field side "a"|"b"
---@field rev string "WORKING" | ":0" | full SHA
---@field line integer
---@field end_line integer
---@field snippet string The anchored line's text at comment time
---@field ctx_before? string
---@field ctx_after? string

---@class ReviewThread
---@field id string
---@field anchor ReviewAnchor
---@field status "open"|"resolved"|"applied"
---@field created_at string
---@field updated_at string
---@field outdated_since? string
---@field resolved_reason? string
---@field comments ReviewComment[]

---@class ReviewDoc
---@field version integer
---@field review { summary?: string, updated_at?: string }
---@field threads ReviewThread[]

--#region time / id helpers

---@return string
function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string ]]
end

---Parse an ISO-8601 UTC timestamp to a unix epoch. Returns nil on garbage.
---@param ts? string
---@return integer?
function M.parse_ts(ts)
  if type(ts) ~= "string" then return nil end
  local y, mo, d, h, mi, s = ts:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local epoch = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  if not epoch then return nil end
  -- The fields are UTC, but os.time() read them as local time: shift by the
  -- local↔UTC offset, computed at the parsed moment so sessions spanning a
  -- DST change stay correct (≤1h residual right at a boundary — immaterial
  -- against day-scale TTLs). os.date("!*t") pins isdst=false, which would
  -- bias zones currently on summer time by an hour — drop it so mktime
  -- decides.
  local utc = os.date("!*t", epoch) --[[@as osdateparam]]
  utc.isdst = nil
  local off = os.difftime(os.time(os.date("*t", epoch) --[[@as osdateparam]]), os.time(utc))
  return epoch + off
end

-- Seed once per process: LuaJIT does not auto-seed, so without this two
-- editors launched close together would draw identical random sequences.
math.randomseed(uv.hrtime() + uv.os_getpid())

local id_counter = 0

---@param prefix string
---@return string
function M.gen_id(prefix)
  id_counter = id_counter + 1
  return ("%s-%x%x%x%x"):format(
    prefix, os.time() % 0xffffff, uv.os_getpid() % 0xffff, math.random(0xffff), id_counter)
end

--#endregion

--#region JSON

-- Key order for pretty printing: humans and the AI both read this file —
-- stable, readable output matters. Keep the order and format in sync with
-- the encoder in skills/review/scripts/review_write.py so the two
-- writers don't churn each other's formatting.
local KEY_ORDER = {
  version = 1, review = 2, threads = 3,
  id = 10, anchor = 11, status = 12, created_at = 13, updated_at = 14,
  outdated_since = 15, resolved_reason = 16, comments = 17,
  path = 20, side = 21, rev = 22, line = 23, end_line = 24,
  snippet = 25, ctx_before = 26, ctx_after = 27,
  author = 30, ts = 31, body = 32, suggestion = 33,
  replace_lines = 40, text = 41,
  summary = 50,
}

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(x, y)
    local ox, oy = KEY_ORDER[x] or 99, KEY_ORDER[y] or 99
    if ox ~= oy then return ox < oy end
    return tostring(x) < tostring(y)
  end)
  return keys
end

---Pretty-print a plain lua table as JSON (2-space indent, stable key order).
---@param value any
---@param indent? integer
---@return string
function M.encode(value, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local pad_in = string.rep("  ", indent + 1)

  if type(value) == "table" then
    if vim.islist(value) then
      if #value == 0 then return "[]" end
      local parts = {}
      for _, v in ipairs(value) do
        parts[#parts + 1] = pad_in .. M.encode(v, indent + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    else
      if next(value) == nil then return "{}" end
      local parts = {}
      for _, k in ipairs(sorted_keys(value)) do
        parts[#parts + 1] = ("%s%s: %s"):format(pad_in, vim.json.encode(tostring(k)), M.encode(value[k], indent + 1))
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
  end

  return vim.json.encode(value)
end

--#endregion

--#region document access

---@param adapter VCSAdapter
---@return string
function M.path_for(adapter)
  return utils.path:join(adapter.ctx.dir, M.FILENAME)
end

---@return ReviewDoc
function M.empty_doc()
  return { version = M.VERSION, review = {}, threads = {} }
end

---Validate + normalize a decoded document. Invalid threads are dropped.
---@param doc any
---@return ReviewDoc? doc
---@return integer dropped
local function validate(doc)
  if type(doc) ~= "table" or type(doc.version) ~= "number" then
    return nil, 0
  end

  doc.review = type(doc.review) == "table" and doc.review or {}
  local threads = type(doc.threads) == "table" and doc.threads or {}
  local valid, dropped = {}, 0

  for _, t in ipairs(threads) do
    local a = type(t) == "table" and t.anchor or nil
    if type(t) == "table"
      and type(t.id) == "string"
      and type(a) == "table"
      and type(a.path) == "string"
      and type(a.line) == "number"
      and type(t.comments) == "table"
    then
      t.status = (t.status == "resolved" or t.status == "applied") and t.status or "open"
      a.side = (a.side == "a") and "a" or "b"
      a.end_line = type(a.end_line) == "number" and a.end_line or a.line
      valid[#valid + 1] = t
    else
      dropped = dropped + 1
    end
  end

  doc.threads = valid
  return doc, dropped
end

---Load the review file. On corruption, the broken file is backed up to
---`<path>.bak` and an empty doc is returned.
---@param path string
---@return ReviewDoc doc
---@return string? warn
function M.load(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return M.empty_doc(), nil end

  local stat = uv.fs_fstat(fd)
  local content = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)

  if not content or content == "" then return M.empty_doc(), nil end

  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  local doc, dropped = nil, 0
  if ok then doc, dropped = validate(decoded) end

  if not doc then
    pcall(uv.fs_rename, path, path .. ".bak")
    return M.empty_doc(), ("Corrupt review file backed up to %s.bak"):format(path)
  end

  if dropped > 0 then
    return doc, ("Dropped %d invalid thread(s) from the review file"):format(dropped)
  end

  return doc, nil
end

---Garbage-collect a document in place. Never drops open threads.
---@param doc ReviewDoc
---@param now? integer epoch
---@return integer removed
function M.gc(doc, now)
  now = now or os.time()
  local kept, removed = {}, 0

  for _, t in ipairs(doc.threads) do
    local drop = false
    local age_ref = M.parse_ts(t.updated_at) or M.parse_ts(t.created_at)

    if (t.status == "resolved" or t.status == "applied") and age_ref and now - age_ref > M.TTL_RESOLVED then
      drop = true
    elseif t.status == "open" and t.outdated_since then
      local since = M.parse_ts(t.outdated_since)
      if since and now - since > M.TTL_OUTDATED then drop = true end
    end

    if drop then removed = removed + 1 else kept[#kept + 1] = t end
  end
  doc.threads = kept

  -- Hard caps: prune resolved/applied oldest-first, then outdated open ones.
  local function prune_one()
    local best_i, best_age
    for i, t in ipairs(doc.threads) do
      if t.status ~= "open" or t.outdated_since then
        local age = M.parse_ts(t.updated_at) or M.parse_ts(t.created_at) or 0
        if not best_age or age < best_age then best_i, best_age = i, age end
      end
    end
    if best_i then
      table.remove(doc.threads, best_i)
      removed = removed + 1
      return true
    end
    return false
  end

  while #doc.threads > M.MAX_THREADS do
    if not prune_one() then
      utils.warn("[diffview] Review file over thread cap, but all threads are open — not pruning.")
      break
    end
  end

  while #M.encode(doc) > M.MAX_BYTES do
    if not prune_one() then
      utils.warn("[diffview] Review file over size cap, but all threads are open — not pruning.")
      break
    end
  end

  return removed
end

--#endregion

--#region locking + atomic write

---Keep the lockfile protocol in sync with the AI-side writer:
---skills/review/scripts/review_core.py (same lockfile name and stale-steal
---threshold; retry cadence may differ — the CLI blocks, Neovim must not).
M.LOCK_STALE_S = 10
M.LOCK_RETRY_MS = 40
M.LOCK_RETRIES = 25

---One non-blocking attempt to take the lockfile.
---@param path string
---@return boolean acquired
local function try_lock(path)
  local lockfile = path .. ".lock"
  local fd = uv.fs_open(lockfile, "wx", 384)
  if fd then
    uv.fs_close(fd)
    return true
  end

  -- Steal stale locks (a crashed writer). The steal is atomic: rename the
  -- stale lockfile to a unique name — only one contender's rename can
  -- succeed — then unlink the claimed name. A plain unlink here would let
  -- two writers both decide the lock is stale, with the second unlink
  -- deleting the first stealer's freshly created lock.
  local stat = uv.fs_stat(lockfile)
  if stat and os.time() - stat.mtime.sec > M.LOCK_STALE_S then
    local claimed = ("%s.stale.%d"):format(lockfile, uv.os_getpid())
    if uv.fs_rename(lockfile, claimed) then
      pcall(uv.fs_unlink, claimed)
      fd = uv.fs_open(lockfile, "wx", 384)
      if fd then
        uv.fs_close(fd)
        return true
      end
    end
  end
  return false
end

local function unlock(path)
  pcall(uv.fs_unlink, path .. ".lock")
end

---Atomically write `content` to `path` (temp file + rename). The temp file
---never replaces the target unless every byte was written and fsynced — a
---short write (e.g. disk full) must not clobber a good store.
---@param path string
---@param content string
---@return boolean ok
local function write_atomic(path, content)
  local tmp = ("%s.tmp.%d"):format(path, uv.os_getpid())
  local fd = uv.fs_open(tmp, "w", 420)
  if not fd then return false end

  local written = 0
  while written < #content do
    local n = uv.fs_write(fd, content:sub(written + 1), written)
    if not n or n <= 0 then break end
    written = written + n
  end

  local ok = written == #content and uv.fs_fsync(fd) ~= nil
  uv.fs_close(fd)

  if not ok or uv.fs_rename(tmp, path) == nil then
    pcall(uv.fs_unlink, tmp)
    return false
  end
  return true
end

---The single write entry point: lock, read fresh, apply the caller's delta,
---GC, write atomically, remember the content hash for self-suppression.
---
---Never blocks the UI: the first lock attempt runs inline (the uncontended
---case completes synchronously), contention is retried from the event loop.
---`on_done` is called exactly once — with the written doc, or with
---(nil, err) once the retry budget runs out or the write fails.
---@param path string
---@param apply fun(doc: ReviewDoc) Mutates the freshly loaded doc.
---@param on_done? fun(doc?: ReviewDoc, err?: string)
function M.update(path, apply, on_done)
  local function locked_write()
    local ok, result = pcall(function()
      local doc = M.load(path)
      apply(doc)
      doc.version = M.VERSION
      doc.review.updated_at = M.now()
      M.gc(doc)

      local content = M.encode(doc) .. "\n"
      if not write_atomic(path, content) then
        error("Failed to write the review file: " .. path)
      end

      M.last_written[path] = vim.fn.sha256(content)
      return doc
    end)

    unlock(path)

    if on_done then
      if ok then on_done(result, nil) else on_done(nil, tostring(result)) end
    end
  end

  local attempts = 0
  local function attempt()
    if try_lock(path) then return locked_write() end

    attempts = attempts + 1
    if attempts >= M.LOCK_RETRIES then
      if on_done then
        on_done(nil, "Could not lock the review file (another writer is stuck?)")
      end
      return
    end
    vim.defer_fn(attempt, M.LOCK_RETRY_MS)
  end

  attempt()
end

---Check whether the file's current content is our own last write.
---@param path string
---@return boolean
function M.is_own_write(path)
  local last = M.last_written[path]
  if not last then return false end

  local fd = uv.fs_open(path, "r", 438)
  if not fd then return false end
  local stat = uv.fs_fstat(fd)
  local content = stat and uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)

  return vim.fn.sha256(content) == last
end

--#endregion

return M
