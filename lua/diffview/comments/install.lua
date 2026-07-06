-- AI-side wiring for the review loop: `:DiffviewReview setup` registers the
-- bundled MCP server with the Claude Code CLI (user scope — all projects)
-- and links the trigger skill into ~/.claude/skills. Explicit opt-in only:
-- nothing here runs from plugin load, and every state-changing command is
-- printed before it runs.

local lazy = require("diffview.lazy")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local uv = vim.uv or vim.loop
local M = {}

M.MCP_NAME = "diff-nvim"
M.SKILL_LINK_NAME = "diff-nvim-review"

---Absolute path of the ACTIVE plugin copy's MCP server script, resolved
---through the runtimepath (manager-agnostic).
---@return string?
function M.server_script()
  return vim.api.nvim_get_runtime_file("skills/review/scripts/review_mcp.py", false)[1]
end

---The bundled skill directory (contains SKILL.md + scripts/).
---@return string?
function M.skill_dir()
  local script = M.server_script()
  return script and vim.fs.dirname(vim.fs.dirname(script)) or nil
end

---@return string
function M.skill_link_path()
  return vim.fs.normalize("~/.claude/skills/" .. M.SKILL_LINK_NAME)
end

---@return string? python "python3" | "python" | nil
function M.python_cmd()
  for _, py in ipairs({ "python3", "python" }) do
    if vim.fn.executable(py) == 1 then return py end
  end
end

---The exact `claude mcp add` argv setup runs (exposed for tests/health).
---@param py string
---@param script string
---@return string[]
function M.add_cmd(py, script)
  return {
    "claude", "mcp", "add",
    "--scope", "user",
    "--transport", "stdio",
    M.MCP_NAME,
    "--", py, script,
  }
end

---Ownership state of the skill symlink: we may only touch what is ours.
---@param link? string (default: the real link path; injectable for tests)
---@return "missing"|"ours"|"foreign"
function M.link_state(link)
  link = link or M.skill_link_path()
  local st = uv.fs_lstat(link)
  if not st then return "missing" end
  if st.type ~= "link" then return "foreign" end
  local target = uv.fs_readlink(link)
  -- Ours = a symlink into a diffview plugin's bundled skill dir.
  if target and target:match("skills/review/?$") then return "ours" end
  return "foreign"
end

---@param cmd string[]
---@return string out
---@return integer code
local function run(cmd)
  local out = vim.fn.system(cmd)
  return vim.trim(out or ""), vim.v.shell_error
end

---Register the MCP server (user scope) + link the trigger skill. Idempotent:
---remove-then-add, and re-running after the plugin moves re-registers the
---fresh path.
function M.setup()
  local script = M.server_script()
  if not script then
    utils.err("[diffview] Could not resolve the bundled MCP server on the runtimepath.")
    return
  end
  local py = M.python_cmd()
  if not py then
    utils.err("[diffview] python3 (or python) not found on PATH — required by the review MCP server.")
    return
  end
  if vim.fn.executable("claude") ~= 1 then
    utils.err("[diffview] `claude` CLI not found on PATH — install Claude Code first.")
    return
  end

  -- Idempotency: drop any previous registration, then add the current path.
  run({ "claude", "mcp", "remove", "--scope", "user", M.MCP_NAME })

  local add = M.add_cmd(py, script)
  utils.info("[diffview] running: " .. table.concat(add, " "))
  local out, code = run(add)
  if code ~= 0 then
    utils.err("[diffview] MCP registration failed: " .. out)
    return
  end
  utils.info("[diffview] " .. out)

  -- Trigger skill: personal-scope symlink, ownership-disciplined.
  local link = M.skill_link_path()
  local state = M.link_state(link)
  if state == "foreign" then
    utils.warn(("[diffview] %s exists and is not ours — leaving it untouched "
      .. "(the skill auto-trigger is not linked)."):format(link))
  else
    if state == "ours" then uv.fs_unlink(link) end
    vim.fn.mkdir(vim.fs.dirname(link), "p")
    local ok, e = uv.fs_symlink(M.skill_dir(), link, { dir = true })
    if ok then
      utils.info("[diffview] skill linked: " .. link .. " -> " .. M.skill_dir())
    else
      utils.warn("[diffview] could not link the skill: " .. tostring(e))
    end
  end

  utils.info("[diffview] AI review loop enabled for all projects. Verify with :checkhealth diffview")
end

---Remove the MCP registration and the owned skill symlink.
function M.uninstall()
  if vim.fn.executable("claude") == 1 then
    local out, code = run({ "claude", "mcp", "remove", "--scope", "user", M.MCP_NAME })
    utils.info("[diffview] claude mcp remove: " .. (code == 0 and out or ("(not registered) " .. out)))
  end

  local link = M.skill_link_path()
  local state = M.link_state(link)
  if state == "ours" then
    uv.fs_unlink(link)
    utils.info("[diffview] removed skill link " .. link)
  elseif state == "foreign" then
    utils.warn("[diffview] " .. link .. " is not ours — leaving it untouched.")
  end
end

---Registration snapshot for :checkhealth and the nudge.
---@return { registered: boolean, entry?: string }
function M.registration()
  if vim.fn.executable("claude") ~= 1 then return { registered = false } end
  local out, code = run({ "claude", "mcp", "get", M.MCP_NAME })
  return { registered = code == 0, entry = out }
end

return M
