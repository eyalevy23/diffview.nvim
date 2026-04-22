local async = require("diffview.async")
local lazy = require("diffview.lazy")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Window = require("diffview.scene.window").Window
local oop = require("diffview.oop")

local diff_mod = require("diffview.diff")
local Diff = diff_mod.Diff
local EditToken = diff_mod.EditToken

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

  -- Compute available text width once for virtual line wrapping
  local win_width = api.nvim_win_get_width(self.b.id)
  local textoff = vim.fn.getwininfo(self.b.id)[1].textoff or 0
  local text_width = math.max(1, win_width - textoff)

  -- Tokenize a line into runs of word chars, runs of whitespace, and single
  -- "other" chars (punctuation, multi-byte). Returns parallel arrays of token
  -- strings plus 0-indexed byte offsets [start, end_excl) for each token.
  local function tokenize(s)
    local tokens, byte_starts, byte_ends_excl = {}, {}, {}
    local len = #s
    local i = 1

    local function utf8_len(byte)
      if byte < 0x80 then return 1
      elseif byte < 0xC0 then return 1
      elseif byte < 0xE0 then return 2
      elseif byte < 0xF0 then return 3
      elseif byte < 0xF8 then return 4
      else return 1 end
    end

    local function kind(byte)
      if (byte >= 0x30 and byte <= 0x39)
        or (byte >= 0x41 and byte <= 0x5A)
        or (byte >= 0x61 and byte <= 0x7A)
        or byte == 0x5F then return "word" end
      if byte == 0x20 or byte == 0x09 then return "space" end
      if byte < 0x80 then return "other" end
      return "utf8"
    end

    while i <= len do
      local b = s:byte(i)
      local k = kind(b)
      local start = i - 1

      if k == "word" or k == "space" then
        local j = i + 1
        while j <= len and kind(s:byte(j)) == k do
          j = j + 1
        end
        tokens[#tokens + 1] = s:sub(i, j - 1)
        byte_starts[#byte_starts + 1] = start
        byte_ends_excl[#byte_ends_excl + 1] = j - 1
        i = j
      else
        local clen = utf8_len(b)
        local j = i + clen
        if j > len + 1 then j = len + 1 end
        tokens[#tokens + 1] = s:sub(i, j - 1)
        byte_starts[#byte_starts + 1] = start
        byte_ends_excl[#byte_ends_excl + 1] = j - 1
        i = j
      end
    end

    return { tokens = tokens, byte_starts = byte_starts, byte_ends_excl = byte_ends_excl }
  end

  -- Run Myers on two token arrays. Returns a result table with:
  --   ranges_a, ranges_b      -- coalesced { byte_start, byte_end_excl } lists
  --   changed_chars_a/b       -- bytes covered by deletes/replaces on each side
  --   total_chars_a/b         -- total byte length of each side
  --   similarity              -- noop_count / max(#tok_a, #tok_b)
  local function diff_tokens(tok_a, tok_b)
    local d = Diff(tok_a.tokens, tok_b.tokens)
    local script = d:create_edit_script()

    local ranges_a, ranges_b = {}, {}
    local cur_a_s, cur_a_e, cur_b_s, cur_b_e
    local function flush_a()
      if cur_a_s then
        ranges_a[#ranges_a + 1] = { cur_a_s, cur_a_e }
        cur_a_s, cur_a_e = nil, nil
      end
    end
    local function flush_b()
      if cur_b_s then
        ranges_b[#ranges_b + 1] = { cur_b_s, cur_b_e }
        cur_b_s, cur_b_e = nil, nil
      end
    end

    local ai, bi = 1, 1
    local noop = 0
    local changed_a, changed_b = 0, 0

    for _, op in ipairs(script) do
      if op == EditToken.NOOP then
        flush_a(); flush_b()
        noop = noop + 1
        ai, bi = ai + 1, bi + 1
      elseif op == EditToken.DELETE then
        local s, e = tok_a.byte_starts[ai], tok_a.byte_ends_excl[ai]
        if cur_a_s then cur_a_e = e else cur_a_s, cur_a_e = s, e end
        flush_b()
        changed_a = changed_a + (e - s)
        ai = ai + 1
      elseif op == EditToken.INSERT then
        local s, e = tok_b.byte_starts[bi], tok_b.byte_ends_excl[bi]
        if cur_b_s then cur_b_e = e else cur_b_s, cur_b_e = s, e end
        flush_a()
        changed_b = changed_b + (e - s)
        bi = bi + 1
      elseif op == EditToken.REPLACE then
        local sa, ea = tok_a.byte_starts[ai], tok_a.byte_ends_excl[ai]
        if cur_a_s then cur_a_e = ea else cur_a_s, cur_a_e = sa, ea end
        local sb, eb = tok_b.byte_starts[bi], tok_b.byte_ends_excl[bi]
        if cur_b_s then cur_b_e = eb else cur_b_s, cur_b_e = sb, eb end
        changed_a = changed_a + (ea - sa)
        changed_b = changed_b + (eb - sb)
        ai, bi = ai + 1, bi + 1
      end
    end
    flush_a(); flush_b()

    local total_a = (#tok_a.byte_ends_excl > 0) and tok_a.byte_ends_excl[#tok_a.byte_ends_excl] or 0
    local total_b = (#tok_b.byte_ends_excl > 0) and tok_b.byte_ends_excl[#tok_b.byte_ends_excl] or 0
    local denom = math.max(#tok_a.tokens, #tok_b.tokens, 1)

    return {
      ranges_a = ranges_a,
      ranges_b = ranges_b,
      changed_chars_a = changed_a,
      changed_chars_b = changed_b,
      total_chars_a = total_a,
      total_chars_b = total_b,
      similarity = noop / denom,
    }
  end

  -- Filter a diff result through the change-ratio threshold. If too much of
  -- either line changed (>0.65), the per-token highlights are useless noise --
  -- return nil so the caller falls back to plain add/delete colors.
  local function ratio_filter(result)
    if not result then return nil, nil end
    local ra = result.total_chars_a > 0 and result.changed_chars_a / result.total_chars_a or 0
    local rb = result.total_chars_b > 0 and result.changed_chars_b / result.total_chars_b or 0
    if ra > 0.65 or rb > 0.65 then return nil, nil end
    return result.ranges_a, result.ranges_b
  end

  -- Greedily pair deleted lines with added lines by similarity score within a
  -- single hunk. Returns a list of { oi, ni, result } where oi/ni are absolute
  -- line indices and result is the cached diff_tokens output.
  local function pair_lines(old_toks, new_toks, old_lines, new_lines,
                            old_start, old_count, new_start, new_count)
    local candidates = {}
    for oi = old_start, old_start + old_count - 1 do
      local toa = old_toks[oi]
      if toa then
        local la = old_lines[oi]
        for ni = new_start, new_start + new_count - 1 do
          local tob = new_toks[ni]
          if tob then
            local lb = new_lines[ni]
            if la ~= lb
              and #la > 0 and #lb > 0
              and #la <= 1000 and #lb <= 1000
              and #toa.tokens <= 400 and #tob.tokens <= 400
            then
              local res = diff_tokens(toa, tob)
              if res.similarity >= 0.30 then
                candidates[#candidates + 1] = {
                  oi = oi, ni = ni, similarity = res.similarity, result = res,
                }
              end
            end
          end
        end
      end
    end

    table.sort(candidates, function(a, b) return a.similarity > b.similarity end)

    local taken_old, taken_new = {}, {}
    local pairs_list = {}
    for _, c in ipairs(candidates) do
      if not taken_old[c.oi] and not taken_new[c.ni] then
        taken_old[c.oi] = true
        taken_new[c.ni] = true
        pairs_list[#pairs_list + 1] = c
      end
    end
    return pairs_list
  end

  -- Build a virt_line by splitting the line around a list of 0-indexed
  -- { byte_start, byte_end_excl } change ranges. Unchanged spans get
  -- DiffviewDiffDelete; changed spans get DiffviewDiffDeleteText.
  local function make_delete_virt_chunks(line, change_ranges)
    if not change_ranges or #change_ranges == 0 then
      return { { line, "DiffviewDiffDelete" } }
    end
    local chunks = {}
    local pos = 0
    for _, range in ipairs(change_ranges) do
      local cs, ce = range[1], range[2]
      if cs > pos then
        chunks[#chunks + 1] = { line:sub(pos + 1, cs), "DiffviewDiffDelete" }
      end
      if ce > cs then
        chunks[#chunks + 1] = { line:sub(cs + 1, ce), "DiffviewDiffDeleteText" }
      end
      pos = ce
    end
    if pos < #line then
      chunks[#chunks + 1] = { line:sub(pos + 1), "DiffviewDiffDelete" }
    end
    return chunks
  end

  -- Wrap a list of highlight chunks into multiple virt_lines that fit text_width
  local function wrap_chunks(chunks, tw)
    local lines = {}
    local cur = {}
    local cur_w = 0
    for _, chunk in ipairs(chunks) do
      local text, hl = chunk[1], chunk[2]
      local cw = vim.fn.strdisplaywidth(text)
      if cur_w + cw <= tw then
        cur[#cur + 1] = { text, hl }
        cur_w = cur_w + cw
      else
        -- Split this chunk across lines
        local total_chars = vim.fn.strchars(text)
        local char_pos = 0
        while char_pos < total_chars do
          local remaining = tw - cur_w
          if remaining <= 0 then
            lines[#lines + 1] = cur
            cur = {}
            cur_w = 0
            remaining = tw
          end
          local lo, hi = 1, total_chars - char_pos
          while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, char_pos, mid)) > remaining then
              hi = mid - 1
            else
              lo = mid
            end
          end
          local part = vim.fn.strcharpart(text, char_pos, lo)
          if vim.fn.strdisplaywidth(part) == 0 then break end
          cur[#cur + 1] = { part, hl }
          cur_w = cur_w + vim.fn.strdisplaywidth(part)
          char_pos = char_pos + lo
        end
      end
    end
    if #cur > 0 then lines[#lines + 1] = cur end
    return lines
  end

  -- Apply highlights in reverse so extmark positions stay valid
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

    -- Tokenize each line in the hunk once; reused for similarity scoring.
    local old_toks, new_toks = {}, {}
    for oi = old_start, old_start + old_count - 1 do
      if oi >= 1 and oi <= #old_lines then
        old_toks[oi] = tokenize(old_lines[oi])
      end
    end
    for ni = new_start, new_start + new_count - 1 do
      if ni >= 1 and ni <= #new_lines then
        new_toks[ni] = tokenize(new_lines[ni])
      end
    end

    -- Pair deleted lines with their best-matching added line by similarity,
    -- then derive intra-line ranges (filtered by change-ratio) keyed by
    -- absolute line index.
    local pairs_list = pair_lines(old_toks, new_toks, old_lines, new_lines,
                                  old_start, old_count, new_start, new_count)
    local range_for_old, range_for_new = {}, {}
    for _, p in ipairs(pairs_list) do
      local ra, rb = ratio_filter(p.result)
      range_for_old[p.oi] = ra
      range_for_new[p.ni] = rb
    end

    if new_count > 0 then
      for j = new_start, new_start + new_count - 1 do
        if j >= 1 and j <= #new_lines then
          local ranges = range_for_new[j]
          api.nvim_buf_set_extmark(buf_b, ns, j - 1, 0, {
            line_hl_group = "DiffviewDiffAdd",
            priority = 50,
          })
          if ranges then
            for _, range in ipairs(ranges) do
              if range[2] > range[1] then
                api.nvim_buf_set_extmark(buf_b, ns, j - 1, range[1], {
                  end_col = range[2],
                  hl_group = "DiffviewDiffText",
                  priority = 51,
                })
              end
            end
          end
        end
      end
    end

    if old_count > 0 then
      local virt_lines = {}

      for j = old_start, old_start + old_count - 1 do
        if j >= 1 and j <= #old_lines then
          local line = old_lines[j]
          local chunks = make_delete_virt_chunks(line, range_for_old[j])

          -- Wrap if needed
          local total_w = vim.fn.strdisplaywidth(line)
          if total_w > text_width then
            local wrapped = wrap_chunks(chunks, text_width)
            for _, wl in ipairs(wrapped) do
              virt_lines[#virt_lines + 1] = wl
            end
          else
            virt_lines[#virt_lines + 1] = chunks
          end
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

---Clear inline diff extmarks and folds from the buffer
---@private
function Diff1Inline:_clear_inline(buf)
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(winid) and api.nvim_win_get_buf(winid) == buf then
        api.nvim_win_call(winid, function()
          pcall(vim.cmd, "norm! zE")
        end)
      end
    end
  end
end

---@override
function Diff1Inline:detach_files()
  self:_clear_inline(self.b.file and self.b.file.bufnr)
  Diff2.detach_files(self)
end

---@override
function Diff1Inline:destroy()
  self:_clear_inline(self.b.file and self.b.file.bufnr)
  Diff2.destroy(self)
end

---Override sync_scroll to be a no-op (single window, nothing to sync)
function Diff1Inline:sync_scroll() end

M.Diff1Inline = Diff1Inline
return M
