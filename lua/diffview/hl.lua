local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local web_devicons
local icon_cache = {}

local M = {}

---@alias hl.HiValue<T> T|"NONE"

---@class hl.HiSpec
---@field fg         hl.HiValue<string>
---@field bg         hl.HiValue<string>
---@field sp         hl.HiValue<string>
---@field style      hl.HiValue<string>
---@field ctermfg    hl.HiValue<integer>
---@field ctermbg    hl.HiValue<integer>
---@field cterm      hl.HiValue<string>
---@field blend      hl.HiValue<integer>
---@field default    hl.HiValue<boolean> Only set values if the hl group is cleared.
---@field link       string|-1
---@field explicit   boolean All undefined fields will be cleared from the hl group.

---@class hl.HiLinkSpec
---@field force boolean
---@field default boolean
---@field clear boolean

---@class hl.HlData
---@field link string|integer
---@field fg integer Foreground color integer
---@field bg integer Background color integer
---@field sp integer Special color integer
---@field x_fg string Foreground color hex string
---@field x_bg string Bakground color hex string
---@field x_sp string Special color hex string
---@field bold boolean
---@field italic boolean
---@field underline boolean
---@field underlineline boolean
---@field undercurl boolean
---@field underdash boolean
---@field underdot boolean
---@field strikethrough boolean
---@field standout boolean
---@field reverse boolean
---@field blend integer
---@field default boolean

---@alias hl.HlAttrValue integer|boolean

local HAS_NVIM_0_8 = vim.fn.has("nvim-0.8") == 1
local HAS_NVIM_0_9 = vim.fn.has("nvim-0.9") == 1

---@enum HlAttribute
M.HlAttribute = {
  fg = 1,
  bg = 2,
  sp = 3,
  x_fg = 4,
  x_bg = 5,
  x_sp = 6,
  bold = 7,
  italic = 8,
  underline = 9,
  underlineline = 10,
  undercurl = 11,
  underdash = 12,
  underdot = 13,
  strikethrough = 14,
  standout = 15,
  reverse = 16,
  blend = 17,
}

local style_attrs = {
  "bold",
  "italic",
  "underline",
  "underlineline",
  "undercurl",
  "underdash",
  "underdot",
  "strikethrough",
  "standout",
  "reverse",
}

-- NOTE: Some atrtibutes have been renamed in v0.8.0
if HAS_NVIM_0_8 then
  M.HlAttribute.underdashed = M.HlAttribute.underdash
  M.HlAttribute.underdash = nil

  M.HlAttribute.underdotted = M.HlAttribute.underdot
  M.HlAttribute.underdot = nil

  M.HlAttribute.underdouble = M.HlAttribute.underlineline
  M.HlAttribute.underlineline = nil

  style_attrs = {
    "bold",
    "italic",
    "underline",
    "underdouble",
    "undercurl",
    "underdashed",
    "underdotted",
    "strikethrough",
    "standout",
    "reverse",
  }
end

utils.add_reverse_lookup(M.HlAttribute)
utils.add_reverse_lookup(style_attrs)

---@param name string Syntax group name.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return hl.HlData?
function M.get_hl(name, no_trans)
  local hl

  if no_trans then
    if HAS_NVIM_0_9 then
      hl = api.nvim_get_hl(0, { name = name, link = true })
    else
      hl = api.nvim__get_hl_defs(0)[name]
    end
  else
    local id = api.nvim_get_hl_id_by_name(name)

    if id then
      if HAS_NVIM_0_9 then
        hl = api.nvim_get_hl(0, { id = id, link = false })
      else
        hl = api.nvim_get_hl_by_id(id, true)
      end
    end
  end

  if hl then
    if not HAS_NVIM_0_9 then
      -- Handle renames
      if hl.foreground then hl.fg = hl.foreground; hl.foreground = nil end
      if hl.background then hl.bg = hl.background; hl.background = nil end
      if hl.special then hl.sp = hl.special; hl.special = nil end
    end

    if hl.fg then hl.x_fg = string.format("#%06x", hl.fg) end
    if hl.bg then hl.x_bg = string.format("#%06x", hl.bg) end
    if hl.sp then hl.x_sp = string.format("#%06x", hl.sp) end

    return hl
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_fg(groups, no_trans)
  return M.get_displayed(groups, "fg", no_trans)
