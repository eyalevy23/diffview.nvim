-- Inline rendering of comment threads in a diff buffer: a gutter sign on the
-- anchored line plus a bordered virt_lines box under it (hunk-style "note in
-- the document"), in a dedicated namespace so diff re-renders never wipe it.

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("diffview_comments")

M.ns = ns

-- Threads render their bodies inline while open; resolved threads shrink to a
-- dim sign so the document stays clean.
local SIGN_OPEN = "●"
local SIGN_RESOLVED = "○"
local SIGN_APPLIED = "✓"

-- Cards never grow past this, no matter how wide the window is — full-bleed
-- comment boxes on an ultrawide read worse than a bounded card.
local MAX_CARD_WIDTH = 100

---@param author string
---@return boolean
local function is_ai(author)
  return author == "claude" or author == "ai"
end

---In-card author styling (carries the card background).
---@param author string
---@return string hl
local function author_hl(author)
  return is_ai(author) and "DiffviewCommentAuthorAI" or "DiffviewCommentAuthorHuman"
end

---Gutter-sign styling (no card background — it sits in the sign column).
---@param author string
---@return string hl
local function sign_hl(author)
  return is_ai(author) and "DiffviewCommentSignAI" or "DiffviewCommentSignHuman"
end

---@param author string
---@return string icon
local function author_icon(author)
  local icons = require("diffview.config").get_config().comments.icons or {}
  if is_ai(author) then return icons.ai or "󰚩" end
  return icons.human or ""
end

---Hard-split a single over-width word into display-width sized chunks
---(binary search per chunk — handles wide chars).
---@param word string
---@param width integer
---@return string[]
local function split_word(word, width)
  local out = {}
  local total = vim.fn.strchars(word)
  local pos = 0
  while pos < total do
    local lo, hi = 1, total - pos
    while lo < hi do
      local mid = math.ceil((lo + hi) / 2)
      if vim.fn.strdisplaywidth(vim.fn.strcharpart(word, pos, mid)) > width then
        hi = mid - 1
      else
        lo = mid
      end
    end
    out[#out + 1] = vim.fn.strcharpart(word, pos, lo)
    pos = pos + lo
  end
  return out
end

---Wrap `text` to `width` display cells, breaking on spaces — a word is only
---hard-split when it is itself wider than `width`. Leading indent sticks to
---the first line (suggestion text is code). Returns at least one line.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  width = math.max(width, 16)
  if vim.fn.strdisplaywidth(text) <= width then return { text } end

  local out = {}
  local line = nil ---@type string?

  for ws, word in text:gmatch("(%s*)(%S+)") do
    -- The first word keeps the leading indent; later words keep their
    -- separating whitespace when they stay on the same line.
    local joined = (line == nil) and (ws .. word) or (line .. ws .. word)

    if vim.fn.strdisplaywidth(joined) <= width then
      line = joined
    else
      if line ~= nil then
        out[#out + 1] = line
        line = nil
      end
      if vim.fn.strdisplaywidth(word) <= width then
        line = word
      else
        local pieces = split_word(word, width)
        for i = 1, #pieces - 1 do
          out[#out + 1] = pieces[i]
        end
        line = pieces[#pieces]
      end
    end
  end

  if line ~= nil and line ~= "" then out[#out + 1] = line end
  if #out == 0 then out[1] = text end
  return out
end

---Relative timestamp ("2h ago"); anything older than a week falls back to
---the plain date. Recomputed on every repaint, so it stays roughly honest.
---@param ts? string
---@return string
local function rel_ts(ts)
  local epoch = require("diffview.comments.store").parse_ts(ts)
  if not epoch then return "" end

  local d = os.time() - epoch
  if d < 60 then return "just now" end
  if d < 3600 then return ("%dm ago"):format(math.floor(d / 60)) end
  if d < 86400 then return ("%dh ago"):format(math.floor(d / 3600)) end
  if d < 7 * 86400 then return ("%dd ago"):format(math.floor(d / 86400)) end
  return ts and ts:match("^(%d+%-%d+%-%d+)") or ""
end

---Total display width of a chunk list.
---@param chunks table[]
---@return integer
local function chunk_width(chunks)
  local w = 0
  for _, c in ipairs(chunks) do w = w + vim.fn.strdisplaywidth(c[1]) end
  return w
end

---Split one display line into (text, hl) chunks, styling `inline code`
---spans. An unpaired backtick renders literally.
---@param text string
---@param body_hl string
---@return table[] chunks
local function inline_chunks(text, body_hl)
  local chunks = {}
  local pos = 1
  while true do
    local s, e, code = text:find("`([^`]+)`", pos)
    if not s then break end
    if s > pos then chunks[#chunks + 1] = { text:sub(pos, s - 1), body_hl } end
    chunks[#chunks + 1] = { code, "DiffviewCommentInlineCode" }
    pos = e + 1
  end
  if pos <= #text then chunks[#chunks + 1] = { text:sub(pos), body_hl } end
  if #chunks == 0 then chunks[1] = { text, body_hl } end
  return chunks
end

--#region suggestion syntax highlighting

-- Suggestions are code: give them real Treesitter colors over the add-tint,
-- GitHub-style. Every path here degrades to the plain tint — no parser, no
-- filetype, no gui colors, oversized lines — all fall back silently.

local MAX_HL_LINE = 500 -- bytes; don't paint minified monsters

-- All three caches are bounded the same way: wholesale reset past the cap.
-- They re-fill lazily; entries are tiny, the caps are generous.
local CACHE_MAX = 256

---filetype → TS lang per anchored path ("" = known-unresolvable).
local lang_cache, lang_cache_n = {}, 0

---Parsed spans per (lang, text): table<lnum0, span[]> | false (uncolorable).
local span_cache, span_cache_n = {}, 0
local SPAN_CACHE_MAX = 128

---Combined groups (capture fg over the suggestion bg): name | false.
local sugg_groups, sugg_groups_n = {}, 0

api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("diffview_comments_render", { clear = true }),
  callback = function()
    -- `:hi clear` wiped the derived groups; re-create them lazily against
    -- the new colorscheme.
    sugg_groups, sugg_groups_n = {}, 0
  end,
})

---@param path? string
---@return string? lang
local function lang_for(path)
  if not path then return end
  local hit = lang_cache[path]
  if hit ~= nil then return hit ~= "" and hit or nil end

  if lang_cache_n >= CACHE_MAX then lang_cache, lang_cache_n = {}, 0 end

  local ft = vim.filetype.match({ filename = path })
  local lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
  lang_cache[path] = lang or ""
  lang_cache_n = lang_cache_n + 1
  return lang
end

---Parse a suggestion body and collect capture spans per line. A suggestion
---is a fragment parsed out of context — Treesitter's error recovery makes
---this mostly right; an occasional off token is cosmetic.
---@param text string
---@param lang string
---@return table<integer, { [1]: integer, [2]: integer, [3]: string }[]>? spans_by_line0 [start_byte, end_byte, capture]
local function suggestion_spans(text, lang)
  local key = lang .. "\0" .. text
  local hit = span_cache[key]
  if hit ~= nil then return hit or nil end

  if span_cache_n >= SPAN_CACHE_MAX then span_cache, span_cache_n = {}, 0 end

  local ok, spans = pcall(function()
    local parser = vim.treesitter.get_string_parser(text, lang)
    local root = parser:parse(true)[1]:root()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then return nil end

    local by_line = {}
    for id, node in query:iter_captures(root, text, 0, -1) do
      local capture = query.captures[id]
      if capture ~= "spell" and capture ~= "nospell" and capture ~= "none" and capture:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        for l = sr, math.min(er, sr + 50) do
          by_line[l] = by_line[l] or {}
          local line_spans = by_line[l]
          line_spans[#line_spans + 1] = {
            l == sr and sc or 0,
            l == er and ec or math.huge,
            capture,
          }
        end
      end
    end
    return by_line
  end)

  span_cache[key] = ok and spans or false
  span_cache_n = span_cache_n + 1
  return ok and spans or nil
end

---The combined group for a capture over the suggestion background. Created
---on demand; re-created after ColorScheme wipes them.
---@param capture string e.g. "keyword.function"
---@param lang string
---@return string? group
local function capture_hl(capture, lang)
  local key = capture .. "@" .. lang
  local hit = sugg_groups[key]
  if hit ~= nil then return hit or nil end

  if sugg_groups_n >= CACHE_MAX then sugg_groups, sugg_groups_n = {}, 0 end

  local hl = require("diffview.hl")
  -- "@keyword.function.lua" is rarely defined directly: walk the same
  -- fallback chain the TS highlighter uses.
  local names = { ("@%s.%s"):format(capture, lang) }
  local cur = "@" .. capture
  while cur do
    names[#names + 1] = cur
    cur = cur:match("^(.*)%.[^.]+$")
  end

  local fg = hl.get_fg(names)
  local bg = hl.get_bg("DiffviewCommentSuggestionAdd")
  if not (fg and bg) then
    sugg_groups[key] = false
    sugg_groups_n = sugg_groups_n + 1
    return
  end

  local group = "DiffviewCommentSugg_" .. key:gsub("[^%w]", "_")
  api.nvim_set_hl(0, group, { fg = fg, bg = bg })
  sugg_groups[key] = group
  sugg_groups_n = sugg_groups_n + 1
  return group
end

---Chunkify one display segment of a suggestion line, painting its spans.
---@param seg string Exact byte substring of the source line.
---@param off integer Byte offset of `seg` within its line.
---@param line_spans? { [1]: integer, [2]: integer, [3]: string }[]
---@param lang? string
---@return table[] chunks
local function suggestion_chunks(seg, off, line_spans, lang)
  local base = "DiffviewCommentSuggestionAdd"
  if not (line_spans and lang) or #seg == 0 or #seg > MAX_HL_LINE then
    return { { seg, base } }
  end

  -- Paint capture names per byte (capture order — later wins, matching the
  -- highlighter's override behavior), then compress runs into chunks.
  local paint = {}
  for _, sp in ipairs(line_spans) do
    local s = math.max(sp[1] - off, 0)
    local e = math.min((sp[2] == math.huge and math.huge or sp[2] - off), #seg)
    for b = s + 1, e do paint[b] = sp[3] end
  end

  local chunks = {}
  local run_start, run_capture = 1, paint[1]
  for b = 2, #seg + 1 do
    local cap = paint[b]
    if b == #seg + 1 or cap ~= run_capture then
      local group = run_capture and capture_hl(run_capture, lang) or nil
      chunks[#chunks + 1] = { seg:sub(run_start, b - 1), group or base }
      run_start, run_capture = b, cap
    end
  end
  return chunks
end

--#endregion

---Build the virt_lines chunks for one thread card:
---
---  ╭╴ eyal · 2h ago ─────────────────── ⊘ outdated ╶╮
---  │ Body text with `inline code` styled.           │
---  │ ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ │
---  │ 󰚩 claude · 1h ago                              │
---  │ ▷ Suggested change · replaces lines 12–14      │
---  │ + local x = 1                                  │
---  ╰╴t-1a2b3c ─────────────────────────── ↵ reply ╶╯
---
---The first comment's author + time live in the top border so the card stays
---compact; every line lands at exactly `width` cells.
---@param thread ReviewThread
---@param width integer
---@param outdated boolean
---@return table[][] virt_lines
local function build_box(thread, width, outdated)
  local border_hl = outdated and "DiffviewCommentBorderOutdated" or "DiffviewCommentBorder"
  local body_hl = outdated and "DiffviewCommentOutdated" or "DiffviewCommentBody"
  local inner = width - 4
  local lines = {}

  ---Pad a line's chunks to the card width and close it with the right rail.
  ---`pad_hl` lets block rows (suggestions) extend their tint to the rail.
  ---@param chunks table[]
  ---@param pad_hl? string
  ---@return table[]
  local function close_line(chunks, pad_hl)
    local pad = math.max(0, (width - 1) - chunk_width(chunks))
    if pad > 0 then chunks[#chunks + 1] = { string.rep(" ", pad), pad_hl or "DiffviewCommentCard" } end
    chunks[#chunks + 1] = { "│", border_hl }
    return chunks
  end

  ---A border row: `left` chunks, a `─` fill, then right-aligned `right`
  ---chunks before the closing corner. Right chunks are dropped one by one
  ---(rightmost kept longest) if the row would overflow.
  ---@param corners { [1]: string, [2]: string }
  ---@param left table[]
  ---@param right table[]
  ---@return table[]
  local function border_row(corners, left, right)
    local cw = vim.fn.strdisplaywidth(corners[1]) + vim.fn.strdisplaywidth(corners[2])
    while true do
      local fill = width - cw - chunk_width(left) - chunk_width(right)
      if fill >= 1 or (#left == 0 and #right == 0) then
        local row = { { corners[1], border_hl } }
        vim.list_extend(row, left)
        row[#row + 1] = { string.rep("─", math.max(0, fill)), border_hl }
        vim.list_extend(row, right)
        row[#row + 1] = { corners[2], border_hl }
        return row
      end
      if #right > 0 then table.remove(right, 1) else table.remove(left) end
    end
  end

  ---Author + relative time header chunks for one comment.
  ---@param comment ReviewComment
  ---@return table[]
  local function header_chunks(comment)
    return {
      { ("%s %s"):format(author_icon(comment.author), comment.author), author_hl(comment.author) },
      { (" · %s "):format(rel_ts(comment.ts)), "DiffviewCommentDim" },
    }
  end

  -- Top border: the first comment's identity, plus the outdated tag.
  local first = thread.comments[1]
  lines[#lines + 1] = border_row(
    { "╭╴", "╮" },
    first and header_chunks(first) or {},
    outdated and { { " ⊘ outdated ", "DiffviewCommentOutdated" } } or {}
  )

  for ci, comment in ipairs(thread.comments) do
    -- Later comments get a soft separator and their own header row.
    if ci > 1 then
      lines[#lines + 1] = close_line({
        { "│ ", border_hl },
        { string.rep("╌", inner), "DiffviewCommentSeparator" },
      })
      lines[#lines + 1] = close_line(vim.list_extend({ { "│ ", border_hl } }, header_chunks(comment)))
    end

    for _, raw in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
      for _, seg in ipairs(wrap(raw, inner)) do
        lines[#lines + 1] = close_line(vim.list_extend({ { "│ ", border_hl } }, inline_chunks(seg, body_hl)))
      end
    end

    if comment.suggestion and comment.suggestion.text then
      local rl = comment.suggestion.replace_lines
      local label = {
        { "│ ", border_hl },
        { "▷ Suggested change", "DiffviewCommentSuggestion" },
      }
      if rl then
        label[#label + 1] = { (" · replaces lines %d–%d"):format(rl[1] or 0, rl[2] or 0), "DiffviewCommentDim" }
      end
      lines[#lines + 1] = close_line(label)

      -- Code lines hard-slice at the card width (word-wrap helps prose, not
      -- code) — slices stay exact substrings, so span byte offsets hold.
      local lang = lang_for(thread.anchor and thread.anchor.path)
      local spans = lang and suggestion_spans(comment.suggestion.text, lang) or nil

      for li, raw in ipairs(vim.split(comment.suggestion.text, "\n", { plain = true })) do
        local segs = raw ~= "" and split_word(raw, inner - 2) or { "" }
        local off = 0
        for si, seg in ipairs(segs) do
          local chunks = {
            { "│ ", border_hl },
            { si == 1 and "+ " or "  ", "DiffviewCommentSuggestionAdd" },
          }
          vim.list_extend(chunks, suggestion_chunks(seg, off, spans and spans[li - 1], lang))
          lines[#lines + 1] = close_line(chunks, "DiffviewCommentSuggestionAdd")
          off = off + #seg
        end
      end
    end
  end

  -- Bottom border: thread id on the left, a single quiet hint on the right —
  -- the full keymap surface lives in the docs, not on every card.
  lines[#lines + 1] = border_row(
    { "╰╴", "╯" },
    { { thread.id .. " ", "DiffviewCommentDim" } },
    { { " ↵ reply ", "DiffviewCommentHint" } }
  )

  return lines
end

---@class PlacedThread
---@field thread ReviewThread
---@field row integer 1-indexed row in the target buffer
---@field outdated boolean

---Render the given threads into a buffer. Wipes and redraws the whole
---namespace — thread counts are small and this keeps state trivial.
---@param bufnr integer
---@param placed PlacedThread[]
function M.render(bufnr, placed)
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local width = 80
  local win = vim.fn.win_findbuf(bufnr)[1]
  if win then
    width = math.max(40, api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 1)
  end
  width = math.min(width, MAX_CARD_WIDTH)

  local max_row = api.nvim_buf_line_count(bufnr)

  for _, p in ipairs(placed) do
    local row = math.min(math.max(p.row, 1), max_row)
    local thread = p.thread

    local sign, sign_group
    if thread.status == "resolved" then
      sign, sign_group = SIGN_RESOLVED, "DiffviewCommentSignResolved"
    elseif thread.status == "applied" then
      sign, sign_group = SIGN_APPLIED, "DiffviewCommentSignApplied"
    else
      local last = thread.comments[#thread.comments]
      sign, sign_group = SIGN_OPEN, last and sign_hl(last.author) or "DiffviewCommentSignHuman"
    end

    api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      sign_text = sign,
      sign_hl_group = sign_group,
      priority = 60,
    })

    if thread.status == "open" then
      api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
        virt_lines = build_box(thread, width, p.outdated),
        virt_lines_above = false,
        priority = 60,
      })
    end
  end
end

---Rows of rendered thread signs in a buffer, sorted (for ]t/[t).
---@param bufnr integer
---@return integer[] rows 1-indexed
function M.thread_rows(bufnr)
  local marks = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local rows, seen = {}, {}
  for _, m in ipairs(marks) do
    local row = m[2] + 1
    if m[4].sign_text and not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)
  return rows
end

function M.clear(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

return M
