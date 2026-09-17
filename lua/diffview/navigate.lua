-- Landing helpers shared by the pickers and the peek float: open (or switch
-- to) a diff view and put the cursor on a specific source line of a file,
-- translated to the rendered row of the unified layout.

local async = require("diffview.async")
local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local unified = lazy.require("diffview.scene.layouts.unified_render") ---@module "diffview.scene.layouts.unified_render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

---Open `entry` in the view and (optionally) land the cursor on a source line.
---Awaits the file switch so the landing survives the first-open cursor reset.
---@param view DiffView|FileHistoryView
---@param entry FileEntry
---@param side? "a"|"b"
---@param lnum? integer Source line on `side`.
M.goto_entry = async.void(function(view, entry, side, lnum)
  if view:instanceof(DiffView.__get()) then
    ---@cast view DiffView
    await(view:set_file(entry, true, true))
  else
    ---@cast view FileHistoryView
    await(view:set_file(entry, true))
  end

  if not (side and lnum) then return end

  local main = view.cur_layout:get_main_win()
  if not (main and main:is_valid()) then return end

  local buf = api.nvim_win_get_buf(main.id)
  local row = unified.row_for(buf, side, lnum)

  if not row then
    -- Not a unified buffer (other layout): the raw source line is the best
    -- we can do; deleted lines only exist on side a.
    row = side == "b" and lnum or nil
  end

  if row then
    api.nvim_set_current_win(main.id)
    utils.set_cursor(main.id, row, 0)
    api.nvim_win_call(main.id, function() pcall(vim.cmd, "normal! zvzz") end)
  end
end)

---@param view DiffView
---@param abs_path string
---@param side? "a"|"b"
---@param lnum? integer
local function land(view, abs_path, side, lnum)
  local rel = pl:relative(abs_path, view.adapter.ctx.toplevel)

  for _, entry in view.files:iter() do
    if entry.path == rel then
      M.goto_entry(view, entry, side, lnum)
      return
    end
  end

  utils.info(("[diffview] '%s' is not part of this diff."):format(rel))
end

---An open diff view for the same rev arg whose repo contains `abs_path`.
---@param rev_arg? string
---@param abs_path string
---@return DiffView?
function M.find_view(rev_arg, abs_path)
  for _, view in ipairs(lib.views) do
    if view:instanceof(DiffView.__get()) then
      ---@cast view DiffView
      local top = view.adapter.ctx.toplevel
      if (view.rev_arg or "") == (rev_arg or "")
        and abs_path:sub(1, #top) == top
        and api.nvim_tabpage_is_valid(view.tabpage)
      then
        return view
      end
    end
  end
end

---Switch to the diff view for `args` (opening one if needed) and land on
---`abs_path` at `lnum`. This is the peek float's escalation and the reverse
---of jump-to-edit: from the real file straight back into the diff.
---@param args string[] `:DiffviewOpen` args (`{}` for the uncommitted view).
---@param abs_path string
---@param side? "a"|"b"
---@param lnum? integer
function M.open_at(args, abs_path, side, lnum)
  local view = M.find_view(args[1], abs_path)

  if view then
    api.nvim_set_current_tabpage(view.tabpage)
    land(view, abs_path, side, lnum)
    return
  end

  view = lib.diffview_open(args)
  if not view then return end
  view:open()

  -- The file list arrives asynchronously, with the first `files_updated`.
  view.emitter:once("files_updated", vim.schedule_wrap(function()
    if vim.tbl_contains(lib.views, view) then
      land(view, abs_path, side, lnum)
    end
  end))
end

---Run `open` (which opens a view, possibly after async work such as the
---branch diff's merge-base), then `cb` once that view's file list is in: on
---its first `files_updated`, with no polling. `cb` never runs when no view
---opens (a bad rev, not a repo).
---@param open fun()
---@param cb fun()
function M.when_files_ready(open, cb)
  local requested = vim.uv.now()
  DiffviewGlobal.emitter:once("view_opened", function(_, view)
    -- A failed open never emits; don't let a view opened much later by
    -- something else fire this stale request.
    if vim.uv.now() - requested > 10000 then return end
    view.emitter:once("files_updated", vim.schedule_wrap(cb))
  end)
  open()
end

return M
