local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Screen = Device.screen
local Tokens = require("tokens")

local OverlayWidget = {}

local function textWidgetOpts(t)
    t.use_book_text_color = true
    return t
end

-- ─── BarWidget ────────────────────────────────────────────────────────────────

local BarWidget = {}
BarWidget.__index = BarWidget

function BarWidget:new(o)
    return setmetatable(o or {}, self)
end

function BarWidget:paintTo(bb, x, y)
    local w          = self.width
    local h          = self.height
    local pct        = math.max(0, math.min(1, self.percentage or 0))
    local ticks      = self.ticks or {}
    local Blitbuffer = require("ffi/blitbuffer")

    local border  = 2
    local radius  = self.radius or 2
    local padding = 4

    if radius > 0 then
        bb:paintRoundedRect(x, y, w, h,
            self.bgcolor or Blitbuffer.COLOR_WHITE, radius)
        bb:paintBorder(x, y, w, h, border,
            self.bordercolor or Blitbuffer.COLOR_BLACK, radius)
    else
        bb:paintRect(x, y, w, h,
            self.bordercolor or Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + border, y + border,
            w - 2*border, h - 2*border,
            self.bgcolor or Blitbuffer.COLOR_WHITE)
    end

    local inset   = border + padding
    local inner_w = w - 2*inset
    local inner_h = h - 2*inset
    local ix      = x + inset
    local iy      = y + inset

    local fill_w = math.max(0, math.ceil(inner_w * pct))
    if fill_w > 0 then
        bb:paintRect(ix, iy, fill_w, inner_h,
            self.fillcolor or Blitbuffer.COLOR_DARK_GRAY)
    end

    local tick_inset   = 1
    local tick_inner_w = w - 2*tick_inset
    local tick_inner_h = h - 2*tick_inset
    local tix          = x + tick_inset
    local tiy          = y + tick_inset

    local tick_w     = 1
    local tick_color = self.tick_color or Blitbuffer.COLOR_BLACK
    for _, frac in ipairs(ticks) do
        if frac > 0 and frac < 1 then
            local tx = tix + math.floor(tick_inner_w * frac) - math.floor(tick_w / 2)
            tx = math.max(tix, math.min(tx, tix + tick_inner_w - tick_w))
            bb:paintRect(tx, tiy, tick_w, tick_inner_h, tick_color)
        end
    end
end

function BarWidget:getSize()
    return { w = self.width, h = self.height }
end

function BarWidget:free() end

-- ─── HorizontalRowWidget ──────────────────────────────────────────────────────
-- Paints a list of segments (text or bar) left to right.
-- Each segment is vertically centred within the row height.

local HorizontalRowWidget = {}
HorizontalRowWidget.__index = HorizontalRowWidget

function HorizontalRowWidget:new(o)
    return setmetatable(o or {}, self)
end

function HorizontalRowWidget:paintTo(bb, x, y)
    local row_h    = self.height
    local x_cursor = x
    for _, seg in ipairs(self.segments) do
        local seg_y = y + math.floor((row_h - seg.h) / 2)
        seg.widget:paintTo(bb, x_cursor, seg_y)
        x_cursor = x_cursor + seg.w
    end
end

function HorizontalRowWidget:getSize()
    return { w = self.width, h = self.height }
end

function HorizontalRowWidget:free()
    for _, seg in ipairs(self.segments) do
        if seg.widget and seg.widget.free then
            seg.widget:free()
        end
    end
    self.segments = {}
end

-- ─── MultiLineWidget ──────────────────────────────────────────────────────────
-- Stacks rows vertically. Each row is either a TextWidget, BarWidget,
-- or HorizontalRowWidget.

local MultiLineWidget = {}
MultiLineWidget.__index = MultiLineWidget

function MultiLineWidget:new(o)
    return setmetatable(o or {}, self)
end

function MultiLineWidget:paintTo(bb, x, y)
    local y_cursor = 0
    for _, entry in ipairs(self.lines) do
        local lx = x + (entry.h_nudge or 0)
        if self.align == "center" then
            lx = x + math.floor((self.width - entry.w) / 2) + (entry.h_nudge or 0)
        elseif self.align == "right" then
            lx = x + self.width - entry.w + (entry.h_nudge or 0)
        end
        entry.widget:paintTo(bb, lx, y + y_cursor + (entry.v_nudge or 0))
        y_cursor = y_cursor + entry.h
    end
end

function MultiLineWidget:getSize()
    return { w = self.width, h = self.height }
end

function MultiLineWidget:free()
    for _, entry in ipairs(self.lines) do
        if entry.widget and entry.widget.free then
            entry.widget:free()
        end
    end
    self.lines = {}
end

-- ─── Internal helpers ─────────────────────────────────────────────────────────

