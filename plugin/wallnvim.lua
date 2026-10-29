if vim.g.loaded_wallnvim then
  return
end
vim.g.loaded_wallnvim = 1

local wall = require("wallnvim")

vim.api.nvim_create_user_command("WallNvim", function()
  wall.open()
end, { desc = "Abrir seletor de wallpapers WallNvim" })

vim.api.nvim_create_user_command("WallToggle", function()
  wall.toggle()
end, { desc = "Alternar seletor de wallpapers WallNvim" })

vim.api.nvim_create_user_command("WallSet", function(opts)
  if opts.args and opts.args ~= "" then
    wall.set_wallpaper(opts.args)
  end
end, { nargs = 1, complete = "file", desc = "Definir wallpaper especificando o caminho" })
