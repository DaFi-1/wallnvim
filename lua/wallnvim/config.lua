local M = {}

local uv = vim.uv or vim.loop

M.defaults = {
  keymap = false,
  dir = "./dotfiles/wallpapers",
  layout = "grid", -- "grid" (grade com imagens), "list" / "text" (lista em texto), "auto"
  cmd = "feh",
  cmd_args = { "--no-fehbg", "--bg-fill" },
  width = 110,
  height = 32,
  border = "rounded",
  cell_width = 16,
  cell_height = 6,
  gap = 1,
  columns = nil,
  image_support = nil,
  preload = true,
}

local function resolve_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    dir = M.defaults.dir
  end
  dir = dir:gsub("/+$", "")
  if dir:sub(1, 2) == "./" and not uv.fs_stat(dir) and vim.env.HOME then
    local home_rel = vim.env.HOME .. dir:sub(2)
    if uv.fs_stat(home_rel) then
      return home_rel
    end
  end
  return vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")
end

M.opts = vim.deepcopy(M.defaults)
M.opts.dir = resolve_dir(M.opts.dir)

function M.setup(opts)
  opts = opts or {}
  if opts.wallpaper_dir and not opts.dir then
    opts.dir = opts.wallpaper_dir
  end
  M.opts = vim.tbl_deep_extend("force", M.defaults, opts)
  M.opts.dir = resolve_dir(M.opts.dir)
end

return M

