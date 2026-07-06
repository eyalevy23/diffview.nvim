-- Comments-on-diff: GitHub-style threads anchored to lines of the unified
-- diff, stored in one JSON file per repo (see store.lua) that both Neovim and
-- an AI read/write. This module wires everything together: buffer context,
-- thread placement, inline rendering, input floats, actions, and the
-- fs-watcher that reflects AI writes live.

local lazy = require("diffview.lazy")

local anchor_mod = require("diffview.comments.anchor")
local render = require("diffview.comments.render")
local store = require("diffview.comments.store")

local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local unified = lazy.require("diffview.scene.layouts.unified_render") ---@module "diffview.scene.layouts.unified_render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

---@class CommentBufCtx
---@field adapter VCSAdapter
---@field store_path string
---@field path string Repo-relative file path of the entry.
---@field rev_a string
---@field rev_b string
---@field buf_a? integer
---@field buf_b? integer

---Context per unified diff buffer.
---@type table<integer, CommentBufCtx>
M.buf_ctx = {}

---Cached documents per store path.
---@type table<string, ReviewDoc>
M.docs = {}

---fs watchers per store path.
M.watchers = {}

---Observation state per thread id from the latest placement pass:
---"outdated" | "ok". Absent means the thread was never placed (its file/rev
---isn't open) — its outdated_since must be left untouched on write.
---@type table<string, "outdated"|"ok">
M.observed = {}

--#region doc + context plumbing

---@param path string store path
---@return ReviewDoc
function M.get_doc(path)
  if not M.docs[path] then
    local doc, warn = store.load(path)
    M.docs[path] = doc
    if warn then utils.warn("[diffview] " .. warn) end
  end
  return M.docs[path]
end

---All open threads for a repo-relative file path (panel badge). Loads the
---review file on demand so the badge is right on the panel's FIRST paint,
---before any diff buffer has attached.
---@param adapter VCSAdapter
---@param file_path string
---@return integer open_count
function M.count_for(adapter, file_path)
  local doc = M.get_doc(store.path_for(adapter))
  local n = 0
  for _, t in ipairs(doc.threads) do
    if t.anchor.path == file_path and t.status == "open" then n = n + 1 end
  end
  return n
end

---Write through the store, stamping any threads we observed as outdated, then
---refresh every affected buffer.
---@param store_path string
---@param apply fun(doc: ReviewDoc)
---@return ReviewDoc?
function M.update(store_path, apply)
  local doc, err = store.update(store_path, function(doc)
    for _, t in ipairs(doc.threads) do
      local seen = M.observed[t.id]
      if seen == "outdated" and not t.outdated_since then
        t.outdated_since = store.now()
      elseif seen == "ok" then
        t.outdated_since = nil
      end
    end
    apply(doc)
  end)

  if not doc then
    utils.err("[diffview] " .. (err or "review write failed"))
    return
  end

  M.docs[store_path] = doc
  M.refresh_all(store_path)
  return doc
end

---@param bufnr integer
---@return CommentBufCtx?
local function ctx_for(bufnr)
  local ctx = M.buf_ctx[bufnr]
  if ctx and api.nvim_buf_is_valid(bufnr) then return ctx end
end

---Place every visible thread for a buffer: match path + rev, resolve drift.
---@param bufnr integer
---@return PlacedThread[]
local function place_threads(bufnr)
  local ctx = ctx_for(bufnr)
  if not ctx then return {} end

  local doc = M.get_doc(ctx.store_path)
  local placed = {} ---@type PlacedThread[]

  local src_lines = {}
  local function lines_for(side)
    if src_lines[side] then return src_lines[side] end
    local buf = side == "a" and ctx.buf_a or ctx.buf_b
    src_lines[side] = (buf and api.nvim_buf_is_valid(buf))
        and api.nvim_buf_get_lines(buf, 0, -1, false) or {}
    return src_lines[side]
  end

  for _, thread in ipairs(doc.threads) do
    local a = thread.anchor
    if a.path == ctx.path then
      local side_rev = a.side == "a" and ctx.rev_a or ctx.rev_b
      if a.rev == side_rev then
        local res = anchor_mod.resolve(a, lines_for(a.side))
        local row = unified.row_for(bufnr, a.side, res.line)

        M.observed[thread.id] = res.outdated and "outdated" or "ok"

        if row then
          placed[#placed + 1] = { thread = thread, row = row, outdated = res.outdated }
        end
      end
    end
  end

  return placed
end

---Re-render the threads of one unified buffer.
---@param bufnr integer
function M.refresh_buf(bufnr)
  if not (api.nvim_buf_is_valid(bufnr) and M.buf_ctx[bufnr]) then return end
  render.render(bufnr, place_threads(bufnr))
end

---Re-read every known review file from disk and repaint. Exposed for the
---AI-side "nudge" (`nvim --remote-expr`); the fs-watcher covers the normal
---path.
function M.reload()
  for path in pairs(M.docs) do
    local doc, warn = store.load(path)
    M.docs[path] = doc
    if warn then utils.warn("[diffview] " .. warn) end
  end
  M.refresh_all()
end

---Refresh all buffers backed by a store path (and the file panel badge).
---@param store_path? string
function M.refresh_all(store_path)
  for bufnr, ctx in pairs(M.buf_ctx) do
    if not api.nvim_buf_is_valid(bufnr) then
      M.buf_ctx[bufnr] = nil
    elseif not store_path or ctx.store_path == store_path then
      M.refresh_buf(bufnr)
    end
  end

  local view = lib.get_current_view()
  if view and view.panel and view.panel.render then
    pcall(function()
      view.panel:render()
      view.panel:redraw()
    end)
  end
end

---Start watching the review file for external (AI) writes.
---@param ctx CommentBufCtx
local function ensure_watcher(ctx)
  local path = ctx.store_path
  if M.watchers[path] then return end

  local handle = uv.new_fs_event()
  if not handle then return end

  local dir = vim.fs.dirname(path)
  local fname = vim.fs.basename(path)
  local pending = false

  -- Watch the directory: atomic renames replace the file inode, which breaks
  -- direct file watches. The git dir is busy (index!), so filter by name.
  local ok = handle:start(dir, {}, function(err, filename)
    if err or (filename and filename ~= fname) then return end
    if pending then return end
    pending = true

    vim.defer_fn(function()
      pending = false
      if store.is_own_write(path) then return end

      local doc, warn = store.load(path)
      M.docs[path] = doc
      if warn then utils.warn("[diffview] " .. warn) end

      M.refresh_all(path)

      if lib.get_current_view() then
        local open = 0
        for _, t in ipairs(doc.threads) do
          if t.status == "open" then open = open + 1 end
        end
        api.nvim_echo({ { ("[diffview] review updated externally (%d open thread(s))"):format(open) } }, false, {})
      end
    end, 200)
  end)

  if ok then
    M.watchers[path] = handle
  else
    handle:close()
  end
end

---Tear down state for stores that no longer back any live buffer: close the
---fs-watcher and drop the cached doc + observation state. Called on
---view_closed, after the view has destroyed its diff buffers.
function M.detach_orphans()
  local live = {}
  for bufnr, ctx in pairs(M.buf_ctx) do
    if api.nvim_buf_is_valid(bufnr) then
      live[ctx.store_path] = true
    else
      M.buf_ctx[bufnr] = nil
    end
  end

  for path, handle in pairs(M.watchers) do
    if not live[path] then
      handle:stop()
      if not handle:is_closing() then handle:close() end
      M.watchers[path] = nil

      local doc = M.docs[path]
      if doc then
        for _, t in ipairs(doc.threads) do
          M.observed[t.id] = nil
        end
        M.docs[path] = nil
      end
    end
  end
end

---Register a unified diff buffer: capture its context and render its threads.
---Called on diff_buf_win_enter.
---@param bufnr integer
function M.attach(bufnr)
  local view = lib.get_current_view()
  if not view then return end

  local entry = view.cur_entry
  local layout = view.cur_layout
  if not (entry and layout and layout.name == "diff1_unified") then return end

  local a_file = layout.a and layout.a.file
  local b_file = layout.b and layout.b.file
  local adapter = view.adapter

  M.buf_ctx[bufnr] = {
    adapter = adapter,
    store_path = store.path_for(adapter),
    path = entry.path,
    rev_a = a_file and a_file.rev and anchor_mod.rev_key(a_file.rev) or "",
    rev_b = b_file and b_file.rev and anchor_mod.rev_key(b_file.rev) or "",
    buf_a = a_file and a_file.bufnr,
    buf_b = b_file and b_file.bufnr,
  }

  ensure_watcher(M.buf_ctx[bufnr])
  M.get_doc(M.buf_ctx[bufnr].store_path)
  M.refresh_buf(bufnr)
  M._drift_watch(M.buf_ctx[bufnr])
end

---On write of the real (LOCAL) file: re-resolve WORKING anchors for that path
---and persist the drifted line numbers + snippets.
---@param ctx CommentBufCtx
function M._drift_watch(ctx)
  local buf = ctx.buf_b
  if not (buf and api.nvim_buf_is_valid(buf)) then return end
  if vim.b[buf].diffview_comments_drift then return end
  vim.b[buf].diffview_comments_drift = true

  api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    callback = function()
      if not api.nvim_buf_is_valid(buf) then return true end

      local doc = M.docs[ctx.store_path]
      if not doc then return end

      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      local dirty = false

      for _, t in ipairs(doc.threads) do
        local a = t.anchor
        if a.path == ctx.path and a.side == "b" and a.rev == "WORKING" then
          local res = anchor_mod.resolve(a, lines)
          if not res.outdated and res.line ~= a.line then dirty = true end
        end
      end

      if dirty then
        M.update(ctx.store_path, function(fresh)
          for _, t in ipairs(fresh.threads) do
            local a = t.anchor
            if a.path == ctx.path and a.side == "b" and a.rev == "WORKING" then
              local res = anchor_mod.resolve(a, lines)
              if not res.outdated then
                anchor_mod.write_back(a, res.line, lines)
              end
            end
          end
        end)
      end
    end,
  })
