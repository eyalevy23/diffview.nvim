-- Single-window unified diff layout. The visible window shows a synthetic
-- read-only scratch buffer where context / added / deleted lines are all real
-- buffer lines (rendered by scene/layouts/unified_render.lua). The `a` and
-- `b` windows exist only as hidden data carriers, exactly like `a` in
-- Diff1Inline. Editing happens in the real file via the jump-to-edit action.

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
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

local uid_counter = 0

---@class Diff1Unified : Diff2
---@field main Window The single visible window (unified scratch buffer).
local Diff1Unified = oop.create_class("Diff1Unified", Diff2)

Diff1Unified.name = "diff1_unified"

---@param opt Diff2.init.Opt
function Diff1Unified:init(opt)
  self:super(opt)
  self.main = Window({})
  self:use_windows(self.main)
  self._watched = {}
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
    file.winbar = (" UNIFIED - %s"):format(file.path)

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
  local st, changed = unified.render(file.bufnr, self.a.file, self.b.file)
  self:_watch_source()
  return st, changed
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

  local _, changed = self:_render()
  if not changed then return end

  unified.apply_folds(self.main.id, file.bufnr)

  if anchor then
    local new_row = unified.row_for(file.bufnr, "b", anchor)
    if new_row then
      utils.set_cursor(self.main.id, new_row, col)
    end
  end
end

---Watch the new-side source buffer for edits (made via jump-to-edit or any
---other window) and re-render, debounced.
---@private
function Diff1Unified:_watch_source()
  local src = self.b.file and self.b.file:is_valid() and self.b.file.bufnr or nil
  if not src or self._watched[src] then return end
  self._watched[src] = true

  local work = debounce.debounce_trailing(200, false, vim.schedule_wrap(function()
    self:_refresh()
  end))

  api.nvim_buf_attach(src, false, {
    on_lines = function()
      if not (self.main.file and self.main.file:is_valid()) then
        self._watched[src] = nil
        return true -- detach
      end
      work()
    end,
    on_detach = function()
      self._watched[src] = nil
    end,
  })
end

---@override
---@param self Diff1Unified
Diff1Unified.open_files = async.void(function(self)
  -- Load both source buffers (a=old, b=new); neither is displayed.
  for _, win in ipairs({ self.a, self.b }) do
    if win.file and not win.file:is_valid() then
      await(win:load_file())
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
  local win_is_new = api.nvim_win_get_buf(self.main.id) ~= file.bufnr
  local _, changed = self:_render()

  api.nvim_win_set_buf(self.main.id, file.bufnr)

  utils.set_local(self.main.id, {
    diff = false,
    scrollbind = false,
    cursorbind = false,
    number = false,
    relativenumber = false,
    foldmethod = "manual",
    foldenable = true,
    foldcolumn = "0",
    signcolumn = "yes:1",
    statuscolumn = "%!v:lua.require'diffview.scene.layouts.unified_render'.statuscol()",
    foldtext = "v:lua.require'diffview.scene.layouts.unified_render'.foldtext()",
    fillchars = "fold:─,diff: ",
  })

  local config = require("diffview.config")
  file:attach_buffer(false, {
    keymaps = config.get_layout_keymaps(self),
    disable_diagnostics = true,
  })

  if self.main:show_winbar_info() then
    vim.wo[self.main.id].winbar = file.winbar
  end

  self.main.emitter:emit("post_open")

  if changed or win_is_new then
    unified.apply_folds(self.main.id, file.bufnr)
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
