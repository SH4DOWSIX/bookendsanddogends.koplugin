local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen
local Tokens = require("tokens")
local OverlayWidget = require("overlay_widget")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")

-- ─── Sparse table helpers ─────────────────────────────────────────────────────

--- Remove an index from a sparse table, shifting higher indices down.
local function sparseRemove(tbl, idx)
    if not tbl then return end
    local max_idx = 0
    for k in pairs(tbl) do
        if type(k) == "number" and k > max_idx then max_idx = k end
    end
    for i = idx, max_idx do
        tbl[i] = tbl[i + 1]
    end
end

--- Truncate a string to max_bytes, avoiding splitting multi-byte UTF-8 characters.
local function truncateUtf8(str, max_bytes)
    if #str <= max_bytes then return str end
    local pos = 0
    local i = 1
    while i <= max_bytes do
        local b = str:byte(i)
        local char_len
        if b < 0x80 then char_len = 1
        elseif b < 0xE0 then char_len = 2
        elseif b < 0xF0 then char_len = 3
        else char_len = 4 end
        if i + char_len - 1 > max_bytes then break end
        pos = i + char_len - 1
        i = i + char_len
    end
    return str:sub(1, pos) .. "..."
end

-- ─── Plugin ────────────────────────────────────────────────────────────────��──

local Bookends = WidgetContainer:extend{
    name        = "bookends_and_dogends",
    is_doc_only = true,
}

Bookends.POSITIONS = {
    { key = "tl", label = _("Top-left"),     row = "top",    h_anchor = "left",   v_anchor = "top"    },
    { key = "tc", label = _("Top-center"),   row = "top",    h_anchor = "center", v_anchor = "top"    },
    { key = "tr", label = _("Top-right"),    row = "top",    h_anchor = "right",  v_anchor = "top"    },
    { key = "bl", label = _("Bottom-left"),  row = "bottom", h_anchor = "left",   v_anchor = "bottom" },
    { key = "bc", label = _("Bottom-center"),row = "bottom", h_anchor = "center", v_anchor = "bottom" },
    { key = "br", label = _("Bottom-right"), row = "bottom", h_anchor = "right",  v_anchor = "bottom" },
}

-- Dogear settings keys
local DOGEAR_S_ICON      = "bookends_dogear_icon"
local DOGEAR_S_ICON_NAME = "bookends_dogear_icon_name"
local DOGEAR_S_SCALE     = "bookends_dogear_scale"
local DOGEAR_S_MARGIN_T  = "bookends_dogear_margin_top"
local DOGEAR_S_MARGIN_R  = "bookends_dogear_margin_right"
local DOGEAR_MAX_STEPS   = 20

local SUPPORTED_EXTENSIONS = {
    [".png"] = true, [".svg"] = true, [".alpha"] = true,
    [".bmp"] = true, [".jpg"] = true, [".jpeg"] = true,
}

local SEP = {
    text         = "\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80",
    enabled_func = function() return false end,
}

-- All per-line arrays that need to be kept in sync when lines are added/removed/swapped
local LINE_ARRAYS = {
    "line_style", "line_font_size", "line_font_face",
    "line_v_nudge", "line_h_nudge", "line_uppercase",
    "line_bar_height", "line_bar_manual_width",
}

-- ─── init ─────────────────────────────────────────────────────────────────────

function Bookends:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self.ui.view:registerViewModule("bookends", self)
    self.session_start_time = os.time()
    self.session_start_page = nil
    self.session_max_page   = nil
    self.dirty              = true
    self.position_cache     = {}

    local Presets = require("ui/presets")
    self.preset_obj = {
        presets         = G_reader_settings:readSetting("bookends_presets", {}),
        dispatcher_name = "load_bookends_preset",
        buildPreset     = function() return self:buildPreset() end,
        loadPreset      = function(preset) self:loadPreset(preset) end,
    }
end

function Bookends:onReaderReady()
    self:patchReaderDogear()
end

-- ─── loadSettings ─────────────────────────────────────────────────────────────

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("bookends_enabled", false)

    self.defaults = {
        font_face   = G_reader_settings:readSetting("bookends_font_face",   Font.fontmap["ffont"]),
        font_size   = G_reader_settings:readSetting("bookends_font_size",   footer_settings.text_font_size),
        font_bold   = G_reader_settings:readSetting("bookends_font_bold",   false),
        v_offset    = G_reader_settings:readSetting("bookends_v_offset",    35),
        h_offset    = G_reader_settings:readSetting("bookends_h_offset",    18),
        overlap_gap = G_reader_settings:readSetting("bookends_overlap_gap", 10),
        bar_height  = G_reader_settings:readSetting("bookends_bar_height",  8),
    }

    local default_positions = {
        tl = { lines = { "%A \xE2\x8B\xAE %T" }, line_font_size = { [1] = 12 } },
        tc = { lines = { "%k \xC2\xB7 %a %d" },  line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
        tr = { lines = { "%C" },                  line_style = { [1] = "bold" } },
        bl = { lines = { "\xE2\x8F\xB3 %R session" }, v_offset = 16 },
        bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 }, v_offset = 35 },
        br = { lines = { "%B %W" }, line_font_size = { [1] = 10 }, v_offset = 14 },
    }

    self.positions = {}
    for _, pos in ipairs(self.POSITIONS) do
        local saved = G_reader_settings:readSetting("bookends_pos_" .. pos.key)
        if saved then
            -- Migration: old format string → lines array
            if saved.format and saved.format ~= "" and not saved.lines then
                saved.lines  = { saved.format }
                saved.format = nil
            end
            if not saved.lines then saved.lines = {} end
            self.positions[pos.key] = saved
        else
            self.positions[pos.key] = default_positions[pos.key] or { lines = {} }
        end
    end
end

-- ─── Dogear scanning ──────────────────────────────────────────────────────────

function Bookends:getDogearPluginDir()
    return self.path .. "/icons"
end

function Bookends:getDogearUserDir()
    return DataStorage:getDataDir() .. "/icons/dogears"
end

function Bookends:scanDogearDesigns()
    local designs, seen = {}, {}
    local function scan(dir)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local ext = entry:match("(%.[^%.]+)$")
                if ext and SUPPORTED_EXTENSIONS[ext:lower()] and not seen[entry] then
                    seen[entry] = true
                    table.insert(designs, { text = entry, path = dir .. "/" .. entry })
                end
            end
        end
    end
    scan(self:getDogearPluginDir())
    scan(self:getDogearUserDir())
    table.sort(designs, function(a, b) return a.text < b.text end)
    return designs
end

-- ─── Dogear monkey-patch ──────────────────────────────────────────────────────

