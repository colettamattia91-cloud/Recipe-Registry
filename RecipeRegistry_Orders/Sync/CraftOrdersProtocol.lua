local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Protocol = {}
Addon.Protocol = Protocol

-- Wire message kinds. Distinct strings (not prefixed with "ORDERS")
-- because the codec wraps them under the RRORD/RRORDDEV comm prefix
-- already — there's no namespace collision with RR's HELLO/SUMMARY/
-- INDEX_DIFF/BLOCK_PULL on the addon channel.
Protocol.KIND_HELLO            = "HELLO_ORDERS"
Protocol.KIND_SUMMARY          = "SUMMARY_ORDERS"
Protocol.KIND_EVENTS_REQUEST   = "EVENTS_REQUEST"
Protocol.KIND_EVENTS_RESPONSE  = "EVENTS_RESPONSE"

-- Telemetry counters. Surfaced via /rrord diag in iteration D.
Protocol.telemetry = Protocol.telemetry or {
    helloSent             = 0,
    helloReceived         = 0,
    summarySent           = 0,
    summaryReceived       = 0,
    eventsRequestSent     = 0,
    eventsRequestReceived = 0,
    eventsResponseSent    = 0,
    eventsResponseReceived = 0,
    eventsApplied         = 0,
    dropped               = 0,
    droppedReasons        = {},
}

local function getDB()
    return Addon.db and Addon.db.global or nil
end

local function getCodec()
    return Addon.Codec
end

local function getReducer()
    return Addon.Reducer
end

local function localKey()
    if type(Addon.GetLocalPlayerKey) == "function" then
        return Addon:GetLocalPlayerKey() or "?"
    end
    return "?"
end

local function bumpDropped(reason)
    Protocol.telemetry.dropped = (Protocol.telemetry.dropped or 0) + 1
    Protocol.telemetry.droppedReasons[reason] = (Protocol.telemetry.droppedReasons[reason] or 0) + 1
end

-- Build a compact per-producer "I have events up to seq=N" map from
-- the local peers table. The receiver compares against its own to
-- decide which producers it's behind on.
function Protocol:BuildSummary()
    local db = getDB()
    if not db then return { producers = {} } end
    local producers = {}
    for peerKey, record in pairs(db.peers or {}) do
        local seq = tonumber(record and record.highWaterSeq) or 0
        if seq > 0 then
            producers[peerKey] = seq
        end
    end
    return {
        producers     = producers,
        ordersCount   = self:_CountOrders(),
        eventsCount   = #(db.events.log or {}),
    }
end

function Protocol:_CountOrders()
    local db = getDB()
    if not db then return 0 end
    local count = 0
    for _ in pairs(db.orders or {}) do count = count + 1 end
    return count
end

-- Given a peer's advertised summary, compute which producers the peer
-- has MORE events for than we do, plus the gap range. Used to build
-- EVENTS_REQUEST. Self-events (producer = our key) are excluded — we
-- always know our own events.
function Protocol:ComputeGaps(peerSummary)
    if type(peerSummary) ~= "table" or type(peerSummary.producers) ~= "table" then
        return {}
    end
    local db = getDB()
    if not db then return {} end
    local self_ = localKey()
    local localPeers = db.peers or {}
    local gaps = {}
    for producer, peerHWM in pairs(peerSummary.producers) do
        if producer ~= self_ then
            local localHWM = tonumber(localPeers[producer] and localPeers[producer].highWaterSeq) or 0
            local peerHWMnum = tonumber(peerHWM) or 0
            if peerHWMnum > localHWM then
                gaps[producer] = { fromSeq = localHWM + 1, throughSeq = peerHWMnum }
            end
        end
    end
    return gaps
end

