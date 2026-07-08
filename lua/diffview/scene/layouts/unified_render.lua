-- Renders a unified (interleaved context/-/+ lines) diff of two source
-- buffers into a read-only scratch buffer, and owns the per-buffer state
-- mapping every rendered line back to its source line. All rendered lines are
-- REAL buffer lines (selectable, yankable, commentable) — unlike the
-- extmark-decorated inline layout.
--
-- State is keyed by the scratch bufnr. Consumers (jump-to-edit, hunk nav, the
-- comments layer) go through the accessors here rather than reaching into the
-- state tables.

local inline_hl = require("diffview.scene.layouts.inline_hl")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("diffview_unified")
local ns_ts = api.nvim_create_namespace("diffview_unified_ts")

-- Context lines kept visible around each hunk; the rest is folded.
M.CONTEXT = 3

-- Skip word-level pairing for hunks where old_count * new_count exceeds this:
-- the greedy pairer is O(n*m) per hunk and huge rewrite-hunks gain nothing
-- from word diff anyway.
local HUNK_PAIR_CAP = 40000

-- Source lines are Treesitter-highlighted in blocks of this many lines per
-- cache miss, so scrolling costs one parse per block, not per line.
local TS_BLOCK = 120

---@class UnifiedLineInfo
---@field kind "ctx"|"add"|"del"
---@field old_lnum? integer Line number in the old (a) source
---@field new_lnum? integer Line number in the new (b) source

---@class UnifiedState
---@field line_map UnifiedLineInfo[] 1-indexed by rendered row
---@field row_of_new table<integer, integer> new_lnum -> rendered row (ctx + add)
---@field row_of_old table<integer, integer> old_lnum -> rendered row (ctx + del)
---@field hunk_rows integer[] first rendered row of each hunk
---@field fold_ranges { [1]: integer, [2]: integer }[] rows of unchanged gaps
---@field buf_a? integer
---@field buf_b? integer
---@field tick_a? integer changedtick of buf_a at render time
---@field tick_b? integer changedtick of buf_b at render time
---@field w_old integer gutter width for old line numbers
---@field w_new integer gutter width for new line numbers
---@field col_cache table<integer, string> memoized statuscolumn strings
---@field col_wrap? string statuscolumn for wrapped continuation rows
---@field col_blank? string statuscolumn for virtual (virt_lines) rows
---@field ts_cache table<integer, false|{ [1]: integer, [2]: integer, [3]: string }[]>

---@type table<integer, UnifiedState>
M.state = {}

---@param bufnr integer
---@param lnum integer 1-indexed rendered row
---@return UnifiedLineInfo?
function M.get_line_info(bufnr, lnum)
  local st = M.state[bufnr]
  return st and st.line_map[lnum] or nil
end

---Rendered row for a source line.
---@param bufnr integer
---@param side "a"|"b"
---@param lnum integer
---@return integer?
function M.row_for(bufnr, side, lnum)
  local st = M.state[bufnr]
  if not st then return end
  return side == "a" and st.row_of_old[lnum] or st.row_of_new[lnum]
end

---Best line in the NEW file to edit for a given rendered row. Deleted lines
---resolve to the next surviving new-side line (or the last one).
---@param bufnr integer
---@param row integer
---@return integer?
function M.edit_target(bufnr, row)
  local st = M.state[bufnr]
  if not st then return end

  for r = row, #st.line_map do
    local info = st.line_map[r]
    if info and info.new_lnum then return info.new_lnum end
  end
  for r = row - 1, 1, -1 do
    local info = st.line_map[r]
    if info and info.new_lnum then return info.new_lnum end
  end

  return 1
end

