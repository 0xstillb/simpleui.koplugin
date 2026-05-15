-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic/list views.

local _           = require("sui_i18n").translate
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local SUISettings = require("sui_store")

-- Widget requires at module level so the require() cache is hit once,
-- not on every cell render.
local AlphaContainer  = require("ui/widget/container/alphacontainer")
local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FileChooser     = require("ui/widget/filechooser")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = require("device").screen
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TopContainer    = require("ui/widget/container/topcontainer")

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SK = {
    enabled         = "simpleui_fc_enabled",
    show_name       = "simpleui_fc_show_name",
    hide_underline  = "simpleui_fc_hide_underline",
    label_style     = "simpleui_fc_label_style",
    label_position  = "simpleui_fc_label_position",
    badge_position  = "simpleui_fc_badge_position",
    badge_hidden    = "simpleui_fc_badge_hidden",
    cover_mode      = "simpleui_fc_cover_mode",
    label_mode      = "simpleui_fc_label_mode",
    overlay_pages    = "simpleui_fc_overlay_pages",
    overlay_series   = "simpleui_fc_overlay_series",
    overlay_progress = "simpleui_fc_overlay_progress",
    progress_mode    = "simpleui_fc_progress_mode",
    overlay_new      = "simpleui_fc_overlay_new",
    series_grouping = "simpleui_fc_series_grouping",
    subfolder_cover = "simpleui_fc_subfolder_cover",
    recursive_cover = "simpleui_fc_recursive_cover",
    label_scale     = "simpleui_fc_label_scale",
    folder_style      = "simpleui_fc_folder_style",
    hide_spine        = "simpleui_fc_hide_spine",
    show_title_strip  = "simpleui_fc_show_title_strip",
    show_author_strip = "simpleui_fc_show_author_strip",
    badge_color_pages    = "simpleui_fc_badge_color_pages",
    badge_color_series   = "simpleui_fc_badge_color_series",
    badge_color_progress = "simpleui_fc_badge_color_progress",
    badge_color_new      = "simpleui_fc_badge_color_new",
    badge_color_folder   = "simpleui_fc_badge_color_folder",
}

-- ---------------------------------------------------------------------------
-- Module table and forward declarations
-- ---------------------------------------------------------------------------

local M = {}

-- Series-grouping state — forward-declared so all functions can close over them.
local _sg_current           = nil
local _sg_items_cache       = {}
local _sg_last_evicted_path = nil

-- ---------------------------------------------------------------------------
-- Settings API
-- ---------------------------------------------------------------------------

function M.isEnabled()   return SUISettings:isTrue(SK.enabled)          end
function M.setEnabled(v) SUISettings:saveSetting(SK.enabled, v)         end

local function _getFlag(key)      return SUISettings:readSetting(key) ~= false end
local function _setFlag(key, v)   SUISettings:saveSetting(key, v)              end

function M.getShowName()       return _getFlag(SK.show_name)      end
function M.setShowName(v)      _setFlag(SK.show_name, v)          end
function M.getHideUnderline()  return _getFlag(SK.hide_underline) end
function M.setHideUnderline(v) _setFlag(SK.hide_underline, v)     end

-- "alpha" (default) = semitransparent white overlay; "frame" = solid grey border.
function M.getLabelStyle()    return SUISettings:readSetting(SK.label_style)    or "alpha"   end
function M.setLabelStyle(v)   SUISettings:saveSetting(SK.label_style, v)                     end

-- "bottom" (default) | "center" | "top"
function M.getLabelPosition()  return SUISettings:readSetting(SK.label_position) or "bottom" end
function M.setLabelPosition(v) SUISettings:saveSetting(SK.label_position, v)                 end

-- "top" (default) | "bottom"
function M.getBadgePosition()  return SUISettings:readSetting(SK.badge_position) or "top"   end
function M.setBadgePosition(v) SUISettings:saveSetting(SK.badge_position, v)                 end

function M.getBadgeHidden()  return SUISettings:isTrue(SK.badge_hidden)                      end
function M.setBadgeHidden(v) SUISettings:saveSetting(SK.badge_hidden, v)                     end

-- "default" = scale-to-fit; "2_3" = force 2:3 aspect ratio.
function M.getCoverMode()    return SUISettings:readSetting(SK.cover_mode) or "default"      end
function M.setCoverMode(v)   SUISettings:saveSetting(SK.cover_mode, v)                       end

-- "overlay" (default) = folder name on cover; "hidden" = no label.
function M.getLabelMode()    return SUISettings:readSetting(SK.label_mode) or "overlay"      end
function M.setLabelMode(v)   SUISettings:saveSetting(SK.label_mode, v)                       end

-- Pages badge on book covers (default on).
function M.getOverlayPages()  return SUISettings:readSetting(SK.overlay_pages) ~= false      end
function M.setOverlayPages(v) _setFlag(SK.overlay_pages, v)                                        end

-- Series index badge on book covers (default off).
function M.getOverlaySeries()  return SUISettings:isTrue(SK.overlay_series)                  end
function M.setOverlaySeries(v) _setFlag(SK.overlay_series, v)                                      end

-- Progress pentagon badge on book covers (default on).
-- Shows: percentage read · checkmark for completed · bare pentagon for unstarted.
-- When active, native KOReader marks (dog-ear, progress bar, collection star,
-- description hint) are suppressed to avoid visual overlap.
function M.getOverlayProgress()  return SUISettings:readSetting(SK.overlay_progress) ~= false end
function M.setOverlayProgress(v) _setFlag(SK.overlay_progress, v)                                   end

-- Progress display mode: "banner" (default) = pentagon badge overlay;
-- "native" = suppress badge, show native KOReader progress indicators;
-- "none"   = suppress badge AND native indicators.
function M.getProgressMode()
    return SUISettings:readSetting(SK.progress_mode) or "banner"
end
function M.setProgressMode(v)
    SUISettings:saveSetting(SK.progress_mode, v)
    -- Keep legacy overlay_progress flag in sync so external code that reads
    -- it directly still behaves correctly.
    _setFlag(SK.overlay_progress, v == "banner")
    -- Manage the native collection mark (collection_show_mark):
    --   banner/none → disable it (plugin redraws it at bottom-right in banner mode;
    --                 none mode suppresses all indicators).
    --   native      → restore it so KOReader draws the star at top-right normally.
    if v == "banner" or v == "none" then
        G_reader_settings:saveSetting("collection_show_mark", false)
    elseif v == "native" then
        G_reader_settings:saveSetting("collection_show_mark", true)
    end
end

-- "New" rounded-rectangle badge on book covers for unread books (default on).
-- Only shown when percent_finished is nil and status is not "complete" or "abandoned".
function M.getOverlayNew()  return SUISettings:nilOrTrue(SK.overlay_new)  end
function M.setOverlayNew(v) _setFlag(SK.overlay_new, v)                      end

-- Virtual series folders in the mosaic (default off).
function M.getSeriesGrouping()  return SUISettings:isTrue(SK.series_grouping)                end
function M.setSeriesGrouping(v) _setFlag(SK.series_grouping, v)                                    end

-- Placeholder cover for folders with no direct ebooks (default off).
function M.getSubfolderCover()  return SUISettings:isTrue(SK.subfolder_cover)                end
function M.setSubfolderCover(v) _setFlag(SK.subfolder_cover, v)                                    end

-- Scan up to 3 subfolder levels for a cached cover (default off).
function M.getRecursiveCover()  return SUISettings:isTrue(SK.recursive_cover)                end
function M.setRecursiveCover(v) _setFlag(SK.recursive_cover, v)                                    end

-- Folder cover display style: "single" (default, selectable cover), "quad" (2×2 grid),
-- or "auto" (single when <4 books, quad when ≥4 books).
function M.getFolderStyle()    return SUISettings:readSetting(SK.folder_style) or "single"   end
function M.setFolderStyle(v)   SUISettings:saveSetting(SK.folder_style, v)                   end

-- _resolveStyle is defined further below (after _entriesWithNoFilter and
-- _collectCoversRecursive are in scope).
local _resolveStyle

-- Hide the book spine decoration on folder covers (default: spine shown).
function M.getHideSpine()  return SUISettings:isTrue(SK.hide_spine)  end
function M.setHideSpine(v) SUISettings:saveSetting(SK.hide_spine, v) end

-- Show book title below covers in mosaic mode (default: off). Requires restart.
function M.getShowTitleStrip()   return SUISettings:isTrue(SK.show_title_strip)  end
function M.setShowTitleStrip(v)  SUISettings:saveSetting(SK.show_title_strip, v) end

-- Show book author below covers in mosaic mode (default: off). Requires restart.
function M.getShowAuthorStrip()  return SUISettings:isTrue(SK.show_author_strip)  end
function M.setShowAuthorStrip(v) SUISettings:saveSetting(SK.show_author_strip, v) end

-- Per-badge color settings.
-- "dark"  = black background, white text.
-- "light" = white background, black text.
-- Defaults: progress/new/folder -> dark; pages/series -> light.
function M.getBadgeColorPages()     return SUISettings:readSetting(SK.badge_color_pages)    or "light" end
function M.setBadgeColorPages(v)    SUISettings:saveSetting(SK.badge_color_pages, v)    end

function M.getBadgeColorSeries()    return SUISettings:readSetting(SK.badge_color_series)   or "light" end
function M.setBadgeColorSeries(v)   SUISettings:saveSetting(SK.badge_color_series, v)   end

function M.getBadgeColorProgress()  return SUISettings:readSetting(SK.badge_color_progress) or "dark"  end
function M.setBadgeColorProgress(v) SUISettings:saveSetting(SK.badge_color_progress, v) end

function M.getBadgeColorNew()       return SUISettings:readSetting(SK.badge_color_new)      or "dark"  end
function M.setBadgeColorNew(v)      SUISettings:saveSetting(SK.badge_color_new, v)      end

function M.getBadgeColorFolder()    return SUISettings:readSetting(SK.badge_color_folder)   or "dark"  end
function M.setBadgeColorFolder(v)   SUISettings:saveSetting(SK.badge_color_folder, v)   end

-- Folder label text scale: integer %, clamped to [50, 200], default 100.
local _FC_SCALE_MIN  = 50
local _FC_SCALE_MAX  = 200
local _FC_SCALE_DEF  = 100
local _FC_SCALE_STEP = 10
M.FC_LABEL_SCALE_MIN  = _FC_SCALE_MIN
M.FC_LABEL_SCALE_MAX  = _FC_SCALE_MAX
M.FC_LABEL_SCALE_DEF  = _FC_SCALE_DEF
M.FC_LABEL_SCALE_STEP = _FC_SCALE_STEP

local function _clampFCScale(n)
    return math.max(_FC_SCALE_MIN, math.min(_FC_SCALE_MAX, math.floor(n)))
end

function M.getLabelScalePct()
    local n = tonumber(SUISettings:readSetting(SK.label_scale))
    if not n then return _FC_SCALE_DEF end
    return _clampFCScale(n)
end
function M.getLabelScale()    return M.getLabelScalePct() / 100 end
function M.setLabelScale(pct) SUISettings:saveSetting(SK.label_scale, _clampFCScale(pct)) end

-- ---------------------------------------------------------------------------
-- Module-level constants — computed once from device DPI.
-- ---------------------------------------------------------------------------

local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))
local _BASE_NB_SIZE = Screen:scaleBySize(10)
local _BASE_NB_FS   = Screen:scaleBySize(4)
local _BASE_DIR_FS  = Screen:scaleBySize(5)

local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2
local _SPINE_COLOR = Blitbuffer.gray(0.70)

local _LATERAL_PAD        = Screen:scaleBySize(10)
local _VERTICAL_PAD       = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE  = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

local _LABEL_ALPHA = 0.75

-- Title/author strip height (pixels). Set by M.install() to the exact value
-- computed for the session; 0 when both options are disabled.
-- Module-level so _computeCellGeometry (which is module-scope) can read it.
local _module_strip_h = 0

-- Badge geometry constants.
-- _BADGE_FONT_SZ is still used by the book-count circle badge (_buildBadge).
-- Text badges (pages, series, "New") derive all geometry from eff_size instead.
local _BADGE_FONT_SZ     = Screen:scaleBySize(5)
local _BADGE_TOP_INSET   = Screen:scaleBySize(0)   -- pentagon Y: flush with cover top edge
local _BADGE_RIGHT_INSET = Screen:scaleBySize(8)   -- inset from cover edge for all corner badges
local _BADGE_BAR_H       = Screen:scaleBySize(8)   -- progress-bar height (badge Y anchor)
local _BADGE_BAR_GAP     = Screen:scaleBySize(4)   -- gap between pages badge and progress bar


-- Module-level font-size cache for _getFolderNameWidget.
-- Key: display_text .. "\0" .. available_w .. "\0" .. max_font_size
-- Survives MosaicMenuItem recycling across scrolls, unlike a per-item cache.
-- Two-generation design (same as the item cache): each generation holds at most
-- _FS_CACHE_MAX entries; when full the current gen is demoted and a fresh one
-- starts. Effective capacity is 2 × _FS_CACHE_MAX with smooth eviction.
local _FS_CACHE_MAX   = 200
local _fs_cache_a     = {}
local _fs_cache_b     = {}
local _fs_cache_a_cnt = 0

local function _fsCacheGet(key)
    return _fs_cache_a[key] or _fs_cache_b[key]
end

local function _fsCacheSet(key, value)
    if _fs_cache_a_cnt >= _FS_CACHE_MAX then
        _fs_cache_b   = _fs_cache_a
        _fs_cache_a   = {}
        _fs_cache_a_cnt = 0
    end
    _fs_cache_a[key] = value
    _fs_cache_a_cnt  = _fs_cache_a_cnt + 1
end

local _PLUGIN_DIR  = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _ICON_PATH   = _PLUGIN_DIR .. "icons/custom.svg"
local _ICON_EXISTS = lfs.attributes(_ICON_PATH, "mode") == "file"

-- ---------------------------------------------------------------------------
-- Cover-file discovery
-- ---------------------------------------------------------------------------

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- Per-directory cache for .cover.* lookups.
-- Values: filepath string on hit, false on confirmed miss.
-- Invalidated in refreshPath when the library was visited (files may have changed).
-- Capped at _DIR_CACHE_MAX entries (two-generation) to bound memory use.
local _DIR_CACHE_MAX    = 300
local _cover_file_cache = {}
local _cfc_b            = {}
local _cfc_cnt          = 0

local function _cfcGet(key)   return _cover_file_cache[key] or _cfc_b[key] end
local function _cfcSet(key, v)
    if _cfc_cnt >= _DIR_CACHE_MAX then
        _cfc_b            = _cover_file_cache
        _cover_file_cache = {}
        _cfc_cnt          = 0
    end
    _cover_file_cache[key] = v
    _cfc_cnt = _cfc_cnt + 1
end

local function findCover(dir_path)
    local cached = _cfcGet(dir_path)
    if cached ~= nil then return cached or nil end
    local base = dir_path .. "/.cover"
    for i = 1, #_COVER_EXTS do
        local fname = base .. _COVER_EXTS[i]
        if lfs.attributes(fname, "mode") == "file" then
            _cfcSet(dir_path, fname)
            return fname
        end
    end
    _cfcSet(dir_path, false)
    return nil
end

-- Per-directory cache for the ListMenuItem lfs.dir cover scan.
-- Same invalidation rules as _cover_file_cache.
-- Capped at _DIR_CACHE_MAX entries (two-generation).
local _lm_dir_cover_cache = {}
local _lmc_b              = {}
local _lmc_cnt            = 0

