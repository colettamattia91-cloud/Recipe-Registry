local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Reducer = {}
Addon.Reducer = Reducer

-- Per-kind handlers fill this table below; declared here so handlers
-- can be assigned via Reducer._handlers["..."] = function(...) ... end.
Reducer._handlers = {}

-- Telemetry counters surface in /rrord diag once the diagnostics
-- module lands; meanwhile they're handy for spec assertions.
Reducer.telemetry = Reducer.telemetry or {
    applied             = 0,
    duplicates          = 0,
    tombstoned          = 0,
    rejected            = 0,
    unknownKind         = 0,
    invalidTransition   = 0,
    producerMismatch    = 0,
    snapshotMismatches  = 0,
}

local function getDB()
    return Addon.db and Addon.db.global or nil
end

local function getStateMachine()
    return Addon.StateMachine
end

local function getPeerRecord(db, producer)
    db.peers = db.peers or {}
    local record = db.peers[producer]
    if not record then
        record = { highWaterSeq = 0, lastSeenAt = 0 }
        db.peers[producer] = record
    end
    return record
end

local function isTombstoned(db, orderId)
    if not orderId then return false end
    return db.events.tombstones[orderId] ~= nil
end

local function mirrorEventToLog(db, event)
    -- Append a copy to the local log so diagnostics and the UI event
    -- viewer reflect peer activity alongside local mutations. seq stays
    -- as the producer's seq; the local log is keyed by (producer, seq)
    -- when interpreted, not by the local counter.
    db.events.log[#db.events.log + 1] = {
        seq           = event.seq,
        producer      = event.producer,
        orderId       = event.orderId,
        kind          = event.kind,
        actor         = event.actor,
        at            = event.at,
        payload       = event.payload or {},
        schemaVersion = event.schemaVersion or 1,
        foreign       = true,
    }
end

local function bumpCounter(name)
    Reducer.telemetry[name] = (Reducer.telemetry[name] or 0) + 1
end

-- Result helper. Reducer:ApplyEvent always returns a uniform shape so
-- callers (protocol layer, tests) can branch consistently.
local function result(applied, reason)
    return { applied = applied == true, reason = reason }
end

function Reducer:ResetTelemetry()
    for key in pairs(self.telemetry) do
        self.telemetry[key] = 0
    end
end

function Reducer:GetPeerHighWaterMark(producer)
    local db = getDB()
    if not db then return 0 end
    local record = db.peers and db.peers[producer]
    return record and record.highWaterSeq or 0
end

-- Apply a single foreign event to local state. Returns a result table:
--   { applied = true }                             -- event consumed
--   { applied = false, reason = "duplicate" }     -- seq <= peer HWM
--   { applied = false, reason = "tombstoned" }    -- order pruned
--   { applied = false, reason = "unknown-kind" }
--   { applied = false, reason = "..." }           -- per-handler reject
--
-- The peer HWM is bumped on every "consumed" outcome (applied,
-- tombstoned, unknown-kind, rejected) so we don't keep re-evaluating
-- the same envelope. Pure duplicates leave the HWM unchanged.
function Reducer:ApplyEvent(event)
    if type(event) ~= "table" then return result(false, "invalid-event") end
    if type(event.kind) ~= "string" or event.kind == "" then return result(false, "missing-kind") end
    if type(event.producer) ~= "string" or event.producer == "" then return result(false, "missing-producer") end

    local seq = tonumber(event.seq)
    if not seq or seq <= 0 then return result(false, "missing-seq") end

    local db = getDB()
    if not db then return result(false, "store-not-ready") end

    local peer = getPeerRecord(db, event.producer)
    if seq <= (peer.highWaterSeq or 0) then
        bumpCounter("duplicates")
        return result(false, "duplicate")
    end

    if isTombstoned(db, event.orderId) then
        peer.highWaterSeq = seq
        peer.lastSeenAt = event.at or peer.lastSeenAt
        bumpCounter("tombstoned")
        return result(false, "tombstoned")
    end

    local handler = self._handlers[event.kind]
    if not handler then
        peer.highWaterSeq = seq
        peer.lastSeenAt = event.at or peer.lastSeenAt
        bumpCounter("unknownKind")
        return result(false, "unknown-kind")
    end

    local ok, err = handler(self, event, db)
    peer.highWaterSeq = seq
    peer.lastSeenAt = event.at or peer.lastSeenAt
    if not ok then
        bumpCounter("rejected")
        return result(false, err or "rejected")
    end

    mirrorEventToLog(db, event)
    bumpCounter("applied")
    return result(true)
