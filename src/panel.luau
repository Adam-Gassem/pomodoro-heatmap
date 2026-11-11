--!nonstrict
-- FocusFlow - panel: timer controls + insights (heatmap, trends, rhythms).

local tab = "timer" -- "timer" | "insights"
local isOpen = false

local PHASE = {
    work = { name = "Focus", glyph = "brain", color = "primary" },
    short = { name = "Short break", glyph = "coffee", color = "tertiary" },
    long = { name = "Long break", glyph = "armchair", color = "tertiary" },
}

-- Heat levels: none, 1..4 (4 = daily goal reached, or the busiest day if no goal)
local HEAT = { [0] = "on_surface/0.07", "primary/0.28", "primary/0.48", "primary/0.72", "primary" }
local CELL, GAP = 11, 2
local DAY_LABELS = { "Mon", "", "Wed", "", "Fri", "", "" }
local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

local nonce = 0
local function send(cmd)
    nonce += 1
    noctalia.state.set("focusflow.cmd", { cmd = cmd, n = nonce .. ":" .. noctalia.nowMs() })
end

-- ------------------------------------------------------------------ helpers

local function clock(sec)
    sec = math.max(0, sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function duration(min)
    min = math.floor(min or 0)
    if min < 60 then return string.format("%dm", min) end
    local h, m = math.floor(min / 60), min % 60
    if m == 0 then return string.format("%dh", h) end
    return string.format("%dh %02dm", h, m)
end

local function plural(n, word)
    return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function muted(text, size)
    return ui.label({ text = text, fontSize = size or 11, color = "on_surface_variant" })
end

local function card(props, children)
    props.fill = props.fill or "surface_container"
    props.radius = props.radius or 14
    props.padding = props.padding or 14
    props.gap = props.gap or 10
    return ui.column(props, children)
end

local function sectionTitle(glyph, title, sub)
    local row = {
        ui.glyph({ name = glyph, size = 15, color = "primary" }),
        ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }
    if sub then table.insert(row, muted(sub)) end
    return ui.row({ gap = 8, align = "center" }, row)
end

-- ------------------------------------------------------------------ header

local function tabButton(id, text, glyph)
    return ui.button({
        text = text,
        glyph = glyph,
        variant = tab == id and "secondary" or "ghost",
        height = 30,
        onClick = function()
            if tab ~= id then
                tab = id
                if id == "insights" then send("refresh-stats") end
                render()
            end
        end,
    })
end

local function header(t)
    local p = PHASE[t and t.phase or "work"] or PHASE.work
    return ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = p.glyph, size = 18, color = p.color }),
        ui.label({ text = "FocusFlow", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        tabButton("timer", "Timer", "hourglass"),
        tabButton("insights", "Insights", "chart-bar"),
    })
end

-- ------------------------------------------------------------------ timer tab

local function roundDots(t)
    local dots = {}
    for i = 1, t.rounds do
        local fill = "on_surface/0.14"
        if i < t.round or (i == t.round and t.phase ~= "work") then
            fill = "primary"
        elseif i == t.round then
            fill = t.status == "running" and "primary/0.55" or "primary/0.35"
        end
        table.insert(dots, ui.box({ width = i == t.round and 18 or 8, height = 8, radius = 4, fill = fill }))
    end
    return ui.row({ gap = 6, align = "center", justify = "center" }, dots)
end

local function timerHero(t)
    local p = PHASE[t.phase] or PHASE.work
    local active = t.status ~= "idle"
    local progress = (t.total or 0) > 0 and (1 - t.remaining / t.total) or 0
    local stateText = t.status == "paused" and "Paused" or (t.status == "running" and "In progress" or "Ready")
    local accent = t.status == "paused" and "on_surface_variant" or p.color

    return card({ padding = 20, gap = 14, align = "stretch" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.box({ width = 8, height = 8, radius = 4, fill = accent }),
            ui.label({ text = p.name, fontSize = 13, fontWeight = "bold", color = accent, flexGrow = 1 }),
            muted(t.phase == "work" and string.format("Round %d / %d", t.round, t.rounds) or stateText, 12),
        }),
        ui.column({ align = "center", gap = 2 }, {
            ui.label({
                text = clock(t.remaining),
                fontSize = 58,
                fontWeight = "bold",
                fontFamily = "monospace",
                color = active and accent or "on_surface",
                textAlign = "center",
            }),
            muted(t.phase == "work" and stateText or "Step away from the screen", 12),
        }),
        ui.progress({ progress = progress, height = 6, radius = 3, fill = accent, track = "on_surface/0.1" }),
        roundDots(t),
    })
end

