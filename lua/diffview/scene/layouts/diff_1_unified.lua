-- Single-window unified diff layout. The visible window shows a synthetic
-- read-only scratch buffer where context / added / deleted lines are all real
-- buffer lines (rendered by scene/layouts/unified_render.lua). The `a` and
-- `b` windows exist only as hidden data carriers. Editing happens in the real
-- file via the jump-to-edit action.

local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Window = require("diffview.scene.window").Window
local Rev = require("diffview.vcs.rev").Rev
local RevType = require("diffview.vcs.rev").RevType
local oop = require("diffview.oop")

local unified = require("diffview.scene.layouts.unified_render")

require("diffview.comments").init()

local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local dir_watch = lazy.require("diffview.vcs.dir_watch") ---@module "diffview.vcs.dir_watch"
local hl = lazy.require("diffview.hl") ---@module "diffview.hl"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

local uid_counter = 0

---@class Diff1Unified : Diff2
---@field main Window The single visible window (unified scratch buffer).
---@field _file_mode_buf? integer The unified buffer shown as the whole file (gutter markers instead of -/+ rows); moving to another file resets it.
---@field _diff_open_folds? { [1]: integer, [2]: integer }[] Gap folds open when the file view was entered, reopened on the way back.
local Diff1Unified = oop.create_class("Diff1Unified", Diff2)

Diff1Unified.name = "diff1_unified"

---@param opt Diff2.init.Opt
function Diff1Unified:init(opt)
  self:super(opt)
  self.main = Window({})
  self:use_windows(self.main)
  self._src = nil ---@type integer? The b-side buffer being followed.
  self._disk = nil ---@type fun()? Unsubscribes the one disk watch, for `_src`.
  self._work = nil ---@type ManagedFn? The one re-render debounce.
  self._attached = {} ---@type table<integer, true> Buffers carrying our attach.
end

---@override
---@param self Diff1Unified
---@param pivot integer?
Diff1Unified.create = async.void(function(self, pivot)
  self:create_pre()
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.main then
      self.main:set_id(curwin)
    else
      self.main = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)

  -- Only the unified window is real — a and b are hidden data carriers.
  self.windows = { self.main }

  await(self:create_post())
end)

