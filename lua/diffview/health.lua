local health = vim.health or require("health")
local fmt = string.format

-- Polyfill deprecated health api
if vim.fn.has("nvim-0.10") ~= 1 then
  health = {
    start = health.report_start,
    ok = health.report_ok,
    info = health.report_info,
    warn = health.report_warn,
    error = health.report_error,
  }
end

local M = {}

M.plugin_deps = {
  {
    name = "nvim-web-devicons",
    optional = true,
  },
}

---@param cmd string|string[]
---@return string[] stdout
---@return integer code
local function system_list(cmd)
  local out = vim.fn.systemlist(cmd)
  return out or {}, vim.v.shell_error
end

local function lualib_available(name)
  local ok, _ = pcall(require, name)
  return ok
end

function M.check()
  if vim.fn.has("nvim-0.7") == 0 then
    health.error("Diffview.nvim requires Neovim 0.7.0+")
  end

  -- LuaJIT
  if not _G.jit then
    health.error("Not running on LuaJIT! Non-JIT Lua runtimes are not officially supported by the plugin. Mileage may vary.")
  end

  health.start("Checking plugin dependencies")

  local missing_essential = false

  for _, plugin in ipairs(M.plugin_deps) do
    if lualib_available(plugin.name) then
      health.ok(plugin.name .. " installed.")
    else
      if plugin.optional then
        health.warn(fmt("Optional dependency '%s' not found.", plugin.name))
      else
        missing_essential = true
        health.error(fmt("Dependency '%s' not found!", plugin.name))
      end
    end
  end

  health.start("Checking VCS tools")

  ;(function()
    if missing_essential then
      health.warn("Cannot perform checks on external dependencies without all essential plugin dependencies installed!")
      return
    end

    health.info("The plugin requires at least one of the supported VCS tools to be valid.")

    local has_valid_adapter = false
    local adapter_kinds = {
      { class = require("diffview.vcs.adapters.git").GitAdapter, name = "Git" },
    }

    for _, kind in ipairs(adapter_kinds) do
      local bs = kind.class.bootstrap
      if not bs.done then kind.class.run_bootstrap() end

      if bs.version_string then
        health.ok(fmt("%s found.", kind.name))
      end

      if bs.ok then
        health.ok(fmt("%s is up-to-date. (%s)", kind.name, bs.version_string))
        has_valid_adapter = true
      else
        health.warn(bs.err or (kind.name .. ": Unknown error"))
      end
    end

    if not has_valid_adapter then
      health.error("No valid VCS tool was found!")
    end
  end)()

  health.start("AI review loop (diff.nvim)")

  ;(function()
    local install = require("diffview.comments.install")
    local uv = vim.uv or vim.loop

    local py = install.python_cmd()
    if py then
      health.ok(py .. " found.")
    else
      health.warn("python3/python not found on PATH — the review MCP server needs it.")
    end

    if vim.fn.executable("claude") ~= 1 then
      health.warn("`claude` CLI not found on PATH — the AI side is unavailable "
        .. "(install Claude Code, then run :DiffviewReview setup).")
      return
    end
    health.ok("claude CLI found.")

    local script = install.server_script()
    if script then
      health.ok("bundled MCP server resolved: " .. script)
    else
      health.error("bundled MCP server not found on the runtimepath!")
      return
    end

    local reg = install.registration()
    if not reg.registered then
      health.warn("MCP server '" .. install.MCP_NAME .. "' is not registered — "
        .. "run :DiffviewReview setup to enable the AI side globally.")
    else
      local entry = reg.entry or ""
      if entry:find(script, 1, true) then
        health.ok("MCP registered (user scope) and pointing at the active plugin copy.")
      elseif entry:find("review_mcp%.py") then
        local stale = entry:match("(/%S+review_mcp%.py)")
        if stale and not uv.fs_stat(stale) then
          health.warn("MCP registration points at a MISSING path (plugin moved/removed?): "
            .. stale .. " — re-run :DiffviewReview setup.")
        else
          health.warn("MCP registration points at a DIFFERENT plugin copy — "
            .. "re-run :DiffviewReview setup to target the active one.")
        end
      else
        health.warn("An MCP server named '" .. install.MCP_NAME .. "' is registered "
          .. "but doesn't look like this plugin's — inspect with: claude mcp get " .. install.MCP_NAME)
      end
    end

    local link = install.skill_link_path()
    local state = install.link_state(link)
    if state == "ours" then
      local resolved = uv.fs_realpath(link)
      if resolved and install.skill_dir() and resolved == uv.fs_realpath(install.skill_dir()) then
        health.ok("trigger skill linked to the active plugin copy.")
      elseif resolved then
        health.warn("trigger skill link points at a different copy: " .. resolved
          .. " — re-run :DiffviewReview setup.")
      else
        health.warn("trigger skill link is DANGLING: " .. link .. " — re-run :DiffviewReview setup.")
      end
    elseif state == "missing" then
      health.warn("trigger skill not linked (~/.claude/skills/" .. install.SKILL_LINK_NAME
        .. ") — run :DiffviewReview setup. The MCP tools work without it; "
        .. "the skill only adds auto-triggering.")
    else
      health.warn(link .. " exists but is not this plugin's symlink — leaving it to you.")
    end

    local npx_copy = vim.fs.normalize("~/.agents/skills/" .. install.SKILL_LINK_NAME)
    if uv.fs_stat(npx_copy) then
      health.warn("duplicate skill copy from `npx skills` at " .. npx_copy
        .. " — it can go stale; prefer one source (remove it or skip :DiffviewReview setup's link).")
    end
  end)()
end

return M
