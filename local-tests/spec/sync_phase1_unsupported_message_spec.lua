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
        reason = reason or "phase1-prime",
        runTimers = false,
    })
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

Test.it("saved variables become ready at addon init without sending sync traffic", function()
    local addon, wow = freshAddon()

    Test.truthy(addon.Sync.savedVariablesReady, "saved variables should be ready immediately after addon init")
    Test.eq(addon.Sync.lastSavedVariablesReadyReason, "addon-initialize", "saved variables should be wired through addon initialization")
    Test.falsy(addon.Sync.playerReady, "player readiness should still wait for PLAYER_LOGIN")
    Test.falsy(addon.Sync.syncReady, "sync should stay gated before player/world/roster/index readiness")
    Test.eq(countCommKind(wow, "HELLO"), 0, "addon init should not emit hello traffic")
end)

Test.it("PLAYER_LOGIN and PLAYER_ENTERING_WORLD keep sync quiet until the full readiness gate is satisfied", function()
    local addon, wow, data = freshAddon()
    Loader.Enable(addon)

    addon:OnPlayerLogin()
    Test.truthy(addon.Sync.playerReady, "PLAYER_LOGIN should mark player readiness")
    Test.eq(countCommKind(wow, "HELLO"), 0, "PLAYER_LOGIN should not broadcast hello inline")

    addon:OnPlayerEnteringWorld(nil, true, false)
    Test.truthy(addon.Sync:IsInWorldTransition(), "PLAYER_ENTERING_WORLD should enter world transition gating")
    Test.eq(countCommKind(wow, "HELLO"), 0, "PLAYER_ENTERING_WORLD should not broadcast hello inline")

    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    addon.Sync.worldTransitionUntil = 0
    addon:OnGuildRosterUpdate()
    data:PrepareSyncIndexNow("phase1-ready")
    addon.Sync:RefreshSyncReadyState("phase1-ready")

    Test.truthy(addon.Sync.syncReady, "syncReady should transition only after roster/index/world gates are satisfied")
    Test.truthy(addon.Sync._helloTimer ~= nil, "syncReady transition should schedule hello through the delayed path")
    Test.eq(countCommKind(wow, "HELLO"), 0, "syncReady transition should not broadcast hello inline")
    Test.eq(addon.Sync.lastSyncReadyReason, "phase1-ready", "fixed watchdog timer should not be required for readiness correctness")
end)

Test.it("paused runtime blocks sync traffic while keeping local data accessible", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase1-pause")
    local ownerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(ownerKey)
    entry.professions.Alchemy = entry.professions.Alchemy or {
        recipes = { [1001] = true },
        count = 1,
        signature = "1001",
        skillRank = 1,
        skillMaxRank = 75,
    }
    data:NormalizeMemberEntry(entry, ownerKey)
    data:PrepareSyncIndexNow("phase1-pause-index")

    wow.SetInstance(true, "party")
    addon.SyncPausePolicy:RefreshPauseState()
    local helloBefore = countCommKind(wow, "HELLO")
    local sent = addon.Sync:BroadcastHello()

    Test.falsy(sent, "paused runtime should refuse direct hello broadcast attempts")
    Test.eq(countCommKind(wow, "HELLO"), helloBefore, "paused runtime should not emit new hello traffic")
    Test.truthy(data:GetMember(ownerKey) ~= nil, "paused runtime should still expose local saved-variable data")
end)

io.write(string.format("Sync phase 1 unsupported message: %d test(s) passed\n", Test.count))
