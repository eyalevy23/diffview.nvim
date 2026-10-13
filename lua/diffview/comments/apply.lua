-- Applying a review suggestion. Always to the working-tree file — never to
-- whatever revision the diff shows — so it works the same from any view
-- (uncommitted, staged, branch, a commit, file history). The suggestion is
-- located in the current file by content (anchor.locate_suggestion), and a
-- preview float shows exactly what will change before anything is written:
--
--   <CR>  apply and save; the thread becomes "applied"
--   e     open the file in a new tab with the change applied, unsaved —
--         saving marks the thread applied, closing without saving drops it
--   x     decline (optional reason): the thread stays open with your reply,
--         so it lands in the AI's queue
--   q     close, nothing recorded

local lazy = require("diffview.lazy")

local anchor_mod = lazy.require("diffview.comments.anchor") ---@module "diffview.comments.anchor"
local comments = lazy.require("diffview.comments") ---@module "diffview.comments"
local unified = lazy.require("diffview.scene.layouts.unified_render") ---@module "diffview.scene.layouts.unified_render"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

---@class SuggestionPlan
---@field thread ReviewThread
---@field comment ReviewComment The comment carrying the suggestion.
---@field store_path string
---@field path string Absolute path of the working-tree file.
---@field rel string Repo-relative path (titles, messages).
---@field lines string[] The file's lines the plan was computed against.
---@field first integer
---@field last integer
---@field text string[] Replacement lines.

---@type { win: integer, buf: integer, scratch: integer[], plan: SuggestionPlan }?
local state = nil

---The buffer already holding `path`, if one is loaded. Compared by real
---path: the repo may be reached through a symlink (or /tmp vs /private/tmp).
---@param path string
---@return integer?
local function loaded_buf(path)
  local real = uv.fs_realpath(path) or path
  for _, b in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(b)
    if name ~= "" and api.nvim_buf_is_loaded(b) and (uv.fs_realpath(name) or name) == real then
      return b
    end
  end
end

---The file's current content: an open buffer wins (unsaved edits included).
---@param path string
---@return string[]?
local function current_lines(path)
  local b = loaded_buf(path)
  if b then return api.nvim_buf_get_lines(b, 0, -1, false) end
  if vim.fn.filereadable(path) == 1 then return vim.fn.readfile(path) end
end

---The thread's newest suggestion — only the newest: an older one was
---superseded by the conversation, so declining the newest never brings it
---back.
---@param thread ReviewThread
---@return ReviewComment?
---@return string? err
local function pending_suggestion(thread)
  for i = #thread.comments, 1, -1 do
    local c = thread.comments[i]
    if c.suggestion and c.suggestion.replace_lines then
      if c.suggestion.declined_at then return nil, "The latest suggestion on this thread was declined." end
      return c
    end
  end
  return nil, "No suggestion on this thread."
end

---@param thread ReviewThread
---@param store_path string
---@param toplevel string
---@return SuggestionPlan? plan
---@return string? err
local function make_plan(thread, store_path, toplevel)
  local comment, why = pending_suggestion(thread)
  if not comment then return nil, why end

  local rel = thread.anchor.path
  local path = vim.fs.normalize(toplevel .. "/" .. rel)
  local lines = current_lines(path)
  if not lines then return nil, ("%s is not in your working tree."):format(rel) end

  local first, last, reason = anchor_mod.locate_suggestion(thread.anchor, comment.suggestion, lines)
  if not first then return nil, ("Can't apply to %s: %s."):format(rel, reason) end

  return {
    thread = thread,
    comment = comment,
    store_path = store_path,
    path = path,
    rel = rel,
    lines = lines,
    first = first,
    last = last,
    text = vim.split(comment.suggestion.text, "\n", { plain = true }),
  }
end

---@param plan SuggestionPlan
---@return string[]
local function applied_lines(plan)
  local out = vim.list_slice(plan.lines, 1, plan.first - 1)
  vim.list_extend(out, plan.text)
  vim.list_extend(out, plan.lines, plan.last + 1)
  return out
end

