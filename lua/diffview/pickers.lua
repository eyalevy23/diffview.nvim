-- Diff-scoped fuzzy finders. On a 60-file agentic diff, paging through the
-- file panel doesn't scale — these let you jump straight to a file, or to a
-- changed LINE anywhere in the review, by typing a few characters.
--
--   pick_file()  — fuzzy-find among the files of the current view, with the
--                  file's patch as the preview.
--   pick_line()  — fuzzy-find across every added/deleted line of the whole
--                  view ("where did the agent touch `retry_policy`?"), landing
--                  on the exact rendered row in the unified diff.
--
-- Telescope when available (fzf-native if the user loaded it); vim.ui.select
-- otherwise so both work in a bare config. Loaded lazily from actions so
-- Telescope never loads until the first pick.

local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local navigate = lazy.require("diffview.navigate") ---@module "diffview.navigate"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

--#region view helpers

---The view to pick in. With `opts.open`, opens a diffview first (and retries
---the picker once it is ready) so a global keymap can be a one-liner.
---@param opts? { open?: string|string[] }
---@param retry fun()
---@return DiffView|FileHistoryView?
local function current_view(opts, retry)
  local view = lib.get_current_view()
  if view and (view:instanceof(DiffView.__get()) or view:instanceof(FileHistoryView.__get())) then
    return view --[[@as DiffView|FileHistoryView ]]
  end

  if not (opts and opts.open) then
    utils.err("[diffview] Open a diffview first.")
    return
  end

  local args = type(opts.open) == "table" and opts.open or { opts.open }
  require("diffview").open(args --[[@as string[] ]])

  local tries = 0
  local function poll()
    local v = lib.get_current_view()
    if v and v.ready and (v.files == nil or v.files:len() > 0 or v.initialized) then
      retry()
    elseif tries < 50 then
      tries = tries + 1
      vim.defer_fn(poll, 100)
    end
  end
  vim.defer_fn(poll, 100)
end

---All file entries of a view, in panel order.
---@param view DiffView|FileHistoryView
---@return FileEntry[]
local function view_files(view)
  if view:instanceof(DiffView.__get()) then
    ---@cast view DiffView
    return view.panel:ordered_file_list()
  end
  ---@cast view FileHistoryView
  return view.panel:list_files()
end

local goto_entry = function(...) return navigate.goto_entry(...) end

--#endregion

--#region git plumbing

---`git diff` rev arguments for one entry, oriented so that `+` is the right
---side of the view. Untracked files (no rev to diff against) return nil.
---@param entry FileEntry
---@return string[]?
local function entry_diff_args(entry)
  if entry.status == "?" then return end
  local a, b = entry.revs.a, entry.revs.b
  if not (a and b) then return end

  local ok, args = pcall(function() return entry.adapter:rev_to_args(a, b) end)
  if not ok then return end

  if a.type == RevType.LOCAL then
    -- rev_to_args flips the direction for a LOCAL left side.
    table.insert(args, 1, "-R")
  end
  return args
end

