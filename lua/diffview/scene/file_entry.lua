local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local conflict_decor = lazy.require("diffview.scene.conflict_decor") ---@module "diffview.scene.conflict_decor"
local hl = lazy.require("diffview.hl") ---@module "diffview.hl"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local pl = lazy.access(utils, "path") ---@type PathLib

local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer
---@field conflicts integer

---@class RevMap
---@field a Rev
---@field b Rev
---@field c Rev
---@field d Rev

---@class FileEntry : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit Commit|nil
---@field merge_ctx vcs.MergeContext?
---@field active boolean
---@field opened boolean
local FileEntry = oop.create_class("FileEntry")

---@class FileEntry.init.Opt
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit? Commit
---@field merge_ctx? vcs.MergeContext

---FileEntry constructor
---@param opt FileEntry.init.Opt
function FileEntry:init(opt)
  self.adapter = opt.adapter
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = pl:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path)
  self.revs = opt.revs
  self.layout = opt.layout
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.commit = opt.commit
  self.merge_ctx = opt.merge_ctx
  self.active = false
  self.opened = false
  self:use_merge_winopts()
end

function FileEntry:destroy()
  for _, f in ipairs(self.layout:files()) do
    f:destroy()
  end

  self.layout:destroy()
end

---@param new_head Rev
function FileEntry:update_heads(new_head)
  for _, file in ipairs(self.layout:files()) do
    if file.rev.track_head then
      file:dispose_buffer()
      file.rev = new_head
    end
  end
end

---@param flag boolean
function FileEntry:set_active(flag)
  self.active = flag

  for _, f in ipairs(self.layout:files()) do
    f.active = flag
  end
end

