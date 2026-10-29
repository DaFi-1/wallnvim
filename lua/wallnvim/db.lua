local config = require("wallnvim.config")

local M = {}

local ffi = require("ffi")
local uv = vim.uv or vim.loop

pcall(ffi.cdef, [[
  typedef struct sqlite3 sqlite3;
  typedef struct sqlite3_stmt sqlite3_stmt;

  int sqlite3_open(const char *filename, sqlite3 **ppDb);
  int sqlite3_close(sqlite3 *db);
  int sqlite3_busy_timeout(sqlite3 *db, int ms);
  int sqlite3_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
  void sqlite3_free(void *p);

  int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
  int sqlite3_step(sqlite3_stmt *pStmt);
  int sqlite3_reset(sqlite3_stmt *pStmt);
  int sqlite3_clear_bindings(sqlite3_stmt *pStmt);
  int sqlite3_finalize(sqlite3_stmt *pStmt);
  int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int len, void(*destructor)(void*));
  int sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, int64_t val);
  const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
  int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
]])

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

local IMAGE_EXTS = {
  jpg = true,
  jpeg = true,
  png = true,
  webp = true,
  bmp = true,
  gif = true,
}

local lib = nil
local lib_checked = false
local db_handle = nil
local is_initialized = false
local resolved_data_dir = nil
local db_file_path = nil
local thumbs_dir_path = nil

-- O(1) in-memory caches
local by_path = {}
local by_dir = {}

-- Cached prepared statements for O(1) statement execution without re-parsing SQL
local stmt_upsert_wall = nil
local stmt_delete_wall = nil
local stmt_upsert_dir = nil

local function load_sqlite_lib()
  if lib_checked then
    return lib
  end
  lib_checked = true
  local names = { "libsqlite3.so.0", "libsqlite3.so", "sqlite3", "libsqlite3.dylib" }
  for _, name in ipairs(names) do
    local ok, loaded = pcall(ffi.load, name)
    if ok and loaded then
      lib = loaded
      return lib
    end
  end
  return nil
end

local function cstr_or_empty(ptr)
  if ptr == nil then
    return ""
  end
  return ffi.string(ptr)
end

local function stat_mtime_ms(st)
  if not st or not st.mtime then
    return 0
  end
  return st.mtime.sec * 1000 + math.floor((st.mtime.nsec or 0) / 1000000)
end

local function sql_quote(val)
  if not val then
    return "''"
  end
  return "'" .. tostring(val):gsub("'", "''") .. "'"
end

local function exec_sql(sql)
  if not (db_handle and lib) then
    return false
  end
  local errmsg = ffi.new("char*[1]")
  local rc = lib.sqlite3_exec(db_handle, sql, nil, nil, errmsg)
  if errmsg[0] ~= nil then
    lib.sqlite3_free(errmsg[0])
  end
  return rc == SQLITE_OK
end

local function prepare_stmt(sql)
  if not (db_handle and lib) then
    return nil
  end
  local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
  if lib.sqlite3_prepare_v2(db_handle, sql, -1, stmt_ptr, nil) == SQLITE_OK then
    return stmt_ptr[0]
  end
  return nil
end

function M.get_data_dir()
  if config.opts.data_dir and config.opts.data_dir ~= resolved_data_dir then
    resolved_data_dir = config.opts.data_dir
    db_file_path = nil
    thumbs_dir_path = nil
  end
  if resolved_data_dir then
    return resolved_data_dir
  end

  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  local plugin_root = nil
  if source:sub(1, 1) == "@" then
    plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source:sub(2))))
  end

  if plugin_root and uv.fs_stat(plugin_root) then
    resolved_data_dir = vim.fn.fnamemodify(plugin_root .. "/data", ":p"):gsub("/+$", "")
  else
    resolved_data_dir = vim.fn.stdpath("data") .. "/wallnvim"
  end

  pcall(vim.fn.mkdir, resolved_data_dir, "p")
  return resolved_data_dir
end

function M.get_db_path()
  if not db_file_path then
    db_file_path = M.get_data_dir() .. "/wallpapers.db"
  end
  return db_file_path
end

function M.get_thumbs_dir()
  if not thumbs_dir_path then
    thumbs_dir_path = M.get_data_dir() .. "/thumbs"
    pcall(vim.fn.mkdir, thumbs_dir_path, "p")
  end
  return thumbs_dir_path
end

