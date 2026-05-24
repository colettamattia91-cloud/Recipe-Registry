local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Runtime = {}
Addon.Runtime = Runtime

-- Scheduling parameters. Tuned to match Recipe Registry's experience
-- with HELLO traffic in TBC Classic raids: long enough that login
-- storms coalesce, short enough that local changes converge within
-- a session.
local LOGIN_HELLO_DELAY        = 30   -- give RR + Orders time to settle on login/reload
local CHANGE_HELLO_DELAY       = 10   -- local mutation should converge soon
local ROSTER_HELLO_DELAY       = 8    -- guild membership delta is interesting
local PAUSE_RESCHEDULE_DELAY   = 15   -- if pause policy denies send, try again later
local MIN_BROADCAST_INTERVAL   = 5    -- never two HELLOs closer than this

Runtime.delays = {
    LOGIN_HELLO_DELAY      = LOGIN_HELLO_DELAY,
    CHANGE_HELLO_DELAY     = CHANGE_HELLO_DELAY,
    ROSTER_HELLO_DELAY     = ROSTER_HELLO_DELAY,
    PAUSE_RESCHEDULE_DELAY = PAUSE_RESCHEDULE_DELAY,
    MIN_BROADCAST_INTERVAL = MIN_BROADCAST_INTERVAL,
}

-- Reason-specific delay. The shortest pending reason wins so that
-- "local-change" doesn't get delayed by an existing "login" reason.
local REASON_DELAY = {
    ["login"]            = LOGIN_HELLO_DELAY,
    ["reload"]           = LOGIN_HELLO_DELAY,
    ["local-change"]     = CHANGE_HELLO_DELAY,
    ["roster"]           = ROSTER_HELLO_DELAY,
    ["pause-resume"]     = PAUSE_RESCHEDULE_DELAY,
}

Runtime.telemetry = Runtime.telemetry or {
    helloScheduled  = 0,
    helloCoalesced  = 0,
    helloFired      = 0,
    helloSent       = 0,
    helloSkipped    = 0,
    pausedDeferred  = 0,
    readinessFailed = 0,
    skippedReasons  = {},
}

local function bumpSkipped(reason)
    Runtime.telemetry.helloSkipped = (Runtime.telemetry.helloSkipped or 0) + 1
    Runtime.telemetry.skippedReasons[reason] = (Runtime.telemetry.skippedReasons[reason] or 0) + 1
end

local function getRR()
    return _G.RecipeRegistry
end

local function nowSeconds()
    if type(time) == "function" then return time() end
    return 0
end

local function shouldPauseProtocol(kind)
    local rr = getRR()
    if not (rr and rr.SyncPausePolicy and type(rr.SyncPausePolicy.ShouldPauseProtocolTraffic) == "function") then
        return false  -- no pause policy reachable => assume OK to send
    end
    local ok, paused = pcall(rr.SyncPausePolicy.ShouldPauseProtocolTraffic, rr.SyncPausePolicy, kind)
    if not ok then return false end
    return paused == true
end

local function isReady()
    if not (Addon.db and Addon.db.global) then return false, "db-not-ready" end
    if not Addon.Protocol then return false, "protocol-missing" end
    local key = type(Addon.GetLocalPlayerKey) == "function" and Addon:GetLocalPlayerKey() or nil
    if type(key) ~= "string" or key == "" or key == "?" then
        return false, "player-key-missing"
    end
    return true
end

-- ---------------------------------------------------------------------
-- Scheduling. Multiple reasons coalesce into one timer so a burst of
-- local mutations doesn't fire a burst of HELLOs. The shortest of the
-- pending reasons' delays wins.

function Runtime:ScheduleHello(reason)
    reason = tostring(reason or "unspecified")
    self._pendingReasons = self._pendingReasons or {}
    self._pendingReasons[reason] = true
    self.telemetry.helloScheduled = self.telemetry.helloScheduled + 1

    local desiredDelay = REASON_DELAY[reason] or CHANGE_HELLO_DELAY

    -- Respect MIN_BROADCAST_INTERVAL: a HELLO that went out N seconds
    -- ago shouldn't get a follow-up until the interval has passed.
    if self._lastBroadcastAt and self._lastBroadcastAt > 0 then
        local since = nowSeconds() - self._lastBroadcastAt
        if since < MIN_BROADCAST_INTERVAL then
            desiredDelay = math.max(desiredDelay, MIN_BROADCAST_INTERVAL - since)
        end
    end

    if self._helloTimer then
        local existing = self._helloTimerDelay or desiredDelay
        if desiredDelay >= existing then
            -- Existing timer already fires sooner; just coalesce.
            self.telemetry.helloCoalesced = self.telemetry.helloCoalesced + 1
            return
        end
        -- Replace with a sooner timer.
        if type(Addon.CancelTimer) == "function" then
            Addon:CancelTimer(self._helloTimer)
        end
        self._helloTimer = nil
        self.telemetry.helloCoalesced = self.telemetry.helloCoalesced + 1
    end

    if type(Addon.ScheduleTimer) ~= "function" then
        -- No timer support; fire immediately so behaviour is at least
        -- observable. Real plugin always has AceTimer-3.0 embedded.
        Runtime:FireHello()
        return
    end

    self._helloTimerDelay = desiredDelay
    self._helloTimerDueAt = nowSeconds() + desiredDelay
    self._helloTimer = Addon:ScheduleTimer(function()
        Runtime._helloTimer = nil
        Runtime._helloTimerDelay = nil
        Runtime._helloTimerDueAt = nil
        Runtime:FireHello()
    end, desiredDelay)