function Bookends:patchReaderDogear()
    local ok, err = pcall(function()
        local ReaderDogear = require("apps/reader/modules/readerdogear")
        if ReaderDogear._bookends_patched then
            self:applyDogearToLive()
            return
        end
        ReaderDogear._bookends_patched = true

        local orig_setup        = ReaderDogear.setupDogear
        local orig_resetLayout  = ReaderDogear.resetLayout
        local orig_updateOffset = ReaderDogear.updateDogearOffset

        local function getMarginPx()
            local step = math.max(2, math.ceil(
                math.min(Screen:getWidth(), Screen:getHeight()) / 128))
            local mt = G_reader_settings:readSetting(DOGEAR_S_MARGIN_T) or 0
            local mr = G_reader_settings:readSetting(DOGEAR_S_MARGIN_R) or 0
            return mt * step, mr * step
        end

        local function applyMargins(rd_self)
            if not (rd_self.vgroup and rd_self.icon and rd_self.top_pad) then return end
            local mt, mr = getMarginPx()
            rd_self.top_pad.width = (rd_self.dogear_y_offset or 0) + mt

            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan  = require("ui/widget/horizontalspan")
            if mr > 0 then
                if rd_self._be_wrapper then
                    rd_self._be_wrapper[1] = nil
                    if rd_self._be_wrapper.free then rd_self._be_wrapper:free() end
                end
                rd_self._be_wrapper = HorizontalGroup:new{
                    align = "top",
                    rd_self.icon,
                    HorizontalSpan:new{ width = mr },
                }
                rd_self.vgroup[2] = rd_self._be_wrapper
            else
                if rd_self._be_wrapper then
                    rd_self._be_wrapper[1] = nil
                    if rd_self._be_wrapper.free then rd_self._be_wrapper:free() end
                    rd_self._be_wrapper = nil
                end
                rd_self.vgroup[2] = rd_self.icon
            end
            if rd_self[1] and rd_self[1].dimen then
                rd_self[1].dimen.h = rd_self.top_pad.width + rd_self.dogear_size
            end
            rd_self.vgroup:resetLayout()
        end

        ReaderDogear.setupDogear = function(rd_self, new_dogear_size)
            local sf        = G_reader_settings:readSetting(DOGEAR_S_SCALE) or 1.0
            local icon_path = G_reader_settings:readSetting(DOGEAR_S_ICON)
            if not new_dogear_size then new_dogear_size = rd_self.dogear_max_size end
            new_dogear_size = math.ceil(new_dogear_size * sf)

            if rd_self._be_wrapper then
                rd_self._be_wrapper[1] = nil
                if rd_self._be_wrapper.free then rd_self._be_wrapper:free() end
                rd_self._be_wrapper = nil
            end
            if rd_self._be_custom_icon then
                rd_self._be_custom_icon:free()
                rd_self._be_custom_icon = nil
                rd_self.icon = nil
            end

            rd_self.dogear_size = nil
            orig_setup(rd_self, new_dogear_size)

            if icon_path and lfs.attributes(icon_path, "mode") == "file" then
                if rd_self.icon then rd_self.icon:free() end
                local custom = ImageWidget:new{
                    file    = icon_path,
                    width   = rd_self.dogear_size,
                    height  = rd_self.dogear_size,
                    alpha   = true,
                    is_icon = true,
                }
                rd_self.icon            = custom
                rd_self._be_custom_icon = custom
                rd_self.vgroup[2]       = custom
            end
            applyMargins(rd_self)
        end

        if orig_resetLayout then
            ReaderDogear.resetLayout = function(rd_self, ...)
                orig_resetLayout(rd_self, ...)
                applyMargins(rd_self)
            end
        end
        if orig_updateOffset then
            ReaderDogear.updateDogearOffset = function(rd_self, ...)
                orig_updateOffset(rd_self, ...)
                applyMargins(rd_self)
            end
        end
    end)
    if not ok then logger.err("Bookends and Dogends: patchReaderDogear failed:", err) end
    self:applyDogearToLive()
end

function Bookends:applyDogearToLive()
    local d = self.ui and self.ui.view and self.ui.view.dogear
    if not d then return end
    d.dogear_size = nil
    d:setupDogear()
    d:resetLayout()
    UIManager:setDirty(d, "ui")
end

function Bookends:resetDogear()
    G_reader_settings:delSetting(DOGEAR_S_ICON)
    G_reader_settings:delSetting(DOGEAR_S_ICON_NAME)
    G_reader_settings:delSetting(DOGEAR_S_SCALE)
    G_reader_settings:delSetting(DOGEAR_S_MARGIN_T)
    G_reader_settings:delSetting(DOGEAR_S_MARGIN_R)
    self:applyDogearToLive()
end

-- ─── Preset support ──────────────────────────────────���────────────────────────

function Bookends:buildPreset()
    local util = require("util")
    local preset = {
        enabled   = self.enabled,
        defaults  = util.tableDeepCopy(self.defaults),
        positions = {},
    }
    for _, pos in ipairs(self.POSITIONS) do
        preset.positions[pos.key] = util.tableDeepCopy(self.positions[pos.key])
    end
    return preset
end

function Bookends:loadPreset(preset)
    local util = require("util")
    if preset.enabled ~= nil then
        self.enabled = preset.enabled
        G_reader_settings:saveSetting("bookends_enabled", self.enabled)
    end
    if preset.defaults then
        self.defaults = util.tableDeepCopy(preset.defaults)
        G_reader_settings:saveSetting("bookends_font_face",   self.defaults.font_face)
        G_reader_settings:saveSetting("bookends_font_size",   self.defaults.font_size)
        G_reader_settings:saveSetting("bookends_font_bold",   self.defaults.font_bold)
        G_reader_settings:saveSetting("bookends_v_offset",    self.defaults.v_offset)
        G_reader_settings:saveSetting("bookends_h_offset",    self.defaults.h_offset)
        G_reader_settings:saveSetting("bookends_overlap_gap", self.defaults.overlap_gap)
        G_reader_settings:saveSetting("bookends_bar_height",  self.defaults.bar_height)
    end
    if preset.positions then
        for _, pos in ipairs(self.POSITIONS) do
            if preset.positions[pos.key] then
                self.positions[pos.key] = util.tableDeepCopy(preset.positions[pos.key])
                self:savePositionSetting(pos.key)
            end
        end
    end
    self:markDirty()
end

-- ─── Settings helpers ─────────────────────────────────────────────────────────

function Bookends:savePositionSetting(key)
    G_reader_settings:saveSetting("bookends_pos_" .. key, self.positions[key])
end