end

---The color a group actually paints as `which` ("fg"|"bg"). Unlike the raw
---attribute, this honors `reverse`: a reversed group (common for diff groups
---in gruvbox-style themes) shows its fg as the background and vice versa —
---colors derived from the raw attribute would come out inverted.
---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param which "fg"|"bg"
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_displayed(groups, which, no_trans)
  no_trans = not not no_trans

  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local hl = M.get_hl(group, no_trans)
    if hl then
      local flip = hl.reverse
      local v
      if which == "bg" then
        v = flip and hl.x_fg or hl.x_bg
      else
        v = flip and hl.x_bg or hl.x_fg
      end
      if v then return v end
    end
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_bg(groups, no_trans)
  return M.get_displayed(groups, "bg", no_trans)
end

---@param spec hl.HiSpec
---@return hl.HlData
function M.hi_spec_to_def_map(spec)
  ---@type hl.HlData
  local res = {}
  local fields = { "fg", "bg", "sp", "ctermfg", "ctermbg", "default", "link" }

  for _, field in ipairs(fields) do
    res[field] = spec[field]
  end

  if spec.style then
    local spec_attrs = utils.add_reverse_lookup(vim.split(spec.style, ","))

    for _, attr in ipairs(style_attrs) do
      res[attr] = spec_attrs[attr] ~= nil
    end
  end

  return res
end

---@param groups string|string[] Syntax group name or a list of group names.
---@param opt hl.HiSpec
function M.hi(groups, opt)
  if type(groups) ~= "table" then groups = { groups } end

  for _, group in ipairs(groups) do
    local def_spec

    if opt.explicit then
      def_spec = M.hi_spec_to_def_map(opt)
    else
      def_spec = M.hi_spec_to_def_map(
        vim.tbl_extend("force", M.get_hl(group, true) or {}, opt)
      )
    end

    for k, v in pairs(def_spec) do
      if v == "NONE" then
        def_spec[k] = nil
      end
    end

    if not HAS_NVIM_0_9 and def_spec.link then
      -- Pre 0.9 `nvim_set_hl()` could not set other attributes in combination
      -- with `link`. Furthermore, setting non-link attributes would clear the
      -- link, but this does *not* happen if you set the other attributes first
      -- (???). However, if the value of `link` is `-1`, the group will be
      -- cleared regardless (?????).
      local link = def_spec.link
      def_spec.link = nil

      if not def_spec.default then
        api.nvim_set_hl(0, group, def_spec)
      end

      if link ~= -1 then
        api.nvim_set_hl(0, group, { link = link, default = def_spec.default })
      end
    else
      api.nvim_set_hl(0, group, def_spec)
    end
  end
end

---@param from string|string[] Syntax group name or a list of group names.
---@param to? string Syntax group name. (default: `"NONE"`)
---@param opt? hl.HiLinkSpec
function M.hi_link(from, to, opt)
  if to and tostring(to):upper() == "NONE" then
    ---@diagnostic disable-next-line: cast-local-type
    to = -1
  end

  opt = vim.tbl_extend("keep", opt or {}, {
    force = true,
  }) --[[@as hl.HiLinkSpec ]]

  if type(from) ~= "table" then from = { from } end

  for _, f in ipairs(from) do
    if opt.clear then
      if not HAS_NVIM_0_9 then
        -- Pre 0.9 `nvim_set_hl()` did not clear other attributes when `link` was set.
        api.nvim_set_hl(0, f, {})
      end

      api.nvim_set_hl(0, f, { default = opt.default, link = to })

    else
      -- When `clear` is not set; use our `hi()` function such that other
      -- attributes are not affected.
      M.hi(f, { default = opt.default, link = to })
    end
  end
end

