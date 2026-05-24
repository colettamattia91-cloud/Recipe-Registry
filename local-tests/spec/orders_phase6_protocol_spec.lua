local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function lineFor(recipeKey, quantity)
    local info = RECIPES[recipeKey]
    return {
        recipeKey    = recipeKey,
        quantity     = quantity,
        recipeLabel  = info and info.label,
        outputItemID = info and info.createdItemID,
    }
end

-- The harness default playerName is "Tester" and the default realm is
-- "TestRealm" — UnitFullName / GetRealmName produce "Tester-TestRealm"
-- which is what Addon:GetLocalPlayerKey will return.
local LOCAL_KEY = "Tester-TestRealm"
local REMOTE_KEY = "Bob-OtherRealm"

local function getLastSent()
    local rows = Loader.Wow.GetSentComm()
    return rows[#rows]
end

local function clearSent()
    local rows = Loader.Wow.GetSentComm()
    for index = #rows, 1, -1 do rows[index] = nil end
end

io.write("Craft Orders protocol\n")

Test.it("BroadcastHello sends a GUILD HELLO_ORDERS with current channel + summary", function()
    local plugin = freshPlugin()
    -- Seed one local event so BuildSummary has something to report.
    plugin.Store:CreateDraft({
        requester = LOCAL_KEY, crafter = REMOTE_KEY,
        lines = { lineFor(929, 1) },
    })
    clearSent()
    Test.truthy(plugin.Protocol:BroadcastHello())

    local sent = getLastSent()
    Test.truthy(sent)
    Test.eq(sent.prefix, plugin.COMM_PREFIX)
    Test.eq(sent.distribution, "GUILD")
    Test.eq(sent.target, nil)
    local payload = sent.message
    Test.eq(payload.kind, plugin.Protocol.KIND_HELLO)
    Test.eq(payload.buildChannel, plugin.BUILD_CHANNEL)
    Test.eq(payload.wireVersion, plugin.WIRE_VERSION)
    Test.eq(payload.sender, LOCAL_KEY)
    -- Summary advertises the local producer's high-water-mark.
    Test.truthy(payload.summary)
    Test.truthy((payload.summary.producers[LOCAL_KEY] or 0) >= 1)
    Test.eq(plugin.Protocol.telemetry.helloSent, 1)
end)

Test.it("SendSummary whispers to the named peer with SUMMARY_ORDERS", function()
    local plugin = freshPlugin()
    clearSent()
    Test.truthy(plugin.Protocol:SendSummary(REMOTE_KEY, { helloId = "abc" }))
    local sent = getLastSent()
    Test.eq(sent.distribution, "WHISPER")
    Test.eq(sent.target, REMOTE_KEY)
    Test.eq(sent.message.kind, plugin.Protocol.KIND_SUMMARY)
    Test.eq(sent.message.inReplyTo, "abc")
end)

Test.it("OnCommReceived ignores messages on the wrong prefix", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Protocol:OnCommReceived("NotOurPrefix", { kind = "HELLO_ORDERS" }, "GUILD", REMOTE_KEY)
    Test.eq(plugin.Protocol.telemetry.helloReceived, 0)
    Test.eq(plugin.Protocol.telemetry.dropped, 0, "wrong-prefix is a fast no-op, not counted")
end)

Test.it("OnCommReceived ignores self-echo on the guild channel", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = LOCAL_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = {} },
    }, "GUILD", LOCAL_KEY)
    Test.eq(plugin.Protocol.telemetry.helloReceived, 0)
end)

Test.it("OnCommReceived drops messages from a different build channel", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    local foreignChannel = (plugin.BUILD_CHANNEL == "dev") and "release" or "dev"
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = foreignChannel,
        summary = { producers = {} },
    }, "GUILD", REMOTE_KEY)
    Test.eq(plugin.Protocol.telemetry.helloReceived, 0)
    Test.eq(plugin.Protocol.telemetry.dropped, 1)
    Test.eq(plugin.Protocol.telemetry.droppedReasons["channel-mismatch"], 1)