end

-- Convenience: apply a batch of events. Sorts within (producer, orderId)
-- by seq before applying so out-of-order arrivals on the wire still
-- reduce correctly. Returns a summary { applied, rejected, duplicates,
-- tombstoned, unknownKind } over the batch.
function Reducer:ApplyEvents(events)
    if type(events) ~= "table" then return { applied = 0 } end
    local sorted = {}
    for index = 1, #events do
        sorted[index] = events[index]
    end
    table.sort(sorted, function(a, b)
        local ap = tostring(a and a.producer or "")
        local bp = tostring(b and b.producer or "")
        if ap ~= bp then return ap < bp end
        local ao = tostring(a and a.orderId or "")
        local bo = tostring(b and b.orderId or "")
        if ao ~= bo then return ao < bo end
        return (tonumber(a and a.seq) or 0) < (tonumber(b and b.seq) or 0)
    end)

    local summary = { applied = 0, rejected = 0, duplicates = 0, tombstoned = 0, unknownKind = 0 }
    for index = 1, #sorted do
        local outcome = self:ApplyEvent(sorted[index])
        if outcome.applied then
            summary.applied = summary.applied + 1
        elseif outcome.reason == "duplicate" then
            summary.duplicates = summary.duplicates + 1
        elseif outcome.reason == "tombstoned" then
            summary.tombstoned = summary.tombstoned + 1
        elseif outcome.reason == "unknown-kind" then
            summary.unknownKind = summary.unknownKind + 1
        else
            summary.rejected = summary.rejected + 1
        end
    end

    -- Broadcast a single coalesced change signal when at least one
    -- foreign event landed. The Store fires the same message on local
    -- mutations, so the Board/Cart auto-refresh path is uniform across
    -- "I changed it" and "a peer's update arrived". Per-event firing
    -- would also work (the Board debounces) but a batch ApplyEvents
    -- from EVENTS_RESPONSE would multiply the signal pointlessly.
    if summary.applied > 0 and type(Addon.SendMessage) == "function" then
        Addon:SendMessage("CraftOrders:Changed", "sync-applied", nil)
    end

    return summary
end

-- ---------------------------------------------------------------------
-- Per-kind handlers. Each handler returns `true` on success or
-- `false, "reason"` on rejection. They never throw, never partially
-- apply.

function Reducer._handlers.OrderCreated(self, event, db)
    local payload = event.payload or {}
    if type(payload.requester) ~= "string" or payload.requester == "" then
        return false, "missing-requester"
    end
    if type(payload.crafter) ~= "string" or payload.crafter == "" then
        return false, "missing-crafter"
    end
    if type(payload.lines) ~= "table" or #payload.lines == 0 then
        return false, "no-lines"
    end

    local existing = db.orders[event.orderId]
    if existing then
        -- Same id, same producer => idempotent (probably a re-snapshot
        -- after a peer disconnect/reconnect). Distinct producers with
        -- the same id is a collision; refuse rather than silently
        -- overwriting.
        if existing._producer and existing._producer ~= event.producer then
            bumpCounter("producerMismatch")
            return false, "producer-mismatch"
        end
        return true
    end

    local SM = getStateMachine()
    local order = {
        id            = event.orderId,
        schemaVersion = 1,
        requester     = payload.requester,
        crafter       = payload.crafter,
        createdAt     = payload.createdAt or event.at or 0,
        updatedAt     = event.at or payload.createdAt or 0,
        status        = SM and SM.STATES.DRAFT or "Draft",
        deliveryMode  = payload.deliveryMode or "mail",
        lines         = {},
        materials     = {},
        batches       = {},
        notes         = payload.notes or "",
        expiresAt     = nil,
        _producer     = event.producer,
    }
    for index = 1, #payload.lines do
        local source = payload.lines[index]
        order.lines[index] = {
            recipeKey    = tonumber(source.recipeKey),
            quantity     = tonumber(source.quantity),
            recipeLabel  = source.recipeLabel,
            outputItemID = tonumber(source.outputItemID),
        }
    end
    db.orders[event.orderId] = order

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end

    if payload.lineCount and payload.lineCount ~= #order.lines then
        bumpCounter("snapshotMismatches")
    end
    return true
