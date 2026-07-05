-- Shared intra-line diff + per-line Treesitter highlight helpers, used by the
-- single-window diff layouts (Diff1Inline, Diff1Unified).

local diff_mod = require("diffview.diff")
local Diff = diff_mod.Diff
local EditToken = diff_mod.EditToken

local api = vim.api

local M = {}

-- Word-level highlight is only meaningful when a deleted line and an added
-- line are genuinely a modification of one another. Be conservative: require
-- strong *content* similarity to pair two lines, and drop the highlight when
-- too much of the line changed (past that point a flat add/delete reads
-- better than scattered noise). Tune these if highlights feel too eager/shy.
M.PAIR_MIN_SIMILARITY = 0.5
M.MAX_CHANGE_RATIO = 0.5

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

-- Run Myers on two token arrays. Returns a result table with:
--   ranges_a, ranges_b      -- coalesced { byte_start, byte_end_excl } lists
--   changed_chars_a/b       -- bytes covered by deletes/replaces on each side
--   total_chars_a/b         -- total byte length of each side
--   similarity              -- matched word bytes / max word bytes
function M.diff_tokens(tok_a, tok_b)
  local d = Diff(tok_a.tokens, tok_b.tokens)
  local script = d:create_edit_script()

  local ranges_a, ranges_b = {}, {}
  local cur_a_s, cur_a_e, cur_b_s, cur_b_e
  local function flush_a()
    if cur_a_s then
      ranges_a[#ranges_a + 1] = { cur_a_s, cur_a_e }
      cur_a_s, cur_a_e = nil, nil
    end
  end
  local function flush_b()
    if cur_b_s then
      ranges_b[#ranges_b + 1] = { cur_b_s, cur_b_e }
      cur_b_s, cur_b_e = nil, nil
    end
  end

  local ai, bi = 1, 1
  local matched_word = 0
  local changed_a, changed_b = 0, 0

  for _, op in ipairs(script) do
    if op == EditToken.NOOP then
      flush_a(); flush_b()
      if tok_a.is_word[ai] then
        matched_word = matched_word + (tok_a.byte_ends_excl[ai] - tok_a.byte_starts[ai])
      end
      ai, bi = ai + 1, bi + 1
    elseif op == EditToken.DELETE then
      local s, e = tok_a.byte_starts[ai], tok_a.byte_ends_excl[ai]
      if cur_a_s then cur_a_e = e else cur_a_s, cur_a_e = s, e end
      flush_b()
      changed_a = changed_a + (e - s)
      ai = ai + 1
    elseif op == EditToken.INSERT then
      local s, e = tok_b.byte_starts[bi], tok_b.byte_ends_excl[bi]
      if cur_b_s then cur_b_e = e else cur_b_s, cur_b_e = s, e end
      flush_a()
      changed_b = changed_b + (e - s)
      bi = bi + 1
    elseif op == EditToken.REPLACE then
      local sa, ea = tok_a.byte_starts[ai], tok_a.byte_ends_excl[ai]
      if cur_a_s then cur_a_e = ea else cur_a_s, cur_a_e = sa, ea end
      local sb, eb = tok_b.byte_starts[bi], tok_b.byte_ends_excl[bi]
      if cur_b_s then cur_b_e = eb else cur_b_s, cur_b_e = sb, eb end
      changed_a = changed_a + (ea - sa)
      changed_b = changed_b + (eb - sb)
      ai, bi = ai + 1, bi + 1
    end
  end
  flush_a(); flush_b()

  local total_a = (#tok_a.byte_ends_excl > 0) and tok_a.byte_ends_excl[#tok_a.byte_ends_excl] or 0
  local total_b = (#tok_b.byte_ends_excl > 0) and tok_b.byte_ends_excl[#tok_b.byte_ends_excl] or 0

  -- Content similarity: fraction of "word" bytes (identifiers, keywords,
  -- numbers) that matched. Whitespace and punctuation are deliberately
  -- ignored, so two unrelated lines that merely share boilerplate like
  -- `if ... then` or `x[#x + 1] = {` don't score as similar.
  local word_denom = math.max(tok_a.word_total, tok_b.word_total, 1)

  return {
    ranges_a = ranges_a,
    ranges_b = ranges_b,
    changed_chars_a = changed_a,
    changed_chars_b = changed_b,
    total_chars_a = total_a,
    total_chars_b = total_b,
    similarity = matched_word / word_denom,
  }
end

-- Filter a diff result through the change-ratio threshold. If too much of
-- either line changed (> MAX_CHANGE_RATIO), the per-token highlights are noise --
-- return nil so the caller falls back to plain add/delete colors.
function M.ratio_filter(result)
  if not result then return nil, nil end
  local ra = result.total_chars_a > 0 and result.changed_chars_a / result.total_chars_a or 0
  local rb = result.total_chars_b > 0 and result.changed_chars_b / result.total_chars_b or 0
  if ra > M.MAX_CHANGE_RATIO or rb > M.MAX_CHANGE_RATIO then return nil, nil end
  return result.ranges_a, result.ranges_b
end

-- Greedily pair deleted lines with added lines by similarity score within a
-- single hunk. Returns a list of { oi, ni, result } where oi/ni are absolute
-- line indices and result is the cached diff_tokens output.
function M.pair_lines(old_toks, new_toks, old_lines, new_lines,
                      old_start, old_count, new_start, new_count)
  local candidates = {}
  for oi = old_start, old_start + old_count - 1 do
    local toa = old_toks[oi]
    if toa then
      local la = old_lines[oi]
      for ni = new_start, new_start + new_count - 1 do
        local tob = new_toks[ni]
        if tob then
          local lb = new_lines[ni]
          if la ~= lb
            and #la > 0 and #lb > 0
            and #la <= 1000 and #lb <= 1000
            and #toa.tokens <= 400 and #tob.tokens <= 400
          then
            local res = M.diff_tokens(toa, tob)
            if res.similarity >= M.PAIR_MIN_SIMILARITY then
              candidates[#candidates + 1] = {
                oi = oi, ni = ni, similarity = res.similarity, result = res,
              }
            end
          end
        end
      end
    end
  end

  table.sort(candidates, function(a, b) return a.similarity > b.similarity end)

  local taken_old, taken_new = {}, {}
  local pairs_list = {}
  for _, c in ipairs(candidates) do
    if not taken_old[c.oi] and not taken_new[c.ni] then
      taken_old[c.oi] = true
      taken_new[c.ni] = true
      pairs_list[#pairs_list + 1] = c
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
