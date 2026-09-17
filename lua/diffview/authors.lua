-- Author identity the way lazygit shows it: initials and a colour derived
-- from an MD5 of the name. One source for pick_commit's rows, peek's blame
-- title and (from a user config) gitsigns' blame line.

local api = vim.api

local M = {}

local bit = require("bit")

-- MD5 per its RFC, only to reproduce lazygit's author colours, which are
-- derived from an MD5 of the author name.
local md5_k = {}
for i = 0, 63 do md5_k[i] = bit.tobit(math.floor(math.abs(math.sin(i + 1)) * 2 ^ 32)) end
local md5_s = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

---First three MD5 state words of `str`: digest bytes 0-11, little-endian.
---@param str string
---@return integer, integer, integer
local function md5_words(str)
  local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
  local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

  local len = #str
  local bits = len * 8
  local msg = str .. "\128" .. ("\0"):rep((55 - len) % 64) .. string.char(
    band(bits, 0xff), band(rshift(bits, 8), 0xff), band(rshift(bits, 16), 0xff), band(rshift(bits, 24), 0xff),
    0, 0, 0, 0
  )

  local a0, b0, c0, d0 = tobit(0x67452301), tobit(0xefcdab89), tobit(0x98badcfe), tobit(0x10325476)
  local m = {}
  for chunk = 1, #msg, 64 do
    for j = 0, 15 do
      local p = chunk + j * 4
      local w1, w2, w3, w4 = msg:byte(p, p + 3)
      m[j] = bor(w1, lshift(w2, 8), lshift(w3, 16), lshift(w4, 24))
    end
    local a, b, c, d = a0, b0, c0, d0
    for i = 0, 63 do
      local f, g
      if i < 16 then
        f, g = bor(band(b, c), band(bnot(b), d)), i
      elseif i < 32 then
        f, g = bor(band(d, b), band(bnot(d), c)), (5 * i + 1) % 16
      elseif i < 48 then
        f, g = bxor(b, c, d), (3 * i + 5) % 16
      else
        f, g = bxor(c, bor(b, bnot(d))), (7 * i) % 16
      end
      a, d, c, b = d, c, b, tobit(b + rol(tobit(f + a + md5_k[i] + m[g]), md5_s[i + 1]))
    end
    a0, b0, c0, d0 = tobit(a0 + a), tobit(b0 + b), tobit(c0 + c), tobit(d0 + d)
  end
  return a0, b0, c0
end

---lazygit's randFloat: the word's four bytes summed mod 100, as a fraction.
---@param word integer
---@return number
local function rand_float(word)
  local sum = 0
  for k = 0, 3 do sum = (sum + bit.band(bit.rshift(word, 8 * k), 0xff)) % 100 end
  return sum / 100
end

---go-colorful's Hsl, truncated to 8-bit channels the way lazygit does.
---@return string
local function hsl_to_hex(h, s, l)
  local t1 = l < 0.5 and l * (1 + s) or l + s - l * s
  local t2 = 2 * l - t1
  h = h / 360
  local function channel(t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    local v
    if 6 * t < 1 then
      v = t2 + (t1 - t2) * 6 * t
    elseif 2 * t < 1 then
      v = t1
    elseif 3 * t < 2 then
      v = t2 + (t1 - t2) * (2 / 3 - t) * 6
    else
      v = t2
    end
    return math.floor(v * 255)
  end
  return ("#%02x%02x%02x"):format(channel(h + 1 / 3), channel(h), channel(h - 1 / 3))
end

---lazygit's initials: a wide first character (CJK) alone, the first two
---characters of a one-word name, else the first letter of the first two words.
---@param name string
---@return string
local function author_initials(name)
  if name == "" then return "" end
  local first = vim.fn.strcharpart(name, 0, 1)
  if api.nvim_strwidth(first) > 1 then return first end
  local words = vim.split(name, " ", { plain = true })
  if #words == 1 then return vim.fn.strcharpart(name, 0, 2) end
  return vim.fn.strcharpart(words[1], 0, 1) .. vim.fn.strcharpart(words[2], 0, 1)
end

---@class diffview.Author
---@field initials string
---@field color string "#rrggbb"
---@field hl string Highlight group with `fg = color`; defined whenever returned.

local authors = {} ---@type table<string, diffview.Author>

-- The colours are fixed hexes, not theme colours, so after `:colorscheme`
-- wipes the groups they're set again right away: blame text already on
-- screen (a gitsigns extmark) keeps its colour.
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("diffview_authors", { clear = true }),
  callback = function()
    for _, author in pairs(authors) do
      api.nvim_set_hl(0, author.hl, { fg = author.color })
    end
  end,
})

---lazygit's initials and colour for an author name.
---@param name string
---@return diffview.Author
function M.get(name)
  local author = authors[name]
  if not author then
    local w0, w1, w2 = md5_words(name)
    local color = hsl_to_hex(rand_float(w0) * 360, 0.6 + 0.4 * rand_float(w1), 0.4 + 0.2 * rand_float(w2))
    author = { initials = author_initials(name), color = color, hl = "DiffviewCommitAuthor" .. color:sub(2) }
    api.nvim_set_hl(0, author.hl, { fg = author.color })
    authors[name] = author
  end
  return author
end

return M