local function controls(t)
    local running = t.status == "running"
    local primaryText = running and "Pause" or (t.status == "paused" and "Resume" or "Start")
    local active = t.status ~= "idle"
    local row1 = ui.row({ gap = 8, align = "center" }, {
        ui.button({ glyph = "minus", variant = "outline", width = 44, height = 44, enabled = active,
            onClick = function() send("minus") end }),
        ui.button({ text = primaryText, glyph = running and "player-pause" or "player-play", variant = "primary",
            height = 44, flexGrow = 1, onClick = function() send("toggle") end }),
        ui.button({ glyph = "plus", variant = "outline", width = 44, height = 44, enabled = active,
            onClick = function() send("plus") end }),
    })
    local row2 = {
        ui.button({ text = "Skip", glyph = "player-skip-forward", variant = "ghost", height = 32, flexGrow = 1,
            onClick = function() send("skip") end }),
        ui.button({ text = "Restart", glyph = "refresh", variant = "ghost", height = 32, flexGrow = 1,
            enabled = active, onClick = function() send("reset") end }),
        ui.button({ text = "New cycle", glyph = "player-stop", variant = "ghost", height = 32, flexGrow = 1,
            enabled = active or t.round > 1 or t.phase ~= "work", onClick = function() send("stop") end }),
    }
    if t.phase ~= "work" then
        row2[1] = ui.button({ text = "Focus now", glyph = "brain", variant = "ghost", height = 32, flexGrow = 1,
            onClick = function() send("focus") end })
    end
    return ui.column({ gap = 6 }, { row1, ui.row({ gap = 4 }, row2) })
end

local function miniWeek(s)
    local bars = {}
    local peak = 1
    for i = 8, 14 do peak = math.max(peak, s.recent[i].min) end
    if (s.goal or 0) > 0 then peak = math.max(peak, s.goal) end
    for i = 8, 14 do
        local d = s.recent[i]
        local h = d.min > 0 and math.max(3, math.floor(40 * d.min / peak)) or 3
        table.insert(bars, ui.column({ flexGrow = 1, gap = 4, align = "center",
            tooltip = string.format("%s\n%s · %s", d.label, duration(d.min), plural(d.count, "session")) }, {
            ui.column({ height = 40, justify = "end", align = "stretch", width = 18 }, {
                ui.box({ height = h, radius = 3,
                    fill = i == 14 and "primary" or (d.min > 0 and "primary/0.45" or "on_surface/0.1") }),
            }),
            ui.label({ text = d.short, fontSize = 10, color = i == 14 and "primary" or "on_surface_variant" }),
        }))
    end
    return ui.row({ gap = 4 }, bars)
end

local function todayCard(s)
    local goal = s.goal or 0
    local children = {
        sectionTitle("target", "Today", goal > 0 and string.format("Goal %s", duration(goal)) or nil),
    }
    local big = ui.row({ align = "end", gap = 8 }, {
        ui.label({ text = duration(s.today.min), fontSize = 26, fontWeight = "bold", color = "on_surface" }),
        ui.column({ paddingV = 5 }, {
            muted(goal > 0 and string.format("%d%% of goal", math.floor(100 * s.today.min / goal)) or "focused", 12),
        }),
    })
    table.insert(children, big)
    if goal > 0 then
        table.insert(children, ui.progress({ progress = math.min(1, s.today.min / goal), height = 4, radius = 2,
            fill = s.today.min >= goal and "tertiary" or "primary", track = "on_surface/0.1" }))
    end
    table.insert(children, ui.row({ gap = 16 }, {
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "brain", size = 13, color = "on_surface_variant" }),
            muted(plural(s.today.count, "session"), 12) }),
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "flame", size = 13,
            color = s.streak > 0 and "tertiary" or "on_surface_variant" }), muted(plural(s.streak, "day") .. " streak", 12) }),
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "calendar-stats", size = 13, color = "on_surface_variant" }),
            muted(duration(s.week.min) .. " this week", 12) }),
    }))
    table.insert(children, miniWeek(s))
    return card({}, children)
end

local function timerTab(t, s)
    local children = { timerHero(t), controls(t) }
    if s then table.insert(children, todayCard(s)) end
    return ui.column({ gap = 12, flexGrow = 1 }, children)
end

-- ------------------------------------------------------------------ insights tab

local function kpi(glyph, label, value, sub, subColor)
    return card({ flexGrow = 1, gap = 4, padding = 12 }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = glyph, size = 13, color = "on_surface_variant" }),
            muted(label),
        }),
        ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = sub or " ", fontSize = 11, color = subColor or "on_surface_variant", maxLines = 1 }),
    })
end