function Bookends:getPositionSetting(key, field)
    local pos = self.positions[key]
    if pos[field] ~= nil then return pos[field] end
    return self.defaults[field]
end

function Bookends:isPositionActive(key)
    return self.enabled and #self.positions[key].lines > 0
end

function Bookends:markDirty()
    self.dirty = true
    UIManager:setDirty(self.ui, "ui")
end

-- ─── Style helpers ────────────────────────────────────────────────────────────

Bookends.STYLES = { "regular", "bold", "italic", "bolditalic" }
Bookends.STYLE_LABELS = {
    regular    = _("Regular"),
    bold       = _("Bold"),
    italic     = _("Italic"),
    bolditalic = _("Bold Italic"),
}

local _italic_variants = {
    ["NotoSans-Regular.ttf"]  = "NotoSans-Italic.ttf",
    ["NotoSans-Bold.ttf"]     = "NotoSans-BoldItalic.ttf",
    ["NotoSerif-Regular.ttf"] = "NotoSerif-Italic.ttf",
    ["NotoSerif-Bold.ttf"]    = "NotoSerif-BoldItalic.ttf",
}

function Bookends:resolveLineConfig(face_name, font_size, style, bar_height, bar_manual_width)
    style = style or "regular"
    local bold = (style == "bold" or style == "bolditalic")
    local resolved_face = face_name
    if style == "italic" or style == "bolditalic" then
        local italic = _italic_variants[face_name]
        if italic then resolved_face = italic end
    end
    return {
        face             = Font:getFace(resolved_face, font_size),
        bold             = bold,
        bar_height       = bar_height       or self.defaults.bar_height or 8,
        bar_manual_width = bar_manual_width or nil,
    }
end

-- ─── Event handlers ───────────────────────────────────────────────────────────

function Bookends:onPageUpdate()
    local current = self.ui.view.state.page
    if current then
        if not self.session_start_page then
            self.session_start_page = current
            self.session_max_page   = current
        elseif current > self.session_max_page then
            self.session_max_page = current
        end
    end
    self:markDirty()
end

function Bookends:onPosUpdate()                    self:markDirty() end
function Bookends:onReaderFooterVisibilityChange() self:markDirty() end
function Bookends:onSetDimensions()                self:markDirty() end

function Bookends:onResume()
    -- Reset session timer on wake so elapsed time excludes suspend periods
    self.session_start_time = os.time()
    self:markDirty()
end

-- ─── paintTo ──────────────────────────────────────────────────────────────────

function Bookends:paintTo(bb, x, y)
    if not self.enabled then return end

    local screen_size   = Screen:getSize()
    local screen_w      = screen_size.w
    local screen_h      = screen_size.h
    local session_pages = math.max(0,
        (self.session_max_page or 0) - (self.session_start_page or 0))

    -- Phase 1: Expand tokens for all active positions
    local expanded = {}
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            local joined = table.concat(self.positions[pos.key].lines, "\n")
            expanded[pos.key] = Tokens.expand(
                joined, self.ui, self.session_start_time, session_pages)
        end
    end

    -- Phase 2: Cache check — skip rebuild if nothing changed
    if not self.dirty then
        local changed = false
        for key, text in pairs(expanded) do
            if text ~= self.position_cache[key] then changed = true; break end
        end
        if not changed then
            for key in pairs(self.position_cache) do
                if not expanded[key] then changed = true; break end
            end
        end
        if not changed then
            for _, pos in ipairs(self.POSITIONS) do
                local entry = self.widget_cache and self.widget_cache[pos.key]
                if entry then entry.widget:paintTo(bb, x + entry.x, y + entry.y) end
            end
            return
        end
    end

    -- Phase 3: Build per-line configs and measure text widths
    local measurements = {}
    for key, text in pairs(expanded) do
        local ps            = self.positions[key]
        local default_face  = self:getPositionSetting(key, "font_face")
        local default_size  = self:getPositionSetting(key, "font_size")
        local default_bar_h = self:getPositionSetting(key, "bar_height")
                              or self.defaults.bar_height or 8

        local line_configs = {}
        for i = 1, #ps.lines do
            local face   = (ps.line_font_face        and ps.line_font_face[i])        or default_face
            local fsize  = (ps.line_font_size        and ps.line_font_size[i])        or default_size
            local style  = (ps.line_style            and ps.line_style[i])            or "regular"
            local bar_h  = (ps.line_bar_height       and ps.line_bar_height[i])       or default_bar_h
            local bar_mw = (ps.line_bar_manual_width and ps.line_bar_manual_width[i]) or nil
            local cfg    = self:resolveLineConfig(face, fsize, style, bar_h, bar_mw)
            cfg.v_nudge  = (ps.line_v_nudge   and ps.line_v_nudge[i])   or 0
            cfg.h_nudge  = (ps.line_h_nudge   and ps.line_h_nudge[i])   or 0
            cfg.uppercase = (ps.line_uppercase and ps.line_uppercase[i]) or false
            table.insert(line_configs, cfg)
        end

        local w = OverlayWidget.measureTextWidth(text, line_configs)
        measurements[key] = { width = w, line_configs = line_configs }
    end

    -- Phase 4: Overlap limits per row, then build and cache widgets
    local gap = self.defaults.overlap_gap
    if self.widget_cache then OverlayWidget.freeWidgets(self.widget_cache) end
    self.widget_cache = {}

    for _, row in ipairs({ "top", "bottom" }) do
        local left_key   = row == "top" and "tl" or "bl"
        local center_key = row == "top" and "tc" or "bc"
        local right_key  = row == "top" and "tr" or "br"

        local left_w   = measurements[left_key]   and measurements[left_key].width   or nil
        local center_w = measurements[center_key] and measurements[center_key].width or nil
        local right_w  = measurements[right_key]  and measurements[right_key].width  or nil

        local lho          = self:getPositionSetting(left_key,  "h_offset")
        local rho          = self:getPositionSetting(right_key, "h_offset")
        local max_h_offset = math.max(lho or 0, rho or 0)

        local limits = OverlayWidget.calculateRowLimits(
            left_w, center_w, right_w, screen_w, gap, max_h_offset)

        local row_keys = {
            { key = left_key,   limit_key = "left"   },
            { key = center_key, limit_key = "center" },
            { key = right_key,  limit_key = "right"  },
        }

        for _, rk in ipairs(row_keys) do
            local key = rk.key
            if expanded[key] then
                local m = measurements[key]
                local pos_def
                for _, p in ipairs(self.POSITIONS) do
                    if p.key == key then pos_def = p; break end
                end

                local max_width      = limits[rk.limit_key]
                local h_off          = self:getPositionSetting(key, "h_offset")
                local full_available = screen_w - (h_off * 2)
                local available_w    = max_width
                    and math.min(full_available, max_width)
                    or  full_available

                local widget, w, h = OverlayWidget.buildTextWidget(
                    expanded[key], m.line_configs, pos_def.h_anchor,
                    max_width, available_w, full_available)

                if widget then
                    local v_off = self:getPositionSetting(key, "v_offset")
                    local px, py = OverlayWidget.computeCoordinates(
                        pos_def.h_anchor, pos_def.v_anchor,
                        w, h, screen_w, screen_h, v_off, h_off)

                    -- Apply first-line nudge for single-line widgets
                    -- (MultiLineWidget handles per-line nudges internally)
                    local cfg1 = m.line_configs[1]
                    if cfg1 and not widget.lines then
                        px = px + (cfg1.h_nudge or 0)
                        py = py + (cfg1.v_nudge or 0)
                    end

                    self.widget_cache[key] = { widget = widget, x = px, y = py }
                    widget:paintTo(bb, x + px, y + py)
                end
            end
        end
    end

    -- Update cache state
    self.position_cache = {}
    for key, text in pairs(expanded) do self.position_cache[key] = text end
    self.dirty = false