end)

Test.it("OnCommReceived drops messages with wire version below our floor", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = REMOTE_KEY,
        wireVersion = 0,  -- below MIN_SUPPORTED
        buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = {} },
    }, "GUILD", REMOTE_KEY)
    Test.eq(plugin.Protocol.telemetry.dropped, 1)
    Test.eq(plugin.Protocol.telemetry.droppedReasons["wire-too-old"], 1)
end)

Test.it("OnCommReceived drops unknown kinds with a dropped counter", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "ZZ_FUTURE_KIND", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
    }, "GUILD", REMOTE_KEY)
    Test.eq(plugin.Protocol.telemetry.dropped, 1)
    Test.eq(plugin.Protocol.telemetry.droppedReasons["unknown-kind"], 1)
end)

Test.it("OnCommReceived drops messages with malformed envelope", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, "not-a-table", "GUILD", REMOTE_KEY)
    Test.truthy(plugin.Protocol.telemetry.dropped >= 1)
end)

Test.it("HELLO_ORDERS where summaries match produces no SUMMARY reply", function()
    local plugin = freshPlugin()
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = {} },  -- both peers know nothing — no diff
    }, "GUILD", REMOTE_KEY)
    Test.eq(#Loader.Wow.GetSentComm(), 0, "no follow-up; states already agree")
    Test.eq(plugin.Protocol.telemetry.helloReceived, 1)
end)

Test.it("HELLO_ORDERS where peer is ahead triggers a SUMMARY reply", function()
    local plugin = freshPlugin()
    -- Peer claims to have events from REMOTE_KEY up to seq 5; we have
    -- none. The summary maps differ, so we reply with our own SUMMARY.
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = { [REMOTE_KEY] = 5 } },
        helloId = "h-1",
    }, "GUILD", REMOTE_KEY)

    local sent = getLastSent()
    Test.truthy(sent)
    Test.eq(sent.message.kind, plugin.Protocol.KIND_SUMMARY)
    Test.eq(sent.target, REMOTE_KEY)
    Test.eq(sent.message.inReplyTo, "h-1")
end)

Test.it("SUMMARY_ORDERS where peer is ahead triggers an EVENTS_REQUEST", function()
    local plugin = freshPlugin()
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "SUMMARY_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = { [REMOTE_KEY] = 5 } },
    }, "WHISPER", REMOTE_KEY)

    local sent = getLastSent()
    Test.truthy(sent)
    Test.eq(sent.message.kind, plugin.Protocol.KIND_EVENTS_REQUEST)
    Test.eq(sent.target, REMOTE_KEY)
    local range = sent.message.requests[REMOTE_KEY]
    Test.truthy(range)
    Test.eq(range.fromSeq, 1)
    Test.eq(range.throughSeq, 5)
end)

Test.it("SUMMARY_ORDERS with no gaps stays silent", function()
    local plugin = freshPlugin()
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "SUMMARY_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = {} },
    }, "WHISPER", REMOTE_KEY)
    Test.eq(#Loader.Wow.GetSentComm(), 0)
end)

Test.it("EVENTS_REQUEST yields EVENTS_RESPONSE with matching log slices", function()
    local plugin = freshPlugin()
    -- Three local events (seqs 1..3) all from LOCAL_KEY producer.
    local order = plugin.Store:CreateDraft({
        requester = LOCAL_KEY, crafter = REMOTE_KEY,
        lines = { lineFor(929, 1) },
    })
    plugin.Store:AddLine(order.id, lineFor(929, 1))
    plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    clearSent()

    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "EVENTS_REQUEST", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        requests = { [LOCAL_KEY] = { fromSeq = 2, throughSeq = 3 } },
    }, "WHISPER", REMOTE_KEY)

    local sent = getLastSent()
    Test.truthy(sent)
    Test.eq(sent.message.kind, plugin.Protocol.KIND_EVENTS_RESPONSE)
    Test.eq(sent.target, REMOTE_KEY)
    Test.eq(#sent.message.events, 2)
    Test.eq(sent.message.events[1].seq, 2)
    Test.eq(sent.message.events[2].seq, 3)
end)

