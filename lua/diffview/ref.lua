-- Reference at cursor: the real file, side and source line numbers that the
-- cursor (or a row range) in a diff window stands for, plus those lines
-- marked +/-/space. Rendered rows in the unified layout are offset from their
-- source lines by every deleted line above them, so any consumer outside
-- diffview (copy-path keymaps, "send this to an agent" plugins) should go
-- through here instead of reading buffer names or raw row numbers.
--
-- The returned shape is a stable contract for external callers. Caveats:
-- - The inline layout keeps no hunks, so each call there diffs the whole file
--   (~5 ms for a 5000-line file). The unified layout reads its line map.
-- - For commit and file-history entries the line numbers are that revision's,
--   while `abs` / `rel` name the file in the working tree.

local lazy = require("diffview.lazy")

local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local unified = lazy.require("diffview.scene.layouts.unified_render") ---@module "diffview.scene.layouts.unified_render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

---@class DiffviewRefLine
---@field kind "+"|"-"|" "
---@field text string
---@field lnum integer Old-file line for "-", new-file line otherwise.

---@class DiffviewRef
---@field abs string Absolute path (built from the repo root, not cwd).
---@field rel string Repo-relative path.
---@field side "a"|"b" "a" only when every referenced line is a deletion.
---@field first integer First source line on `side`.
---@field last integer Last source line on `side`.
---@field lines DiffviewRefLine[]

local KIND = { ctx = " ", add = "+", del = "-" }

---@param line_map UnifiedLineInfo[]
---@param text string[] rendered lines; `text[r - offset]` is row r
---@param r1 integer
---@param r2 integer
---@param offset integer
---@return DiffviewRefLine[]
local function collect(line_map, text, r1, r2, offset)
  local lines = {}
  for r = r1, r2 do
    local info = line_map[r]
    if info then
      lines[#lines + 1] = {
        kind = KIND[info.kind],
        text = text[r - offset] or "",
        lnum = info.kind == "del" and info.old_lnum or info.new_lnum,
      }
    end
  end
  return lines
end

---@param opts? { range?: { [1]: integer, [2]: integer } } buffer rows, 1-based, inclusive
---@return DiffviewRef?
function M.at_cursor(opts)
  -- No view has ever been opened: answer without loading diffview's core.
  if not package.loaded["diffview.lib"] then return end

  local view = lib.get_current_view()
  local entry = view and view.cur_entry
  local layout = view and view.cur_layout
  if not (entry and layout) then return end

  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_get_current_buf()

  -- Only the layout's own diff windows: panels, help and foreign buffers in
  -- the view's tab reference no line.
  local file
  for _, win in ipairs(layout.windows) do
    if win.id == winid and win.file and win.file.bufnr == bufnr then
      file = win.file
      break
    end
  end
  if not file then return end

  local s, e
  if opts and opts.range then
    s, e = opts.range[1], opts.range[2]
  else
    s = api.nvim_win_get_cursor(winid)[1]
    e = s
  end
  if s > e then s, e = e, s end
  s = math.max(1, s)
  e = math.min(e, api.nvim_buf_line_count(bufnr))
  if s > e then return end

  local lines
  if layout.name == "diff1_unified" then
    -- Same recovery as jump_to_edit: the render state can be dropped while
    -- the buffer stays on screen.
    if not unified.state[bufnr] then
      pcall(function() return layout:_render() end)
    end
    local st = unified.state[bufnr]
    if not st then return end
    lines = collect(st.line_map, api.nvim_buf_get_lines(bufnr, s - 1, e, false), s, e, s - 1)
  elseif layout.name == "diff1_inline" then
    -- The window shows the new file; deletions are virtual lines. Map through
    -- the same builder the unified layout uses so a range that spans a
    -- deletion carries its "-" lines too.
    local a = layout.a.file
    local old = {}
    if a and a:is_valid() and not a.nulled then
      old = api.nvim_buf_get_lines(a.bufnr, 0, -1, false)
    end
    local new = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text, st = unified.build(old, new)
    local r1, r2 = st.row_of_new[s], st.row_of_new[e]
    if not (r1 and r2) then return end
    lines = collect(st.line_map, text, r1, r2, 0)
  elseif file.symbol == "a" or file.symbol == "b" then
    -- Merge-tool windows (ours / working copy): rows are source lines.
    lines = {}
    for i, text in ipairs(api.nvim_buf_get_lines(bufnr, s - 1, e, false)) do
      lines[i] = { kind = " ", text = text, lnum = s + i - 1 }
    end
  else
    return
  end

  if #lines == 0 then return end

  -- A merge-tool "a" window is the old side outright; in a diff, the new side
  -- unless every referenced line is a deletion.
  local side = "a"
  if file.symbol ~= "a" then
    for _, l in ipairs(lines) do
      if l.kind ~= "-" then
        side = "b"
        break
      end
    end
  end

  -- first/last count only lines that exist on `side`: deletions interleaved
  -- in a new-side range carry old-side numbers.
  local first, last
  for _, l in ipairs(lines) do
    if side == "a" or l.kind ~= "-" then
      first = first or l.lnum
      last = l.lnum
    end
  end

  local rel = (side == "a" and entry.oldpath) or entry.path
  return {
    abs = pl:absolute(rel, entry.adapter.ctx.toplevel),
    rel = rel,
    side = side,
    first = first,
    last = last,
    lines = lines,
  }
end

return M
