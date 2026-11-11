--!nonstrict
-- Pomodoro Heatmap - pure analytics over the session log.
--
-- A session record is { s = startSec, e = endSec, d = focusedSec, c = completed }.
-- Everything is bucketed by the *local* calendar day of the session start.

local M = {}

M.HEATMAP_WEEKS = 26
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local DAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Local-midnight-safe day arithmetic: anchor on noon so DST shifts never
-- push a date across a day boundary.
local function noonOf(sec)
    local t = os.date("*t", sec)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
end

function M.dayKey(sec)
    return os.date("%Y-%m-%d", sec)
end

function M.shiftDays(sec, days)
    local t = os.date("*t", noonOf(sec))
    return os.time({ year = t.year, month = t.month, day = t.day + days, hour = 12 })
end

-- Monday = 1 ... Sunday = 7
function M.weekdayMon(sec)
    local wday = tonumber(os.date("%w", sec)) or 0 -- 0 = Sunday
    return wday == 0 and 7 or wday
end

-- Locale-independent labels (os.date's %a/%b follow LC_TIME).
function M.dayLabel(sec, withYear)
    local t = os.date("*t", sec)
    local s = string.format("%s %d %s", DAYS[M.weekdayMon(sec)], t.day, MONTHS[t.month])
    if withYear then s ..= " " .. t.year end
    return s
end

local function levelFor(minutes, goal, peak)
    if minutes <= 0 then return 0 end
    local ref = goal > 0 and goal or peak
    if ref <= 0 then return 1 end
    local ratio = minutes / ref
    if ratio >= 1 then return 4 end
    if ratio >= 0.66 then return 3 end
    if ratio >= 0.33 then return 2 end
    return 1
end

function M.compute(sessions, nowSec, goalMin)
    goalMin = goalMin or 0
    local byDay = {}
    local hours = table.create(24, 0)
    local weekdays = table.create(7, 0)
    local totalSec, totalCount, partialCount = 0, 0, 0

    for _, r in ipairs(sessions) do
        local d = tonumber(r.d) or 0
        if d > 0 and r.s then
            local key = M.dayKey(r.s)
            local day = byDay[key]
            if not day then
                day = { sec = 0, count = 0 }
                byDay[key] = day
            end
            day.sec += d
            totalSec += d
            if r.c then
                day.count += 1
                totalCount += 1
            else
                partialCount += 1
            end
            -- Spread the minutes over the clock hours they actually covered.
            local cursor, remaining = r.s, d
            while remaining > 0 do
                local hour = tonumber(os.date("%H", cursor)) or 0
                local intoHour = (tonumber(os.date("%M", cursor)) or 0) * 60 + (tonumber(os.date("%S", cursor)) or 0)
                local chunk = math.min(remaining, 3600 - intoHour)
                hours[hour + 1] += chunk / 60
                cursor += chunk
                remaining -= chunk
            end
            local wd = M.weekdayMon(r.s)
            weekdays[wd] += d / 60
        end
    end

    local function minutesOn(sec)
        local day = byDay[M.dayKey(sec)]
        return day and day.sec / 60 or 0, day and day.count or 0
    end

    local todayMin, todayCount = minutesOn(nowSec)

    -- Rolling 7-day windows.
    local weekMin, prevWeekMin, weekCount = 0, 0, 0
    for i = 0, 6 do
        local m, c = minutesOn(M.shiftDays(nowSec, -i))
        weekMin += m
        weekCount += c
        prevWeekMin += (minutesOn(M.shiftDays(nowSec, -i - 7)))
    end

    -- Streaks (a day counts when any focus time was logged).
    local streak = 0
    local cursor = nowSec
    if todayMin <= 0 then cursor = M.shiftDays(nowSec, -1) end -- today isn't over yet
    while (minutesOn(cursor)) > 0 do
        streak += 1
        cursor = M.shiftDays(cursor, -1)
    end

    local keys = {}
    for k in pairs(byDay) do table.insert(keys, k) end
    table.sort(keys)
    local best, run, prevNoon = 0, 0, nil
    local bestDay, bestDayMin = nil, 0
    for _, k in ipairs(keys) do
        local y, mo, d = k:match("^(%d+)%-(%d+)%-(%d+)$")
        local noon = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
        if prevNoon and M.dayKey(M.shiftDays(prevNoon, 1)) == k then
            run += 1
        else
            run = 1
        end
        prevNoon = noon
        if run > best then best = run end
        local m = byDay[k].sec / 60
        if m > bestDayMin then bestDay, bestDayMin = k, m end
    end

    -- Heatmap: weeks as columns (Mon..Sun rows), ending with the current week.
    local weeks = M.HEATMAP_WEEKS
    local todayKey = M.dayKey(nowSec)
    local gridStart = M.shiftDays(nowSec, -(M.weekdayMon(nowSec) - 1) - (weeks - 1) * 7)
    local peak = 0
    for i = 0, weeks * 7 - 1 do
        local m = minutesOn(M.shiftDays(gridStart, i))
        if m > peak then peak = m end
    end
    local columns, monthLabels = {}, {}
    local lastMonth = nil
    local activeDays, rangeMin = 0, 0
    for w = 1, weeks do
        local cells = {}
        for wd = 1, 7 do
            local sec = M.shiftDays(gridStart, (w - 1) * 7 + wd - 1)
            local key = M.dayKey(sec)
            local m, c = minutesOn(sec)
            local future = key > todayKey
            if not future and m > 0 then
                activeDays += 1
                rangeMin += m
            end
            cells[wd] = {
                date = key,
                label = M.dayLabel(sec, true),
                min = math.floor(m + 0.5),
                count = c,
                level = future and -1 or levelFor(m, goalMin, peak),
                today = key == todayKey,
            }
        end
        columns[w] = cells
        -- Month label on the first column that contains the 1st..7th of a month.
        local month = tonumber(os.date("%m", M.shiftDays(gridStart, (w - 1) * 7))) or 1
        if month ~= lastMonth then
            monthLabels[w] = MONTHS[month]
            lastMonth = month
        else
            monthLabels[w] = ""
        end
    end

    -- Last 14 days for the bar chart.
    local recent = {}
    for i = 13, 0, -1 do
        local sec = M.shiftDays(nowSec, -i)
        local m, c = minutesOn(sec)
        table.insert(recent, {
            date = M.dayKey(sec),
            short = DAYS[M.weekdayMon(sec)]:sub(1, 1),
            label = M.dayLabel(sec, false),
            min = math.floor(m + 0.5),
            count = c,
        })
    end

    for i = 1, 24 do hours[i] = math.floor(hours[i] + 0.5) end
    for i = 1, 7 do weekdays[i] = math.floor(weekdays[i] + 0.5) end

    local peakHour, peakHourMin = nil, 0
    for i = 1, 24 do
        if hours[i] > peakHourMin then peakHour, peakHourMin = i - 1, hours[i] end
    end

    return {
        today = { min = math.floor(todayMin + 0.5), count = todayCount },
        goal = goalMin,
        week = { min = math.floor(weekMin + 0.5), prevMin = math.floor(prevWeekMin + 0.5), count = weekCount },
        streak = streak,
        bestStreak = best,
        total = { min = math.floor(totalSec / 60 + 0.5), count = totalCount, partial = partialCount, days = #keys },
        completion = (totalCount + partialCount) > 0 and totalCount / (totalCount + partialCount) or nil,
        bestDay = bestDay and { date = bestDay, min = math.floor(bestDayMin + 0.5) } or nil,
        peakHour = peakHour,
        heatmap = {
            weeks = weeks,
            columns = columns,
            months = monthLabels,
            activeDays = activeDays,
            rangeMin = math.floor(rangeMin + 0.5),
            useGoal = goalMin > 0,
        },
        recent = recent,
        hours = hours,
        weekdays = weekdays,
        computedAt = nowSec,
    }
end

return M
