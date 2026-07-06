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

---@param author string
---@return string hl
local function author_hl(author)
  if author == "claude" or author == "ai" then
    return "DiffviewCommentAuthorAI"
  end
  return "DiffviewCommentAuthorHuman"
end

---Wrap `text` to `width` display cells. Returns at least one line.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  width = math.max(width, 16)
  if vim.fn.strdisplaywidth(text) <= width then return { text } end

  local out = {}
  local total = vim.fn.strchars(text)
  local pos = 0
  while pos < total do
    local lo, hi = 1, total - pos
    while lo < hi do
      local mid = math.ceil((lo + hi) / 2)
      if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, pos, mid)) > width then
        hi = mid - 1
      else
        lo = mid
      end
    end
    out[#out + 1] = vim.fn.strcharpart(text, pos, lo)
    pos = pos + lo
  end
  return out
end

---@param ts? string
---@return string
local function short_ts(ts)
  if type(ts) ~= "string" then return "" end
  return ts:gsub("T", " "):gsub(":%d%dZ$", "")
end

---Build the virt_lines chunks for one thread box.
---@param thread ReviewThread
---@param width integer
---@param outdated boolean
---@return table[][] virt_lines
local function build_box(thread, width, outdated)
  local border_hl = outdated and "DiffviewCommentOutdated" or "DiffviewCommentBorder"
  local body_hl = outdated and "DiffviewCommentOutdated" or "DiffviewCommentBody"
  local inner = width - 4
  local lines = {}

  local title = (" 🗨 %s%s "):format(thread.id, outdated and " (outdated)" or "")
  local fill = math.max(0, width - 2 - vim.fn.strdisplaywidth(title))
  lines[#lines + 1] = {
    { "┌─", border_hl },
    { title, outdated and "DiffviewCommentOutdated" or "DiffviewCommentTitle" },
    { string.rep("─", fill), border_hl },
  }

  for ci, comment in ipairs(thread.comments) do
    if ci > 1 then
      lines[#lines + 1] = { { "│", border_hl }, { " " .. string.rep("·", inner), border_hl } }
    end

    lines[#lines + 1] = {
      { "│ ", border_hl },
      { ("%s %s"):format(SIGN_OPEN, comment.author), author_hl(comment.author) },
      { ("  %s"):format(short_ts(comment.ts)), "DiffviewCommentDim" },
    }

    for _, raw in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
      for _, chunk in ipairs(wrap(raw, inner)) do
        lines[#lines + 1] = { { "│ ", border_hl }, { chunk, body_hl } }
      end
    end

    if comment.suggestion and comment.suggestion.text then
      lines[#lines + 1] = {
        { "│ ", border_hl },
        { "▷ suggestion", "DiffviewCommentSuggestion" },
        { ("  (lines %d–%d)"):format(
          comment.suggestion.replace_lines and comment.suggestion.replace_lines[1] or 0,
          comment.suggestion.replace_lines and comment.suggestion.replace_lines[2] or 0
        ), "DiffviewCommentDim" },
      }
      for _, raw in ipairs(vim.split(comment.suggestion.text, "\n", { plain = true })) do
        for _, chunk in ipairs(wrap(raw, inner - 2)) do
          lines[#lines + 1] = { { "│ + ", border_hl }, { chunk, "DiffviewCommentSuggestion" } }
        end
      end
    end
  end

  lines[#lines + 1] = { { "└" .. string.rep("─", math.max(0, width - 1)), border_hl } }
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

  local max_row = api.nvim_buf_line_count(bufnr)

  for _, p in ipairs(placed) do
    local row = math.min(math.max(p.row, 1), max_row)
    local thread = p.thread

    local sign, sign_hl
    if thread.status == "resolved" then
      sign, sign_hl = SIGN_RESOLVED, "DiffviewCommentDim"
    elseif thread.status == "applied" then
      sign, sign_hl = SIGN_APPLIED, "DiffviewCommentSignApplied"
    else
      local last = thread.comments[#thread.comments]
      sign, sign_hl = SIGN_OPEN, last and author_hl(last.author) or "DiffviewCommentAuthorHuman"
    end

    api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      sign_text = sign,
      sign_hl_group = sign_hl,
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
