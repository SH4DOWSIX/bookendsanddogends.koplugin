local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

-- ─── Bar sentinel helpers ─────────────────────────────────────────────────────
-- %bar_book and %bar_chapter are expanded into opaque sentinel strings that
-- overlay_widget.lua later renders as BarWidgets. They MUST be substituted
-- before the single-char %b/%B tokens to avoid the leading %b being consumed.
--
-- Sentinel format (self-contained, terminated by :END):
--   BARBOOK:<pct>;<ticks>:END
--   BARCHAPTER:<pct>:END

function Tokens.isBarSentinel(s)
    return type(s) == "string" and
        (s:match("^BARBOOK:[0-9.]+;[0-9.,]*:END$") or
         s:match("^BARCHAPTER:[0-9.]+:END$")) ~= nil
end

function Tokens.lineHasBar(s)
    return type(s) == "string" and
        (s:match("BARBOOK:[0-9.]+;[0-9.,]*:END") or
         s:match("BARCHAPTER:[0-9.]+:END")) ~= nil
end

function Tokens.decodeBar(s)
    local pct, tick_str = s:match("^BARBOOK:([0-9.]+);([0-9.,]*):END$")
    if pct then
        local ticks = {}
        if tick_str and tick_str ~= "" then
            for t in tick_str:gmatch("[0-9.]+") do
                local v = tonumber(t)
                if v then table.insert(ticks, v) end
            end
        end
        return { kind = "book", pct = tonumber(pct), ticks = ticks }
    end
    local pct2 = s:match("^BARCHAPTER:([0-9.]+):END$")
    if pct2 then
        return { kind = "chapter", pct = tonumber(pct2), ticks = {} }
    end
    return nil
end

function Tokens.splitLineSegments(line)
    local segments  = {}
    local remaining = line

    while true do
        local best_start, best_end, best_match = nil, nil, nil
        for _, p in ipairs({
            "BARBOOK:[0-9.]+;[0-9.,]*:END",
            "BARCHAPTER:[0-9.]+:END",
        }) do
            local s, e = remaining:find(p)
            if s and (best_start == nil or s < best_start) then
                best_start = s
                best_end   = e
                best_match = remaining:sub(s, e)
            end
        end

        if not best_start then
            table.insert(segments, { kind = "text", text = remaining })
            break
        end

        local pre = remaining:sub(1, best_start - 1)
        table.insert(segments, { kind = "text", text = pre })

        local info = Tokens.decodeBar(best_match)
        table.insert(segments, { kind = "bar", info = info })

        remaining = remaining:sub(best_end + 1)
    end

    return segments
end

-- ─── Main expand ─────────────────────────────────────────────────────────────