end

--#endregion

--#region interactions

---@return string
local function author_name()
  local conf = require("diffview.config").get_config()
  return (conf.comments and conf.comments.author)
    or (vim.env.USER and vim.env.USER:lower())
    or "human"
end

---Open a floating markdown input. `<C-s>` submits, `q`/<Esc> cancels.
---@param opts { title: string, initial?: string, on_submit: fun(text: string) }
local function open_input(opts)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  if opts.initial and opts.initial ~= "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial, "\n", { plain = true }))
  end

  local width = math.min(80, math.max(50, math.floor(vim.o.columns * 0.6)))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 8,
    style = "minimal",
    border = "rounded",
    title = (" %s — <C-s> submit · q cancel "):format(opts.title),
    title_pos = "left",
  })
  vim.wo[win].wrap = true

  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end

  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if text ~= "" then opts.on_submit(text) end
  end

  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-s>", submit, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

  if opts.initial and opts.initial ~= "" then
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end
end

---Find the thread rendered at (or covering) a buffer row.
---@param bufnr integer
---@param row integer
---@return ReviewThread?
local function thread_at(bufnr, row)
  for _, p in ipairs(place_threads(bufnr)) do
    if p.row == row then return p.thread end
  end
end

---<CR>: reply to the thread on this line, or start a new one.
function M.comment_open()
  local bufnr = api.nvim_get_current_buf()
  local ctx = ctx_for(bufnr)
  if not ctx then return end

  local row = api.nvim_win_get_cursor(0)[1]
  local existing = thread_at(bufnr, row)

  if existing then
    open_input({
      title = ("Reply · %s"):format(existing.id),
      on_submit = function(text)
        local doc = M.update(ctx.store_path, function(doc)
          for _, t in ipairs(doc.threads) do
            if t.id == existing.id then
              t.comments[#t.comments + 1] = {
                id = store.gen_id("c"),
                author = author_name(),
                ts = store.now(),
                body = text,
              }
              t.updated_at = store.now()
              t.status = "open"
            end
          end
        end)
        if not doc then
          vim.fn.setreg('"', text)
          utils.warn('[diffview] Write failed — comment text saved to the unnamed register.')
        end
      end,
    })
    return
  end

  local info = unified.get_line_info(bufnr, row)
  if not info then return end

  local side = info.kind == "del" and "a" or "b"
  local src_lnum = side == "a" and info.old_lnum or info.new_lnum
  local src_buf = side == "a" and ctx.buf_a or ctx.buf_b
  if not (src_lnum and src_buf and api.nvim_buf_is_valid(src_buf)) then return end

  local src_lines = api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local rev = side == "a" and ctx.rev_a or ctx.rev_b

  open_input({
    title = ("New comment · %s:%d"):format(ctx.path, src_lnum),
    on_submit = function(text)
      local doc = M.update(ctx.store_path, function(doc)
        doc.threads[#doc.threads + 1] = {
          id = store.gen_id("t"),
          anchor = anchor_mod.make(ctx.path, side, rev, src_lnum, src_lnum, src_lines),
          status = "open",
          created_at = store.now(),
          updated_at = store.now(),
          comments = {
            { id = store.gen_id("c"), author = author_name(), ts = store.now(), body = text },
          },
        }
      end)
      if not doc then
        vim.fn.setreg('"', text)
        utils.warn('[diffview] Write failed — comment text saved to the unnamed register.')
      end
    end,
  })