Test.it("EVENTS_REQUEST with empty match stays silent", function()
    local plugin = freshPlugin()
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "EVENTS_REQUEST", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        requests = { ["Unknown-Peer"] = { fromSeq = 1, throughSeq = 99 } },
    }, "WHISPER", REMOTE_KEY)
    Test.eq(#Loader.Wow.GetSentComm(), 0)
end)

Test.it("EVENTS_RESPONSE feeds the Reducer and materializes orders", function()
    local plugin = freshPlugin()
    local createEvent = {
        kind = "OrderCreated", orderId = "rr-ord-remote-7",
        producer = REMOTE_KEY, seq = 1, actor = REMOTE_KEY, at = 1700000000,
        payload = {
            requester = REMOTE_KEY, crafter = "Eve-OtherRealm",
            deliveryMode = "mail", notes = "", createdAt = 1700000000,
            lines = { lineFor(929, 2) }, lineCount = 1,
        },
    }
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "EVENTS_RESPONSE", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        events = { createEvent },
    }, "WHISPER", REMOTE_KEY)

    local order = plugin.Store:GetOrder("rr-ord-remote-7")
    Test.truthy(order, "reducer materialized the order")
    Test.eq(order.requester, REMOTE_KEY)
    Test.eq(plugin.Protocol.telemetry.eventsApplied, 1)
end)

Test.it("End-to-end: peer summary -> request -> response materializes remote orders", function()
    local plugin = freshPlugin()
    -- Simulate that the peer pre-shipped one event in a stash; we'll
    -- play it back when handling the EVENTS_REQUEST below.
    local peerLog = {
        {
            kind = "OrderCreated", orderId = "rr-ord-remote-end-to-end",
            producer = REMOTE_KEY, seq = 1, actor = REMOTE_KEY, at = 1700000001,
            payload = {
                requester = REMOTE_KEY, crafter = "Eve-OtherRealm",
                deliveryMode = "mail", notes = "", createdAt = 1700000001,
                lines = { lineFor(929, 1) }, lineCount = 1,
            },
        },
    }

    -- Step 1: peer sends HELLO advertising they have REMOTE_KEY seq=1.
    -- We respond with SUMMARY (our producers are empty).
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "HELLO_ORDERS", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        summary = { producers = { [REMOTE_KEY] = 1 } },
    }, "GUILD", REMOTE_KEY)
    local summaryReply = getLastSent()
    Test.eq(summaryReply.message.kind, plugin.Protocol.KIND_SUMMARY)

    -- Step 2: peer reads our SUMMARY, sees we're behind on REMOTE_KEY,
    -- and would send EVENTS_REQUEST. Simulate that:
    clearSent()
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "EVENTS_REQUEST", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        requests = { [LOCAL_KEY] = { fromSeq = 1, throughSeq = 999 } },  -- nothing for them from us
    }, "WHISPER", REMOTE_KEY)
    Test.eq(#Loader.Wow.GetSentComm(), 0, "we have no LOCAL_KEY events for them")

    -- Step 3: peer sends EVENTS_RESPONSE with what we should pull.
    plugin.Protocol:OnCommReceived(plugin.COMM_PREFIX, {
        kind = "EVENTS_RESPONSE", sender = REMOTE_KEY,
        wireVersion = plugin.WIRE_VERSION, buildChannel = plugin.BUILD_CHANNEL,
        events = peerLog,
    }, "WHISPER", REMOTE_KEY)

    Test.truthy(plugin.Store:GetOrder("rr-ord-remote-end-to-end"))
    Test.eq(plugin.Reducer:GetPeerHighWaterMark(REMOTE_KEY), 1)
end)

io.write(string.format("Craft Orders protocol: %d test(s) passed\n", Test.count))
