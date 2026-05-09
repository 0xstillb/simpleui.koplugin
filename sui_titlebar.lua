-- sui_titlebar.lua — Simple UI
-- Title-bar customisations for the FileManager (FM) and injected fullscreen
-- widgets (Collections, History, …).
--
-- FM context:   apply(fm_self)  /  restore(fm_self)  /  reapply(fm_self)
-- Injected:     applyToInjected(w)  /  restoreInjected(w)
-- Both:         reapplyAll(fm, stack)

local _ = require("sui_i18n").translate
local Config = require("sui_config")

-- Lua 5.1 / LuaJIT compat: table.unpack was added in 5.2.
local _unpack = table.unpack or unpack

-- Plugin directory resolved once at load time (used for browse-mode icon paths).
local _PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"

-- Full paths for the four browse-mode icons.
local _BROWSE_ICONS = {
    normal = _PLUGIN_DIR .. "icons/default.svg",
    author = _PLUGIN_DIR .. "icons/author.svg",
    series = _PLUGIN_DIR .. "icons/series.svg",
    tags   = _PLUGIN_DIR .. "icons/tags.svg",
}

local M = {}

-- ---------------------------------------------------------------------------
-- Improvement #4 — module-level lazy loader for sui_browsemeta.
-- Avoids repeated pcall(require, ...) inside hot paths (genItemTable wrapper,
-- onFolderUp, browse button callback). false means "tried and not available".
-- ---------------------------------------------------------------------------

local _BM_cache  -- nil = not yet tried; false = unavailable; table = module
local function _BrowseMeta()
    if _BM_cache == nil then
        local ok, m = pcall(require, "sui_browsemeta")
        _BM_cache = (ok and m) or false
    end
    return _BM_cache or nil
end

-- Invalidate the cache so that reapplyAll picks up a newly-enabled BrowseMeta.
-- Called by reapply() before re-running apply().
local function _resetBMCache()
    _BM_cache = nil
end

-- ---------------------------------------------------------------------------
-- Settings keys and defaults
-- ---------------------------------------------------------------------------

local SETTING_KEY = "simpleui_titlebar_custom"
local FM_CFG_KEY  = "simpleui_tb_fm_cfg"
local INJ_CFG_KEY = "simpleui_tb_inj_cfg"
local SIZE_KEY    = "simpleui_tb_size"

local _SIZE_SCALE = { compact = 0.75, default = 1.0, large = 1.3 }

local _VIS_DEFAULTS = {
    menu_button   = true,
    up_button     = true,
    title         = true,
    search_button = true,
    browse_button = false,
    inj_back      = true,
    inj_right     = false,
}

-- Default side/order configs for FM and injected widgets.
local _FM_DEFAULTS = {
    side        = { menu_button = "right", up_button = "left", search_button = "left", browse_button = "right" },
    order_left  = { "up_button", "search_button" },
    order_right = { "browse_button", "menu_button" },
}
local _INJ_DEFAULTS = {
    side        = { inj_back = "left", inj_right = "right" },
    order_left  = { "inj_back" },
    order_right = { "inj_right" },
}

-- ---------------------------------------------------------------------------
-- Item catalogue (used by the Arrange Buttons menu)
-- ---------------------------------------------------------------------------

M.ITEMS = {
    { id = "menu_button",   label = function() return _("Menu")   end, ctx = "fm"  },
    { id = "up_button",     label = function() return _("Back")   end, ctx = "fm"  },
    { id = "search_button", label = function() return _("Search") end, ctx = "fm"  },
    { id = "browse_button", label = function() return _("Browse") end, ctx = "fm"  },
    { id = "title",         label = function() return _("Title")  end, ctx = "fm",  no_side = true },
    { id = "inj_back",      label = function() return _("Menu")   end, ctx = "inj" },
    { id = "inj_right",     label = function() return _("Close")  end, ctx = "inj" },
}

-- ---------------------------------------------------------------------------
-- Public settings accessors
-- ---------------------------------------------------------------------------

function M.isEnabled()   return G_reader_settings:nilOrTrue(SETTING_KEY) end
function M.setEnabled(v) G_reader_settings:saveSetting(SETTING_KEY, v)   end

local function _visKey(id) return "simpleui_tb_item_" .. id end

function M.isItemVisible(id)
    local v = G_reader_settings:readSetting(_visKey(id))
    if v == nil then return _VIS_DEFAULTS[id] ~= false end
    return v == true
end
function M.setItemVisible(id, v) G_reader_settings:saveSetting(_visKey(id), v) end

function M.getSizeKey()   return G_reader_settings:readSetting(SIZE_KEY) or "default" end
function M.setSizeKey(v)  G_reader_settings:saveSetting(SIZE_KEY, v) end
function M.getSizeScale() return _SIZE_SCALE[M.getSizeKey()] or 1.0 end

-- ---------------------------------------------------------------------------
-- Config load/save (side assignments + button order)
-- ---------------------------------------------------------------------------