local function splitLines(text)
    local lines = {}
    local s = text
    while true do
        local nl = s:find("\n", 1, true)
        if nl then
            table.insert(lines, s:sub(1, nl - 1))
            s = s:sub(nl + 1)
        else
            table.insert(lines, s)
            break
        end
    end
    return lines
end

local function buildBarWidget(info, bar_w, bar_h)
    bar_h = bar_h or 8
    bar_w = math.max(4, bar_w or Screen:getWidth())
    return BarWidget:new{
        width      = bar_w,
        height     = bar_h,
        percentage = info.pct,
        ticks      = info.ticks or {},
        tick_width = 1,
        bordersize = 2,
        radius     = 2,
    }
end

-- Build a HorizontalRowWidget from an ordered list of segments on one line.
-- segments: list of { kind="text", text=... } or { kind="bar", info=... }
-- cfg: line config (face, bold, bar_height, bar_manual_width)
-- full_available_w: uncapped slot width for auto bar width resolution
-- max_width: text truncation limit (nil = none)
-- screen_w: fallback
local function buildHorizontalRow(segments, cfg, full_available_w, max_width, screen_w)
    local bar_h = cfg.bar_height or 8

    -- First pass: build text widgets, identify auto-width bars
    local built          = {}
    local used_w         = 0
    local auto_bar_count = 0

    for _, seg in ipairs(segments) do
        if seg.kind == "text" and seg.text ~= "" then
            local tw = TextWidget:new(textWidgetOpts{
                text                   = seg.text,
                face                   = cfg.face,
                bold                   = cfg.bold,
                max_width              = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local sz = tw:getSize()
            table.insert(built, { kind = "text", widget = tw, w = sz.w, h = sz.h })
            used_w = used_w + sz.w
        elseif seg.kind == "bar" then
            local mw = cfg.bar_manual_width
            if mw and mw > 0 then
                -- Fixed width bar — build now
                local bw  = math.max(4, mw)
                local bar = buildBarWidget(seg.info, bw, bar_h)
                table.insert(built, { kind = "bar", widget = bar, w = bw, h = bar_h })
                used_w = used_w + bw
            else
                -- Auto width bar — placeholder, resolve after measuring text
                table.insert(built, { kind = "bar_auto", info = seg.info, w = 0, h = bar_h })
                auto_bar_count = auto_bar_count + 1
            end
        end
        -- empty text segments are skipped
    end

    -- Second pass: resolve auto-width bars equally from remaining space
    if auto_bar_count > 0 then
        local remaining = math.max(4,
            (full_available_w or screen_w or Screen:getWidth()) - used_w)
        local each = math.max(4, math.floor(remaining / auto_bar_count))
        for _, entry in ipairs(built) do
            if entry.kind == "bar_auto" then
                local bar    = buildBarWidget(entry.info, each, bar_h)
                entry.kind   = "bar"
                entry.widget = bar
                entry.w      = each
            end
        end
    end

    -- Compute row dimensions
    local total_w = 0
    local row_h   = 0
    for _, entry in ipairs(built) do
        total_w = total_w + entry.w
        if entry.h > row_h then row_h = entry.h end
    end

    if #built == 0 then return nil, 0, 0 end

    local row = HorizontalRowWidget:new{
        segments = built,
        width    = total_w,
        height   = row_h,
    }
    return row, total_w, row_h
end
-- ─── Public API ───────────────────────────────────────────────────────────────

--- Build a widget for a possibly multi-line, possibly bar-containing string.
--
-- @param text          expanded string (may contain bar sentinels)
-- @param line_configs  array of per-source-line configs
-- @param h_anchor      "left"|"center"|"right"
-- @param max_width     number|nil  text truncation cap
-- @param available_w   number|nil  slot width capped by overlap prevention
-- @param screen_w      number|nil  full uncapped slot width (for auto bar width)
function OverlayWidget.buildTextWidget(text, line_configs, h_anchor, max_width, available_w, screen_w)
    screen_w = screen_w or Screen:getWidth()

    local lines = splitLines(text)
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    if #lines == 0 then return nil, 0, 0 end

    local function getConfig(i)
        return line_configs[i] or line_configs[#line_configs]
               or { face = nil, bold = false, v_nudge = 0, h_nudge = 0,
                    bar_height = 8, bar_manual_width = nil }
    end

    local align = "center"
    if h_anchor == "left"  then align = "left"  end
    if h_anchor == "right" then align = "right" end

    -- Fast path: single plain text line
    if #lines == 1 and not Tokens.lineHasBar(lines[1]) then
        local cfg = getConfig(1)
        local tw  = TextWidget:new(textWidgetOpts{
            text                   = lines[1],
            face                   = cfg.face,
            bold                   = cfg.bold,
            max_width              = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        })
        local size = tw:getSize()
        return tw, size.w, size.h
    end

    -- Fast path: single bar-containing line
    if #lines == 1 then
        local cfg      = getConfig(1)
        local segments = Tokens.splitLineSegments(lines[1])
        local row, rw, rh = buildHorizontalRow(
            segments, cfg, screen_w, max_width, screen_w)
        return row, rw, rh
    end

    -- Multi-line: build each line, stack vertically
    local line_entries = {}
    local max_w        = 0
    local total_h      = 0

    for i, line in ipairs(lines) do
        local cfg = getConfig(i)

        if Tokens.lineHasBar(line) then
            local segments = Tokens.splitLineSegments(line)
            local row, rw, rh = buildHorizontalRow(
                segments, cfg, screen_w, max_width, screen_w)
            if row then
                table.insert(line_entries, {
                    widget  = row,
                    w       = rw,
                    h       = rh,
                    v_nudge = cfg.v_nudge or 0,
                    h_nudge = cfg.h_nudge or 0,
                })
                if rw > max_w then max_w = rw end
                total_h = total_h + rh
            end
        else
            local tw = TextWidget:new(textWidgetOpts{
                text                   = line,
                face                   = cfg.face,
                bold                   = cfg.bold,
                max_width              = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local sz = tw:getSize()
            table.insert(line_entries, {
                widget  = tw,
                w       = sz.w,
                h       = sz.h,
                v_nudge = cfg.v_nudge or 0,
                h_nudge = cfg.h_nudge or 0,
            })
            if sz.w > max_w then max_w = sz.w end
            total_h = total_h + sz.h
        end
    end

    if #line_entries == 0 then return nil, 0, 0 end

    local reported_w = math.max(max_w, 4)
    local mlw = MultiLineWidget:new{
        lines  = line_entries,
        width  = reported_w,
        height = total_h,
        align  = align,
    }
    return mlw, reported_w, total_h
end

--- Measure the pixel width of the widest text-only line (bars excluded).
-- Used by main.lua for overlap prevention measurements.
function OverlayWidget.measureTextWidth(text, line_configs)
    local max_w = 0
    local i     = 0
    for line in text:gmatch("([^\n]+)") do
        i = i + 1
        if not Tokens.lineHasBar(line) then
            local cfg = line_configs[i] or line_configs[#line_configs]
                        or { face = nil, bold = false }
            local tw = TextWidget:new(textWidgetOpts{
                text = line,
                face = cfg.face,
                bold = cfg.bold,
            })
            local w = tw:getSize().w
            tw:free()
            if w > max_w then max_w = w end
        end
    end
    return max_w
end

--- Calculate max_width for each position in a row, applying overlap prevention.
-- Center-first priority: center claims its natural width first, then sides
-- get whatever remains. This matches your version's simplified approach.
function OverlayWidget.calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset)
    local limits = { left = nil, center = nil, right = nil }

    if center_w then
        local center_max = math.max(0, screen_w - 2 * gap)
        if center_w > center_max then
            limits.center = center_max
            center_w      = center_max
        end
    end

    if center_w then
        local available_side = math.max(0, math.floor((screen_w - center_w) / 2) - gap)
        if left_w  and left_w  > available_side - h_offset then
            limits.left  = math.max(0, available_side - h_offset)
        end
        if right_w and right_w > available_side - h_offset then
            limits.right = math.max(0, available_side - h_offset)
        end
    else
        if left_w and right_w then
            local half = math.floor(screen_w / 2) - math.floor(gap / 2)
            if left_w  > half - h_offset then limits.left  = math.max(0, half - h_offset) end
            if right_w > half - h_offset then limits.right = math.max(0, half - h_offset) end
        end
        if left_w and not right_w then
            local max = math.max(0, screen_w - h_offset)
            if left_w  > max then limits.left  = max end
        end
        if right_w and not left_w then
            local max = math.max(0, screen_w - h_offset)
            if right_w > max then limits.right = max end
        end
    end

    return limits
end

--- Compute the (x, y) paint coordinates for a widget.
function OverlayWidget.computeCoordinates(h_anchor, v_anchor, text_w, text_h,
                                          screen_w, screen_h, v_offset, h_offset)
    local x, y
    if h_anchor == "left" then
        x = h_offset
    elseif h_anchor == "center" then
        x = math.floor((screen_w - text_w) / 2)
    else
        x = screen_w - text_w - h_offset
    end
    if v_anchor == "top" then
        y = v_offset
    else
        y = screen_h - text_h - v_offset
    end
    return x, y
end

--- Free all widgets in a cache table.
function OverlayWidget.freeWidgets(widget_cache)
    local keys = {}
    for key in pairs(widget_cache) do table.insert(keys, key) end
    for _, key in ipairs(keys) do
        local entry = widget_cache[key]
        if entry.widget and entry.widget.free then entry.widget:free() end
        widget_cache[key] = nil
    end
end

return OverlayWidget