-- Collect log entries for a specific producer between [fromSeq, throughSeq]
-- inclusive. Used by EVENTS_REQUEST handler.
function Protocol:CollectEvents(producer, fromSeq, throughSeq)
    local db = getDB()
    if not db then return {} end
    fromSeq    = tonumber(fromSeq) or 1
    throughSeq = tonumber(throughSeq) or math.huge
    local out = {}
    for index = 1, #db.events.log do
        local entry = db.events.log[index]
        if entry.producer == producer
            and entry.seq
            and entry.seq >= fromSeq
            and entry.seq <= throughSeq
        then
            out[#out + 1] = entry
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Outbound: build payloads and ship them via SendCommMessage. The
-- runtime layer (iteration C) decides WHEN to call these; the protocol
-- layer just does the right thing each time it's asked.

local function sendComm(message, distribution, target)
    local codec = getCodec()
    if not codec then return false end
    local encoded = codec:Encode(message)
    if encoded == nil then return false end
    if type(Addon.SendCommMessage) ~= "function" then return false end
    Addon:SendCommMessage(Addon.COMM_PREFIX, encoded, distribution, target)
    return true
end

function Protocol:BroadcastHello(opts)
    opts = opts or {}
    local message = {
        kind         = self.KIND_HELLO,
        sender       = localKey(),
        wireVersion  = Addon.WIRE_VERSION,
        minWireVersion = Addon.MIN_SUPPORTED_WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId      = Addon.BUILD_ID,
        summary      = self:BuildSummary(),
        helloId      = opts.helloId,
    }
    local ok = sendComm(message, "GUILD")
    if ok then
        self.telemetry.helloSent = self.telemetry.helloSent + 1
    end
    return ok
end

function Protocol:SendSummary(targetKey, opts)
    opts = opts or {}
    if type(targetKey) ~= "string" or targetKey == "" then return false end
    local message = {
        kind         = self.KIND_SUMMARY,
        sender       = localKey(),
        wireVersion  = Addon.WIRE_VERSION,
        minWireVersion = Addon.MIN_SUPPORTED_WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId      = Addon.BUILD_ID,
        summary      = self:BuildSummary(),
        inReplyTo    = opts.helloId,
    }
    local ok = sendComm(message, "WHISPER", targetKey)
    if ok then
        self.telemetry.summarySent = self.telemetry.summarySent + 1
    end
    return ok
end

function Protocol:SendEventsRequest(targetKey, requests)
    if type(targetKey) ~= "string" or targetKey == "" then return false end
    if type(requests) ~= "table" then return false end
    local message = {
        kind         = self.KIND_EVENTS_REQUEST,
        sender       = localKey(),
        wireVersion  = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        requests     = requests,  -- { [producer] = { fromSeq, throughSeq } }
    }
    local ok = sendComm(message, "WHISPER", targetKey)
    if ok then
        self.telemetry.eventsRequestSent = self.telemetry.eventsRequestSent + 1
    end
    return ok
end

function Protocol:SendEventsResponse(targetKey, events)
    if type(targetKey) ~= "string" or targetKey == "" then return false end
    if type(events) ~= "table" then return false end
    local message = {
        kind         = self.KIND_EVENTS_RESPONSE,
        sender       = localKey(),
        wireVersion  = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        events       = events,
    }
    local ok = sendComm(message, "WHISPER", targetKey)
    if ok then
        self.telemetry.eventsResponseSent = self.telemetry.eventsResponseSent + 1
    end
    return ok
end

-- ---------------------------------------------------------------------
-- Inbound. RegisterComm hooks this up so the addon comm channel
-- delivers RRORD / RRORDDEV traffic here. The receiver does:
--   1. Drop anything not on our channel (prefix mismatch).
--   2. Drop self-echoes.
--   3. Decode + validate the envelope (wire version, build channel,
--      kind known).
--   4. Dispatch to the per-kind handler.

local function compatibleWireVersion(message)
    local peerWire = tonumber(message.wireVersion)
    if not peerWire then return false, "missing-wire-version" end
    if peerWire < Addon.MIN_SUPPORTED_WIRE_VERSION then return false, "wire-too-old" end
    local peerMin = tonumber(message.minWireVersion) or peerWire
    if Addon.WIRE_VERSION < peerMin then return false, "wire-too-old-locally" end
    return true
end

function Protocol:OnCommReceived(prefix, raw, distribution, sender)
    if prefix ~= Addon.COMM_PREFIX then return end  -- not ours

    if sender and sender == localKey() then
        return  -- ignore guild-channel self-echo
    end

    local codec = getCodec()
    if not codec then bumpDropped("no-codec") return end
    local message = codec:Decode(raw)
    if type(message) ~= "table" then bumpDropped("decode-failed") return end

    local kind = message.kind
    if type(kind) ~= "string" or kind == "" then
        bumpDropped("missing-kind") return
    end

    if message.buildChannel ~= Addon.BUILD_CHANNEL then
        bumpDropped("channel-mismatch") return
    end

    local compatible, wireReason = compatibleWireVersion(message)
    if not compatible then
        bumpDropped(wireReason or "wire-incompatible") return
    end

    local handler = self._handlers[kind]
    if not handler then
        bumpDropped("unknown-kind") return
    end

    handler(self, message, sender, distribution)
end

-- ---------------------------------------------------------------------
-- Per-kind handlers. Each handler bumps its received counter, then
-- decides whether to act. Acting may include sending a follow-up
-- message; the protocol layer is allowed to do that immediately. The
-- runtime layer (iteration C) will add throttling, scheduling, and
-- pause-policy checks around these.

Protocol._handlers = {}

function Protocol._handlers:HELLO_ORDERS(message, sender)
    self.telemetry.helloReceived = self.telemetry.helloReceived + 1

    -- Compare the peer's summary against our own. If we have nothing
    -- to offer (no gaps either way), stay silent. Otherwise reply with
    -- our own SUMMARY so the originator can compute what to pull.
    local peerSummary = message.summary or {}
    local myProducers = self:BuildSummary().producers
    local peerProducers = peerSummary.producers or {}

    local differ = false
    for producer, peerSeq in pairs(peerProducers) do
        if (tonumber(myProducers[producer]) or 0) ~= (tonumber(peerSeq) or 0) then
            differ = true
            break
        end
    end
    if not differ then
        for producer, mySeq in pairs(myProducers) do
            if (tonumber(peerProducers[producer]) or 0) ~= (tonumber(mySeq) or 0) then
                differ = true
                break
            end
        end
    end
    if not differ then
        return
    end

    self:SendSummary(sender, { helloId = message.helloId })
end

function Protocol._handlers:SUMMARY_ORDERS(message, sender)
    self.telemetry.summaryReceived = self.telemetry.summaryReceived + 1

    -- Identify producers where the peer is ahead of us; ask for the
    -- delta. Batched into a single EVENTS_REQUEST.
    local gaps = self:ComputeGaps(message.summary)
    local requests = {}
    local hasAny = false
    for producer, range in pairs(gaps) do
        requests[producer] = { fromSeq = range.fromSeq, throughSeq = range.throughSeq }
        hasAny = true
    end
    if not hasAny then return end
    self:SendEventsRequest(sender, requests)
end

function Protocol._handlers:EVENTS_REQUEST(message, sender)
    self.telemetry.eventsRequestReceived = self.telemetry.eventsRequestReceived + 1

    local requests = message.requests
    if type(requests) ~= "table" then return end

    local payload = {}
    for producer, range in pairs(requests) do
        if type(range) == "table" then
            local events = self:CollectEvents(producer, range.fromSeq, range.throughSeq)
            for index = 1, #events do
                payload[#payload + 1] = events[index]
            end
        end
    end
    if #payload == 0 then return end
    self:SendEventsResponse(sender, payload)
end

function Protocol._handlers:EVENTS_RESPONSE(message)
    self.telemetry.eventsResponseReceived = self.telemetry.eventsResponseReceived + 1

    local reducer = getReducer()
    if not reducer then return end
    local events = message.events
    if type(events) ~= "table" then return end
    local summary = reducer:ApplyEvents(events)
    self.telemetry.eventsApplied = self.telemetry.eventsApplied + (summary.applied or 0)
end

-- Install the comm handler on the addon. Called from the plugin's
-- OnEnable once the channel/prefix are settled. Idempotent.
function Protocol:RegisterCommHandler()
    if self._commRegistered then return end
    if type(Addon.RegisterComm) ~= "function" then return end
    Addon:RegisterComm(Addon.COMM_PREFIX, function(_, prefix, raw, distribution, sender)
        Protocol:OnCommReceived(prefix, raw, distribution, sender)
    end)
    self._commRegistered = true
end

function Protocol:ResetTelemetry()
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
