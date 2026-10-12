-- Diff-scoped fuzzy finders. On a 60-file agentic diff, paging through the
-- file panel doesn't scale — these let you jump straight to a file, or to a
-- changed LINE anywhere in the review, by typing a few characters.
--
--   pick_file()  — fuzzy-find among the files of the current view, with the
--                  file's patch as the preview.
--   pick_line()  — fuzzy-find across every added/deleted line of the whole
--                  view ("where did the agent touch `retry_policy`?"), landing
--                  on the exact rendered row in the unified diff.
--   pick_commit() — fuzzy-find a commit (or mark several for a range) and open
--                  it, rows coloured the way lazygit colours its commit list.
--
-- fzf-lua when available; vim.ui.select otherwise so both work in a bare
-- config. Loaded lazily from actions so fzf-lua never loads until the first
-- pick.

local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView =
  lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local authors = lazy.require("diffview.authors") ---@module "diffview.authors"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local navigate = lazy.require("diffview.navigate") ---@module "diffview.navigate"
local trunk = lazy.require("diffview.trunk") ---@module "diffview.trunk"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

local M = {}

--#region view helpers

---The view to pick in. With `opts.open`, opens a diffview first (and retries
---the picker once it is ready) so a global keymap can be a one-liner: `true`
---opens the branch diff, a string or list are rev args as for :DiffviewOpen.
---@param opts? { open?: true|string|string[] }
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

  navigate.when_files_ready(function() require("diffview").open_for_picker(opts.open) end, retry)
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
    "-c",
    "core.quotePath=false",
    "diff",
    "--no-color",
    "--no-ext-diff",
    "-M",
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
  for _, l in ipairs(content) do
    -- readfile() turns NUL bytes into "\n" inside an item: binary content has
    -- no lines to list, and a "\n" in a row breaks fzf and set_lines.
    if l:find("\n", 1, true) then
      return { out[1], ("Binary files /dev/null and b/%s differ"):format(entry.path) }
    end
    out[#out + 1] = "+" .. l
  end
  return out
end

---Patch text for a single entry, as shown by the file previewer.
---@param entry FileEntry
---@param cb fun(lines: string[])
local function entry_patch(entry, cb)
  local args = entry_diff_args(entry)
  if not args then return cb(untracked_patch(entry)) end
  local paths = { "--", entry.path }
  if entry.oldpath and entry.oldpath ~= entry.path then paths[#paths + 1] = entry.oldpath end
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

---@param entry FileEntry
---@return string status, string path, string rest Rest keeps its leading spaces.
local function file_fields(entry)
  local stats = entry.stats or {}
  local counts = ""
  if stats.additions or stats.deletions then
    counts = ("  +%d -%d"):format(stats.additions or 0, stats.deletions or 0)
  end
  local kind = entry.kind == "staged" and " [staged]"
    or entry.kind == "conflicting" and " [conflict]"
    or ""
  return entry.status or " ", entry.path, kind .. counts
end

---@param entry FileEntry
---@return string
local function file_label(entry) return ("%s %s%s"):format(file_fields(entry)) end

---@param l diffview.ChangedLine
---@return string
local function line_label(l) return ("%s:%d %s %s"):format(l.path, l.lnum, l.kind, vim.trim(l.text)) end

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

--#region fzf-lua

-- fzf-lua's own field separator: renders as a space, never typed in text.
local SEP = "\u{2002}"

---@param i integer
---@return string
local function fzf_row(i, ...) return table.concat({ i, ... }, SEP) end

---@param hl string
---@param s string
---@return string
local function ansi(hl, s) return (require("fzf-lua.utils").ansi_from_hl(hl, s)) end

---@class diffview.FzfPick
---@field title string Label of the prompt box.
---@field items any[]
---@field fields? fun(item: any): ... Row text of an item, split into fzf fields.
---@field contents? function fzf-lua content of `fzf_row`s, instead of `fields`.
---@field nth? string Fields that matching sees (the index never is).
---@field multi? boolean
---@field enter_prefix? string fzf actions run on <CR> before accepting.
---@field preview_title fun(item: any): string
---@field preview fun(item: any, show: fun(lines: string[], ft: string, row?: integer))
---@field on_select fun(items: any[]) Picked items in list order.

---An fzf-lua picker over `o.items`. Every row leads with its item's index,
---hidden and never matched, so the preview and <CR> map rows back to items.
---The preview is a real buffer (fzf-lua's builtin previewer) that `o.preview`
---fills, possibly later: a fill for a row the cursor has left is dropped.
---@param o diffview.FzfPick
function M.fzf_pick(o)
  local function item_of(line) return o.items[tonumber(line:match("^%d+"))] end

  local Previewer = require("fzf-lua.previewer.builtin").base:extend()
  function Previewer:populate_preview_buf(entry_str)
    local item = item_of(entry_str)
    if not item then return end
    local buf = self:get_tmp_buffer()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "…" })
    self:set_preview_buf(buf)
    self.win:update_preview_title(" " .. o.preview_title(item) .. " ")
    o.preview(item, function(lines, ft, row)
      if self.preview_bufnr ~= buf or not api.nvim_buf_is_valid(buf) then return end
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = ft
      local win = self.win.preview_winid
      if row and api.nvim_win_is_valid(win) then
        api.nvim_win_set_cursor(win, { row, 0 })
        api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
      end
      self.win:update_preview_scrollbar()
    end)
  end

  local contents = o.contents
  if not contents then
    contents = {}
    for i, item in ipairs(o.items) do
      contents[i] = fzf_row(i, o.fields(item))
    end
  end

  require("fzf-lua").fzf_exec(contents, {
    previewer = { _ctor = function() return Previewer end },
    fzf_opts = {
      ["--input-label"] = " " .. o.title .. " ",
      ["--delimiter"] = SEP,
      ["--with-nth"] = "2..",
      ["--nth"] = o.nth,
      ["--multi"] = o.multi,
    },
    actions = {
      enter = {
        prefix = o.enter_prefix,
        fn = function(selected)
          local index = {}
          for _, line in ipairs(selected) do
            index[#index + 1] = tonumber(line:match("^%d+"))
          end
          table.sort(index)
          local picked = vim.tbl_map(function(i) return o.items[i] end, index)
          if #picked > 0 then o.on_select(picked) end
        end,
      },
    },
  })
end

--#endregion

--#region commit list

-- `%H` rather than `%h`: the status sets below come from rev-list, which prints
-- full hashes. No pathspec: `-- .` made git diff every commit's tree (2-4x
-- slower) and history simplification hid merge commits lazygit shows.
local LOG_ARGS = { "log", "--topo-order", "--no-show-signature", "--format=%H%x09%aN%x09%s" }

---@param args string[]
---@return string[]
local function git_cmd(args) return utils.vec_join(config.get_config().git_cmd, args) end

---@param line string
---@return string? hash, string author, string subject
local function parse_commit(line) return line:match("^(%x+)\t([^\t]*)\t(.*)$") end

---Hash sets of the commits not on main, and of those not pushed either, from
---two parallel `git rev-list`s. A set is nil when git failed.
---
---"On main" means on the remote trunk only (trunk.remote_refs, as lazygit's
---main branches): a local main with unpushed commits must not turn them green.
-----ignore-missing skips whichever ref doesn't exist.
---@param cwd string
---@param cb fun(unmerged?: table<string, true>, unpushed?: table<string, true>)
local function load_commit_status(cwd, cb)
  local sets, pending = {}, 2
  local function run(key, exclude, fallback)
    local cmd = git_cmd(
      utils.vec_join("rev-list", "--ignore-missing", "HEAD", "--not", exclude, trunk.remote_refs)
    )
    vim.system(cmd, { cwd = cwd, text = true }, function(out)
      if out.code ~= 0 and fallback then return run(key, fallback) end
      if out.code == 0 then
        local set = {}
        for hash in out.stdout:gmatch("%x+") do
          set[hash] = true
        end
        sets[key] = set
      end
      pending = pending - 1
      if pending == 0 then vim.schedule(function() cb(sets.unmerged, sets.unpushed) end) end
    end)
  end
  run("unmerged", {})
  -- Pushed = on the upstream, as lazygit has it. `@{upstream}` is fatal when
  -- unset (a branch never pushed, detached HEAD) even with --ignore-missing;
  -- then fall back to "on any remote", so a new branch's base commits aren't
  -- red when they are already out there. lazygit shows those all yellow.
  run("unpushed", { "@{upstream}" }, { "--remotes" })
end

---Open one commit, or the range spanning several.
---@param cwd string
---@param hashes string[] Newest first.
local function open_commits(cwd, hashes)
  if #hashes == 1 then
    require("diffview").open({ hashes[1] .. "^!" })
    return
  end

  local function git(args)
    local out = vim.system(git_cmd(args), { cwd = cwd, text = true }):wait()
    return out.code == 0 and vim.split(out.stdout, "\n", { trimempty = true }) or {}
  end

  -- `A..B` excludes A's own changes, so diff from the oldest marked commit's
  -- PARENT — otherwise it silently drops out and marking N commits only ever
  -- shows N-1.
  local base = git({ "rev-parse", "--quiet", "--verify", hashes[#hashes] .. "^" })[1]
  if not base then
    -- Root commit has no parent: diff against the empty tree. Asking git for
    -- it keeps this correct in sha256 repos too.
    base = git({ "hash-object", "-t", "tree", "/dev/null" })[1]
  end
  require("diffview").open({ base .. ".." .. hashes[1] })
end

--#endregion

--#region pickers

---Fuzzy-find a file of the current view and open it.
---@param opts? { open?: true|string|string[] } With no diffview open, open one
---first — `true` for the branch diff, else rev args like "main...HEAD" — and
---pick once it's ready.
function M.pick_file(opts)
  local view = current_view(opts, function() M.pick_file() end)
  if not view then return end

  local files = view_files(view)
  if #files == 0 then
    utils.info("[diffview] No files in this view.")
    return
  end

  if not pcall(require, "fzf-lua") then
    vim.ui.select(files, { prompt = "Diff files", format_item = file_label }, function(choice)
      if choice then goto_entry(view, choice) end
    end)
    return
  end

  local patch_cache = {} ---@type table<FileEntry, string[]>

  M.fzf_pick({
    title = "Diff files",
    items = files,
    fields = function(file)
      local status, path, rest = file_fields(file)
      return status, path, vim.trim(rest)
    end,
    nth = "2",
    preview_title = function(file) return file.path end,
    preview = function(file, show)
      if patch_cache[file] then return show(patch_cache[file], "diff") end
      entry_patch(file, function(lines)
        patch_cache[file] = lines
        show(lines, "diff")
      end)
    end,
    on_select = function(picked) goto_entry(view, picked[1]) end,
  })
end

---Fuzzy-find across every added / deleted line of the current diff and jump
---to it. Deleted lines land on their `-` row in the unified buffer.
---@param opts? { open?: true|string|string[] } See pick_file.
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

    if not pcall(require, "fzf-lua") then
      vim.ui.select(
        changes,
        { prompt = "Changed lines", format_item = line_label },
        function(choice)
          if choice then jump(choice) end
        end
      )
      return
    end

    local signs = {
      ["+"] = ansi("DiffviewUnifiedSignAdd", "+"),
      ["-"] = ansi("DiffviewUnifiedSignDel", "-"),
    }
    local patch_cache = {} ---@type table<string, string[]>

    ---@param l diffview.ChangedLine
    ---@param lines string[]
    ---@param show fun(lines: string[], ft: string, row?: integer)
    local function show_at(l, lines, show) show(lines, "diff", patch_row_of(lines, l)) end

    M.fzf_pick({
      title = "Changed lines",
      items = changes,
      fields = function(l)
        return signs[l.kind], ("%s:%d  %s"):format(l.path, l.lnum, vim.trim(l.text))
      end,
      nth = "2",
      preview_title = function(l) return l.path end,
      preview = function(l, show)
        if patch_cache[l.path] then return show_at(l, patch_cache[l.path], show) end
        local file = files_by_path[l.path]
        if not file then return end
        entry_patch(file, function(lines)
          patch_cache[l.path] = lines
          show_at(l, lines, show)
        end)
      end,
      on_select = function(picked) jump(picked[1]) end,
    })
  end)
end

---Fuzzy-find a commit and open it in a view. Mark commits with <Tab> (or mark
---one and <CR> on another) to diff the range they span.
---
---Rows read like lazygit's commit list: the hash is green when the commit is
---on main, yellow when pushed but not on main, red when not pushed; then the
---author's initials in lazygit's colour for that author. The status comes from
---two small rev-lists started alongside the log.
function M.pick_commit()
  local cwd = vim.fs.root(vim.uv.cwd(), ".git")
  if not cwd then
    utils.err("[diffview] Not inside a git repository.")
    return
  end

  if not pcall(require, "fzf-lua") then
    vim.system(
      git_cmd(LOG_ARGS),
      { cwd = cwd, text = true },
      vim.schedule_wrap(function(out)
        local commits = {}
        for _, line in ipairs(vim.split(out.stdout or "", "\n", { trimempty = true })) do
          local hash, _, subject = parse_commit(line)
          if hash then commits[#commits + 1] = { hash = hash, subject = subject } end
        end
        vim.ui.select(commits, {
          prompt = "Commits",
          format_item = function(c) return c.hash:sub(1, 8) .. " " .. c.subject end,
        }, function(choice)
          if choice then open_commits(cwd, { choice.hash }) end
        end)
      end)
    )
    return
  end

  local hashes = {} ---@type string[]
  local rows ---@type string[]?
  local write ---@type fun(data?: string[])?
  local log ---@type string[]?
  local status ---@type { unmerged?: table<string, true>, unpushed?: table<string, true> }?

  local function emit()
    if not (rows and write) then return end
    write(rows)
    write(nil)
    write = nil
  end

  ---@param hash string
  ---@return string?
  local function hash_hl(hash)
    if not (status.unmerged and status.unpushed) then return end
    if not status.unmerged[hash] then return "DiffviewCommitMerged" end
    return status.unpushed[hash] and "DiffviewCommitUnpushed" or "DiffviewCommitPushed"
  end

  -- Every row waits for both the log and the status, so it is drawn once, in
  -- its colour. Both start before the picker, so fzf's own startup overlaps
  -- them.
  local function build()
    if not (log and status) then return end
    local paint, author_cell = {}, {}
    for _, hl in ipairs({ "DiffviewCommitMerged", "DiffviewCommitPushed", "DiffviewCommitUnpushed" }) do
      paint[hl] = select(3, require("fzf-lua.utils").ansi_from_hl(hl, ""))
    end
    rows = {}
    for _, line in ipairs(log) do
      local hash, author, subject = parse_commit(line)
      if hash then
        if subject == "" then subject = "<empty commit message>" end
        if not author_cell[author] then
          local a = authors.get(author)
          author_cell[author] =
            ansi(a.hl, a.initials .. (" "):rep(2 - api.nvim_strwidth(a.initials)))
        end
        local short, p = hash:sub(1, 8), paint[hash_hl(hash)]
        hashes[#hashes + 1] = hash
        rows[#rows + 1] = fzf_row(#hashes, p and p(short) or short, author_cell[author], subject)
      end
    end
    emit()
  end

  vim.system(
    git_cmd(LOG_ARGS),
    { cwd = cwd, text = true },
    vim.schedule_wrap(function(out)
      log = vim.split(out.stdout or "", "\n", { trimempty = true })
      build()
    end)
  )
  load_commit_status(cwd, function(unmerged, unpushed)
    status = { unmerged = unmerged, unpushed = unpushed }
    build()
  end)

  local patch_cache = {} ---@type table<string, string[]>

  M.fzf_pick({
    title = "Git Commits",
    items = hashes,
    -- Called again by fzf-lua's resume.
    contents = function(_, w)
      write = w
      emit()
    end,
    -- The short hash and the subject only: 40 hex chars would let fuzzy
    -- queries match inside hashes.
    nth = "1,3",
    multi = true,
    -- Marking one commit with <Tab> and pressing <CR> on another means "diff
    -- these two": with at most one marked, the hovered one counts in too.
    enter_prefix = 'transform([ "$FZF_SELECT_COUNT" -gt 1 ] || echo select)',
    preview_title = function(hash) return hash:sub(1, 8) end,
    preview = function(hash, show)
      if patch_cache[hash] then return show(patch_cache[hash], "diff") end
      local cmd = git_cmd({
        "show",
        "--format=",
        "--diff-merges=first-parent",
        "--no-color",
        "--no-ext-diff",
        hash,
      })
      vim.system(
        cmd,
        { cwd = cwd, text = true },
        vim.schedule_wrap(function(out)
          patch_cache[hash] = vim.split(out.stdout or "", "\n", { trimempty = true })
          show(patch_cache[hash], "diff")
        end)
      )
    end,
    -- Newest first by list position: the log is --topo-order, so a commit
    -- always sits above its ancestors. Commit dates can't order them — a
    -- rebase stamps every rebased commit with the same second.
    on_select = function(picked) open_commits(cwd, picked) end,
  })
end

--#endregion

return M