end

function Bookends:onCloseWidget()
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
        self.widget_cache = nil
    end
end

-- ─── Menu ─────────────────────────────────────────────────────────────────────

function Bookends:addToMainMenu(menu_items)
    menu_items.bookends_and_dogends = {
        text           = _("Bookends and Dogends"),
        sorting_hint   = "typeset",
        sub_item_table = self:buildMainMenu(),
    }
end

function Bookends:buildMainMenu()
    local menu = {
        {
            text         = _("Enable Bookends and Dogends"),
            checked_func = function() return self.enabled end,
            callback     = function()
                self.enabled = not self.enabled
                G_reader_settings:saveSetting("bookends_enabled", self.enabled)
                self:markDirty()
            end,
        },
        -- Defaults submenu
        {
            text           = _("Defaults"),
            enabled_func   = function() return self.enabled end,
            sub_item_table = {
                {
                    text           = _("Default font"),
                    sub_item_table = self:buildFontMenu(
                        function() return self.defaults.font_face end,
                        function(face)
                            self.defaults.font_face = face
                            G_reader_settings:saveSetting("bookends_font_face", face)
                            self:markDirty()
                        end),
                },
                {
                    text           = _("Default font size"),
                    keep_menu_open = true,
                    callback       = function()
                        self:showSpinner(_("Default font size"),
                            self.defaults.font_size, 8, 36,
                            self.ui.view.footer.settings.text_font_size,
                            function(val)
                                self.defaults.font_size = val
                                G_reader_settings:saveSetting("bookends_font_size", val)
                                self:markDirty()
                            end)
                    end,
                },
                {
                    text           = _("Default progress bar height (px)"),
                    keep_menu_open = true,
                    callback       = function()
                        self:showSpinner(_("Default progress bar height (px)"),
                            self.defaults.bar_height, 2, 40, 8,
                            function(val)
                                self.defaults.bar_height = val
                                G_reader_settings:saveSetting("bookends_bar_height", val)
                                self:markDirty()
                            end)
                    end,
                },
                {
                    text           = _("Default vertical offset"),
                    keep_menu_open = true,
                    callback       = function()
                        self:showSpinner(_("Default vertical offset (px)"),
                            self.defaults.v_offset, 0, 999, 35,
                            function(val)
                                self.defaults.v_offset = val
                                G_reader_settings:saveSetting("bookends_v_offset", val)
                                self:markDirty()
                            end)
                    end,
                },
                {
                    text           = _("Default horizontal offset"),
                    keep_menu_open = true,
                    callback       = function()
                        self:showSpinner(_("Default horizontal offset (px)"),
                            self.defaults.h_offset, 0, 999, 18,
                            function(val)
                                self.defaults.h_offset = val
                                G_reader_settings:saveSetting("bookends_h_offset", val)
                                self:markDirty()
                            end)
                    end,
                },
                {
                    text           = _("Overlap gap"),
                    keep_menu_open = true,
                    callback       = function()
                        self:showSpinner(_("Minimum gap between texts (px)"),
                            self.defaults.overlap_gap, 0, 100, 10,
                            function(val)
                                self.defaults.overlap_gap = val
                                G_reader_settings:saveSetting("bookends_overlap_gap", val)
                                self:markDirty()
                            end)
                    end,
                },
            },
        },
        -- Presets
        {
            text                = _("Presets"),
            enabled_func        = function() return self.enabled end,
            sub_item_table_func = function() return self:buildPresetsMenu() end,
        },
        -- Dogear
        {
            text                = _("Dogear (bookmark corner)"),
            sub_item_table_func = function() return self:buildDogearMenu() end,
        },
    }

    -- Per-position entries
    for _, pos in ipairs(self.POSITIONS) do
        table.insert(menu, {
            text_func = function()
                local lines = self.positions[pos.key].lines
                if #lines == 0 then return pos.label end
                local preview = Tokens.expandPreview(lines[1], self.ui,
                    self.session_start_time,
                    math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0)))
                if #lines > 1 then preview = preview .. " ..." end
                if #preview > 40 then preview = truncateUtf8(preview, 37) end
                return pos.label .. ": " .. preview
            end,
            enabled_func        = function() return self.enabled end,
            sub_item_table_func = function() return self:buildPositionMenu(pos) end,
        })
    end

    return menu
end

-- ─── Dogear menu ──────────────────────────────────────────────────────────────