---Winbar breadcrumb for a repo-relative path — ` lua ›  atlas ›  query.lua`
---— plus the rendered diff's `+N -M`, right-aligned. A static string, rebuilt
---only when the diff re-renders.
---@param path string
---@param st? UnifiedState
---@return string
function Diff1Unified:winbar_for(path, st)
  local conf = config.get_config()
  local segs = vim.split(path, "/", { plain = true })
  local out = {}
  for i, seg in ipairs(segs) do
    local name = seg:gsub("%%", "%%%%")
    if i < #segs then
      local icon = conf.use_icons and ("%#DiffviewFolderSign#" .. conf.icons.folder_closed .. " ") or ""
      out[i] = icon .. "%#DiffviewWinBarDir#" .. name
    else
      local icon, icon_hl = hl.get_file_icon(seg, vim.fn.fnamemodify(seg, ":e"))
      out[i] = (icon_hl and ("%#" .. icon_hl .. "#") or "") .. icon .. "%#DiffviewWinBarFile#" .. name
    end
  end
  local bar = " " .. table.concat(out, "%#DiffviewWinBarSep# › ") .. "%="
  if st and st.file_mode then
    bar = bar .. "%#DiffviewWinBarDir#file view "
  end
  if st and st.n_add + st.n_del > 0 then
    -- A rounded pill (the statusline's own caps) keeps the counts legible at
    -- the winbar's size; a zero side is left out, as in the file panel.
    local counts = {}
    if st.n_add > 0 then counts[#counts + 1] = ("%%#DiffviewWinBarPillAdd#+%d"):format(st.n_add) end
    if st.n_del > 0 then counts[#counts + 1] = ("%%#DiffviewWinBarPillDel#-%d"):format(st.n_del) end
    local body = table.concat(counts, "%#DiffviewWinBarPillAdd# ")
    if hl.winbar_pill and conf.use_icons then
      bar = bar .. "%#DiffviewWinBarPill#\u{e0b6}%#DiffviewWinBarPillAdd# " .. body
        .. "%#DiffviewWinBarPillAdd# %#DiffviewWinBarPill#\u{e0b4} "
    else
      bar = bar .. body .. " "
    end
  end
  return bar .. "%*"
end

---The synthetic file wrapping the unified scratch buffer. Created lazily on
---the FileEntry's layout so the buffer is cached per entry and adopted by the
---view's layout clone through `use_entry`. Being a real `vcs.File` keeps
---keymap attachment, `Window:is_file_open()`, events and destruction working.
---@return vcs.File
function Diff1Unified:get_unified_file()
  if not self.main.file then
    local base = self.b.file or self.a.file
    assert(base, "Cannot create a unified file without a source file!")

    local file = File({
      adapter = base.adapter,
      path = base.path,
      kind = base.kind,
      commit = base.commit,
      rev = Rev(RevType.CUSTOM),
      nulled = false,
      binary = false,
    }) --[[@as vcs.File ]]
    file.symbol = "b"
    file.winbar = self:winbar_for(file.path)

    self.main:set_file(file)
  end

  return self.main.file
end

---@override
---@param self Diff1Unified
---@param entry FileEntry
Diff1Unified.use_entry = async.void(function(self, entry)
  local layout = entry.layout --[[@as Diff1Unified ]]
  assert(layout:instanceof(Diff1Unified))

  self:set_file_a(layout.a.file)
  self:set_file_b(layout.b.file)
  self.main:set_file(layout:get_unified_file())

  if self:is_valid() then
    await(self:open_files())
  end
end)

---Ensure the scratch buffer exists for the unified file.
---@private
---@return vcs.File
function Diff1Unified:_ensure_unified_buf()
  local file = self:get_unified_file()

  if not file:is_valid() then
    file.bufnr = api.nvim_create_buf(false, true) -- nofile, nobuflisted
    vim.bo[file.bufnr].undolevels = -1
    vim.bo[file.bufnr].modifiable = false
    vim.bo[file.bufnr].bufhidden = "hide"

    -- NOTE: deliberately no `filetype detect`: a real filetype would attach a
    -- whole-buffer TS parser to interleaved -/+ content. Highlighting comes
    -- from the sources via unified_render's decoration provider.
    uid_counter = uid_counter + 1
    pcall(api.nvim_buf_set_name, file.bufnr, ("diffview://unified/%d/%s"):format(uid_counter, file.path))

    api.nvim_create_autocmd("BufWipeout", {
      buffer = file.bufnr,
      once = true,
      callback = function(state)
        unified.cleanup(state.buf)
      end,
    })

    file:post_buf_created()
  end

  return file
end

---Render (or refresh) the unified buffer from the current a/b sources.
---@private
---@return UnifiedState st
---@return boolean changed
function Diff1Unified:_render()
  local file = self:_ensure_unified_buf()
  local st, changed = unified.render(file.bufnr, self.a.file, self.b.file, {
    file_mode = self._file_mode_buf == file.bufnr,
  })
  self:_follow(self.b.file and self.b.file:is_valid() and self.b.file.bufnr or nil)
  self:_watch_diagnostics(file.bufnr)
  return st, changed
end

---Mirror the new side's diagnostics onto the added rows. Only a working-tree
---file has language servers attached; the view kind's `disable_diagnostics`
---turns it off.
---@private
---@param bufnr integer
function Diff1Unified:_watch_diagnostics(bufnr)
  local b = self.b.file
  local conf = config.get_config().view
  local view = lib.get_current_view()
  local opts = (view and FileHistoryView.__get():ancestorof(view)) and conf.file_history or conf.default

  local src = b and b:is_valid() and not (b.nulled or b.binary) and b.rev.type == RevType.LOCAL
    and not opts.disable_diagnostics and b.bufnr or nil
  local min = opts.diagnostics_min_severity
  if type(min) ~= "number" then
    min = vim.diagnostic.severity[min or "WARN"] or vim.diagnostic.severity.WARN
  end

  unified.watch_diagnostics(bufnr, src, min)
end

---Re-render after a source buffer changed, preserving cursor position.
---@private
function Diff1Unified:_refresh()
  local file = self.main.file
  if not (self.main:is_valid() and file and file:is_valid()) then return end
  if api.nvim_win_get_buf(self.main.id) ~= file.bufnr then return end

  local row = api.nvim_win_get_cursor(self.main.id)[1]
  local col = api.nvim_win_get_cursor(self.main.id)[2]
  local anchor = unified.edit_target(file.bufnr, row)
  local open_folds = unified.open_fold_spans(self.main.id, file.bufnr)

  local st, changed = self:_render()
  if not changed then return end

  file.winbar = self:winbar_for(file.path, st)
  if self.main:show_winbar_info() then
    vim.wo[self.main.id].winbar = file.winbar
  end
  unified.apply_folds(self.main.id, file.bufnr, open_folds)

  if anchor then
    local new_row = unified.row_for(file.bufnr, "b", anchor)
    if new_row then
      utils.set_cursor(self.main.id, new_row, col)
    end
  end
end

---Toggle between the interleaved diff and the whole file with gitsigns-style
---gutter markers. The cursor stays on its source line and at the same height
---in the window; a deleted row maps to the next surviving line.
function Diff1Unified:toggle_file_mode()
  local file = self.main.file
  local win = self.main.id
  if not (self.main:is_valid() and file and file:is_valid()) then return end
  if api.nvim_win_get_buf(win) ~= file.bufnr then return end

  local row, col = unpack(api.nvim_win_get_cursor(win))
  local screen_row = api.nvim_win_call(win, vim.fn.winline)
  local lnum = unified.edit_target(file.bufnr, row)

  local on = self._file_mode_buf ~= file.bufnr
  if on and not (self.b.file and not self.b.file.nulled) then
    utils.info("[diffview] The file is deleted on this side: there is no file to view.")
    return
  end
  self._file_mode_buf = on and file.bufnr or nil
  if on then
    hl.update_file_sign_hl()
    self._diff_open_folds = unified.open_fold_spans(win, file.bufnr)
  end

  local st = self:_render()
  file.winbar = self:winbar_for(file.path, st)
  if self.main:show_winbar_info() then
    vim.wo[win].winbar = file.winbar
  end
  -- The file view's relative numbers (v:relnum) only redraw on cursor moves
  -- while the window's own 'relativenumber' is set. Local only: vim.wo would
  -- also overwrite the global value (it acts like :set for window options).
  utils.set_local(win, { relativenumber = on and vim.go.relativenumber })
  unified.apply_folds(win, file.bufnr, not on and self._diff_open_folds or nil)
  if not on then self._diff_open_folds = nil end

  local new_row = lnum and unified.row_for(file.bufnr, "b", lnum) or 1
  api.nvim_win_call(win, function()
    utils.set_cursor(win, new_row, col)
    -- Back in the diff, the line may sit in a folded unchanged gap: open it.
    pcall(vim.cmd, "normal! zv")
    vim.fn.winrestview({ topline = math.max(1, new_row - (screen_row - 1)) })
  end)
end

-- Trailing debounce for source-edit re-renders: the diff repaints once you
-- pause typing for this long. Renders while the view's tab is hidden are
-- skipped entirely and caught up on tab enter.
local REFRESH_DEBOUNCE_MS = 1000

---Whether the unified window lives in the currently active tabpage.
---@private
---@return boolean
function Diff1Unified:_is_visible()
  return self.main:is_valid()
    and api.nvim_win_get_tabpage(self.main.id) == api.nvim_get_current_tabpage()
end

---Reload `src` without a prompt or an E211 for a deleted file. A buffer with
---unsaved edits is yours, and under 'noautoread' checktime raises a dialog
---that `:silent!` does not suppress: both are left alone.
---@param src integer
local function checktime(src)
  if not (api.nvim_buf_is_loaded(src) and vim.bo[src].buftype == "" and not vim.bo[src].modified) then
    return
  end
  -- Global-local: the buffer value is nil until set with :setlocal.
  local autoread = api.nvim_get_option_value("autoread", { buf = src })
  if autoread == nil then autoread = vim.go.autoread end
  if autoread then
    pcall(vim.cmd, ("silent! checktime %d"):format(src))
  end
end

---Reload `src` when its file changes on disk. Neovim itself only checks on
---focus gain, so an agent's edit landing while Neovim already has focus
---would never show. Watches the directory, not the file: tools that save by
---renaming a temp file over it (`sed -i`, most editors) end a file watch.
---@private
---@param src integer
---@return fun()? unsubscribe
function Diff1Unified:_watch_disk(src)
  local path = api.nvim_buf_get_name(src)
  if path == "" or vim.bo[src].buftype ~= "" then return end

  return dir_watch.subscribe(vim.fs.dirname(path), vim.fs.basename(path), function(err, filename)
    -- One check per burst: a write can arrive as several events.
    if err or filename == nil or self._disk_pending == src then return end
    self._disk_pending = src
    vim.schedule(function()
      if self._disk_pending == src then self._disk_pending = nil end
      -- An event queued before the layout moved on to another file.
      if self._src == src then checktime(src) end
    end)
  end)
end

---Follow the new-side source buffer: one disk watch and one attach for the
---file on screen, re-rendering (debounced) on edits made via jump-to-edit,
---any other window or disk. A hidden view is never re-rendered for nobody —
---the refresh is deferred until its tab becomes current.
---@private
---@param src integer?
function Diff1Unified:_follow(src)
  if self._src ~= src then
    self._src = src
    -- Subscribe before leaving the old file: within one directory the OS
    -- watch is kept rather than closed and recreated.
    local unwatch = src and self:_watch_disk(src) or nil
    if self._disk then self._disk() end
    self._disk = unwatch
  end
  if not src then return end

  -- The rest runs on every render: Neovim drops an attach when the buffer is
  -- unloaded (`:bdelete`), and the render reloading it must re-attach.
  self._work = self._work or debounce.debounce_trailing(REFRESH_DEBOUNCE_MS, false, vim.schedule_wrap(function()
    if not self:_is_visible() then
      self._refresh_pending = true
      return
    end
    self:_refresh()
  end))

  -- An attach left on a file the layout has moved away from stays idle and
  -- is reused if that file comes back.
  if not self._attached[src] then
    local function live()
      return src == self._src and self.main.file and self.main.file:is_valid()
    end

    -- False when the buffer is not loaded: the next render tries again.
    self._attached[src] = api.nvim_buf_attach(src, false, {
      on_lines = function()
        if not live() then
          self._attached[src] = nil
          return true -- detach
        end
        self._work()
      end,
      -- A reload from disk (autoread, `:checktime`, `:edit`) fires only this,
      -- never on_lines: without it an edit made outside Neovim (an agent, a
      -- rebase) leaves the view showing the old content. Its return value
      -- cannot detach.
      on_reload = function()
        if live() then self._work() end
      end,
      on_detach = function()
        self._attached[src] = nil
      end,
    }) or nil
  end

  if not self._catchup_au then
    self._catchup_au = api.nvim_create_autocmd("TabEnter", {
      callback = function()
        if not self.main:is_valid() then
          self._catchup_au = nil
          return true -- delete the autocmd
        end
        if self._refresh_pending and self:_is_visible() then
          self._refresh_pending = false
          self:_refresh()
        end
      end,
    })
  end
end

---@override
---@param self Diff1Unified
Diff1Unified.open_files = async.void(function(self)
  -- Load both source buffers (a=old, b=new); neither is displayed.
  for _, win in ipairs({ self.a, self.b }) do
    if win.file and not win.file:is_valid() then
      await(win:load_file())
    elseif win.file and win.file.loaded then
      -- Another open of this entry is still filling the buffer: rendering
      -- now would diff against an empty side.
      await(win.file.loaded)
    end
  end

  await(async.scheduler())

  if not self.main:is_valid() then
    self.emitter:emit("files_opened")
    return
  end

  if not (self.b.file and self.b.file.active) then
    self.main:open_null()
    self.emitter:emit("files_opened")
    return
  end

  self.main.emitter:emit("pre_open")

  local file = self:_ensure_unified_buf()
  -- File view is per visit: moving to another file returns to the diff.
  if self._file_mode_buf ~= file.bufnr then self._file_mode_buf = nil end
  local win_is_new = api.nvim_win_get_buf(self.main.id) ~= file.bufnr
  local open_folds = unified.open_fold_spans(self.main.id, file.bufnr)
  -- Only the file on screen is watched: catch up on disk edits made while
  -- this one was hidden. Done before `_render` follows it: the render reads
  -- the fresh lines, and the now-stale attach queues no second one.
  if self.b.file and self.b.file:is_valid() then
    checktime(self.b.file.bufnr)
  end
  local st, changed = self:_render()
  file.winbar = self:winbar_for(file.path, st)

  -- Attach keymaps BEFORE the buffer enters the window: plugins that scan
  -- buffer-local maps on BufEnter (e.g. which-key installing its instant
  -- <leader> trigger) must see them, or every <leader> press in this buffer
  -- stalls for 'timeoutlen' on native mapping disambiguation.
  local config = require("diffview.config")
  file:attach_buffer(false, {
    keymaps = config.get_layout_keymaps(self),
    disable_diagnostics = true,
  })

  api.nvim_win_set_buf(self.main.id, file.bufnr)

  utils.set_local(self.main.id, {
    diff = false,
    scrollbind = false,
    cursorbind = false,
    number = false,
    relativenumber = self._file_mode_buf ~= nil and vim.go.relativenumber,
    foldmethod = "manual",
    foldenable = true,
    foldcolumn = "0",
    -- Neovim never applies line backgrounds (line_hl_group) to the
    -- breakindent/showbreak region of wrapped rows, which would punch a hole
    -- in the add/del bands. Wrapped rows start flush at col 0 instead, and
    -- the statuscolumn callback draws the wrap marker in the gutter.
    breakindent = false,
    showbreak = "NONE",
    signcolumn = "yes:1",
    statuscolumn = "%!v:lua.require'diffview.scene.layouts.unified_render'.statuscol()",
    foldtext = "v:lua.require'diffview.scene.layouts.unified_render'.foldtext()",
    fillchars = "fold: ,diff: ,eob: ",
  })

  if self.main:show_winbar_info() then
    vim.wo[self.main.id].winbar = file.winbar
  end

  self.main.emitter:emit("post_open")

  if changed or win_is_new then
    unified.apply_folds(self.main.id, file.bufnr, open_folds)
  end

  api.nvim_win_call(self.main.id, function()
    DiffviewGlobal.emitter:emit("diff_buf_win_enter", file.bufnr, self.main.id, {
      symbol = "b",
      layout_name = self.name,
    })
  end)

  self.emitter:emit("files_opened")
end)

function Diff1Unified:get_main_win()
  return self.main
end

---@override
function Diff1Unified:destroy()
  if self._catchup_au then
    pcall(api.nvim_del_autocmd, self._catchup_au)
    self._catchup_au = nil
  end
  -- Idempotent and reusable: a layout-class switch destroys a cached clone
  -- that may be used again. Leftover attaches detach on their next edit.
  if self._disk then
    self._disk()
    self._disk = nil
  end
  self._disk_pending = nil
  self._src = nil
  if self._work then
    self._work.close()
    self._work = nil
  end
  local file = self.main.file
  if file and file.bufnr then
    unified.cleanup(file.bufnr)
  end
  Diff2.destroy(self)
end

---Override sync_scroll to be a no-op (single window, nothing to sync)
function Diff1Unified:sync_scroll() end

M.Diff1Unified = Diff1Unified
return M
