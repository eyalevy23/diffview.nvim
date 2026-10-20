-- The AI side of the review loop, run outside the editor with Neovim as the
-- Lua runtime (skills/review/scripts/review.lua is the entry point):
--
--   nvim --clean -l review.lua mcp       MCP server Claude Code spawns (stdio)
--   nvim --clean -l review.lua --queue   CLI for agents without MCP
--
-- Every write goes through store.update — the same lock, atomic write and
-- encoder Neovim uses — so the two writers cannot drift apart.
--
-- Enforced invariants (a violation fails the whole call; nothing is written):
--   * every id is minted here — callers never supply ids
--   * the author is always "claude"; anyone else's comments are untouchable
--   * status may only become "applied" — resolving is the human's call
--   * a review file that isn't valid review JSON is refused, never repaired
--     (repair is Neovim's job: store.load backs it up)
--
-- Error contract: failures carry a code, also the CLI's exit code: 1 usage /
-- ops error, 2 invariant violation, 3 unreadable review file (left
-- untouched), 4 lock timeout, 5 write failure.

local store = require("diffview.comments.store")

local uv = vim.uv or vim.loop
local M = {}

M.AUTHOR = "claude"

local PROTOCOL_VERSION = "2024-11-05"
local SERVER_NAME = "diff-nvim"

---@class ReviewAgentError
---@field code integer
---@field msg string

local function fail(code, fmt, ...)
  error({ code = code, msg = fmt:format(...) }, 0)
end

---@param err any
---@return ReviewAgentError
local function as_agent_error(err)
  if type(err) == "table" and err.code then return err end
  return { code = 1, msg = "internal error: " .. tostring(err) }
end

--#region review file

---<git-dir>/diffview-review.json for the repo containing `cwd` (default: the
---process cwd — Claude Code spawns the server in the session's project).
---@param cwd? string
---@return string
function M.review_file(cwd)
  local ok, res = pcall(function()
    return vim.system({ "git", "rev-parse", "--absolute-git-dir" }, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    fail(1, "cannot run git in %s: %s", cwd or uv.cwd(), tostring(res))
  end
  if res.code ~= 0 then
    fail(1, "not in a git repository (%s) — run from inside the repo, "
      .. "or pass an explicit repo/--review-file", cwd or uv.cwd())
  end
  return vim.trim(res.stdout) .. "/" .. store.FILENAME
end

---Strict read: a missing or empty file is an empty review; anything that
---isn't a review document fails with code 3 and stays untouched.
---@param path string
---@return ReviewDoc
function M.read(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return { version = store.VERSION, review = vim.empty_dict(), threads = {} } end
  local stat = uv.fs_fstat(fd)
  local content = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  if not content then fail(3, "cannot read %s", path) end
  if vim.trim(content) == "" then return { version = store.VERSION, review = vim.empty_dict(), threads = {} } end

  local ok, doc = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok then
    fail(3, "review file is not valid JSON (%s) — refusing to touch it; let Neovim repair it", tostring(doc))
  end
  if type(doc) ~= "table" or type(doc.version) ~= "number" then
    fail(3, "review file has no valid version field — refusing to touch it")
  end
  -- An empty review must still encode as {} (store.encode prints an empty
  -- table as a list).
  doc.review = type(doc.review) == "table" and next(doc.review) and doc.review or vim.empty_dict()
  doc.threads = type(doc.threads) == "table" and doc.threads or {}
  return doc
end

---Open threads awaiting the AI — its work queue.
---@param path string
---@return ReviewThread[]
function M.queue(path)
  return vim.tbl_filter(store.awaiting_ai, M.read(path).threads)
end

--#endregion

--#region ops

local function as_str(value, field, opi)
  if type(value) ~= "string" or vim.trim(value) == "" then
    fail(1, "op %d: %s must be a non-empty string", opi, field)
  end
  return value
end

local function as_int(value, field, opi, minimum)
  minimum = minimum or 1
  if type(value) ~= "number" or value % 1 ~= 0 or value < minimum then
    fail(1, "op %d: %s must be an integer >= %d", opi, field, minimum)
  end
  return value
end

---@return ReviewAnchor
local function check_anchor(anchor, opi)
  if type(anchor) ~= "table" then fail(1, "op %d: add_thread needs an anchor object", opi) end
  local line = as_int(anchor.line, "anchor.line", opi)
  local side = anchor.side or "b"
  if side ~= "a" and side ~= "b" then fail(1, 'op %d: anchor.side must be "a" or "b"', opi) end
  if type(anchor.snippet) ~= "string" then
    fail(1, "op %d: anchor.snippet is required — the EXACT text of the anchored line "
      .. "(may be empty for a blank line)", opi)
  end

  local out = {
    path = as_str(anchor.path, "anchor.path", opi),
    side = side,
    rev = as_str(anchor.rev or "WORKING", "anchor.rev", opi),
    line = line,
    end_line = as_int(anchor.end_line or line, "anchor.end_line", opi, line),
    snippet = anchor.snippet,
  }
  for _, key in ipairs({ "ctx_before", "ctx_after" }) do
    if anchor[key] ~= nil then
      if type(anchor[key]) ~= "string" then fail(1, "op %d: anchor.%s must be a string", opi, key) end
      out[key] = anchor[key]
    end
  end
  return out
end

local function find_thread(doc, tid, opi)
  for _, t in ipairs(doc.threads) do
    if t.id == tid then return t end
  end
  fail(1, "op %d: thread %s not found", opi, tid)
end

---Apply ops to a freshly loaded doc, all or nothing: every failure raises
---before the caller writes. Ops are indexed from 0 in messages, like the
---minted list.
---@param doc ReviewDoc
---@param ops table[]
---@return table[] minted
function M.apply_ops(doc, ops)
  local minted = {}
  local ts = store.now()

  for i, op in ipairs(ops) do
    local opi = i - 1
    if type(op) ~= "table" then fail(1, "op %d: each op must be an object", opi) end
    local kind = op.op

    if kind == "add_thread" then
      local anchor = check_anchor(op.anchor, opi)
      local body = as_str(op.body, "body", opi)
      local tid, cid = store.gen_id("t"), store.gen_id("c")
      doc.threads[#doc.threads + 1] = {
        id = tid,
        anchor = anchor,
        status = "open",
        created_at = ts,
        updated_at = ts,
        comments = { { id = cid, author = M.AUTHOR, ts = ts, body = body } },
      }
      minted[#minted + 1] = { op = opi, thread_id = tid, comment_id = cid }

    elseif kind == "add_comment" then
      local thread = find_thread(doc, as_str(op.thread_id, "thread_id", opi), opi)
      local body = as_str(op.body, "body", opi)
      local cid = store.gen_id("c")
      thread.comments = thread.comments or {}
      thread.comments[#thread.comments + 1] = { id = cid, author = M.AUTHOR, ts = ts, body = body }
      thread.updated_at = ts
      minted[#minted + 1] = { op = opi, comment_id = cid }

    elseif kind == "edit_comment" then
      local cid = as_str(op.comment_id, "comment_id", opi)
      local target, parent
      for _, t in ipairs(doc.threads) do
        for _, c in ipairs(t.comments or {}) do
          if c.id == cid then target, parent = c, t end
        end
      end
      if not target then fail(1, "op %d: comment %s not found", opi, cid) end
      if target.author ~= M.AUTHOR then
        fail(2, "op %d: refusing to edit comment %s — its author is %s, not %s. "
          .. "Others' comments are untouchable.", opi, cid, tostring(target.author), M.AUTHOR)
      end
      target.body = as_str(op.body, "body", opi)
      target.edited_at = ts
      parent.updated_at = ts

    elseif kind == "set_status" then
      if op.status ~= "applied" then
        fail(2, 'op %d: set_status only accepts "applied" — resolving (or reopening) is the human\'s call', opi)
      end
      local thread = find_thread(doc, as_str(op.thread_id, "thread_id", opi), opi)
      thread.status = "applied"
      thread.updated_at = ts

    elseif kind == "set_summary" then
      doc.review.summary = as_str(op.summary, "summary", opi)

    else
      fail(1, "op %d: unknown op %s", opi, vim.inspect(kind))
    end
  end

  return minted
end

---The full locked write. Blocks (on the event loop) until store.update
---finishes — fine here: this process has no UI.
---@param path string
---@param ops table[]
---@return { ok: boolean, minted: table[] }
function M.write(path, ops)
  if type(ops) ~= "table" or not vim.islist(ops) or #ops == 0 then
    fail(1, 'no ops: expected {"ops": [...]} or a bare [...] with at least one op')
  end
  -- Refuse a corrupt file up front: store.load would back it up and start
  -- over, and that call belongs to the human's editor, not the AI.
  M.read(path)

  local minted, op_err, done, write_err
  store.update(path, function(doc)
    local ok, res = pcall(M.apply_ops, doc, ops)
    if not ok then
      op_err = res
      error("ops rejected", 0) -- abort the write
    end
    minted = res
  end, function(_, err)
    done, write_err = true, err
  end)

  vim.wait(5000, function() return done end, 10)
  if op_err then error(op_err, 0) end
  if not done or (write_err and write_err:find("^Could not lock")) then
    fail(4, "could not lock the review file (another writer is stuck?)")
  end
  if write_err then fail(5, "%s", write_err) end
  return { ok = true, minted = minted }
end

--#endregion

--#region MCP server

-- Injected into every session via MCP `instructions` (Claude Code truncates
-- at 2KB — keep this well under). Workflow etiquette lives here; mechanical
-- invariants live in the tool descriptions.
local INSTRUCTIONS = table.concat({
  "diff.nvim review loop: the human writes review comments anchored to diff lines in Neovim; "
    .. "you read and answer them with the review_* tools. Both sides share one file per repo "
    .. "(under .git) — the tools handle locking and location; never edit that file directly.",
  "",
  "Etiquette: when asked about review comments, start from review_queue — every thread it "
    .. "returns is addressed to you. Reply in-thread with review_reply. If you were asked to "
    .. "change code and did it directly, say so in your reply and mark the thread with "
    .. "review_set_status (applied). Resolving threads is the human's call, never yours, and "
    .. "never re-litigate resolved threads.",
  "",
  "Reviewing a diff yourself: read the actual changes plus enough surrounding context to judge "
    .. "correctness, then one review_add_thread per distinct finding, anchored to the most "
    .. "relevant line with that line's EXACT current text as the snippet (anchors survive edits "
    .. "through it). Write your overall verdict with review_set_summary. Quality over quantity: "
    .. "real defects, risky edges, concrete simplifications — skip style nits unless asked.",
}, "\n")

local function tool(name, description, props, required)
  props.repo = {
    type = "string",
    description = "Any path inside the target git repo. Defaults to the server's working "
      .. "directory (the session's project).",
  }
  return {
    name = name,
    description = description,
    inputSchema = { type = "object", properties = props, required = required },
  }
end

local function str(description) return { type = "string", description = description } end
local function int(description) return { type = "integer", description = description } end

local TOOLS = {
  tool("review_queue",
    "Open review threads awaiting your reply (their last comment is not yours). Start here.",
    {}, {}),
  tool("review_list",
    "The full review document: every thread plus the review summary.",
    {}, {}),
  tool("review_add_thread",
    "Start a new review thread anchored to a source line. Ids are minted for you; the comment author is always 'claude'.",
    {
      file = str("Repo-relative path of the file"),
      line = int("1-indexed line the thread anchors to"),
      snippet = str("EXACT current text of the anchored line (required — anchors survive drift through it)"),
      body = str("The comment text"),
      end_line = int("Last line of the anchored range (defaults to line)"),
      side = { type = "string", enum = { "a", "b" }, description = "'b' = new/right side (default), 'a' = old/deleted lines" },
      rev = str("'WORKING' (default) = working tree; ':0' = index; else a full SHA"),
      ctx_before = str("Text of the line above (include when it exists)"),
      ctx_after = str("Text of the line below (include when it exists)"),
    },
    { "file", "line", "snippet", "body" }),
  tool("review_reply",
    "Append your reply to an existing thread. The author is always 'claude'.",
    { thread_id = { type = "string" }, body = { type = "string" } },
    { "thread_id", "body" }),
  tool("review_edit_comment",
    "Amend one of YOUR OWN comments. Refused for any comment whose author is not 'claude'.",
    { comment_id = { type = "string" }, body = str("Replacement body") },
    { "comment_id", "body" }),
  tool("review_set_status",
    "Mark a thread 'applied' after you actually changed the code. Only 'applied' is accepted — resolving is the human's call.",
    { thread_id = { type = "string" }, status = { type = "string", enum = { "applied" } } },
    { "thread_id", "status" }),
  tool("review_set_summary",
    "Set the overall verdict of the review pass (one paragraph).",
    { summary = { type = "string" } },
    { "summary" }),
}

---Run one tool call; returns the result table (raises ReviewAgentError).
---@param name string
---@param args table
---@return any
function M.call_tool(name, args)
  local path = M.review_file(args.repo)

  if name == "review_queue" then return M.queue(path) end
  if name == "review_list" then return M.read(path) end

  local op
  if name == "review_add_thread" then
    local anchor = { path = args.file, line = args.line, snippet = args.snippet }
    for _, key in ipairs({ "side", "rev", "end_line", "ctx_before", "ctx_after" }) do
      anchor[key] = args[key]
    end
    op = { op = "add_thread", anchor = anchor, body = args.body }
  elseif name == "review_reply" then
    op = { op = "add_comment", thread_id = args.thread_id, body = args.body }
  elseif name == "review_edit_comment" then
    op = { op = "edit_comment", comment_id = args.comment_id, body = args.body }
  elseif name == "review_set_status" then
    op = { op = "set_status", thread_id = args.thread_id, status = args.status }
  elseif name == "review_set_summary" then
    op = { op = "set_summary", summary = args.summary }
  else
    fail(1, "unknown tool: %s", tostring(name))
  end
  return M.write(path, { op })
end

local function send(payload)
  io.stdout:write(vim.json.encode(payload), "\n")
  io.stdout:flush()
end

---Handle one decoded JSON-RPC message.
---@param msg table
function M.handle(msg)
  local method, id = msg.method, msg.id
  local function reply(result) send({ jsonrpc = "2.0", id = id, result = result }) end

  if method == "initialize" then
    reply({
      protocolVersion = PROTOCOL_VERSION,
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = SERVER_NAME, version = "0.2.0" },
      instructions = INSTRUCTIONS,
    })
  elseif id == nil then
    return -- notifications (notifications/initialized, ...) need no answer
  elseif method == "ping" then
    reply(vim.empty_dict())
  elseif method == "tools/list" then
    reply({ tools = TOOLS })
  elseif method == "tools/call" then
    local params = msg.params or {}
    local ok, res = pcall(M.call_tool, params.name, params.arguments or {})
    if ok then
      reply({ content = { { type = "text", text = store.encode(res) } } })
    else
      local e = as_agent_error(res)
      reply({ content = { { type = "text", text = ("error(%d): %s"):format(e.code, e.msg) } }, isError = true })
    end
  else
    send({ jsonrpc = "2.0", id = id, error = { code = -32601, message = "method not found: " .. tostring(method) } })
  end
end

---Newline-delimited JSON-RPC on stdin/stdout, one message at a time (so tool
---calls are serialized in-process by construction).
function M.serve()
  for line in io.stdin:lines() do
    if vim.trim(line) ~= "" then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(msg) == "table" then
        M.handle(msg)
      else
        io.stderr:write("review: ignoring non-JSON line\n")
      end
    end
  end
end

--#endregion

--#region CLI

M.USAGE = [[
CLI for diff.nvim's review loop — the fallback for agents without MCP (Claude
Code sessions use the MCP server: `review.lua mcp`). Same lock, same file.

Usage (nvim as the Lua runtime):
    nvim --clean -l review.lua mcp                     # MCP server on stdio
    nvim --clean -l review.lua OPSFILE                 # ops JSON from a file
    nvim --clean -l review.lua - < ops.json            # ops JSON on stdin
    nvim --clean -l review.lua OPSFILE --review-file P # explicit review file
    nvim --clean -l review.lua --queue                 # open threads awaiting claude
    nvim --clean -l review.lua --list                  # the full review document

The review file is <git-dir>/diffview-review.json of the current directory's
repo; --review-file PATH overrides it.

The ops payload is {"ops": [op, ...]} or a bare [op, ...]; each op is one of:
    {"op": "add_thread", "anchor": {"path", "line", "snippet", ...}, "body": "..."}
    {"op": "add_comment", "thread_id": "t-..", "body": "..."}
    {"op": "edit_comment", "comment_id": "c-..", "body": "..."}
    {"op": "set_status", "thread_id": "t-..", "status": "applied"}
    {"op": "set_summary", "summary": "..."}

Exit codes: 0 ok; 1 usage/ops error; 2 invariant violation; 3 unreadable
review file (left untouched); 4 lock timeout; 5 write failure.
On success stdout is JSON: {"ok": true, "minted": [...]}.]]

local function die(code, msg)
  io.stderr:write("review: ", msg, "\n")
  os.exit(code)
end

local function run_cli(argv)
  local ops_file, review_path, mode = nil, nil, "write"
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--review-file" then
      i = i + 1
      review_path = argv[i] or die(1, "--review-file needs a path")
    elseif a:match("^%-%-review%-file=") then
      review_path = a:sub(#"--review-file=" + 1)
    elseif a == "--list" or a == "--queue" then
      if mode ~= "write" then die(1, "--list and --queue are mutually exclusive") end
      mode = a:sub(3)
    elseif a == "-h" or a == "--help" then
      io.stdout:write(M.USAGE, "\n")
      return
    elseif ops_file == nil then
      ops_file = a
    else
      die(1, "unexpected argument: " .. a)
    end
    i = i + 1
  end
  if mode ~= "write" and ops_file then die(1, ("--%s is read-only — don't pass an ops file with it"):format(mode)) end

  local ok, err = pcall(function()
    local path = review_path or M.review_file()
    if mode == "queue" then return io.stdout:write(store.encode(M.queue(path)), "\n") end
    if mode == "list" then return io.stdout:write(store.encode(M.read(path)), "\n") end

    local raw
    if ops_file == nil or ops_file == "-" then
      raw = io.stdin:read("*a")
    else
      local f = io.open(ops_file, "r") or fail(1, "cannot read ops file %s", ops_file)
      raw = f:read("*a")
      f:close()
    end
    local dok, payload = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if not dok then fail(1, "ops are not valid JSON: %s", tostring(payload)) end
    local ops = (type(payload) == "table" and not vim.islist(payload)) and payload.ops or payload
    io.stdout:write(vim.json.encode(M.write(path, ops)), "\n")
  end)
  if not ok then
    local e = as_agent_error(err)
    die(e.code, e.msg)
  end
end

---Entry point for skills/review/scripts/review.lua.
---@param argv string[]
function M.main(argv)
  -- stdout is the protocol channel: keep every message off it.
  vim.notify = function(msg) io.stderr:write(tostring(msg), "\n") end
  print = function(...)
    io.stderr:write(table.concat(vim.tbl_map(tostring, { ... }), "\t"), "\n")
  end

  if argv[1] == "mcp" then return M.serve() end
  run_cli(argv)
end

--#endregion

return M
