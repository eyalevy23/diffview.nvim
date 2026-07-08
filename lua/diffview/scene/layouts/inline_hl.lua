-- Shared intra-line diff + per-line Treesitter highlight helpers, used by the
-- single-window diff layouts (Diff1Inline, Diff1Unified).

local diff_mod = require("diffview.diff")
local Diff = diff_mod.Diff
local EditToken = diff_mod.EditToken

local api = vim.api

local M = {}

-- Word-level highlight is only meaningful when a deleted line and an added
-- line are genuinely a modification of one another, and only readable when
-- the result is a small number of clean ranges. The philosophy (borrowed
-- from delta): show nothing rather than confetti — a flat add/delete reads
-- better than a fragmented or mostly-emphasized line.
M.PAIR_MIN_SIMILARITY = 0.5 -- min content similarity to align lines in n:m hunks
M.MAX_EMPHASIS_RATIO = 0.6  -- flat when more than this much content is emphasized
M.MAX_RANGES = 3            -- flat when a line needs more ranges than this
M.WEAK_GAP_MAX_BYTES = 4    -- matched wordless gaps up to this wide merge into ranges

-- Tokenize a line into runs of word chars, runs of whitespace, and single
-- "other" chars (punctuation, multi-byte). Returns parallel arrays of token
-- strings plus 0-indexed byte offsets [start, end_excl) for each token.
function M.tokenize(s)
  local tokens, byte_starts, byte_ends_excl, is_word = {}, {}, {}, {}
  local word_total = 0
  local len = #s
  local i = 1

  local function utf8_len(byte)
    if byte < 0x80 then return 1
    elseif byte < 0xC0 then return 1
    elseif byte < 0xE0 then return 2
    elseif byte < 0xF0 then return 3
    elseif byte < 0xF8 then return 4
    else return 1 end
  end

  local function kind(byte)
    if (byte >= 0x30 and byte <= 0x39)
      or (byte >= 0x41 and byte <= 0x5A)
      or (byte >= 0x61 and byte <= 0x7A)
      or byte == 0x5F then return "word" end
    if byte == 0x20 or byte == 0x09 then return "space" end
    if byte < 0x80 then return "other" end
    return "utf8"
  end

  while i <= len do
    local b = s:byte(i)
    local k = kind(b)
    local start = i - 1

    if k == "word" or k == "space" then
      local j = i + 1
      while j <= len and kind(s:byte(j)) == k do
        j = j + 1
      end
      tokens[#tokens + 1] = s:sub(i, j - 1)
      byte_starts[#byte_starts + 1] = start
      byte_ends_excl[#byte_ends_excl + 1] = j - 1
      is_word[#is_word + 1] = (k == "word")
      if k == "word" then word_total = word_total + (j - 1 - start) end
      i = j
    else
      local clen = utf8_len(b)
      local j = i + clen
      if j > len + 1 then j = len + 1 end
      tokens[#tokens + 1] = s:sub(i, j - 1)
      byte_starts[#byte_starts + 1] = start
      byte_ends_excl[#byte_ends_excl + 1] = j - 1
      is_word[#is_word + 1] = false
      i = j
    end
  end

  return {
    tokens = tokens,
    byte_starts = byte_starts,
    byte_ends_excl = byte_ends_excl,
    is_word = is_word,
    word_total = word_total,
  }
end

---Common prefix + suffix byte count of two strings (capped so overlapping
---affixes are not double counted).
---@param a string
---@param b string
---@return integer
local function common_affix(a, b)
  local n = math.min(#a, #b)
  local p = 0
  while p < n and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
  local s = 0
  while s < n - p and a:byte(#a - s) == b:byte(#b - s) do s = s + 1 end
  return p + s
end

-- Run Myers on two token arrays. Returns a result table consumed by
-- `ratio_filter()`:
--   segs_a, segs_b          -- per-side segment runs { changed, s, e, has_word }
--   changed_chars_a/b       -- bytes covered by deletes/replaces on each side
--   content_chars_a/b       -- byte length excluding leading/trailing whitespace
--   similarity              -- matched word bytes / max word bytes
function M.diff_tokens(tok_a, tok_b)
  local d = Diff(tok_a.tokens, tok_b.tokens)
  local script = d:create_edit_script()

  local function new_side(tok)
    return { tok = tok, segs = {}, changed = 0, cur = nil }
  end

  local function push(side, changed, i)
    local tok = side.tok
    local s, e = tok.byte_starts[i], tok.byte_ends_excl[i]
    -- Whitespace runs carry no information: they don't count toward the
    -- emphasis ratio (so indent shifts don't drown a tiny real change).
    local b1 = tok.tokens[i]:byte(1)
    local nonws = (b1 == 0x20 or b1 == 0x09) and 0 or (e - s)
    local cur = side.cur
    if cur and cur.changed == changed then
      cur.e = e
      cur.has_word = cur.has_word or tok.is_word[i]
      cur.nonws = cur.nonws + nonws
    else
      if cur then side.segs[#side.segs + 1] = cur end
      side.cur = { changed = changed, s = s, e = e, has_word = tok.is_word[i], nonws = nonws }
    end
    if changed then side.changed = side.changed + (e - s) end
  end

  local A, B = new_side(tok_a), new_side(tok_b)
  local ai, bi = 1, 1
  local matched_word = 0

  for _, op in ipairs(script) do
    if op == EditToken.NOOP then
      push(A, false, ai)
      push(B, false, bi)
      if tok_a.is_word[ai] then
        matched_word = matched_word + (tok_a.byte_ends_excl[ai] - tok_a.byte_starts[ai])
      end
      ai, bi = ai + 1, bi + 1
    elseif op == EditToken.DELETE then
      push(A, true, ai)
      ai = ai + 1
    elseif op == EditToken.INSERT then
      push(B, true, bi)
      bi = bi + 1
    elseif op == EditToken.REPLACE then
      push(A, true, ai)
      push(B, true, bi)
      -- Partial credit: a replaced identifier that shares most of its bytes
      -- (a rename, a changed suffix) still signals homologous lines. Without
      -- this, one long changed identifier tanks the score of an otherwise
      -- identical line.
      if tok_a.is_word[ai] and tok_b.is_word[bi] then
        matched_word = matched_word + common_affix(tok_a.tokens[ai], tok_b.tokens[bi])
      end
      ai, bi = ai + 1, bi + 1
    end
  end
  if A.cur then A.segs[#A.segs + 1] = A.cur end
  if B.cur then B.segs[#B.segs + 1] = B.cur end

  -- Content span: exclude pure-whitespace lead/tail so indentation doesn't
  -- dilute the emphasis ratio.
  local function content_chars(tok)
    local first, last
    for i = 1, #tok.tokens do
      if tok.tokens[i]:match("%S") then
        first = first or tok.byte_starts[i]
        last = tok.byte_ends_excl[i]
      end
    end
    return (first and last) and (last - first) or 0
  end

  -- Content similarity: fraction of "word" bytes (identifiers, keywords,
  -- numbers) that matched. Whitespace and punctuation are deliberately
  -- ignored, so two unrelated lines that merely share boilerplate like
  -- `if ... then` or `x[#x + 1] = {` don't score as similar.
  local word_denom = math.max(tok_a.word_total, tok_b.word_total, 1)

  return {
    segs_a = A.segs,
    segs_b = B.segs,
    changed_chars_a = A.changed,
    changed_chars_b = B.changed,
    content_chars_a = content_chars(tok_a),
    content_chars_b = content_chars(tok_b),
    similarity = math.min(matched_word / word_denom, 1),
  }
end

---Coalesce one side's segments into display ranges. Changed runs separated
---only by a narrow, wordless matched gap ("(", " = ", ", ") merge into one
---range — fragmented confetti reads as noise.
---@param segs { changed: boolean, s: integer, e: integer, has_word: boolean }[]
---@return { [1]: integer, [2]: integer }[] ranges
---@return integer emphasized total bytes covered
local function coalesce(segs)
  local ranges, emphasized = {}, 0
  local i = 1
  while i <= #segs do
    local seg = segs[i]
    if seg.changed then
      local s, e = seg.s, seg.e
      local nonws = seg.nonws
      local j = i + 1
      while j + 1 <= #segs
        and not segs[j].changed
        and not segs[j].has_word
        and (segs[j].e - segs[j].s) <= M.WEAK_GAP_MAX_BYTES
        and segs[j + 1].changed
      do
        e = segs[j + 1].e
        nonws = nonws + segs[j].nonws + segs[j + 1].nonws
        j = j + 2
      end
      ranges[#ranges + 1] = { s, e }
      emphasized = emphasized + nonws
      i = j
    else
      i = i + 1
    end
  end
  return ranges, emphasized
end

-- Turn a diff result into display ranges — or nothing. This is the layer
-- that makes word highlights readable; both gates reject the emphasis
-- entirely (flat add/delete colors) rather than degrade it:
--   * fragmentation: a line that needs more than MAX_RANGES ranges isn't
--     summarizable — the highlight would be confetti
--   * ratio: when most of a line's content is emphasized, the emphasis
--     carries no information
function M.ratio_filter(result)
  if not result then return nil, nil end

  local ranges_a, emph_a = coalesce(result.segs_a)
  local ranges_b, emph_b = coalesce(result.segs_b)

  if #ranges_a > M.MAX_RANGES or #ranges_b > M.MAX_RANGES then return nil, nil end

  local qa = result.content_chars_a > 0 and emph_a / result.content_chars_a or 0
  local qb = result.content_chars_b > 0 and emph_b / result.content_chars_b or 0
  if qa > M.MAX_EMPHASIS_RATIO or qb > M.MAX_EMPHASIS_RATIO then return nil, nil end

  return ranges_a, ranges_b
end

-- Pair deleted lines with added lines within one hunk, in order — pairs
-- never cross, homologs keep their relative position (like delta's edit
-- inference). Returns a list of { oi, ni, result } where oi/ni are absolute
-- line indices and result is the cached diff_tokens output.
--
--   * a 1:1 hunk pairs unconditionally: a single edited line is THE common
--     case, and the display gates in `ratio_filter()` are the real filter
--   * larger hunks align via DP on content similarity: only pairs scoring
--     at least PAIR_MIN_SIMILARITY can align; everything else stays flat
function M.pair_lines(old_toks, new_toks, old_lines, new_lines,
                      old_start, old_count, new_start, new_count)
  local function diffable(oi, ni)
    local toa, tob = old_toks[oi], new_toks[ni]
    if not (toa and tob) then return false end
    local la, lb = old_lines[oi], new_lines[ni]
    return la ~= lb
      and #la > 0 and #lb > 0
      and #la <= 1000 and #lb <= 1000
      and #toa.tokens <= 400 and #tob.tokens <= 400
  end

  if old_count == 1 and new_count == 1 then
    if not diffable(old_start, new_start) then return {} end
    return { {
      oi = old_start,
      ni = new_start,
      result = M.diff_tokens(old_toks[old_start], new_toks[new_start]),
    } }
  end

  -- Memoized pair diffs, keyed by relative "i:j".
  local results = {}
  local function sim(i, j)
    local oi, ni = old_start + i - 1, new_start + j - 1
    local key = i .. ":" .. j
    if results[key] == nil then
      results[key] = diffable(oi, ni) and M.diff_tokens(old_toks[oi], new_toks[ni]) or false
    end
    local res = results[key]
    return res and res.similarity or nil
  end

  -- Needleman-Wunsch over lines: maximize total similarity of aligned pairs.
  local dp, choice = {}, {}
  for i = 0, old_count do
    dp[i] = {}
    dp[i][0] = 0
  end
  for j = 0, new_count do dp[0][j] = 0 end

  for i = 1, old_count do
    choice[i] = {}
    for j = 1, new_count do
      local best, c = dp[i - 1][j], "up"
      if dp[i][j - 1] > best then best, c = dp[i][j - 1], "left" end
      local s = sim(i, j)
      if s and s >= M.PAIR_MIN_SIMILARITY and dp[i - 1][j - 1] + s > best then
        best, c = dp[i - 1][j - 1] + s, "diag"
      end
      dp[i][j] = best
      choice[i][j] = c
    end
  end

  local pairs_list = {}
  local i, j = old_count, new_count
  while i > 0 and j > 0 do
    local c = choice[i][j]
    if c == "diag" then
      pairs_list[#pairs_list + 1] = {
        oi = old_start + i - 1,
        ni = new_start + j - 1,
        result = results[i .. ":" .. j],
      }
      i, j = i - 1, j - 1
    elseif c == "up" then
      i = i - 1
    else
      j = j - 1
    end
  end
  return pairs_list
end

-- Query Treesitter for highlight spans across a range of lines in `buf`.
-- Returns a map { [0-indexed lnum] = { { byte_start, byte_end_excl, hl_group }, ... } }.
-- Empty table if no parser is available for the buffer's filetype.
function M.ts_spans_for_lines(buf, lstart, lend_excl, line_texts_1idx)
  if not buf or not api.nvim_buf_is_valid(buf) then return {} end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then return {} end

  pcall(function() parser:parse({ lstart, lend_excl }) end)

  local spans_by_lnum = {}
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then return end

    for id, node in query:iter_captures(tree:root(), buf, lstart, lend_excl) do
      local capture = query.captures[id]
      if capture and capture:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        local hl = "@" .. capture .. "." .. lang
        local lo = math.max(sr, lstart)
        local hi = math.min(er, lend_excl - 1)
        for lnum = lo, hi do
          local line = line_texts_1idx[lnum + 1] or ""
          local s = (lnum == sr) and sc or 0
          local e = (lnum == er) and ec or #line
          if e > s then
            spans_by_lnum[lnum] = spans_by_lnum[lnum] or {}
            spans_by_lnum[lnum][#spans_by_lnum[lnum] + 1] = { s, e, hl }
          end
        end
      end
    end
  end)

  return spans_by_lnum
end

return M
