local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function primeSyncReady(addon, wow, data, reason)
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "inbound-debug-prime",
        runTimers = false,
    })
end

local function seedPeer(addon, peerKey)
    local caps = addon.Sync:GetLocalProtocolCaps()
    addon.Sync:ObservePeerVersion(peerKey, {
        sender = peerKey,
        addonVersion = addon.ADDON_VERSION,
        wireVersion = addon.WIRE_VERSION,
        buildChannel = addon.BUILD_CHANNEL,
        caps = caps,
    })
    addon.Sync:RecordPeerCaps(peerKey, caps)
end

io.write("Inbound seed debug\n")

Test.it("inbound seed diagnostics show open reject and pause-clear counters", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "inbound-debug")
    local maxInbound = addon.Sync._private.constants.MAX_INBOUND_SEED_SESSIONS or 4

    for index = 1, maxInbound do
        local peerKey = string.format("Inbounddebug%02d-TestRealm", index)
        seedPeer(addon, peerKey)
        local session = addon.Sync:RegisterInboundSeedSession(peerKey, string.format("REQ:%02d", index), {
            { blockKey = peerKey .. "::Alchemy" },
        })
        Test.truthy(session ~= nil, "inbound session within cap should be registered")
    end

    seedPeer(addon, "Inboundoverflow-TestRealm")
    local overflowSession, overflowReason = addon.Sync:RegisterInboundSeedSession("Inboundoverflow-TestRealm", "REQ:overflow", {
        { blockKey = "Inboundoverflow-TestRealm::Alchemy" },
    })
    Test.eq(overflowSession, nil, "overflow session should be rejected")
    Test.eq(overflowReason, "global-cap", "overflow session reject reason")

    addon.Sync.savedVariablesReady = false
    addon.Sync:RefreshSyncReadyState("inbound-not-ready")
    local allowed, rejectReason = addon.Sync:CanServeInboundSeed("Inbounddebug01-TestRealm")
    Test.falsy(allowed, "not-ready runtime should reject serving")
    Test.eq(rejectReason, "saved-variables", "not-ready rejection reason")
    addon.Sync.savedVariablesReady = true
    addon.Sync:RefreshSyncReadyState("inbound-ready")

    wow.SetInstance(true, "party")
    addon.SyncPausePolicy:RefreshPauseState()

    local snapshot = addon.Sync:GetRuntimeObservabilitySnapshot()
    Test.eq(snapshot.inboundSeed.activeCount, 0, "pause should clear inbound sessions")
    Test.truthy(snapshot.inboundSeed.rejectedCap > 0, "snapshot should report cap rejections")
    Test.truthy(snapshot.inboundSeed.rejectedNotReady > 0, "snapshot should report not-ready rejections")
    Test.truthy(snapshot.inboundSeed.clearedPause > 0, "snapshot should report pause clears")
end)

io.write(string.format("Inbound seed debug: %d test(s) passed\n", Test.count))