function Bookends:buildDogearMenu()
    local screen_min = math.min(Screen:getWidth(), Screen:getHeight())
    local step       = math.max(2, math.ceil(screen_min / 128))
    local menu       = {}

    table.insert(menu, {
        text_func = function()
            local name = G_reader_settings:readSetting(DOGEAR_S_ICON_NAME)
            return name and (_("Design: ") .. name) or _("Design: default")
        end,
        sub_item_table_func = function() return self:buildDogearIconMenu() end,
    })

    table.insert(menu, SEP)

    table.insert(menu, {
        text_func = function()
            local s = G_reader_settings:readSetting(DOGEAR_S_SCALE) or 1.0
            return string.format(_("Size: %.1f\xC3\x97"), s)
        end,
        keep_menu_open = true,
        callback = function()
            local cur = G_reader_settings:readSetting(DOGEAR_S_SCALE) or 1.0
            UIManager:show(SpinWidget:new{
                value         = math.floor(cur * 10 + 0.5),
                value_min     = 5,
                value_max     = 40,
                default_value = 10,
                title_text    = _("Dogear size (5=0.5\xC3\x97 10=1.0\xC3\x97 20=2.0\xC3\x97)"),
                ok_text       = _("Set"),
                callback      = function(spin)
                    G_reader_settings:saveSetting(DOGEAR_S_SCALE, spin.value / 10)
                    self:applyDogearToLive()
                end,
            })
        end,
    })

    table.insert(menu, {
        text_func = function()
            local s = G_reader_settings:readSetting(DOGEAR_S_MARGIN_T) or 0
            return string.format(_("Top offset: %d px"), s * step)
        end,
        keep_menu_open = true,
        callback = function()
            local cur = G_reader_settings:readSetting(DOGEAR_S_MARGIN_T) or 0
            self:showSpinner(_("Dogear top offset (steps)"), cur, 0, DOGEAR_MAX_STEPS, 0,
                function(val)
                    G_reader_settings:saveSetting(DOGEAR_S_MARGIN_T, val)
                    self:applyDogearToLive()
                end)
        end,
    })

    table.insert(menu, {
        text_func = function()
            local s = G_reader_settings:readSetting(DOGEAR_S_MARGIN_R) or 0
            return string.format(_("Right offset: %d px"), s * step)
        end,
        keep_menu_open = true,
        callback = function()
            local cur = G_reader_settings:readSetting(DOGEAR_S_MARGIN_R) or 0
            self:showSpinner(_("Dogear right offset (steps)"), cur, 0, DOGEAR_MAX_STEPS, 0,
                function(val)
                    G_reader_settings:saveSetting(DOGEAR_S_MARGIN_R, val)
                    self:applyDogearToLive()
                end)
        end,
    })

    table.insert(menu, SEP)

    table.insert(menu, {
        text     = _("Reset dogear to defaults"),
        callback = function()
            local InfoMessage = require("ui/widget/infomessage")
            self:resetDogear()
            UIManager:show(InfoMessage:new{ text = _("Dogear reset."), timeout = 2 })
        end,
    })

    return menu
end

function Bookends:buildDogearIconMenu()
    local designs = self:scanDogearDesigns()
    local menu    = {}

    table.insert(menu, {
        text_func = function()
            local cur = G_reader_settings:readSetting(DOGEAR_S_ICON)
            return cur and _("   Default") or _("\xE2\x9C\x93 Default")
        end,
        callback = function()
            G_reader_settings:delSetting(DOGEAR_S_ICON)
            G_reader_settings:delSetting(DOGEAR_S_ICON_NAME)
            self:applyDogearToLive()
        end,
    })

    if #designs == 0 then
        table.insert(menu, {
            text = _("No designs found — place images in:") .. " " ..
                   self:getDogearPluginDir() .. " " .. _("or") .. " " ..
                   self:getDogearUserDir(),
            enabled_func = function() return false end,
        })
    else
        for _, design in ipairs(designs) do
            local d = design
            table.insert(menu, {
                text_func = function()
                    local cur = G_reader_settings:readSetting(DOGEAR_S_ICON)
                    return ((cur == d.path) and "\xE2\x9C\x93 " or "   ") .. d.text
                end,
                callback = function()
                    G_reader_settings:saveSetting(DOGEAR_S_ICON,      d.path)
                    G_reader_settings:saveSetting(DOGEAR_S_ICON_NAME, d.text)
                    self:applyDogearToLive()
                end,
            })
        end
    end

    return menu
end

-- ─── Presets ──────────────────────────────────────────────────────────────────

Bookends.BUILT_IN_PRESETS = {
    {
        name = _("Minimal"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = {} },
                tc = { lines = {} },
                tr = { lines = {} },
                bl = { lines = {} },
                bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 }, v_offset = 35 },
                br = { lines = {} },
            },
        },
    },
    {
        name = _("Full status"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = { "%A \xE2\x8B\xAE %T" }, line_font_size = { [1] = 12 } },
                tc = { lines = { "%k \xC2\xB7 %a %d" }, line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
                tr = { lines = { "%C" }, line_style = { [1] = "bold" } },
                bl = { lines = { "\xE2\x8F\xB3 %R session" }, v_offset = 16 },
                bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 }, v_offset = 35 },
                br = { lines = { "%B %W" }, line_font_size = { [1] = 10 }, v_offset = 14 },
            },
        },
    },
    {
        name = _("Book info"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = {} },
                tc = { lines = { "%T", "%A" }, line_style = { [1] = "bold", [2] = "italic" }, line_font_size = { [2] = 11 } },
                tr = { lines = {} },
                bl = { lines = {} },
                bc = { lines = { "%c / %t (%p)" }, v_offset = 35 },
                br = { lines = {} },
            },
        },
    },
    {
        name = _("Chapter focus"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = {} },
                tc = { lines = { "%C" }, line_style = { [1] = "bold" } },
                tr = { lines = {} },
                bl = { lines = { "%g / %G (%P)" } },
                bc = { lines = { "Page %c of %t" }, v_offset = 35 },
                br = { lines = { "%h left" } },
            },
        },
    },
    {
        name = _("Progress bars"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = { "%A \xE2\x8B\xAE %T" }, line_font_size = { [1] = 12 } },
                tc = { lines = { "%k \xC2\xB7 %a %d" }, line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
                tr = { lines = { "%C" }, line_style = { [1] = "bold" } },
                bl = { lines = { "%bar_chapter" }, v_offset = 16 },
                bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 }, v_offset = 35 },
                br = { lines = { "%bar_book" }, v_offset = 14 },
            },
        },
    },
    {
        name = _("Token test"),
        preset = {
            enabled = true,
            positions = {
                tl = { lines = {
                    "%T", "%A", "%S", "%C",
                }, line_font_size = { [1] = 10, [2] = 10, [3] = 10, [4] = 10 } },
                tc = { lines = {
                    "%k \xC2\xB7 %K",
                    "%d \xC2\xB7 %D",
                    "%n \xC2\xB7 %w \xC2\xB7 %a",
                }, line_font_size = { [1] = 10, [2] = 10, [3] = 10 } },
                tr = { lines = {
                    "%B %b \xC2\xB7 %W",
                    "%m",
                }, line_font_size = { [1] = 10, [2] = 10 } },
                bl = { lines = {
                    "%R session \xC2\xB7 %s pages",
                    "%h ch \xC2\xB7 %H book",
                }, line_font_size = { [1] = 10, [2] = 10 }, v_offset = 16 },
                bc = { lines = {
                    "Page %c of %t (%p)",
                }, line_font_size = { [1] = 10 }, v_offset = 35 },
                br = { lines = {
                    "Ch: %g/%G (%P)",
                    "Left: %l ch \xC2\xB7 %L book",
                }, line_font_size = { [1] = 10, [2] = 10 }, v_offset = 14 },
            },
        },
    },
}