local function load_all_from_ffi()
  local stmt = prepare_stmt(
    "SELECT path, dir, name, mtime, size, thumb_path, b64_thumb FROM wallpapers ORDER BY name ASC;"
  )
  if stmt then
    while lib.sqlite3_step(stmt) == SQLITE_ROW do
      local path = cstr_or_empty(lib.sqlite3_column_text(stmt, 0))
      local dir = cstr_or_empty(lib.sqlite3_column_text(stmt, 1))
      local name = cstr_or_empty(lib.sqlite3_column_text(stmt, 2))
      local mtime = tonumber(lib.sqlite3_column_int64(stmt, 3)) or 0
      local size = tonumber(lib.sqlite3_column_int64(stmt, 4)) or 0
      local thumb_path = cstr_or_empty(lib.sqlite3_column_text(stmt, 5))
      local b64_thumb = cstr_or_empty(lib.sqlite3_column_text(stmt, 6))
      if path ~= "" and thumb_path ~= "" then
        if b64_thumb == "" then
          local ok, enc = pcall(vim.base64.encode, thumb_path)
          b64_thumb = ok and enc or ""
        end
        by_path[path] = {
          path = path,
          dir = dir,
          name = name,
          mtime = mtime,
          size = size,
          thumb_path = thumb_path,
          b64_thumb = b64_thumb,
          verified = false,
        }
        local d = by_dir[dir]
        if not d then
          d = { names = {}, max_width = 0, mtime = 0 }
          by_dir[dir] = d
        end
        d.names[#d.names + 1] = name
        local w = vim.fn.strdisplaywidth(name)
        if w > d.max_width then
          d.max_width = w
        end
      end
    end
    lib.sqlite3_finalize(stmt)
  end

  local dstmt = prepare_stmt("SELECT dir, mtime FROM dir_state;")
  if dstmt then
    while lib.sqlite3_step(dstmt) == SQLITE_ROW do
      local dir = cstr_or_empty(lib.sqlite3_column_text(dstmt, 0))
      local mtime = tonumber(lib.sqlite3_column_int64(dstmt, 1)) or 0
      if by_dir[dir] then
        by_dir[dir].mtime = mtime
      end
    end
    lib.sqlite3_finalize(dstmt)
  end
end

local function load_all_from_cli(path)
  local out = vim.fn.system({
    "sqlite3",
    "-separator",
    "\t",
    path,
    "SELECT path, dir, name, mtime, size, thumb_path, b64_thumb FROM wallpapers ORDER BY name ASC;",
  })
  if type(out) ~= "string" then
    return
  end
  for line in out:gmatch("[^\r\n]+") do
    local p = vim.split(line, "\t", { plain = true })
    if #p >= 6 and p[1] ~= "" and p[6] ~= "" then
      local b64 = (p[7] and p[7] ~= "") and p[7] or vim.base64.encode(p[6])
      by_path[p[1]] = {
        path = p[1],
        dir = p[2],
        name = p[3],
        mtime = tonumber(p[4]) or 0,
        size = tonumber(p[5]) or 0,
        thumb_path = p[6],
        b64_thumb = b64,
        verified = false,
      }
      local d = by_dir[p[2]]
      if not d then
        d = { names = {}, max_width = 0, mtime = 0 }
        by_dir[p[2]] = d
      end
      d.names[#d.names + 1] = p[3]
      local w = vim.fn.strdisplaywidth(p[3])
      if w > d.max_width then
        d.max_width = w
      end
    end
  end

  local dout = vim.fn.system({
    "sqlite3",
    "-separator",
    "\t",
    path,
    "SELECT dir, mtime FROM dir_state;",
  })
  if type(dout) == "string" then
    for line in dout:gmatch("[^\r\n]+") do
      local dp = vim.split(line, "\t", { plain = true })
      if #dp >= 2 and by_dir[dp[1]] then
        by_dir[dp[1]].mtime = tonumber(dp[2]) or 0
      end
    end
  end
end

function M.init()
  if is_initialized then
    return true
  end

  local path = M.get_db_path()
  M.get_thumbs_dir()
  local sqlite_lib = load_sqlite_lib()

  local schema = [[
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS wallpapers (
      path TEXT PRIMARY KEY,
      dir TEXT NOT NULL,
      name TEXT NOT NULL,
      mtime INTEGER NOT NULL,
      size INTEGER NOT NULL,
      thumb_path TEXT NOT NULL,
      b64_thumb TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_wallpapers_dir ON wallpapers(dir, name);
    CREATE TABLE IF NOT EXISTS dir_state (
      dir TEXT PRIMARY KEY,
      mtime INTEGER NOT NULL,
      file_count INTEGER NOT NULL
    );
  ]]

  if sqlite_lib then
    local db_ptr = ffi.new("sqlite3*[1]")
    if sqlite_lib.sqlite3_open(path, db_ptr) == SQLITE_OK then
      db_handle = db_ptr[0]
      pcall(sqlite_lib.sqlite3_busy_timeout, db_handle, 2000)
      exec_sql(schema)
      stmt_upsert_wall = prepare_stmt(
        "INSERT OR REPLACE INTO wallpapers (path, dir, name, mtime, size, thumb_path, b64_thumb, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
      )
      stmt_delete_wall = prepare_stmt("DELETE FROM wallpapers WHERE path = ?;")
      stmt_upsert_dir = prepare_stmt(
        "INSERT OR REPLACE INTO dir_state (dir, mtime, file_count) VALUES (?, ?, ?);"
      )
      load_all_from_ffi()
      is_initialized = true
      return true
    end
  end

  if vim.fn.executable("sqlite3") == 1 then
    vim.fn.system({ "sqlite3", path, schema })
    load_all_from_cli(path)
    is_initialized = true
    return true
  end

  is_initialized = true
  return false
end

function M.get_valid_entry(path)
  if not is_initialized then
    M.init()
  end
  local entry = by_path[path]
  if not entry then
    return nil
  end
  if not entry.verified then
    local st = uv.fs_stat(entry.thumb_path)
    if not st then
      by_path[path] = nil
      return nil
    end
    entry.verified = true
  end
  return entry
end

function M.upsert(entry)
  if not entry or not entry.path or not entry.thumb_path then
    return false
  end
  if not is_initialized then
    M.init()
  end

  if not entry.b64_thumb or entry.b64_thumb == "" then
    local ok, encoded = pcall(vim.base64.encode, entry.thumb_path)
    if not ok then
      return false
    end
    entry.b64_thumb = encoded
  end
  entry.verified = true
  by_path[entry.path] = entry

  if stmt_upsert_wall and lib then
    lib.sqlite3_reset(stmt_upsert_wall)
    lib.sqlite3_clear_bindings(stmt_upsert_wall)
    lib.sqlite3_bind_text(stmt_upsert_wall, 1, entry.path, -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_text(stmt_upsert_wall, 2, entry.dir or "", -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_text(stmt_upsert_wall, 3, entry.name or "", -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_int64(stmt_upsert_wall, 4, entry.mtime or 0)
    lib.sqlite3_bind_int64(stmt_upsert_wall, 5, entry.size or 0)
    lib.sqlite3_bind_text(stmt_upsert_wall, 6, entry.thumb_path, -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_text(stmt_upsert_wall, 7, entry.b64_thumb, -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_int64(stmt_upsert_wall, 8, os.time())
    lib.sqlite3_step(stmt_upsert_wall)
    lib.sqlite3_reset(stmt_upsert_wall)
    return true
  end

  if vim.fn.executable("sqlite3") == 1 then
    local sql = string.format(
      "INSERT OR REPLACE INTO wallpapers (path, dir, name, mtime, size, thumb_path, b64_thumb, updated_at) VALUES (%s, %s, %s, %d, %d, %s, %s, %d);",
      sql_quote(entry.path),
      sql_quote(entry.dir),
      sql_quote(entry.name),
      entry.mtime or 0,
      entry.size or 0,
      sql_quote(entry.thumb_path),
      sql_quote(entry.b64_thumb),
      os.time()
    )
    vim.system({ "sqlite3", M.get_db_path(), sql })
    return true
  end

  return false
end

local function update_dir_state(dir, mtime, count)
  if stmt_upsert_dir and lib then
    lib.sqlite3_reset(stmt_upsert_dir)
    lib.sqlite3_clear_bindings(stmt_upsert_dir)
    lib.sqlite3_bind_text(stmt_upsert_dir, 1, dir, -1, SQLITE_TRANSIENT)
    lib.sqlite3_bind_int64(stmt_upsert_dir, 2, mtime)
    lib.sqlite3_bind_int64(stmt_upsert_dir, 3, count)
    lib.sqlite3_step(stmt_upsert_dir)
    lib.sqlite3_reset(stmt_upsert_dir)
  elseif vim.fn.executable("sqlite3") == 1 then
    local sql = string.format(
      "INSERT OR REPLACE INTO dir_state (dir, mtime, file_count) VALUES (%s, %d, %d);",
      sql_quote(dir),
      mtime,
      count
    )
    vim.system({ "sqlite3", M.get_db_path(), sql })
  end
end

local function delete_removed_paths(removed)
  if #removed == 0 then
    return
  end
  if stmt_delete_wall and lib then
    exec_sql("BEGIN IMMEDIATE;")
    for _, path in ipairs(removed) do
      lib.sqlite3_reset(stmt_delete_wall)
      lib.sqlite3_clear_bindings(stmt_delete_wall)
      lib.sqlite3_bind_text(stmt_delete_wall, 1, path, -1, SQLITE_TRANSIENT)
      lib.sqlite3_step(stmt_delete_wall)
      lib.sqlite3_reset(stmt_delete_wall)
    end
    exec_sql("COMMIT;")
  end
end

---Synchronizes the wallpaper directory incrementally against the SQLite cache.
---Returns: names (sorted array), max_display_width (number), pending_items (array of new/changed file descriptors)
function M.sync_dir(dir)
  if not is_initialized then
    M.init()
  end

  dir = (dir or config.opts.dir):gsub("/+$", "")
  local dir_st = uv.fs_stat(dir)
  if not dir_st then
    return {}, 0, {}
  end

  local dir_mtime = stat_mtime_ms(dir_st)
  local cached_dir = by_dir[dir]

  -- O(1) Fast path: directory mtime unchanged and all entries have valid thumbnails
  if cached_dir and cached_dir.mtime == dir_mtime and #cached_dir.names > 0 then
    local pending = {}
    for _, name in ipairs(cached_dir.names) do
      local full_path = dir .. "/" .. name
      local entry = M.get_valid_entry(full_path)
      if not entry then
        local fst = uv.fs_stat(full_path)
        if fst then
          pending[#pending + 1] = {
            path = full_path,
            dir = dir,
            name = name,
            mtime = stat_mtime_ms(fst),
            size = fst.size or 0,
          }
        end
      end
    end
    return cached_dir.names, cached_dir.max_width, pending
  end

  -- Incremental directory scan
  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}, 0, {}
  end

  local names = {}
  local seen_paths = {}
  local pending = {}
  local max_width = 0

  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local ext = name:match("%.([%w]+)$")
    if ext and IMAGE_EXTS[ext:lower()] then
      local full_path = dir .. "/" .. name
      local fst = uv.fs_stat(full_path)
      if fst and (typ == "file" or fst.type == "file") then
        local mtime = stat_mtime_ms(fst)
        local size = fst.size or 0
        seen_paths[full_path] = true
        names[#names + 1] = name

        local w = vim.fn.strdisplaywidth(name)
        if w > max_width then
          max_width = w
        end

        local existing = by_path[full_path]
        if existing and existing.mtime == mtime and existing.size == size and M.get_valid_entry(full_path) then
          -- Unchanged image: already cached in SQLite & verified on disk
        else
          pending[#pending + 1] = {
            path = full_path,
            dir = dir,
            name = name,
            mtime = mtime,
            size = size,
          }
        end
      end
    end
  end

  -- Prune deleted wallpapers from memory and SQLite
  local removed = {}
  for path, entry in pairs(by_path) do
    if entry.dir == dir and not seen_paths[path] then
      by_path[path] = nil
      removed[#removed + 1] = path
    end
  end
  delete_removed_paths(removed)

  table.sort(names)
  by_dir[dir] = {
    names = names,
    max_width = max_width,
    mtime = dir_mtime,
  }
  update_dir_state(dir, dir_mtime, #names)

  return names, max_width, pending
end

function M.close()
  if stmt_upsert_wall and lib then
    lib.sqlite3_finalize(stmt_upsert_wall)
    stmt_upsert_wall = nil
  end
  if stmt_delete_wall and lib then
    lib.sqlite3_finalize(stmt_delete_wall)
    stmt_delete_wall = nil
  end
  if stmt_upsert_dir and lib then
    lib.sqlite3_finalize(stmt_upsert_dir)
    stmt_upsert_dir = nil
  end
  if db_handle and lib then
    lib.sqlite3_close(db_handle)
    db_handle = nil
  end
  is_initialized = false
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("WallNvimDB", { clear = true }),
  callback = function()
    M.close()
  end,
})

return M