local function _lmcGet(key)   return _lm_dir_cover_cache[key] or _lmc_b[key] end
local function _lmcSet(key, v)
    if _lmc_cnt >= _DIR_CACHE_MAX then
        _lmc_b            = _lm_dir_cover_cache
        _lm_dir_cover_cache = {}
        _lmc_cnt          = 0
    end
    _lm_dir_cover_cache[key] = v
    _lmc_cnt = _lmc_cnt + 1
end

-- ---------------------------------------------------------------------------
-- Patch helpers
-- ---------------------------------------------------------------------------

local function _getMosaicMenuItemAndPatch()
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_mm or not MosaicMenu then return nil, nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil, nil end
    return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem"), userpatch
end

local function _getListMenuItem()
    local ok_lm, ListMenu = pcall(require, "listmenu")
    if not ok_lm or not ListMenu then return nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil end
    return userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
end

-- ---------------------------------------------------------------------------
-- Cover-override settings
-- Stored in SUISettings under "simpleui_fc_covers": { [dir_path] = book_path }
-- ---------------------------------------------------------------------------

local _FC_COVERS_KEY = "simpleui_fc_covers"

-- Lazy-loaded, mutated in-place — never goes stale during a session.
local _overrides_cache = nil

local function _getCoverOverrides()
    if not _overrides_cache then
        _overrides_cache = SUISettings:readSetting(_FC_COVERS_KEY) or {}
    end
    return _overrides_cache
end

local function _saveCoverOverride(dir_path, book_path)
    local t = _getCoverOverrides()
    t[dir_path] = book_path
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

local function _clearCoverOverride(dir_path)
    local t = _getCoverOverrides()
    t[dir_path] = nil
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

-- ---------------------------------------------------------------------------
-- Shared helper: run genItemTableFromPath with the status filter suppressed.
-- Folders with "show only new/reading" active would otherwise hide books that
-- can still supply cover art. Returns the entries table or nil.
-- ---------------------------------------------------------------------------
local function _entriesWithNoFilter(menu, dir_path)
    local saved = FileChooser.show_filter
    FileChooser.show_filter = {}
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved
    return entries
end

-- ---------------------------------------------------------------------------
-- Folder-item invalidation: clears _foldercover_processed so the next
-- updateItems re-fetches the cover. Triggers a full redraw of the grid.
-- ---------------------------------------------------------------------------
local function _invalidateFolderItem(menu, dir_path)
    if not menu then return end
    if menu.layout then
        for _, row in ipairs(menu.layout) do
            for _, item in ipairs(row) do
                if item._foldercover_processed
                        and item.entry and item.entry.path == dir_path then
                    item._foldercover_processed = false
                end
            end
        end
    end
    menu:updateItems(1, true)
end

-- ---------------------------------------------------------------------------
-- Recursive cover search: scans dir_path up to max_depth levels for any
-- cached book cover. Returns { data, w, h } or nil.
-- ---------------------------------------------------------------------------
-- Collect up to `needed` covers from dir_path recursively (files first, then
-- subdirs). Returns an array that may be shorter than needed if not enough
-- covers are cached yet.
local function _collectCoversRecursive(menu, dir_path, depth, max_depth, needed, BookInfoManager)
    if depth > max_depth or needed <= 0 then return {} end

    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return {} end

    local covers  = {}
    local subdirs = {}
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, menu.cover_specs)
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
                if #covers >= needed then return covers end
            end
        else
            if not entry.is_go_up then
                subdirs[#subdirs + 1] = entry
            end
        end
    end

    -- Still need more — recurse into subdirectories.
    for _, entry in ipairs(subdirs) do
        if #covers >= needed then break end
        local sub = _collectCoversRecursive(
            menu, entry.path, depth + 1, max_depth, needed - #covers, BookInfoManager)
        for _, c in ipairs(sub) do
            covers[#covers + 1] = c
            if #covers >= needed then break end
        end
    end

    return covers
end

-- Compatibility shim: find exactly one cover recursively (used by the
-- single-cover bookless-folder path).
local function _findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    local found = _collectCoversRecursive(menu, dir_path, depth, max_depth, 1, BookInfoManager)
    return found[1]
end

-- ---------------------------------------------------------------------------
-- Resolve the effective folder style for a specific folder.
-- "auto" mode counts the books and returns "quad" (≥4 books) or "single" (<4).
-- All other modes are returned as-is.
-- The optional `entry` argument is used to detect virtual folder types whose
-- synthetic paths cannot be scanned via _entriesWithNoFilter.
-- ---------------------------------------------------------------------------
_resolveStyle = function(menu, dir_path, entry)
    local style = M.getFolderStyle()
    if style ~= "auto" then return style end
    if not menu or not dir_path then return "single" end

    -- ── Series-group virtual folder ───────────────────────────────────────
    -- Series group items have a synthetic path (base_dir..series_name) that
    -- is neither a real filesystem directory nor a browsemeta virtual path.
    -- _entriesWithNoFilter → genItemTableFromPath would return nothing for
    -- them, so we count directly from the cache that was populated during
    -- series-grouping injection.
    local is_sg = (entry and entry.is_series_group) or (_sg_items_cache[dir_path] ~= nil)
    if is_sg then
        local items = (entry and entry.series_items) or _sg_items_cache[dir_path]
        if items and #items >= 4 then return "quad" end
        return "single"
    end

    -- Count books directly inside the folder.
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return "single" end
    local book_count = 0
    for _, e in ipairs(entries) do
        if e.is_file or e.file then
            book_count = book_count + 1
            if book_count >= 4 then return "quad" end
        end
    end
    -- If recursive cover is enabled, also count books from subfolders.
    if book_count < 4 and M.getRecursiveCover() then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager then
            for _, e in ipairs(entries) do
                if not (e.is_file or e.file) and not e.is_go_up then
                    local sub = _collectCoversRecursive(
                        menu, e.path, 1, 3, 4 - book_count, BookInfoManager)
                    book_count = book_count + #sub
                    if book_count >= 4 then return "quad" end
                end
            end
        end
    end
    return "single"
end

-- Public wrapper so other modules (e.g. sui_browsemeta) can resolve the
-- effective folder style without duplicating the auto-count logic.
-- Returns "single" or "quad".
function M.resolveStyle(fc, dir_path, entry)
    return _resolveStyle(fc, dir_path, entry)
end

-- ---------------------------------------------------------------------------
-- Book collection for the cover picker dialog.
-- Recursion follows the same max_depth used by the automatic scan.
-- Capped at _COLLECT_MAX entries so the picker dialog stays usable.
local _COLLECT_MAX = 50
local function _collectBooks(menu, dir_path, depth, max_depth, out)
    if #out >= _COLLECT_MAX then return end
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return end
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            out[#out + 1] = entry
            if #out >= _COLLECT_MAX then return end
        elseif depth < max_depth then
            _collectBooks(menu, entry.path, depth + 1, max_depth, out)
            if #out >= _COLLECT_MAX then return end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cover picker dialogs
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- _createCollectionFromSeriesGroup(vpath, series_name)
--
-- Called when the user long-presses a series-group folder in the folder-covers
-- browser and selects "Create collection".
--
-- Behaviour mirrors _createCollectionFromVirtualFolder in sui_browsemeta.lua:
--   • Pre-fills the InputDialog with the series name so the user can edit it.
--   • Reads the book paths from _sg_items_cache[vpath].
--   • Calls ReadCollection:addCollection + addItem for every book, then writes.
--   • Shows an InfoMessage with the final count.
-- ---------------------------------------------------------------------------
local function _createCollectionFromSeriesGroup(vpath, series_name)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local T           = require("ffi/util").template

    local series_items = _sg_items_cache[vpath]
    if not series_items or #series_items == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No books found in this series."),
            timeout = 2,
        })
        return
    end

    local RC = require("readcollection")

    local input_dialog
    input_dialog = InputDialog:new{
        title   = _("New collection name"),
        input   = series_name or "",
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function()
                    UIManager:close(input_dialog)
                end,
            },
            {
                text = _("Create"),
                callback = function()
                    local name = input_dialog:getInputText()
                    if name == "" then return end
                    UIManager:close(input_dialog)

                    if RC.coll[name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Collection already exists: %1"), name),
                        })
                        return
                    end

                    RC:addCollection(name)
                    local count = 0
                    for _, item in ipairs(series_items) do
                        local fp = item.path
                        if fp and not RC.coll[name][fp] then
                            RC:addItem(fp, name)
                            count = count + 1
                        end
                    end
                    RC:write({ [name] = true })

                    UIManager:show(InfoMessage:new{
                        text    = T(_("Collection \"%1\" created with %2 books."),
                                    name, count),
                        timeout = 3,
                    })
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function _openSeriesGroupCoverPicker(vpath, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local series_items = _sg_items_cache[vpath]
    if not series_items or #series_items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this series."), timeout = 2 })
        return
    end

    local overrides    = _getCoverOverrides()
    local cur_override = overrides[vpath]
    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "✓ " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            _clearCoverOverride(vpath)
            _invalidateFolderItem(menu, vpath)
        end,
    }}

    for _, item in ipairs(series_items) do
        local fp = item.path
        if fp then
            local bi    = BookInfoManager:getBookInfo(fp, false)
            local title = (bi and bi.title and bi.title ~= "")
                and bi.title
                or (fp:match("([^/]+)%.[^%.]+$") or fp)
            local _fp   = fp
            buttons[#buttons + 1] = {{
                text = ((cur_override == _fp) and "✓ " or "  ") .. title,
                callback = function()
                    UIManager:close(picker)
                    _saveCoverOverride(vpath, _fp)
                    _invalidateFolderItem(menu, vpath)
                end,
            }}
        end
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{ title = _("Folder cover"), title_align = "center", buttons = buttons }
    UIManager:show(picker)
end