function Bookends:buildPresetsMenu()
    local Presets     = require("ui/presets")
    local InfoMessage = require("ui/widget/infomessage")

    local items = Presets.genPresetMenuItemTable(self.preset_obj)

    local builtin_items = {
        {
            text         = "\xE2\x94\x80\xE2\x94\x80 " .. _("Built-in") .. " \xE2\x94\x80\xE2\x94\x80",
            enabled_func = function() return false end,
        },
    }

local loaded_msg = _("Preset '%1' loaded.")
for _, bp in ipairs(self.BUILT_IN_PRESETS) do
    local preset_name = tostring(bp.name)
    local msg = loaded_msg:gsub("%%1", preset_name)
    table.insert(builtin_items, {
        text           = bp.name,
        keep_menu_open = true,
        callback       = function()
            self:loadPreset(bp.preset)
            UIManager:show(InfoMessage:new{
                text    = msg,
                timeout = 2,
            })
        end,
    })
end

    for i = #builtin_items, 1, -1 do
        table.insert(items, 2, builtin_items[i])
    end

    if #self.preset_obj.presets > 0 or next(self.preset_obj.presets) then
        table.insert(items, 2 + #builtin_items, {
            text         = "\xE2\x94\x80\xE2\x94\x80 " .. _("Your presets") .. " \xE2\x94\x80\xE2\x94\x80",
            enabled_func = function() return false end,
        })
    end

    return items
end

-- ─── Position menu ────────────────────────────────────────────────────────────

