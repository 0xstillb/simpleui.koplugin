-- sui_library.lua — SimpleUI virtual "All Books" library view
-- Queries bookinfo_cache.sqlite3 (managed by CoverBrowser/BookInfoManager) and
-- presents all EPUB + PDF books as a flat virtual FileChooser view.
-- Does not scan folders, read book files, or make network calls.

local DataStorage = require("datastorage")
local logger      = require("logger")

local M = {}

-- Virtual path sentinel — distinct from BrowseMeta's VROOT (U+E257).
local _VPATH = "\u{E258}simpleui_all_books"

-- DB path for mtime watching.
local _DB_PATH = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"

local _cache       = nil
local _cache_mtime = nil
local _patched     = false

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------

local function _getBIM()
    local ok, bim = pcall(require, "bookinfomanager")
    if not ok or not bim then
        ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    end
    return (ok and bim) and bim or nil
end

local function _getDbMtime()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(_DB_PATH, "modification")
end

local function _isCacheValid()
    if not _cache then return false end
    local mt = _getDbMtime()
    return mt ~= nil and mt == _cache_mtime
end

local _SQL_ALL = "SELECT directory, filename, title, authors, series, series_index, keywords"
              .. " FROM bookinfo ORDER BY title ASC, filename ASC"

local function _queryAllBooks()
    local bim = _getBIM()
    if not bim then return {} end
    local results = {}
    local stmt
    local ok, err = pcall(function()
        bim:openDbConnection()
        stmt = bim.db_conn:prepare(_SQL_ALL)
        while true do
            local row = stmt:step()
            if not row then break end
            local fname = row[2]
            local ext   = fname:match("%.([^.]+)$")
            if ext == "epub" or ext == "pdf" then
                results[#results + 1] = {
                    fullpath     = row[1] .. fname,
                    filename     = fname,
                    title        = row[3],
                    authors      = row[4],
                    series       = row[5],
                    series_index = tonumber(row[6]),
                    keywords     = row[7],
                }
            end
        end
    end)
    if stmt then pcall(function() stmt:finalize() end) end
    if not ok then
        logger.warn("sui_library: SQL error:", tostring(err))
        return {}
    end
    return results
end

-- ---------------------------------------------------------------------------
-- Public cache API
-- ---------------------------------------------------------------------------

function M.getAllBooks()
    if _isCacheValid() then return _cache end
    _cache       = _queryAllBooks()
    _cache_mtime = _getDbMtime()
    return _cache
end

function M.invalidateCache()
    _cache       = nil
    _cache_mtime = nil
end

function M.getDbMtime() return _getDbMtime() end
function M.getDbPath()  return _DB_PATH end

-- ---------------------------------------------------------------------------
-- FileChooser patch — intercept _VPATH and serve virtual item_table
-- ---------------------------------------------------------------------------

local function _buildItemTable(fc)
    local books = M.getAllBooks()
    local lfs   = require("libs/libkoreader-lfs")
    local items = {}
    for _, b in ipairs(books) do
        -- Skip entries whose file no longer exists on disk.
        local attr = lfs.attributes(b.fullpath)
        if attr and attr.mode == "file" then
            local label = b.authors and b.authors:gsub("\n", ", ") or ""
            items[#items + 1] = {
                text      = b.title or b.filename,
                path      = b.fullpath,
                is_file   = true,
                mandatory = label,
                _lib_title   = b.title,
                _lib_authors = b.authors,
                _lib_series  = b.series,
            }
        end
    end
    return items
end

local _orig_genItemTableFromPath = nil

local function _install()
    if _patched then return end
    _patched = true
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok_fc or not FileChooser then return end

    _orig_genItemTableFromPath        = FileChooser.genItemTableFromPath
    local orig                        = _orig_genItemTableFromPath
    FileChooser.genItemTableFromPath  = function(fc, path)
        if path == _VPATH then
            return _buildItemTable(fc)
        end
        return orig(fc, path)
    end
end

local function _uninstall()
    if not _patched then return end
    _patched = false
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fc and FileChooser and _orig_genItemTableFromPath then
        FileChooser.genItemTableFromPath = _orig_genItemTableFromPath
        _orig_genItemTableFromPath = nil
    end
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function M.isAllBooksActive(fc)
    return fc and fc.path == _VPATH
end

function M.navigateTo(fm)
    local fc = fm and fm.file_chooser
    if not fc then return false end
    _install()
    -- Mark as entry point so FileChooser hides the Up button at this level.
    fc._browse_by_meta_entry_path = _VPATH
    if fm._navbar_suppress_path_change ~= nil then
        fm._navbar_suppress_path_change = true
    end
    local ok = pcall(function() fc:changeToPath(_VPATH) end)
    if fm._navbar_suppress_path_change ~= nil then
        fm._navbar_suppress_path_change = nil
    end
    if not ok then
        fc._browse_by_meta_entry_path = nil
        return false
    end
    if fm.updateTitleBarPath then
        -- Use the translated string if available, otherwise plain English.
        local ok_i18n, _ = pcall(require, "sui_i18n")
        local label = ok_i18n and _("All Books") or "All Books"
        pcall(function() fm:updateTitleBarPath(label, true) end)
    end
    if fc.onGotoPage then
        pcall(function() fc:onGotoPage(1) end)
    end
    return true
end

-- Called from _goHome() / exitToHome to clean up virtual state.
function M.exitIfActive(fc)
    if not fc then return end
    if fc.path == _VPATH then
        fc._browse_by_meta_entry_path = nil
    end
end

-- Called from sui_patches.lua teardownAll to remove the FileChooser patch.
function M.teardown()
    _uninstall()
    M.invalidateCache()
end

return M
