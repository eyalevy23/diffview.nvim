local api = vim.api

---Overflow float for panel rows.
---
---A row whose flex region had to be truncated to fit the panel gets its
---complete text drawn in a one-line float laid over it, so a deeply nested or
---simply long name stays readable without widening the panel or scrolling it
---sideways. It follows the cursor: shown for the row the cursor lands on,
---dropped as soon as it moves away or leaves the buffer.
---
---Same idea as nvim-tree's `renderer.full_name`, but the trigger is exact
---rather than inferred. nvim-tree re-measures the drawn line and subtracts the
---width of its right-aligned extmarks to guess whether anything was cut; here
---the renderer stashes the untruncated chunks on the row's component
---(`comp.full_row`, see scene/views/diff/render.lua) at the moment it decides
---to truncate, so there is nothing to re-derive and nothing to get wrong.
---
---The float carries the left and flex regions only — the indent, the icon and
---the whole name. The pinned right region (stats, status letter) is left out
---on purpose: it is already fully visible in the row underneath, and repeating
---it would push the name back out of view.
local M = {}

---The single live float, if any. Only one row can be under the cursor.
---@type integer?
local win

local ns = api.nvim_create_namespace("DiffviewFullName")

function M.hide()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end

  win = nil
end

---@param panel Panel Panel whose rows may carry `full_row` chunks.
function M.show(panel)
  M.hide()

  if not (panel and panel:is_open() and panel:buf_loaded()) then return end
  if api.nvim_get_current_buf() ~= panel.bufid then return end

  -- A wrapped row is already readable in full, and a horizontally scrolled one
  -- would put the float over the wrong text.
  if vim.wo[panel.winid].wrap then return end
  if vim.fn.winsaveview().leftcol ~= 0 then return end

  local lnum = api.nvim_win_get_cursor(panel.winid)[1]
  local comp = panel.components.comp:get_comp_on_line(lnum)
  local chunks = comp and comp.full_row

  if not chunks then return end

  local text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))

  -- Room from the row's first text column to the right edge of the editor. The
  -- float may well end up narrower than the panel and still be worth drawing:
  -- it drops the right region, so it spends every column it has on the name.
  local textoff = vim.fn.getwininfo(panel.winid)[1].textoff
  local room = vim.o.columns - api.nvim_win_get_position(panel.winid)[2] - textoff
  local width = math.min(vim.fn.strdisplaywidth(text), room)

  if width < 1 then return end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, { text })

  local offset = 0
  for _, chunk in ipairs(chunks) do
    local len = #chunk[1]

    if chunk[2] then
      api.nvim_buf_set_extmark(buf, ns, 0, offset, {
        end_col = offset + len,
        hl_group = chunk[2],
      })
    end

    offset = offset + len
  end

  win = api.nvim_open_win(buf, false, {
    relative = "win",
    win = panel.winid,
    -- Anchored to the buffer position, so it lands on the row's own text
    -- columns whatever the panel's gutter is doing.
    bufpos = { lnum - 1, 0 },
    row = 0,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "none",
    zindex = 40,
    focusable = false,
    noautocmd = true,
  })

  vim.wo[win].wrap = false
  vim.wo[win].winhighlight =
    "Normal:DiffviewNormal,NormalNC:DiffviewNormal,CursorLine:DiffviewCursorLine"
  -- The float is never focused, so its cursor stays on line 1 — which is the
  -- row: with cursorline on, the overlay keeps the panel's selected-row
  -- background instead of punching a hole in it.
  vim.wo[win].cursorline = vim.wo[panel.winid].cursorline
  vim.wo[win].cursorlineopt = "both"
end

return M