-- Merges saved config onto defaults. Any default items absent from the saved
-- order lists are appended, so newly-added buttons always appear in Arrange.
local function _loadCfg(key, defaults)
    local raw = G_reader_settings:readSetting(key)
    if type(raw) ~= "table" then
        local side = {}
        for k, v in pairs(defaults.side) do side[k] = v end
        return {
            side        = side,
            order_left  = { _unpack(defaults.order_left) },
            order_right = { _unpack(defaults.order_right) },
        }
    end
    local side = {}
    for k, v in pairs(defaults.side) do side[k] = v end
    if type(raw.side) == "table" then
        for k, v in pairs(raw.side) do side[k] = v end
    end
    local order_left  = (type(raw.order_left)  == "table") and raw.order_left  or defaults.order_left
    local order_right = (type(raw.order_right) == "table") and raw.order_right or defaults.order_right
    -- Append default items absent from both saved order lists.
    local in_saved = {}
    for _, id in ipairs(order_left)  do in_saved[id] = true end
    for _, id in ipairs(order_right) do in_saved[id] = true end
    for _, id in ipairs(defaults.order_right) do
        if not in_saved[id] then
            order_right[#order_right + 1] = id
            if not side[id] then side[id] = defaults.side[id] or "right" end
        end
    end
    for _, id in ipairs(defaults.order_left) do
        if not in_saved[id] then
            order_left[#order_left + 1] = id
            if not side[id] then side[id] = defaults.side[id] or "left" end
        end
    end
    return { side = side, order_left = order_left, order_right = order_right }
end

function M.getFMConfig()      return _loadCfg(FM_CFG_KEY,  _FM_DEFAULTS)  end
function M.getInjConfig()     return _loadCfg(INJ_CFG_KEY, _INJ_DEFAULTS) end
function M.saveFMConfig(cfg)  G_reader_settings:saveSetting(FM_CFG_KEY,  cfg) end
function M.saveInjConfig(cfg) G_reader_settings:saveSetting(INJ_CFG_KEY, cfg) end

-- ---------------------------------------------------------------------------
-- Internal layout helpers
-- ---------------------------------------------------------------------------

-- Returns true if the item represents the "go up" row.
local function _isGoUpItem(item)
    return item.is_go_up or (item.text and item.text:find("\u{2B06}"))
end

-- ---------------------------------------------------------------------------
-- Path-based navigation helpers
-- ---------------------------------------------------------------------------
--
-- _normPath: resolves symlinks (Android /sdcard → /storage/emulated/0) and
-- strips trailing slashes so all comparisons are consistent.  Falls back
-- gracefully when realpath is unavailable or the path does not exist.
local function _normPath(path)
    if not path then return nil end
    local ffiUtil = require("ffi/util")
    local ok, resolved = pcall(ffiUtil.realpath, path)
    return (ok and resolved or path):gsub("/$", "")
end

-- _normHome: cached normalised home_dir.  Re-read each call — the user may
-- change home_dir in settings between navigations.
local function _normHome()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then return nil end
    return _normPath(home)
end

-- _isAtFSRoot: true when path is the effective navigation root.
-- With lock ON the root is home_dir; with lock OFF it is "/".
local function _isAtFSRoot(path)
    local p = _normPath(path)
    if not p or p == "" or p == "/" then return true end
    if G_reader_settings:isTrue("lock_home_folder") then
        local h = _normHome()
        return h ~= nil and p == h
    end
    return false
end

-- _isSubFolder: true when the back button should be shown at `path`.
--
-- Virtual BrowseMeta paths (Authors / Series / Tags):
--   root     — the entry point before choosing a dimension: hide.
--   dim_list — the list of all authors / series / tags: hide.
--              This is the virtual equivalent of the home root.
--   file_list — the books inside one author / series / tag: show.
--              This is the virtual equivalent of a subfolder.
--   (BrowseMeta not active → path treated as normal filesystem path)
--
-- Normal filesystem paths depend on lock_home_folder:
--   lock OFF: root of navigation is "/". Show everywhere except "/".
--   lock ON:  root of navigation is home_dir. Show only when strictly
--             below home_dir; hide at home_dir and outside home.
--
-- Uses realpath so Android /sdcard symlinks normalise consistently.
-- DOES NOT handle series-view (path unchanged from parent) — caller checks
-- fc.item_table._sg_is_series_view separately.
local function _isSubFolder(path)
    if not path then return false end
    local p = _normPath(path)
    if not p or p == "" or p == "/" then return false end

    -- Virtual path: delegate entirely to BrowseMeta's level classification.
    local BM = _BrowseMeta()
    if BM then
        local ok, level = pcall(BM.getPathLevel, path)
        if ok and level then
            -- file_list = inside a specific author/series/tag → show.
            -- root / dim_list = top of the virtual tree → hide.
            return level == "file_list"
        end
        -- getPathLevel returned nil → path is not virtual; fall through.
    end

    -- Normal filesystem path.
    if G_reader_settings:isTrue("lock_home_folder") then
        -- Locked: only show when strictly inside home_dir.
        local h = _normHome()
        if not h then return false end              -- no home set → hide
        if p == h then return false end             -- at home root → hide
        return p:sub(1, #h + 1) == h .. "/"        -- strictly below home → show
    else
        -- Unlocked: any path other than "/" has a parent to go back to.
        return true
    end
end

-- _isAtRoot: backwards-compat wrapper used by early-hide and browse-button.
local function _isAtRoot(fc)
    if not fc then return true end
    -- Series view always has a parent even if the path is the home root.
    if fc.item_table and fc.item_table._sg_is_series_view then return false end
    return not _isSubFolder(fc.path)
end

-- Keep _isLockedAtHome for any callers outside this file that may require it,
-- but internally we now use _isAtFSRoot / _isSubFolder.
local function _isLockedAtHome(path)
    return _isAtFSRoot(path) and
           G_reader_settings:isTrue("lock_home_folder") and
           _normPath(path) == _normHome()
end

-- Pixel x-position for a button at slot (0-based) on a given side.
local function _buttonX(side, slot, btn_w, pad, gap, sw)
    if side == "left" then
        return pad + slot * (btn_w + gap)
    else
        return sw - btn_w - pad - slot * (btn_w + gap)
    end
end

-- Builds id -> { side, slot } map from ordered lists and a visible-ids set.
-- order_right[1] maps to the rightmost screen position (highest slot index).
local function _buildSlotMap(order_left, order_right, visible_ids)
    local slots   = {}
    local count_l = 0
    for _, id in ipairs(order_left) do
        if visible_ids[id] then
            slots[id] = { side = "left", slot = count_l }
            count_l   = count_l + 1
        end
    end
    local right_vis = {}
    for _, id in ipairs(order_right) do
        if visible_ids[id] then right_vis[#right_vis + 1] = id end
    end
    local n = #right_vis
    for i, id in ipairs(right_vis) do
        slots[id] = { side = "right", slot = n - i }
    end
    return slots
end

-- Reloads an ImageWidget after its .file field has been changed.
local function _reloadImage(img)
    pcall(img.free, img)
    pcall(img.init, img)
end

-- Resizes btn to new_w x new_w and zeroes left/right/bottom paddings.
-- Pass keep_top_pad=true to preserve padding_top (needed for injected buttons).
local function _resizeAndStrip(btn, new_w, keep_top_pad)
    btn.width  = new_w
    btn.height = new_w
    if btn.image then
        btn.image.width  = new_w
        btn.image.height = new_w
        _reloadImage(btn.image)
    end
    btn.padding_left   = 0
    btn.padding_right  = 0
    btn.padding_bottom = 0
    if not keep_top_pad then btn.padding_top = 0 end
    btn:update()
end

-- Snapshots a button's current geometry and optional state into a plain table.
local function _snapBtn(btn, opts)
    local snap = {
        align   = btn.overlap_align,
        offset  = btn.overlap_offset,
        pad_l   = btn.padding_left,
        pad_r   = btn.padding_right,
        pad_bot = btn.padding_bottom,
        w       = btn.width,
        h       = btn.height,
    }
    if opts then
        if opts.save_icon     then snap.icon     = btn.image and btn.image.file end
        if opts.save_callback then
            snap.callback = btn.callback
            snap.hold_cb  = btn.hold_callback
        end
        if opts.save_dimen then snap.dimen = btn.dimen end
    end
    return snap
end

-- Restores a button from a snapshot produced by _snapBtn.
local function _restoreBtn(btn, snap)
    if not snap then return end
    if snap.icon and btn.image then
        btn.image.file = snap.icon
        _reloadImage(btn.image)
    end
    btn.overlap_align  = snap.align
    btn.overlap_offset = snap.offset
    btn.padding_left   = snap.pad_l
    btn.padding_right  = snap.pad_r
    btn.padding_bottom = snap.pad_bot
    if snap.w ~= nil then
        btn.width  = snap.w
        btn.height = snap.h
        if btn.image then
            btn.image.width  = snap.w
            btn.image.height = snap.h
            _reloadImage(btn.image)
        end
    end
    pcall(btn.update, btn)
    if snap.callback ~= nil then btn.callback      = snap.callback end
    if snap.hold_cb  ~= nil then btn.hold_callback = snap.hold_cb  end
    if snap.dimen    ~= nil then btn.dimen         = snap.dimen    end
end

-- Reads layout geometry from a TitleBar instance (called once per apply).
local function _layoutParams(tb)
    local Screen  = require("device").screen
    local scale   = M.getSizeScale()
    local base_iw = Screen:scaleBySize(36)
    pcall(function()
        local sz = (tb.right_button and tb.right_button.image and tb.right_button.image:getSize())
               or  (tb.left_button  and tb.left_button.image  and tb.left_button.image:getSize())
        if sz and sz.w and sz.w > 0 then base_iw = sz.w end
    end)
    return {
        iw  = math.floor(base_iw * scale),
        pad = Screen:scaleBySize(18),
        gap = Screen:scaleBySize(18),
        sw  = Screen:getWidth(),
    }
end

-- ---------------------------------------------------------------------------
-- _resolveIsSub: single authoritative is_sub resolver.
-- Replaces the go-up item scan with a path-based approach (Zen UI style),
-- adapted to handle SimpleUI's virtual folder and series-view cases:
--
--   1. Series view (_sg_is_series_view): the path does NOT change when the
--      user drills into a series group — fc.path stays the parent's path.
--      We check the flag first because _isSubFolder would return false for a
--      series opened from the home root, hiding the back button incorrectly.
--
--   2. BrowseMeta virtual paths: the VROOT marker (U+E257) sits after the
--      base_dir segment, so _isSubFolder's prefix test against home_dir still
--      works correctly without special-casing.
--
--   3. Normal filesystem: _isSubFolder compares realpath-normalised strings,
--      handling Android /sdcard symlinks consistently.
--
-- The cached _simpleui_has_go_up flag is kept for the early-hide path in
-- apply() (before the first genItemTable fires), but is no longer the primary
-- source of truth here.
-- ---------------------------------------------------------------------------
local function _resolveIsSub(fc_self)
    -- Series view: path is unchanged from parent, so path comparison is blind.
    -- The flag is set by sui_foldercovers when it calls switchItemTable.
    if fc_self.item_table and fc_self.item_table._sg_is_series_view then
        return true
    end
    -- Path-based test: handles normal folders, locked-home, and virtual paths.
    return _isSubFolder(fc_self.path)
end

-- ---------------------------------------------------------------------------
-- Improvement #6 — _hideOffset: defensive off-screen x value.
-- Uses 2× screen width instead of a fixed +100px so the button stays
-- invisible even after orientation changes before the next reapply.
-- ---------------------------------------------------------------------------
local function _hideOffset(sw)
    return sw * 2
end

-- ---------------------------------------------------------------------------
-- FM titlebar — apply
-- ---------------------------------------------------------------------------

function M.apply(fm_self)
    if not M.isEnabled() then return end
    local tb = fm_self.title_bar
    if not tb then return end
    if fm_self._titlebar_patched then return end
    fm_self._titlebar_patched = true

    local UIManager = require("ui/uimanager")
    local lp        = _layoutParams(tb)
    local iw, pad, gap, sw = lp.iw, lp.pad, lp.gap, lp.sw

    -- Read all visibility settings once.
    local show_menu   = M.isItemVisible("menu_button")
    local show_up     = M.isItemVisible("up_button")
    local show_search = M.isItemVisible("search_button")
    local show_browse = M.isItemVisible("browse_button") and (function()
        -- Improvement #4: use cached _BrowseMeta() instead of inline pcall.
        local BM = _BrowseMeta()
        return BM and BM.isEnabled()
    end)()
    local show_title  = M.isItemVisible("title")

    local cfg     = M.getFMConfig()
    local visible = {}
    if show_menu   then visible["menu_button"]   = true end
    if show_up     then visible["up_button"]     = true end
    if show_search then visible["search_button"] = true end
    if show_browse then visible["browse_button"] = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    -- Resizes, strips paddings and positions a button according to its slot.
    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

    -- Right button (menu) ----------------------------------------------------

    if tb.right_button then
        local rb = tb.right_button
        fm_self._titlebar_rb = _snapBtn(rb, { save_icon = true, save_callback = true })

        -- Patch setRightIcon so our custom icon survives folder navigation.
        local _icon_enabled     = show_menu
        local orig_setRightIcon = tb.setRightIcon
        fm_self._titlebar_orig_setRightIcon = orig_setRightIcon
        tb.setRightIcon = function(tb_self, icon, ...)
            local result = orig_setRightIcon(tb_self, icon, ...)
            if icon == "plus" and _icon_enabled then
                if tb_self.right_button and tb_self.right_button.image then
                    tb_self.right_button.image.file = Config.ICON.ko_menu
                    _reloadImage(tb_self.right_button.image)
                end
                UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
            end
            return result
        end

        if show_menu then
            if rb.image then
                rb.image.file = Config.ICON.ko_menu
                _reloadImage(rb.image)
            end
            placeBtn("menu_button", rb)
        else
            rb.overlap_align  = nil
            -- Improvement #6: use defensive 2× width offset.
            rb.overlap_offset = { _hideOffset(sw), 0 }
            rb.callback       = function() end
            rb.hold_callback  = function() end
        end
    end

    -- Left button (back/up) --------------------------------------------------

    if tb.left_button then
        local lb = tb.left_button
        fm_self._titlebar_lb = _snapBtn(lb, { save_callback = true })

        if show_up then
            placeBtn("up_button", lb)

            -- Hide back button immediately if already at root before the first
            -- genItemTable fires, to avoid a brief flash of the button.
            if _isAtRoot(fm_self.file_chooser) then
                -- Improvement #6: use defensive 2× width offset.
                lb.overlap_offset = { _hideOffset(sw), 0 }
                lb.callback       = function() end
                lb.hold_callback  = function() end
            end

            local fc = fm_self.file_chooser
            if fc then
                -- Resolve bidi chevron direction once.
                local ICON_UP = "chevron.left"
                pcall(function()
                    local BD = require("ui/bidi")
                    ICON_UP = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
                end)

                -- Improvement #7 — _leftSideBtns built once after apply() sets
                -- _titlebar_search_btn / _titlebar_browse_btn, then cached.
                -- Rebuilt only on reapply() (which calls restore() + apply() fresh).
                -- The comment in the original noted "rebuilt each call because
                -- search_btn/browse_btn are assigned later"; we solve this by
                -- deferring construction to the first _applyBackButtonState call,
                -- at which point both injected buttons have been assigned.
                local _left_btns_cache = nil
                local function _leftSideBtns()
                    if _left_btns_cache then return _left_btns_cache end
                    local list = {}
                    for _, id in ipairs(cfg.order_left) do
                        if id ~= "up_button" and slot_map[id] and slot_map[id].side == "left" then
                            local widget
                            if id == "search_button" then
                                widget = fm_self._titlebar_search_btn
                            elseif id == "browse_button" then
                                widget = fm_self._titlebar_browse_btn
                            end
                            if widget then
                                list[#list + 1] = { btn = widget, slot = slot_map[id].slot }
                            end
                        end
                    end
                    _left_btns_cache = list
                    return list
                end

                local up_slot = slot_map["up_button"].slot
                fm_self._simpleui_up_x = _buttonX("left", up_slot, iw, pad, gap, sw)

                -- Single authoritative function for back-button visibility and action.
                -- root+page1: hide; root+page>1: paginate; subfolder: folder-up.
                -- `page` is always passed explicitly to avoid stale cur_page reads.
                local function _applyBackButtonState(fc_self, is_sub, page)
                    local tb2 = fm_self.title_bar
                    if not (tb2 and tb2.left_button) then return end
                    local btn       = tb2.left_button
                    local neighbors = _leftSideBtns()

                    if not is_sub and page <= 1 then
                        -- Hide back button and compact neighbors left.
                        -- Improvement #6: use defensive 2× width offset.
                        btn.overlap_offset = { _hideOffset(sw), 0 }
                        btn.callback       = function() end
                        btn.hold_callback  = function() end
                        for _, entry in ipairs(neighbors) do
                            local dslot = entry.slot > up_slot and entry.slot - 1 or entry.slot
                            entry.btn.overlap_offset = { _buttonX("left", dslot, iw, pad, gap, sw), 0 }
                        end
                    else
                        -- Show back button and restore neighbor positions.
                        btn:setIcon(ICON_UP)
                        btn.overlap_offset = { _buttonX("left", up_slot, iw, pad, gap, sw), 0 }
                        for _, entry in ipairs(neighbors) do
                            entry.btn.overlap_offset = { _buttonX("left", entry.slot, iw, pad, gap, sw), 0 }
                        end
                        if page > 1 then
                            -- Paginated list: tap goes back one page, hold goes to page 1.
                            btn.callback      = function() fc_self:onGotoPage(page - 1) end
                            btn.hold_callback = function() fc_self:onGotoPage(1) end
                        else
                            -- Subfolder page 1: tap goes to parent, hold is no-op.
                            btn.callback      = function() fc_self:onFolderUp() end
                            btn.hold_callback = function() end
                        end
                    end
                    UIManager:setDirty(tb2.show_parent or fm_self, "ui", tb2.dimen)
                end

                -- ---------------------------------------------------------------------------
                -- Improvement #2 — single genItemTable wrapper with a listener registry.
                -- Instead of wrapping fc.genItemTable twice (once here for the back button,
                -- once below for the browse icon), we install one wrapper that calls all
                -- registered listeners after the original. Each feature registers its own
                -- listener via fc._simpleui_gen_listeners. restore() clears the list and
                -- restores the original, avoiding listener-chain fragility.
                -- ---------------------------------------------------------------------------
                fm_self._titlebar_orig_fc_genItemTable = fc.genItemTable
                fc._simpleui_gen_listeners = {}

                local orig_genItemTable = fc.genItemTable
                fc.genItemTable = function(fc_self, dirs, files, path)
                    local item_table = orig_genItemTable(fc_self, dirs, files, path)
                    if not item_table then return item_table end

                    -- Strip the go-up row from the list (we own the back button now).
                    -- is_sub is determined by path, not by the presence of this item.
                    local filtered = {}
                    for _, item in ipairs(item_table) do
                        if not _isGoUpItem(item) then
                            filtered[#filtered + 1] = item
                        end
                    end

                    -- Path-based is_sub: use the path argument when available (it
                    -- reflects the destination of the current genItemTable call),
                    -- falling back to fc_self.path for the initial load.
                    local effective_path = path or fc_self.path
                    local is_sub = _isSubFolder(effective_path)
                    -- Series view overrides path-based result (path unchanged from parent).
                    if fc_self.item_table and fc_self.item_table._sg_is_series_view then
                        is_sub = true
                    end
                    fc_self._simpleui_has_go_up = is_sub
                    _applyBackButtonState(fc_self, is_sub, 1)

                    -- Notify all other registered listeners (e.g. browse icon refresh).
                    for _, listener in ipairs(fc_self._simpleui_gen_listeners or {}) do
                        pcall(listener, fc_self)
                    end

                    return filtered
                end

                -- KOReader called genItemTable before our patch was installed on the
                -- first FM open. Strip the go-up entry retroactively so the initial
                -- render matches subsequent navigations.
                local it = fc.item_table
                if it then
                    local cleaned     = {}
                    local found_go_up = false
                    for _, item in ipairs(it) do
                        if _isGoUpItem(item) then
                            found_go_up = true
                        else
                            cleaned[#cleaned + 1] = item
                        end
                    end
                    if found_go_up then
                        for i = #it, 1, -1 do it[i] = nil end
                        for i, v in ipairs(cleaned) do it[i] = v end
                        UIManager:nextTick(function()
                            if fc and fc.updateItems then
                                pcall(fc.updateItems, fc, 1, true)
                            end
                        end)
                    end
                end

                -- onFolderUp re-evaluates back-button state after navigation.
                -- FileChooser.onFolderUp is resolved at call time (not captured as an
                -- upvalue) because sui_foldercovers may swap the class method at runtime.
                --
                -- Improvement #8 — save the previous instance value of onFolderUp
                -- (which may be nil or a value set by another plugin) so restore()
                -- can reinstate it exactly, rather than blindly nil-ing the slot.
                local FileChooser_cls = require("ui/widget/filechooser")
                fm_self._titlebar_orig_fc_onFolderUp = fc.onFolderUp  -- may be nil
                fc.onFolderUp = function(fc_self, ...)
                    -- At the dim_list level of a virtual browse tree, exit to normal FS.
                    -- Improvement #4: use cached _BrowseMeta().
                    local BM = _BrowseMeta()
                    if BM and BM.exitToNormal then
                        local path = fc_self.path or ""
                        if path:find("/", 1, true) then
                            local ok_pl, level = pcall(BM.getPathLevel, path)
                            if ok_pl and level == "dim_list" then
                                BM.exitToNormal(fc_self, fm_self)
                                -- Improvement #1: use _resolveIsSub instead of inline duplicate.
                                local is_sub_after = _resolveIsSub(fc_self)
                                fc_self._simpleui_has_go_up = is_sub_after
                                _applyBackButtonState(fc_self, is_sub_after, 1)
                                return true
                            end
                        end
                    end
                    -- Delegate to the current class method (resolved at call time).
                    local current = FileChooser_cls.onFolderUp
                    local ok, result = pcall(current, fc_self, ...)
                    -- Improvement #1: use _resolveIsSub instead of inline duplicate.
                    -- Note: _resolveIsSub prefers the cached flag set by genItemTable.
                    local is_sub = _resolveIsSub(fc_self)
                    fc_self._simpleui_has_go_up = is_sub
                    _applyBackButtonState(fc_self, is_sub, 1)
                    if not ok then error(result) end
                    return result
                end

                -- onGotoPage updates back-button state on every CoverBrowser page turn.
                -- Re-entrancy guard prevents KOReader's internal recursive calls from
                -- overwriting the state set for the outer call.
                local orig_onGotoPage = fc.onGotoPage
                if orig_onGotoPage then
                    fm_self._titlebar_orig_fc_onGotoPage = orig_onGotoPage
                    fc.onGotoPage = function(fc_self, page, ...)
                        if fc_self._simpleui_in_goto then
                            return orig_onGotoPage(fc_self, page, ...)
                        end
                        fc_self._simpleui_in_goto = true
                        local ok, result = pcall(orig_onGotoPage, fc_self, page, ...)
                        -- Clear re-entrancy guard BEFORE any error() so a failure
                        -- inside orig_onGotoPage never leaves the flag stuck at true.
                        fc_self._simpleui_in_goto = nil

                        -- _resolveIsSub now handles both the series-view flag and the
                        -- path-based test, so no inline special case is needed here.
                        local is_sub = _resolveIsSub(fc_self)
                        fc_self._simpleui_has_go_up = is_sub
                        _applyBackButtonState(fc_self, is_sub, page)
                        if not ok then error(result) end
                        return result
                    end
                end
            end
        else
            lb.overlap_align  = nil
            -- Improvement #6: use defensive 2× width offset.
            lb.overlap_offset = { _hideOffset(sw), 0 }
            lb.callback       = function() end
            lb.hold_callback  = function() end
        end
    end

    -- Search button ----------------------------------------------------------
    -- Injected directly into the TitleBar OverlapGroup.
    -- All paddings (including top) are zeroed to align with the other buttons.

    if show_search then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["search_button"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)
                local search_btn = IconButton:new{
                    icon        = "appbar.search",
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback = function()
                        local fs = fm_self.filesearcher
                        if fs and fs.onShowFileSearch then fs:onShowFileSearch() end
                    end,
                }
                _resizeAndStrip(search_btn, iw)
                search_btn.overlap_align  = nil
                search_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, search_btn)
                fm_self._titlebar_search_btn = search_btn
                fm_self._simpleui_search_x   = _buttonX(s.side, s.slot, iw, pad, gap, sw)

                -- Improvement #3 — compute compact slot once, reuse for both
                -- the cached value and the immediate-at-root initial adjustment.
                if s.side == "left" then
                    local up_slot2  = slot_map["up_button"] and slot_map["up_button"].slot or 0
                    local dslot     = s.slot > up_slot2 and s.slot - 1 or s.slot
                    local compact_x = _buttonX("left", dslot, iw, pad, gap, sw)
                    fm_self._simpleui_search_x_compact = compact_x
                    -- If already at root on first apply, shift to compact position now.
                    if show_up and _isAtRoot(fm_self.file_chooser) then
                        search_btn.overlap_offset = { compact_x, 0 }
                    end
                end
            end
        end
    end

    -- Browse button ----------------------------------------------------------
    -- Injected like search_button. Icon reflects the current browse mode and
    -- is refreshed on every genItemTable call via the listener registry
    -- (Improvement #2) instead of a second genItemTable wrapper.

    if show_browse then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["browse_button"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)

                -- Resolve initial icon from the current browse mode.
                -- Improvement #4: use cached _BrowseMeta().
                local _initial_icon = _BROWSE_ICONS.normal
                local BM0 = _BrowseMeta()
                if BM0 then
                    local fc0  = fm_self.file_chooser
                    local mode = fc0 and BM0.getCurrentMode(fc0) or "normal"
                    _initial_icon = _BROWSE_ICONS[mode] or _BROWSE_ICONS.normal
                end

                local browse_btn
                browse_btn = IconButton:new{
                    icon        = _initial_icon,
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback = function()
                        -- Improvement #4: use cached _BrowseMeta().
                        local BM = _BrowseMeta()
                        if not BM then return end
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local fc_ref       = fm_self.file_chooser
                        local cur_mode     = fc_ref and BM.getCurrentMode(fc_ref) or "normal"
                        local function _check(mode)
                            return cur_mode == mode and "\u{2713} " or "  "
                        end
                        -- Closes dialog, navigates to mode, and refreshes the icon.
                        local function _navigate(dlg, mode)
                            UIManager:close(dlg)
                            BM.navigateTo(fm_self, mode)
                            if browse_btn.image then
                                browse_btn.image.file = _BROWSE_ICONS[mode] or _BROWSE_ICONS.normal
                                _reloadImage(browse_btn.image)
                                UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
                            end
                        end
                        local dlg
                        dlg = ButtonDialog:new{
                            title       = _("Browse library"),
                            title_align = "center",
                            buttons = {
                                {{ text = _check("normal") .. _("Default"),   callback = function() _navigate(dlg, "normal") end }},
                                {{ text = _check("author") .. _("By author"), callback = function() _navigate(dlg, "author") end }},
                                {{ text = _check("series") .. _("By series"), callback = function() _navigate(dlg, "series") end }},
                                {{ text = _check("tags")   .. _("By tags"),   callback = function() _navigate(dlg, "tags")   end }},
                                {{ text = _("Cancel"),                         callback = function() UIManager:close(dlg)     end }},
                            },
                        }
                        UIManager:show(dlg)
                    end,
                }

                _resizeAndStrip(browse_btn, iw)
                -- Re-apply the initial icon after update() in case IconButton:new
                -- rendered a stale fallback during :init().
                if browse_btn.image then
                    browse_btn.image.file = _initial_icon
                    _reloadImage(browse_btn.image)
                end
                browse_btn.overlap_align  = nil
                browse_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, browse_btn)
                fm_self._titlebar_browse_btn = browse_btn

                -- Improvement #3 — compute compact slot once, reuse for both
                -- the cached value and the immediate-at-root initial adjustment.
                if s.side == "left" then
                    local up_slot_b = slot_map["up_button"] and slot_map["up_button"].slot or 0
                    local dslot_b   = s.slot > up_slot_b and s.slot - 1 or s.slot
                    local compact_x_b = _buttonX("left", dslot_b, iw, pad, gap, sw)
                    fm_self._simpleui_browse_x_compact = compact_x_b
                    -- If already at root on first apply, shift to compact position now.
                    if show_up and _isAtRoot(fm_self.file_chooser) then
                        browse_btn.overlap_offset = { compact_x_b, 0 }
                    end
                end

                -- Improvement #2 — register browse-icon refresh as a listener on the
                -- shared genItemTable wrapper instead of wrapping genItemTable again.
                local fc_b = fm_self.file_chooser
                if fc_b and fc_b._simpleui_gen_listeners then
                    fc_b._simpleui_gen_listeners[#fc_b._simpleui_gen_listeners + 1] = function(fc_self)
                        -- Improvement #4: use cached _BrowseMeta().
                        local BM2 = _BrowseMeta()
                        if BM2 and browse_btn.image then
                            local mode2 = BM2.getCurrentMode(fc_self)
                            local icon2 = _BROWSE_ICONS[mode2] or _BROWSE_ICONS.normal
                            if browse_btn.image.file ~= icon2 then
                                browse_btn.image.file = icon2
                                _reloadImage(browse_btn.image)
                                UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
                            end
                        end
                    end
                    fm_self._titlebar_browse_gen_hooked = true
                end
            end
        end
    end

    -- Title ------------------------------------------------------------------

    if tb.setTitle then
        fm_self._titlebar_orig_title_set = true
        tb:setTitle(show_title and _("Library") or "")
    end
end

-- ---------------------------------------------------------------------------
-- FM titlebar — restore / reapply
-- ---------------------------------------------------------------------------

function M.restore(fm_self)
    local tb = fm_self.title_bar
    if not tb then return end
    if not fm_self._titlebar_patched then return end

    -- Restore the setRightIcon patch.
    if fm_self._titlebar_orig_setRightIcon then
        tb.setRightIcon = fm_self._titlebar_orig_setRightIcon
        fm_self._titlebar_orig_setRightIcon = nil
    end

    -- Restore left and right buttons.
    if tb.right_button then _restoreBtn(tb.right_button, fm_self._titlebar_rb) end
    fm_self._titlebar_rb = nil
    if tb.left_button  then _restoreBtn(tb.left_button,  fm_self._titlebar_lb) end
    fm_self._titlebar_lb = nil

    -- Remove injected search and browse buttons from the TitleBar OverlapGroup.
    for _, key in ipairs({ "_titlebar_search_btn", "_titlebar_browse_btn" }) do
        local btn = fm_self[key]
        if btn then
            for i = #tb, 1, -1 do
                if tb[i] == btn then table.remove(tb, i); break end
            end
            fm_self[key] = nil
        end
    end
    fm_self._simpleui_browse_x_compact  = nil
    fm_self._titlebar_browse_gen_hooked = nil

    -- Restore file-chooser patches.
    local fc = fm_self.file_chooser
    if fc then
        -- Improvement #2: clear the listener registry and restore original genItemTable.
        fc._simpleui_gen_listeners = nil
        if fm_self._titlebar_orig_fc_genItemTable then
            fc.genItemTable = fm_self._titlebar_orig_fc_genItemTable
        end
        -- Improvement #8: restore the exact previous value of onFolderUp (may be nil),
        -- rather than unconditionally setting it to nil.
        if fm_self._titlebar_orig_fc_onFolderUp ~= nil then
            fc.onFolderUp = fm_self._titlebar_orig_fc_onFolderUp
        else
            fc.onFolderUp = nil
        end
        if fm_self._titlebar_orig_fc_onGotoPage then
            fc.onGotoPage = fm_self._titlebar_orig_fc_onGotoPage
        end
    end
    fm_self._titlebar_orig_fc_genItemTable = nil
    fm_self._titlebar_orig_fc_onFolderUp   = nil
    fm_self._titlebar_orig_fc_onGotoPage   = nil

    if fm_self._titlebar_orig_title_set and tb.setTitle then
        tb:setTitle("")
        fm_self._titlebar_orig_title_set = nil
    end

    fm_self._titlebar_patched = nil
end

function M.reapply(fm_self)
    -- Improvement #4: reset BrowseMeta cache so a newly-enabled module is
    -- picked up on the next apply() rather than using a stale false value.
    _resetBMCache()
    M.restore(fm_self)
    M.apply(fm_self)
end

-- ---------------------------------------------------------------------------
-- Injected widget titlebar — applyToInjected / restoreInjected
-- ---------------------------------------------------------------------------

function M.applyToInjected(widget)
    if not M.isEnabled() then return end
    local tb = widget.title_bar
    if not tb then return end
    if widget._titlebar_inj_patched then return end
    widget._titlebar_inj_patched = true

    local lp                = _layoutParams(tb)
    local iw, pad, gap, sw  = lp.iw, lp.pad, lp.gap, lp.sw
    local show_back  = M.isItemVisible("inj_back")
    local show_right = M.isItemVisible("inj_right")

    local cfg     = M.getInjConfig()
    local visible = {}
    if show_back  then visible["inj_back"]  = true end
    if show_right then visible["inj_right"] = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

    -- Left button (back).
    if tb.left_button then
        local lb = tb.left_button
        widget._titlebar_inj_lb = _snapBtn(lb)
        if show_back then
            placeBtn("inj_back", lb)
        else
            lb.overlap_align  = nil
            -- Improvement #6: use defensive 2× width offset.
            lb.overlap_offset = { _hideOffset(sw), 0 }
        end
    end

    -- Right button (close). Hidden by zeroing its dimen so it receives no taps.
    if tb.right_button then
        local rb = tb.right_button
        widget._titlebar_inj_rb = _snapBtn(rb, { save_callback = true, save_dimen = true })
        if show_right then
            placeBtn("inj_right", rb)
        else
            rb.dimen         = require("ui/geometry"):new{ w = 0, h = 0 }
            rb.callback      = function() end
            rb.hold_callback = function() end
        end
    end
end

function M.restoreInjected(widget)
    local tb = widget.title_bar
    if not tb then return end
    if not widget._titlebar_inj_patched then return end
    if tb.left_button  then _restoreBtn(tb.left_button,  widget._titlebar_inj_lb) end
    if tb.right_button then _restoreBtn(tb.right_button, widget._titlebar_inj_rb) end
    widget._titlebar_inj_lb      = nil
    widget._titlebar_inj_rb      = nil
    widget._titlebar_inj_patched = nil
end

-- ---------------------------------------------------------------------------
-- reapplyAll — re-applies to the FM and every live injected widget
-- ---------------------------------------------------------------------------

function M.reapplyAll(fm_self, window_stack)
    local logger = require("logger")
    if fm_self then
        local ok, err = pcall(M.reapply, fm_self)
        if not ok then
            logger.warn("simpleui: titlebar.reapplyAll FM failed:", tostring(err))
        end
    end
    if type(window_stack) == "table" then
        for _, entry in ipairs(window_stack) do
            local w = entry.widget
            if w and w._titlebar_inj_patched then
                local ok, err = pcall(function()
                    M.restoreInjected(w)
                    M.applyToInjected(w)
                end)
                if not ok then
                    logger.warn("simpleui: titlebar.reapplyAll widget failed:", tostring(err))
                end
            end
        end
    end
end

return M