function Bookends:buildPositionMenu(pos)
    local is_corner = pos.h_anchor ~= "center"
    local menu      = {}

    for i = 1, #self.positions[pos.key].lines do
        local idx = i
        table.insert(menu, {
            text_func = function()
                local preview = Tokens.expandPreview(
                    self.positions[pos.key].lines[idx] or "", self.ui,
                    self.session_start_time,
                    math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0)))
                if #preview > 45 then preview = truncateUtf8(preview, 42) end
                return _("Line") .. " " .. idx .. ": " .. preview
            end,
            callback      = function() self:editLineString(pos, idx) end,
            hold_callback = function(tmi) self:showLineManageDialog(pos, idx, tmi) end,
        })
    end

    table.insert(menu, {
        text     = "+ " .. _("Add line") .. "  (" .. _("long press lines to manage") .. ")",
        callback = function()
            local idx = #self.positions[pos.key].lines + 1
            table.insert(self.positions[pos.key].lines, "")
            self:savePositionSetting(pos.key)
            self:editLineString(pos, idx)
        end,
        separator = true,
    })

    table.insert(menu, {
        text_func = function()
            local v = self.positions[pos.key].v_offset
            return v and (_("Override vertical offset") .. " (" .. v .. ")")
                      or  _("Override vertical offset")
        end,
        keep_menu_open = true,
        callback = function()
            self:showSpinner(_("Vertical offset for " .. pos.label),
                self:getPositionSetting(pos.key, "v_offset"), 0, 999,
                self.defaults.v_offset,
                function(val)
                    self.positions[pos.key].v_offset = val
                    self:savePositionSetting(pos.key)
                    self:markDirty()
                end)
        end,
    })

    if is_corner then
        table.insert(menu, {
            text_func = function()
                local h = self.positions[pos.key].h_offset
                return h and (_("Override horizontal offset") .. " (" .. h .. ")")
                          or  _("Override horizontal offset")
            end,
            keep_menu_open = true,
            callback = function()
                self:showSpinner(_("Horizontal offset for " .. pos.label),
                    self:getPositionSetting(pos.key, "h_offset"), 0, 999,
                    self.defaults.h_offset,
                    function(val)
                        self.positions[pos.key].h_offset = val
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
            end,
        })
    end

    table.insert(menu, {
        text     = _("Reset all overrides"),
        callback = function()
            local lines_copy = self.positions[pos.key].lines
            self.positions[pos.key] = { lines = lines_copy }
            self:savePositionSetting(pos.key)
            self:markDirty()
        end,
    })

    return menu
end

-- ��── Line editing ─────────────────────────────────────────────────────────────

function Bookends:editLineString(pos, line_idx)
    local IconPicker   = require("icon_picker")
    local util         = require("util")
    local pos_settings = self.positions[pos.key]
    local current_text = pos_settings.lines[line_idx] or ""

    -- Ensure all per-line arrays exist
    for _, arr in ipairs(LINE_ARRAYS) do
        pos_settings[arr] = pos_settings[arr] or {}
    end

    local original_settings = util.tableDeepCopy(pos_settings)

    local line_style     = pos_settings.line_style[line_idx]            or "regular"
    local line_size      = pos_settings.line_font_size[line_idx]
    local line_face      = pos_settings.line_font_face[line_idx]
    local line_v_nudge   = pos_settings.line_v_nudge[line_idx]          or 0
    local line_h_nudge   = pos_settings.line_h_nudge[line_idx]          or 0
    local line_uppercase = pos_settings.line_uppercase[line_idx]        or false
    local line_bar_h     = pos_settings.line_bar_height[line_idx]
    local line_bar_mw    = pos_settings.line_bar_manual_width[line_idx] or 0

    local nudge_step = 1

    local function applyLivePreview()
        pos_settings.line_style[line_idx]            = line_style ~= "regular" and line_style or nil
        pos_settings.line_font_size[line_idx]        = line_size
        pos_settings.line_font_face[line_idx]        = line_face
        pos_settings.line_v_nudge[line_idx]          = line_v_nudge ~= 0 and line_v_nudge or nil
        pos_settings.line_h_nudge[line_idx]          = line_h_nudge ~= 0 and line_h_nudge or nil
        pos_settings.line_uppercase[line_idx]        = line_uppercase or nil
        pos_settings.line_bar_height[line_idx]       = line_bar_h
        pos_settings.line_bar_manual_width[line_idx] = line_bar_mw ~= 0 and line_bar_mw or nil
        self:savePositionSetting(pos.key)
        self:markDirty()
    end

    local format_dialog

    local style_button = {
        text_func = function() return self.STYLE_LABELS[line_style] or _("Regular") end,
        callback  = function()
            for idx, s in ipairs(self.STYLES) do
                if s == line_style then
                    line_style = self.STYLES[(idx % #self.STYLES) + 1]
                    break
                end
            end
            applyLivePreview()
            format_dialog:reinit()
        end,
    }

    local size_button = {
        text_func = function()
            return _("Size") .. ": " ..
                (line_size or self:getPositionSetting(pos.key, "font_size"))
        end,
        callback = function()
            local cur = line_size or self:getPositionSetting(pos.key, "font_size")
            UIManager:show(SpinWidget:new{
                value         = cur,
                value_min     = 8,
                value_max     = 36,
                default_value = self:getPositionSetting(pos.key, "font_size"),
                title_text    = _("Font size for line") .. " " .. line_idx,
                ok_text       = _("Set"),
                callback      = function(spin)
                    line_size = spin.value
                    applyLivePreview()
                    format_dialog:reinit()
                end,
            })
        end,
    }

    local font_button = {
        text_func = function()
            return line_face and (_("Font") .. " \xE2\x9C\x93") or _("Font...")
        end,
        callback = function()
            format_dialog:onCloseKeyboard()
            self:showFontPicker(
                line_face or self:getPositionSetting(pos.key, "font_face"),
                function(ff)
                    line_face = ff
                    applyLivePreview()
                    format_dialog:reinit()
                end)
        end,
    }

    local case_button = {
        text_func = function() return line_uppercase and "AA" or "Aa" end,
        callback  = function()
            line_uppercase = not line_uppercase
            applyLivePreview()
            format_dialog:reinit()
        end,
    }

    local bar_h_button = {
        text_func = function()
            return _("Bar h") .. ": " ..
                (line_bar_h or self.defaults.bar_height or 8) .. "px"
        end,
        callback = function()
            local cur = line_bar_h or self.defaults.bar_height or 8
            UIManager:show(SpinWidget:new{
                value         = cur,
                value_min     = 2,
                value_max     = 40,
                default_value = self.defaults.bar_height or 8,
                title_text    = _("Bar height (px) for line") .. " " .. line_idx,
                ok_text       = _("Set"),
                callback      = function(spin)
                    line_bar_h = spin.value
                    applyLivePreview()
                    format_dialog:reinit()
                end,
            })
        end,
    }

    local bar_mw_button = {
        text_func = function()
            if line_bar_mw and line_bar_mw > 0 then
                return _("Bar w") .. ": " .. line_bar_mw .. "px"
            else
                return _("Bar w: full")
            end
        end,
        callback = function()
            UIManager:show(SpinWidget:new{
                value         = line_bar_mw or 0,
                value_min     = 0,
                value_max     = Screen:getWidth(),
                default_value = 0,
                title_text    = _("Bar width (px, 0 = full)"),
                ok_text       = _("Set"),
                callback      = function(spin)
                    line_bar_mw = spin.value
                    applyLivePreview()
                    format_dialog:reinit()
                end,
            })
        end,
    }

    local nudge_up = {
        text = "\xE2\x96\xB2",
        callback = function()
            format_dialog:onCloseKeyboard()
            line_v_nudge = line_v_nudge - nudge_step
            applyLivePreview(); format_dialog:reinit()
        end,
    }
    local nudge_down = {
        text = "\xE2\x96\xBC",
        callback = function()
            format_dialog:onCloseKeyboard()
            line_v_nudge = line_v_nudge + nudge_step
            applyLivePreview(); format_dialog:reinit()
        end,
    }
    local nudge_left = {
        text = "\xE2\x97\x80",
        callback = function()
            format_dialog:onCloseKeyboard()
            line_h_nudge = line_h_nudge - nudge_step
            applyLivePreview(); format_dialog:reinit()
        end,
    }
    local nudge_right = {
        text = "\xE2\x96\xB6",
        callback = function()
            format_dialog:onCloseKeyboard()
            line_h_nudge = line_h_nudge + nudge_step
            applyLivePreview(); format_dialog:reinit()
        end,
    }
    local nudge_label = {
        text_func = function()
            if line_v_nudge == 0 and line_h_nudge == 0 then return _("Position") end
            return line_h_nudge .. "," .. line_v_nudge
        end,
        callback = function()
            format_dialog:onCloseKeyboard()
            line_v_nudge = 0; line_h_nudge = 0
            applyLivePreview(); format_dialog:reinit()
        end,
    }

    format_dialog = InputDialog:new{
        title  = pos.label .. " \xE2\x80\x94 " .. _("Line") .. " " .. line_idx,
        input  = current_text,
        edited_callback = function()
            if not format_dialog then return end
            local live_text = format_dialog:getInputText()
            if live_text and live_text ~= "" then
                pos_settings.lines[line_idx] = live_text
                self:savePositionSetting(pos.key)
                self:markDirty()
            end
        end,
        buttons = {
            -- Row 1: style / size / font / case / bar controls
            { style_button, size_button, font_button, case_button, bar_h_button, bar_mw_button },
            -- Row 2: position nudge
            { nudge_left, nudge_right, nudge_label, nudge_up, nudge_down },
            -- Row 3: main actions
            {
                {
                    text     = _("Cancel"),
                    callback = function()
                        for k, v in pairs(original_settings) do
                            pos_settings[k] = v
                        end
                        self:savePositionSetting(pos.key)
                        UIManager:close(format_dialog)
                        self:markDirty()
                    end,
                },
                {
                    text     = _("Icons"),
                    callback = function()
                        format_dialog:onCloseKeyboard()
                        IconPicker:show(function(value)
                            format_dialog:addTextToInput(value)
                        end)
                    end,
                },
                {
                    text     = _("Tokens"),
                    callback = function()
                        format_dialog:onCloseKeyboard()
                        self:showTokenPicker(function(token)
                            format_dialog:addTextToInput(token)
                        end)
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_text = format_dialog:getInputText()
                        if new_text == "" then
                            table.remove(pos_settings.lines, line_idx)
                            for _, arr in ipairs(LINE_ARRAYS) do
                                if pos_settings[arr] then
                                    table.remove(pos_settings[arr], line_idx)
                                end
                            end
                        else
                            pos_settings.lines[line_idx] = new_text
                            applyLivePreview()
                        end
                        self:savePositionSetting(pos.key)
                        UIManager:close(format_dialog)
                        self:markDirty()
                    end,
                },
            },
        },
    }
    UIManager:show(format_dialog)
    format_dialog:onShowKeyboard()
end

-- ─── Line manage dialog (hold) ────────────────────────────────────────────────

function Bookends:showLineManageDialog(pos, line_idx, touchmenu_instance)
    local ConfirmBox = require("ui/widget/confirmbox")
    local T          = require("ffi/util").template
    local ps         = self.positions[pos.key]
    local num_lines  = #ps.lines

    local function refreshMenu()
        if touchmenu_instance then
            touchmenu_instance.item_table = self:buildPositionMenu(pos)
            touchmenu_instance:updateItems()
        end
    end

    local function removeLine()
        table.remove(ps.lines, line_idx)
        for _, arr in ipairs(LINE_ARRAYS) do
            if ps[arr] then table.remove(ps[arr], line_idx) end
        end
        self:savePositionSetting(pos.key)
        self:markDirty()
        refreshMenu()
    end

    local function swapLines(a, b)
        ps.lines[a], ps.lines[b] = ps.lines[b], ps.lines[a]
        for _, arr in ipairs(LINE_ARRAYS) do
            if ps[arr] then ps[arr][a], ps[arr][b] = ps[arr][b], ps[arr][a] end
        end
        self:savePositionSetting(pos.key)
        self:markDirty()
        refreshMenu()
    end

    local other_buttons = {}
    if line_idx > 1 then
        table.insert(other_buttons, {
            { text = _("Move up"), callback = function() swapLines(line_idx, line_idx - 1) end },
        })
    end
    if line_idx < num_lines then
        table.insert(other_buttons, {
            { text = _("Move down"), callback = function() swapLines(line_idx, line_idx + 1) end },
        })
    end

    UIManager:show(ConfirmBox:new{
        text                = T(_("Line %1: %2"), line_idx, ps.lines[line_idx]),
        icon                = "notice-question",
        ok_text             = _("Delete"),
        ok_callback         = removeLine,
        cancel_text         = _("Cancel"),
        other_buttons_first = true,
        other_buttons       = other_buttons,
    })
end

-- ─── Font picker ──────────────────────────────────────────────────────────────

function Bookends:showFontPicker(current_face, on_select)
    local Menu     = require("ui/widget/menu")
    local cre      = require("document/credocument"):engineInit()
    local FontList = require("fontlist")
    local items    = {}
    for _, face_name in ipairs(cre.getFontFaces()) do
        local ff, fi = cre.getFontFaceFilenameAndFaceIndex(face_name)
        if not ff then ff, fi = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true) end
        if ff then
            local dn = FontList:getLocalizedFontName(ff, fi) or face_name
            table.insert(items, {
                text          = ((ff == current_face) and "\xE2\x9C\x93 " or "   ") .. dn,
                font_filename = ff,
            })
        end
    end
    local menu
    menu = Menu:new{
        title        = _("Select font"),
        item_table   = items,
        width        = math.floor(Screen:getWidth()  * 0.8),
        height       = math.floor(Screen:getHeight() * 0.8),
        onMenuChoice = function(_, item)
            UIManager:close(menu)
            if item.font_filename then on_select(item.font_filename) end
        end,
    }
    UIManager:show(menu, nil, nil,
        math.floor((Screen:getWidth()  - menu.dimen.w) / 2),
        math.floor((Screen:getHeight() - menu.dimen.h) / 2))
end

-- ─── Token picker ─────────────────────────────────────────────────────────────

Bookends.TOKEN_CATALOG = {
    { _("Metadata"), {
        { "%T", _("Document title") },
        { "%A", _("Author(s)") },
        { "%S", _("Series with index") },
        { "%C", _("Chapter title") },
    }},
    { _("Page / Progress"), {
        { "%c",          _("Current page number") },
        { "%t",          _("Total pages") },
        { "%p",          _("Book percentage read") },
        { "%P",          _("Chapter percentage read") },
        { "%g",          _("Pages read in chapter") },
        { "%G",          _("Total pages in chapter") },
        { "%l",          _("Pages left in chapter") },
        { "%L",          _("Pages left in book") },
        { "%bar_book",   _("Book progress bar") },
        { "%bar_chapter",_("Chapter progress bar") },
    }},
    { _("Time / Date"), {
        { "%k", _("12-hour clock") },
        { "%K", _("24-hour clock") },
        { "%d", _("Date short (28 Mar)") },
        { "%D", _("Date long (28 March 2026)") },
        { "%n", _("Date numeric (28/03/2026)") },
        { "%w", _("Weekday (Friday)") },
        { "%a", _("Weekday short (Fri)") },
    }},
    { _("Reading"), {
        { "%h", _("Time left in chapter") },
        { "%H", _("Time left in book") },
        { "%R", _("Session reading time") },
        { "%s", _("Session pages read") },
    }},
    { _("Device"), {
        { "%b",  _("Battery level") },
        { "%B",  _("Battery icon (dynamic)") },
        { "%W",  _("Wi-Fi icon (dynamic)") },
        { "%m",  _("RAM used %") },
        { "%Fl", _("Brightness level") },
        { "%Fw", _("Warmth level") },
    }},
}

function Bookends:showTokenPicker(on_select)
    local Menu  = require("ui/widget/menu")
    local items = {}
    for _, category in ipairs(self.TOKEN_CATALOG) do
        local label  = category[1]
        local tokens = category[2]
        table.insert(items, {
            text     = "\xE2\x94\x80\xE2\x94\x80 " .. label .. " \xE2\x94\x80\xE2\x94\x80",
            dim      = true,
            callback = function() end,
        })
        for _, token_entry in ipairs(tokens) do
            table.insert(items, {
                text         = token_entry[1] .. "  " .. token_entry[2],
                insert_value = token_entry[1],
            })
        end
    end
    local menu
    menu = Menu:new{
        title          = _("Insert token"),
        item_table     = items,
        width          = math.floor(Screen:getWidth()  * 0.8),
        height         = math.floor(Screen:getHeight() * 0.8),
        items_per_page = 14,
        onMenuChoice   = function(_, item)
            if item.insert_value then
                UIManager:close(menu)
                on_select(item.insert_value)
            end
        end,
    }
    UIManager:show(menu, nil, nil,
        math.floor((Screen:getWidth()  - menu.dimen.w) / 2),
        math.floor((Screen:getHeight() - menu.dimen.h) / 2))
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

function Bookends:buildFontMenu(get_current, on_select)
    local cre      = require("document/credocument"):engineInit()
    local FontList = require("fontlist")
    local menu     = {}
    for _, face_name in ipairs(cre.getFontFaces()) do
        local ff, fi = cre.getFontFaceFilenameAndFaceIndex(face_name)
        if not ff then ff, fi = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true) end
        if ff then
            local dn = FontList:getLocalizedFontName(ff, fi) or face_name
            table.insert(menu, {
                text         = dn,
                checked_func = function() return get_current() == ff end,
                callback     = function() on_select(ff) end,
            })
        end
    end
    return menu
end

function Bookends:showSpinner(title, value, min, max, default, on_set)
    UIManager:show(SpinWidget:new{
        value         = value,
        value_min     = min,
        value_max     = max,
        default_value = default,
        title_text    = title,
        ok_text       = _("Set"),
        callback      = function(spin) on_set(spin.value) end,
    })
end

return Bookends