---Run `git diff` asynchronously in the repo top-level.
---@param adapter VCSAdapter
---@param args string[]
---@param cb fun(lines: string[])
local function git_diff(adapter, args, cb)
  local cmd = utils.vec_join(
    adapter:get_command(),
    "-c", "core.quotePath=false",
    "diff", "--no-color", "--no-ext-diff", "-M",
    args
  )
  vim.system(cmd, { cwd = adapter.ctx.toplevel, text = true }, function(out)
    local lines = {}
    if out.code == 0 and out.stdout then
      lines = vim.split(out.stdout, "\n", { plain = true })
      if lines[#lines] == "" then lines[#lines] = nil end
    end
    vim.schedule(function() cb(lines) end)
  end)
end

---Synthesize a patch for an untracked file (git diff shows nothing for it).
---@param entry FileEntry
---@return string[]
local function untracked_patch(entry)
  local ok, content = pcall(vim.fn.readfile, entry.absolute_path)
  if not ok then content = {} end
  local out = {
    ("diff --git a/%s b/%s"):format(entry.path, entry.path),
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/" .. entry.path,
    ("@@ -0,0 +1,%d @@"):format(#content),
  }
  for _, l in ipairs(content) do out[#out + 1] = "+" .. l end
  return out
end

---Patch text for a single entry, as shown by the file previewer.
---@param entry FileEntry
---@param cb fun(lines: string[])
local function entry_patch(entry, cb)
  local args = entry_diff_args(entry)
  if not args then
    return cb(untracked_patch(entry))
  end
  local paths = { "--", entry.path }
  if entry.oldpath and entry.oldpath ~= entry.path then
    paths[#paths + 1] = entry.oldpath
  end
  git_diff(entry.adapter, utils.vec_join(args, paths), cb)
end

---@class diffview.ChangedLine
---@field path string
---@field kind "+"|"-"
---@field lnum integer Line number on the side the line lives on.
---@field text string

---Walk unified-diff output and yield every +/- line with its source line
---number. Handles rename headers, `\ No newline` markers and -U0 output.
---@param lines string[]
---@param on_line fun(l: diffview.ChangedLine)
---@param on_hunk? fun(path: string, row: integer, old_start: integer, new_start: integer)
local function walk_patch(lines, on_line, on_hunk)
  local path
  local old_lnum, new_lnum
  local in_hunk = false

  for row, line in ipairs(lines) do
    local c = line:sub(1, 1)

    if line:match("^diff %-%-git ") then
      in_hunk = false
      path = nil
    elseif line:match("^%+%+%+ ") then
      local p = line:sub(5)
      if p ~= "/dev/null" then path = p:gsub("^b/", "") end
    elseif line:match("^%-%-%- ") and not path then
      local p = line:sub(5)
      if p ~= "/dev/null" then path = p:gsub("^a/", "") end
    elseif c == "@" then
      local os_, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      if os_ and ns then
        old_lnum, new_lnum = tonumber(os_), tonumber(ns)
        in_hunk = true
        if on_hunk and path then on_hunk(path, row, old_lnum, new_lnum) end
      end
    elseif in_hunk and path then
      if c == "+" then
        on_line({ path = path, kind = "+", lnum = new_lnum, text = line:sub(2), row = row })
        new_lnum = new_lnum + 1
      elseif c == "-" then
        on_line({ path = path, kind = "-", lnum = old_lnum, text = line:sub(2), row = row })
        old_lnum = old_lnum + 1
      elseif c == " " or line == "" then
        old_lnum, new_lnum = old_lnum + 1, new_lnum + 1
      end
      -- "\ No newline at end of file": no line-number movement.
    end
  end
end

---Every changed line of the view. Entries sharing rev args are diffed in one
---git call (at most one per section: conflicting / working / staged).
---@param view DiffView
---@param cb fun(changes: diffview.ChangedLine[])
local function collect_changes(view, cb)
  local groups = {} ---@type table<string, { args: string[], paths: string[] }>
  local order = {}
  local changes = {} ---@type diffview.ChangedLine[]
  local known = {} ---@type table<string, boolean>

  for _, entry in ipairs(view_files(view)) do
    known[entry.path] = true
    local args = entry_diff_args(entry)
    if args then
      local key = table.concat(args, "\0")
      if not groups[key] then
        groups[key] = { args = args, paths = {} }
        order[#order + 1] = key
      end
      local g = groups[key]
      g.paths[#g.paths + 1] = entry.path
      if entry.oldpath and entry.oldpath ~= entry.path then
        g.paths[#g.paths + 1] = entry.oldpath
      end
    else
      walk_patch(untracked_patch(entry), function(l) changes[#changes + 1] = l end)
    end
  end

  local pending = #order
  if pending == 0 then return cb(changes) end

  for _, key in ipairs(order) do
    local g = groups[key]
    git_diff(view.adapter, utils.vec_join(g.args, "-U0", "--", g.paths), function(lines)
      walk_patch(lines, function(l)
        -- Only lines of files the panel actually lists (pathspec is a
        -- prefix match: `dir` would also pull in `dir/other`).
        if known[l.path] then changes[#changes + 1] = l end
      end)
      pending = pending - 1
      if pending == 0 then
        table.sort(changes, function(x, y)
          if x.path ~= y.path then return x.path < y.path end
          if x.row ~= y.row then return x.row < y.row end
          return x.lnum < y.lnum
        end)
        cb(changes)
      end
    end)
  end
end

--#endregion

--#region display

local ns_preview = api.nvim_create_namespace("diffview_picker_preview")

---@param entry FileEntry
---@return string
local function file_label(entry)
  local stats = entry.stats or {}
  local counts = ""
  if stats.additions or stats.deletions then
    counts = ("  +%d -%d"):format(stats.additions or 0, stats.deletions or 0)
  end
  local kind = entry.kind == "staged" and " [staged]"
    or entry.kind == "conflicting" and " [conflict]"
    or ""
  return ("%s %s%s%s"):format(entry.status or " ", entry.path, kind, counts)
end

---@param l diffview.ChangedLine
---@return string
local function line_label(l)
  return ("%s:%d %s %s"):format(l.path, l.lnum, l.kind, vim.trim(l.text))
end

---Fill a preview buffer with a patch and highlight it as a diff.
---@param bufnr integer
---@param lines string[]
local function show_patch(bufnr, lines)
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local ok, putils = pcall(require, "telescope.previewers.utils")
  if ok then
    pcall(putils.highlighter, bufnr, "diff")
  else
    vim.bo[bufnr].filetype = "diff"
  end
end

---Row (1-indexed) in a patch that holds the given changed line.
---@param lines string[]
---@param l diffview.ChangedLine
---@return integer?
local function patch_row_of(lines, l)
  local found
  walk_patch(lines, function(x)
    if not found and x.kind == l.kind and x.lnum == l.lnum then found = x.row end
  end)
  return found
end

--#endregion

--#region pickers

---Fuzzy-find a file of the current view and open it.
---@param opts? { open?: string|string[] } With no diffview open, open one with
---this rev arg first (e.g. "main...HEAD") and pick once it's ready.
function M.pick_file(opts)
  local view = current_view(opts, function() M.pick_file() end)
  if not view then return end

  local files = view_files(view)
  if #files == 0 then
    utils.info("[diffview] No files in this view.")
    return
  end

  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if not has_telescope then
    vim.ui.select(files, { prompt = "Diff files", format_item = file_label }, function(choice)
      if choice then goto_entry(view, choice) end
    end)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")
  local t_actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local patch_cache = {} ---@type table<FileEntry, string[]>

  pickers.new({}, {
    prompt_title = "Diff files",
    finder = finders.new_table({
      results = files,
      entry_maker = function(entry)
        return {
          value = entry,
          display = file_label(entry),
          ordinal = entry.path,
          path = entry.absolute_path,
        }
      end,
    }),
    sorter = conf.file_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Patch",
      dyn_title = function(_, entry) return entry.value.path end,
      define_preview = function(self, entry)
        local file = entry.value ---@type FileEntry
        local bufnr = self.state.bufnr
        local cached = patch_cache[file]
        if cached then return show_patch(bufnr, cached) end

        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "…" })
        entry_patch(file, function(lines)
          patch_cache[file] = lines
          -- The previewer may have moved on to another entry meanwhile.
          if self.state.bufnr == bufnr then show_patch(bufnr, lines) end
        end)
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      t_actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        t_actions.close(prompt_bufnr)
        if entry then goto_entry(view, entry.value) end
      end)
      return true
    end,
  }):find()
end

---Fuzzy-find across every added / deleted line of the current diff and jump
---to it. Deleted lines land on their `-` row in the unified buffer.
---@param opts? { open?: string|string[] } See pick_file.
function M.pick_line(opts)
  local view = current_view(opts, function() M.pick_line() end)
  if not view then return end

  if not view:instanceof(DiffView.__get()) then
    utils.err("[diffview] Searching changed lines only works in a diff view.")
    return
  end
  ---@cast view DiffView

  local files_by_path = {} ---@type table<string, FileEntry>
  for _, entry in ipairs(view_files(view)) do
    files_by_path[entry.path] = files_by_path[entry.path] or entry
  end

  collect_changes(view, function(changes)
    if #changes == 0 then
      utils.info("[diffview] No changed lines in this view.")
      return
    end

    local function jump(l)
      local entry = files_by_path[l.path]
      if entry then goto_entry(view, entry, l.kind == "-" and "a" or "b", l.lnum) end
    end

    local has_telescope, pickers = pcall(require, "telescope.pickers")
    if not has_telescope then
      vim.ui.select(changes, { prompt = "Changed lines", format_item = line_label }, function(choice)
        if choice then jump(choice) end
      end)
      return
    end

    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local previewers = require("telescope.previewers")
    local t_actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local entry_display = require("telescope.pickers.entry_display")

    local displayer = entry_display.create({
      separator = " ",
      items = { { width = 1 }, { remaining = true } },
    })

    local patch_cache = {} ---@type table<string, string[]>

    ---@param self table
    ---@param l diffview.ChangedLine
    ---@param lines string[]
    local function show_at(self, l, lines)
      local bufnr = self.state.bufnr
      show_patch(bufnr, lines)
      local row = patch_row_of(lines, l)
      if row and api.nvim_win_is_valid(self.state.winid) then
        api.nvim_buf_clear_namespace(bufnr, ns_preview, 0, -1)
        api.nvim_buf_set_extmark(bufnr, ns_preview, row - 1, 0, {
          end_row = row,
          end_col = 0,
          hl_group = "TelescopePreviewLine",
          hl_eol = true,
          strict = false,
          priority = 60,
        })
        api.nvim_win_set_cursor(self.state.winid, { row, 0 })
        api.nvim_win_call(self.state.winid, function() pcall(vim.cmd, "normal! zz") end)
      end
    end

    pickers.new({}, {
      prompt_title = "Changed lines",
      finder = finders.new_table({
        results = changes,
        entry_maker = function(l)
          local sign_hl = l.kind == "+" and "DiffviewUnifiedSignAdd" or "DiffviewUnifiedSignDel"
          return {
            value = l,
            ordinal = ("%s %s:%d"):format(vim.trim(l.text), l.path, l.lnum),
            display = function()
              return displayer({
                { l.kind, sign_hl },
                ("%s:%d  %s"):format(l.path, l.lnum, vim.trim(l.text)),
              })
            end,
            path = pl:absolute(l.path, view.adapter.ctx.toplevel),
            lnum = l.lnum,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Patch",
        dyn_title = function(_, entry) return entry.value.path end,
        define_preview = function(self, entry)
          local l = entry.value ---@type diffview.ChangedLine
          local bufnr = self.state.bufnr
          local cached = patch_cache[l.path]
          if cached then return show_at(self, l, cached) end

          local file = files_by_path[l.path]
          if not file then return end
          api.nvim_buf_set_lines(bufnr, 0, -1, false, { "…" })
          entry_patch(file, function(lines)
            patch_cache[l.path] = lines
            if self.state.bufnr == bufnr then show_at(self, l, lines) end
          end)
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        t_actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          t_actions.close(prompt_bufnr)
          if entry then jump(entry.value) end
        end)
        return true
      end,
    }):find()
  end)
end

--#endregion

return M