---Replace the planned range in `buf`, refusing if the file moved on since
---the preview (a stale plan must not land on the wrong lines).
---@param plan SuggestionPlan
---@param buf integer
---@return boolean ok
local function write_into(plan, buf)
  if not vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), plan.lines) then
    utils.warn("[diffview] The file changed since the preview — apply again.")
    return false
  end
  api.nvim_buf_set_lines(buf, plan.first - 1, plan.last, false, plan.text)
  return true
end

function M.close()
  if not state then return end
  local s = state
  state = nil
  if api.nvim_win_is_valid(s.win) then api.nvim_win_close(s.win, true) end
  unified.cleanup(s.buf)
  for _, b in ipairs(s.scratch) do pcall(api.nvim_buf_delete, b, { force = true }) end
end

--#region actions

---Mark the thread applied when `buf` is next written — the change is only
---"applied" once it is on disk. Keyed per thread, so two pending suggestions
---in one file both count on the save.
---@param plan SuggestionPlan
---@param buf integer
---@return integer augroup
local function mark_on_save(plan, buf)
  local aug = api.nvim_create_augroup(("diffview_apply_%d_%s"):format(buf, plan.thread.id), { clear = true })
  api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    buffer = buf,
    once = true,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, aug)
      comments.mark_applied(plan.store_path, plan.thread.id)
    end,
  })
  return aug
end

---<CR>: write the change into the file and save — unless the file's buffer
---already had unsaved edits of yours: then it is applied but left unsaved.
local function apply_now()
  local plan = state and state.plan
  M.close()
  if not plan then return end

  local buf = loaded_buf(plan.path)
  if not buf then
    buf = vim.fn.bufadd(plan.path)
    vim.fn.bufload(buf)
  end
  local was_modified = vim.bo[buf].modified
  if not write_into(plan, buf) then return end

  if was_modified then
    mark_on_save(plan, buf)
    utils.info(("[diffview] Applied to %s — it had unsaved edits, so it is not saved yet."):format(plan.rel))
    return
  end

  -- noautocmd: a format-on-save would rewrite lines the suggestion never
  -- touched. BufWritePost is replayed for the anchor drift bookkeeping.
  api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
  api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  utils.info(("[diffview] Applied to %s:%d."):format(plan.rel, plan.first))
  comments.mark_applied(plan.store_path, plan.thread.id)
end

---e: the change in the real file, in a new tab, unsaved. Saving is the
---"yes". Leaving it unsaved drops the suggestion again — but only while the
---buffer still holds exactly what was put there: anything you typed since
---is yours and is never reverted.
local function edit_first()
  local plan = state and state.plan
  M.close()
  if not plan then return end

  vim.cmd("tabedit " .. vim.fn.fnameescape(plan.path))
  local buf = api.nvim_get_current_buf()
  local was_modified = vim.bo[buf].modified
  if not write_into(plan, buf) then return end
  utils.set_cursor(0, plan.first, 0)

  local aug = mark_on_save(plan, buf)

  if was_modified then
    -- Your own unsaved edits are in the same buffer: never revert those.
    utils.info("[diffview] The file already had unsaved edits — save to apply, or undo (u) to drop it.")
    return
  end
  if #vim.fn.win_findbuf(buf) > 1 then
    -- Open elsewhere too: closing this tab leaves it on screen, so there is
    -- no "closed without saving" moment to revert at.
    utils.info("[diffview] The file is open in another window too — save to apply, or undo (u) to drop it.")
    return
  end

  local applied = api.nvim_buf_get_lines(buf, 0, -1, false)
  local leave_id
  leave_id = api.nvim_create_autocmd("BufWinLeave", {
    group = aug,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not api.nvim_buf_is_valid(buf) or #vim.fn.win_findbuf(buf) > 0 then return end
        pcall(api.nvim_del_autocmd, leave_id)
        if not vim.bo[buf].modified then
          pcall(api.nvim_del_augroup_by_id, aug)
        elseif vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), applied) then
          pcall(api.nvim_del_augroup_by_id, aug)
          api.nvim_buf_call(buf, function() vim.cmd("silent! edit!") end)
          utils.info("[diffview] Suggestion not applied (left without saving).")
        else
          -- Edited since: yours. Saving it later still counts as applied.
          utils.info(("[diffview] %s keeps your unsaved edits (with the suggestion)."):format(plan.rel))
        end
      end)
    end,
  })