function Tokens.expand(format_str, ui, session_start_time, session_pages_read, preview_mode)
    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    -- Helper: check if any of the given tokens appear in the format string.
    -- Handles both single-char (%x) and multi-char (%Xy) tokens.
	local function needs(...)
		for i = 1, select("#", ...) do
			local tok = select(i, ...)
			if format_str:find("%" .. tok, 1, true) then
				return true
			end
		end
		return false
	end

    local pageno = ui.view.state.page
    local doc    = ui.document

    -- ── Page numbers (respects hidden flows + pagemap) ──
    local currentpage = ""
    local totalpages  = ""
    if needs("c", "t", "p", "L", "bar_book") then
        if ui.pagemap and ui.pagemap:wantsPageLabels() then
            currentpage = ui.pagemap:getCurrentPageLabel(true) or ""
            totalpages  = ui.pagemap:getLastPageLabel(true)    or ""
        elseif pageno and doc:hasHiddenFlows() then
            currentpage = doc:getPageNumberInFlow(pageno)
            local flow  = doc:getPageFlow(pageno)
            totalpages  = doc:getTotalPagesInFlow(flow)
        else
            currentpage = pageno or 0
            totalpages  = doc:getPageCount()
        end
    end

    -- ── Book progress fraction (for bar) ──
    local book_pct_raw = 0
    if needs("p", "bar_book") then
        if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
            book_pct_raw = math.max(0, math.min(1, currentpage / totalpages))
        end
    end

    -- ── Book percentage text token ──
    local percent = ""
    if needs("p") then
        if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
            percent = math.floor(currentpage / totalpages * 100) .. "%"
        end
    end

    -- ── Pages left in book ──
    local pages_left_book = ""
    if needs("L") and pageno then
        local left = doc:getTotalPagesLeft(pageno)
        if left then pages_left_book = left end
    end

    -- ── Chapter tick marks (fractions of book, for bar_book) ──
    local chapter_ticks = {}
    if needs("bar_book") and ui.toc and type(totalpages) == "number" and totalpages > 0 then
        local ok, ticks = pcall(function()
            return ui.toc:getTocTicksFlattened()
        end)
        if ok and ticks then
            if pageno and doc:hasHiddenFlows() then
                local flow       = doc:getPageFlow(pageno)
                local flow_total = doc:getTotalPagesInFlow(flow)
                for _, page in ipairs(ticks) do
                    if doc:getPageFlow(page) == flow and flow_total > 0 then
                        table.insert(chapter_ticks,
                            doc:getPageNumberInFlow(page) / flow_total)
                    end
                end
            else
                for _, page in ipairs(ticks) do
                    table.insert(chapter_ticks, page / totalpages)
                end
            end
        end
    end

    -- ── Chapter progress ──
    local chapter_pct         = ""
    local chapter_pct_raw     = 0
    local chapter_pages_done  = ""
    local chapter_pages_left  = ""
    local chapter_total_pages = ""
    local chapter_title       = ""
    if needs("P", "g", "G", "l", "C", "bar_chapter") and pageno and ui.toc then
        local done  = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done  = done + 1
            chapter_total_pages = total
            chapter_pct         = math.floor(chapter_pages_done / total * 100) .. "%"
            chapter_pct_raw     = math.max(0, math.min(1, chapter_pages_done / total))
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then chapter_pages_left = left end
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then chapter_title = title end
    end

    -- ── Session pages read ──
    local session_pages = math.max(0, session_pages_read or 0)

    -- ── Time left in chapter / book ──
    local time_left_chapter = ""
    local time_left_doc     = ""
    if needs("h", "H") and pageno and ui.statistics and ui.statistics.getTimeForPages then
        if needs("h") then
            local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
            if not ch_left then ch_left = doc:getTotalPagesLeft(pageno) end
            if ch_left then
                local result = ui.statistics:getTimeForPages(ch_left)
                if result and result ~= "N/A" then time_left_chapter = result end
            end
        end
        if needs("H") then
            local doc_left = doc:getTotalPagesLeft(pageno)
            if doc_left then
                local result = ui.statistics:getTimeForPages(doc_left)
                if result and result ~= "N/A" then time_left_doc = result end
            end
        end
    end

    -- ── Clock ──
    local time_12h = ""
    local time_24h = ""
    if needs("k") then time_12h = os.date("%I:%M %p"):gsub("^0", "") end
    if needs("K") then time_24h = os.date("%H:%M") end

    -- ── Dates ──
    local date_short         = ""
    local date_long          = ""
    local date_num           = ""
    local date_weekday       = ""
    local date_weekday_short = ""
    if needs("d", "D", "n", "w", "a") then
        if needs("d") then date_short         = os.date("%d %b")      end
        if needs("D") then date_long          = os.date("%d %B %Y")   end
        if needs("n") then date_num           = os.date("%d/%m/%Y")   end
        if needs("w") then date_weekday       = os.date("%A")         end
        if needs("a") then date_weekday_short = os.date("%a")         end
    end

    -- ── Session reading time ──
    local session_time = ""
    if needs("R") and session_start_time then
        local elapsed = os.time() - session_start_time
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, elapsed, true)
    end

    -- ── Document metadata ──
    local title   = ""
    local authors = ""
    local series  = ""
    if needs("T", "A", "S") then
        local doc_props    = ui.doc_props or {}
        local ok, props    = pcall(doc.getProps, doc)
        if not ok then props = {} end
        title   = doc_props.display_title or props.title   or ""
        authors = doc_props.authors        or props.authors or ""
        series  = doc_props.series         or props.series  or ""
        local series_index = doc_props.series_index or props.series_index
        if series ~= "" and series_index then
            series = series .. " #" .. series_index
        end
    end

    -- ── Battery ──
    local batt_lvl    = ""
    local batt_symbol = ""
    if needs("b", "B") then
        local powerd  = Device:getPowerDevice()
        local capacity = powerd:getCapacity()
        if capacity then
            batt_symbol = powerd:getBatterySymbol(
                powerd:isCharged(), powerd:isCharging(), capacity) or ""
            batt_lvl = capacity .. "%"
        end
    end

    -- ── Frontlight brightness (%Fl) ──
    local frontlight_lvl = ""
    if needs("Fl") then
        if Device:hasFrontlight() then
            local powerd = Device:getPowerDevice()
            if powerd:isFrontlightOn() then
                local intensity = powerd:frontlightIntensity()
                if intensity and intensity > 0 then
                    frontlight_lvl = intensity .. "%"
                else
                    frontlight_lvl = "Off"
                end
            else
                frontlight_lvl = "Off"
            end
        end
    end

    -- ── Frontlight warmth (%Fw) ──
    local frontlight_warmth = ""
    if needs("Fw") then
        if Device:hasNaturalLight() then
            local powerd = Device:getPowerDevice()
            if powerd:isFrontlightOn() then
                local warmth = powerd:frontlightWarmth()
                if warmth and warmth > 0 then
                    frontlight_warmth = warmth .. "%"
                else
                    frontlight_warmth = "Off"
                end
            else
                frontlight_warmth = "Off"
            end
        end
    end

    -- ── Wi-Fi ──
    local wifi_symbol = ""
    if needs("W") then
        local NetworkMgr = require("ui/network/manager")
        wifi_symbol = NetworkMgr:isWifiOn()
            and "\xEE\xB2\xA8"   -- U+ECA8 wifi on
            or  "\xEE\xB2\xA9"   -- U+ECA9 wifi off
    end

    -- ── Memory usage ──
    local mem_usage = ""
    if needs("m") then
        local meminfo = io.open("/proc/meminfo", "r")
        if meminfo then
            local total, available
            for line in meminfo:lines() do
                if line:match("^MemTotal:")     then total     = tonumber(line:match("(%d+)")) end
                if line:match("^MemAvailable:") then available = tonumber(line:match("(%d+)")) end
                if total and available then break end
            end
            meminfo:close()
            if total and available and total > 0 then
                mem_usage = math.floor((total - available) / total * 100) .. "%"
            end
        end
    end

    -- ── Preview mode: override all values with descriptive labels ──
    if preview_mode then
        local replace = {
            ["%c"]  = "[page]",       ["%t"]  = "[total]",      ["%p"]  = "[%]",
            ["%P"]  = "[ch%]",        ["%g"]  = "[ch.read]",    ["%G"]  = "[ch.total]",
            ["%l"]  = "[ch.left]",    ["%L"]  = "[left]",
            ["%h"]  = "[ch.time]",    ["%H"]  = "[time]",
            ["%k"]  = "[12h]",        ["%K"]  = "[24h]",
            ["%d"]  = "[date]",       ["%D"]  = "[date.long]",
            ["%n"]  = "[dd/mm/yy]",   ["%w"]  = "[weekday]",    ["%a"]  = "[wkday]",
            ["%R"]  = "[session]",    ["%s"]  = "[pages]",
            ["%T"]  = "[title]",      ["%A"]  = "[author]",
            ["%S"]  = "[series]",     ["%C"]  = "[chapter]",
            ["%b"]  = "[batt]",       ["%B"]  = "[batt]",       ["%W"]  = "[wifi]",
            ["%m"]  = "[mem]",
            ["%Fl"] = "[brightness]",
            ["%Fw"] = "[warmth]",
        }
        local result = format_str:gsub("%%bar_chapter", "[ch. bar]")
        result = result:gsub("%%bar_book", "[book bar]")
        -- Multi-char tokens first, then single-char
        result = result:gsub("(%%%u%l)", replace)
        result = result:gsub("(%%%a)",   replace)
        return result
    end

    -- ── Live substitution table ──
    local replace = {
        -- Page/Progress
        ["%c"] = tostring(currentpage),
        ["%t"] = tostring(totalpages),
        ["%p"] = tostring(percent),
        ["%P"] = tostring(chapter_pct),
        ["%g"] = tostring(chapter_pages_done),
        ["%G"] = tostring(chapter_total_pages),
        ["%l"] = tostring(chapter_pages_left),
        ["%L"] = tostring(pages_left_book),
        -- Time/Reading
        ["%h"] = tostring(time_left_chapter),
        ["%H"] = tostring(time_left_doc),
        ["%k"] = time_12h,
        ["%K"] = time_24h,
        ["%d"] = date_short,
        ["%D"] = date_long,
        ["%n"] = date_num,
        ["%w"] = date_weekday,
        ["%a"] = date_weekday_short,
        ["%R"] = session_time,
        ["%s"] = tostring(session_pages),
        -- Metadata
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%C"] = tostring(chapter_title),
        -- Device
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
        ["%W"] = wifi_symbol,
        ["%m"] = tostring(mem_usage),
        -- Frontlight
        ["%Fl"] = tostring(frontlight_lvl),
        ["%Fw"] = tostring(frontlight_warmth),
    }

    -- !! Bar tokens MUST come before single-char substitution so that
    -- %bar_book/%bar_chapter are not consumed by the %b battery token.
    local tick_str = table.concat(chapter_ticks, ",")
    local result = format_str:gsub("%%bar_chapter",
        string.format("BARCHAPTER:%.6f:END", chapter_pct_raw))
    result = result:gsub("%%bar_book",
        string.format("BARBOOK:%.6f;%s:END", book_pct_raw, tick_str))

    -- Multi-char tokens first (%Fl, %Fw), then single-char (%%%a)
    result = result:gsub("(%%%u%l)", replace)
    result = result:gsub("(%%%a)",   replace)
    return result
end

function Tokens.expandPreview(format_str, ui, session_start_time, session_pages_read)
    return Tokens.expand(format_str, ui, session_start_time, session_pages_read, true)
end

return Tokens