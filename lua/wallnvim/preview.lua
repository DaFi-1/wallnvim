local db = require("wallnvim.db")

local M = {}

local uv = vim.uv or vim.loop

local THUMB_W, THUMB_H = 320, 180
local MAX_JOBS = 4
local VF_FILTER = string.format(
  "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black",
  THUMB_W,
  THUMB_H,
  THUMB_W,
  THUMB_H
)
local VARIANT_TAG = "thumb" .. THUMB_W .. "x" .. THUMB_H

-- Dedicated range (89201..89400) so IDs never collide with playnvim (88200..88300)
local IMG_ID_MIN = 89201
local IMG_ID_MAX = 89400
local img_counter = IMG_ID_MIN - 1

local function next_image_id()
  img_counter = img_counter + 1
  if img_counter > IMG_ID_MAX then
    img_counter = IMG_ID_MIN
  end
  return img_counter
end

-- ---------------------------------------------------------------- tmux offset

local tmux = { left = 0, top = 0, width = vim.o.columns, height = vim.o.lines, key = false }

local function is_in_tmux()
  return vim.env.TMUX ~= nil or vim.env.TERM_PROGRAM == "tmux"
end

function M.supports_images()
  if vim.env.KITTY_WINDOW_ID then
    return true
  end
  local tp = (vim.env.TERM_PROGRAM or ""):lower()
  if tp == "kitty" or tp == "wezterm" or tp == "ghostty" or tp == "konsole" then
    return true
  end
  local term = (vim.env.TERM or ""):lower()
  return term:find("kitty", 1, true) ~= nil
    or term:find("ghostty", 1, true) ~= nil
    or term:find("wezterm", 1, true) ~= nil
end

function M.use_images(opts_or_bool)
  if type(opts_or_bool) == "boolean" then
    return opts_or_bool
  end
  if type(opts_or_bool) == "table" then
    if type(opts_or_bool.image_support) == "boolean" then
      return opts_or_bool.image_support
    end
    local layout = type(opts_or_bool.layout) == "string" and opts_or_bool.layout:lower() or nil
    if layout == "list" or layout == "text" then
      return false
    end
    if layout == "grid" or layout == "image" or layout == "images" then
      return true
    end
  end
  return M.supports_images()
end

