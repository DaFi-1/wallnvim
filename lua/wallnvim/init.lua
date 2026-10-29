local config = require("wallnvim.config")
local db = require("wallnvim.db")
local ui = require("wallnvim.ui")

local M = {}

M.setup = function(opts)
  config.setup(opts)
  db.init()
  if config.opts.keymap and type(config.opts.keymap) == "string" and config.opts.keymap ~= "" then
    vim.keymap.set("n", config.opts.keymap, ui.toggle, {
      silent = true,
      desc = "Abrir seletor de wallpapers WallNvim",
    })
  end
  if config.opts.preload ~= false then
    vim.defer_fn(function()
      ui.preload()
    end, 200)
  end
end

M.open = ui.open
M.close = ui.close
M.toggle = ui.toggle
M.is_open = ui.is_open
M.set_wallpaper = ui.set_wallpaper

return M