function M.get_file_icon(name, ext, render_data, line_idx, offset)
  if not config.get_config().use_icons then return "" end

  if not web_devicons then
    local ok
    ok, web_devicons = pcall(require, "nvim-web-devicons")

    if not ok then
      config.get_config().use_icons = false
      utils.warn(
        "nvim-web-devicons is required to use file icons! "
          .. "Set `use_icons = false` in your config to stop seeing this message."
      )

      return ""
    end
  end

  local icon, hl
  local icon_key = (name or "") .. "|&|" .. (ext or "")

  if icon_cache[icon_key] then
    icon, hl = unpack(icon_cache[icon_key])
  else
    icon, hl = web_devicons.get_icon(name, ext, { default = true })
    icon_cache[icon_key] = { icon, hl }
  end

  if icon then
    if hl and render_data then
      render_data:add_hl(hl, line_idx, offset, offset + string.len(icon) + 1)
    end

    return icon .. " ", hl
  end

  return ""
end

local git_status_hl_map = {
  ["A"] = "DiffviewStatusAdded",
  ["?"] = "DiffviewStatusUntracked",
  ["M"] = "DiffviewStatusModified",
  ["R"] = "DiffviewStatusRenamed",
  ["C"] = "DiffviewStatusCopied",
  ["T"] = "DiffviewStatusTypeChanged",
  ["U"] = "DiffviewStatusUnmerged",
  ["X"] = "DiffviewStatusUnknown",
  ["D"] = "DiffviewStatusDeleted",
  ["B"] = "DiffviewStatusBroken",
  ["!"] = "DiffviewStatusIgnored",
}

function M.get_git_hl(status)
  return git_status_hl_map[status]
end

function M.get_colors()
  return {
    white = M.get_fg("Normal") or "White",
    red = M.get_fg("Keyword") or "Red",
    green = M.get_fg("Character") or "Green",
    yellow = M.get_fg("PreProc") or "Yellow",
    blue = M.get_fg("Include") or "Blue",
    purple = M.get_fg("Define") or "Purple",
    cyan = M.get_fg("Conditional") or "Cyan",
    dark_red = M.get_fg("Keyword") or "DarkRed",
    orange = M.get_fg("Number") or "Orange",
  }
end

function M.get_hl_groups()
  local colors = M.get_colors()

  return {
    FilePanelTitle = { fg = M.get_fg("Label") or colors.blue, style = "bold" },
    FilePanelCounter = { fg = M.get_fg("Identifier") or colors.purple, style = "bold" },
    FilePanelFileName = { fg = M.get_fg("Normal") or colors.white },
    Dim1 = { fg = M.get_fg("Comment") or colors.white },
    PeekSubject = { fg = M.get_fg("Title") or colors.blue, style = "bold" },
    Primary = { fg = M.get_fg("Function") or "Purple" },
    Secondary = { fg = M.get_fg("String") or "Orange" },
  }
end

M.hl_links = {
  Normal = "Normal",
  NonText = "NonText",
  CursorLine = "CursorLine",
  WinSeparator = "WinSeparator",
  SignColumn = "Normal",
  StatusLine = "StatusLine",
  StatusLineNC = "StatusLineNC",
  EndOfBuffer = "EndOfBuffer",
  FilePanelRootPath = "DiffviewFilePanelTitle",
  FilePanelFileName = "Normal",
  FilePanelSelected = "Type",
  FilePanelPath = "Comment",
  FilePanelInsertions = "diffAdded",
  FilePanelDeletions = "diffRemoved",
  FilePanelConflicts = "DiagnosticSignWarn",
  FolderName = "Directory",
  FolderSign = "PreProc",
  WinBarDir = "DiffviewFilePanelPath",
  WinBarFile = "DiffviewFilePanelFileName",
  WinBarSep = "DiffviewNonText",
  Hash = "Identifier",
  -- pick_commit's hash colours, after lazygit: on main / pushed / not pushed.
  CommitMerged = "diffAdded",
  CommitPushed = "DiagnosticWarn",
  CommitUnpushed = "diffRemoved",
  Reference = "Function",
  ReflogSelector = "Special",
  StatusAdded = "diffAdded",
  StatusUntracked = "diffAdded",
  StatusModified = "diffChanged",
  StatusRenamed = "diffChanged",
  StatusCopied = "diffChanged",
  StatusTypeChange = "diffChanged",
  StatusUnmerged = "diffChanged",
  StatusUnknown = "diffRemoved",
  StatusDeleted = "diffRemoved",
  StatusBroken = "diffRemoved",
  StatusIgnored = "Comment",
  DiffAdd = "DiffAdd",
  DiffDelete = "DiffDelete",
  DiffChange = "DiffChange",
  DiffText = "DiffText",
  UnifiedNumOld = "LineNr",
  UnifiedNumNew = "LineNr",
  UnifiedNumCur = "CursorLineNr",
  UnifiedSignAdd = "diffAdded",
  UnifiedSignDel = "diffRemoved",
  UnifiedFold = "Comment",
  UnifiedFoldIcon = "DiffviewNonText",
  CommentSignHuman = "Identifier",
  CommentSignAI = "Special",
  CommentSignResolved = "Comment",
  CommentSignApplied = "diffAdded",
  CommentCount = "DiffviewFilePanelCounter",
  PeekBody = "Normal",
  PeekBlame = "Comment",
  PeekHint = "NonText",
  PeekBorder = "FloatBorder",
  PeekTitle = "FloatTitle",
}