end

local function handleStateTransition(_, event, db, order)
    local SM = getStateMachine()
    if not SM then return false, "state-machine-missing" end

    local payload = event.payload or {}
    local toState = payload.toState
    if not toState then return false, "missing-to-state" end

    if payload.fromState and payload.fromState ~= order.status then
        -- Out-of-order arrival or local desync. Don't apply; counter
        -- will surface this in diagnostics.
        bumpCounter("invalidTransition")
        return false, "from-state-mismatch"
    end

    local ok, err = SM:CanTransition(order.status, toState, event.actor)
    if not ok then
        bumpCounter("invalidTransition")
        return false, err or "invalid-transition"
    end

    order.status = toState
    order.updatedAt = event.at or order.updatedAt
    return true
end

local function handleLineAdded(_, event, db, order)
    local payload = event.payload or {}
    local recipeKey = tonumber(payload.recipeKey)
    local quantity = tonumber(payload.quantity)
    if not recipeKey or recipeKey == 0 then return false, "invalid-line-recipekey" end
    if not quantity or quantity <= 0 then return false, "invalid-line-quantity" end

    order.lines[#order.lines + 1] = {
        recipeKey    = recipeKey,
        quantity     = quantity,
        recipeLabel  = payload.recipeLabel,
        outputItemID = tonumber(payload.outputItemID),
    }
    order.updatedAt = event.at or order.updatedAt

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end
    return true
end

local function handleLineRemoved(_, event, db, order)
    local payload = event.payload or {}
    local lineIndex = tonumber(payload.lineIndex)
    if not lineIndex or lineIndex < 1 or lineIndex > #(order.lines or {}) then
        return false, "invalid-line-index"
    end
    if #order.lines == 1 then return false, "last-line-protected" end

    table.remove(order.lines, lineIndex)
    order.updatedAt = event.at or order.updatedAt

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end
    return true
end

local function handleProviderSet(_, event, db, order)
    local payload = event.payload or {}
    local itemID = tonumber(payload.itemID)
    if not itemID then return false, "invalid-itemid" end

    local bucket = order.materials and order.materials[itemID] or nil
    if not bucket then return false, "unknown-material" end

    local required = tonumber(bucket.required) or 0
    if required <= 0 then return false, "material-required-zero" end

    local newRequester = tonumber(payload.newRequester)
    local newCrafter   = tonumber(payload.newCrafter)
    if newRequester == nil or newCrafter == nil then
        return false, "missing-split"
    end
    if newRequester + newCrafter ~= required then
        return false, "split-mismatch"
    end

    bucket.requesterProvided = newRequester
    bucket.crafterProvided   = newCrafter
    order.updatedAt = event.at or order.updatedAt
    return true
end

function Reducer._handlers.OrderUpdated(self, event, db)
    local order = db.orders[event.orderId]
    if not order then
        return false, "unknown-order"
    end

    local payload = event.payload or {}
    local change = payload.change

    if change == "line-added" then
        return handleLineAdded(self, event, db, order)
    elseif change == "line-removed" then
        return handleLineRemoved(self, event, db, order)
    elseif change == "provider-set" then
        return handleProviderSet(self, event, db, order)
    elseif change == "state-transition" then
        return handleStateTransition(self, event, db, order)
    end

    return false, "unknown-change"
end

function Reducer._handlers.Pruned(self, event, db)
    if not event.orderId then return false, "missing-orderid" end
    db.orders[event.orderId] = nil
    db.events.tombstones[event.orderId] = {
        at        = event.at or 0,
        reason    = (event.payload and event.payload.reason) or "remote-prune",
        producer  = event.producer,
    }
    return true
end

-- TamperDetected is informational and never mutates state directly.
-- Phase 4 (mail scanner) will start emitting it; we accept the kind
-- now so events flow through without being labelled "unknown-kind".
function Reducer._handlers.TamperDetected(self, event, db)
    return true
end