local function query_tmux_pane()
  if vim.fn.executable("tmux") ~= 1 then
    return nil
  end
  local cmd = { "tmux", "display-message", "-p" }
  if vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= "" then
    cmd[#cmd + 1] = "-t"
    cmd[#cmd + 1] = vim.env.TMUX_PANE
  end
  cmd[#cmd + 1] = "#{pane_left},#{pane_top},#{pane_width},#{pane_height}"

  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok or not proc then
    return nil
  end
  local res = proc:wait(150)
  if not res or res.code ~= 0 or not res.stdout then
    return nil
  end
  local pl, pt, pw, ph = res.stdout:match("(%d+),(%d+),(%d+),(%d+)")
  if not pl then
    return nil
  end
  return tonumber(pl), tonumber(pt), tonumber(pw), tonumber(ph)
end

local function get_tmux_pane_offset()
  if not is_in_tmux() then
    return 0, 0, vim.o.columns, vim.o.lines
  end
  local key = vim.o.columns .. "x" .. vim.o.lines
  if tmux.key ~= key then
    local pl, pt, pw, ph = query_tmux_pane()
    if pl then
      tmux.left, tmux.top, tmux.width, tmux.height = pl, pt, pw, ph
    end
    tmux.key = key
  end
  return tmux.left, tmux.top, tmux.width, tmux.height
end

function M.invalidate_tmux_offset()
  tmux.key = false
end

-- ------------------------------------------------------------- kitty protocol

local batch_buf = nil

local function wrap_tmux(seq)
  if is_in_tmux() then
    return "\x1bPtmux;" .. seq:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
  end
  return seq
end

local function send_seq(seq)
  if not seq or seq == "" then
    return
  end
  if batch_buf then
    batch_buf[#batch_buf + 1] = seq
  else
    pcall(vim.api.nvim_chan_send, vim.v.stderr, wrap_tmux(seq))
  end
end

function M.begin_batch()
  batch_buf = {}
end

function M.flush_batch()
  if not batch_buf then
    return
  end
  local chunks = batch_buf
  batch_buf = nil
  if #chunks > 0 then
    pcall(vim.api.nvim_chan_send, vim.v.stderr, wrap_tmux(table.concat(chunks)))
  end
end

function M.clear_image()
  send_seq("\x1b_Ga=d,d=a,q=2\x1b\\")
end

function M.draw_cell(entry_or_path, win, cell_row, cell_col, cols, rows, win_pos)
  if not entry_or_path or cols < 1 or rows < 1 then
    return
  end
  if not win_pos then
    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end
    local ok_pos, pos = pcall(vim.api.nvim_win_get_position, win)
    if not ok_pos or not pos then
      return
    end
    win_pos = pos
  end

  local b64
  if type(entry_or_path) == "table" then
    b64 = entry_or_path.b64_thumb
  else
    local ok, encoded = pcall(vim.base64.encode, entry_or_path)
    b64 = ok and encoded or nil
  end
  if not b64 or b64 == "" then
    return
  end

  local pane_left, pane_top = get_tmux_pane_offset()
  local term_row = win_pos[1] + 2 + cell_row + pane_top
  local term_col = win_pos[2] + 2 + cell_col + pane_left
  local raw = string.format(
    "\x1b7\x1b[%d;%dH\x1b_Ga=T,f=100,t=f,c=%d,r=%d,i=%d,C=1,q=2;%s\x1b\\\x1b8",
    term_row,
    term_col,
    cols,
    rows,
    next_image_id(),
    b64
  )
  send_seq(raw)
end

-- ------------------------------------------------------------ image -> PNG + SQLite

local pending = {}
local queue = {}
local running = 0

local function build_descriptor(item)
  if type(item) == "table" then
    return item
  end
  local st = uv.fs_stat(item)
  if not st then
    return nil
  end
  local mtime = st.mtime.sec * 1000 + math.floor((st.mtime.nsec or 0) / 1000000)
  return {
    path = item,
    dir = vim.fs.dirname(item),
    name = vim.fs.basename(item),
    mtime = mtime,
    size = st.size or 0,
  }
end

local function pump()
  while running < MAX_JOBS and #queue > 0 do
    local job = table.remove(queue, 1)
    running = running + 1
    vim.system(job.cmd, {}, function(res)
      vim.schedule(function()
        running = running - 1
        local cbs = pending[job.path]
        pending[job.path] = nil
        local entry = nil
        if res.code == 0 and uv.fs_stat(job.out) then
          local ok, b64 = pcall(vim.base64.encode, job.out)
          entry = {
            path = job.desc.path,
            dir = job.desc.dir,
            name = job.desc.name,
            mtime = job.desc.mtime,
            size = job.desc.size,
            thumb_path = job.out,
            b64_thumb = ok and b64 or "",
            verified = true,
          }
          db.upsert(entry)
        end
        if cbs then
          for _, cb in ipairs(cbs) do
            cb(entry)
          end
        end
        pump()
      end)
    end)
  end
end

function M.resolve_thumb(item, on_done)
  local path = type(item) == "table" and item.path or item
  if not path then
    if on_done then
      on_done(nil)
    end
    return
  end

  -- Fast path 1: O(1) SQLite + in-memory cache lookup
  local cached = db.get_valid_entry(path)
  if cached then
    if on_done then
      on_done(cached)
    end
    return
  end

  local desc = build_descriptor(item)
  if not desc then
    if on_done then
      on_done(nil)
    end
    return
  end

  local key = vim.fn.sha256(
    desc.path .. ":" .. math.floor(desc.mtime / 1000) .. ":" .. desc.size .. ":" .. VARIANT_TAG
  )
  local out = db.get_thumbs_dir() .. "/" .. key .. ".png"

  -- Fast path 2: Already on disk in data/thumbs (import into SQLite immediately)
  if uv.fs_stat(out) then
    local ok, b64 = pcall(vim.base64.encode, out)
    local entry = {
      path = desc.path,
      dir = desc.dir,
      name = desc.name,
      mtime = desc.mtime,
      size = desc.size,
      thumb_path = out,
      b64_thumb = ok and b64 or "",
      verified = true,
    }
    db.upsert(entry)
    if on_done then
      on_done(entry)
    end
    return
  end

  if vim.fn.executable("ffmpeg") ~= 1 then
    local fallback = desc.path:lower():match("%.png$") and desc.path or nil
    if on_done then
      on_done(fallback)
    end
    return
  end

  if pending[desc.path] then
    if on_done then
      table.insert(pending[desc.path], on_done)
    end
    return
  end

  pending[desc.path] = on_done and { on_done } or {}
  queue[#queue + 1] = {
    path = desc.path,
    desc = desc,
    out = out,
    cmd = {
      "ffmpeg",
      "-y",
      "-v",
      "error",
      "-threads",
      "1",
      "-i",
      desc.path,
      "-vf",
      VF_FILTER,
      "-frames:v",
      "1",
      "-update",
      "1",
      out,
    },
  }
  pump()
end

---Preloads only new/changed items into SQLite and thumbnails dir
function M.preload_items(pending_items, on_complete)
  if not pending_items or #pending_items == 0 then
    if on_complete then
      on_complete()
    end
    return
  end
  local remaining = #pending_items
  for _, item in ipairs(pending_items) do
    M.resolve_thumb(item, function()
      remaining = remaining - 1
      if remaining == 0 and on_complete then
        on_complete()
      end
    end)
  end
end

return M