---Mix `c1` over `c2` (both "#rrggbb") with weight `alpha`. Nil on anything
---that isn't a gui hex color.
---@param c1? string
---@param c2? string
---@param alpha number
---@return string?
function M.blend(c1, c2, alpha)
  local r1, g1, b1 = (c1 or ""):match("^#(%x%x)(%x%x)(%x%x)$")
  local r2, g2, b2 = (c2 or ""):match("^#(%x%x)(%x%x)(%x%x)$")
  if not (r1 and r2) then return nil end

  local function mix(a, b)
    return math.floor(tonumber(a, 16) * alpha + tonumber(b, 16) * (1 - alpha) + 0.5)
  end
  return ("#%02x%02x%02x"):format(mix(r1, r2), mix(g1, g2), mix(b1, b2))
end

---Comment-card groups. The card reads as a slightly elevated surface: its
---background is the normal bg nudged a few percent toward the foreground,
---with border/separator/hint fading into it at decreasing contrast. Every
---in-card group carries the card bg so the surface is seamless. Falls back
---to plain links when gui colors can't be derived (cterm-only setups).
function M.update_comment_hl()
  local fg = M.get_fg("Normal", true)
  local bg = M.get_bg("Normal", true)
  local card = M.blend(fg, bg, 0.05)

  if not card then
    for from, to in pairs({
      CommentCard = "NormalFloat",
      CommentBody = "NormalFloat",
      CommentBorder = "FloatBorder",
      CommentBorderOutdated = "NonText",
      CommentSeparator = "NonText",
      CommentDim = "Comment",
      CommentHint = "NonText",
      CommentAuthorHuman = "Identifier",
      CommentAuthorAI = "Special",
      CommentInlineCode = "Special",
      CommentOutdated = "Comment",
    }) do
      M.hi_link("Diffview" .. from, to, { default = true })
    end
    return
  end

  local dim = M.get_fg("Comment") or M.blend(fg, bg, 0.45)

  local groups = {
    CommentCard = { bg = card },
    CommentBody = { fg = fg, bg = card },
    CommentBorder = { fg = M.blend(fg, bg, 0.18), bg = card },
    CommentBorderOutdated = { fg = M.blend(fg, bg, 0.10), bg = card },
    CommentSeparator = { fg = M.blend(fg, bg, 0.10), bg = card },
    CommentDim = { fg = dim, bg = card },
    CommentHint = { fg = M.blend(fg, bg, 0.35), bg = card },
    CommentAuthorHuman = { fg = M.get_fg("Identifier") or fg, bg = card, style = "bold" },
    CommentAuthorAI = { fg = M.get_fg("Special") or fg, bg = card, style = "bold" },
    CommentInlineCode = { fg = M.get_fg({ "@markup.raw", "String" }) or fg, bg = M.blend(fg, bg, 0.10) },
    CommentOutdated = { fg = dim, bg = card, style = "italic" },
  }

  for name, spec in pairs(groups) do
    spec.explicit = true
    spec.default = true
    M.hi("Diffview" .. name, spec)
  end
end

