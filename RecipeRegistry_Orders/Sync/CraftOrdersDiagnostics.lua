local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Diagnostics = {}
Addon.Diagnostics = Diagnostics

local function getDB()
    return Addon.db and Addon.db.global or nil
end

local function safeCount(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

local function safeNum(value)
    return tonumber(value) or 0
end

-- Returns a flat snapshot of the current sync state. Both the slash
-- handler and spec assertions consume this. Tables are read-only by
-- convention; mutating them won't affect the underlying state.
function Diagnostics:Snapshot()
    local db = getDB()
    local protocol = Addon.Protocol
    local runtime  = Addon.Runtime
    local reducer  = Addon.Reducer

    local peers = {}
    if db and db.peers then
        for peerKey, record in pairs(db.peers) do
            peers[#peers + 1] = {
                key          = peerKey,
                highWaterSeq = safeNum(record.highWaterSeq),
                lastSeenAt   = safeNum(record.lastSeenAt),
            }
        end
        table.sort(peers, function(a, b)
            if a.highWaterSeq ~= b.highWaterSeq then
                return a.highWaterSeq > b.highWaterSeq
            end
            return tostring(a.key) < tostring(b.key)
        end)
    end

    return {
        protocol = {
            commRegistered      = protocol and protocol._commRegistered == true or false,
            commPrefix          = Addon.COMM_PREFIX,
            wireVersion         = Addon.WIRE_VERSION,
            buildChannel        = Addon.BUILD_CHANNEL,
            telemetry           = protocol and protocol.telemetry or {},
        },
        runtime = (runtime and runtime.DescribeState and runtime:DescribeState())
            or { enabled = false, hasPendingTimer = false, pendingReasons = {} },
        reducer = {
            telemetry = reducer and reducer.telemetry or {},
        },
        store = {
            orders       = safeCount(db and db.orders),
            events       = #(db and db.events and db.events.log or {}),
            tombstones   = safeCount(db and db.events and db.events.tombstones),
            peers        = peers,
        },
    }
end

-- Renders the snapshot into the array of strings printed by /rrord sync.
-- Kept as a pure formatter so the spec can assert content without an
-- AceConsole runtime.
function Diagnostics:FormatSyncLines(snapshot)
    snapshot = snapshot or self:Snapshot()
    local lines = {}

    lines[#lines + 1] = string.format(
        "Sync: prefix=%s wire=%s channel=%s comm=%s",
        tostring(snapshot.protocol.commPrefix),
        tostring(snapshot.protocol.wireVersion),
        tostring(snapshot.protocol.buildChannel),
        snapshot.protocol.commRegistered and "registered" or "|cffff5555not-registered|r"
    )

    local runtime = snapshot.runtime or {}
    local scheduledIn = "idle"
    if runtime.hasPendingTimer and runtime.pendingDueAt then
        local now = type(time) == "function" and time() or 0
        scheduledIn = string.format("in %ds (%s)",
            math.max(0, (runtime.pendingDueAt or 0) - now),
            table.concat(runtime.pendingReasons or {}, ","))
    end
    lines[#lines + 1] = string.format(
        "Runtime: enabled=%s next-hello=%s lastBroadcast=%ds ago",
        tostring(runtime.enabled),
        scheduledIn,
        math.max(0, (type(time) == "function" and time() or 0) - safeNum(runtime.lastBroadcastAt))
    )

    local pTel = snapshot.protocol.telemetry or {}
    lines[#lines + 1] = string.format(
        "Hello: sent=%d received=%d  Summary: sent=%d received=%d",
        safeNum(pTel.helloSent), safeNum(pTel.helloReceived),
        safeNum(pTel.summarySent), safeNum(pTel.summaryReceived)
    )
    lines[#lines + 1] = string.format(
        "Events: req-sent=%d req-recv=%d resp-sent=%d resp-recv=%d applied=%d dropped=%d",
        safeNum(pTel.eventsRequestSent), safeNum(pTel.eventsRequestReceived),
        safeNum(pTel.eventsResponseSent), safeNum(pTel.eventsResponseReceived),
        safeNum(pTel.eventsApplied), safeNum(pTel.dropped)
    )

    local rTel = snapshot.reducer.telemetry or {}
    lines[#lines + 1] = string.format(
        "Reducer: applied=%d duplicates=%d rejected=%d tombstoned=%d unknownKind=%d",
        safeNum(rTel.applied), safeNum(rTel.duplicates), safeNum(rTel.rejected),
        safeNum(rTel.tombstoned), safeNum(rTel.unknownKind)
    )

    local store = snapshot.store
    lines[#lines + 1] = string.format(
        "Store: orders=%d events=%d tombstones=%d peers=%d",
        store.orders, store.events, store.tombstones, #store.peers
    )

    if #store.peers > 0 then
        lines[#lines + 1] = "Peers (by highest seq):"
        local shown = math.min(#store.peers, 8)
        for index = 1, shown do
            local peer = store.peers[index]
            local now = type(time) == "function" and time() or 0
            local age = math.max(0, now - peer.lastSeenAt)
            lines[#lines + 1] = string.format("  %s  seq=%d  lastSeen=%ds ago",
                peer.key, peer.highWaterSeq, age)
        end
        if #store.peers > shown then
            lines[#lines + 1] = string.format("  (+ %d more)", #store.peers - shown)
        end
    end

    return lines
end

-- Single-line summary used inside /rrord diag.
function Diagnostics:FormatStatusLine()
    local s = self:Snapshot()
    local pTel = s.protocol.telemetry or {}
    local rTel = s.reducer.telemetry or {}
    return string.format(
        "Sync: comm=%s runtime=%s hello-sent=%d events-applied=%d reducer-applied=%d",
        s.protocol.commRegistered and "ok" or "off",
        s.runtime.enabled and "on" or "off",
        safeNum(pTel.helloSent), safeNum(pTel.eventsApplied),
        safeNum(rTel.applied)
    )
end
