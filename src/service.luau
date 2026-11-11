--!nonstrict
-- FocusFlow - timer engine, persistence and analytics publisher.
--
-- The timer is anchored on wall-clock deadlines (endsAt), not on tick counts,
-- so it stays correct across suspend, lag spikes and shell restarts.
--
-- Shared state (noctalia.state):
--   focusflow.timer  snapshot for the bar widget and panel (published each second)
--   focusflow.stats  analytics (published on change and at midnight)
--   focusflow.cmd    { cmd = "...", n = nonce } commands from the widget/panel

local Stats = require("./src/stats.luau")

local DATA_DIR = noctalia.pluginDataDir()
local HISTORY_PATH = DATA_DIR .. "/history.json"
local STATE_PATH = DATA_DIR .. "/state.json"
local MIN_PARTIAL_SEC = 60

noctalia.mkdirAll(DATA_DIR)

-- ------------------------------------------------------------------ config

local cfg = {}
local function int(key, fallback)
    local v = tonumber(noctalia.getConfig(key))
    return v and math.floor(v) or fallback
end
local function bool(key, fallback)
    local v = noctalia.getConfig(key)
    if v == nil then return fallback end
    return v == true
end
local function loadConfig()
    cfg = {
        work = math.max(1, int("work-minutes", 25)) * 60,
        short = math.max(1, int("short-break-minutes", 5)) * 60,
        long = math.max(1, int("long-break-minutes", 15)) * 60,
        rounds = math.max(1, int("rounds", 4)),
        autoBreaks = bool("auto-start-breaks", true),
        autoWork = bool("auto-start-work", false),
        goal = math.max(0, int("daily-goal-minutes", 120)),
        logPartial = bool("log-partial", true),
        notify = bool("notify", true),
        sound = bool("sound", true),
        soundFile = noctalia.getConfig("sound-file") or "/usr/share/sounds/freedesktop/stereo/complete.oga",
    }
end
loadConfig()

local function phaseLength(phase)
    return (cfg[phase] or cfg.work) * 1000
end

-- ------------------------------------------------------------------ persistence

local function readJson(path)
    if not noctalia.fileExists(path) then return nil end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(noctalia.json.decode, raw)
    return ok and type(data) == "table" and data or nil
end

local function writeJson(path, data)
    local tmp = path .. ".tmp"
    noctalia.writeFile(tmp, noctalia.json.encode(data))
    noctalia.renameFile(tmp, path)
end

local history = readJson(HISTORY_PATH)
if not history or type(history.sessions) ~= "table" then
    history = { version = 1, sessions = {} }
end

-- ------------------------------------------------------------------ timer state

-- phase: "work" | "short" | "long";  status: "idle" | "running" | "paused"
local T = {
    phase = "work",
    status = "idle",
    endsAt = nil,        -- ms, while running
    remainingMs = phaseLength("work"),
    totalMs = phaseLength("work"),
    round = 1,           -- which focus session of the cycle (1..rounds)
    startedAt = nil,     -- sec, first start of the current phase
}

local saved = readJson(STATE_PATH)
if saved and saved.phase and saved.status then
    for k, v in pairs(saved) do T[k] = v end
    if T.round > cfg.rounds then T.round = 1 end
end

local function saveState()
    writeJson(STATE_PATH, {
        phase = T.phase, status = T.status, endsAt = T.endsAt,
        remainingMs = T.remainingMs, totalMs = T.totalMs,
        round = T.round, startedAt = T.startedAt,
    })
end

local function remainingNow()
    if T.status == "running" and T.endsAt then
        return math.max(0, T.endsAt - noctalia.nowMs())
    end
    return T.remainingMs
end

-- ------------------------------------------------------------------ publishing

local currentStats = nil
local statsDay = Stats.dayKey(os.time())

local function publishStats()
    currentStats = Stats.compute(history.sessions, os.time(), cfg.goal)
    statsDay = Stats.dayKey(os.time())
    noctalia.state.set("focusflow.stats", currentStats)
end

local lastPublishedSec = -1
local function publishTimer(force)
    local rem = remainingNow()
    local sec = math.ceil(rem / 1000)
    if not force and sec == lastPublishedSec then return end
    lastPublishedSec = sec
    noctalia.state.set("focusflow.timer", {
        phase = T.phase,
        status = T.status,
        remaining = sec,
        total = math.floor(T.totalMs / 1000),
        round = T.round,
        rounds = cfg.rounds,
        todayMin = currentStats and currentStats.today.min or 0,
        todayCount = currentStats and currentStats.today.count or 0,
        goal = cfg.goal,
        streak = currentStats and currentStats.streak or 0,
    })
end

-- ------------------------------------------------------------------ logging

local function logFocus(completed)
    if T.phase ~= "work" or not T.startedAt then return end
    local focused = math.floor((T.totalMs - remainingNow()) / 1000 + 0.5)
    if completed then focused = math.floor(T.totalMs / 1000) end
    if not completed and (not cfg.logPartial or focused < MIN_PARTIAL_SEC) then return end
    table.insert(history.sessions, {
        s = T.startedAt,
        e = os.time(),
        d = focused,
        p = math.floor(T.totalMs / 1000),
        c = completed,
    })
    writeJson(HISTORY_PATH, history)
    publishStats()
