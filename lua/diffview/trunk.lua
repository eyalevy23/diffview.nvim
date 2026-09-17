-- The trunk: the branch everything merges into. One definition for everything
-- that needs it — the branch diff (:DiffviewBranch), peek's `branch` base and
-- pick_commit's "on main" colour.
--
-- The origin copy wins over a local main: a local main is often stale, or
-- ahead with unpushed commits, and either way gives the wrong merge-base.

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---Remote trunk refs, in order of preference.
M.remote_refs = { "refs/remotes/origin/main", "refs/remotes/origin/master" }

---Only used when the repo has no remote trunk (a repo never pushed anywhere).
M.local_refs = { "refs/heads/main", "refs/heads/master" }

---Merge-base of HEAD with the first trunk ref that exists: one `git
---merge-base` when origin/main exists, one more per ref missing before it.
---@param cwd string Any directory inside the repo.
---@param cb fun(sha?: string, ref?: string) On the main loop. `ref` is the short
---name ("origin/main"); both are nil when the repo has no trunk.
function M.merge_base(cwd, cb)
  local refs = utils.vec_join(M.remote_refs, M.local_refs)

  local function try(i)
    local ref = refs[i]
    if not ref then return cb() end

    local cmd = utils.vec_join(config.get_config().git_cmd, "merge-base", ref, "HEAD")
    vim.system(cmd, { cwd = cwd, text = true }, vim.schedule_wrap(function(out)
      local sha = out.code == 0 and vim.trim(out.stdout) or ""
      if sha == "" then return try(i + 1) end
      cb(sha, (ref:gsub("^refs/%a+/", "")))
    end))
  end

  try(1)
end

return M
