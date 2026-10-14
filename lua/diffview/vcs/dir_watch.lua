-- One OS watch per directory, shared by everyone interested in a file in it.
-- The git dir is watched for the index (per view) and for the review file
-- (per repo): each extra handle on it would get every `.git` event again.

local uv = vim.uv or vim.loop

local M = {}

---@class DirWatch
---@field handle uv.uv_fs_event_t
---@field subs table<table, { basename: string, cb: fun(err?: string, filename?: string) }>

---@type table<string, DirWatch>
local watches = {}

---Call `cb(err, filename)` from a fast context when `basename` in `dir`
---changes (or for an event without a filename, as libuv may send). Watches
---the directory, not the file: renames over the file end a file watch.
---@param dir string
---@param basename string
---@param cb fun(err?: string, filename?: string)
---@return fun()? unsubscribe Idempotent; nil when the watch could not start.
function M.subscribe(dir, basename, cb)
  dir = vim.fs.normalize(dir)
  local w = watches[dir]

  if not w then
    local handle = uv.new_fs_event()
    if not handle then return end
    w = { handle = handle, subs = {} }

    local ok = handle:start(dir, {}, function(err, filename)
      -- Over a copy, skipping anyone who left meanwhile.
      for _, key in ipairs(vim.tbl_keys(w.subs)) do
        local sub = w.subs[key]
        if sub and (err or filename == nil or filename == sub.basename) then
          sub.cb(err, filename)
        end
      end
    end)

    if not ok then
      handle:close()
      return
    end
    watches[dir] = w
  end

  local key = {}
  w.subs[key] = { basename = basename, cb = cb }

  return function()
    if not w.subs[key] then return end
    w.subs[key] = nil
    if next(w.subs) == nil then
      if not w.handle:is_closing() then w.handle:close() end
      if watches[dir] == w then watches[dir] = nil end
    end
  end
end

return M
