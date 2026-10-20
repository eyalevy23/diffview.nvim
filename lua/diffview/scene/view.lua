local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff1Unified = lazy.access("diffview.scene.layouts.diff_1_unified", "Diff1Unified") ---@type Diff1Unified|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local Signal = lazy.access("diffview.control", "Signal") ---@type Signal|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@enum LayoutMode
local LayoutMode = oop.enum({
  HORIZONTAL = 1,
  VERTICAL = 2,
})

---@class View : diffview.Object
---@field tabpage integer
---@field emitter EventEmitter
---@field default_layout Layout (class)
---@field ready boolean
---@field closing Signal
local View = oop.create_class("View")

---@diagnostic disable unused-local

---@abstract
function View:init_layout() oop.abstract_stub() end

---@abstract
function View:post_open() oop.abstract_stub() end

---@diagnostic enable unused-local

---View constructor
function View:init(opt)
  opt = opt or {}
  self.emitter = opt.emitter or EventEmitter()
  self.default_layout = opt.default_layout or View.get_default_layout()
  self.ready = utils.sate(opt.ready, false)
  self.closing = utils.sate(opt.closing, Signal())

  -- Kept so close can unsubscribe it: the global emitter would otherwise
  -- retain every view ever opened.
  self._on_view_closed = function(_, view, ...)
    local cur_view = require("diffview.lib").get_current_view()

    if (view and view == self) or (not view and cur_view == self) then
      self.emitter:emit("view_closed", view, ...)
    end
  end

  DiffviewGlobal.emitter:on("view_closed", self._on_view_closed)
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = api.nvim_get_current_tabpage()
  self:init_layout()
  self:post_open()
  DiffviewGlobal.emitter:emit("view_opened", self)
  DiffviewGlobal.emitter:emit("view_enter", self)
end

function View:close()
  self.closing:send()

  if self.tabpage and api.nvim_tabpage_is_valid(self.tabpage) then
    DiffviewGlobal.emitter:emit("view_leave", self)

    if #api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
    end

    local pagenr = api.nvim_tabpage_get_number(self.tabpage)
    vim.cmd("tabclose " .. pagenr)
  end

  DiffviewGlobal.emitter:emit("view_closed", self)
  DiffviewGlobal.emitter:off(self._on_view_closed, "view_closed")
end

function View:is_cur_tabpage()
  return self.tabpage == api.nvim_get_current_tabpage()
end

---@return Diff2
function View.get_default_diff2()
  return Diff1Unified.__get()
end

---@return Diff3
function View.get_default_diff3()
  return Diff3Hor.__get()
end

---@return LayoutName|-1
function View.get_default_layout_name()
  return config.get_config().view.default.layout
end

---@return Layout # (class) The default layout class.
function View.get_default_layout()
  local name = View.get_default_layout_name()

  if name == -1 then
    return View.get_default_diff2()
  end

  return config.name_to_layout(name --[[@as string ]])
end

---@return Layout
function View.get_default_merge_layout()
  local name = config.get_config().view.merge_tool.layout

  if name == -1 then
    return View.get_default_diff3()
  end

  return config.name_to_layout(name)
end

---@return Diff2
function View.get_temp_layout()
  local layout_class = View.get_default_layout()
  return layout_class({
    a = File.NULL_FILE,
    b = File.NULL_FILE,
  })
end

M.LayoutMode = LayoutMode
M.View = View

return M
