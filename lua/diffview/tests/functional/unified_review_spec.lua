local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("unified review aids", function()
  local u = require("diffview.scene.layouts.unified_render")
  local config = require("diffview.config")

  -- These aids read whitespace changes (re-indents): see them, as `gw` does.
  local saved_ws
  before_each(function()
    saved_ws = config.get_config().ignore_whitespace
    config.get_config().ignore_whitespace = false
  end)
  after_each(function()
    config.get_config().ignore_whitespace = saved_ws
  end)

  local function kinds(lines, st)
    local out = {}
    for r = 1, #lines do
      local info = st.line_map[r]
      out[r] = (info.kind == "ctx" and " " or info.kind == "add" and "+" or "-") .. (info.link or " ")
        .. (info.moved and info.moved:sub(1, 1) or " ") .. lines[r]
    end
    return out
  end

  it("treats a re-indent as context when whitespace is ignored (the default)", function()
    config.get_config().ignore_whitespace = true
    local lines, st = u.build({ "if x then", "f()", "end" }, { "if x then", "  f()", "end" })
    eq({ "   if x then", "     f()", "   end" }, kinds(lines, st))
    eq(0, #st.hunk_rows)
  end)

  it("brackets a replacement from its first removed row to its last added row", function()
    local lines, st = u.build({ "a", "b", "c" }, { "a", "B1", "B2", "c" })
    eq({
      "   a",
      "-╭ b",
      "+├ B1",
      "+╰ B2",
      "   c",
    }, kinds(lines, st))
  end)

  it("leaves pure additions and deletions unbracketed", function()
    local lines, st = u.build({ "a", "b", "c" }, { "a", "c", "d" })
    eq({ "   a", "-  b", "   c", "+  d" }, kinds(lines, st))
  end)

  it("marks a block that moved, with hints naming the other end", function()
    local block = { "local function helper(x)", "  local y = x * 2", "  return y + 1", "end" }
    -- The code in between is longer than the block, so the diff keeps it and
    -- moves the block (the smaller change).
    local between = { "m1()", "m2()", "m3()", "m4()", "m5()", "m6()" }
    local old = { "top()" }
    vim.list_extend(old, block)
    vim.list_extend(old, between)
    vim.list_extend(old, { "bottom()" })
    local new = { "top()" }
    vim.list_extend(new, between)
    vim.list_extend(new, block)
    vim.list_extend(new, { "bottom()" })

    local lines, st = u.build(old, new)
    local moved_rows, hints = 0, {}
    for r = 1, #lines do
      local info = st.line_map[r]
      if info.moved == "moved" then moved_rows = moved_rows + 1 end
      if info.moved_hint then hints[#hints + 1] = info.moved_hint end
    end
    eq(8, moved_rows)
    eq(4, st.n_moved)
    eq(0, st.n_reindent)
    eq({ "moved to line 8 ↓", "moved from line 2 ↑" }, hints)
  end)

  it("calls a same-place indentation change 'reindent'", function()
    local old = { "f()", "local a = one()", "local b = two()", "local c = three()", "g()" }
    local new = { "f()", "do", "  local a = one()", "  local b = two()", "  local c = three()", "end", "g()" }
    local _, st = u.build(old, new)
    local seen, hints = {}, {}
    for _, info in ipairs(st.line_map) do
      if info.moved then seen[info.moved] = true end
      if info.moved_hint then hints[#hints + 1] = info.kind .. ": " .. info.moved_hint end
    end
    eq({ reindent = true }, seen)
    eq(3, st.n_reindent)
    eq(0, st.n_moved)
    -- One note, on the first removed line: where it lives now.
    eq({ "del: only re-indented · now line 3" }, hints)
  end)

  it("puts one note per hunk when a real change splits a re-indented block", function()
    local old = { "f()", "local a = one()", "local b = two()", "local c = three()",
      "local d = 'old'", "local e = four()", "local g = five()", "local h = six()", "g()" }
    local new = { "f()", "if x then", "  local a = one()", "  local b = two()", "  local c = three()",
      "  local d = 'new'", "  local e = four()", "  local g = five()", "  local h = six()", "end", "g()" }
    local _, st = u.build(old, new)
    local hints = {}
    for _, info in ipairs(st.line_map) do
      if info.moved_hint then hints[#hints + 1] = info.moved_hint end
    end
    eq(6, st.n_reindent)
    eq({ "only re-indented · now line 3" }, hints)
  end)

  it("prefers re-indented in place over a copy of the same lines elsewhere", function()
    local call = { "set_mark(buf, ns, row, {", "end_row = row,", "end_col = 0," }
    local old = { "f()" }
    vim.list_extend(old, call)
    vim.list_extend(old, { "})", "g()", "h()", "i()", "j()" })
    -- New: the original wrapped in an `if`, and the same three lines written
    -- again further down at another depth (as in the real case: the same
    -- extmark call in two branches).
    local new = { "f()", "if on then" }
    for _, l in ipairs(call) do new[#new + 1] = "  " .. l end
    vim.list_extend(new, { "  })", "end", "g()", "h()", "i()" })
    for _, l in ipairs(call) do new[#new + 1] = "    " .. l end
    vim.list_extend(new, { "    hl = 1,", "    })", "j()" })

    local _, st = u.build(old, new)
    eq(0, st.n_moved)
    local hints = {}
    for _, info in ipairs(st.line_map) do
      if info.moved_hint then hints[#hints + 1] = info.moved_hint end
    end
    eq({ "only re-indented · now line 3" }, hints)
  end)

  it("does not call a few trivial lines a move", function()
    local _, st = u.build({ "x()", "end", "end", "}", "y()" }, { "y()", "end", "end", "}", "x()" })
    eq(0, st.n_moved)
  end)

  it("locates the cursor among hunks", function()
    local _, st = u.build({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" },
      { "a", "B", "c", "d", "e", "f", "g", "H", "i", "j" })
    eq(2, #st.hunk_rows)
    eq({ 0, false }, { u.hunk_at(st, 1) })
    eq({ 1, true }, { u.hunk_at(st, st.hunk_rows[1]) })
    eq({ 1, false }, { u.hunk_at(st, st.hunk_ranges[1][2] + 1) })
    eq({ 2, true }, { u.hunk_at(st, st.hunk_rows[2] + 1) })
  end)
end)

describe("noise reduction", function()
  local u = require("diffview.scene.layouts.unified_render")
  local config = require("diffview.config")
  local gen = require("diffview.generated")
  local api = vim.api

  local function fake(lines)
    local b = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return { bufnr = b, nulled = false, is_valid = function() return api.nvim_buf_is_valid(b) end }
  end

  after_each(function()
    config.get_config().ignore_whitespace = true
    config.get_config().generated.collapse = true
  end)

  it("knows generated files by basename and path globs", function()
    assert.True(gen.is_generated("yarn.lock"))
    assert.True(gen.is_generated("web/package-lock.json"))
    assert.True(gen.is_generated("dist/app.min.js"))
    assert.True(gen.is_generated("src/__snapshots__/x.test.ts.snap"))
    assert.False(gen.is_generated("src/lock.lua"))
    assert.False(gen.is_generated("README.md"))
    config.get_config().generated.collapse = false
    assert.False(gen.collapsed("yarn.lock"))
  end)

  it("folds a collapsed file to one row with no hunks, counts kept", function()
    local out = api.nvim_create_buf(false, true)
    local st = u.render(out, fake({ "a", "b" }), fake({ "a", "B", "c" }), { collapsed = true })
    eq(true, st.collapsed)
    eq(0, #st.hunk_rows)
    eq({ { 1, api.nvim_buf_line_count(out) } }, st.fold_ranges)
    eq(2, st.n_add)
    eq(1, st.n_del)
  end)

  it("folds a whitespace-only file, and shows it after the toggle", function()
    local out = api.nvim_create_buf(false, true)
    local a, b = fake({ "if x then", "f()", "end" }), fake({ "if x then", "  f()", "end" })
    local st = u.render(out, a, b)
    eq(true, st.ws_only)
    eq({ { 1, 3 } }, st.fold_ranges)
    config.get_config().ignore_whitespace = false
    local st2, changed = u.render(out, a, b)
    eq(true, changed)
    eq(nil, st2.ws_only)
    eq(1, #st2.hunk_rows)
  end)
end)

describe("word highlights", function()
  local h = require("diffview.scene.layouts.inline_hl")

  local function painted(a, b)
    local ra, rb = h.ratio_filter(h.diff_tokens(h.tokenize(a), h.tokenize(b)))
    local out_a, out_b = {}, {}
    for _, r in ipairs(ra or {}) do out_a[#out_a + 1] = a:sub(r[1] + 1, r[2]) end
    for _, r in ipairs(rb or {}) do out_b[#out_b + 1] = b:sub(r[1] + 1, r[2]) end
    return out_a, out_b
  end

  it("never paints indentation or the spaces around a change", function()
    local a, b = painted(
      '    hl_group = "DiffviewDiffAdd",',
      '        hl_group = info.moved and "DiffviewDiffMovedAdd" or "DiffviewDiffAdd",'
    )
    eq({}, a)
    eq({ 'info.moved and "DiffviewDiffMovedAdd" or' }, b)
  end)

  it("marks a changed separator as just that character", function()
    local a, b = painted("  foo = bar", "  foo = bar,")
    eq({}, a)
    eq({ "," }, b)
    a, b = painted("call(x);", "call(x)")
    eq({ ";" }, a)
    eq({}, b)
  end)
end)
