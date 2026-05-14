-- module_new_books.lua — Simple UI
-- Module: New Books (recently added to library, sorted by file date).
-- Scans the home directory recursively for book files and displays
-- the most recently added ones with cover thumbnails.  Unread books
-- are labelled "New"; started books show their read percentage.

local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local _ = require("sui_i18n").translate

local logger = require("logger")
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_new_books: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config       = require("sui_config")
local UI           = require("sui_core")
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_NB_LABEL_FS = Screen:scaleBySize(10)
local _SCAN_CACHE_TTL_S = 30
local _scan_cache = { home = nil, ts = 0, list = nil }

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "new_books"
M.name        = _("New Books")
M.label       = _("New Books")
M.enabled_key = "new_books"
M.default_on  = false  -- opt-in; users enable via Arrange Modules

function M.reset()
    _SH = nil
    _scan_cache.home = nil
    _scan_cache.ts   = 0
    _scan_cache.list = nil
end

-- ---------------------------------------------------------------------------
-- File scanning
-- ---------------------------------------------------------------------------

local _BOOK_EXTS = {
    epub = true, mobi = true, azw3 = true, azw = true, kfx = true,
    pdf = true, djvu = true, fb2 = true, cbz = true, cbr = true,
    doc = true, docx = true, rtf = true, txt = true,
}

-- Keep only the newest `cap` files while scanning to avoid storing
-- a huge full-library list in memory.
local function collectNewestBooks(dir, newest, cap)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "file" then
                    local ext = f:match("%.([^%.]+)$")
                    if ext and _BOOK_EXTS[ext:lower()] then
                        local rec = { path = path, mtime = attr.modification or 0 }
                        local n = #newest
                        if n < cap then
                            newest[n + 1] = rec
                        else
                            -- Replace the oldest record if this one is newer.
                            local min_i = 1
                            local min_m = newest[1].mtime
                            for i = 2, n do
                                local m = newest[i].mtime
                                if m < min_m then
                                    min_m = m
                                    min_i = i
                                end
                            end
                            if rec.mtime > min_m then
                                newest[min_i] = rec
                            end
                        end
                    end
                elseif attr.mode == "directory" then
                    collectNewestBooks(path, newest, cap)
                end
            end
        end
    end
end

local function copyFirst(list, limit)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i]
    end
    return out
end

-- Return up to `limit` file paths from home_dir, newest first by mtime.
local function scanNewBooks(limit)
    limit = limit or 5
    local home = G_reader_settings:readSetting("home_dir")
    if not home then return {} end

    local now = os.time()
    if _scan_cache.home == home and _scan_cache.list and (now - (_scan_cache.ts or 0) <= _SCAN_CACHE_TTL_S) then
        return copyFirst(_scan_cache.list, limit)
    end

    local cap = math.max(limit * 6, 40)
    local newest = {}
    collectNewestBooks(home, newest, cap)
    table.sort(newest, function(a, b) return a.mtime > b.mtime end)

    local list = {}
    for i = 1, #newest do
        list[i] = newest[i].path
    end
    _scan_cache.home = home
    _scan_cache.ts   = now
    _scan_cache.list = list
    return copyFirst(list, limit)
end