end

---Edit your own latest comment on the thread at the cursor line.
function M.comment_edit()
  local bufnr = api.nvim_get_current_buf()
  local ctx = ctx_for(bufnr)
  if not ctx then return end

  local row = api.nvim_win_get_cursor(0)[1]
  local existing = thread_at(bufnr, row)
  if not existing then return end

  local me = author_name()
  local target
  for i = #existing.comments, 1, -1 do
    if existing.comments[i].author == me then
      target = existing.comments[i]
      break
    end
  end
  if not target then
    utils.warn("[diffview] No comment of yours to edit here.")
    return
  end

  open_input({
    title = ("Edit · %s"):format(target.id),
    initial = target.body,
    on_submit = function(text)
      local doc = M.update(ctx.store_path, function(doc)
        for _, t in ipairs(doc.threads) do
          if t.id == existing.id then
            for _, c in ipairs(t.comments) do
              if c.id == target.id and c.author == me then
                c.body = text
                t.updated_at = store.now()
              end
            end
          end
        end
      end)
      if not doc then
        vim.fn.setreg('"', text)
        utils.warn('[diffview] Write failed — comment text saved to the unnamed register.')
      end
    end,
  })
end

---Toggle resolved on the thread at the cursor line.
function M.comment_resolve()
  local bufnr = api.nvim_get_current_buf()
  local ctx = ctx_for(bufnr)
  if not ctx then return end

  local row = api.nvim_win_get_cursor(0)[1]
  local existing = thread_at(bufnr, row)
  if not existing then return end

  M.update(ctx.store_path, function(doc)
    for _, t in ipairs(doc.threads) do
      if t.id == existing.id then
        t.status = t.status == "open" and "resolved" or "open"
        t.resolved_reason = t.status == "resolved" and "manual" or nil
        t.updated_at = store.now()
      end
    end
  end)