local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local books     = {}
    local max_depth = M.getRecursiveCover() and 3 or 1
    _collectBooks(menu, dir_path, 1, max_depth, books)

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this folder."), timeout = 2 })
        return
    end

    local overrides    = _getCoverOverrides()
    local cur_override = overrides[dir_path]
    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "✓ " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            _clearCoverOverride(dir_path)
            _invalidateFolderItem(menu, dir_path)
        end,
    }}

    for _, entry in ipairs(books) do
        local fp      = entry.path
        local bi      = BookInfoManager:getBookInfo(fp, false)
        local title   = (bi and bi.title and bi.title ~= "")
            and bi.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        local rel       = fp:sub(#dir_path + 2)
        local subfolder = rel:match("^(.+)/[^/]+$")
        local label     = subfolder and (title .. "  [" .. subfolder .. "]") or title
        buttons[#buttons + 1] = {{
            text = ((cur_override == fp) and "✓ " or "  ") .. label,
            callback = function()
                UIManager:close(picker)
                _saveCoverOverride(dir_path, fp)
                _invalidateFolderItem(menu, dir_path)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{ title = _("Folder cover"), title_align = "center", buttons = buttons }
    UIManager:show(picker)
end

-- ---------------------------------------------------------------------------
-- Long-press "Set folder cover…" button in the FileManager file dialog.
-- ---------------------------------------------------------------------------

local function _installFileDialogButton(BookInfoManager)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end

    -- Button 1: cover picker (hidden in quad mode for series/virtual folders).
    FileManager:addFileDialogButtons("simpleui_fc_cover",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end

            local fc         = FileManager.instance and FileManager.instance.file_chooser
            local item_entry = nil
            if fc and fc.item_table then
                for _, it in ipairs(fc.item_table) do
                    if it.path == file then item_entry = it; break end
                end
            end

            -- A series group is identified either by the item flag (authoritative)
            -- or by the _sg_items_cache entry (populated when series grouping is on).
            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (_sg_items_cache[file] ~= nil)
            local is_virtual_meta   = item_entry and item_entry.is_virtual_meta_leaf

            local label
            -- Resolve effective style for this folder (handles "auto" mode).
            local effective_style = _resolveStyle(fc, file, item_entry)
            -- All folder types hide the picker in quad mosaic mode.
            local in_list_view = fc and fc.display_mode_type == "list"
            if effective_style == "quad" and not in_list_view then return nil end
            label = _("Set folder cover")

            return {{
                text = label,
                callback = function()
                    local UIManager = require("ui/uimanager")
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    if not fc then return end
                    if is_virtual_series then
                        _openSeriesGroupCoverPicker(file, fc, BookInfoManager)
                    elseif is_virtual_meta then
                        local ok_bm, BM = pcall(require, "sui_browsemeta")
                        if ok_bm and BM and BM.openVirtualCoverPicker then
                            BM.openVirtualCoverPicker(file, fc)
                        end
                    else
                        _openFolderCoverPicker(file, fc, BookInfoManager)
                    end
                end,
            }}
        end
    )

    -- Button 2: "Create collection" for series-group folders.
    -- Available in all view modes (including quad/4-grid where the cover
    -- picker is suppressed), mirroring the behaviour of virtual meta folders.
    FileManager:addFileDialogButtons("simpleui_fc_series_collection",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end
            if not M.getSeriesGrouping() then return nil end

            local fc         = FileManager.instance and FileManager.instance.file_chooser
            local item_entry = nil
            if fc and fc.item_table then
                for _, it in ipairs(fc.item_table) do
                    if it.path == file then item_entry = it; break end
                end
            end

            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (_sg_items_cache[file] ~= nil)
            if not is_virtual_series then return nil end

            local series_name = (item_entry and item_entry.text) or ""

            return {{
                text = _("Create collection"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    _createCollectionFromSeriesGroup(file, series_name)
                end,
            }}
        end
    )
end

local function _uninstallFileDialogButton()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end
    FileManager:removeFileDialogButtons("simpleui_fc_cover")
    FileManager:removeFileDialogButtons("simpleui_fc_series_collection")
end

-- ---------------------------------------------------------------------------
-- Item-table cache — single-entry cache for FileChooser:genItemTableFromPath.
--
-- Strategy: cache the complete sorted item table for the current directory.
-- The cache key encodes path + directory mtime + all settings that affect
-- the list (collate, filter, show_hidden). On a cache hit the entire
-- lfs.dir scan, sort, and per-item getListItem() calls are skipped.
--
-- A single lfs.attributes() call per navigation is the only overhead.
-- Memory cost: one table reference — the same object FileChooser already
-- holds, not a copy.
--
-- Invalidation:
--   • Directory changed   → automatic (mtime or path differ in the key).
--   • Closing a book      → _itc_invalidate() in refreshPath.
--   • Status/prop change  → _itc_invalidate() via setBookInfoCacheProperty.
--   • access-time collate → cache disabled (mtime never reflects reads).
--   • _dummy calls        → bypassed (used by cover-collection helpers).
-- ---------------------------------------------------------------------------

-- Single cache entry: {key=string, t=item_table} or nil.
local _itc = nil

local _orig_setBookInfoCacheProperty = nil
local _orig_genItemTableFromPath     = nil

local function _itc_invalidate()
    _itc = nil
end

local function _itc_key(path, fc)
    local mtime      = lfs.attributes(path, "modification") or 0
    local filter_raw = fc.show_filter and fc.show_filter.status
    local filter_str
    if type(filter_raw) == "table" then
        local parts = {}
        for k, v in pairs(filter_raw) do
            if v then parts[#parts + 1] = tostring(k) end
        end
        table.sort(parts)
        filter_str = table.concat(parts, "\1")
    else
        filter_str = tostring(filter_raw or "")
    end
    return path .. "\0" .. mtime .. "\0"
        .. (G_reader_settings:readSetting("collate") or "strcoll") .. "\0"
        .. tostring(G_reader_settings:isTrue("collate_mixed"))     .. "\0"
        .. tostring(G_reader_settings:isTrue("reverse_collate"))   .. "\0"
        .. tostring(fc.show_hidden or false) .. "\0"
        .. filter_str
end

local function _installItemCache()
    if FileChooser._simpleui_fc_cache_patched then return end
    FileChooser._simpleui_fc_cache_patched = true

    -- Invalidate on any book status/property change (e.g. marking read).
    -- The sort position depends on percent_finished, so stale items would
    -- appear in the wrong place until the next directory change.
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.setBookInfoCacheProperty then
        _orig_setBookInfoCacheProperty = BookList.setBookInfoCacheProperty
        BookList.setBookInfoCacheProperty = function(file, prop_name, prop_value)
            _itc_invalidate()
            return _orig_setBookInfoCacheProperty(file, prop_name, prop_value)
        end
    end

    _orig_genItemTableFromPath = FileChooser.genItemTableFromPath

    FileChooser.genItemTableFromPath = function(fc, path)
        -- Bypass for non-FM instances (PathChooser, dialogs) and for
        -- _dummy=true calls used by cover-collection helpers.
        if fc._dummy or fc.name ~= "filemanager" then
            return _orig_genItemTableFromPath(fc, path)
        end

        -- access-time collate: directory mtime doesn't change when books are
        -- read, so the key would never change. Disable the cache for this mode.
        if (G_reader_settings:readSetting("collate") or "strcoll") == "access" then
            _itc = nil
            return _orig_genItemTableFromPath(fc, path)
        end

        local key = _itc_key(path, fc)
        if _itc and _itc.key == key then
            return _itc.t
        end

        local result = _orig_genItemTableFromPath(fc, path)

        -- Do not cache virtual series-grouping views: their synthetic path
        -- has no reliable mtime, so stale data would never be evicted.
        if not (result and result._sg_is_series_view) then
            _itc = { key = key, t = result }
        else
            _itc = nil
        end

        return result
    end
end

local function _uninstallItemCache()
    if not FileChooser._simpleui_fc_cache_patched then return end
    FileChooser.genItemTableFromPath  = _orig_genItemTableFromPath
    _orig_genItemTableFromPath        = nil
    FileChooser._simpleui_fc_cache_patched = nil
    if _orig_setBookInfoCacheProperty then
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        if ok_bl and BookList then
            BookList.setBookInfoCacheProperty = _orig_setBookInfoCacheProperty
        end
        _orig_setBookInfoCacheProperty = nil
    end
    _itc = nil
end

function M.invalidateCache()
    _itc = nil
end

-- Returns a sub_items table for the "Progress badge" entry in the settings menu.
-- The caller is responsible for inserting it into the parent menu table.
function M.getProgressModeMenuItems()
    local function _set(mode)
        M.setProgressMode(mode)
        -- Force a full redraw so the change is visible immediately.
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager then
            local ok_fm, fm_mod = pcall(require, "apps/filemanager/filemanager")
            if ok_fm and fm_mod and fm_mod.instance then
                fm_mod.instance.file_chooser:updateItems()
            end
        end
    end

    return {
        {
            text_func = function()
                return _("Banner")
            end,
            checked_func = function() return M.getProgressMode() == "banner" end,
            callback = function() _set("banner") end,
        },
        {
            text_func = function()
                return _("Native")
            end,
            checked_func = function() return M.getProgressMode() == "native" end,
            callback = function() _set("native") end,
        },
        {
            text_func = function()
                return _("None")
            end,
            checked_func = function() return M.getProgressMode() == "none" end,
            callback = function() _set("none") end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Series grouping — virtual folders for multi-book series.
--
-- _sg_current:  active virtual-folder state while browsing a series group,
--               nil when in a real filesystem folder.
-- _sg_items_cache: vpath → { series_items }
-- ---------------------------------------------------------------------------

-- Groups series books from item_table into virtual folder items.
-- Modifies item_table in place. No-ops when grouping is not applicable.
local function _sgProcessItemTable(item_table, file_chooser)
    if not M.getSeriesGrouping()                  then return end
    if not file_chooser or not item_table         then return end
    if item_table._sg_is_series_view              then return end
    if file_chooser.show_current_dir_for_hold     then return end

    -- Evict stale _sg_items_cache entries for the current directory.
    -- Without this the cache grows unboundedly across reader→HS cycles.
    -- The guard skips the loop when the path hasn't changed since last eviction.
    local current_path = file_chooser.path
    if current_path and current_path ~= _sg_last_evicted_path then
        _sg_last_evicted_path = current_path
        local prefix = current_path
        if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
        for k in pairs(_sg_items_cache) do
            if k:sub(1, #prefix) == prefix then _sg_items_cache[k] = nil end
        end
    end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local series_map      = {}
    local processed       = {}
    local book_count      = 0
    local no_series_count = 0

    for _, item in ipairs(item_table) do
        if item.is_go_up then
            processed[#processed + 1] = item
        else
            if not item.sort_percent     then item.sort_percent     = 0     end
            if not item.percent_finished then item.percent_finished = 0     end
            if not item.opened           then item.opened           = false end

            local handled = false

            if (item.is_file or item.file) and item.path then
                book_count = book_count + 1
                local doc_props = item.doc_props or BookInfoManager:getDocProps(item.path)
                local sname = doc_props and doc_props.series
                if sname and sname ~= "\u{FFFF}" then
                    item._sg_series_index = doc_props.series_index or 0
                    if not series_map[sname] then
                        local base_path  = item.path:match("(.*/)") or ""
                        local group_attr = {}
                        if item.attr then
                            for k, v in pairs(item.attr) do group_attr[k] = v end
                        end
                        group_attr.mode = "directory"
                        local vpath      = base_path .. sname
                        local group_item = {
                            text             = sname,
                            is_file          = false,
                            is_directory     = true,
                            is_series_group  = true,
                            path             = vpath,
                            series_items     = { item },
                            attr             = group_attr,
                            mode             = "directory",
                            sort_percent     = item.sort_percent,
                            percent_finished = item.percent_finished,
                            opened           = item.opened,
                            doc_props        = item.doc_props or {
                                series        = sname,
                                series_index  = 0,
                                display_title = sname,
                            },
                            suffix = item.suffix,
                        }
                        series_map[sname]             = group_item
                        group_item._sg_list_index     = #processed + 1
                        processed[#processed + 1]     = group_item
                    else
                        local si = series_map[sname].series_items
                        si[#si + 1] = item
                    end
                    handled = true
                else
                    no_series_count = no_series_count + 1
                end
            end

            if not handled then processed[#processed + 1] = item end
        end
    end

    -- If every book belongs to the same single series the folder is already
    -- organized — skip grouping to avoid a redundant wrapping level.
    local series_count = 0
    for _ in pairs(series_map) do
        series_count = series_count + 1
        if series_count > 1 then break end
    end
    if series_count == 1 and no_series_count == 0 and book_count > 0 then return end

    -- Ungroup singletons; sort and cache multi-book groups.
    for _, group in pairs(series_map) do
        local items = group.series_items
        if #items == 1 then
            local idx = group._sg_list_index
            if idx and processed[idx] == group then processed[idx] = items[1] end
        else
            table.sort(items, function(a, b)
                return (a._sg_series_index or 0) < (b._sg_series_index or 0)
            end)
            group.mandatory           = tostring(#items) .. " \u{F016}"
            _sg_items_cache[group.path] = items
        end
    end

    -- Re-sort the full processed list using FileChooser's sort function.
    -- Read sort settings once — G_reader_settings calls are not free.
    local ok_collate, collate = pcall(function() return file_chooser:getCollate() end)
    local collate_obj = ok_collate and collate or nil
    local reverse     = G_reader_settings:isTrue("reverse_collate")
    local sort_func
    pcall(function() sort_func = file_chooser:getSortingFunction(collate_obj, reverse) end)
    local mixed = G_reader_settings:isTrue("collate_mixed")
        and collate_obj and collate_obj.can_collate_mixed

    local final   = {}
    local up_item = nil

    if mixed then
        local to_sort = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then up_item = item
            else to_sort[#to_sort + 1] = item end
        end
        if sort_func then pcall(table.sort, to_sort, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, item in ipairs(to_sort) do final[#final + 1] = item end
    else
        local dirs  = {}
        local files = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then
                up_item = item
            elseif item.is_directory or item.is_series_group
                or (item.attr and item.attr.mode == "directory")
                or item.mode == "directory"
            then
                dirs[#dirs + 1] = item
            else
                files[#files + 1] = item
            end
        end
        if sort_func then pcall(table.sort, dirs,  sort_func) end
        if sort_func then pcall(table.sort, files, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, d in ipairs(dirs)  do final[#final + 1] = d end
        for _, f in ipairs(files) do final[#final + 1] = f end
    end

    -- Write result back into item_table in place.
    -- Use a numeric loop to clear the array part; avoids hash traversal from pairs().
    for i = #item_table, 1, -1 do item_table[i] = nil end
    for i, v in ipairs(final)   do item_table[i] = v   end
end

-- Switches the file_chooser view into a virtual series folder.
local function _sgOpenGroup(file_chooser, group_item)
    if not file_chooser then return end

    local items = group_item.series_items

    -- _sg_current holds only what cannot be recovered from item_table:
    --   series_name: to re-find the group item in the parent list on return.
    --   parent_page: to restore the scroll position in the parent list.
    -- parent_path is stored on item_table._sg_parent_path (single source of truth).
    _sg_current = {
        series_name = group_item.text,
        parent_page = file_chooser.page or 1,
    }

    items._sg_is_series_view = true
    items._sg_parent_path    = file_chooser.path
    file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)

    -- Update the titlebar subtitle to show the series name.
    local ok_p, Patches = pcall(require, "sui_patches")
    if ok_p and Patches and Patches.setFMPathBase then
        local fm = require("apps/filemanager/filemanager").instance
        Patches.setFMPathBase(group_item.text, fm)
    end

    if file_chooser.onGotoPage then
        pcall(function() file_chooser:onGotoPage(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Series grouping hooks — installed/uninstalled as a unit.
-- ---------------------------------------------------------------------------

local _sg_orig_switchItemTable = nil
local _sg_orig_onMenuSelect    = nil
local _sg_orig_onMenuHold      = nil
local _sg_orig_onFolderUp      = nil
local _sg_orig_changeToPath    = nil
local _sg_orig_refreshPath     = nil
local _sg_orig_updateItems     = nil

local function _installSeriesGrouping()
    if FileChooser._simpleui_sg_patched then return end
    FileChooser._simpleui_sg_patched = true

    _sg_orig_switchItemTable = FileChooser.switchItemTable
    _sg_orig_onMenuSelect    = FileChooser.onMenuSelect
    _sg_orig_onMenuHold      = FileChooser.onMenuHold
    _sg_orig_onFolderUp      = FileChooser.onFolderUp
    _sg_orig_changeToPath    = FileChooser.changeToPath
    _sg_orig_refreshPath     = FileChooser.refreshPath
    _sg_orig_updateItems     = FileChooser.updateItems

    -- Process items before KOReader calculates itemmatch so the grouped list
    -- is what the page/focus logic sees.
    -- Also clears _sg_is_series_view on the OLD table at the last safe moment:
    -- the new table has arrived, so the titlebar will see the correct state
    -- immediately. This avoids the timing window where the flag was cleared in
    -- changeToPath (too early) and made _simpleui_sg_leaving necessary.
    FileChooser.switchItemTable = function(fc, new_title, new_item_table,
                                           itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table._sg_is_series_view then
            -- Leaving a series view: clear flag on the outgoing table now.
            if fc.item_table then fc.item_table._sg_is_series_view = false end
            _sgProcessItemTable(new_item_table, fc)
        end
        return _sg_orig_switchItemTable(fc, new_title, new_item_table,
                                        itemnumber, itemmatch, new_subtitle)
    end

    FileChooser.onMenuSelect = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            _sgOpenGroup(fc, item)
            return true
        end
        return _sg_orig_onMenuSelect(fc, item)
    end

    -- Long-press on a virtual series folder only shows the cover picker.
    FileChooser.onMenuHold = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            if not M.isEnabled() then return true end
            local UIManager    = require("ui/uimanager")
            local ButtonDialog = require("ui/widget/buttondialog")

            -- In quad mode the cover picker is disabled (the quad grid always
            -- auto-selects covers). Exception: Detailed list with folder view.
            -- "Create collection" is always available regardless of view mode.
            local in_list_view    = fc and fc.display_mode_type == "list"
            local cover_available = not (
                _resolveStyle(fc, item.path, item) == "quad" and not in_list_view
            )

            local series_name = (item.text or ""):gsub("/$", "")
            local vpath       = item.path
            local dialog

            local buttons = {}

            if cover_available then
                buttons[#buttons + 1] = {{
                    text     = _("Set folder cover"),
                    callback = function()
                        UIManager:close(dialog)
                        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
                        if ok_bim and BookInfoManager then
                            _openSeriesGroupCoverPicker(vpath, fc, BookInfoManager)
                        end
                    end,
                }}
            end

            buttons[#buttons + 1] = {{
                text     = _("Create collection"),
                callback = function()
                    UIManager:close(dialog)
                    _createCollectionFromSeriesGroup(vpath, series_name)
                end,
            }}

            buttons[#buttons + 1] = {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }}

            dialog = ButtonDialog:new{
                title       = series_name,
                title_align = "center",
                buttons     = buttons,
            }
            UIManager:show(dialog)
            return true
        end
        return _sg_orig_onMenuHold(fc, item)
    end

    FileChooser.onFolderUp = function(fc)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            if parent then fc:changeToPath(parent) end
            return true
        end
        return _sg_orig_onFolderUp(fc)
    end

    FileChooser.changeToPath = function(fc, path, ...)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            -- Redirect relative ".." paths to the real parent.
            if parent and path and (path:match("/%.%.") or path:match("^%.%.")) then
                path = parent
            end
            -- Note: _sg_is_series_view is cleared in the switchItemTable override
            -- (when the new item_table arrives) rather than here. This avoids the
            -- timing window between changeToPath and switchItemTable where the
            -- titlebar could read a stale false value and hide the back button.
            if path == parent then
                -- Returning to real parent: mark _sg_current for focus restore
                -- and pre-set the page so the parent scrolls to the right position.
                if _sg_current then
                    _sg_current.should_restore = true
                    local saved_page = _sg_current.parent_page
                    if saved_page and saved_page > 1 then
                        fc.page = saved_page
                    end
                end
            else
                -- Navigating somewhere else: drop series state entirely.
                _sg_current = nil
            end
        else
            _sg_current = nil
        end
        return _sg_orig_changeToPath(fc, path, ...)
    end

    -- After refreshPath (e.g. closing a book) re-enter the virtual folder
    -- if one was active.
    local _sg_refreshPath_depth = 0  -- depth counter (survives errors; bool guard would stick)
    FileChooser.refreshPath = function(fc)
        -- Guard against infinite recursion: _sgOpenGroup → switchItemTable
        -- can trigger another refreshPath call on some KOReader versions.
        if _sg_refreshPath_depth > 0 then
            return _sg_orig_refreshPath(fc)
        end
        _sg_refreshPath_depth = _sg_refreshPath_depth + 1

        -- The item table is stale after closing a book (percent_finished,
        -- bold state, sort position may have changed). Drop the cache so
        -- the next genItemTableFromPath rebuilds cleanly.
        _itc_invalidate()

        -- Only flush disk-level cover caches when the library was actually
        -- visited (files may have been added/removed). Preserving them on a
        -- plain reader→HS transition avoids redundant lfs.* calls per folder.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._library_was_visited then
            for k in pairs(_cover_file_cache)   do _cover_file_cache[k]   = nil end
            for k in pairs(_cfc_b)              do _cfc_b[k]              = nil end
            _cfc_cnt = 0
            for k in pairs(_lm_dir_cover_cache) do _lm_dir_cover_cache[k] = nil end
            for k in pairs(_lmc_b)              do _lmc_b[k]              = nil end
            _lmc_cnt = 0
        end

        _sg_orig_refreshPath(fc)
        if M.getSeriesGrouping() and _sg_current then
            local sname      = _sg_current.series_name
            local saved_page = _sg_current.parent_page
            for _, item in ipairs(fc.item_table or {}) do
                if item.is_series_group and item.text == sname then
                    _sgOpenGroup(fc, item)
                    -- Restore parent_page: _sgOpenGroup resets it to fc.page
                    -- (which is 1 after refreshPath), so we overwrite it here.
                    if _sg_current then _sg_current.parent_page = saved_page end
                    break
                end
            end
        end

        _sg_refreshPath_depth = _sg_refreshPath_depth - 1
    end

    -- Restore focus to the series group item when returning from a virtual folder.
    FileChooser.updateItems = function(fc, ...)
        if not M.getSeriesGrouping() then
            _sg_current = nil
            return _sg_orig_updateItems(fc, ...)
        end

        if fc.item_table and fc.item_table._sg_is_series_view then
            return _sg_orig_updateItems(fc, ...)
        end

        if _sg_current and _sg_current.should_restore
                and fc.item_table and #fc.item_table > 0 then
            local sname = _sg_current.series_name
            for idx, item in ipairs(fc.item_table) do
                if item.is_series_group and item.text == sname then
                    fc.page = math.ceil(idx / fc.perpage)
                    local select_num = ((idx - 1) % fc.perpage) + 1
                    if fc.path_items and fc.path then fc.path_items[fc.path] = idx end
                    _sg_current = nil
                    return _sg_orig_updateItems(fc, select_num)
                end
            end
            _sg_current = nil
        end

        return _sg_orig_updateItems(fc, ...)
    end
end

-- ---------------------------------------------------------------------------
-- Public API for other modules that need to query or exit the series view
-- without accessing internal state directly.
-- ---------------------------------------------------------------------------

--- Returns true when fc is currently showing a virtual series folder.
function M.isInSeriesView(fc)
    return fc and fc.item_table and fc.item_table._sg_is_series_view == true
end

--- Exits the series view and navigates to the real parent folder.
--- No-ops when not in a series view. Used by sui_bottombar to avoid
--- direct access to _sg_is_series_view.
function M.exitSeriesView(fc)
    if not M.isInSeriesView(fc) then return end
    local parent = fc.item_table._sg_parent_path
    -- Clear _sg_current so changeToPath does not try to restore the series.
    _sg_current = nil
    -- Clear the flag directly: we are abandoning the series view (not backing
    -- into the parent), so switchItemTable's auto-clear is sufficient but we
    -- do it here too for safety in case changeToPath short-circuits.
    fc.item_table._sg_is_series_view = false
    if parent then
        fc:changeToPath(parent)
    end
end

local function _uninstallSeriesGrouping()
    if not FileChooser._simpleui_sg_patched then return end
    if _sg_orig_switchItemTable then FileChooser.switchItemTable = _sg_orig_switchItemTable; _sg_orig_switchItemTable = nil end
    if _sg_orig_onMenuSelect    then FileChooser.onMenuSelect    = _sg_orig_onMenuSelect;    _sg_orig_onMenuSelect    = nil end
    if _sg_orig_onMenuHold      then FileChooser.onMenuHold      = _sg_orig_onMenuHold;      _sg_orig_onMenuHold      = nil end
    if _sg_orig_onFolderUp      then FileChooser.onFolderUp      = _sg_orig_onFolderUp;      _sg_orig_onFolderUp      = nil end
    if _sg_orig_changeToPath    then FileChooser.changeToPath    = _sg_orig_changeToPath;    _sg_orig_changeToPath    = nil end
    if _sg_orig_refreshPath     then FileChooser.refreshPath     = _sg_orig_refreshPath;     _sg_orig_refreshPath     = nil end
    if _sg_orig_updateItems     then FileChooser.updateItems     = _sg_orig_updateItems;     _sg_orig_updateItems     = nil end
    FileChooser._simpleui_sg_patched = nil
    _sg_current           = nil
    _sg_items_cache       = {}
    _sg_last_evicted_path = nil
end

-- ---------------------------------------------------------------------------
-- Visual build helpers — one per overlay layer.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Progress pentagon badge — direct Blitbuffer rendering.
--
-- Design: downward-pointing pentagon (rectangle + triangular tip).
-- Outer shape: COLOR_GRAY (2 px frame).
-- Inner shape: COLOR_BLACK (fill).
-- Text/icon:   COLOR_WHITE.
--
-- States:
--   "complete"           → white checkmark
--   percent_finished set → white "42%" text
--   neither              → bare pentagon (book not yet started)
-- ---------------------------------------------------------------------------

local function _pentagonPaintRect(bb, bx, by, bw, bh, color)
    -- Pentagon: rectangular body (top 30/42 of height) + downward triangular tip.
    local rect_h = math.floor(bh * 30 / 42)
    local tip_h  = bh - rect_h
    bb:paintRect(bx, by, bw, rect_h, color)
    for row = 0, tip_h - 1 do
        local frac = (row + 1) / tip_h         -- 0→1 towards tip
        local rw   = math.max(2, math.floor(bw * (1 - frac)))
        local rx   = bx + math.floor((bw - rw) / 2)
        bb:paintRect(rx, by + rect_h + row, rw, 1, color)
    end
end

local function _pentagonPaintCheck(bb, bx, by, bw, bh, color)
    -- Two diagonal line segments forming a checkmark.
    local tk = math.max(2, math.floor(math.min(bw, bh) / 8))
    local function drawLine(x0, y0, x1, y1)
        local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
        if steps == 0 then steps = 1 end
        for i = 0, steps do
            local t = i / steps
            bb:paintRect(
                math.floor(x0 + t * (x1 - x0)),
                math.floor(y0 + t * (y1 - y0)),
                tk, tk, color)
        end
    end
    -- Short left arm (shallow descent): 8%,62% → 30%,82%
    local lx0 = bx + math.floor(bw * 0.08); local ly0 = by + math.floor(bh * 0.62)
    local lx1 = bx + math.floor(bw * 0.30); local ly1 = by + math.floor(bh * 0.82)
    -- Long right arm: pivot → 82%,18%
    local rx1  = bx + math.floor(bw * 0.82); local ry1 = by + math.floor(bh * 0.18)
    drawLine(lx0, ly0, lx1, ly1)
    drawLine(lx1, ly1, rx1, ry1)
end

-- Returns a descriptor table for the progress badge, or nil if too small.
-- No Blitbuffer is allocated here — the badge is drawn directly onto the
-- cover bb in paintTo(), which avoids the "white rectangle outside the
-- pentagon tip" artefact that blitFrom() (opaque copy) would produce.
--   eff_size         — effective badge size in px (drives bw/bh proportions)
--   status           — "complete" | "abandoned" | "reading" | other/nil
--   percent_finished — 0.0–1.0 or nil (nil = not started)
--   border           — frame border thickness (matches cover FrameContainer border)
local function _buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
    local bw = math.floor(eff_size * 1.2)
    local bh = math.floor(eff_size * 1.1)
    if bw < 4 or bh < 4 then return nil end
    return {
        bw               = bw,
        bh               = bh,
        border           = border or 1,
        status           = status,
        percent_finished = percent_finished,
        eff_size         = eff_size,
        dark             = dark ~= false,  -- default true
    }
end

-- Draws the progress badge described by `desc` directly onto `bb` at (ox, oy).
-- No intermediate Blitbuffer — pixels outside the pentagon are simply never
-- written, so the cover image beneath remains intact.
-- The outer frame uses COLOR_GRAY (original colour) with the same thickness
-- as the cover FrameContainer border.
local function _drawProgressBadge(bb, ox, oy, desc)
    local bw = desc.bw
    local bh = desc.bh
    local fr = desc.border   -- frame thickness = same as cover FrameContainer border
    local fill_color = desc.dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local text_color = desc.dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    -- Outer frame in COLOR_GRAY (original colour).
    -- Full footprint: bw + 2*fr  ×  bh + 2*fr
    _pentagonPaintRect(bb, ox,      oy,      bw + 2 * fr, bh + 2 * fr, Blitbuffer.COLOR_GRAY)
    -- Inner body (inset by fr on each side).
    _pentagonPaintRect(bb, ox + fr, oy + fr, bw,          bh,          fill_color)

    -- Icon / text area inside the rectangular portion of the body.
    local rect_h = math.floor(bh * 30 / 42)
    local pad_x  = math.floor(bw * 0.12)
    -- pad_y controls the icon bounding box (checkmark / pause bars).
    -- Text (percent) uses its own vertical offset below to shift it downward
    -- without shrinking the icon area.
    local pad_y  = math.floor(rect_h * 0.25)
    local icon_x = ox + fr + pad_x
    local icon_y = oy + fr + pad_y
    local icon_w = bw - 2 * pad_x
    local icon_h = rect_h - 2 * pad_y
    -- Vertical offset applied to all content (icons + text): shifts everything
    -- downward so there is more black space above, balancing the triangular tip below.
    local text_y_offset = math.floor(rect_h * 0.15)

    if desc.status == "complete" then
        -- White checkmark: same vertical anchor as the percentage text (rect_h centred + offset).
        local sq   = math.min(icon_w, icon_h)
        local sq_x = icon_x + math.floor((icon_w - sq) / 2)
        local sq_y = oy + fr + math.floor((rect_h - sq) / 2) + text_y_offset
        _pentagonPaintCheck(bb, sq_x, sq_y, sq, sq, text_color)

    elseif desc.status == "abandoned" then
        -- Nerd font glyph U+EAE3 (on-hold / pause icon), same colour as the
        -- complete checkmark (COLOR_WHITE). cfont has nerdfonts/symbols.ttf in
        -- its fallback chain so the codepoint renders without a separate face.
        local font_sz = math.max(7, math.floor(desc.eff_size * 0.24))
        local aw = TextWidget:new{
            text    = "",
            face    = Font:getFace("cfont", font_sz),
            bold    = false,
            fgcolor = text_color,
            padding = 0,
        }
        local aw_sz = aw:getSize()
        aw:paintTo(bb,
            ox + fr + math.floor((bw     - aw_sz.w) / 2),
            oy + fr + math.floor((rect_h - aw_sz.h) / 2) + text_y_offset)
        if aw.free then aw:free() end

    elseif desc.percent_finished ~= nil then
        -- Percentage text: centred horizontally, shifted downward by text_y_offset.
        local pct     = math.floor(100 * desc.percent_finished)
        local pct_str = pct .. "%"
        local font_sz = math.max(7, math.floor(desc.eff_size * 0.24))
        local tw = TextWidget:new{
            text    = pct_str,
            face    = Font:getFace("cfont", font_sz),
            bold    = true,
            fgcolor = text_color,
            padding = 0,
        }
        local tw_sz   = tw:getSize()
        tw:paintTo(bb,
            ox + fr + math.floor((bw     - tw_sz.w) / 2),
            oy + fr + math.floor((rect_h - tw_sz.h) / 2) + text_y_offset)
        if tw.free then tw:free() end
    end
    -- "not started" / "reading" with no percent: bare pentagon, no content drawn.
end

-- ---------------------------------------------------------------------------
-- Rounded-rectangle badge — shared descriptor + direct-draw pipeline.
--
-- Mirrors the progress pentagon architecture exactly:
--   _buildRectBadgeDesc  — allocates nothing; returns a plain table.
--   _drawRectBadge       — draws directly onto the cover bb in paintTo().
--
-- Sizing is identical to the progress badge:
--   eff_size = math.max(8,  math.floor(cell_min * 0.14))
--   font_sz  = math.max(7,  math.floor(eff_size * 0.24))   ← same ratio as pentagon text
--
-- Used by: pages badge, series-index badge, "New" badge.
-- ---------------------------------------------------------------------------

-- Returns a descriptor table (no Blitbuffer allocated) or nil when too small.
--   text     — label string
--   bold     — boolean
--   cell_min — math.min(cell_w, cell_h) at update() time
--   dark     — true → black bg / white text;  false → white bg / black text
--   new_badge — true → apply 2× lateral padding (wider pill for short words)
local function _buildRectBadgeDesc(text, bold, cell_min, dark, new_badge)
    local eff_size = math.max(8, math.floor((cell_min or 40) * 0.14))
    -- font_sz uses the same 0.24 ratio as the progress pentagon text/icons.
    local font_sz  = math.max(7, math.floor(eff_size * 0.24))
    local pad_h    = math.max(1, math.floor(eff_size * 0.10))
    local pad_v    = math.max(1, math.floor(eff_size * 0.06))
    local corner   = math.max(1, math.floor(eff_size * 0.08))
    local border   = Size.border.thin
    -- Measure text size with a temporary widget (freed immediately — no alloc kept).
    local tw = TextWidget:new{
        text    = text,
        face    = Font:getFace("cfont", font_sz),
        bold    = bold or false,
        padding = 0,
    }
    local tsz = tw:getSize()
    if tw.free then tw:free() end
    local lateral = pad_h * 4   -- same lateral padding for all badges
    local inner_h = tsz.h + pad_v * 2
    -- Enforce a square minimum so short labels like "#1" are not tiny slivers.
    local inner_w = math.max(tsz.w + lateral, inner_h)
    local w = inner_w + border * 2
    local h = inner_h + border * 2
    if w < 4 or h < 4 then return nil end
    return {
        text     = text,
        bold     = bold or false,
        font_sz  = font_sz,
        w        = w,
        h        = h,
        inner_w  = inner_w,
        inner_h  = inner_h,
        border   = border,
        corner   = corner,
        dark     = dark,
    }
end

-- Draws the rounded-rectangle badge described by `desc` directly onto `bb`
-- at pixel position (ox, oy).  No intermediate Blitbuffer is allocated;
-- the FrameContainer + TextWidget are built, painted, and freed here.
local function _drawRectBadge(bb, ox, oy, desc)
    local bg = desc.dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = desc.dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local tw = TextWidget:new{
        text    = desc.text,
        face    = Font:getFace("cfont", desc.font_sz),
        bold    = desc.bold,
        fgcolor = fg,
        padding = 0,
    }
    local bw = FrameContainer:new{
        dimen      = Geom:new{ w = desc.w, h = desc.h },
        bordersize = desc.border,
        color      = Blitbuffer.COLOR_GRAY,
        background = bg,
        radius     = desc.corner,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = desc.inner_w, h = desc.inner_h },
            tw,
        },
    }
    bw:paintTo(bb, ox, oy)
    bw:free()
end

local function _buildSpine(img_h)
    local h1 = math.floor(img_h * 0.97)
    local h2 = math.floor(img_h * 0.94)
    local y1 = math.floor((img_h - h1) / 2)
    local y2 = math.floor((img_h - h2) / 2)

    local function spineLine(h, y_off)
        local line = LineWidget:new{
            dimen      = Geom:new{ w = _EDGE_THICK, h = h },
            background = _SPINE_COLOR,
        }
        line.overlap_offset = { 0, y_off }
        return OverlapGroup:new{ dimen = Geom:new{ w = _EDGE_THICK, h = img_h }, line }
    end

    return HorizontalGroup:new{
        align = "center",
        spineLine(h2, y2),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
        spineLine(h1, y1),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
    }
end

-- Folder-name label overlaid on the cover image. Returns nil when disabled.
-- `display` is the pre-read settings table { label_mode, show_name, label_style, label_pos }.
-- spine_w: actual spine width in pixels (0 when spine is hidden).
local function _buildLabel(item, available_w, size, border, cv_scale, display, spine_w)
    if display.label_mode ~= "overlay" then return nil end
    if not display.show_name            then return nil end
    local label_style = display.label_style
    local label_pos   = display.label_pos

    local dir_max_fs = math.max(8, math.floor(_BASE_DIR_FS * cv_scale * M.getLabelScale()))
    local directory  = item:_getFolderNameWidget(available_w, dir_max_fs)
    local img_only   = Geom:new{ w = size.w, h = size.h }
    local img_dimen  = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }

    local frame = FrameContainer:new{
        padding        = 0,
        padding_top    = _VERTICAL_PAD,
        padding_bottom = _VERTICAL_PAD,
        padding_left   = _LATERAL_PAD,
        padding_right  = _LATERAL_PAD,
        bordersize     = border,
        background     = Blitbuffer.COLOR_WHITE,
        directory,
    }

    local label_inner
    if label_style == "alpha" then
        label_inner = AlphaContainer:new{ alpha = _LABEL_ALPHA, frame }
    else
        label_inner = frame
    end

    local name_og = OverlapGroup:new{ dimen = img_dimen }

    if label_pos == "center" then
        name_og[1] = CenterContainer:new{
            dimen = img_only, label_inner, overlap_align = "center",
        }
    elseif label_pos == "top" then
        name_og[1] = TopContainer:new{
            dimen = img_dimen, label_inner, overlap_align = "center",
        }
    else  -- "bottom"
        name_og[1] = BottomContainer:new{
            dimen = img_dimen, label_inner, overlap_align = "center",
        }
    end

    name_og.overlap_offset = { spine_w or _SPINE_W, 0 }
    return name_og
end

-- Book-count badge (circle, top- or bottom-right). Returns nil when hidden.
-- cell_dimen (optional): full mosaic cell size used for badge sizing; when
-- omitted, cover_dimen is used instead (smaller, produces a smaller badge).
local function _buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen)
    if M.getBadgeHidden() then return nil end
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local nb_count       = tonumber(nb_text)
    -- Sizing identical to all other badges: eff_size = cell_min * 0.14,
    -- font_sz = eff_size * 0.24 (same ratio as progress pentagon text).
    -- Use the full cell dimensions for sizing so the badge matches the scale
    -- of the pages/series badges on book covers (which use self.width/self.height).
    local size_dimen     = cell_dimen or cover_dimen
    local cell_min       = math.min(size_dimen.w, size_dimen.h)
    local nb_size        = math.max(8, math.floor(cell_min * 0.14))
    local nb_font_size   = math.max(7, math.floor(nb_size * 0.24))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))
    local dark           = M.getBadgeColorFolder() == "dark"
    local bg_color       = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg_color       = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    local badge = FrameContainer:new{
        padding    = 0,
        bordersize = Size.border.thin,
        color      = Blitbuffer.COLOR_GRAY,
        background = bg_color,
        radius     = math.floor(nb_size / 2),
        dimen      = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size, h = nb_size },
            (function()
                local tw = TextWidget:new{
                    text    = tostring(math.min(nb_count, 99)),
                    face    = Font:getFace("cfont", nb_font_size),
                    fgcolor = fg_color,
                    bold    = true,
                }
                local _orig_pt = tw.paintTo
                tw.paintTo = function(self, bb, x, y)
                    _orig_pt(self, bb, x, y + 1) -- HACK: Change this +1 to the required value
                end
                return tw
            end)(),
        },
    }

    local inner = RightContainer:new{
        dimen = Geom:new{ w = cover_dimen.w, h = nb_size + badge_margin },
        FrameContainer:new{
            padding       = 0,
            padding_right = badge_margin_r,
            bordersize    = 0,
            badge,
        },
    }

    if M.getBadgePosition() == "bottom" then
        return BottomContainer:new{
            dimen          = cover_dimen,
            padding_bottom = badge_margin,
            inner,
            overlap_align  = "center",
        }
    else
        return TopContainer:new{
            dimen         = cover_dimen,
            padding_top   = badge_margin,
            inner,
            overlap_align = "center",
        }
    end
end

-- ---------------------------------------------------------------------------
-- Shared geometry helper — computes the five values every cover-building
-- function needs.  Called once per cell; eliminates the five-way duplication
-- of the border/spine_w/max_img_w/max_img_h block.
-- ---------------------------------------------------------------------------
local function _computeCellGeometry(item)
    local border    = Size.border.thin
    local spine_w   = not M.getHideSpine() and _SPINE_W or 0
    -- Note: self.height has already been reduced by _STRIP_H in the update()
    -- wrapper before _setFolderCover/_setEmptyFolderCover call this function,
    -- so we must NOT subtract _module_strip_h again here.
    local max_img_w = item.width  - spine_w - border * 2
    local max_img_h = item.height - border * 2
    return border, spine_w, max_img_w, max_img_h
end

-- ---------------------------------------------------------------------------
-- Shared assembly helper — wraps any pre-built content_widget (ImageWidget,
-- empty FrameContainer, or quad grid) with the spine, centres it in the
-- mosaic cell, and overlays the folder-name label and item-count badge.
-- Returns the outer OverlapGroup ready for _underline_container[1].
--
--   item           — the MosaicMenuItem
--   content_widget — the framed cover block (already wrapped in FrameContainer)
--   size           — Geom{w,h} of the content_widget *inside* its border
--   border         — Size.border.thin (passed in to avoid a redundant call)
--   spine_w        — precomputed spine width in px (0 when spine hidden)
--   display        — settings table { label_mode, show_name, label_style, label_pos }
--
-- cv_scale is derived here from cover_h (the authoritative value) so callers
-- never have to compute or pass it — any approximation made before cover_h is
-- known would produce a different number.
-- ---------------------------------------------------------------------------
local function _assembleCoverWidget(item, content_widget, size, border, spine_w, display)
    local spine       = spine_w > 0 and _buildSpine(size.h) or nil
    local cover_group = spine
        and HorizontalGroup:new{ align = "center", spine, content_widget }
        or  HorizontalGroup:new{ align = "center", content_widget }

    local cover_w     = spine_w + size.w + border * 2
    local cover_h     = size.h  + border * 2
    local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
    local cell_dimen  = Geom:new{ w = item.width, h = item.height }
    local cv_scale    = math.max(0.1, math.floor((cover_h / _BASE_COVER_H) * 10) / 10)

    local folder_name_widget = _buildLabel(item, size.w - _LATERAL_PAD * 2,
        size, border, cv_scale, display, spine_w)
    local nbitems_widget = _buildBadge(item.mandatory, cover_dimen, cv_scale, cell_dimen)

    local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
    if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
    if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

    local x_center = math.floor((item.width  - cover_w) / 2)
    local y_center = math.floor((item.height - cover_h) / 2)
    overlap.overlap_offset = { x_center - math.floor(spine_w / 2), y_center }

    return OverlapGroup:new{ dimen = cell_dimen, overlap }
end

-- ---------------------------------------------------------------------------
-- Install helper — marks the cell as processed, frees the previous widget,
-- and assigns the new one.  Extracted to avoid repeating these three lines
-- in every quad-cover caller inside update().
-- ---------------------------------------------------------------------------
local function _installWidget(item, widget)
    item._foldercover_processed = true
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = widget
end

-- ---------------------------------------------------------------------------
-- Quad-cover builder — 2×2 grid of book covers for a folder cell.
-- Returns the OverlapGroup widget ready to assign to _underline_container[1],
-- or nil when no covers are available (caller falls through to empty cover).
-- img_list: array of up to 4 { data=bb, w=n, h=n } or { file=path, w=n, h=n }
-- border, spine_w, max_img_w, max_img_h: all come from _computeCellGeometry so
-- M.getHideSpine() and Size.border.thin are never read twice in the same cell.
-- ---------------------------------------------------------------------------
local function _buildQuadCover(item, img_list, border, spine_w, max_img_w, max_img_h, display)
    local sep       = math.max(1, Screen:scaleBySize(1))

    -- Compute the portrait block dimensions (always 2:3).
    local ratio = 2 / 3
    local img_w, img_h
    if max_img_w / max_img_h > ratio then
        img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
    else
        img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
    end

    -- Each quadrant.
    local half_w  = math.floor((img_w - sep) / 2)
    local half_w2 = img_w - sep - half_w
    local half_h  = math.floor((img_h - sep) / 2)
    local half_h2 = img_h - sep - half_h
    local cell_dims = {
        { w = half_w,  h = half_h  },
        { w = half_w2, h = half_h  },
        { w = half_w,  h = half_h2 },
        { w = half_w2, h = half_h2 },
    }

    local cells = {}
    for i = 1, 4 do
        local c  = img_list[i]
        local cd = cell_dims[i]
        if c then
            local img_opts = { width = cd.w, height = cd.h }
            if c.file  then img_opts.file  = c.file  end
            if c.data  then img_opts.image = c.data  end
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cd.w, h = cd.h },
                ImageWidget:new(img_opts),
            }
        else
            -- Empty slot: white fill so the separator lines remain visible.
            -- A child widget is required so FrameContainer:getSize() doesn't
            -- crash trying to index a nil value (framecontainer.lua:55).
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cd.w, h = cd.h },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local sep_color = Blitbuffer.COLOR_LIGHT_GRAY
    local grid = FrameContainer:new{
        padding    = 0,
        bordersize = border,
        VerticalGroup:new{
            HorizontalGroup:new{
                cells[1],
                LineWidget:new{ background = sep_color,
                    dimen = Geom:new{ w = sep, h = half_h } },
                cells[2],
            },
            LineWidget:new{ background = sep_color,
                dimen = Geom:new{ w = img_w, h = sep } },
            HorizontalGroup:new{
                cells[3],
                LineWidget:new{ background = sep_color,
                    dimen = Geom:new{ w = sep, h = half_h2 } },
                cells[4],
            },
        },
    }

    local size = Geom:new{ w = img_w, h = img_h }

    return _assembleCoverWidget(item, grid, size, border, spine_w, display)
end

-- ---------------------------------------------------------------------------
-- Collect up to `max_count` cached book covers from `dir_path`.
-- Uses the existing _entriesWithNoFilter + recursive helper.
-- Returns array of { data=bb, w=n, h=n }.
-- ---------------------------------------------------------------------------
local function _collectCovers(menu, dir_path, max_count, BookInfoManager)
    local covers  = {}
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return covers end

    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            if #covers >= max_count then break end
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
            end
        end
    end

    -- If we still need covers and recursive mode is on, search subfolders.
    -- Use _collectCoversRecursive so a single subfolder can contribute more
    -- than one cover (needed to fill all 4 quadrants from a deeply nested tree).
    if #covers < max_count and M.getRecursiveCover() then
        for _, entry in ipairs(entries) do
            if not (entry.is_file or entry.file) and not entry.is_go_up then
                if #covers >= max_count then break end
                local sub = _collectCoversRecursive(
                    menu, entry.path, 1, 3, max_count - #covers, BookInfoManager)
                for _, c in ipairs(sub) do
                    covers[#covers + 1] = c
                    if #covers >= max_count then break end
                end
            end
        end
    end

    return covers
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.install()
    local MosaicMenuItem, userpatch = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if MosaicMenuItem._simpleui_fc_patched then return end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    -- ReadCollection needed to check if a book belongs to a collection.
    local ok_rc, ReadCollection = pcall(require, "readcollection")
    if not ok_rc then ReadCollection = nil end

    -- Lazy cache for collection_mark upvalues from orig_paintTo.
    -- Populated on first banner-mode paint of a book in a collection.
    local _fc_coll_sz, _fc_coll_widget

    -- Capture cell dimensions before each render so the 2:3 StretchingImageWidget
    -- can enforce the correct aspect ratio.
    local max_img_w, max_img_h

    if not MosaicMenuItem._simpleui_fc_iw_n then
        local local_ImageWidget
        local n = 1
        while true do
            local name, value = debug.getupvalue(MosaicMenuItem.update, n)
            if not name then break end
            if name == "ImageWidget" then local_ImageWidget = value; break end
            n = n + 1
        end

        if local_ImageWidget then
            local StretchingImageWidget = local_ImageWidget:extend({})
            StretchingImageWidget.init = function(self)
                if local_ImageWidget.init then local_ImageWidget.init(self) end
                if M.getCoverMode() ~= "2_3"   then return end
                if not max_img_w or not max_img_h then return end
                local ratio = 2 / 3
                self.scale_factor = nil
                self.stretch_limit_percentage = 50
                if max_img_w / max_img_h > ratio then
                    self.height = max_img_h
                    self.width  = math.floor(max_img_h * ratio)
                else
                    self.width  = max_img_w
                    self.height = math.floor(max_img_w / ratio)
                end
            end
            debug.setupvalue(MosaicMenuItem.update, n, StretchingImageWidget)
            MosaicMenuItem._simpleui_fc_iw_n         = n
            MosaicMenuItem._simpleui_fc_orig_iw      = local_ImageWidget
            MosaicMenuItem._simpleui_fc_stretched_iw = StretchingImageWidget
        end
    end

    local orig_init = MosaicMenuItem.init
    MosaicMenuItem._simpleui_fc_orig_init = orig_init

    -- ── Title/Author strip geometry (fixed for the session; requires restart) ──
    -- Calculated here so init, update and paintTo all share the same value.
    local _show_title_strip  = M.getShowTitleStrip()
    local _show_author_strip = M.getShowAuthorStrip()
    local _STRIP_H = 0

    if _show_title_strip or _show_author_strip then
        local Screen_   = require("device").screen
        local Font_     = require("ui/font")
        local TextWidget_ = require("ui/widget/textwidget")
        local _PAD = Screen_:scaleBySize(3)
        local _GAP = Screen_:scaleBySize(2)
        local function _mh(fs, bold)
            local tw = TextWidget_:new{ text="Ag", face=Font_:getFace("cfont",fs),
                bold=bold, padding=0 }
            local h = tw:getSize().h; tw:free(); return h
        end
        local TITLE_LINE  = _mh(16, true)
        local AUTHOR_LINE = _mh(13, false)
        _STRIP_H = _PAD
        if _show_title_strip  then _STRIP_H = _STRIP_H + TITLE_LINE end
        if _show_title_strip and _show_author_strip then _STRIP_H = _STRIP_H + _GAP end
        if _show_author_strip then _STRIP_H = _STRIP_H + AUTHOR_LINE end
        _STRIP_H = _STRIP_H + _PAD
    end
    -- Expose on both the module variable (for _computeCellGeometry) and the
    -- class table (for bookkeeping / uninstall).
    _module_strip_h = _STRIP_H
    MosaicMenuItem._simpleui_strip_h = _STRIP_H

    -- Flag used by update wrapper to avoid double-shrink when init calls update.
    local _in_strip_init = false

    function MosaicMenuItem:init()
        -- Shrink cell height so the original init (and browser_cover_mosaic_uniform)
        -- lays out the cover image within the reduced space, leaving the strip area free.
        if _STRIP_H > 0 and self.height then
            self.height = self.height - _STRIP_H
        end
        if self.width and self.height then
            local border_size = Size.border.thin
            max_img_w = self.width  - 2 * border_size
            max_img_h = self.height - 2 * border_size
        end
        _in_strip_init = true
        if orig_init then orig_init(self) end
        _in_strip_init = false
        -- Restore so the cell occupies its full grid slot.
        if _STRIP_H > 0 and self.height then
            self.height = self.height + _STRIP_H
        end
    end

    MosaicMenuItem._simpleui_fc_patched     = true
    MosaicMenuItem._simpleui_fc_orig_update = MosaicMenuItem.update

    local original_update = MosaicMenuItem.update

    function MosaicMenuItem:update(...)
        -- Invalidate the title/author strip blitbuffer cache on every cover reload.
        self._simpleui_strip_data = nil
        if self._simpleui_strip_bb then
            self._simpleui_strip_bb:free(); self._simpleui_strip_bb = nil
        end
        -- Shrink height so the original update (and other patches) compute the cover
        -- image within the reduced space.  Skipped when called from within init()
        -- because init already shrank self.height before calling orig_init.
        if not _in_strip_init and _STRIP_H > 0 and self.height then
            self.height = self.height - _STRIP_H
        end
        original_update(self, ...)
        if not _in_strip_init and _STRIP_H > 0 and self.height then
            self.height = self.height + _STRIP_H
            -- KOReader evaluated show_progress_bar with a reduced self.height and
            -- may have set it to false (or nil) incorrectly.  Re-apply the exact
            -- condition from mosaicmenu.lua so the native bar is shown when it
            -- should be.  We only force it to true — we never force it to false —
            -- so any explicit "complete" suppression from KOReader is preserved.
            if not self.show_progress_bar and self.percent_finished
                    and self.status ~= "complete"
                    and BookInfoManager:getSetting("show_progress_in_mosaic") then
                self.show_progress_bar = true
            end
        end

        -- Capture pages and series index from the BookList cache (no extra I/O).
        -- Stored on self so paintTo() can use them without a redundant getBookInfo call.
        if not self.is_directory and not self.file_deleted and self.filepath then
            self._fc_pages        = nil
            self._fc_series_index = nil
            local bi = self.menu and self.menu.getBookInfo
                       and self.menu.getBookInfo(self.filepath)
            if bi then
                if bi.pages then self._fc_pages = bi.pages end
                if bi.series and bi.series_index then
                    self._fc_series_index = bi.series_index
                end
            end
            -- Pre-compute the underline color once per update so onFocus()
            -- is a plain field assignment rather than a settings read.
            self._fc_underline_color = M.getHideUnderline()
                and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            -- Pre-read badge visibility flags so paintTo() makes zero settings reads.
            self._fc_overlay_pages    = M.getOverlayPages()
            self._fc_overlay_series   = M.getOverlaySeries()
            self._fc_overlay_progress = M.getProgressMode() == "banner"
            self._fc_overlay_new      = M.getOverlayNew()

            -- Build badge descriptors (plain tables, no Blitbuffer allocated).
            -- _fc_progress_bb, _fc_pages_desc, _fc_series_desc, _fc_new_desc are
            -- all plain tables — no :free() needed for any of them.
            self._fc_progress_bb = nil
            self._fc_pages_desc  = nil
            self._fc_series_desc = nil
            self._fc_new_desc    = nil

            if self._fc_overlay_pages and self.status ~= "complete" and self._fc_pages then
                local cell_min = math.min(self.width or 40, self.height or 40)
                local dark = M.getBadgeColorPages() == "dark"
                self._fc_pages_desc = _buildRectBadgeDesc(self._fc_pages .. " p.", false, cell_min, dark, false)
            end

            if self._fc_overlay_series and self._fc_series_index then
                local cell_min = math.min(self.width or 40, self.height or 40)
                local dark = M.getBadgeColorSeries() == "dark"
                self._fc_series_desc = _buildRectBadgeDesc("#" .. self._fc_series_index, false, cell_min, dark, false)
            end

            -- ── Progress pentagon badge ───────────────────────────────────────
            -- Rendered only when the feature is enabled and the item is a book.
            -- Only shown for books that have been opened (percent_finished is set
            -- or status is "complete"); bare-pentagon "not started" state is hidden.
            if self._fc_overlay_progress then
                local has_progress = (self.percent_finished ~= nil) or (self.status == "complete") or (self.status == "abandoned")
                if has_progress then
                    local eff_size = math.max(8, math.floor(
                        math.min(self.width or 40, self.height or 40) * 0.14))
                    local dark = M.getBadgeColorProgress() == "dark"
                    local prog_desc = _buildProgressBadgeDesc(
                        eff_size, self.status, self.percent_finished, Size.border.thin, dark)
                    if prog_desc then self._fc_progress_bb = prog_desc end
                end
            end

            -- ── "New" badge (top-right) ────────────────────────────────────────────────────────────
            -- Descriptor pre-built for books that have never been opened.
            if self._fc_overlay_new then
                local is_unread = (self.percent_finished == nil) and (self.status ~= "complete") and (self.status ~= "abandoned")
                if is_unread then
                    local cell_min = math.min(self.width or 40, self.height or 40)
                    local dark = M.getBadgeColorNew() == "dark"
                    self._fc_new_desc = _buildRectBadgeDesc(_("New"), true, cell_min, dark, true)
                end
            end
        end

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        -- Defer the first folder-cover pass when the homescreen is visible.
        -- The HS has no folder covers so the user sees nothing during this tick;
        -- rendering is scheduled for the next tick so the HS paints first.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance and not self.menu._fc_hs_deferred then
            self.menu._fc_hs_deferred = true
            local menu_ref = self.menu
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                menu_ref._fc_hs_deferred = false
                local HS2 = package.loaded["sui_homescreen"]
                if HS2 and HS2._instance then return end
                local fm = package.loaded["apps/filemanager/filemanager"]
                if not fm or not fm.instance or fm.instance.tearing_down then return end
                menu_ref:updateItems()
            end)
            return
        end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        -- Read all display settings once into a table so every build helper
        -- receives them as a single argument (no per-call settings reads).
        local display = {
            label_mode  = M.getLabelMode(),
            show_name   = M.getShowName(),
            label_style = M.getLabelStyle(),
            label_pos   = M.getLabelPosition(),
        }
        -- When the title/author strip is active it already shows the folder name
        -- below the cover — suppress the overlay label to avoid redundancy.
        if _STRIP_H > 0 then
            display.label_mode = "hidden"
        end
        local folder_style = _resolveStyle(self.menu, dir_path, self.entry)   -- "single" | "quad" (resolved)

        -- ── Series group cover ────────────────────────────────────────────────
        -- Series group cover — respects folder_style (single or quad).
        if self.entry.is_series_group then
            if self._foldercover_processed then return end

            -- A user-chosen override renders as a single cover image only in single mode.
            -- In quad mode the override is ignored so the grid is always shown.
            local sg_override_fp = folder_style ~= "quad" and _getCoverOverrides()[dir_path]
            if sg_override_fp then
                local bi = BookInfoManager:getBookInfo(sg_override_fp, true)
                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover
                        and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                then
                    self:_setFolderCover(
                        { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                        display)
                    return
                end
            end

            local items = self.entry.series_items or _sg_items_cache[dir_path]

            -- ── Quad mode: build a 2x2 grid from up to 4 series book covers ──
            if folder_style == "quad" and items then
                local covers = {}
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                and not bi.ignore_cover
                                and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                        then
                            covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
                            if #covers >= 4 then break end
                        end
                    end
                end
                if #covers > 0 then
                    local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)
                    local widget = _buildQuadCover(self, covers,
                        border, spine_w, max_img_w, max_img_h, display)
                    if widget then
                        _installWidget(self, widget)
                        return
                    end
                end
                -- No covers ready yet — register for async retry.
                if self.menu and self.menu.items_to_update then
                    if not self.menu._fc_pending_set then
                        self.menu._fc_pending_set = {}
                    end
                    if not self.menu._fc_pending_set[self] then
                        self.menu._fc_pending_set[self] = true
                        table.insert(self.menu.items_to_update, self)
                    end
                end
                return
            end

            -- ── Single mode: first available cover from the series ────────────
            if items then
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                and not bi.ignore_cover
                                and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                        then
                            self:_setFolderCover(
                                { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                                display)
                            return
                        end
                    end
                end
            end
            return
        end

        -- ── Quad (2×2 grid) mode ──────────────────────────────────────────────
        if folder_style == "quad" then
            -- Static .cover.* file takes precedence even in quad mode (single image).
            local cover_file = findCover(dir_path)
            if cover_file then
                local ok, w, h = pcall(function()
                    local tmp = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                    tmp:_render()
                    local ow = tmp:getOriginalWidth()
                    local oh = tmp:getOriginalHeight()
                    tmp:free()
                    return ow, oh
                end)
                if ok and w and h then
                    self:_setFolderCover(
                        { file = cover_file, w = w, h = h },
                        display)
                    return
                end
            end

            local covers = _collectCovers(self.menu, dir_path, 4, BookInfoManager)
            if #covers > 0 then
                local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)
                local widget = _buildQuadCover(self, covers,
                    border, spine_w, max_img_w, max_img_h, display)
                if widget then
                    _installWidget(self, widget)
                    return
                end
            end
            -- No covers yet — register for async retry.
            if self.menu and self.menu.items_to_update then
                if not self.menu._fc_pending_set then
                    self.menu._fc_pending_set = {}
                end
                if not self.menu._fc_pending_set[self] then
                    self.menu._fc_pending_set[self] = true
                    table.insert(self.menu.items_to_update, self)
                end
            end
            return
        end

        -- ── Single-cover mode (default) ───────────────────────────────────────

        -- User-chosen cover override.
        local override_fp = _getCoverOverrides()[dir_path]
        if override_fp then
            local bi = BookInfoManager:getBookInfo(override_fp, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
            then
                self:_setFolderCover(
                    { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                    display)
                return
            end
        end

        -- ── Static .cover.* image file ────────────────────────────────────────
        local cover_file = findCover(dir_path)
        if cover_file then
            local ok, w, h = pcall(function()
                local tmp = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                tmp:_render()
                local ow = tmp:getOriginalWidth()
                local oh = tmp:getOriginalHeight()
                tmp:free()
                return ow, oh
            end)
            if ok and w and h then
                self:_setFolderCover(
                    { file = cover_file, w = w, h = h },
                    display)
                return
            end
        end

        -- ── First cached book cover inside the folder ─────────────────────────
        local has_files      = false
        local has_subfolders = false

        local entries = _entriesWithNoFilter(self.menu, dir_path)
        if entries then
            for _, entry in ipairs(entries) do
                if entry.is_file or entry.file then
                    has_files = true
                    local bi = BookInfoManager:getBookInfo(entry.path, true)
                    if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                            and not bi.ignore_cover
                            and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                    then
                        self:_setFolderCover(
                            { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                            display)
                        return
                    end
                else
                    has_subfolders = true
                end
            end
        end

        -- ── Bookless folder: recursive scan or placeholder ────────────────────
        if not has_files then
            if has_subfolders and M.getSubfolderCover() and M.getRecursiveCover() then
                local cover = _findCoverRecursive(self.menu, dir_path, 1, 3, BookInfoManager)
                if cover then
                    self:_setFolderCover(cover, display)
                    return
                end
            end
            if M.getSubfolderCover() then
                self:_setEmptyFolderCover(display)
            end
            return
        end

        -- No cover found yet — register for async retry once BookInfoManager
        -- finishes extracting covers in the background.
        if self.menu and self.menu.items_to_update then
            if not self.menu._fc_pending_set then
                self.menu._fc_pending_set = {}
            end
            if not self.menu._fc_pending_set[self] then
                self.menu._fc_pending_set[self] = true
                table.insert(self.menu.items_to_update, self)
            end
        end
    end

    -- Builds and installs a single-image cover widget into the mosaic cell.
    -- `img`     — { file=path } or { data=blitbuffer, w=n, h=n }
    -- `display` — pre-read settings table { label_mode, show_name, label_style, label_pos }
    function MosaicMenuItem:_setFolderCover(img, display)
        self._foldercover_processed = true
        local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)

        local img_options = {}
        if img.file then img_options.file  = img.file end
        if img.data then img_options.image = img.data end

        local ratio = 2 / 3
        if max_img_w / max_img_h > ratio then
            img_options.height = max_img_h
            img_options.width  = math.floor(max_img_h * ratio)
        else
            img_options.width  = max_img_w
            img_options.height = math.floor(max_img_w / ratio)
        end
        img_options.stretch_limit_percentage = 50

        local image        = ImageWidget:new(img_options)
        local size         = image:getSize()
        local content      = FrameContainer:new{ padding = 0, bordersize = border, image }
        _installWidget(self, _assembleCoverWidget(self, content, size, border, spine_w, display))
    end

    -- Placeholder cover for bookless folders (only subfolders or empty).
    -- `display` — pre-read settings table { label_mode, show_name, label_style, label_pos }
    function MosaicMenuItem:_setEmptyFolderCover(display)
        self._foldercover_processed = true
        local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)

        local ratio = 2 / 3
        local img_w, img_h
        if max_img_w / max_img_h > ratio then
            img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
        else
            img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
        end

        local icon_size   = math.floor(math.min(img_w, img_h) * 0.5)
        local icon_widget = nil

        local actual_icon_path = _ICON_PATH
        pcall(function()
            local SUIStyle = require("sui_style")
            local custom = SUIStyle.getIcon("sui_fc_empty")
            if custom then actual_icon_path = custom end
        end)

        local Config = require("sui_config")
        local nerd_char = Config.nerdIconChar(actual_icon_path)

        if nerd_char then
            local ok_tw, tw = pcall(function()
                return CenterContainer:new{
                    dimen = Geom:new{ w = img_w, h = img_h },
                    TextWidget:new{
                        text    = nerd_char,
                        face    = Font:getFace("symbols", math.floor(icon_size * 0.85)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        padding = 0,
                    },
                }
            end)
            if ok_tw then icon_widget = tw end
        else
            local actual_icon_exists = lfs.attributes(actual_icon_path, "mode") == "file"
            if actual_icon_exists then
                local ok_iw, iw = pcall(function()
                    return CenterContainer:new{
                        dimen = Geom:new{ w = img_w, h = img_h },
                        ImageWidget:new{
                            file    = actual_icon_path,
                            width   = icon_size,
                            height  = icon_size,
                            alpha   = true,
                            is_icon = true,
                        },
                    }
                end)
                if ok_iw then icon_widget = iw end
            end
        end

        local bg_canvas = FrameContainer:new{
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen      = Geom:new{ w = img_w, h = img_h },
            icon_widget,
        }

        local size    = Geom:new{ w = img_w, h = img_h }
        local content = FrameContainer:new{ padding = 0, bordersize = border, bg_canvas }
        _installWidget(self, _assembleCoverWidget(self, content, size, border, spine_w, display))
    end

    -- Binary-search the largest font size that fits the folder name in the
    -- available width without overflowing two lines. Result is cached in the
    -- module-level bounded two-generation cache (keyed by text+width+max_fs) so
    -- repeated renders after scroll/recycle skip all widget allocations.
    -- Capitalises the first letter of each word.
    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size)
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w) return w:sub(1,1):upper() .. w:sub(2) end)
            self._fc_display_text = BD.directory(text)
        end
        local text      = self._fc_display_text
        local max_fs    = dir_max_font_size or _BASE_DIR_FS
        local cache_key = text .. "\0" .. available_w .. "\0" .. max_fs

        local cached_fs = _fsCacheGet(cache_key)
        if cached_fs then
            return TextBoxWidget:new{
                text      = text,
                face      = Font:getFace("cfont", cached_fs),
                width     = available_w,
                alignment = "center",
                bold      = true,
            }
        end

        -- Pass 1: find the largest font where the longest word still fits.
        -- Use font metrics directly (no widget allocation) when available;
        -- fall back to a single TextWidget measurement otherwise.
        local longest_word = ""
        for word in text:gmatch("%S+") do
            if #word > #longest_word then longest_word = word end
        end

        local dir_font_size = max_fs

        if longest_word ~= "" then
            local lo, hi = 8, dir_font_size
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                local tw = TextWidget:new{
                    text = longest_word,
                    face = Font:getFace("cfont", mid),
                    bold = true,
                }
                local word_w = tw:getWidth()
                tw:free()
                if word_w <= available_w then lo = mid else hi = mid - 1 end
            end
            dir_font_size = lo
        end

        -- Pass 2: find the largest font where the full text fits in two lines.
        -- A TextBoxWidget allocation here is unavoidable (we need line wrapping),
        -- but we keep the range tight thanks to Pass 1, minimising iterations.
        -- pcall guards against exotic text/font combinations that can raise in TextBoxWidget.
        local lo, hi = 8, dir_font_size
        while lo < hi do
            local mid  = math.floor((lo + hi + 1) / 2)
            local fits = false
            local ok, tbw = pcall(function()
                return TextBoxWidget:new{
                    text      = text,
                    face      = Font:getFace("cfont", mid),
                    width     = available_w,
                    alignment = "center",
                    bold      = true,
                }
            end)
            if ok and tbw then
                fits = tbw:getSize().h <= tbw:getLineHeight() * 2.2
                tbw:free(true)
            end
            if fits then lo = mid else hi = mid - 1 end
        end
        dir_font_size = lo

        _fsCacheSet(cache_key, dir_font_size)

        return TextBoxWidget:new{
            text      = text,
            face      = Font:getFace("cfont", dir_font_size),
            width     = available_w,
            alignment = "center",
            bold      = true,
        }
    end

    -- onFocus: apply the pre-computed underline color (no settings read in the hot path).
    MosaicMenuItem._simpleui_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = self._fc_underline_color
            or (M.getHideUnderline() and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
        return true
    end

    -- paintTo: draw book-cover overlays (pages badge, series index badge).
    -- Folder covers are handled via widget replacement in _setFolderCover;
    -- this function only acts on regular book items.
    -- All badge geometry constants are pre-computed at module level.
    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem._simpleui_fc_orig_paintTo = orig_paintTo

    local function _round(v) return math.floor(v + 0.5) end

    function MosaicMenuItem:paintTo(bb, x, y)
        x = math.floor(x)
        y = math.floor(y)

        -- Always refresh corner_mark_size from orig_paintTo's upvalue so that
        -- _fc_coll_sz is current in every progress mode (not just "banner") and
        -- automatically tracks grid changes (nb_cols/nb_rows, screen rotation).
        -- This is a cheap integer upvalue read done once per cell per frame.
        if not self.is_directory then
            local ni = 1
            while true do
                local nm, vl = debug.getupvalue(orig_paintTo, ni)
                if not nm then break end
                if nm == "corner_mark_size" then _fc_coll_sz = vl; break end
                ni = ni + 1
            end
        end

        -- When the progress pentagon badge is active ("banner" mode), suppress
        -- native KOReader marks that would overlap or duplicate it:
        --   do_hint_opened   → dog-ear corner mark ("reading in progress")
        --   shortcut_icon    → collection star — suppressed here; redrawn at
        --                      bottom-right after orig_paintTo when in banner mode
        --   has_description  → description side bar (right edge)
        -- NOTE: show_progress_bar (native bottom bar) is intentionally NOT
        -- suppressed — it remains visible alongside the pentagon badge.
        -- In "none" mode the same marks are also suppressed (user wants no indicators).
        -- In "native" mode they are left untouched so KOReader draws them normally.
        -- Fields are temporarily nil'd before calling orig_paintTo and restored
        -- immediately after, so all other paintTo logic is unaffected.
        local _saved_hint, _saved_icon, _saved_desc, _saved_menu_name
        local _saved_been_opened
        local _progress_mode = M.getProgressMode()
        if (_progress_mode == "banner" or _progress_mode == "none") and not self.is_directory then
            _saved_hint = self.do_hint_opened;   self.do_hint_opened   = false
            _saved_icon = self.shortcut_icon;    self.shortcut_icon    = nil
            _saved_desc = self.has_description;  self.has_description  = false
            -- Spoof menu.name so orig_paintTo skips the native collection mark.
            -- In banner mode we redraw it at bottom-right below.
            -- In none mode it stays suppressed entirely.
            if self.menu then
                _saved_menu_name = self.menu.name
                self.menu.name   = "collections"
            end
            -- When the collection mark will be redrawn at bottom-right (banner mode,
            -- book in a collection), make the native progress bar shrink its right edge
            -- by corner_mark_size pixels — exactly the same behaviour as do_hint_opened.
            -- We set do_hint_opened = true for orig_paintTo but keep been_opened = false
            -- so the dog-ear mark (which requires do_hint_opened AND been_opened) is
            -- never drawn.  The dog-ear was already suppressed above; this is just
            -- belt-and-suspenders, but it also correctly avoids the dog-ear when
            -- self.been_opened happens to be true.
            if _progress_mode == "banner"
                    and self.show_progress_bar
                    and self.filepath
                    and ReadCollection
                    and ReadCollection:isFileInCollections(self.filepath) then
                _saved_been_opened    = self.been_opened
                self.do_hint_opened   = true
                self.been_opened      = false
            end
        end

        orig_paintTo(self, bb, x, y)

        if (_progress_mode == "banner" or _progress_mode == "none") and not self.is_directory then
            self.do_hint_opened   = _saved_hint
            self.shortcut_icon    = _saved_icon
            self.has_description  = _saved_desc
            if self.menu and _saved_menu_name ~= nil then
                self.menu.name = _saved_menu_name
            end
            if _saved_been_opened ~= nil then
                self.been_opened = _saved_been_opened
            end
        end

        -- ── Collection mark repositioned to bottom-right (banner mode only) ────────
        -- orig_paintTo was prevented from drawing the mark at top-right (menu.name
        -- spoofed above).  Here we draw it at bottom-right using the same ix as the
        -- native code but with iy = bottom of cover instead of top.
        -- corner_mark_size and collection_mark are read lazily from orig_paintTo's
        -- upvalues; they are nil until mosaicmenu initialises them on first update().
        if _progress_mode == "banner" and not self.is_directory
                and self.filepath
                and self.menu and _saved_menu_name ~= nil and _saved_menu_name ~= "collections"
                and ReadCollection and ReadCollection:isFileInCollections(self.filepath) then
            -- Read corner_mark_size / collection_mark from orig_paintTo upvalues.
            -- Cached in closures; re-read only when the widget is nil (first render)
            -- or when corner_mark_size changes (screen rotation / zoom change).
            if not _fc_coll_widget then
                local ni = 1
                while true do
                    local nm, vl = debug.getupvalue(orig_paintTo, ni)
                    if not nm then break end
                    if nm == "corner_mark_size" then _fc_coll_sz     = vl end
                    if nm == "collection_mark"  then _fc_coll_widget = vl end
                    ni = ni + 1
                end
            end
            local cm_size   = _fc_coll_sz
            local cm_widget = _fc_coll_widget
            if cm_size and cm_widget then
                local tgt = self[1] and self[1][1] and self[1][1][1]
                if tgt and tgt.dimen then
                    -- ix mirrors the native top-right calculation
                    local ix
                    if BD.mirroredUILayout() then
                        ix = math.floor((self.width - tgt.dimen.w) / 2)
                    else
                        ix = self.width - math.ceil((self.width - tgt.dimen.w) / 2) - cm_size
                    end
                    -- iy: bottom of cover minus mark size (mirrors do_hint_opened logic)
                    local iy = self.height - math.ceil((self.height - tgt.dimen.h) / 2) - cm_size
                    local rect_size = cm_size - tgt.bordersize
                    bb:paintRect(x + ix, tgt.dimen.y + iy + tgt.bordersize,
                                 rect_size, rect_size, Blitbuffer.COLOR_GRAY)
                    cm_widget:paintTo(bb, x + ix, y + iy)
                end
            end
        end

        if self.is_directory or self.file_deleted then return end

        -- Locate the cover FrameContainer in the widget tree.
        local target = self._cover_frame
            or (self[1] and self[1][1] and self[1][1][1])
        if not target or not target.dimen then return end

        local fw = target.dimen.w
        local fh = target.dimen.h
        -- Prefer the absolute coordinates stored by orig_paintTo (most accurate).
        -- Fall back to manual centring when dimen.x/y are not yet populated.
        local fx, fy
        if target.dimen.x and target.dimen.x ~= 0 then
            fx = target.dimen.x
            fy = target.dimen.y
        else
            fx = x + _round((self.width  - fw) / 2)
            fy = y + _round((self.height - fh) / 2)
        end

        -- (fw, fh, fx, fy already set above)

        -- Left margin of the native progress bar, computed the same way KOReader does
        -- in mosaicmenu.lua paintTo():
        --   progress_widget_margin = floor((corner_mark_size - progress_widget.height) / 2)
        --   pos_x = x + ceil((self.width - progress_widget.width) / 2)
        --         = fx + progress_widget_margin
        -- _fc_coll_sz holds corner_mark_size (read from orig_paintTo upvalues in banner
        -- mode); fall back to _BADGE_RIGHT_INSET before it has been populated.
        local _native_bar_left_margin
        if _fc_coll_sz then
            _native_bar_left_margin = math.floor((_fc_coll_sz - _BADGE_BAR_H) / 2)
        else
            _native_bar_left_margin = _BADGE_RIGHT_INSET
        end

        -- ── Pages badge (bottom-left) ─────────────────────────────────────────
        if self._fc_overlay_pages and self.status ~= "complete" then
            local desc = self._fc_pages_desc
            if desc then
                -- Align the badge left edge with the left edge of the native progress bar.
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - desc.w - _native_bar_left_margin
                else
                    badge_x = fx + _native_bar_left_margin
                end
                -- When the native progress bar is visible, lift the badge above it.
                local badge_y
                if self.show_progress_bar then
                    local corner_sz = _fc_coll_sz or math.floor(math.min(self.width, self.height) / 8)
                    local bar_top   = fy + fh - corner_sz + _native_bar_left_margin
                    badge_y = bar_top - _BADGE_BAR_GAP - desc.h
                else
                    badge_y = fy + fh - desc.h - _native_bar_left_margin
                end
                _drawRectBadge(bb, badge_x, badge_y, desc)
            end
        end

        -- ── Series index badge (top-left) ─────────────────────────────────────
        if self._fc_overlay_series then
            local desc = self._fc_series_desc
            -- Fallback: if the descriptor was not pre-built (e.g. series_index
            -- was not yet in the BookList cache when update() ran), query
            -- BookInfoManager directly — same behaviour as the previous version.
            if not desc and self.filepath then
                local bi = BookInfoManager:getBookInfo(self.filepath, false)
                if bi and bi.series and bi.series_index then
                    local cell_min = math.min(self.width or fw, self.height or fh)
                    local dark = M.getBadgeColorSeries() == "dark"
                    local d = _buildRectBadgeDesc("#" .. bi.series_index, false, cell_min, dark, false)
                    if d then
                        -- Cache for future paintTo calls.
                        self._fc_series_desc = d
                        desc = d
                    end
                end
            end
            if desc then
                -- Align left edge with the native progress bar (same margin as pages badge).
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - desc.w - _native_bar_left_margin
                else
                    badge_x = fx + _native_bar_left_margin
                end
                local badge_y = fy + _BADGE_RIGHT_INSET
                _drawRectBadge(bb, badge_x, badge_y, desc)
            end
        end

        -- ── Progress pentagon badge (top-right) ───────────────────────────────
        -- Drawn directly onto `bb` (no intermediate Blitbuffer) so pixels
        -- outside the pentagon shape are never written — the cover art shows
        -- through the triangular tip without any white artefact.
        -- Offset upward by `border` so the badge top edge sits exactly on top
        -- of the cover FrameContainer border — the top line of the pentagon
        -- merges with the cover frame and becomes invisible.
        if self._fc_overlay_progress then
            local prog_desc = self._fc_progress_bb   -- descriptor table, not a BB
            if prog_desc then
                local fr     = prog_desc.border
                local rect_w = prog_desc.bw + 2 * fr
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + _BADGE_RIGHT_INSET
                else
                    badge_x = fx + fw - rect_w - _BADGE_RIGHT_INSET
                end
                -- badge_y = fy - fr  →  top edge of pentagon overlaps cover border
                local badge_y = fy - fr
                _drawProgressBadge(bb, badge_x, badge_y, prog_desc)
            end
        end

        -- ── "New" badge (top-right) ───────────────────────────────────────────────────────────────
        -- Shown only for truly unread books (percent_finished == nil, status not complete/abandoned).
        -- Mirrors the pages badge geometry: same inset from top+right as pages has from bottom+left.
        -- Not shown when the progress pentagon badge is already active for this item.
        if self._fc_overlay_new then
            local desc = self._fc_new_desc
            local has_progress_badge = self._fc_overlay_progress and self._fc_progress_bb
            if desc and not has_progress_badge then
                -- Mirror the pages/series inset: same _BADGE_RIGHT_INSET from top-right.
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + _BADGE_RIGHT_INSET
                else
                    badge_x = fx + fw - desc.w - _BADGE_RIGHT_INSET
                end
                local badge_y = fy + _BADGE_RIGHT_INSET
                _drawRectBadge(bb, badge_x, badge_y, desc)
            end
        end

    end

    local orig_free = MosaicMenuItem.free
    MosaicMenuItem._simpleui_fc_orig_free = orig_free
    function MosaicMenuItem:free()
        -- All badge state is now plain descriptor tables (no Blitbuffer to free).
        self._fc_progress_bb = nil
        self._fc_pages_desc  = nil
        self._fc_series_desc = nil
        self._fc_new_desc    = nil
        self._fc_overlay_new = nil
        -- Title/author strip blitbuffer cleanup.
        if self._simpleui_strip_bb then self._simpleui_strip_bb:free(); self._simpleui_strip_bb = nil end
        self._simpleui_strip_data = nil
        if orig_free then orig_free(self) end
    end

    _installItemCache()
    _installSeriesGrouping()
    _installFileDialogButton(BookInfoManager)

    -- -----------------------------------------------------------------------
    -- Title/Author strip — deferred paintTo patch.
    -- Must run after the badge paintTo wrap (above) so this wrapper is the
    -- outermost layer and calls the badge-patched paintTo as orig_paintTo.
    -- We defer via FileManager.setupLayout so the badge patch has already been
    -- applied by the time we capture orig_paintTo.
    -- -----------------------------------------------------------------------
    if _STRIP_H > 0 then
        local ok_fm_strip, FileManager_strip = pcall(require, "apps/filemanager/filemanager")
        if ok_fm_strip and FileManager_strip then
            local _strip_orig_setupLayout = FileManager_strip.setupLayout
            local _strip_paintTo_patched  = false

            FileManager_strip.setupLayout = function(fm, ...)
                _strip_orig_setupLayout(fm, ...)
                if _strip_paintTo_patched or not fm.coverbrowser then return end
                _strip_paintTo_patched = true

                local Blitbuffer_s  = require("ffi/blitbuffer")
                local Font_s        = require("ui/font")
                local TextWidget_s  = require("ui/widget/textwidget")
                local BD_s          = require("ui/bidi")
                local Screen_s      = require("device").screen

                local TITLE_FONT_S  = 16
                local AUTHOR_FONT_S = 13
                local PAD_S         = Screen_s:scaleBySize(3)
                local GAP_S         = Screen_s:scaleBySize(2)
                local PAD_H_S       = Screen_s:scaleBySize(6)  -- horizontal text margin

                -- Re-measure line heights at paint time for accuracy.
                local function _mhs(fs, bold)
                    local tw = TextWidget_s:new{ text="Ag", face=Font_s:getFace("cfont",fs),
                        bold=bold, padding=0 }
                    local h = tw:getSize().h; tw:free(); return h
                end
                local TITLE_LINE_S  = _mhs(TITLE_FONT_S, true)
                -- AUTHOR_LINE_S only needed for cur_y offset (already embedded in _STRIP_H).

                local orig_strip_paintTo = MosaicMenuItem.paintTo

                function MosaicMenuItem:paintTo(bb, x, y)
                    x = math.floor(x); y = math.floor(y)
                    -- Temporarily shrink self.height by _STRIP_H before calling the
                    -- badge-patched paintTo chain so that KOReader's own paintTo
                    -- calculations (native progress bar pos_y, dog-ear iy, etc.) all
                    -- treat the cover area as ending above the strip.  Without this,
                    -- the native progress bar is drawn inside the strip zone and
                    -- immediately covered by it.
                    if _STRIP_H > 0 and self.height then
                        self.height = self.height - _STRIP_H
                    end
                    orig_strip_paintTo(self, bb, x, y)
                    if _STRIP_H > 0 and self.height then
                        self.height = self.height + _STRIP_H
                    end

                    -- Nothing to do when strip was not requested.
                    if _STRIP_H <= 0 then return end

                    -- Build/use the cached strip blitbuffer.
                    if not self._simpleui_strip_bb then

                        -- ── Folders (real and virtual) ──────────────────────────
                        if self.is_directory then
                            local name = self.text and self.text:gsub("/$", "") or ""
                            if name == "" then return end

                            local strip_bb = Blitbuffer_s.new(self.width, _STRIP_H, bb:getType())
                            strip_bb:fill(Blitbuffer_s.COLOR_WHITE)
                            local tw = TextWidget_s:new{
                                text                   = BD_s.auto(name),
                                face                   = Font_s:getFace("cfont", TITLE_FONT_S),
                                bold                   = true,
                                padding                = 0,
                                fgcolor                = Blitbuffer_s.COLOR_BLACK,
                                max_width              = self.width - 2 * PAD_H_S,
                                truncate_with_ellipsis = true,
                            }
                            local tsz = tw:getSize()
                            tw:paintTo(strip_bb,
                                math.floor((self.width - tsz.w) / 2),
                                math.floor((_STRIP_H  - tsz.h) / 2))
                            tw:free()
                            self._simpleui_strip_bb = strip_bb

                        -- ── Books ───────────────────────────────────────────────
                        else
                            -- Populate metadata cache on first paint after an update().
                            if self._simpleui_strip_data == nil then
                                if not self.bookinfo_found then
                                    self._simpleui_strip_data = false
                                else
                                    local info = BookInfoManager:getBookInfo(self.filepath, false)
                                    local title   = info and not info.ignore_meta and info.title   or nil
                                    local authors = info and not info.ignore_meta and info.authors or nil
                                    -- Use only the first author when multiple are stored as newline-separated.
                                    if authors and authors:find("\n") then
                                        authors = authors:match("^([^\n]+)")
                                    end
                                    if title or authors then
                                        self._simpleui_strip_data = { title = title, authors = authors }
                                    else
                                        self._simpleui_strip_data = false
                                    end
                                end
                            end
                            if not self._simpleui_strip_data then return end

                            local strip_bb = Blitbuffer_s.new(self.width, _STRIP_H, bb:getType())
                            strip_bb:fill(Blitbuffer_s.COLOR_WHITE)
                            local text_w = self.width - 2 * PAD_H_S
                            local cur_y  = PAD_S

                            if _show_title_strip and self._simpleui_strip_data.title then
                                local tw = TextWidget_s:new{
                                    text                   = BD_s.auto(self._simpleui_strip_data.title),
                                    face                   = Font_s:getFace("cfont", TITLE_FONT_S),
                                    bold                   = true,
                                    padding                = 0,
                                    fgcolor                = Blitbuffer_s.COLOR_BLACK,
                                    max_width              = text_w,
                                    truncate_with_ellipsis = true,
                                }
                                local tsz = tw:getSize()
                                tw:paintTo(strip_bb, math.floor((self.width - tsz.w) / 2), cur_y)
                                tw:free()
                                if _show_author_strip then cur_y = cur_y + TITLE_LINE_S + GAP_S end
                            end

                            if _show_author_strip and self._simpleui_strip_data.authors then
                                local aw = TextWidget_s:new{
                                    text                   = BD_s.auto(self._simpleui_strip_data.authors),
                                    face                   = Font_s:getFace("cfont", AUTHOR_FONT_S),
                                    bold                   = false,
                                    padding                = 0,
                                    fgcolor                = Blitbuffer_s.COLOR_BLACK,
                                    max_width              = text_w,
                                    truncate_with_ellipsis = true,
                                }
                                local asz = aw:getSize()
                                aw:paintTo(strip_bb, math.floor((self.width - asz.w) / 2), cur_y)
                                aw:free()
                            end

                            self._simpleui_strip_bb = strip_bb
                        end
                    end

                    -- Blit the strip immediately below the cover area.
                    if self._simpleui_strip_bb then
                        local ok_hs, HS_s = pcall(require, "sui_homescreen")
                        local wp_active = ok_hs and HS_s and HS_s.styleGetWallpaperShowInFM() and HS_s.styleGetBgWidget() ~= nil

                        if wp_active then
                            require("sui_core").paintWithAlphaMask(self, bb,
                                x, y + self.height - _STRIP_H, self.width, _STRIP_H,
                                Blitbuffer_s.COLOR_BLACK,
                                function(w, tmp_bb, tx, ty)
                                    tmp_bb:blitFrom(w._simpleui_strip_bb, tx, ty, 0, 0, w.width, _STRIP_H)
                                end)
                        else
                            bb:blitFrom(self._simpleui_strip_bb,
                                x, y + self.height - _STRIP_H,
                                0, 0, self.width, _STRIP_H)
                        end
                    end
                end -- paintTo
            end -- setupLayout
        end -- FileManager available
    end -- _STRIP_H > 0

    -- -----------------------------------------------------------------------
    -- ListMenuItem patch — cover images for virtual folders in list_image_meta.
    -- -----------------------------------------------------------------------

    local ListMenuItem = _getListMenuItem()
    if ListMenuItem and not ListMenuItem._simpleui_lm_patched then
        ListMenuItem._simpleui_lm_patched     = true
        ListMenuItem._simpleui_lm_orig_update = ListMenuItem.update

        local orig_lm_update = ListMenuItem.update
        function ListMenuItem:update(...)
            orig_lm_update(self, ...)

            if not self.do_cover_image                   then return end
            if not M.isEnabled()                         then return end
            if self.menu and self.menu.no_refresh_covers then return end
            if self._foldercover_processed               then return end

            local entry = self.entry
            if not entry or entry.is_file or entry.file then return end

            local cover_specs = self.menu and self.menu.cover_specs
            local dir_path    = entry.path
            if not dir_path then return end

            -- ── Virtual meta-leaf (browsemeta) ────────────────────────────────
            if entry.is_virtual_meta_leaf then
                local repr_fp     = entry.representative_filepath
                local override_fp = _getCoverOverrides()[dir_path]
                if override_fp then repr_fp = override_fp end
                if not repr_fp then return end
                local bi = BookInfoManager:getBookInfo(repr_fp, true)
                if not bi then return end
                if not (bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover and bi.cover_bb) then return end
                if cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs) then return end
                self:_setListFolderCover(bi)
                return
            end

            -- ── Series group ──────────────────────────────────────────────────
            if entry.is_series_group then
                local sg_override_fp = _getCoverOverrides()[dir_path]
                if sg_override_fp then
                    local bi = BookInfoManager:getBookInfo(sg_override_fp, true)
                    if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                            and not bi.ignore_cover
                            and not (cover_specs and
                                BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                    then
                        self:_setListFolderCover(bi)
                        return
                    end
                end
                local items = entry.series_items or _sg_items_cache[dir_path]
                if items then
                    for _, book_entry in ipairs(items) do
                        if book_entry.path then
                            local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                            if bi and bi.has_cover and bi.cover_fetched
                                    and not bi.ignore_cover and bi.cover_bb
                                    and not (cover_specs and
                                        BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                            then
                                self:_setListFolderCover(bi)
                                return
                            end
                        end
                    end
                end
                return
            end

            -- ── Real folder ───────────────────────────────────────────────────

            -- 1. User-chosen cover override.
            local override_fp = _getCoverOverrides()[dir_path]
            if override_fp then
                local bi = BookInfoManager:getBookInfo(override_fp, true)
                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover
                        and not (cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                then
                    self:_setListFolderCover(bi)
                    return
                end
            end

            -- 2. Static .cover.* image file.
            local cover_file = findCover(dir_path)
            if cover_file then
                local ok, img = pcall(function()
                    local iw = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                    iw:_render()
                    local bb = iw._bb and iw._bb:copy()
                    local ow = iw:getOriginalWidth()
                    local oh = iw:getOriginalHeight()
                    iw:free()
                    return { cover_bb = bb, cover_w = ow, cover_h = oh,
                             has_cover = true, cover_fetched = true }
                end)
                if ok and img and img.cover_bb then
                    self:_setListFolderCover(img)
                    return
                end
            end

            -- 3. First cached book cover — result cached per directory to avoid
            --    repeating the lfs.dir + per-file lfs.attributes walk on every
            --    reader→HS cycle.
            local cached_lm = _lmcGet(dir_path)
            if cached_lm == false then
                -- confirmed miss — fall through to async retry
            elseif cached_lm ~= nil then
                self:_setListFolderCover(cached_lm)
                return
            else
                local saved_filter = FileChooser.show_filter
                FileChooser.show_filter = {}
                local ok_dir, iter, dir_obj = pcall(lfs.dir, dir_path)
                if ok_dir and iter then
                    for f in iter, dir_obj do
                        if f ~= "." and f ~= ".." then
                            local fp   = dir_path .. "/" .. f
                            local attr = lfs.attributes(fp) or {}
                            if attr.mode == "file"
                                    and not f:match("^%._")
                                    and FileChooser:show_file(f, fp)
                            then
                                local bi = BookInfoManager:getBookInfo(fp, true)
                                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                        and not bi.ignore_cover
                                        and not (cover_specs and
                                            BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                                then
                                    FileChooser.show_filter = saved_filter
                                    local entry = {
                                        cover_bb      = bi.cover_bb,
                                        cover_w       = bi.cover_w,
                                        cover_h       = bi.cover_h,
                                        has_cover     = true,
                                        cover_fetched = true,
                                    }
                                    _lmcSet(dir_path, entry)
                                    self:_setListFolderCover(entry)
                                    return
                                end
                            end
                        end
                    end
                end
                FileChooser.show_filter = saved_filter
                _lmcSet(dir_path, false)
            end

            -- 4. Nothing yet — register for async retry when BookInfoManager
            --    finishes extracting covers in the background.
            if self.menu and self.menu.items_to_update then
                if not self.menu._fc_pending_set then
                    self.menu._fc_pending_set = {}
                end
                if not self.menu._fc_pending_set[self] then
                    self.menu._fc_pending_set[self] = true
                    table.insert(self.menu.items_to_update, self)
                end
            end
        end

        -- Renders a cover thumbnail on the left, folder name + item count on the right.
        function ListMenuItem:_setListFolderCover(bookinfo)
            self._foldercover_processed = true

            local underline_h = self.underline_h or 1
            local dimen = Geom:new{
                w = self.width,
                h = self.height - 2 * underline_h,
            }

            local border_size = Size.border.thin
            local img_size    = dimen.h
            local max_img_w   = img_size - 2 * border_size

            local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
                bookinfo.cover_w, bookinfo.cover_h, max_img_w, max_img_w)
            local wimage = ImageWidget:new{
                image        = bookinfo.cover_bb,
                scale_factor = scale_factor,
            }
            wimage:_render()
            local image_size = wimage:getSize()

            local wleft = CenterContainer:new{
                dimen = Geom:new{ w = img_size, h = dimen.h },
                FrameContainer:new{
                    width      = image_size.w + 2 * border_size,
                    height     = image_size.h + 2 * border_size,
                    margin     = 0,
                    padding    = 0,
                    bordersize = border_size,
                    wimage,
                },
            }

            local pad       = _LATERAL_PAD  -- already Screen:scaleBySize(10) at module level
            local main_w    = dimen.w - img_size - pad * 2
            local font_size = (self.menu and self.menu.font_size) or 20
            local info_size = math.max(10, font_size - 4)

            local wname = TextBoxWidget:new{
                text                          = BD.directory(self.text),
                face                          = Font:getFace("cfont", font_size),
                width                         = main_w,
                alignment                     = "left",
                bold                          = true,
                height                        = dimen.h,
                height_adjust                 = true,
                height_overflow_show_ellipsis = true,
            }
            local wcount = TextWidget:new{
                text = self.mandatory or "",
                face = Font:getFace("infont", info_size),
            }

            local wmain = LeftContainer:new{
                dimen = Geom:new{ w = main_w, h = dimen.h },
                VerticalGroup:new{
                    wname,
                    VerticalSpan:new{ width = _EDGE_MARGIN * 2 },  -- ~scaleBySize(2)
                    wcount,
                },
            }

            local widget = OverlapGroup:new{
                dimen = dimen:copy(),
                wleft,
                LeftContainer:new{
                    dimen = dimen:copy(),
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = img_size + pad },
                        wmain,
                    },
                },
            }

            if self._underline_container[1] then self._underline_container[1]:free() end
            self._underline_container[1] = VerticalGroup:new{
                VerticalSpan:new{ width = underline_h },
                widget,
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Uninstall — restores all patched methods and releases module-level caches.
-- ---------------------------------------------------------------------------

function M.uninstall()
    local MosaicMenuItem = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if not MosaicMenuItem._simpleui_fc_patched then return end

    if MosaicMenuItem._simpleui_fc_orig_update then
        MosaicMenuItem.update = MosaicMenuItem._simpleui_fc_orig_update
        MosaicMenuItem._simpleui_fc_orig_update = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_paintTo then
        MosaicMenuItem.paintTo = MosaicMenuItem._simpleui_fc_orig_paintTo
        MosaicMenuItem._simpleui_fc_orig_paintTo = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_free then
        MosaicMenuItem.free = MosaicMenuItem._simpleui_fc_orig_free
        MosaicMenuItem._simpleui_fc_orig_free = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_onFocus then
        MosaicMenuItem.onFocus = MosaicMenuItem._simpleui_fc_orig_onFocus
        MosaicMenuItem._simpleui_fc_orig_onFocus = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_init ~= nil then
        MosaicMenuItem.init = MosaicMenuItem._simpleui_fc_orig_init
        MosaicMenuItem._simpleui_fc_orig_init = nil
    end
    if MosaicMenuItem._simpleui_fc_iw_n and MosaicMenuItem._simpleui_fc_orig_iw then
        debug.setupvalue(MosaicMenuItem.update, MosaicMenuItem._simpleui_fc_iw_n,
            MosaicMenuItem._simpleui_fc_orig_iw)
        MosaicMenuItem._simpleui_fc_iw_n         = nil
        MosaicMenuItem._simpleui_fc_orig_iw      = nil
        MosaicMenuItem._simpleui_fc_stretched_iw = nil
    end
    MosaicMenuItem._setFolderCover      = nil
    MosaicMenuItem._getFolderNameWidget = nil
    MosaicMenuItem._simpleui_fc_patched = nil
    MosaicMenuItem._simpleui_strip_h    = nil
    _module_strip_h = 0

    _uninstallItemCache()
    _uninstallSeriesGrouping()
    _uninstallFileDialogButton()

    for k in pairs(_cover_file_cache)        do _cover_file_cache[k]        = nil end
    for k in pairs(_cfc_b)                  do _cfc_b[k]                   = nil end
    _cfc_cnt = 0
    for k in pairs(_lm_dir_cover_cache)     do _lm_dir_cover_cache[k]     = nil end
    for k in pairs(_lmc_b)                  do _lmc_b[k]                   = nil end
    _lmc_cnt = 0
    for k in pairs(_fs_cache_a)             do _fs_cache_a[k]              = nil end
    for k in pairs(_fs_cache_b)             do _fs_cache_b[k]              = nil end
    _fs_cache_a_cnt = 0
    _overrides_cache = nil

    local ListMenuItem = _getListMenuItem()
    if ListMenuItem and ListMenuItem._simpleui_lm_patched then
        if ListMenuItem._simpleui_lm_orig_update then
            ListMenuItem.update = ListMenuItem._simpleui_lm_orig_update
            ListMenuItem._simpleui_lm_orig_update = nil
        end
        ListMenuItem._setListFolderCover      = nil
        ListMenuItem._simpleui_lm_patched     = nil
    end
end

return M