---Perceptual-enough distance between two "#rrggbb" colors (sum of channel
---deltas, 0..765).
---@param c1 string
---@param c2 string
---@return integer
local function color_distance(c1, c2)
  local r1, g1, b1 = c1:match("^#(%x%x)(%x%x)(%x%x)$")
  local r2, g2, b2 = c2:match("^#(%x%x)(%x%x)(%x%x)$")
  if not (r1 and r2) then return 0 end
  return math.abs(tonumber(r1, 16) - tonumber(r2, 16))
    + math.abs(tonumber(g1, 16) - tonumber(g2, 16))
    + math.abs(tonumber(b1, 16) - tonumber(b2, 16))
end

---Word-level emphasis for one side, derived from that side's line band: the
---band's bg pushed toward the side's accent (green/red), so changed words
---read as a stronger shade of their own line — not the unrelated `DiffText`
---color shared by both sides. Background only: syntax colors show through.
---Falls back to linking `fallback` when no gui color can be derived or the
---result would be indistinguishable from the band (e.g. a band that already
---IS the accent color).
---@param name string Group to define.
---@param band string Line band group.
---@param accents string[] Candidate accent fg groups.
---@param fallback string
local function word_hl(name, band, accents, fallback)
  local band_bg = M.get_bg(band)
  local accent = M.get_fg(accents)
  local word = M.blend(accent, band_bg, 0.28)

  if word and color_distance(word, band_bg) >= 24 then
    M.hi(name, { bg = word, default = true, explicit = true })
  else
    M.hi_link(name, fallback, { default = true })
  end
end

---File-mode gutter markers: the user's gitsigns colors when gitsigns is
---around, so the diff's whole-file view reads like a real buffer. Re-run when
---file mode opens: gitsigns often loads after diffview, so a group first
---linked to the fallback is moved over once GitSigns* exists. A group the
---user defined themselves is left alone.
function M.update_file_sign_hl()
  for name, targets in pairs({
    FileSignAdd = { "GitSignsAdd", "diffAdded" },
    FileSignChange = { "GitSignsChange", "diffChanged" },
    FileSignDelete = { "GitSignsDelete", "diffRemoved" },
  }) do
    local group = "Diffview" .. name
    local cur = api.nvim_get_hl(0, { name = group, link = true })
    if vim.tbl_isempty(cur) or cur.link == targets[2] then
      local target = vim.fn.hlexists(targets[1]) == 1 and targets[1] or targets[2]
      api.nvim_set_hl(0, group, { link = target })
    end
  end
end

---Whether the winbar counts are drawn as a pill (a surface color exists).
M.winbar_pill = false

---One hue per merge side, shared by the winbar pills and the conflict tints
---in the RESULT pane, so a side reads as the same color everywhere.
---@return { Ours: string?, Theirs: string?, Base: string?, Result: string? }
function M.merge_side_colors()
  return {
    Ours = M.get_fg({ "Function", "DiffviewFilePanelTitle", "Title" }),
    Theirs = M.get_fg({ "Constant", "WarningMsg" }),
    Base = M.get_fg({ "Comment", "DiffviewNonText" }),
    Result = M.get_fg({ "DiffviewFilePanelInsertions", "Added", "@diff.plus", "GitSignsAdd" }),
  }
end

---The merge tool's own groups:
--- - ConflictOurs/Theirs/Base: each half of a conflict in RESULT, a faint wash
---   of its side's hue. They paint as extmarks, which only show through a diff
---   group with no bg — hence ResultAdd, RESULT's bg-less stand-in for DiffAdd.
--- - ConflictMarker: the `<<<<<<<` / `=======` / `>>>>>>>` lines, dimmed so
---   the code between them leads; ConflictLabel<Side>: the side named after one.
--- - DiffFill: filler rows. They are alignment padding, not deletions, so a
---   faint hatch instead of DiffDelete's alarm.
function M.update_merge_hl()
  -- A transparent Normal has no bg to wash into: CursorLine stands in, as for
  -- the winbar pill.
  local bg = M.get_bg("Normal", true) or M.get_bg({ "CursorLine", "Visual" })
  local dim = M.get_fg({ "Comment", "NonText" })
  for side, color in pairs(M.merge_side_colors()) do
    if side ~= "Result" then
      M.hi("DiffviewConflict" .. side, { bg = M.blend(color, bg, 0.08), explicit = true, default = true })
      M.hi("DiffviewConflictLabel" .. side, { fg = color, style = "italic", explicit = true, default = true })
    end
  end
  M.hi("DiffviewConflictMarker", { fg = dim, explicit = true, default = true })
  M.hi("DiffviewResultAdd", { fg = "NONE", explicit = true, default = true })
  M.hi("DiffviewDiffFill", { fg = M.blend(dim, bg, 0.45) or dim, explicit = true, default = true })