end

-- ------------------------------------------------------------------ alerts

local MESSAGES = {
    work = { "Focus session complete", "Nice work, time for a break." },
    short = { "Break over", "Ready for the next focus session?" },
    long = { "Long break over", "Cycle complete. Ready for a fresh one?" },
}

local function alert(finishedPhase)
    local msg = MESSAGES[finishedPhase]
    if cfg.notify and msg then
        local body = msg[2]
        if finishedPhase == "work" and currentStats then
            body = string.format("%s  Today: %d min · %d sessions", body, currentStats.today.min, currentStats.today.count)
        end
        noctalia.notify("FocusFlow · " .. msg[1], body)
    end
    if cfg.sound and cfg.soundFile ~= "" and noctalia.fileExists(cfg.soundFile) then
        noctalia.runAsync({ "pw-play", cfg.soundFile })
    end
end

-- ------------------------------------------------------------------ transitions

local function enterPhase(phase, autostart)
    T.phase = phase
    T.totalMs = phaseLength(phase)
    T.remainingMs = T.totalMs
    T.startedAt = nil
    T.endsAt = nil
    T.status = "idle"
    if autostart then
        T.status = "running"
        T.startedAt = os.time()
        T.endsAt = noctalia.nowMs() + T.totalMs
    end
end

local function nextPhase()
    if T.phase == "work" then
        if T.round >= cfg.rounds then return "long" end
        return "short"
    end
    return "work"
end

local function advance(autoFromFinish)
    local finished = T.phase
    local nxt = nextPhase()
    if finished ~= "work" then
        T.round = finished == "long" and 1 or (T.round % cfg.rounds) + 1
    end
    local auto = false
    if autoFromFinish then
        auto = (nxt == "work" and cfg.autoWork) or (nxt ~= "work" and cfg.autoBreaks)
    end
    enterPhase(nxt, auto)
end

local actions = {}

function actions.start()
    if T.status == "running" then return end
    if not T.startedAt then T.startedAt = os.time() end
    T.endsAt = noctalia.nowMs() + T.remainingMs
    T.status = "running"
end

function actions.pause()
    if T.status ~= "running" then return end
    T.remainingMs = remainingNow()
    T.endsAt = nil
    T.status = "paused"
end

function actions.toggle()
    if T.status == "running" then actions.pause() else actions.start() end
end

function actions.skip()
    logFocus(false)
    advance(false)
end

function actions.reset() -- restart the current phase
    logFocus(false)
    enterPhase(T.phase, false)
end

function actions.stop() -- back to the start of a fresh cycle
    logFocus(false)
    T.round = 1
    enterPhase("work", false)
end

function actions.focus() -- jump straight into a focus session now
    if T.phase ~= "work" then
        enterPhase("work", false)
    end
    actions.start()
end

function actions.adjust(deltaSec) -- +/- minutes on the running/paused clock
    local newRem = math.max(60 * 1000, remainingNow() + deltaSec * 1000)
    T.totalMs = math.max(T.totalMs + deltaSec * 1000, newRem)
    if T.status == "running" then
        T.endsAt = noctalia.nowMs() + newRem
    else
        T.remainingMs = newRem
    end
end

local function finish()
    local finished = T.phase
    T.remainingMs = 0
    logFocus(true)
    alert(finished)
    advance(true)
end

local function run(cmd, arg)
    if cmd == "plus" then
        actions.adjust(60)
    elseif cmd == "minus" then
        actions.adjust(-60)
    elseif cmd == "refresh-stats" then
        publishStats()
    elseif actions[cmd] then
        actions[cmd](arg)
    else
        noctalia.log("focusflow: unknown command " .. tostring(cmd))
        return
    end
    saveState()
    publishTimer(true)
end

-- ------------------------------------------------------------------ wiring

noctalia.state.watch("focusflow.cmd", function(msg)
    if type(msg) == "table" and msg.cmd then run(msg.cmd, msg.arg) end
end)

-- noctalia msg plugin adam-gassem/focusflow:engine all <event>
function onIpc(event, _payload)
    run(event)
end

function onConfigChanged()
    loadConfig()
    if T.status == "idle" then
        T.totalMs = phaseLength(T.phase)
        T.remainingMs = T.totalMs
    end
    if T.round > cfg.rounds then T.round = 1 end
    saveState()
    publishStats()
    publishTimer(true)
end

noctalia.setUpdateInterval(250)
function update()
    if T.status == "running" and remainingNow() <= 0 then
        finish()
        saveState()
        publishTimer(true)
    else
        publishTimer(false)
    end
    -- Midnight rollover: today's numbers and the heatmap move on.
    local day = Stats.dayKey(os.time())
    if day ~= statsDay then
        publishStats()
        publishTimer(true)
    end
end

-- A deadline that passed while the shell was down completes immediately.
publishStats()
if T.status == "running" and remainingNow() <= 0 then
    finish()
    saveState()
end
publishTimer(true)
