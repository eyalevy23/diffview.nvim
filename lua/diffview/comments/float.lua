-- Full-thread reading float. Inline cards cap their height because the cursor
-- can never scroll *into* virt_lines — a card taller than the screen is
-- unreadable in place. This float is the reading surface: a real markdown
-- buffer in a real window, so j/k, <C-d>, search, and yank all just work.
-- Thread actions route back through the anchor line in the diff buffer, so
-- reply/apply/resolve reuse the exact cursor-based flows the card uses.

local lazy = require("diffview.lazy")

local comments = lazy.require("diffview.comments") ---@module "diffview.comments"

local api = vim.api

local M = {}

---@class CommentFloatState
---@field win integer
---@field buf integer
---@field thread_id string
---@field store_path string
---@field src_win integer The diff window the float was opened from.
local state = nil ---@type CommentFloatState?

---Markdown lines for a whole thread — also the Telescope previewer content,
---so the picker and the float always read the same.
---@param thread ReviewThread
---@return string[]
function M.lines(thread)
  local lines = {
    ("# %s:%d  [%s]"):format(thread.anchor.path, thread.anchor.line, thread.status),
    "",
  }

  -- Fence suggestions with the anchored file's filetype so markdown injection
  -- highlights them as code.
  local ft = thread.anchor.path
      and vim.filetype.match({ filename = thread.anchor.path }) or nil

  for ci, c in ipairs(thread.comments) do
    if ci > 1 then lines[#lines + 1] = "---" end
    lines[#lines + 1] = ("**%s** · %s"):format(c.author, c.ts or "")
    lines[#lines + 1] = ""
    for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
      lines[#lines + 1] = l
    end
    if c.suggestion and c.suggestion.text then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Suggested change:"
      lines[#lines + 1] = "```" .. (ft or "")
      for _, l in ipairs(vim.split(c.suggestion.text, "\n", { plain = true })) do
        lines[#lines + 1] = l
      end
      lines[#lines + 1] = "```"
    end
    lines[#lines + 1] = ""
  end
  return lines
end

---@param buf integer
---@param thread ReviewThread
local function render_into(buf, thread)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(thread))
  vim.bo[buf].modifiable = false
end

function M.close()
  if state and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  state = nil
end

---@param thread_id string
---@return boolean
function M.is_open_for(thread_id)
  return state ~= nil
    and state.thread_id == thread_id
    and api.nvim_win_is_valid(state.win)
end

---Close the float, refocus the diff window (the cursor there never left the
---thread's anchor line), and run a cursor-based comment action.
---@param fn fun()
local function back_to_source(fn)
  local src = state and state.src_win
  M.close()
  if src and api.nvim_win_is_valid(src) then
    api.nvim_set_current_win(src)
  end
  fn()
end

---Open (focused) the reading float for a thread.
---@param thread ReviewThread
---@param opts { store_path: string }
function M.open(thread, opts)
  M.close()

  local src_win = api.nvim_get_current_win()

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  render_into(buf, thread)

  -- Size to the content: wide enough to read prose comfortably, tall enough
  -- to avoid needless scrolling, never past ~3/4 of the screen.
  local width = math.min(100, math.max(60, math.floor(vim.o.columns * 0.7)))
  width = math.min(width, vim.o.columns - 4)
  local rows = 0
  for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.max(3, math.min(rows, math.floor(vim.o.lines * 0.75)))

  local title = thread.anchor.path
  if #title > 50 then title = "…" .. title:sub(-49) end

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" %s:%d · %s "):format(title, thread.anchor.line, thread.id),
    title_pos = "left",
  }
  if vim.fn.has("nvim-0.10") == 1 then
    win_opts.footer = { { " ↵ reply · e edit · a apply · s resolve · q close ", "DiffviewCommentHint" } }
    win_opts.footer_pos = "right"
  end

  local win = api.nvim_open_win(buf, true, win_opts)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc"
  vim.wo[win].winhighlight = "FloatBorder:DiffviewCommentBorder,FloatTitle:DiffviewCommentDim"

  state = {
    win = win,
    buf = buf,
    thread_id = thread.id,
    store_path = opts.store_path,
    src_win = src_win,
  }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", M.close, "Close thread float")
  map("<Esc>", M.close, "Close thread float")
  map("E", M.close, "Close thread float")
  map("<CR>", function() back_to_source(function() comments.comment_open() end) end, "Reply to thread")
  map("r", function() back_to_source(function() comments.comment_open() end) end, "Reply to thread")
  map("e", function() back_to_source(function() comments.comment_edit() end) end, "Edit your comment")
  map("a", function() back_to_source(function() comments.comment_apply() end) end, "Apply suggestion")
  map("s", function() back_to_source(function() comments.comment_resolve() end) end, "Resolve toggle")

  -- The float dies with its context: leaving the buffer or its window being
  -- closed by other means must not leave stale state behind.
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state and state.win == win then state = nil end
    end,
  })
end

---Repaint (or drop) the float after the review doc changed under it — e.g.
---the AI replied while the thread was open. Called from comments.refresh_all.
---@param docs table<string, ReviewDoc>
function M.refresh(docs)
  if not state then return end
  if not api.nvim_win_is_valid(state.win) then
    state = nil
    return
  end

  local doc = docs[state.store_path]
  if not doc then return end

  for _, t in ipairs(doc.threads) do
    if t.id == state.thread_id then
      render_into(state.buf, t)
      return
    end
  end
  M.close() -- thread was deleted under us
end

return M
