local lazy = require("diffview.lazy")

local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api

---The merge tool's RESULT pane, drawn over the conflicted working-tree buffer:
---each half of a conflict washed in its side's hue (the winbar pills' colors),
---the marker lines dimmed and labelled with their side, and the "conflict N of
---M" the RESULT winbar shows. Extmarks only — the buffer is the user's real
---file and outlives the view, so `clear()` takes everything back off.
local M = {}

local ns = api.nvim_create_namespace("diffview_conflict_decor")

---The branch a merge side points at, from `%D` ("HEAD -> main, origin/main"):
---the first ref, without the `HEAD -> ` arrow. A detached HEAD lists a bare
---"HEAD" first, which names nothing; the ref after it does.
---@param ref_names? string
---@return string?
function M.branch(ref_names)
  if not ref_names or ref_names == "" then return nil end
  for _, ref in ipairs(vim.split(ref_names, ", ", { plain = true })) do
    ref = ref:gsub("^HEAD %-> ", "")
    if ref ~= "HEAD" then return ref end
  end
end

---The window showing `bufnr` as a diff in the current tabpage: RESULT.
---@param bufnr integer
---@return integer?
local function result_win(bufnr)
  local tab = api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if api.nvim_win_get_tabpage(win) == tab and vim.wo[win].diff then return win end
  end
end

---Highlight rows `first`..`last` (1-based, inclusive) out to the window edge.
---A char range with `hl_eol`, not `line_hl_group`: the diff's own line
---highlight wins over the latter whatever its priority.
local function band(bufnr, first, last, group)
  if first > last then return end
  api.nvim_buf_set_extmark(bufnr, ns, first - 1, 0, {
    end_row = last,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = 200,
  })
end

local function marker(bufnr, row, label, side)
  api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
    end_row = row,
    end_col = 0,
    hl_group = "DiffviewConflictMarker",
    hl_eol = true,
    priority = 201,
    virt_text = label and { { "  " .. label, "DiffviewConflictLabel" .. side } } or nil,
    virt_text_pos = "eol",
  })
end

---Repaint `bufnr`. RESULT maps DiffAdd to the bg-less DiffviewResultAdd so the
---conflict washes can show; the rows the diff still calls added that sit
---outside any conflict (an auto-merged addition) get DiffAdd back from here.
---@param bufnr integer
---@param ctx? vcs.MergeContext
function M.paint(bufnr, ctx)
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local conflicts = vcs_utils.parse_conflicts(lines)
  local ours_label = "ours"
  local branch = ctx and M.branch(ctx.ours.ref_names)
  if branch then ours_label = ours_label .. " · " .. branch end

  -- A block being resolved by hand is often half there (the `<<<<<<<` already
  -- deleted, the rest not yet), and parse_conflicts still reports it. Only
  -- the markers actually on their rows are drawn, and a half only when both
  -- of its ends are known.
  local function is(row, pat) return row and lines[row] and lines[row]:match(pat) end

  local in_conflict = {}
  for _, c in ipairs(conflicts) do
    for row = c.first, c.last do in_conflict[row] = true end

    if is(c.ours.first, "^<<<<<<< ") then
      marker(bufnr, c.ours.first, ours_label, "Ours")
      if c.ours.last then band(bufnr, c.ours.first + 1, c.ours.last, "DiffviewConflictOurs") end
    end
    if is(c.base.first, "^||||||| ") then
      marker(bufnr, c.base.first, "base", "Base")
      if c.base.last then band(bufnr, c.base.first + 1, c.base.last, "DiffviewConflictBase") end
    end
    local sep = is(c.theirs.first, "^=======$") and c.theirs.first
    local close = is(c.theirs.last, "^>>>>>>> ") and c.theirs.last
    if sep then marker(bufnr, sep, nil, "Theirs") end
    if sep and close then band(bufnr, sep + 1, close - 1, "DiffviewConflictTheirs") end
    if close then marker(bufnr, close, "theirs", "Theirs") end
  end

  local win = result_win(bufnr)
  if not win then return end
  local add_id = vim.fn.hlID("DiffAdd")
  api.nvim_win_call(win, function()
    for row = 1, #lines do
      if not in_conflict[row] and vim.fn.diff_hlID(row, 1) == add_id then
        band(bufnr, row, row, "DiffviewDiffAdd")
      end
    end
  end)
end

---@param bufnr integer
function M.clear(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local pos_cache = {} ---@type table<integer, { key: string, text: string }>

---RESULT's winbar position, evaluated by the winbar itself (`%{% %}`) in the
---window it draws: "conflict 2 of 3" inside one, "3 left" between them,
---"resolved" once none are. Cached on changedtick + cursor row: the winbar is
---redrawn far more often than either changes.
---@param win? integer Defaults to the window the winbar is drawing: a `%{}`
---item runs with that window current (`g:statusline_winid` is only set for
---`%!`), so the current window is the one.
---@return string
function M.position(win)
  win = win or api.nvim_get_current_win()
  if not (win and api.nvim_win_is_valid(win)) then return "" end
  local bufnr = api.nvim_win_get_buf(win)
  local row = api.nvim_win_get_cursor(win)[1]
  local key = api.nvim_buf_get_changedtick(bufnr) .. ":" .. row
  local hit = pos_cache[win]
  if hit and hit.key == key then return hit.text end

  local conflicts, cur, idx = vcs_utils.parse_conflicts(api.nvim_buf_get_lines(bufnr, 0, -1, false), win)
  local text
  if #conflicts == 0 then
    text = "%#DiffviewWinBarResult#resolved "
  elseif cur then
    text = ("%%#DiffviewWinBarDir#conflict %d of %d "):format(idx, #conflicts)
  else
    text = ("%%#DiffviewWinBarDir#%d left "):format(#conflicts)
  end
  pos_cache[win] = { key = key, text = text }
  return text
end

---The RESULT winbar segment that calls `position()`.
M.position_expr = "%=%{%v:lua.require'diffview.scene.conflict_decor'.position()%}"

---Keep `bufnr` painted while `is_live()` holds: repaint on edits, and redraw
---the winbar when the cursor crosses into or out of a conflict. Each autocmd
---drops itself once the view has let the buffer go.
---@param bufnr integer
---@param ctx_fn fun(): vcs.MergeContext?
---@param is_live fun(): boolean
function M.attach(bufnr, ctx_fn, is_live)
  M.paint(bufnr, ctx_fn())

  local group = api.nvim_create_augroup("diffview_conflict_decor_" .. bufnr, { clear = true })
  local last_pos
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if not is_live() then return true end
      -- Scheduled: the diff (and with it diff_hlID) catches up after the edit.
      vim.schedule(function() M.paint(bufnr, ctx_fn()) end)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if not is_live() then return true end
      local win = api.nvim_get_current_win()
      local pos = M.position(win)
      if pos ~= last_pos then
        last_pos = pos
        pcall(api.nvim__redraw, { win = win, winbar = true })
      end
    end,
  })
end

---@param bufnr integer
function M.detach(bufnr)
  pcall(api.nvim_del_augroup_by_name, "diffview_conflict_decor_" .. bufnr)
  M.clear(bufnr)
end

return M
