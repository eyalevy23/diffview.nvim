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
-- Continuation rows of a range thread: a thin rail tying the lines together.
local SIGN_RANGE = "┃"

---Rows of the threads rendered per buffer (for ]t/[t), in render order.
---@type table<integer, integer[]>
local rendered_rows = {}

-- Cards never grow past this, no matter how wide the window is — full-bleed
-- comment boxes on an ultrawide read worse than a bounded card.
local MAX_CARD_WIDTH = 100

local is_ai = require("diffview.comments.store").is_ai

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
---the first line. Returns at least one line.
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

---Build the virt_lines chunks for one thread card:
---
---  ╭╴ eyal · 2h ago ─────────────────── ⊘ outdated ╶╮
---  │ Body text with `inline code` styled.           │
---  │ ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ │
---  │ 󰚩 claude · 1h ago                              │
---  │ Reply text.                                    │
---  ╰╴t-1a2b3c ─────────────────────────── ↵ reply ╶╯
---
---The first comment's author + time live in the top border so the card stays
---compact; every line lands at exactly `width` cells.
---
---Long threads truncate at `max_rows` total rows with a "⌄ N more lines ·
---E to read" row — the cursor can never scroll *into* virt_lines, so a card
---taller than the screen is unreadable inline; the full conversation lives in
---the comment_read float. The build stops at the cap: hidden lines are never
---wrapped or highlighted.
---@param thread ReviewThread
---@param width integer
---@param outdated boolean
---@param max_rows integer|false|nil Cap on total card rows, borders included.
---@param span? { [1]: integer, [2]: integer } Source lines of a range thread.
---@return table[][] virt_lines
local function build_box(thread, width, outdated, max_rows, span)
  local border_hl = outdated and "DiffviewCommentBorderOutdated" or "DiffviewCommentBorder"
  local body_hl = outdated and "DiffviewCommentOutdated" or "DiffviewCommentBody"
  local inner = width - 4
  local lines = {}

  -- `budget` is how many rows may precede the bottom border. `raw_total` /
  -- `raw_shown` count source lines (not wrapped rows), so the tail row can say
  -- how much is hidden without building what it skips.
  local budget = max_rows and (math.max(max_rows, 8) - 1) or math.huge
  local truncated = false
  local raw_total, raw_shown = 0, 0
  if budget ~= math.huge then
    for _, c in ipairs(thread.comments) do
      local _, n = (c.body or ""):gsub("\n", "")
      raw_total = raw_total + n + 1
    end
  end

  ---Pad a line's chunks to the card width and close it with the right rail.
  ---@param chunks table[]
  ---@return table[]
  local function close_line(chunks)
    local pad = math.max(0, (width - 1) - chunk_width(chunks))
    if pad > 0 then chunks[#chunks + 1] = { string.rep(" ", pad), "DiffviewCommentCard" } end
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
      { (" · %s%s "):format(rel_ts(comment.ts), comment.edited_at and " · edited" or ""), "DiffviewCommentDim" },
    }
  end

  -- Top border: the first comment's identity, plus the range and outdated
  -- tags (the outdated one is kept longest when the row is tight).
  local first = thread.comments[1]
  local tags = {}
  if span then
    tags[#tags + 1] = { (" lines %d–%d "):format(span[1], span[2]), "DiffviewCommentDim" }
  end
  if outdated then
    tags[#tags + 1] = { " ⊘ outdated ", "DiffviewCommentOutdated" }
  end
  lines[#lines + 1] = border_row({ "╭╴", "╮" }, first and header_chunks(first) or {}, tags)

  for ci, comment in ipairs(thread.comments) do
    -- Later comments get a soft separator and their own header row.
    if ci > 1 then
      if #lines + 2 > budget then truncated = true break end
      lines[#lines + 1] = close_line({
        { "│ ", border_hl },
        { string.rep("╌", inner), "DiffviewCommentSeparator" },
      })
      lines[#lines + 1] = close_line(vim.list_extend({ { "│ ", border_hl } }, header_chunks(comment)))
    end

    for _, raw in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
      for _, seg in ipairs(wrap(raw, inner)) do
        if #lines >= budget then truncated = true break end
        lines[#lines + 1] = close_line(vim.list_extend({ { "│ ", border_hl } }, inline_chunks(seg, body_hl)))
      end
      if truncated then break end
      raw_shown = raw_shown + 1
    end
    if truncated then break end
  end

  -- Tail row: replace the last content row so the whole card (borders
  -- included) never exceeds max_rows, and point at the reading surface.
  if truncated then
    while #lines > budget - 1 do table.remove(lines) end
    local hidden = math.max(raw_total - raw_shown, 1)
    lines[#lines + 1] = close_line({
      { "│ ", border_hl },
      { "⌄ ", "DiffviewCommentHint" },
      { ("%d more line%s"):format(hidden, hidden == 1 and "" or "s"), "DiffviewCommentDim" },
      { " · E to read", "DiffviewCommentHint" },
    })
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
---@field row integer 1-indexed row in the target buffer (first line)
---@field end_row integer Row of the last line (== row for one-line threads)
---@field rows integer[] Rows of the anchored side's lines, ascending
---@field line integer Resolved first source line
---@field end_line integer Resolved last source line
---@field outdated boolean

---Render the given threads into a buffer. Wipes and redraws the whole
---namespace — thread counts are small and this keeps state trivial.
---@param bufnr integer
---@param placed PlacedThread[]
function M.render(bufnr, placed)
  if not api.nvim_buf_is_valid(bufnr) then
    rendered_rows[bufnr] = nil
    return
  end
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local width = 80
  local win = vim.fn.win_findbuf(bufnr)[1]
  if win then
    width = math.max(40, api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 1)
  end
  width = math.min(width, MAX_CARD_WIDTH)

  local conf = require("diffview.config").get_config().comments or {}
  local max_rows = conf.max_card_height
  if max_rows == nil then max_rows = 16 end

  local max_row = api.nvim_buf_line_count(bufnr)
  local function clamp(r) return math.min(math.max(r, 1), max_row) end
  local rows = {}
  rendered_rows[bufnr] = rows

  for _, p in ipairs(placed) do
    local row = clamp(p.row)
    local end_row = clamp(p.end_row or p.row)
    local thread = p.thread
    rows[#rows + 1] = row

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

    for i = 2, #(p.rows or {}) do
      api.nvim_buf_set_extmark(bufnr, ns, clamp(p.rows[i]) - 1, 0, {
        sign_text = SIGN_RANGE,
        sign_hl_group = sign_group,
        priority = 59,
      })
    end

    if thread.status == "open" then
      local span = (p.end_line and p.end_line > p.line) and { p.line, p.end_line } or nil
      api.nvim_buf_set_extmark(bufnr, ns, end_row - 1, 0, {
        virt_lines = build_box(thread, width, p.outdated, max_rows, span),
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
  local rows, seen = {}, {}
  for _, row in ipairs(rendered_rows[bufnr] or {}) do
    if not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)
  return rows
end

function M.clear(bufnr)
  rendered_rows[bufnr] = nil
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

return M
