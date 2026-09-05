-- Peek: a float over a real file buffer that shows the change around the
-- cursor line as a mini unified diff, plus the story behind it. Three
-- "befores" (bases):
--
--   index   what the uncommitted edit replaced
--   branch  what this branch changed — vs the merge-base with the trunk, or
--           vs the base of an open diff view for this repo (so jumping to
--           the real file with T and peeking shows the same change)
--   blame   the commit that last touched the line and what it replaced;
--           walk older / newer one commit at a time
--
-- Rendering goes through the unified renderer (build, apply_hl, statuscol,
-- Treesitter provider) on a sliced state, so a hunk reads exactly as in the
-- view. No gitsigns dependency: every base is `git show` per side plus an
-- in-process vim.diff. Blame is one `git blame -L` per step, on demand.

local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local navigate = lazy.require("diffview.navigate") ---@module "diffview.navigate"
local unified = lazy.require("diffview.scene.layouts.unified_render") ---@module "diffview.scene.layouts.unified_render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"

local api = vim.api
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

local ns = api.nvim_create_namespace("diffview_peek")

---Named bases, in `b`-cycle order.
M.MODES = { "index", "branch", "blame" }

---@class PeekCtx
---@field adapter GitAdapter
---@field toplevel string
---@field git string[]
---@field abs string
---@field path string Repo-relative path.
---@field lnum integer Cursor line in the source buffer.
---@field lang string?
---@field src_buf integer
---@field src_win integer

---@class PeekCommit
---@field sha string
---@field orig_lnum integer Line number in the file at `sha`.
---@field final_lnum integer
---@field author string?
---@field time integer?
---@field summary string?
---@field filename string Path at `sha`.
---@field previous_sha string?
---@field previous_file string? Path at the parent (renames followed).
---@field zero boolean Not committed yet.

---@class PeekStep
---@field mode "index"|"branch"|"blame"|"rev"
---@field label string
---@field base string? Rev arg reopening this base in a diff view.
---@field old_lines string[]
---@field new_lines string[]
---@field new_buf integer? Real buffer for the new side (index / branch).
---@field old_blame { rev: string?, path: string, contents: string? }? How to blame deleted lines.
---@field target { side: "a"|"b", lnum: integer }
---@field commit PeekCommit?
---@field body string[]? Full commit message, fetched on demand.
---@field built { lines: string[], st: UnifiedState, hunks: table, idx: integer }?

---@class PeekState
---@field win integer?
---@field buf integer
---@field ctx PeekCtx
---@field step PeekStep
---@field history PeekStep[] Blame walk; [1] is the newest.
---@field pos integer
---@field scratch integer[]
---@field aug integer?
---@field show_body boolean
---@field moving boolean
---@field seq integer
local state ---@type PeekState?

-- Bumped on every open / re-render; async results for an older request are
-- dropped.
local seq = 0

--#region git plumbing

---@param ctx PeekCtx
---@param args string[]
---@param opts? { stdin?: string }
---@param cb fun(code: integer, stdout: string, stderr: string)
local function git(ctx, args, opts, cb)
  local cmd = utils.vec_join(ctx.git, args)
  vim.system(cmd, {
    cwd = ctx.toplevel,
    text = true,
    stdin = opts and opts.stdin or nil,
  }, function(out)
    vim.schedule(function() cb(out.code, out.stdout or "", out.stderr or "") end)
  end)
end

---@param text string
---@return string[]
local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

---@param lines string[]
---@return string
local function join_lines(lines)
  return table.concat(lines, "\n") .. "\n"
end

---Content of `spec` (`rev:path`, `:0:path`) as lines; nil when it doesn't exist.
---@param ctx PeekCtx
---@param spec string
---@param cb fun(lines?: string[])
local function show_file(ctx, spec, cb)
  git(ctx, { "show", spec }, nil, function(code, out)
    cb(code == 0 and split_lines(out) or nil)
  end)
end

