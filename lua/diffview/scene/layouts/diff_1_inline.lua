local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Window = require("diffview.scene.window").Window
local oop = require("diffview.oop")

local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

-- Namespace for inline diff extmarks
local ns = api.nvim_create_namespace("diffview_inline")

---@class Diff1Inline : Diff2
local Diff1Inline = oop.create_class("Diff1Inline", Diff2)

Diff1Inline.name = "diff1_inline"

---@class Diff1Inline.init.Opt
---@field a vcs.File
---@field b vcs.File
---@field winid_a integer
---@field winid_b integer

---@param opt Diff1Inline.init.Opt
function Diff1Inline:init(opt)
  self:super(opt)
end

---@override
---@param self Diff1Inline
---@param pivot integer?
Diff1Inline.create = async.void(function(self, pivot)
  self:create_pre()
  local curwin

  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  -- Create a single window (like Diff1)
  api.nvim_win_call(pivot, function()
    vim.cmd("aboveleft vsp")
    curwin = api.nvim_get_current_win()

    if self.b then
      self.b:set_id(curwin)
    else
      self.b = Window({ id = curwin })
    end
  end)

  api.nvim_win_close(pivot, true)

  -- Only use window b (the new file) — window a is hidden, used only for data
  self.windows = { self.b }

  await(self:create_post())
end)

---Override open_files to skip diff mode and apply inline highlights
---@param self Diff1Inline
Diff1Inline.open_files = async.void(function(self)
  -- Load both file buffers (a=old, b=new)
  for _, win in ipairs({ self.a, self.b }) do
    if win.file and not win.file:is_valid() then
      await(win:load_file())
    end
  end

  await(async.scheduler())

  -- Only open file b in the visible window
  if self.b:is_valid() and self.b.file and self.b.file.active then
    if self.b.file:is_valid() then
      self.b.emitter:emit("pre_open")

      api.nvim_win_set_buf(self.b.id, self.b.file.bufnr)

      -- Disable diff mode — we render inline
      local winopts = vim.deepcopy(self.b.file.winopts)
      winopts.diff = false
      winopts.scrollbind = false
      winopts.cursorbind = false
      winopts.foldmethod = "manual"
      utils.set_local(self.b.id, winopts)

      local config = require("diffview.config")
      self.b.file:attach_buffer(false, {
        keymaps = config.get_layout_keymaps(self),
        disable_diagnostics = true,
      })

      if self.b:show_winbar_info() then
        vim.wo[self.b.id].winbar = self.b.file.winbar
      end

      self.b.emitter:emit("post_open")
    end
  end

  -- Apply inline diff highlights
  self:apply_inline_diff()

  self.emitter:emit("files_opened")
end)

---Compute and render inline diff using extmarks
function Diff1Inline:apply_inline_diff()
  local buf_b = self.b.file and self.b.file.bufnr
  if not buf_b or not api.nvim_buf_is_valid(buf_b) then return end

  -- Clear previous inline diff marks
  api.nvim_buf_clear_namespace(buf_b, ns, 0, -1)

  -- Get old file content
  local old_lines = {}
  if self.a.file and self.a.file:is_valid() then
    local buf_a = self.a.file.bufnr
    old_lines = api.nvim_buf_get_lines(buf_a, 0, -1, false)
  end

  -- Get new file content
  local new_lines = api.nvim_buf_get_lines(buf_b, 0, -1, false)

  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"

  -- Handle edge cases
  if old_text == new_text then return end
  if #old_lines == 0 and #new_lines == 0 then return end

  -- Compute unified diff
  local ok, diff_result = pcall(vim.diff, old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
  })

  if not ok or not diff_result then return end

  -- Sort hunks by position in new file
  local hunks = {}
  for _, hunk in ipairs(diff_result) do
    table.insert(hunks, hunk)
  end
  table.sort(hunks, function(a, b) return a[3] < b[3] end)

  -- Apply highlights in reverse so extmark positions stay valid
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

    if new_count > 0 then
      for j = new_start, new_start + new_count - 1 do
        if j >= 1 and j <= #new_lines then
          api.nvim_buf_set_extmark(buf_b, ns, j - 1, 0, {
            line_hl_group = "DiffviewDiffAdd",
            priority = 50,
          })
        end
      end
    end

    if old_count > 0 then
      local virt_lines = {}
      for j = old_start, old_start + old_count - 1 do
        if j >= 1 and j <= #old_lines then
          table.insert(virt_lines, { { old_lines[j], "DiffviewDiffDelete" } })
        end
      end

      if #virt_lines > 0 then
        local virt_line_pos = new_start - 1
        if new_count == 0 then
          virt_line_pos = new_start
        end
        virt_line_pos = math.max(0, math.min(virt_line_pos, #new_lines))

        api.nvim_buf_set_extmark(buf_b, ns, virt_line_pos, 0, {
          virt_lines = virt_lines,
          virt_lines_above = true,
          priority = 50,
        })
      end
    end
  end

  -- Fold unchanged sections (keep 3 context lines around each hunk)
  local context = 3
  local total = #new_lines

  if total > 0 and #hunks > 0 then
    api.nvim_win_call(self.b.id, function()
      pcall(vim.cmd, "norm! zE")

      local visible = {}
      for _, hunk in ipairs(hunks) do
        local s = hunk[3]
        local e = s + math.max(hunk[4], 1) - 1
        table.insert(visible, { math.max(1, s - context), math.min(total, e + context) })
      end

      -- Merge overlapping ranges
      local merged = { visible[1] }
      for k = 2, #visible do
        local prev = merged[#merged]
        local cur = visible[k]
        if cur[1] <= prev[2] + 1 then
          prev[2] = math.max(prev[2], cur[2])
        else
          table.insert(merged, cur)
        end
      end

      -- Fold gaps
      local pos = 1
      for _, range in ipairs(merged) do
        if pos < range[1] then
          vim.cmd(pos .. "," .. (range[1] - 1) .. "fold")
        end
        pos = range[2] + 1
      end
      if pos <= total then
        vim.cmd(pos .. "," .. total .. "fold")
      end
    end)
  end
end

function Diff1Inline:get_main_win()
  return self.b
end

---Override sync_scroll to be a no-op (single window, nothing to sync)
function Diff1Inline:sync_scroll() end

M.Diff1Inline = Diff1Inline
return M