end

function Runtime:CancelPendingHello()
    if self._helloTimer and type(Addon.CancelTimer) == "function" then
        Addon:CancelTimer(self._helloTimer)
    end
    self._helloTimer = nil
    self._helloTimerDelay = nil
    self._helloTimerDueAt = nil
    self._pendingReasons = nil
end

-- Drives the actual BroadcastHello if all gates allow. Called from
-- the scheduled timer (or directly in tests). Bumps fired counter
-- regardless of outcome so the diagnostics line can show "tried 12,
-- sent 10, paused 2".
function Runtime:FireHello()
    self.telemetry.helloFired = self.telemetry.helloFired + 1
    local reasons = self._pendingReasons or {}
    self._pendingReasons = nil

    local ready, readyErr = isReady()
    if not ready then
        self.telemetry.readinessFailed = self.telemetry.readinessFailed + 1
        bumpSkipped(readyErr or "not-ready")
        return false, readyErr or "not-ready"
    end

    if shouldPauseProtocol("HELLO_ORDERS") then
        self.telemetry.pausedDeferred = self.telemetry.pausedDeferred + 1
        bumpSkipped("paused")
        self:ScheduleHello("pause-resume")
        return false, "paused"
    end

    -- All gates pass; ship.
    local ok = Addon.Protocol:BroadcastHello({
        helloId = string.format("ho-%d", nowSeconds()),
        reasons = reasons,
    })
    if ok then
        self.telemetry.helloSent = self.telemetry.helloSent + 1
        self._lastBroadcastAt = nowSeconds()
        return true
    end
    bumpSkipped("send-failed")
    return false, "send-failed"
end

-- ---------------------------------------------------------------------
-- Trigger wiring. Idempotent — called from the plugin's OnEnable.

function Runtime:OnEnable()
    if self._enabled then return end
    self._enabled = true

    -- Subscribe to local mutations so any /rrord new/add/delete/transition
    -- coalesces into a HELLO. The Store fires CraftOrders:Changed via
    -- AceEvent message — same hook the Board uses.
    if type(Addon.RegisterMessage) == "function" then
        Addon:RegisterMessage("CraftOrders:Changed", function()
            Runtime:ScheduleHello("local-change")
        end)
    end

    -- Guild roster changes hint at new peers showing up. Debounced
    -- because GUILD_ROSTER_UPDATE fires repeatedly during a roster
    -- pull; ScheduleHello coalesces them via the timer.
    if type(Addon.RegisterEvent) == "function" then
        Addon:RegisterEvent("GUILD_ROSTER_UPDATE", function()
            Runtime:ScheduleHello("roster")
        end)
    end

    -- Kick off the first broadcast after the longer login delay so
    -- the addon has time to settle (saved variables, plugin OnEnable
    -- order across multiple addons, etc.).
    self:ScheduleHello("login")
end

function Runtime:ResetTelemetry()
    for key, value in pairs(self.telemetry) do
        if type(value) == "table" then
            for innerKey in pairs(value) do
                value[innerKey] = nil
            end
        else
            self.telemetry[key] = 0
        end
    end
end

-- Diagnostics-friendly view of the current state. Iteration D will
-- surface this via /rrord sync.
function Runtime:DescribeState()
    local pending = {}
    for reason in pairs(self._pendingReasons or {}) do
        pending[#pending + 1] = reason
    end
    table.sort(pending)
    return {
        enabled         = self._enabled == true,
        hasPendingTimer = self._helloTimer ~= nil,
        pendingDueAt    = self._helloTimerDueAt,
        pendingReasons  = pending,
        lastBroadcastAt = self._lastBroadcastAt or 0,
        telemetry       = self.telemetry,
    }
end