end

---Apply the latest suggestion of the thread at the cursor to the real file.
function M.comment_apply()
  local bufnr = api.nvim_get_current_buf()
  local ctx = ctx_for(bufnr)
  if not ctx then return end

  local row = api.nvim_win_get_cursor(0)[1]
  local thread = thread_at(bufnr, row)
  if not thread then return end

  local suggestion
  for i = #thread.comments, 1, -1 do
    if thread.comments[i].suggestion then
      suggestion = thread.comments[i].suggestion
      break
    end
  end
  if not (suggestion and suggestion.replace_lines) then
    utils.warn("[diffview] No suggestion on this thread.")
    return
  end

  if thread.anchor.side ~= "b" or thread.anchor.rev ~= "WORKING" then
    utils.warn("[diffview] Can only apply suggestions anchored to the working tree.")
    return
  end

  local buf = ctx.buf_b
  if not (buf and api.nvim_buf_is_valid(buf)) then return end

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local res = anchor_mod.resolve(thread.anchor, lines)
  if res.outdated then
    utils.warn("[diffview] Thread is outdated — can't locate the target lines.")
    return
  end

  -- The suggestion range was recorded against the file at comment time;
  -- shift it by however far the anchor has drifted since.
  local offset = res.line - thread.anchor.line
  local first = suggestion.replace_lines[1] + offset
  local last = suggestion.replace_lines[2] + offset

  if first < 1 or last > #lines or first > last then
    utils.warn("[diffview] Suggestion range no longer valid.")
    return
  end

  local new_lines = vim.split(suggestion.text, "\n", { plain = true })
  api.nvim_buf_set_lines(buf, first - 1, last, false, new_lines)
  api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd write")
  end)

  M.update(ctx.store_path, function(doc)
    for _, t in ipairs(doc.threads) do
      if t.id == thread.id then
        t.status = "applied"
        t.updated_at = store.now()
      end
    end
  end)

  api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
