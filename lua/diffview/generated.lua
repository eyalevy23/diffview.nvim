---Generated files (lockfiles, minified bundles, snapshots): what reviewing a
---diff can skip. Matched by `config.generated.patterns`; whether they are
---collapsed is runtime state, toggled by actions.toggle_generated.
local config = require("diffview.config")

local M = {}

local compiled, compiled_for = {}, nil
---@type table<string, boolean>
local cache = {}

---@return { pat: vim.lpeg.Pattern, path: boolean }[]
local function matchers()
  local patterns = config.get_config().generated.patterns or {}
  if compiled_for ~= patterns then
    compiled, compiled_for, cache = {}, patterns, {}
    for _, glob in ipairs(patterns) do
      local ok, pat = pcall(vim.glob.to_lpeg, glob)
      if ok then compiled[#compiled + 1] = { pat = pat, path = glob:find("/", 1, true) ~= nil } end
    end
  end
  return compiled
end

---Whether a repo-relative path names a generated file.
---@param path string
---@return boolean
function M.is_generated(path)
  local list = matchers()
  local hit = cache[path]
  if hit ~= nil then return hit end
  local base = path:match("[^/]+$") or path
  hit = false
  for _, m in ipairs(list) do
    if m.pat:match(m.path and path or base) then
      hit = true
      break
    end
  end
  cache[path] = hit
  return hit
end

---Whether a path's diff is shown collapsed right now.
---@param path? string
---@return boolean
function M.collapsed(path)
  return path ~= nil and config.get_config().generated.collapse and M.is_generated(path) or false
end

return M