end

---x: decline, with an optional reason.
local function decline()
  local plan = state and state.plan
  M.close()
  if not plan then return end
  comments.decline_suggestion(plan.store_path, plan.thread.id, plan.comment.id)
end

--#endregion

--#region preview float

---A scratch source for the renderer's Treesitter pass.
---@param lines string[]
---@param lang? string
---@return integer buf
---@return boolean has_parser
local function scratch(lines, lang)
  local b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local ok, parser = false, nil
  if lang then ok, parser = pcall(vim.treesitter.get_parser, b, lang) end
  return b, ok and parser ~= nil
end

---@param plan SuggestionPlan
local function open_float(plan)
  local new_lines = applied_lines(plan)
  local ft = vim.filetype.match({ filename = plan.path }) or ""
  local lang = ft ~= "" and vim.treesitter.language.get_lang(ft) or nil

  local lines, st, hunks = unified.build(plan.lines, new_lines)
  local ranges = st.visible_ranges
  local old_src, has_parser = scratch(plan.lines, lang)
  local new_src = scratch(new_lines, has_parser and lang or nil)
  local s = { scratch = { old_src, new_src }, plan = plan }
  st.buf_a, st.buf_b = s.scratch[1], s.scratch[2]
  st.tick_a = api.nvim_buf_get_changedtick(st.buf_a)
  st.tick_b = api.nvim_buf_get_changedtick(st.buf_b)

  local r1, r2 = ranges[1][1], ranges[#ranges][2]
  local sub = unified.slice(st, r1, r2)
  local shown = vim.list_slice(lines, r1, r2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, shown)
  vim.bo[buf].modifiable = false
  unified.state[buf] = sub
  unified.apply_hl(buf, sub, hunks, plan.lines, new_lines)
  unified._ts_precompute(sub, sub.visible_ranges)
  -- No parser (zsh, many configs): the filetype's regex syntax, as in the diff.
  if not has_parser and ft ~= "" then vim.bo[buf].syntax = ft end
  s.buf = buf

  local content = 0
  for _, l in ipairs(shown) do content = math.max(content, vim.fn.strdisplaywidth(l)) end
  local title = (" apply suggestion · %s:%d "):format(plan.rel, plan.first)
  local footer = " ↵ apply · e edit first · x decline · q close "
  local width = math.min(math.max(content + sub.w_old + sub.w_new + 6, #title + 2, #footer + 2), vim.o.columns - 4)
  local height = math.max(1, math.min(#shown, math.floor(vim.o.lines * 0.5)))

  local cfg = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    zindex = 60,
  }
  if vim.fn.has("nvim-0.10") == 1 then
    cfg.footer = { { footer, "DiffviewPeekHint" } }
    cfg.footer_pos = "right"
  end
  s.win = api.nvim_open_win(buf, true, cfg)
  utils.set_local(s.win, {
    wrap = false,
    foldenable = false,
    cursorline = false,
    signcolumn = "no",
    statuscolumn = "%!v:lua.require'diffview.scene.layouts.unified_render'.statuscol()",
    winhighlight = "FloatBorder:DiffviewPeekBorder,FloatTitle:DiffviewPeekTitle,FloatFooter:DiffviewPeekHint",
  })
  state = s

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("<CR>", apply_now, "Apply the suggestion and save")
  map("e", edit_first, "Open the file with the suggestion applied, unsaved")
  map("x", decline, "Decline the suggestion")
  map("q", M.close, "Close")
  map("<Esc>", M.close, "Close")

  -- The preview lives only while it has focus.
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function() vim.schedule(M.close) end,
  })
end

--#endregion

---Preview the thread's pending suggestion against the working-tree file.
---@param thread ReviewThread
---@param store_path string
---@param toplevel string
function M.open(thread, store_path, toplevel)
  M.close()
  local plan, err = make_plan(thread, store_path, toplevel)
  if not plan then
    utils.warn("[diffview] " .. err)
    return
  end
  if vim.deep_equal(applied_lines(plan), plan.lines) then
    utils.info(("[diffview] %s already has this change."):format(plan.rel))
    return
  end
  open_float(plan)
end

return M
