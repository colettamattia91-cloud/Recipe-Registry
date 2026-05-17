local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function countCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function withModernVersion(addon, payload)
    payload = payload or {}
    payload.addonVersion = payload.addonVersion or addon.ADDON_VERSION
    payload.wireVersion = payload.wireVersion or addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or addon.BUILD_CHANNEL
    payload.caps = payload.caps or (addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil)
    return payload
end

io.write("Sync phase 1 unsupported message\n")

Test.it("ignores unknown inbound kinds without mutating runtime sync state", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        helloId = "prime-hello",
        syncModel = "index-diff-block-pull",
        indexStatus = "ready",
        activeOwnerCount = 1,
        activeBlockCount = 1,
        activeContentCount = 1,
        globalFingerprint = "gf3:1:1:1:prime",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    local beforePeerCount = Test.countKeys(addon.Sync.peerVersions)
    local beforeOnlineCount = Test.countKeys(addon.Sync.onlineNodes)
    local beforeQueueCount = Test.countKeys(addon.Sync.pendingRequests)
    local beforeState = addon.Sync.outboundSeedSession and addon.Sync.outboundSeedSession.state or nil

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "UNSUPPORTED_KIND",
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.eq(Test.countKeys(addon.Sync.peerVersions), beforePeerCount, "unsupported kind should not mutate peer version state")
    Test.eq(Test.countKeys(addon.Sync.onlineNodes), beforeOnlineCount, "unsupported kind should not mutate online peer state")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), beforeQueueCount, "unsupported kind should not create queue state")
    Test.eq(addon.Sync.outboundSeedSession and addon.Sync.outboundSeedSession.state or nil, beforeState, "unsupported kind should not mutate seed session state")
    Test.falsy(addon.Sync.inFlight, "unsupported kind should not create in-flight work")
    Test.eq(countCommKind(wow, "BLOCK_PULL_REQUEST"), 0, "unsupported kind should not emit pull traffic")
    Test.eq(countCommKind(wow, "INDEX_DIFF_REQUEST"), 0, "unsupported kind should not emit diff traffic")
    Test.eq(countCommKind(wow, "BLOCK_SNAPSHOT"), 0, "unsupported kind should not emit snapshot traffic")
    Test.eq(addon.Sync.telemetry.unsupportedMessagesIgnored or 0, 1, "unsupported message telemetry should increment")
    Test.eq(addon.Sync.telemetry.lastUnsupportedMessageKind, "UNSUPPORTED_KIND", "unsupported message kind telemetry")
end)

Test.it("startup still sends one HELLO on the modern wire", function()
    local addon, wow = freshAddon()

    addon.Sync:Startup()
    wow.RunTimers(10)

    Test.eq(countCommKind(wow, "HELLO"), 1, "startup should still schedule one hello")
    Test.eq(addon.Sync.telemetry.unsupportedMessagesIgnored or 0, 0, "startup should not touch unsupported telemetry")
end)

io.write(string.format("Sync phase 1 unsupported message: %d test(s) passed\n", Test.count))
