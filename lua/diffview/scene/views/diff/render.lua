local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local pl = utils.path

---Right-truncate `text` to `budget` display cells, ellipsis at the end.
---@param text string
---@param budget integer
---@return string
local function truncate_text(text, budget)
  if vim.fn.strdisplaywidth(text) <= budget then return text end
  if budget < 1 then return "" end
  local lo, hi = 0, vim.fn.strchars(text)
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) > budget - 1 then
      hi = mid - 1
    else
      lo = mid
    end
  end
  return vim.fn.strcharpart(text, 0, lo) .. "…"
end

---Render one file row as [ fixed left ][ flex name… ][ pinned right ]: the
---conflict marker, comment badge and stats are flush to the panel's right
---edge and always render in full — a long name truncates, never them.
---@param comp  RenderComponent
---@param show_path boolean
---@param depth integer|nil
---@param width integer Panel text width.
local function render_file(comp, show_path, depth, width)
  ---@type FileEntry
  local file = comp.context
  local conf = config.get_config()

  -- Fixed left region: status, tree indent, icon.
  local left = { { file.status .. " ", hl.get_git_hl(file.status) } }
  if depth then
    left[#left + 1] = { string.rep(" ", depth + 1) }
  end
  local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
  left[#left + 1] = { icon, icon_hl }

  -- Pinned right region: conflict marker, comment badge, stats.
  local right = {}

  if file.kind == "conflicting" and not (file.stats and file.stats.conflicts) then
    right[#right + 1] = { " !", "DiffviewFilePanelConflicts" }
  end

  do
    -- Open review-comment threads on this file (comments module is loaded
    -- lazily by the unified layout; don't force it here).
    local comments = package.loaded["diffview.comments"]
    if comments then
      local n = comments.count_for(file.adapter, file.path)
      if n > 0 then
        right[#right + 1] = { (" %s%d"):format(conf.comments.icon, n), "DiffviewCommentCount" }
      end
    end
  end

  if file.stats then
    if file.stats.additions then
      right[#right + 1] = { " " .. file.stats.additions, "DiffviewFilePanelInsertions" }
      right[#right + 1] = { ", " }
      right[#right + 1] = { tostring(file.stats.deletions), "DiffviewFilePanelDeletions" }
    elseif file.stats.conflicts then
      local has_conflicts = file.stats.conflicts > 0
      right[#right + 1] = {
        " " .. (has_conflicts and file.stats.conflicts or conf.signs.done),
        has_conflicts and "DiffviewFilePanelConflicts" or "DiffviewFilePanelInsertions",
      }
    end
  end

  local left_w, right_w = 0, 0
  for _, c in ipairs(left) do left_w = left_w + vim.fn.strdisplaywidth(c[1]) end
  for _, c in ipairs(right) do right_w = right_w + vim.fn.strdisplaywidth(c[1]) end

  -- Flex middle: basename (+ parent path in list mode). Keep at least a
  -- sliver of the name even when the row overflows.
  local flex = {
    { file.basename, file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName" },
  }
  if show_path then
    flex[#flex + 1] = { " " .. file.parent_path, "DiffviewFilePanelPath" }
  end
  local budget = math.max(width - left_w - right_w, 3)

  for _, c in ipairs(left) do comp:add_text(c[1], c[2]) end

  local used = 0
  for _, c in ipairs(flex) do
    local w = vim.fn.strdisplaywidth(c[1])
    if used + w <= budget then
      comp:add_text(c[1], c[2])
      used = used + w
    else
      local text = truncate_text(c[1], budget - used)
      if text ~= "" then
        comp:add_text(text, c[2])
        used = used + vim.fn.strdisplaywidth(text)
      end
      break
    end
  end

  local pad = width - left_w - used - right_w
  if pad > 0 then comp:add_text(string.rep(" ", pad)) end

  for _, c in ipairs(right) do comp:add_text(c[1], c[2]) end

  comp:ln()
end

---@param comp RenderComponent
---@param width integer
local function render_file_list(comp, width)
  for _, file_comp in ipairs(comp.components) do
    render_file(file_comp, true, nil, width)
  end
end

---@param ctx DirData
---@param tree_options TreeOptions
---@return string
local function get_dir_status_text(ctx, tree_options)
  local folder_statuses = tree_options.folder_statuses

  if folder_statuses == "always" or (folder_statuses == "only_folded" and ctx.collapsed) then
    return ctx.status
  end

  return " "
end

---@param depth integer
---@param comp RenderComponent
---@param width integer
local function render_file_tree_recurse(depth, comp, width)
  local conf = config.get_config()

  if comp.name == "file" then
    render_file(comp, false, depth, width)
    return
  end

  if comp.name ~= "directory" then return end

  -- Directory component structure:
  -- {
  --   name = "directory",
  --   context = <DirData>,
  --   { name = "dir_name" },
  --   { name = "items", ...<files> },
  -- }

  local dir = comp.components[1]
  local items = comp.components[2]
  local ctx = comp.context --[[@as DirData ]]

  dir:add_text(
    get_dir_status_text(ctx, conf.file_panel.tree_options) .. " ",
    hl.get_git_hl(ctx.status)
  )
  dir:add_text(string.rep(" ", depth))
  dir:add_text(ctx.collapsed and conf.signs.fold_closed or conf.signs.fold_open, "DiffviewNonText")

  if conf.use_icons then
    dir:add_text(
      " " .. (ctx.collapsed and conf.icons.folder_closed or conf.icons.folder_open) .. " ",
      "DiffviewFolderSign"
    )
  end

  dir:add_text(ctx.name, "DiffviewFolderName")
  dir:ln()

  if not ctx.collapsed then
    for _, item in ipairs(items.components) do
      render_file_tree_recurse(depth + 1, item, width)
    end
  end
end

---@param comp RenderComponent
---@param width integer
local function render_file_tree(comp, width)
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(0, c, width)
  end
end

---Render a "+N -M" line-change summary for a set of files, appended to a
---section title line. No-op when none of the files carry additions stats
---(e.g. the conflicts section).
---@param comp RenderComponent
---@param files FileEntry[]
local function render_stats_summary(comp, files)
  local additions, deletions = 0, 0
  local has_stats = false

  for _, file in ipairs(files) do
    if file.stats and file.stats.additions then
      has_stats = true
      additions = additions + file.stats.additions
      deletions = deletions + file.stats.deletions
    end
  end

  if not has_stats then return end

  comp:add_text("  ")
  comp:add_text("+" .. additions, "DiffviewFilePanelInsertions")
  comp:add_text(" ")
  comp:add_text("-" .. deletions, "DiffviewFilePanelDeletions")
end

---@param listing_style "list"|"tree"
---@param comp RenderComponent
---@param width integer
local function render_files(listing_style, comp, width)
  if listing_style == "list" then
    return render_file_list(comp, width)
  end
  render_file_tree(comp, width)
end

---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local conf = config.get_config()
  local width = panel:infer_width()

  -- infer_width() is the full window width, gutter included; the pinned
  -- right region must fit inside the visible TEXT columns (the panel has
  -- signcolumn="yes"), so subtract the decoration columns.
  local text_width = width - 3
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    text_width = vim.api.nvim_win_get_width(panel.winid)
      - vim.fn.getwininfo(panel.winid)[1].textoff - 1
  end

  local comp = panel.components.path.comp

  comp:add_line(
    pl:truncate(pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"), width - 6),
    "DiffviewFilePanelRootPath"
  )

  if conf.show_help_hints and panel.help_mapping then
    comp:add_text("Help: ", "DiffviewFilePanelPath")
    comp:add_line(panel.help_mapping, "DiffviewFilePanelCounter")
    comp:add_line()
  end

  if #panel.files.conflicting > 0 then
    comp = panel.components.conflicting.title.comp
    comp:add_text("Conflicts ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.conflicting .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    render_files(panel.listing_style, panel.components.conflicting.files.comp, text_width)
    panel.components.conflicting.margin.comp:add_line()
  end

  local has_other_files = #panel.files.conflicting > 0 or #panel.files.staged > 0

  -- Don't show the 'Changes' section if it's empty and we have other visible
  -- sections.
  if #panel.files.working > 0 or not has_other_files then
    comp = panel.components.working.title.comp
    comp:add_text("Changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.working .. ")", "DiffviewFilePanelCounter")
    render_stats_summary(comp, panel.files.working)
    comp:ln()

    render_files(panel.listing_style, panel.components.working.files.comp, text_width)
    panel.components.working.margin.comp:add_line()
  end

  if #panel.files.staged > 0 then
    comp = panel.components.staged.title.comp
    comp:add_text("Staged changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.staged .. ")", "DiffviewFilePanelCounter")
    render_stats_summary(comp, panel.files.staged)
    comp:ln()

    render_files(panel.listing_style, panel.components.staged.files.comp, text_width)
    panel.components.staged.margin.comp:add_line()
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    local extra_info = utils.vec_join({ panel.rev_pretty_name }, panel.path_args or {})

    comp = panel.components.info.title.comp
    comp:add_line("Showing changes for:", "DiffviewFilePanelTitle")

    comp = panel.components.info.entries.comp

    for _, arg in ipairs(extra_info) do
      local relpath = pl:relative(arg, panel.adapter.ctx.toplevel)
      if relpath == "" then relpath = "." end
      comp:add_line(pl:truncate(relpath, width - 5), "DiffviewFilePanelPath")
    end
  end
end