-- ---------------------------------------------------------------------------
-- build / getHeight
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("New Books"))
    -- Cache the scan result for the lifetime of this render cycle.
    local new_fps = ctx._new_books_fps
    if not new_fps then
        -- Fetch extra entries to compensate for books that will be excluded
        -- (current book, and books that are 100% read / marked complete).
        new_fps = scanNewBooks(10)
        -- Exclude the currently open book, matching the behaviour of the
        -- Recent Books module which also skips it.
        -- Also exclude books that are 100% read or marked complete,
        -- matching the filter applied by prefetchBooks() in module_books_shared.
        local DS_mod = nil
        pcall(function() DS_mod = require("docsettings") end)
        local filtered = {}
        for _, fp in ipairs(new_fps) do
            if fp ~= ctx.current_fp then
                local pct = 0
                local is_complete = false
                -- Try prefetched data first (no IO).
                local pre = ctx.prefetched and ctx.prefetched[fp]
                if pre and pre ~= false then
                    pct = pre.percent or 0
                    local summary = pre.summary
                    is_complete = type(summary) == "table" and summary.status == "complete"
                elseif DS_mod then
                    -- Fall back to reading DocSettings directly (same as prefetchBooks).
                    local ok, ds = pcall(DS_mod.open, DS_mod, fp)
                    if ok and ds then
                        pct = ds:readSetting("percent_finished") or 0
                        local summary = ds:readSetting("summary")
                        is_complete = type(summary) == "table" and summary.status == "complete"
                        pcall(function() ds:close() end)
                    end
                end
                if pct < 1.0 and not is_complete then
                    filtered[#filtered + 1] = fp
                end
            end
        end
        new_fps = filtered
        if #new_fps > 5 then
            local trimmed = {}
            for i = 1, 5 do trimmed[i] = new_fps[i] end
            new_fps = trimmed
        end
        ctx._new_books_fps = new_fps
    end
    if #new_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("new_books", ctx.pfx)
    local thumb_scale = Config.getThumbScale("new_books", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("new_books", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)
    local label_fs    = math.max(8, math.floor(_BASE_NB_LABEL_FS * scale * lbl_scale))

    local cols    = math.min(#new_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    local shadow_extra = math.max(1, Screen:scaleBySize(2))
    local cell_h  = D.RECENT_CELL_H + shadow_extra
    -- Space-between across 5 fixed slots, same lateral padding as other modules.
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)
    local face    = Font:getFace("smallinfofont", label_fs)

    local row = HorizontalGroup:new{ align = "top" }
    local cover_slots = {}
    for i = 1, cols do
        local fp    = new_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local raw_cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)
        local cover = SH.wrapWithShadow(raw_cover, cw, ch) or raw_cover

        -- "New" for unread books, read percentage otherwise.
        local label_text
        if (bd.percent or 0) < 0.01 then
            label_text = _("New")
        else
            label_text = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5))
        end

        local cell = VerticalGroup:new{
            align = "center",
            cover,
            SH.vspan(D.RB_GAP1, ctx.vspan_pool),
            SH.progressBar(cw, bd.percent, D.RB_BAR_H),
            SH.vspan(D.RB_GAP2, ctx.vspan_pool),
            TextWidget:new{
                text      = label_text,
                face      = face,
                bold      = true,
                fgcolor   = CLR_TEXT_SUB,
                width     = cw,
                height    = D.RB_LABEL_H,
                alignment = "center",
            },
        }

        -- When shadow wrapping succeeds, raw cover is at shadow_group[2].
        local shadow_group = cell[1]
        if shadow_group and shadow_group[2] then
            cover_slots[#cover_slots+1] = { container = shadow_group, idx = 2, fp = fp, w = cw, h = ch, align = nil, stretch = 0 }
        else
            cover_slots[#cover_slots+1] = { container = cell, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0 }
        end

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = cell_h },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = tappable
    end

    local result = FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
    result._cover_slots = cover_slots
    return result
end

function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

function M.getHeight(_ctx)
    local SH = getSH()
    local D  = SH.getDims(Config.getModuleScale("new_books", _ctx and _ctx.pfx),
                           Config.getThumbScale("new_books", _ctx and _ctx.pfx))
    local shadow_extra = math.max(1, Screen:scaleBySize(2))
    return require("sui_config").getScaledLabelH() + D.RECENT_CELL_H + shadow_extra
end

-- ---------------------------------------------------------------------------
-- Settings menu items (Scale, Text Size, Cover Size)
-- ---------------------------------------------------------------------------

local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("new_books", pfx) end,
        set          = function(v) Config.setModuleScale(v, "new_books", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("new_books", pfx) end,
        set       = function(v) Config.setThumbScale(v, "new_books", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local _lc = ctx_menu._
    local label_item = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the label text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("new_books", ctx_menu.pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "new_books", ctx_menu.pfx) end,
        refresh   = ctx_menu.refresh,
    })
    return { _makeScaleItem(ctx_menu), label_item, Config.makeLabelToggleItem("new_books", _("New Books"), ctx_menu.refresh, _lc), _makeThumbScaleItem(ctx_menu) }
end

return M