local function kpis(s)
    local delta = s.week.min - s.week.prevMin
    local deltaText, deltaColor
    if s.week.prevMin == 0 and s.week.min == 0 then
        deltaText = "no focus yet"
    elseif s.week.prevMin == 0 then
        deltaText, deltaColor = "new this week", "primary"
    else
        local pct = math.floor(100 * delta / s.week.prevMin + 0.5)
        deltaText = string.format("%s%d%% vs prior 7d", pct >= 0 and "+" or "", pct)
        deltaColor = pct >= 0 and "primary" or "error"
    end
    local goalSub = s.goal > 0 and string.format("%d%% of %s goal", math.floor(100 * s.today.min / s.goal), duration(s.goal))
        or plural(s.today.count, "session")
    return ui.column({ gap = 8 }, {
        ui.row({ gap = 8 }, {
            kpi("target", "Today", duration(s.today.min), goalSub, s.goal > 0 and s.today.min >= s.goal and "tertiary" or nil),
            kpi("calendar-stats", "Last 7 days", duration(s.week.min), deltaText, deltaColor),
        }),
        ui.row({ gap = 8 }, {
            kpi("flame", "Streak", plural(s.streak, "day"), string.format("best %s", plural(s.bestStreak, "day"))),
            kpi("trophy", "All time", duration(s.total.min), string.format("%s · %s", plural(s.total.count, "session"),
                plural(s.total.days, "day"))),
        }),
    })
end

local function heatmap(s)
    local hm = s.heatmap
    -- Month labels, each spanning the columns until the next label.
    local monthRow = { ui.box({ width = 24 - GAP, height = 1, fill = "on_surface/0" }) }
    local w = 1
    while w <= hm.weeks do
        local span = 1
        while w + span <= hm.weeks and hm.months[w + span] == "" do span += 1 end
        local text = hm.months[w]
        if span < 2 then text = "" end -- not enough room for a label
        table.insert(monthRow, ui.column({ width = span * CELL + (span - 1) * GAP }, {
            ui.label({ text = text, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
        }))
        w += span
    end

    local rows = { ui.row({ gap = GAP }, monthRow) }
    for wd = 1, 7 do
        local cells = { ui.column({ width = 24 - GAP, justify = "center", height = CELL }, {
            ui.label({ text = DAY_LABELS[wd], fontSize = 9, color = "on_surface_variant" }),
        }) }
        for col = 1, hm.weeks do
            local c = hm.columns[col][wd]
            if c.level < 0 then
                table.insert(cells, ui.box({ width = CELL, height = CELL, fill = "on_surface/0" }))
            else
                local tip = c.min > 0
                    and string.format("%s\n%s · %s", c.label, duration(c.min), plural(c.count, "session"))
                    or string.format("%s\nNo focus logged", c.label)
                table.insert(cells, ui.column({
                    key = c.date, width = CELL, height = CELL, radius = 3, fill = HEAT[c.level],
                    border = c.today and "on_surface" or nil, borderWidth = c.today and 1 or nil,
                    tooltip = tip,
                }, {}))
            end
        end
        table.insert(rows, ui.row({ gap = GAP }, cells))
    end

    local legend = { muted("Less", 10) }
    for l = 0, 4 do table.insert(legend, ui.box({ width = 10, height = 10, radius = 2, fill = HEAT[l] })) end
    table.insert(legend, muted("More", 10))

    return card({}, {
        sectionTitle("calendar-stats", "Focus heatmap",
            string.format("%s · %s", plural(hm.activeDays, "active day"), duration(hm.rangeMin))),
        ui.column({ gap = GAP, align = "center" }, rows),
        ui.row({ gap = 4, align = "center" }, {
            muted(hm.useGoal and "Full color = daily goal met" or "Relative to your best day", 10),
            ui.spacer({ flexGrow = 1 }),
            table.unpack(legend),
        }),
    })
end

local function barChart(values, opts)
    local peak = 1
    for _, v in ipairs(values) do peak = math.max(peak, v.value) end
    local bars = {}
    for i, v in ipairs(values) do
        local h = v.value > 0 and math.max(3, math.floor(opts.height * v.value / peak)) or 2
        table.insert(bars, ui.column({ flexGrow = 1, height = opts.height, justify = "end", align = "stretch",
            tooltip = v.tip }, {
            ui.box({ height = h, radius = opts.radius or 3,
                fill = v.highlight and "primary" or (v.value > 0 and "primary/0.5" or "on_surface/0.08") }),
        }))
    end
    local labels = {}
    for _, v in ipairs(values) do
        table.insert(labels, ui.column({ flexGrow = 1, align = "center" }, {
            ui.label({ text = v.axis or "", fontSize = 9, color = v.highlight and "primary" or "on_surface_variant" }),
        }))
    end
    return ui.column({ gap = 4 }, { ui.row({ gap = opts.gap or 4 }, bars), ui.row({ gap = opts.gap or 4 }, labels) })
end

local function recentChart(s)
    local values = {}
    local sum = 0
    for i, d in ipairs(s.recent) do
        sum += d.min
        table.insert(values, {
            value = d.min, axis = d.short, highlight = i == #s.recent,
            tip = string.format("%s\n%s · %s", d.label, duration(d.min), plural(d.count, "session")),
        })
    end
    return card({}, {
        sectionTitle("chart-bar", "Last 14 days", string.format("avg %s / day", duration(sum / 14))),
        barChart(values, { height = 72, gap = 5 }),
    })
end

local function hoursChart(s)
    local values = {}
    local nowHour = tonumber(os.date("%H")) or 0
    for h = 0, 23 do
        table.insert(values, {
            value = s.hours[h + 1],
            axis = (h % 6 == 0) and string.format("%02d", h) or "",
            highlight = h == s.peakHour,
            tip = string.format("%02d:00 – %02d:00\n%s total", h, (h + 1) % 24, duration(s.hours[h + 1])),
        })
    end
    local sub = s.peakHour and string.format("peak %02d:00", s.peakHour) or nil
    return card({}, {
        sectionTitle("clock", "Time of day", sub),
        barChart(values, { height = 52, gap = 2, radius = 2 }),
    })
end

local function weekdayChart(s)
    local peak = 1
    for i = 1, 7 do peak = math.max(peak, s.weekdays[i]) end
    local rows = {}
    for i = 1, 7 do
        local v = s.weekdays[i]
        local ratio = v / peak
        table.insert(rows, ui.row({ gap = 8, align = "center" }, {
            ui.column({ width = 30 }, { ui.label({ text = WEEKDAYS[i], fontSize = 11, color = "on_surface_variant" }) }),
            ui.row({ flexGrow = 1, height = 8, radius = 4, fill = "on_surface/0.07" }, {
                ui.box({ flexGrow = math.max(ratio, 0.0001), height = 8, radius = 4,
                    fill = v == peak and v > 0 and "primary" or "primary/0.5" }),
                ui.box({ flexGrow = math.max(1 - ratio, 0.0001), height = 8, fill = "on_surface/0" }),
            }),
            ui.column({ width = 56, align = "end" }, { ui.label({ text = duration(v), fontSize = 11, color = "on_surface" }) }),
        }))
    end
    return card({}, { sectionTitle("chart-histogram", "By weekday", "all time"), ui.column({ gap = 6 }, rows) })
end

local function facts(s)
    local items = {}
    local function fact(glyph, text)
        table.insert(items, ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, size = 13, color = "primary" }),
            ui.label({ text = text, fontSize = 12, color = "on_surface", flexGrow = 1 }),
        }))
    end
    if s.bestDay then fact("trophy", string.format("Best day: %s on %s", duration(s.bestDay.min), s.bestDay.date)) end
    if s.total.days > 0 then fact("chart-dots", string.format("Average: %s per active day", duration(s.total.min / s.total.days))) end
    if s.completion then
        fact("target", string.format("Completion rate: %d%% (%s interrupted)", math.floor(100 * s.completion + 0.5),
            plural(s.total.partial, "session")))
    end
    if #items == 0 then
        fact("brain", "Finish your first focus session to start building insights.")
    end
    return card({ gap = 8 }, items)