---The merge tool's panes: absolute numbers (relative ones count differently in
---each pane, so rows can't be compared across them), the unified view's quiet
---"N unchanged lines" fold text, and filler drawn as a faint hatch — it is
---alignment padding, not a deletion. RESULT (`b`) also maps DiffAdd to a
---bg-less group so the conflict washes of scene/conflict_decor.lua show.
---@param file vcs.File
---@param is_result boolean
local function use_merge_winopts(file, is_result)
  local winhl = {}
  for _, map in ipairs(file.winopts.winhl or {}) do
    if map:match("^DiffDelete:") then
      map = "DiffDelete:DiffviewDiffFill"
    elseif is_result and map:match("^DiffAdd:") then
      map = "DiffAdd:DiffviewResultAdd"
    end
    winhl[#winhl + 1] = map
  end
  file.winopts = vim.tbl_extend("force", file.winopts, {
    relativenumber = false,
    foldtext = "v:lua.require'diffview.scene.layouts.unified_render'.foldtext()",
    fillchars = "fold: ,diff:╱,eob: ",
    winhl = winhl,
  })
end

---@param target_layout Layout
function FileEntry:convert_layout(target_layout)
  local get_data

  for _, file in ipairs(self.layout:files()) do
    if file.get_data then
      get_data = file.get_data
      break
    end
  end

  local function create_file(rev, symbol)
    return File({
      adapter = self.adapter,
      path = symbol == "a" and self.oldpath or self.path,
      kind = self.kind,
      commit = self.commit,
      get_data = get_data,
      rev = rev,
      nulled = select(2, pcall(target_layout.should_null, rev, self.status, symbol)),
    }) --[[@as vcs.File ]]
  end

  self.layout = target_layout({
    a = utils.tbl_access(self.layout, "a.file") or create_file(self.revs.a, "a"),
    b = utils.tbl_access(self.layout, "b.file") or create_file(self.revs.b, "b"),
    c = utils.tbl_access(self.layout, "c.file") or create_file(self.revs.c, "c"),
    d = utils.tbl_access(self.layout, "d.file") or create_file(self.revs.d, "d"),
  })
  self:use_merge_winopts()
  self:update_merge_context()
end

---Give a conflicted entry's panes the merge tool's window options.
function FileEntry:use_merge_winopts()
  if self.kind ~= "conflicting" or not self.layout then return end
  for _, sym in ipairs({ "a", "b", "c", "d" }) do
    local file = utils.tbl_access(self.layout, { sym, "file" })
    if file then use_merge_winopts(file, sym == "b") end
  end
end

---@param stat? table
function FileEntry:validate_stage_buffers(stat)
  stat = stat or pl:stat(pl:join(self.adapter.ctx.dir, "index"))
  local cached_stat = utils.tbl_access(fstat_cache, { self.adapter.ctx.toplevel, "index" })

  if stat and (not cached_stat or cached_stat.mtime < stat.mtime.sec) then
    for _, f in ipairs(self.layout:files()) do
      if f.rev.type == RevType.STAGE and f:is_valid() then
        if f.rev.stage > 0 then
          -- We only care about stage 0 here
          f:dispose_buffer()
        else
          local is_modified = vim.bo[f.bufnr].modified

          if f.blob_hash then
            local new_hash = self.adapter:file_blob_hash(f.path)

            if new_hash and new_hash ~= f.blob_hash then
              if is_modified then
                utils.warn((
                  "A file was changed in the index since you started editing it!"
                  .. " Be careful not to lose any staged changes when writing to this buffer: %s"
                ):format(api.nvim_buf_get_name(f.bufnr)))
              else
                f:dispose_buffer()
              end
            end
          elseif not is_modified then
            -- Should be very rare that we don't have an index-buffer's blob
            -- hash. But in that case, we can't warn the user when a file
            -- changes in the index while they're editing its index buffer.
            f:dispose_buffer()
          end
        end
      end
    end
  end
end

---A merge pane's winbar, styled like the unified one: the side as a colored
---pill, then the branch. The short hash, right-aligned and dim, only stands in
---when no branch names the side (a rebase, the base). `%<` sits right after
---the pill, so a narrow pane cuts the branch before the side.
---@param label string
---@param side "Ours"|"Theirs"|"Base"|"Result"
---@param detail? string Plain text shown in place of a branch.
---@param rev? { hash: string?, ref_names: string? }
---@return string
local function merge_winbar(label, side, detail, rev)
  local group = "%#DiffviewWinBar" .. side .. "#"
  local bar
  if hl.winbar_pill and config.get_config().use_icons then
    local cap = "%#DiffviewWinBar" .. side .. "Cap#"
    bar = " " .. cap .. "\u{e0b6}" .. group .. " " .. label .. " " .. cap .. "\u{e0b4}"
  else
    bar = " " .. group .. label
  end
  bar = bar .. "%<"

  local branch = rev and conflict_decor.branch(rev.ref_names)
  local text = branch or detail
  if text then
    bar = bar .. " %#DiffviewWinBarFile#" .. text:gsub("%%", "%%%%")
  end
  if not branch and rev and rev.hash then
    bar = bar .. "%= %#DiffviewWinBarDir#" .. rev.hash:sub(1, 7) .. " "
  end
  return bar .. "%*"
end

---Update winbar info
---@param ctx? vcs.MergeContext
function FileEntry:update_merge_context(ctx)
  ctx = ctx or self.merge_ctx
  if ctx then self.merge_ctx = ctx else return end

  local layout = self.layout --[[@as Diff3 ]]

  if layout.a then
    layout.a.file.winbar = merge_winbar("OURS", "Ours", nil, ctx.ours)
  end

  if layout.b then
    layout.b.file.winbar = merge_winbar("RESULT", "Result", "working tree") .. conflict_decor.position_expr
  end

  if layout.c then
    layout.c.file.winbar = merge_winbar("THEIRS", "Theirs", nil, ctx.theirs)
  end
end

---Derive custom folds from the hunks in a diff patch.
---@param diff diff.FileEntry
function FileEntry:update_patch_folds(diff)
  if not self.layout:instanceof(Diff2.__get()) then return end

  local layout = self.layout --[[@as Diff2 ]]
  local folds = {
    a = utils.tbl_set(layout.a.file, { "custom_folds" }, { type = "diff_patch" }),
    b = utils.tbl_set(layout.b.file, { "custom_folds" }, { type = "diff_patch" }),
  }

  local lcount_a = api.nvim_buf_line_count(layout.a.file.bufnr)
  local lcount_b = api.nvim_buf_line_count(layout.b.file.bufnr)

  local prev_last_old, prev_last_new = 0, 0

  for i = 1, #diff.hunks + 1 do
    local hunk = diff.hunks[i]
    local first_old, last_old, first_new, last_new

    if hunk then
      first_old = hunk.old_row
      last_old = first_old + hunk.old_size - 1
      first_new = hunk.new_row
      last_new = first_new + hunk.new_size - 1
    else
      first_old = lcount_a + 1
      first_new = lcount_b + 1
    end

    if first_old - prev_last_old > 1 then
      local prev_fold = folds.a[#folds.a]

      if prev_fold and (prev_last_old + 1) - prev_fold[2] == 1 then
        -- This fold is right next to the previous: merge the folds
        prev_fold[2] = first_old - 1
      else
        table.insert(folds.a, { prev_last_old + 1, first_old - 1 })
      end
      -- print("old:", folds.a[#folds.a][1], folds.a[#folds.a][2])
    end

    if first_new - prev_last_new > 1 then
      local prev_fold = folds.b[#folds.b]

      if prev_fold and (prev_last_new + 1) - prev_fold[2] == 1 then
        -- This fold is right next to the previous: merge the folds
        prev_fold[2] = first_new - 1
      else
        table.insert(folds.b, { prev_last_new + 1, first_new - 1 })
      end
      -- print("new:", folds.b[#folds.b][1], folds.b[#folds.b][2])
    end

    prev_last_old = last_old
    prev_last_new = last_new
  end
end

---Check if the entry has custom diff patch folds.
---@return boolean
function FileEntry:has_patch_folds()
  for _, file in ipairs(self.layout:files()) do
    if not file.custom_folds or file.custom_folds.type ~= "diff_patch" then
      return false
    end
  end

  return true
end

---@return boolean
function FileEntry:is_null_entry()
  return self.path == "null" and self.layout:get_main_win().file == File.NULL_FILE
end

---@static
---@param adapter VCSAdapter
function FileEntry.update_index_stat(adapter, stat)
  stat = stat or pl:stat(pl:join(adapter.ctx.toplevel, "index"))

  if stat then
    if not fstat_cache[adapter.ctx.toplevel] then
      fstat_cache[adapter.ctx.toplevel] = {}
    end

    fstat_cache[adapter.ctx.toplevel].index = {
      mtime = stat.mtime.sec,
    }
  end
end

---@class FileEntry.with_layout.Opt : FileEntry.init.Opt
---@field nulled boolean
---@field get_data git.FileDataProducer?
---@field binary? boolean

---@param layout_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return FileEntry
function FileEntry.with_layout(layout_class, opt)
  local function create_file(rev, symbol)
    return File({
      adapter = opt.adapter,
      path = symbol == "a" and opt.oldpath or opt.path,
      kind = opt.kind,
      commit = opt.commit,
      get_data = opt.get_data,
      rev = rev,
      binary = opt.binary,
      nulled = utils.sate(
        opt.nulled,
        select(2, pcall(layout_class.should_null, rev, opt.status, symbol))
      ),
    }) --[[@as vcs.File ]]
  end

  return FileEntry({
    adapter = opt.adapter,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    revs = opt.revs,
    layout = layout_class({
      a = create_file(opt.revs.a, "a"),
      b = create_file(opt.revs.b, "b"),
      c = create_file(opt.revs.c, "c"),
      d = create_file(opt.revs.d, "d"),
    }),
  })
end

function FileEntry.new_null_entry(adapter)
  return FileEntry({
    adapter = adapter,
    path = "null",
    kind = "working",
    binary = false,
    nulled = true,
    layout = Diff1({
      b = File.NULL_FILE,
    })
  })
end

M.FileEntry = FileEntry

return M