end

---Delete every comment thread in the repo's review store, after confirming.
function M.comment_clear_all()
  local view = lib.get_current_view()
  local adapter = view and view.adapter
  if not adapter then
    utils.err("[diffview] Open a diffview first.")
    return
  end

  local path = store.path_for(adapter)
  local n = #M.get_doc(path).threads
  if n == 0 then
    utils.info("[diffview] No comments to clear.")
    return
  end

  local choice = vim.fn.confirm(
    ("Delete ALL %d comment thread(s) in this repo? This cannot be undone."):format(n),
    "&Delete\n&Cancel", 2)
  if choice ~= 1 then return end

  if M.update(path, function(doc) doc.threads = {} end) then
    utils.info(("[diffview] Cleared %d comment thread(s)."):format(n))
  end
end

---@param dir integer 1|-1
function M.comment_nav(dir)
  local bufnr = api.nvim_get_current_buf()
  if not ctx_for(bufnr) then return end

  local rows = render.thread_rows(bufnr)
  if #rows == 0 then return end

  local cur = api.nvim_win_get_cursor(0)[1]
  local target

  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > cur then target = r break end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then target = rows[i] break end
    end
    target = target or rows[#rows]
  end

  utils.set_cursor(0, target, 0)
end

--#endregion

--#region commands + global wiring

local function cmd_review(cmd_opts)
  local sub = cmd_opts.fargs[1] or "list"
  local view = lib.get_current_view()
  local adapter = view and view.adapter
  if not adapter then
    utils.err("[diffview] :DiffviewReview needs an open diffview.")
    return
  end
  local path = store.path_for(adapter)

  if sub == "clear" then
    M.update(path, function(doc) doc.threads = {} end)
    utils.info("[diffview] Review cleared.")
  elseif sub == "resolve-all" then
    M.update(path, function(doc)
      for _, t in ipairs(doc.threads) do
        if t.status == "open" then
          t.status = "resolved"
          t.resolved_reason = "bulk"
          t.updated_at = store.now()
        end
      end
    end)
  elseif sub == "list" then
    local doc = M.get_doc(path)
    local out = { ("review: %s"):format(path) }
    for _, t in ipairs(doc.threads) do
      out[#out + 1] = ("  [%s] %s %s:%d (%d comment(s))"):format(
        t.status, t.id, t.anchor.path, t.anchor.line, #t.comments)
    end
    if doc.review.summary then
      out[#out + 1] = "  summary: " .. doc.review.summary
    end
    api.nvim_echo(vim.tbl_map(function(l) return { l .. "\n" } end, out), true, {})
  else
    utils.err("[diffview] Unknown subcommand: " .. sub)
  end
end

local initialized = false

---Idempotent global wiring; called when the unified layout loads.
function M.init()
  if initialized then return end
  initialized = true

  DiffviewGlobal.emitter:on("diff_buf_win_enter", function(_, bufnr, _, ctx)
    if ctx and ctx.layout_name == "diff1_unified" then
      M.attach(bufnr)
    end
  end)

  DiffviewGlobal.emitter:on("view_closed", function(_)
    M.detach_orphans()
  end)

  -- Unified re-renders replace the buffer content, which moves/clears our
  -- extmarks — repaint from the resolved anchors.
  api.nvim_create_autocmd("User", {
    pattern = "DiffviewUnifiedRendered",
    callback = function(state)
      local bufnr = state.data and state.data.buf
      if bufnr then
        vim.schedule(function() M.refresh_buf(bufnr) end)
      end
    end,
  })

  api.nvim_create_user_command("DiffviewReview", cmd_review, {
    nargs = "?",
    complete = function() return { "list", "clear", "resolve-all" } end,
  })
end

--#endregion

return M