---Row of the next/previous hunk relative to `row`.
---@param bufnr integer
---@param row integer
---@param dir integer 1 or -1
---@return integer?
function M.next_hunk_row(bufnr, row, dir)
  local st = M.state[bufnr]
  if not st or #st.hunk_rows == 0 then return end

  if dir > 0 then
    for _, r in ipairs(st.hunk_rows) do
      if r > row then return r end
    end
    return st.hunk_rows[1] -- wrap
  else
    for i = #st.hunk_rows, 1, -1 do
      if st.hunk_rows[i] < row then return st.hunk_rows[i] end
    end
    return st.hunk_rows[#st.hunk_rows] -- wrap
  end
end

function M.cleanup(bufnr)
  M.state[bufnr] = nil
end

---@param file? vcs.File
---@return string[] lines
---@return integer? bufnr
local function source_lines(file)
  if file and file:is_valid() and not file.nulled then
    -- A source that exists but was never loaded (session-restored buffer,
    -- `bufadd()` from another plugin) reads as empty, which would render the
    -- whole file as deleted. These sources are never shown in a window, so
    -- nothing else will ever load them.
    if not api.nvim_buf_is_loaded(file.bufnr) then
      pcall(vim.fn.bufload, file.bufnr)
    end
    return api.nvim_buf_get_lines(file.bufnr, 0, -1, false), file.bufnr
  end
  return {}, nil
end

---Compute the interleaved unified lines + line map from two line arrays.
---@param old_lines string[]
---@param new_lines string[]
---@return string[] lines
---@return UnifiedState st (partially filled: maps, hunks, fold ranges)
---@return table hunks the vim.diff hunks (sorted by new position)
local function build(old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"

  local hunks = {}
  if old_text ~= new_text and (#old_lines > 0 or #new_lines > 0) then
    local ok, diff_result = pcall(vim.diff, old_text, new_text, {
      result_type = "indices",
      algorithm = "histogram",
    })
    if ok and diff_result then
      for _, hunk in ipairs(diff_result) do
        hunks[#hunks + 1] = hunk
      end
      table.sort(hunks, function(x, y) return x[3] < y[3] end)
    end
  end

  local lines = {}
  local line_map = {}
  local row_of_new, row_of_old = {}, {}
  local hunk_rows = {}
  local hunk_row_ranges = {}

  local oi, ni = 1, 1

  local function emit_ctx(o, n)
    lines[#lines + 1] = new_lines[n] or old_lines[o] or ""
    line_map[#lines] = { kind = "ctx", old_lnum = o, new_lnum = n }
    row_of_new[n] = #lines
    row_of_old[o] = #lines
  end

  for _, hunk in ipairs(hunks) do
    local sa, ca, sb, cb = hunk[1], hunk[2], hunk[3], hunk[4]
    -- vim.diff indices: when a count is 0, the start is the line *after which*
    -- the change applies — so that line is still context.
    local ctx_end_old = ca > 0 and sa - 1 or sa

    while oi <= ctx_end_old and ni <= #new_lines and oi <= #old_lines do
      emit_ctx(oi, ni)
      oi, ni = oi + 1, ni + 1
    end

    local hunk_first = #lines + 1

    for k = sa, sa + ca - 1 do
      if old_lines[k] then
        lines[#lines + 1] = old_lines[k]
        line_map[#lines] = { kind = "del", old_lnum = k }
        row_of_old[k] = #lines
      end
    end
    if ca > 0 then oi = sa + ca end

    for k = sb, sb + cb - 1 do
      if new_lines[k] then
        lines[#lines + 1] = new_lines[k]
        line_map[#lines] = { kind = "add", new_lnum = k }
        row_of_new[k] = #lines
      end
    end
    if cb > 0 then ni = sb + cb end

    if #lines >= hunk_first then
      hunk_rows[#hunk_rows + 1] = hunk_first
      hunk_row_ranges[#hunk_row_ranges + 1] = { hunk_first, #lines }
    end
  end

  -- Trailing context.
  while oi <= #old_lines and ni <= #new_lines do
    emit_ctx(oi, ni)
    oi, ni = oi + 1, ni + 1
  end
  -- Defensive: if the tails disagree (shouldn't happen), surface the rest
  -- rather than silently dropping lines.
  while ni <= #new_lines do
    lines[#lines + 1] = new_lines[ni]
    line_map[#lines] = { kind = "add", new_lnum = ni }
    row_of_new[ni] = #lines
    ni = ni + 1
  end
  while oi <= #old_lines do
    lines[#lines + 1] = old_lines[oi]
    line_map[#lines] = { kind = "del", old_lnum = oi }
    row_of_old[oi] = #lines
    oi = oi + 1
  end

  -- Unchanged gaps to fold: complement of (hunk ranges padded by CONTEXT).
  local fold_ranges = {}
  local visible_ranges = {}
  if #hunk_row_ranges > 0 then
    local visible = {}
    for _, r in ipairs(hunk_row_ranges) do
      visible[#visible + 1] = { math.max(1, r[1] - M.CONTEXT), math.min(#lines, r[2] + M.CONTEXT) }
    end
    local merged = { visible[1] }
    for k = 2, #visible do
      local prev, cur = merged[#merged], visible[k]
      if cur[1] <= prev[2] + 1 then
        prev[2] = math.max(prev[2], cur[2])
      else
        merged[#merged + 1] = cur
      end
    end
    visible_ranges = merged
    local pos = 1
    for _, range in ipairs(merged) do
      if pos < range[1] then
        fold_ranges[#fold_ranges + 1] = { pos, range[1] - 1 }
      end
      pos = range[2] + 1
    end
    if pos <= #lines then
      fold_ranges[#fold_ranges + 1] = { pos, #lines }
    end
  end

  local st = {
    line_map = line_map,
    row_of_new = row_of_new,
    row_of_old = row_of_old,
    hunk_rows = hunk_rows,
    fold_ranges = fold_ranges,
    visible_ranges = visible_ranges,
    w_old = math.max(1, #tostring(#old_lines)),
    w_new = math.max(1, #tostring(#new_lines)),
    col_cache = {},
    ts_cache = {},
    ts_pending = {},
    ts_avail = {},
  }

  return lines, st, hunks
end

---Apply persistent highlight extmarks: add/del line backgrounds + word-level
---change ranges (via the shared inline_hl pairing).
---@param bufnr integer
---@param st UnifiedState
---@param hunks table
---@param old_lines string[]
---@param new_lines string[]
local function apply_hl(bufnr, st, hunks, old_lines, new_lines)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, hunk in ipairs(hunks) do
    local sa, ca, sb, cb = hunk[1], hunk[2], hunk[3], hunk[4]

    -- Word-level ranges, keyed by absolute source line index.
    local range_for_old, range_for_new = {}, {}
    if ca > 0 and cb > 0 and ca * cb <= HUNK_PAIR_CAP then
      local old_toks, new_toks = {}, {}
      for k = sa, sa + ca - 1 do
        if old_lines[k] then old_toks[k] = inline_hl.tokenize(old_lines[k]) end
      end
      for k = sb, sb + cb - 1 do
        if new_lines[k] then new_toks[k] = inline_hl.tokenize(new_lines[k]) end
      end
      local pairs_list = inline_hl.pair_lines(old_toks, new_toks, old_lines, new_lines, sa, ca, sb, cb)
      for _, p in ipairs(pairs_list) do
        local ra, rb = inline_hl.ratio_filter(p.result)
        range_for_old[p.oi] = ra
        range_for_new[p.ni] = rb
      end
    end

    -- The add/del bands are drawn as full-line RANGE highlights (hl_eol
    -- carries them past EOL), NOT line_hl_group: as of nvim 0.12 a
    -- line_hl_group background paints over range highlights regardless of
    -- priority, which would swallow the word-level emphasis below.
    for k = sa, sa + ca - 1 do
      local row = st.row_of_old[k]
      if row then
        api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
          end_row = row,
          end_col = 0,
          hl_group = "DiffviewDiffDelete",
          hl_eol = true,
          strict = false,
          priority = 50,
        })
        for _, range in ipairs(range_for_old[k] or {}) do
          if range[2] > range[1] then
            api.nvim_buf_set_extmark(bufnr, ns, row - 1, range[1], {
              end_col = range[2],
              hl_group = "DiffviewDiffDeleteText",
              priority = 51,
            })
          end
        end
      end
    end

    for k = sb, sb + cb - 1 do
      local row = st.row_of_new[k]
      if row then
        api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
          end_row = row,
          end_col = 0,
          hl_group = "DiffviewDiffAdd",
          hl_eol = true,
          strict = false,
          priority = 50,
        })
        for _, range in ipairs(range_for_new[k] or {}) do
          if range[2] > range[1] then
            api.nvim_buf_set_extmark(bufnr, ns, row - 1, range[1], {
              end_col = range[2],
              hl_group = "DiffviewDiffText",
              priority = 51,
            })
          end
        end
      end
    end
  end
end

---Render the unified diff of two source buffers into `bufnr`.
---@param bufnr integer The scratch buffer to render into.
---@param file_a? vcs.File Old side.
---@param file_b? vcs.File New side.
---@return UnifiedState st
---@return boolean changed False when the content was already up to date.
function M.render(bufnr, file_a, file_b)
  local old_lines, buf_a = source_lines(file_a)
  local new_lines, buf_b = source_lines(file_b)

  local tick_a = buf_a and api.nvim_buf_get_changedtick(buf_a) or -1
  local tick_b = buf_b and api.nvim_buf_get_changedtick(buf_b) or -1

  local prev = M.state[bufnr]
  if prev
    and prev.buf_a == buf_a and prev.buf_b == buf_b
    and prev.tick_a == tick_a and prev.tick_b == tick_b
  then
    return prev, false
  end

  local lines, st, hunks = build(old_lines, new_lines)
  st.buf_a, st.buf_b = buf_a, buf_b
  st.tick_a, st.tick_b = tick_a, tick_b

  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  M.state[bufnr] = st
  apply_hl(bufnr, st, hunks, old_lines, new_lines)

  -- Color the default-visible region up front (normal context — parser
  -- creation is not allowed during redraw). Rows inside folds fill lazily via
  -- the decoration provider when they scroll into view.
  M._ts_precompute(st, st.visible_ranges)

  -- Content replacement moved/cleared any foreign extmarks (e.g. comment
  -- threads) — let interested layers repaint against the new line_map.
  api.nvim_exec_autocmds("User", {
    pattern = "DiffviewUnifiedRendered",
    modeline = false,
    data = { buf = bufnr },
  })

  return st, true
end

---Fold the unchanged gaps in a window displaying a rendered buffer.
---@param winid integer
---@param bufnr integer
function M.apply_folds(winid, bufnr)
  local st = M.state[bufnr]
  if not st or not api.nvim_win_is_valid(winid) or api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end

  api.nvim_win_call(winid, function()
    pcall(vim.cmd, "norm! zE")
    for _, range in ipairs(st.fold_ranges) do
      pcall(vim.cmd, ("%d,%dfold"):format(range[1], range[2]))
    end
  end)
end

--#region window decoration callbacks

---'statuscolumn' callback: dual gutter `old new ±` with a leading sign slot.
---O(1) per line after the first visit (memoized per rendered row).
---Resolves the buffer from the window being drawn (g:statusline_winid), not
---the current window — the column must not collapse when focus is elsewhere.
function M.statuscol()
  local win = vim.g.statusline_winid
  local buf = (win and win ~= 0) and api.nvim_win_get_buf(win) or api.nvim_get_current_buf()
  local st = M.state[buf]
  if not st then return "" end

  -- Non-buffer screen rows keep the gutter width but not the numbers:
  -- wrapped continuation rows get a wrap marker in the marker slot (the text
  -- area's breakindent/showbreak region can't take the diff line background,
  -- so the unified window draws the marker here instead — see the window
  -- opts in diff_1_unified), virt_lines rows (comment boxes) stay blank.
  local virtnum = vim.v.virtnum
  if virtnum > 0 then
    if not st.col_wrap then
      st.col_wrap = ("%%s%s%%#DiffviewNonText#↪%%* "):format((" "):rep(st.w_old + st.w_new + 2))
    end
    return st.col_wrap
  elseif virtnum < 0 then
    if not st.col_blank then
      st.col_blank = "%s" .. (" "):rep(st.w_old + st.w_new + 4)
    end
    return st.col_blank
  end

  local lnum = vim.v.lnum
  local cached = st.col_cache[lnum]
  if cached then return cached end

  local info = st.line_map[lnum]
  if not info then return "" end

  local old_s = info.old_lnum and tostring(info.old_lnum) or ""
  local new_s = info.new_lnum and tostring(info.new_lnum) or ""
  old_s = string.rep(" ", st.w_old - #old_s) .. old_s
  new_s = string.rep(" ", st.w_new - #new_s) .. new_s

  local marker
  if info.kind == "add" then
    marker = "%#DiffviewUnifiedSignAdd#+"
  elseif info.kind == "del" then
    marker = "%#DiffviewUnifiedSignDel#-"
  else
    marker = " "
  end

  local col = ("%%s%%#DiffviewUnifiedNumOld#%s %%#DiffviewUnifiedNumNew#%s %s%%* ")
    :format(old_s, new_s, marker)
  st.col_cache[lnum] = col
  return col
end

---'foldtext' callback: "··· N unchanged lines ···" (fillchars 'fold' pads).
function M.foldtext()
  return ("─── ··· %d unchanged lines ··· "):format(vim.v.foldend - vim.v.foldstart + 1)
end

--#endregion

--#region per-line Treesitter via decoration provider

---Whether a source buffer can produce Treesitter highlights. Probed once per
---render, in a normal (non-redraw) context — parser creation is not allowed
---during redraw.
---@param st UnifiedState
---@param side "a"|"b"
---@return boolean
local function ts_side_available(st, side)
  local cached = st.ts_avail[side]
  if cached ~= nil then return cached end

  local src_buf = (side == "a") and st.buf_a or st.buf_b
  local avail = false

  if src_buf and api.nvim_buf_is_valid(src_buf) then
    local ok, parser = pcall(vim.treesitter.get_parser, src_buf)
    avail = ok and parser ~= nil
  end

  st.ts_avail[side] = avail
  return avail
end

---Compute + cache TS spans for a block of rendered rows around `row`.
---Deleted rows take their highlights from source buffer a, everything else
---from source buffer b. Costs one ranged parse per TS_BLOCK rows.
---MUST be called from a normal context (not during redraw).
---@param st UnifiedState
---@param row integer 0-indexed
local function ts_fill_block(st, row)
  local info = st.line_map[row + 1]
  if not info then
    st.ts_cache[row] = false
    return
  end

  local side = (info.kind == "del") and "a" or "b"
  local src_buf = (side == "a") and st.buf_a or st.buf_b

  if not ts_side_available(st, side) then
    st.ts_cache[row] = false
    return
  end

  local src_lnum = info.old_lnum or info.new_lnum
  local src_count = api.nvim_buf_line_count(src_buf)
  local lstart = math.max(0, src_lnum - 1 - math.floor(TS_BLOCK / 2))
  local lend_excl = math.min(src_count, lstart + TS_BLOCK)

  local texts = {}
  local got = api.nvim_buf_get_lines(src_buf, lstart, lend_excl, false)
  for i, text in ipairs(got) do
    texts[lstart + i] = text
  end

  local ok, spans_by_lnum = pcall(inline_hl.ts_spans_for_lines, src_buf, lstart, lend_excl, texts)
  if not ok then spans_by_lnum = {} end

  -- Distribute onto every rendered row whose source line (same side) falls in
  -- the block, and mark the whole block as computed.
  local row_of = (side == "a") and st.row_of_old or st.row_of_new
  for l = lstart + 1, lend_excl do
    local r = row_of[l]
    if r then
      local r_info = st.line_map[r]
      -- `del` rows only come from side a blocks; ctx/add only from side b.
      local matches = (side == "a") == (r_info.kind == "del")
      if matches and st.ts_cache[r - 1] == nil then
        st.ts_cache[r - 1] = spans_by_lnum[l - 1] or false
      end
    end
  end

  if st.ts_cache[row] == nil then
    st.ts_cache[row] = false
  end
end

---Precompute TS spans for a set of rendered row ranges (1-indexed, inclusive).
---Called at render time so the default-visible region is colored on the very
---first frame.
---@param st UnifiedState
---@param ranges { [1]: integer, [2]: integer }[]
local function ts_precompute(st, ranges)
  for _, range in ipairs(ranges) do
    for r = range[1], range[2] do
      if st.ts_cache[r - 1] == nil then
        pcall(ts_fill_block, st, r - 1)
      end
    end
  end
end

M._ts_precompute = ts_precompute

api.nvim_set_decoration_provider(ns_ts, {
  on_win = function(_, _, bufnr, _, _)
    return M.state[bufnr] ~= nil
  end,
  on_line = function(_, _, bufnr, row)
    local st = M.state[bufnr]
    if not st then return end

    local spans = st.ts_cache[row]

    if spans == nil then
      -- Cache miss (a row inside an opened fold): parsing is not allowed
      -- during redraw, so fill the block on the main loop and repaint.
      if not st.ts_pending[row] then
        st.ts_pending[row] = true
        vim.schedule(function()
          if M.state[bufnr] ~= st then return end
          pcall(ts_fill_block, st, row)
          st.ts_pending[row] = nil
          for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            pcall(api.nvim__redraw, { win = win, valid = false })
          end
        end)
      end
      return
    end

    if spans then
      for _, s in ipairs(spans) do
        api.nvim_buf_set_extmark(bufnr, ns_ts, row, s[1], {
          end_col = s[2],
          hl_group = s[3],
          ephemeral = true,
          priority = 200,
        })
      end
    end
  end,
})

--#endregion

return M