end

local function insightsTab(s)
    if not s then
        return ui.column({ flexGrow = 1, align = "center", justify = "center" }, { muted("Loading…", 13) })
    end
    return ui.scroll({ key = "insights-scroll", flexGrow = 1, gap = 12 }, {
        kpis(s),
        heatmap(s),
        recentChart(s),
        hoursChart(s),
        weekdayChart(s),
        facts(s),
    })
end

-- ------------------------------------------------------------------ render

function render()
    local t = noctalia.state.get("focusflow.timer")
    local s = noctalia.state.get("focusflow.stats")
    local body
    if not t then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "brain", size = 28, color = "primary" }),
            muted("Starting the FocusFlow engine…", 13),
        })
    elseif tab == "insights" then
        body = insightsTab(s)
    else
        body = timerTab(t, s)
    end
    panel.render(ui.column({ flexGrow = 1, gap = 14 }, { header(t), body }))
end

function onOpen(context)
    isOpen = true
    if context == "insights" or context == "timer" then tab = context end
    render()
end

function onClose()
    isOpen = false
end

noctalia.state.watch("focusflow.timer", function()
    -- The insights view doesn't depend on the ticking clock; skip per-second redraws there.
    if isOpen and tab == "timer" then render() end
end)

noctalia.state.watch("focusflow.stats", function()
    if isOpen then render() end
end)

render()
