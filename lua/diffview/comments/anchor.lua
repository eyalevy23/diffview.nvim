-- Anchor resolution: comments survive line drift because every anchor stores
-- the anchored line's text (snippet) plus one line of context on each side.
-- Resolution order: exact line -> nearby search -> unique whole-file match ->
-- outdated. This is the whole reason the human/AI loop keeps working after
-- the AI edits files in response to comments.

local lazy = require("diffview.lazy")

local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule

local M = {}

-- How far around the recorded line we search for a drifted snippet.
M.SEARCH_RADIUS = 20

---Stable rev identity for a vcs.File's rev.
---@param rev Rev
---@return string
function M.rev_key(rev)
  if rev.type == RevType.LOCAL then
    return "WORKING"
  end
  return rev:object_name()
end

---Build an anchor for a source line.
---@param path string Repo-relative path.
---@param side "a"|"b"
---@param rev_key string
---@param line integer 1-indexed source line.
---@param end_line integer
---@param src_lines string[] The source buffer's lines.
---@return ReviewAnchor
function M.make(path, side, rev_key, line, end_line, src_lines)
  return {
    path = path,
    side = side,
    rev = rev_key,
    line = line,
    end_line = end_line or line,
    snippet = src_lines[line] or "",
    ctx_before = src_lines[line - 1],
    ctx_after = src_lines[line + 1],
  }
end

---@param anchor ReviewAnchor
---@param lines string[]
---@param lnum integer
---@return integer score Higher is better context agreement.
local function ctx_score(anchor, lines, lnum)
  local score = 0
  if anchor.ctx_before ~= nil and lines[lnum - 1] == anchor.ctx_before then score = score + 1 end
  if anchor.ctx_after ~= nil and lines[lnum + 1] == anchor.ctx_after then score = score + 1 end
  return score
end

---@class AnchorResolution
---@field line integer Best current line for the anchor.
---@field end_line integer
---@field exact boolean The line still matches the snippet.
---@field outdated boolean No confident match exists anymore.

---Resolve an anchor against the current content of its file.
---@param anchor ReviewAnchor
---@param lines string[] Current lines of the anchored source.
---@return AnchorResolution
function M.resolve(anchor, lines)
  local span = (anchor.end_line or anchor.line) - anchor.line

  local function result(line, exact, outdated)
    return {
      line = line,
      end_line = line + span,
      exact = exact,
      outdated = outdated,
    }
  end

  -- Empty/blank snippets can't be matched by content; trust the line number.
  if not anchor.snippet or anchor.snippet:match("^%s*$") then
    local line = math.min(anchor.line, math.max(1, #lines))
    return result(line, lines[line] == anchor.snippet, false)
  end

  -- 1. Exact position.
  if lines[anchor.line] == anchor.snippet then
    return result(anchor.line, true, false)
  end

  -- 2. Nearby search, best context agreement wins; ties go to the closest.
  local best, best_score, best_dist
  for d = 0, M.SEARCH_RADIUS do
    for _, lnum in ipairs(d == 0 and { anchor.line } or { anchor.line - d, anchor.line + d }) do
      if lnum >= 1 and lnum <= #lines and lines[lnum] == anchor.snippet then
        local score = ctx_score(anchor, lines, lnum)
        if not best or score > best_score or (score == best_score and d < best_dist) then
          best, best_score, best_dist = lnum, score, d
        end
      end
    end
    if best and best_score == 2 then break end
  end
  if best then
    return result(best, true, false)
  end

  -- 3. Unique whole-file match.
  local matches = {}
  for lnum, text in ipairs(lines) do
    if text == anchor.snippet then
      matches[#matches + 1] = lnum
      if #matches > 1 then break end
    end
  end
  if #matches == 1 then
    return result(matches[1], true, false)
  end

  -- 4. Outdated: render at the last known position, clamped.
  local line = math.min(anchor.line, math.max(1, #lines))
  return result(line, false, true)
end

---Refresh an anchor in place after its line was re-located (drift write-back).
---@param anchor ReviewAnchor
---@param new_line integer
---@param src_lines string[]
function M.write_back(anchor, new_line, src_lines)
  local span = (anchor.end_line or anchor.line) - anchor.line
  anchor.line = new_line
  anchor.end_line = new_line + span
  anchor.snippet = src_lines[new_line] or anchor.snippet
  anchor.ctx_before = src_lines[new_line - 1]
  anchor.ctx_after = src_lines[new_line + 1]
end

return M
