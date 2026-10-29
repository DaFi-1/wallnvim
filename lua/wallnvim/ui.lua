local config = require("wallnvim.config")
local db = require("wallnvim.db")
local preview = require("wallnvim.preview")

local M = {}

local uv = vim.uv or vim.loop
local ns_id = vim.api.nvim_create_namespace("wallnvim_ui")
local ui_augroup = vim.api.nvim_create_augroup("WallNvimUI", { clear = true })

local win, buf = nil, nil
local selected_idx = 1
local first_visible = 1
local wallpapers = {}
local max_name_width = 0
local hl_initialized = false
local resize_timer = nil
local render_gen = 0

local columns = 1
local rows_visible = 1
local cell_w, cell_h, gap = 16, 6, 1
local content_w, content_h = 1, 1
local total_rows = 1
local sb_active = false
local sb_col = nil
local image_mode = true

-- Cached blank buffer state to avoid O(H) allocations and nvim_buf_set_lines on grid scroll
local cached_blank_w = 0
local cached_blank_h = 0
local cached_blank_lines = nil
local buf_blank_applied_w = 0
local buf_blank_applied_h = 0

-- ----------------------------------------------------------------- highlights

local function setup_highlights()
  if hl_initialized then
    return
  end
  hl_initialized = true
  local set = vim.api.nvim_set_hl
  set(0, "WallNvimNormal", { bg = "#000000", fg = "#ffffff", default = true })
  set(0, "WallNvimBorder", { bg = "#000000", fg = "#ffffff", default = true })
  set(0, "WallNvimTitle", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set(0, "WallNvimCellSel", { bg = "#ffffff", fg = "#000000", default = true })
  set(0, "WallNvimScrollTrack", { bg = "#2a2a2a", fg = "#2a2a2a", default = true })
  set(0, "WallNvimScrollThumb", { bg = "#ffffff", fg = "#ffffff", default = true })
end

-- -------------------------------------------------------------------- listing

local function sync_wallpapers()
  local pending_items
  wallpapers, max_name_width, pending_items = db.sync_dir(config.opts.dir)
  return pending_items
end

local function selected_path()
  local name = wallpapers[selected_idx]
  return name and (config.opts.dir .. "/" .. name) or nil
end

-- -------------------------------------------------------------------- actions

local function set_wallpaper_at(path)
  if not path or path == "" then
    return
  end
  local args = vim.list_extend(vim.deepcopy(config.opts.cmd_args or {}), { path })
  vim.system({ config.opts.cmd or "feh", unpack(args) }, {}, function(res)
    vim.schedule(function()
      if not (res and res.code == 0) then
        vim.notify("WallNvim: Erro ao definir wallpaper", vim.log.levels.ERROR)
      end
    end)
  end)
end

local function set_wallpaper()
  set_wallpaper_at(selected_path())
end

-- --------------------------------------------------------------------- layout

local function grid_columns(max_w, cw, g, n)
  local cols = config.opts.columns
  if not cols or cols < 1 then
    cols = math.floor((max_w + g) / (cw + g))
  end
  return math.max(1, math.min(cols, n))
end

local function grid_rows(max_h, ch, g, cols, n)
  local rows = math.max(1, math.floor((max_h + g) / (ch + g)))
  return math.min(rows, math.ceil(n / cols))
end

local function layout_text(max_w, max_h, n)
  local text_w = math.min(math.max(20, max_name_width + 4), max_w)
  local rows = math.max(1, math.min(max_h, n))

  cell_w, cell_h, gap = text_w, 1, 0
  columns, rows_visible = 1, rows
  total_rows = n
  sb_active = n > rows
  sb_col = sb_active and (text_w + 1) or nil
  content_w = sb_active and (text_w + 2) or text_w
  content_h = rows
end

local function layout_grid(max_w, max_h, n)
  local cw = math.max(4, config.opts.cell_width or 16)
  local ch = math.max(3, config.opts.cell_height or 6)
  local g = math.max(0, config.opts.gap or 1)

  local cols = grid_columns(max_w, cw, g, n)
  local rows = grid_rows(max_h, ch, g, cols, n)
  if math.ceil(n / cols) > rows then
    cols = grid_columns(max_w - (g + 1), cw, g, n)
    rows = grid_rows(max_h, ch, g, cols, n)
  end

  cell_w, cell_h, gap = cw, ch, g
  columns, rows_visible = cols, rows
  total_rows = math.ceil(n / cols)
  sb_active = total_rows > rows

  local grid_w = cols * cw + (cols - 1) * g
  local grid_h = rows * ch + (rows - 1) * g
  sb_col = sb_active and (grid_w + g) or nil
  content_w = sb_active and (grid_w + g + 1) or grid_w
  content_h = grid_h
end

local function compute_layout()
  local n = math.max(1, #wallpapers)
  local max_w = math.max(10, math.min(config.opts.width or 110, vim.o.columns - 4))
  local max_h = math.max(4, math.min(config.opts.height or 32, vim.o.lines - 4))
  if image_mode then
    layout_grid(max_w, max_h, n)
  else
    layout_text(max_w, max_h, n)
  end
  return content_w, content_h
end

local function build_win_config()
  local total_w, total_h = content_w + 2, content_h + 2
  local row = math.max(0, math.floor((vim.o.lines - total_h) / 2))
  local col = math.max(0, math.floor((vim.o.columns - total_w) / 2))
  return {
    relative = "editor",
    row = row,
    col = col,
    width = content_w,
    height = content_h,
    border = config.opts.border or "rounded",
    style = "minimal",
  }
end

-- ---------------------------------------------------------------- buffer paint

local function set_cursor()
  if not win or not vim.api.nvim_win_is_valid(win) or #wallpapers == 0 then
    return
  end
  local rel = selected_idx - first_visible
  local line = math.floor(rel / columns) * (cell_h + gap) + 1
  local col = (rel % columns) * (cell_w + gap)
  pcall(vim.api.nvim_win_set_cursor, win, { line, col })
end

local function paint_scrollbar()
  if not sb_active or not sb_col then
    return
  end
  for y = 0, content_h - 1 do
    vim.api.nvim_buf_add_highlight(buf, ns_id, "WallNvimScrollTrack", y, sb_col, sb_col + 1)
  end
  local thumb = math.min(content_h, math.max(1, math.floor(content_h * rows_visible / total_rows + 0.5)))
  local max_top = content_h - thumb
  local denom = math.max(1, total_rows - rows_visible)
  local first_row = math.floor((first_visible - 1) / columns)
  local top = math.max(0, math.min(math.floor(max_top * first_row / denom + 0.5), max_top))
  for y = top, top + thumb - 1 do
    vim.api.nvim_buf_add_highlight(buf, ns_id, "WallNvimScrollThumb", y, sb_col, sb_col + 1)
  end
end

-- O(1) highlight calculation for the active cell (instead of O(R * C) nested loop)
local function paint_frames()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  if #wallpapers == 0 then
    return
  end

  local rel = selected_idx - first_visible
  local visible_capacity = rows_visible * columns

  if rel >= 0 and rel < visible_capacity then
    if image_mode then
      local r = math.floor(rel / columns)
      local c = rel % columns
      local row = r * (cell_h + gap)
      local col = c * (cell_w + gap)
      for yy = row, row + cell_h - 1 do
        vim.api.nvim_buf_add_highlight(buf, ns_id, "WallNvimCellSel", yy, col, col + cell_w)
      end
    else
      local last = sb_active and sb_col or content_w
      vim.api.nvim_buf_add_highlight(buf, ns_id, "WallNvimCellSel", rel, 0, last)
    end
  end

  paint_scrollbar()
  set_cursor()
end

local function draw_images()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  render_gen = render_gen + 1
  local gen = render_gen

  local ok_pos, win_pos = pcall(vim.api.nvim_win_get_position, win)
  if not ok_pos or not win_pos then
    return
  end

  local dir = config.opts.dir
  local inner_w = cell_w - 2
  local inner_h = cell_h - 2

  preview.begin_batch()
  preview.clear_image()

  for r = 0, rows_visible - 1 do
    local base = first_visible + r * columns
    local cr = r * (cell_h + gap) + 1
    for c = 0, columns - 1 do
      local name = wallpapers[base + c]
      if name then
        local cc = c * (cell_w + gap) + 1
        local full_path = dir .. "/" .. name
        local cached = db.get_valid_entry(full_path)
        if cached then
          preview.draw_cell(cached, win, cr, cc, inner_w, inner_h, win_pos)
        else
          preview.resolve_thumb(full_path, function(entry)
            if gen ~= render_gen or not entry then
              return
            end
            if not win or not vim.api.nvim_win_is_valid(win) then
              return
            end
            preview.draw_cell(entry, win, cr, cc, inner_w, inner_h)
          end)
        end
      end
    end
  end

  preview.flush_batch()
end

local function ensure_blank_grid_lines()
  if buf_blank_applied_w == content_w and buf_blank_applied_h == content_h then
    return
  end
  if cached_blank_w ~= content_w or cached_blank_h ~= content_h or not cached_blank_lines then
    local blank = string.rep(" ", content_w)
    cached_blank_lines = {}
    for i = 1, content_h do
      cached_blank_lines[i] = blank
    end
    cached_blank_w = content_w
    cached_blank_h = content_h
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, cached_blank_lines)
  buf_blank_applied_w = content_w
  buf_blank_applied_h = content_h
end

local function format_text_line(name)
  if not name then
    return string.rep(" ", content_w)
  end
  local disp_w = vim.fn.strdisplaywidth(name)
  if disp_w >= content_w then
    return vim.fn.strcharpart(name, 0, content_w)
  end
  return name .. string.rep(" ", content_w - disp_w)
end

local function render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  if image_mode then
    ensure_blank_grid_lines()
  else
    buf_blank_applied_w, buf_blank_applied_h = 0, 0
    local lines = {}
    if #wallpapers == 0 then
      lines[1] = format_text_line(" (Nenhum wallpaper encontrado)")
    else
      for i = 0, rows_visible - 1 do
        lines[i + 1] = format_text_line(wallpapers[first_visible + i])
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  paint_frames()
  if image_mode then
    draw_images()
  end
end

-- ------------------------------------------------------------------ navigation

local function ensure_visible()
  local sel_row = math.floor((selected_idx - 1) / columns)
  local first_row = math.floor((first_visible - 1) / columns)
  if sel_row < first_row then
    first_visible = sel_row * columns + 1
  elseif sel_row > first_row + rows_visible - 1 then
    first_visible = (sel_row - rows_visible + 1) * columns + 1
  end
  if first_visible < 1 then
    first_visible = 1
  end
end

local function move_by(delta)
  local n = #wallpapers
  if n == 0 then
    return
  end
  local target = math.max(1, math.min(selected_idx + delta, n))
  if target == selected_idx then
    return
  end
  selected_idx = target
  local before = first_visible
  ensure_visible()
  if first_visible ~= before then
    render()
  else
    paint_frames()
  end
end

-- --------------------------------------------------------------------- resize

local function place_window()
  vim.api.nvim_win_set_config(win, build_win_config())
end

local function handle_resize()
  if not M.is_open() then
    return
  end
  compute_layout()
  place_window()
  first_visible = math.floor((selected_idx - 1) / columns) * columns + 1
  ensure_visible()
  render()
end

local function redraw_all()
  if not M.is_open() then
    return
  end
  preview.invalidate_tmux_offset()
  handle_resize()
end

local function schedule_resize()
  if not resize_timer then
    resize_timer = uv.new_timer()
  end
  if not resize_timer then
    return
  end
  resize_timer:stop()
  resize_timer:start(120, 0, function()
    resize_timer:stop()
    vim.schedule(redraw_all)
  end)
end

-- ------------------------------------------------------------------ lifecycle

local function stop_images()
  render_gen = render_gen + 1
  preview.clear_image()
end

local function close()
  stop_images()
  if resize_timer then
    resize_timer:stop()
    pcall(resize_timer.close, resize_timer)
    resize_timer = nil
  end
  vim.api.nvim_clear_autocmds({ group = ui_augroup })
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  win, buf = nil, nil
  buf_blank_applied_w, buf_blank_applied_h = 0, 0
end

local function set_win_opts()
  vim.api.nvim_set_option_value(
    "winhighlight",
    "Normal:WallNvimNormal,NormalFloat:WallNvimNormal,FloatBorder:WallNvimBorder,FloatTitle:WallNvimTitle",
    { win = win }
  )
  for opt, val in pairs({
    cursorline = false,
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    winbar = "",
    colorcolumn = "",
  }) do
    vim.api.nvim_set_option_value(opt, val, { win = win })
  end
end

local function toggle_layout()
  if image_mode then
    stop_images()
    image_mode = false
  else
    image_mode = true
  end
  handle_resize()
end

local function set_keymaps()
  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("<C-c>", close)
  map("l", function() move_by(1) end)
  map("<Right>", function() move_by(1) end)
  map("h", function() move_by(-1) end)
  map("<Left>", function() move_by(-1) end)
  map("j", function() move_by(columns) end)
  map("<Down>", function() move_by(columns) end)
  map("k", function() move_by(-columns) end)
  map("<Up>", function() move_by(-columns) end)
  map("<Tab>", toggle_layout)
  map("<CR>", set_wallpaper)
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(win)
    return
  end
  setup_highlights()
  local pending_items = sync_wallpapers()
  image_mode = preview.use_images(config.opts)
  selected_idx = math.max(1, math.min(selected_idx, math.max(1, #wallpapers)))
  first_visible = 1
  ensure_visible()
  compute_layout()

  buf = vim.api.nvim_create_buf(false, true)
  buf_blank_applied_w, buf_blank_applied_h = 0, 0
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "wallnvim", { buf = buf })

  win = vim.api.nvim_open_win(buf, true, build_win_config())
  set_win_opts()
  set_keymaps()

  vim.api.nvim_clear_autocmds({ group = ui_augroup })
  vim.api.nvim_create_autocmd({ "VimResized", "FocusGained" }, {
    group = ui_augroup,
    callback = function(ev)
      if ev.event == "VimResized" then
        schedule_resize()
      else
        redraw_all()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = ui_augroup,
    buffer = buf,
    callback = function()
      if M.is_open() then
        vim.schedule(close)
      end
    end,
  })

  render()
  if image_mode and #pending_items > 0 then
    preview.preload_items(pending_items)
  end
end

function M.preload()
  db.init()
  local pending_items = sync_wallpapers()
  if not preview.use_images(config.opts) then
    return
  end
  if #pending_items > 0 then
    preview.preload_items(pending_items)
  end
end

function M.close()
  if M.is_open() then
    close()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.set_wallpaper(path)
  if path and path ~= "" then
    set_wallpaper_at(path)
  end
end

return M