end

---The winbar's `+N -M` pill: bold counts on a raised surface (Normal's fg
---nudged into its bg, like the comment cards), with rounded caps drawn in the
---surface color. A transparent Normal has no bg to nudge: the theme's
---CursorLine surface stands in. Without any, plain bold counts and no caps —
---caps with no surface between them read as two stray brackets.
function M.update_winbar_hl()
  local fg = M.get_fg("Normal", true)
  local bg = M.get_bg("Normal", true)
  local surface = M.blend(fg, bg, 0.12) or M.get_bg({ "CursorLine", "Visual" })
  M.winbar_pill = surface ~= nil
  local add = M.get_fg({ "DiffviewFilePanelInsertions", "Added", "@diff.plus", "GitSignsAdd" })
  local del = M.get_fg({ "DiffviewFilePanelDeletions", "Removed", "@diff.minus", "GitSignsDelete" })

  -- The merge panes' side pills (OURS / THEIRS / BASE / RESULT): one hue per
  -- side, so a side is found by color before it is read.
  for side, color in pairs(M.merge_side_colors()) do
    M.hi("DiffviewWinBar" .. side, { fg = color, bg = surface, style = "bold", explicit = true, default = true })
    M.hi("DiffviewWinBar" .. side .. "Cap", { fg = surface, explicit = true, default = true })
  end

  if not (surface and add and del) then
    M.winbar_pill = false
    for name, spec in pairs({
      WinBarPillAdd = { fg = add, style = "bold" },
      WinBarPillDel = { fg = del, style = "bold" },
    }) do
      if spec.fg then
        spec.explicit, spec.default = true, true
        M.hi("Diffview" .. name, spec)
      end
    end
    M.hi_link("DiffviewWinBarPillAdd", "DiffviewFilePanelInsertions", { default = true })
    M.hi_link("DiffviewWinBarPillDel", "DiffviewFilePanelDeletions", { default = true })
    return
  end

  for name, spec in pairs({
    WinBarPill = { fg = surface },
    WinBarPillAdd = { fg = add, bg = surface, style = "bold" },
    WinBarPillDel = { fg = del, bg = surface, style = "bold" },
  }) do
    spec.explicit = true
    spec.default = true
    M.hi("Diffview" .. name, spec)
  end
end

function M.update_diff_hl()
  -- Follows DiffviewDiffDelete, and a user definition of either wins: a forced
  -- copy of DiffDelete here overrode whatever the colorscheme set.
  M.hi_link("DiffviewDiffAddAsDelete", "DiffviewDiffDelete", { default = true })
  M.hi_link("DiffviewDiffDeleteDim", "Comment", { default = true })

  M.update_file_sign_hl()

  word_hl("DiffviewDiffAddText", "DiffviewDiffAdd", { "diffAdded", "@diff.plus", "Added" }, "DiffviewDiffText")
  word_hl("DiffviewDiffDeleteText", "DiffviewDiffDelete", { "diffRemoved", "@diff.minus", "Removed" }, "DiffviewDiffText")
end

function M.setup()
  for name, v in pairs(M.get_hl_groups()) do
    v = vim.tbl_extend("force", v, { default = true })
    M.hi("Diffview" .. name, v)
  end

  for from, to in pairs(M.hl_links) do
    M.hi_link("Diffview" .. from, to, { default = true })
  end

  M.update_diff_hl()
  M.update_comment_hl()
  M.update_winbar_hl()
  M.update_merge_hl()
end

return M
