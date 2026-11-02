local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local logger = DiffviewGlobal.logger

local M = {}

---@type View[]
M.views = {}

---@param rev Rev
local function rev_key(rev)
  return ("%s:%s:%s:%s"):format(rev.type, rev.commit or "", rev.stage or "", tostring(rev.track_head))
end

---What makes two diff views the same diff: the repo, the resolved revs (not
---the typed args, so `HEAD~1` after a new commit is a new diff), the paths and
---the options (`--untracked-files` etc.), but not `selected_file`: that only
---says where to land.
---@param toplevel string
---@param left Rev
---@param right Rev
---@param path_args? string[]
---@param options? DiffViewOptions
local function diff_key(toplevel, left, right, path_args, options)
  local opts = vim.deepcopy(options or {})
  opts.selected_file = nil
  return table.concat({
    toplevel, rev_key(left), rev_key(right), vim.inspect(opts), unpack(path_args or {}),
  }, "\0")
end

---An open view whose `key` matches.
---@param key string
---@return View?
local function find_by_key(key)
  for _, view in ipairs(M.views) do
    if not view.closing:check() and api.nvim_tabpage_is_valid(view.tabpage or -1) then
      local vkey = view.open_key
      if not vkey and view:instanceof(DiffView.__get()) then
        ---@cast view DiffView
        vkey = diff_key(view.adapter.ctx.toplevel, view.left, view.right, view.path_args, view.options)
      end
      if vkey == key then return view end
    end
  end
end

---A new view replaces the open views of its own kind (`single_view`): a diff
---closes the other diffs, a file history the other histories; the two kinds
---never close each other. A view showing a merge in progress (a conflicts tab)
---survives that; with `conflicts` set, only the other conflicts tabs close
---instead, so there is one at a time. `keep`'s tab page stays, so no close
---here ever leaves the empty placeholder tab behind.
---@param keep View
---@param conflicts? boolean
function M.close_others(keep, conflicts)
  for _, view in ipairs(vim.list_slice(M.views)) do
    if view ~= keep
      and view.class == keep.class
      and not view.closing:check()
      and (view.merge_ctx ~= nil) == (conflicts == true)
    then
      view:close()
      M.dispose_view(view)
    end
  end
end

---Returns the view and `true` when that diff is open already: the caller
---switches to it instead of opening a second copy.
---@param view_opts? { title?: string } `title`: a fixed tab title (see View:set_title).
---@return View?
---@return boolean? existing
function M.diffview_open(args, view_opts)
  local default_args = config.get_config().default_args.DiffviewOpen
  local argo = arg_parser.parse(utils.flatten({ default_args, args }))
  local rev_arg = argo.args[1]

  logger:info("[command call] :DiffviewOpen " .. table.concat(utils.flatten({
    default_args,
    args,
  }), " "))

  local err, adapter = vcs.get_adapter({
    cmd_ctx = {
      path_args = argo.post_args,
      cpath = argo:get_flag("C", { no_empty = true, expand = true }),
    },
  })

  if err then
    utils.err(err)
    return
  end

  ---@cast adapter -?

  local opts = adapter:diffview_options(argo)

  if opts == nil then
    return
  end

  local key = diff_key(adapter.ctx.toplevel, opts.left, opts.right, adapter.ctx.path_args, opts.options)
  local existing = config.get_config().single_view and find_by_key(key)
  if existing then
    return existing, true
  end

  local v = DiffView({
    adapter = adapter,
    rev_arg = rev_arg,
    title = view_opts and view_opts.title,
    path_args = adapter.ctx.path_args,
    left = opts.left,
    right = opts.right,
    options = opts.options,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger:debug("DiffView instantiation successful!")

  return v
end

---Returns the view and `true` when that history is open already.
---@param range? { [1]: integer, [2]: integer }
---@param args string[]
---@return View?
---@return boolean? existing
function M.file_history(range, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(utils.flatten({ default_args, args }))

  logger:info("[command call] :DiffviewFileHistory " .. table.concat(utils.flatten({
    default_args,
    args,
  }), " "))

  local err, adapter = vcs.get_adapter({
    cmd_ctx = {
      path_args = argo.args,
      cpath = argo:get_flag("C", { no_empty = true, expand = true }),
    },
  })

  if err then
    utils.err(err)
    return
  end

  ---@cast adapter -?

  local log_options = adapter:file_history_options(range, adapter.ctx.path_args, argo)

  if log_options == nil then
    return
  end

  local key = adapter.ctx.toplevel .. "\0" .. vim.inspect(log_options)
  local existing = config.get_config().single_view and find_by_key(key)
  if existing then
    return existing, true
  end

  local v = FileHistoryView({
    adapter = adapter,
    log_options = log_options,
  })

  if not v:is_valid() then
    return
  end

  v.open_key = key

  table.insert(M.views, v)
  logger:debug("FileHistoryView instantiation successful!")

  return v
end

---@param view View
function M.add_view(view)
  table.insert(M.views, view)
end

---@param view View
function M.dispose_view(view)
  for j, v in ipairs(M.views) do
    if v == view then
      table.remove(M.views, j)
      return
    end
  end
end

---Close and dispose of views that have no tabpage.
function M.dispose_stray_views()
  local tabpage_map = {}
  for _, id in ipairs(api.nvim_list_tabpages()) do
    tabpage_map[id] = true
  end

  local dispose = {}
  for _, view in ipairs(M.views) do
    if not tabpage_map[view.tabpage] then
      -- Need to schedule here because the tabnr's don't update fast enough.
      vim.schedule(function()
        view:close()
      end)
      table.insert(dispose, view)
    end
  end

  for _, view in ipairs(dispose) do
    M.dispose_view(view)
  end
end

---Get the currently open Diffview.
---@return View?
function M.get_current_view()
  local tabpage = api.nvim_get_current_tabpage()
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end

  return nil
end

---Get the first tabpage that is not a view. Tries the previous tabpage first.
---If there are no non-view tabpages: returns nil.
---@return number|nil
function M.get_prev_non_view_tabpage()
  local tabs = api.nvim_list_tabpages()
  if #tabs > 1 then
    local seen = {}
    for _, view in ipairs(M.views) do
      seen[view.tabpage] = true
    end

    local prev_tab = utils.tabnr_to_id(vim.fn.tabpagenr("#")) or -1
    if api.nvim_tabpage_is_valid(prev_tab) and not seen[prev_tab] then
      return prev_tab
    else
      for _, id in ipairs(tabs) do
        if not seen[id] then
          return id
        end
      end
    end
  end
end

---@param bufnr integer
---@param ignore? vcs.File[]
---@return boolean
function M.is_buf_in_use(bufnr, ignore)
  local ignore_map = ignore and utils.vec_slice(ignore) or {}
  utils.add_reverse_lookup(ignore_map)

  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView

      for _, file in ipairs(view.cur_entry and view.cur_entry.layout:files() or {}) do
        if file:is_valid() and file.bufnr == bufnr then
          if not ignore_map[file] then
            return true
          end
        end
      end
    end
  end

  return false
end

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      if view.panel:buf_loaded() then
        view.panel:render()
        view.panel:redraw()
      end
    end
  end
end

return M
