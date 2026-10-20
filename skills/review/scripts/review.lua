-- Entry point for the AI side of diff.nvim's review loop, with Neovim as the
-- Lua runtime. `nvim --clean -l review.lua mcp` is the MCP server; any other
-- arguments run the CLI (`--help`). The logic lives in the plugin itself:
-- lua/diffview/comments/agent.lua.

-- This file sits at <plugin>/skills/review/scripts/; resolve symlinks (the
-- skill is linked into ~/.claude/skills) to find the plugin root.
local uv = vim.uv or vim.loop
local script = uv.fs_realpath(_G.arg[0]) or _G.arg[0]
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(script, ":p"))))))
if not uv.fs_stat(root .. "/lua/diffview/comments/agent.lua") then
  io.stderr:write("review: this script must run from the diffview.nvim plugin itself "
    .. "(found no plugin at " .. root .. "). A standalone copy of the skill can't work — "
    .. "use the plugin's skills/review/ (what :DiffviewReview setup links).\n")
  os.exit(1)
end
vim.opt.rtp:prepend(root)

require("diffview.comments.agent").main(_G.arg)
