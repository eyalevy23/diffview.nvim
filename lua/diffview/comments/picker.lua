-- Thread picker: fuzzy-find a review thread across every file of the review
-- and jump to its card. Telescope when available (with a full-thread
-- previewer); vim.ui.select otherwise, so the feature works in a bare config.
-- Loaded lazily from comments/init so requiring it never cycles.

local lazy = require("diffview.lazy")

local async = require("diffview.async")
local store = require("diffview.comments.store")

local comments = lazy.require("diffview.comments") ---@module "diffview.comments"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

---Jump the current view to a thread: select its file, then land the cursor on
---the thread's resolved row. The card render trails the file switch (autocmd +
---schedule), so landing is polled briefly — and re-asserted once, because
---set_file's own deferred cursor restore would otherwise overwrite the jump.
---@param thread ReviewThread
local goto_thread = async.void(function(thread)
  local view = lib.get_current_view()
  if not (view and view.set_file_by_path) then return end

  await(view:set_file_by_path(thread.anchor.path, true))

  local function try_land()
    for bufnr, ctx in pairs(comments.buf_ctx) do
      if api.nvim_buf_is_valid(bufnr) and ctx.path == thread.anchor.path then
        for _, p in ipairs(comments.place_threads(bufnr)) do
          if p.thread.id == thread.id then
            local win = vim.fn.win_findbuf(bufnr)[1]
            if win then
              api.nvim_set_current_win(win)
              utils.set_cursor(win, math.min(p.row, api.nvim_buf_line_count(bufnr)), 0)
              api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
              return true
            end
          end
        end
      end
    end
    return false
  end

  local tries = 0
  local function land()
    if try_land() then
      vim.defer_fn(function() try_land() end, 250)
      return
    end
    tries = tries + 1
    if tries < 40 then vim.defer_fn(land, 50) end
  end
  land()
end)

---One display line summarizing a thread for pickers.
---@param thread ReviewThread
---@return string
local function thread_label(thread)
  local icon = thread.status == "resolved" and "○"
    or thread.status == "applied" and "✓"
    or "●"
  local first = thread.comments[1]
  local body = first and (first.body or ""):gsub("%s+", " ") or ""
  return ("%s %s:%d  %s — %s"):format(
    icon, thread.anchor.path, thread.anchor.line, first and first.author or "?", body)
end

---Pick a comment thread across every file of the review and jump to it. Open
---threads sort first — this exists because finding one card in a 60-file diff
---by paging through entries doesn't scale.
---@param opts? { open?: string } With no diffview open, open one with this
---rev arg first (e.g. "main...HEAD") and pick once it's ready, instead of
---erroring. Lets a global keymap be a one-liner.
function M.pick(opts)
  local view = lib.get_current_view()
  local adapter = view and view.adapter
  if not adapter then
    if not (opts and opts.open) then
      utils.err("[diffview] Open a diffview first.")
      return
    end
    require("diffview").open(opts.open)
    local tries = 0
    local function retry()
      if lib.get_current_view() then
        M.pick()
      elseif tries < 30 then
        tries = tries + 1
        vim.defer_fn(retry, 100)
      end
    end
    vim.defer_fn(retry, 100)
    return
  end

  local doc = comments.get_doc(store.path_for(adapter))
  local threads = vim.list_slice(doc.threads)
  if #threads == 0 then
    utils.info("[diffview] No comment threads in this review.")
    return
  end

  local status_rank = { open = 1, applied = 2, resolved = 3 }
  table.sort(threads, function(x, y)
    local rx, ry = status_rank[x.status] or 9, status_rank[y.status] or 9
    if rx ~= ry then return rx < ry end
    if x.anchor.path ~= y.anchor.path then return x.anchor.path < y.anchor.path end
    return x.anchor.line < y.anchor.line
  end)

  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if not has_telescope then
    vim.ui.select(threads, {
      prompt = "Review threads",
      format_item = thread_label,
    }, function(choice)
      if choice then goto_thread(choice) end
    end)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")
  local t_actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Review threads",
    finder = finders.new_table({
      results = threads,
      entry_maker = function(thread)
        local label = thread_label(thread)
        return { value = thread, display = label, ordinal = label }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Thread",
      define_preview = function(self, entry)
        -- Same content the reading float shows — one source of truth.
        local lines = require("diffview.comments.float").lines(entry.value)
        api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      t_actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        t_actions.close(prompt_bufnr)
        if entry then goto_thread(entry.value) end
      end)
      return true
    end,
  }):find()
end

return M