---Parse `git blame --line-porcelain` output.
---@param out string
---@return PeekCommit[]
local function parse_blame(out)
  local entries, cur = {}, nil

  for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
    local sha, orig, final = line:match("^(%x+) (%d+) (%d+)")

    if sha and (#sha == 40 or #sha == 64) then
      cur = {
        sha = sha,
        orig_lnum = tonumber(orig),
        final_lnum = tonumber(final),
        zero = sha:match("^0+$") ~= nil,
      }
    elseif cur then
      if line:sub(1, 1) == "\t" then
        entries[#entries + 1] = cur
        cur = nil
      else
        local key, value = line:match("^([%w%-]+) ?(.*)$")
        if key == "author" then
          cur.author = value
        elseif key == "author-time" then
          cur.time = tonumber(value)
        elseif key == "summary" then
          cur.summary = value
        elseif key == "filename" then
          cur.filename = value
        elseif key == "previous" then
          cur.previous_sha, cur.previous_file = value:match("^(%x+) (.*)$")
        end
      end
    end
  end

  return entries
end

---Blame one line. With `contents`, the working tree is pretended to hold
---that text (unsaved edits count; uncommitted lines come back as `zero`).
---@param ctx PeekCtx
---@param lnum integer
---@param rev string?
---@param path string
---@param contents string?
---@param cb fun(entry?: PeekCommit, err?: string)
local function blame_line(ctx, lnum, rev, path, contents, cb)
  local args = { "blame", "--line-porcelain", "-L", lnum .. "," .. lnum }
  if contents then vim.list_extend(args, { "--contents", "-" }) end
  if rev then args[#args + 1] = rev end
  vim.list_extend(args, { "--", path })

  git(ctx, args, { stdin = contents }, function(code, out, err)
    if code ~= 0 then return cb(nil, vim.trim(err)) end
    local entry = parse_blame(out)[1]
    if not entry then return cb(nil, "no blame output") end
    cb(entry)
  end)
end

---Git-style relative age ("3 days ago"), same buckets and wording as
---gitsigns' `%R`, so the float and an end-of-line blame read alike.
---@param ts integer
---@return string
local function reltime(ts)
  local elapsed = math.max(os.time() - ts, 0)
  local units = {
    { 60, "second" }, { 3600, "minute" }, { 86400, "hour" },
    { 86400 * 30, "day" }, { 86400 * 365, "month" }, { math.huge, "year" },
  }
  local size = 1
  for _, u in ipairs(units) do
    if elapsed < u[1] then
      local n = math.max(1, math.floor(elapsed / size))
      return ("%d %s%s ago"):format(n, u[2], n == 1 and "" or "s")
    end
    size = u[1]
  end
  return "a while ago"
end

---@param sha string
---@return string
local function short(sha)
  return sha:sub(1, 7)
end

--#endregion

--#region context

---@param bufnr integer
---@param winid integer
---@return PeekCtx?
---@return string? err
local function resolve_ctx(bufnr, winid)
  if vim.bo[bufnr].buftype ~= "" then
    if unified.state[bufnr] then
      return nil, "Peek works in the real file: press T to open it first."
    end
    return nil, "Peek works in real file buffers."
  end

  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil, "Unnamed buffer." end
  local abs = pl:absolute(name)

  local err, adapter = vcs.get_adapter({ top_indicators = { abs } })
  if err then return nil, err end
  ---@cast adapter GitAdapter

  local ft = vim.bo[bufnr].filetype
  local lang = ft ~= "" and vim.treesitter.language.get_lang(ft) or nil

  return {
    adapter = adapter,
    toplevel = adapter.ctx.toplevel,
    git = adapter:get_command(),
    abs = abs,
    path = pl:relative(abs, adapter.ctx.toplevel),
    lnum = api.nvim_win_get_cursor(winid)[1],
    lang = lang,
    src_buf = bufnr,
    src_win = winid,
  }
end

---@param ctx PeekCtx
---@return string[]
local function buf_lines(ctx)
  return api.nvim_buf_get_lines(ctx.src_buf, 0, -1, false)
end

---The request is still what the user is looking at.
---@param ctx PeekCtx
---@param my_seq integer
---@return boolean
local function still_current(ctx, my_seq)
  if my_seq ~= seq then return false end
  if not api.nvim_buf_is_valid(ctx.src_buf) or not api.nvim_win_is_valid(ctx.src_win) then
    return false
  end
  if state and state.win and api.nvim_win_is_valid(state.win) then
    return true -- re-render of an open float
  end
  return api.nvim_get_current_buf() == ctx.src_buf
    and api.nvim_win_get_cursor(ctx.src_win)[1] == ctx.lnum
end

--#endregion

--#region bases

---@param ctx PeekCtx
---@param cb fun(step?: PeekStep, reason?: string)
local function load_index(ctx, cb)
  show_file(ctx, ":0:" .. ctx.path, function(old)
    if not old then return cb(nil, "index: file is not tracked") end
    cb({
      mode = "index",
      label = "vs index",
      base = nil,
      old_lines = old,
      new_lines = buf_lines(ctx),
      new_buf = ctx.src_buf,
      -- Blame the index content as if it were the working tree: line numbers
      -- match exactly, and staged-but-uncommitted lines read as such.
      old_blame = { path = ctx.path, contents = join_lines(old) },
      target = { side = "b", lnum = ctx.lnum },
    })
  end)
end

---The branch base: the left side of an open diff view for this repo when
---one shows the working tree, else the merge-base with the trunk.
---@param ctx PeekCtx
---@param cb fun(sha?: string, label?: string, rev_arg?: string)
local function branch_base(ctx, cb)
  for _, view in ipairs(lib.views) do
    if view:instanceof(DiffView.__get()) then
      ---@cast view DiffView
      if view.adapter.ctx.toplevel == ctx.toplevel
        and view.right.type == RevType.LOCAL
        and view.left.type == RevType.COMMIT
        and api.nvim_tabpage_is_valid(view.tabpage)
      then
        local label = view.rev_arg or view.left.commit
        if label:match("^%x+$") then label = short(label) end
        return cb(view.left.commit, label, view.rev_arg or view.left.commit)
      end
    end
  end

  local head = ctx.adapter:head_rev()
  local head_sha = head and head.commit
  local candidates = vim.list_slice(config.get_config().peek.trunk)

  local function merge_base(ref, on_done)
    git(ctx, { "merge-base", ref, "HEAD" }, nil, function(code, out)
      local sha = code == 0 and vim.trim(out) or ""
      on_done(sha ~= "" and sha or nil)
    end)
  end

  local function try(i)
    local ref = candidates[i]
    if not ref then
      git(ctx, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, nil, function(code, out)
        local remote = code == 0 and vim.trim(out) or nil
        if not remote then return cb(nil) end
        merge_base(remote, function(sha)
          if sha and sha == head_sha then return cb(nil) end
          cb(sha, remote, sha)
        end)
      end)
      return
    end
    merge_base(ref, function(sha)
      if sha and sha == head_sha then
        -- On the trunk itself: nothing branch-specific to show.
        return cb(nil)
      end
      if sha then return cb(sha, ref, sha) end
      try(i + 1)
    end)
  end
  try(1)
end

---@param ctx PeekCtx
---@param sha string
---@param label string
---@param rev_arg string
---@param cb fun(step?: PeekStep, reason?: string)
local function load_rev(ctx, sha, label, rev_arg, cb)
  show_file(ctx, sha .. ":" .. ctx.path, function(old)
    -- Missing at the base: the whole file is new relative to it.
    old = old or {}
    cb({
      mode = "rev",
      label = "vs " .. label,
      base = rev_arg,
      old_lines = old,
      new_lines = buf_lines(ctx),
      new_buf = ctx.src_buf,
      old_blame = { rev = sha, path = ctx.path },
      target = { side = "b", lnum = ctx.lnum },
    })
  end)
end

---@param ctx PeekCtx
---@param cb fun(step?: PeekStep, reason?: string)
local function load_branch(ctx, cb)
  branch_base(ctx, function(sha, label, rev_arg)
    if not sha then return cb(nil, "branch: no trunk to compare with") end
    load_rev(ctx, sha, label, rev_arg, function(step, reason)
      if step then step.mode = "branch" end
      cb(step, reason)
    end)
  end)
end

---A blame step for a resolved commit: the file at the commit vs at its
---parent, targeting the line the commit introduced.
---@param ctx PeekCtx
---@param e PeekCommit
---@param cb fun(step?: PeekStep, reason?: string)
local function blame_step(ctx, e, cb)
  local pending = 2
  local old, new

  local function done()
    pending = pending - 1
    if pending > 0 then return end
    if not new then return cb(nil, "blame: could not read " .. short(e.sha)) end
    cb({
      mode = "blame",
      label = short(e.sha),
      base = e.sha .. "^!",
      old_lines = old or {},
      new_lines = new,
      old_blame = e.previous_sha and { rev = e.previous_sha, path = e.previous_file } or nil,
      target = { side = "b", lnum = e.orig_lnum },
      commit = e,
    })
  end

  show_file(ctx, e.sha .. ":" .. e.filename, function(lines)
    new = lines
    done()
  end)

  if e.previous_sha then
    show_file(ctx, e.previous_sha .. ":" .. e.previous_file, function(lines)
      old = lines
      done()
    end)
  else
    old = {}
    done()
  end
end

---@param ctx PeekCtx
---@param cb fun(step?: PeekStep, reason?: string)
local function load_blame(ctx, cb)
  blame_line(ctx, ctx.lnum, nil, ctx.path, join_lines(buf_lines(ctx)), function(e, err)
    if not e then return cb(nil, "blame: " .. (err or "failed")) end
    if e.zero then return cb(nil, "blame: line is not committed yet") end
    blame_step(ctx, e, cb)
  end)
end

---@param ctx PeekCtx
---@param mode string
---@param cb fun(step?: PeekStep, reason?: string)
local function load(ctx, mode, cb)
  if mode == "index" then return load_index(ctx, cb) end
  if mode == "branch" then return load_branch(ctx, cb) end
  if mode == "blame" then return load_blame(ctx, cb) end

  -- Anything else is a rev.
  git(ctx, { "rev-parse", "--verify", "--quiet", mode .. "^{commit}" }, nil, function(code, out)
    if code ~= 0 then return cb(nil, ("'%s' is not a commit"):format(mode)) end
    load_rev(ctx, vim.trim(out), mode, mode, cb)
  end)
end

--#endregion

--#region diff + slice

---@param ranges { [1]: integer, [2]: integer }[]
---@param row integer
---@return integer? idx
local function range_index(ranges, row)
  for i, r in ipairs(ranges) do
    if row >= r[1] and row <= r[2] then return i end
  end
end

---@param ranges { [1]: integer, [2]: integer }[]
---@param row integer
---@return integer? idx
local function nearest_range(ranges, row)
  local best, best_d
  for i, r in ipairs(ranges) do
    local d = row < r[1] and (r[1] - row) or (row > r[2] and (row - r[2]) or 0)
    if not best_d or d < best_d then best, best_d = i, d end
  end
  return best
end

---Diff the step and locate the hunk cluster at its target. False when the
---target line is unchanged (strict) — that's how the auto chain falls
---through to the next base.
---@param step PeekStep
---@param lenient? boolean Fall back to the nearest cluster.
---@return boolean
local function probe(step, lenient)
  local lines, st, hunks = unified.build(step.old_lines, step.new_lines)
  if #st.visible_ranges == 0 then return false end

  local row = step.target.side == "a"
    and st.row_of_old[step.target.lnum]
    or st.row_of_new[step.target.lnum]
  local idx = row and range_index(st.visible_ranges, row) or nil

  if not idx and lenient then
    idx = nearest_range(st.visible_ranges, row or 1)
  end
  if not idx then return false end

  step.built = { lines = lines, st = st, hunks = hunks, idx = idx }
  return true
end

---The old-side line to follow when walking older: the line paired with the
---target in its hunk, else the hunk's first deleted line. Nil when the hunk
---is a pure addition (the line was born in this commit).
---@param step PeekStep
---@return integer?
local function older_line(step)
  local lnum = step.target.lnum
  local fallback
  for _, h in ipairs(step.built.hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if cb > 0 and lnum >= sb and lnum <= sb + cb - 1 then
      if ca == 0 then return nil end
      return sa + math.min(ca - 1, lnum - sb)
    end
    if ca > 0 and not fallback then fallback = sa end
  end
  return fallback
end

--#endregion

--#region float

---@param lines string[]
---@param lang string?
---@return integer
local function scratch(lines, lang)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- A parser (no filetype: that would attach LSP & co. to a throwaway buffer).
  if lang then pcall(vim.treesitter.get_parser, buf, lang) end
  state.scratch[#state.scratch + 1] = buf
  return buf
end

local function drop_scratch()
  for _, b in ipairs(state.scratch) do
    pcall(api.nvim_buf_delete, b, { force = true })
  end
  state.scratch = {}
end

---@param s string
---@param width integer
---@return string
local function fit(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  return vim.fn.strcharpart(s, 0, math.max(0, width - 1)) .. "…"
end

---@param step PeekStep
---@param idx integer
---@param n integer
---@return string
local function title_for(step, idx, n)
  local head
  if step.mode == "blame" then
    local c = step.commit
    head = ("%s · %s · %s"):format(
      short(c.sha), c.author or "?", c.time and reltime(c.time) or "?")
    if c.filename ~= state.ctx.path then
      head = head .. " · " .. c.filename
    end
  else
    head = step.label
  end
  return (" %s · hunk %d/%d "):format(head, idx, n)
end

---@param step PeekStep
---@return string
local function footer_for(step)
  if step.mode == "blame" then
    return " b base · < older · > newer · ]c [c hunk · o diffview · s sha · K msg · q "
  end
  return " b base · ]c [c hunk · o diffview · q "
end

---Commit subject (and body, when expanded) as virtual lines above row 1.
---@param step PeekStep
---@return integer rows
local function set_header(step)
  if step.mode ~= "blame" then return 0 end
  local c = step.commit
  local vl = { { { " " .. (c.summary or ""), "DiffviewPeekSubject" } } }
  if state.show_body and step.body then
    for _, l in ipairs(step.body) do
      vl[#vl + 1] = { { " " .. l, "DiffviewPeekBody" } }
    end
  end
  api.nvim_buf_set_extmark(state.buf, ns, 0, 0, { virt_lines = vl, virt_lines_above = true })
  return #vl
end

---Where the float goes: below the anchor line when it fits, else above,
---left edge on the text column. Editor-relative coordinates: `bufpos` +
---`anchor` don't place an above-the-line float where the docs say.
---@param height integer
---@return table cfg, integer height
local function placement(height)
  local ctx = state.ctx
  local lnum = math.min(ctx.lnum, api.nvim_buf_line_count(ctx.src_buf))
  local sp = vim.fn.screenpos(ctx.src_win, lnum, 1)
  local line_row, col -- 0-based screen row of the line, 0-based column

  if sp.row > 0 then
    line_row, col = sp.row - 1, sp.col - 1
  else
    -- Not on screen yet (no redraw since the cursor moved): derive from the
    -- window's own coordinates.
    local wpos = api.nvim_win_get_position(ctx.src_win)
    local wl, wc = 1, 1
    api.nvim_win_call(ctx.src_win, function() wl, wc = vim.fn.winline(), vim.fn.wincol() end)
    line_row, col = wpos[1] + wl - 1, wpos[2] + wc - 1
  end

  local below = vim.o.lines - vim.o.cmdheight - (line_row + 1) -- rows under the line
  local above = line_row                                       -- rows over it
  local cfg = { relative = "editor", col = col }

  if height + 2 <= below or below >= above then
    height = math.max(1, math.min(height, below - 2))
    cfg.row = line_row + 1
  else
    height = math.max(1, math.min(height, above - 2))
    cfg.row = line_row - (height + 2)
  end
  return cfg, height
end

---Right-aligned "who wrote this" labels on the deleted lines, async.
---@param step PeekStep
---@param sub UnifiedState
---@param my_seq integer
local function label_deleted(step, sub, my_seq)
  local ob = step.old_blame
  if not (ob and config.get_config().peek.blame_deleted) then return end

  local first, last
  for _, info in pairs(sub.line_map) do
    if info.kind == "del" then
      first = math.min(first or info.old_lnum, info.old_lnum)
      last = math.max(last or 0, info.old_lnum)
    end
  end
  if not first then return end

  local args = { "blame", "--line-porcelain", "-L", first .. "," .. last }
  if ob.contents then vim.list_extend(args, { "--contents", "-" }) end
  if ob.rev then args[#args + 1] = ob.rev end
  vim.list_extend(args, { "--", ob.path })

  git(state.ctx, args, { stdin = ob.contents }, function(code, out)
    if code ~= 0 or not state or state.seq ~= my_seq then return end
    if not api.nvim_buf_is_valid(state.buf) then return end

    local by_lnum = {}
    for _, e in ipairs(parse_blame(out)) do by_lnum[e.final_lnum] = e end

    local prev, widest = nil, 0
    for r = 1, api.nvim_buf_line_count(state.buf) do
      local info = sub.line_map[r]
      local e = info and info.kind == "del" and by_lnum[info.old_lnum] or nil
      if e and e.sha ~= prev then
        local text = e.zero and "uncommitted"
          or ("%s · %s"):format(e.author or "?", e.time and reltime(e.time) or "")
        widest = math.max(widest, vim.fn.strdisplaywidth(text))
        api.nvim_buf_set_extmark(state.buf, ns, r - 1, 0, {
          virt_text = { { text .. " ", "DiffviewPeekBlame" } },
          virt_text_pos = "right_align",
          hl_mode = "combine",
        })
      end
      prev = e and e.sha or nil
    end

    -- Widen so labels don't sit on top of code.
    if widest > 0 and state.win and api.nvim_win_is_valid(state.win) then
      local cfg = api.nvim_win_get_config(state.win)
      local needed = (state.content_width or 0) + widest + 3
      if needed > cfg.width then
        api.nvim_win_set_config(state.win, { width = math.min(needed, vim.o.columns - 4) })
      end
    end
  end)
end

---Set the float's buffer-local keymaps from the config.
local function apply_keymaps()
  for _, mapping in ipairs(config.get_config().keymaps.peek) do
    local opt = vim.tbl_extend("force", { silent = true, nowait = true }, mapping[4] or {}, { buffer = state.buf })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end
end

---The float lives only while it has focus (or the file cursor stays put):
---leaving it any other way than `q` closes it too. Decided via schedule():
---BufLeave fires mid-switch, when the current window still reads as the one
---being left.
local function check_focus()
  vim.schedule(function()
    if not state or state.moving then return end
    if state.win and api.nvim_win_is_valid(state.win) and api.nvim_get_current_win() ~= state.win then
      M.close()
    end
  end)
end

local function create_float()
  local ctx = state.ctx
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].undolevels = -1
  state.buf = buf
  apply_keymaps()

  state.aug = api.nvim_create_augroup("diffview_peek", { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = state.aug,
    buffer = ctx.src_buf,
    callback = check_focus,
  })
  api.nvim_create_autocmd("BufLeave", { group = state.aug, buffer = buf, callback = check_focus })
  api.nvim_create_autocmd("BufWipeout", {
    group = state.aug,
    buffer = buf,
    callback = function() unified.cleanup(buf) end,
  })
end

---Render `step` into the float (creating the window on first use).
---@param step PeekStep
local function render(step)
  local ctx = state.ctx
  local b = step.built
  local st = b.st

  seq = seq + 1
  state.seq = seq
  state.step = step

  drop_scratch()
  st.buf_b = step.new_buf or scratch(step.new_lines, ctx.lang)
  st.buf_a = scratch(step.old_lines, ctx.lang)
  st.tick_a = api.nvim_buf_get_changedtick(st.buf_a)
  st.tick_b = api.nvim_buf_get_changedtick(st.buf_b)

  local range = st.visible_ranges[b.idx]
  local sub = unified.slice(st, range[1], range[2])
  local lines = vim.list_slice(b.lines, range[1], range[2])

  local buf = state.buf
  unified.cleanup(buf)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  unified.state[buf] = sub
  unified.apply_hl(buf, sub, b.hunks, step.old_lines, step.new_lines)
  unified._ts_precompute(sub, sub.visible_ranges)
  local header_rows = set_header(step)

  -- Size to the content.
  local conf = config.get_config().peek
  local gutter = sub.w_old + sub.w_new + 4
  local content = 0
  for _, l in ipairs(lines) do
    content = math.max(content, vim.fn.strdisplaywidth(l))
  end
  if step.commit and step.commit.summary then
    content = math.max(content, vim.fn.strdisplaywidth(step.commit.summary) + 1)
  end
  state.content_width = content + gutter
  local title = title_for(step, b.idx, #st.visible_ranges)
  local footer = footer_for(step)
  local width = math.max(content + gutter + 1, vim.fn.strdisplaywidth(title) + 2, 40)
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines + header_rows, math.max(3, math.floor(vim.o.lines * conf.max_height)))

  local cfg, h = placement(height)
  cfg.width = width
  cfg.height = h
  cfg.col = math.max(0, math.min(cfg.col, vim.o.columns - width - 2))
  cfg.style = "minimal"
  cfg.border = "rounded"
  cfg.title = fit(title, width - 2)
  cfg.title_pos = "left"
  cfg.zindex = 60
  if vim.fn.has("nvim-0.10") == 1 then
    cfg.footer = { { fit(footer, width - 2), "DiffviewPeekHint" } }
    cfg.footer_pos = "right"
  end

  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_config(state.win, cfg)
  else
    state.win = api.nvim_open_win(buf, true, cfg)
    local win = state.win
    utils.set_local(win, {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldenable = false,
      wrap = false,
      cursorline = false,
      statuscolumn = "%!v:lua.require'diffview.scene.layouts.unified_render'.statuscol()",
      winhighlight = "FloatBorder:DiffviewPeekBorder,FloatTitle:DiffviewPeekTitle,FloatFooter:DiffviewPeekHint",
    })
    api.nvim_create_autocmd("WinClosed", {
      group = state.aug,
      pattern = tostring(win),
      once = true,
      callback = function()
        if state and state.win == win then
          state.win = nil
          M.close()
        end
      end,
    })
  end

  -- Scroll the float so the target row is visible.
  local target_row = step.target.side == "a"
    and sub.row_of_old[step.target.lnum]
    or sub.row_of_new[step.target.lnum]
  api.nvim_win_call(state.win, function()
    utils.set_cursor(state.win, target_row or 1, 0)
    if target_row and target_row > h then pcall(vim.cmd, "normal! zz") else pcall(vim.cmd, "normal! gg") end
  end)

  label_deleted(step, sub, state.seq)
end

---@param ctx PeekCtx
---@param step PeekStep
local function show(ctx, step)
  if not state then
    state = {
      ctx = ctx,
      step = step,
      history = {},
      pos = 0,
      scratch = {},
      show_body = false,
      moving = false,
      seq = seq,
    }
    create_float()
  end

  state.ctx = ctx
  if step.mode == "blame" then
    if state.history[state.pos] ~= step then
      state.history = { step }
      state.pos = 1
    end
  else
    state.history = {}
    state.pos = 0
  end

  render(step)
end

---Try `modes` in order; the first with a change at the cursor is shown.
---@param ctx PeekCtx
---@param modes string[]
---@param i integer
---@param my_seq integer
---@param reasons string[]
local function attempt(ctx, modes, i, my_seq, reasons)
  local mode = modes[i]
  if not mode then
    utils.info("[diffview] Nothing to peek here (" .. table.concat(reasons, "; ") .. ").")
    return
  end

  load(ctx, mode, function(step, reason)
    if not still_current(ctx, my_seq) then return end
    if step and probe(step, mode == "blame") then
      show(ctx, step)
    else
      reasons[#reasons + 1] = reason or (mode .. ": no change at the cursor")
      attempt(ctx, modes, i + 1, my_seq, reasons)
    end
  end)
end

--#endregion

--#region public API

---@return boolean
function M.is_open()
  return state ~= nil and state.win ~= nil and api.nvim_win_is_valid(state.win)
end

function M.close()
  if not state then return end
  local s = state
  state = nil

  if s.aug then pcall(api.nvim_del_augroup_by_id, s.aug) end
  local was_focused = s.win and api.nvim_get_current_win() == s.win
  if s.win and api.nvim_win_is_valid(s.win) then
    pcall(api.nvim_win_close, s.win, true)
  end
  if was_focused and s.ctx and api.nvim_win_is_valid(s.ctx.src_win) then
    pcall(api.nvim_set_current_win, s.ctx.src_win)
  end
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    unified.cleanup(s.buf)
    pcall(api.nvim_buf_delete, s.buf, { force = true })
  end
  for _, b in ipairs(s.scratch) do
    pcall(api.nvim_buf_delete, b, { force = true })
  end
end

---Open the peek for the cursor line. The float takes focus (one press to
---read, `q` to leave). Pressed again while it is open: close it when it is
---focused, focus it otherwise.
---@param opts? { base?: string } "index" | "branch" | "blame" | any rev.
---Default: an open diff view's base, else the index, else blame — the first
---one with a change at the cursor.
function M.open(opts)
  opts = opts or {}

  if M.is_open() then
    ---@cast state -?
    if not opts.base then
      if api.nvim_get_current_win() == state.win then
        M.close()
      else
        api.nvim_set_current_win(state.win)
      end
      return
    end
    if api.nvim_get_current_win() == state.win then
      -- Switch base in place, keeping the anchor line.
      seq = seq + 1
      attempt(state.ctx, { opts.base }, 1, seq, {})
      return
    end
    M.close()
  end

  local ctx, err = resolve_ctx(api.nvim_get_current_buf(), api.nvim_get_current_win())
  if not ctx then
    utils.warn("[diffview] " .. err)
    return
  end

  seq = seq + 1
  local modes = opts.base and { opts.base } or { "branch", "index", "blame" }
  attempt(ctx, modes, 1, seq, {})
end

---Cycle to the next base that has a change at the anchor line.
function M.cycle_base()
  if not M.is_open() then return end
  ---@cast state -?
  local cur = state.step.mode
  local start = 0
  for i, m in ipairs(M.MODES) do
    if m == cur then start = i end
  end

  local order = {}
  for k = 1, #M.MODES - 1 do
    order[#order + 1] = M.MODES[(start + k - 1) % #M.MODES + 1]
  end

  seq = seq + 1
  attempt(state.ctx, order, 1, seq, {})
end

---Blame mode: one commit older for the same line.
function M.older()
  if not M.is_open() then return end
  ---@cast state -?
  local step = state.step
  if step.mode ~= "blame" then
    utils.info("[diffview] Walking history needs the blame base (press b).")
    return
  end

  if state.pos < #state.history then
    state.pos = state.pos + 1
    render(state.history[state.pos])
    return
  end

  local c = step.commit
  if not c.previous_sha then
    utils.info("[diffview] Nothing older: " .. short(c.sha) .. " is a root commit.")
    return
  end
  local m = older_line(step)
  if not m then
    utils.info("[diffview] Nothing older: the line was added in " .. short(c.sha) .. ".")
    return
  end

  local ctx, my_seq = state.ctx, state.seq
  blame_line(ctx, m, c.previous_sha, c.previous_file, nil, function(e, err)
    if not state or state.seq ~= my_seq then return end
    if not e then
      utils.warn("[diffview] blame failed: " .. (err or "?"))
      return
    end
    blame_step(ctx, e, function(s2, reason)
      if not state or state.seq ~= my_seq then return end
      if not (s2 and probe(s2, true)) then
        utils.warn("[diffview] " .. (reason or ("could not load " .. short(e.sha))))
        return
      end
      state.history[#state.history + 1] = s2
      state.pos = #state.history
      render(s2)
    end)
  end)
end

---Blame mode: one commit newer (back toward now).
function M.newer()
  if not M.is_open() then return end
  ---@cast state -?
  if state.step.mode ~= "blame" then return end
  if state.pos <= 1 then
    utils.info("[diffview] Already at the newest commit for this line.")
    return
  end
  state.pos = state.pos - 1
  render(state.history[state.pos])
end

---@param dir integer
local function hunk_nav(dir)
  if not M.is_open() then return end
  ---@cast state -?
  local step = state.step
  local ranges = step.built.st.visible_ranges
  local idx = step.built.idx + dir
  if idx < 1 or idx > #ranges then return end
  step.built.idx = idx

  -- Retarget to the cluster's first changed line; for index / branch the
  -- source cursor follows so the float and the file stay in step.
  local st = step.built.st
  local new_lnum, old_lnum
  for r = ranges[idx][1], ranges[idx][2] do
    local info = st.line_map[r]
    if info and info.kind ~= "ctx" then
      new_lnum = new_lnum or info.new_lnum
      old_lnum = old_lnum or info.old_lnum
      if new_lnum then break end
    end
  end
  if new_lnum then
    step.target = { side = "b", lnum = new_lnum }
  else
    -- Pure deletion: anchor on the deleted line; the source cursor goes to
    -- the surviving new-side line after it.
    step.target = { side = "a", lnum = old_lnum }
    new_lnum = 1
    for r = ranges[idx][1], #st.line_map do
      local info = st.line_map[r]
      if info and info.new_lnum then
        new_lnum = info.new_lnum
        break
      end
    end
  end

  if step.new_buf and api.nvim_win_is_valid(state.ctx.src_win) then
    state.moving = true
    state.ctx.lnum = new_lnum
    utils.set_cursor(state.ctx.src_win, new_lnum, 0)
    vim.schedule(function() if state then state.moving = false end end)
  end

  render(step)
end

function M.next_hunk() hunk_nav(1) end
function M.prev_hunk() hunk_nav(-1) end

---Escalate: open (or switch to) the diff view for this base at this line.
function M.open_diffview()
  if not M.is_open() then return end
  ---@cast state -?
  local step, ctx = state.step, state.ctx
  local args, path

  if step.mode == "blame" then
    args = { step.base }
    path = pl:join(ctx.toplevel, step.commit.filename)
  elseif step.mode == "index" then
    args = {}
    path = ctx.abs
  else
    args = { step.base }
    path = ctx.abs
  end

  local target = step.target
  M.close()
  navigate.open_at(args, path, target.side, target.lnum)
end

---Blame mode: copy the commit sha.
function M.yank_sha()
  if not M.is_open() then return end
  ---@cast state -?
  local c = state.step.commit
  if not c then
    utils.info("[diffview] No commit here (press b for the blame base).")
    return
  end
  vim.fn.setreg('"', c.sha)
  pcall(vim.fn.setreg, "+", c.sha)
  utils.info("[diffview] Yanked " .. short(c.sha))
end

---Blame mode: toggle the full commit message under the subject.
function M.toggle_message()
  if not M.is_open() then return end
  ---@cast state -?
  local step = state.step
  if not step.commit then return end

  local function redraw()
    if not (state and state.step == step) then return end
    api.nvim_buf_clear_namespace(state.buf, ns, 0, 1)
    render(step)
  end

  state.show_body = not state.show_body
  if state.show_body and not step.body then
    local my_seq = state.seq
    git(state.ctx, { "log", "-1", "--format=%b", step.commit.sha }, nil, function(code, out)
      if not state or state.seq ~= my_seq then return end
      local body = code == 0 and split_lines(out) or {}
      while body[#body] == "" do body[#body] = nil end
      step.body = #body > 0 and body or { "(no body)" }
      redraw()
    end)
    return
  end
  redraw()
end

--#endregion

return M
