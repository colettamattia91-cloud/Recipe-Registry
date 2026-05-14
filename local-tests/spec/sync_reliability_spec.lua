local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
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

local function lastCommByKind(wow, kind)
    for index = #wow.GetSentComm(), 1, -1 do
        local row = wow.GetSentComm()[index]
        if type(row.message) == "table" and row.message.kind == kind then
            return row.message
        end
    end
    return nil
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function withModernVersion(addon, payload)
    payload = payload or {}
    payload.addonVersion = payload.addonVersion or addon.ADDON_VERSION
    payload.wireVersion = payload.wireVersion or addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or addon.BUILD_CHANNEL
    payload.caps = payload.caps or (addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil)
    return payload
end

local function captureIdleRequestState(sync)
    return {
        pendingRequests = Test.countKeys(sync.pendingRequests),
        activeRequests = sync:GetActiveRequestCount(),
        inFlight = sync:GetInFlightRequest(),
        requestTimeoutInitial = sync.telemetry.requestTimeoutInitial or 0,
        requestTimeoutProgress = sync.telemetry.requestTimeoutProgress or 0,
        requestTimeoutSession = sync.telemetry.requestTimeoutSession or 0,
        peerBackoff = Test.countKeys(sync.peerBackoffUntil),
    }
end

local function assertIdleRequestState(sync, before, label)
    Test.eq(Test.countKeys(sync.pendingRequests), before.pendingRequests, label .. " should not add pending requests")
    Test.eq(sync:GetActiveRequestCount(), before.activeRequests, label .. " should not add active requests")
    Test.eq(sync:GetInFlightRequest(), before.inFlight, label .. " should not create an in-flight request")
    Test.eq(sync.telemetry.requestTimeoutInitial or 0, before.requestTimeoutInitial, label .. " should not touch initial timeout telemetry")
    Test.eq(sync.telemetry.requestTimeoutProgress or 0, before.requestTimeoutProgress, label .. " should not touch progress timeout telemetry")
    Test.eq(sync.telemetry.requestTimeoutSession or 0, before.requestTimeoutSession, label .. " should not touch session timeout telemetry")
    Test.eq(Test.countKeys(sync.peerBackoffUntil), before.peerBackoff, label .. " should not create peer backoff state")
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or "owner"
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
    })
    return entry
end

io.write("Sync reliability\n")

Test.it("uses relaxed timeout constants", function()
    local addon, _wow, _data = freshAddon()
    local constants = addon.Sync._private.constants

    Test.eq(constants.REQUEST_TIMEOUT, 25, "request timeout constant")
    Test.eq(constants.PROGRESS_TIMEOUT, 8, "progress timeout constant")
    Test.eq(constants.SESSION_TIMEOUT, 60, "session timeout constant")
end)

Test.it("combat does not pause REQ or SNAP protocol traffic", function()
    local addon, wow, _data = freshAddon()

    wow.SetCombat(true)
    addon.SyncPausePolicy:RefreshPauseState()

    Test.falsy(addon.SyncPausePolicy:ShouldPauseProtocolTraffic("REQ"), "REQ should stay active in combat")
    Test.falsy(addon.SyncPausePolicy:ShouldPauseProtocolTraffic("SNAP"), "SNAP should stay active in combat")
    Test.truthy(addon.SyncPausePolicy:ShouldPauseHeavyUI(), "heavy UI can still pause in combat")
end)

Test.it("REQ received in instance returns RERR instead of timing out silently", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    seedProfession(data, data:GetPlayerKey(), "Cooking", 99001, { sourceType = "owner" })
    wow.SetInstance(true, "raid")
    addon.SyncPausePolicy:RefreshPauseState()

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "REQ",
        key = data:GetPlayerKey(),
        knownRev = 0,
        wantRev = 1,
        requestId = "req-instance",
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    local reject = lastCommByKind(wow, "RERR")
    Test.truthy(reject, "paused instance should emit RERR")
    Test.eq(reject.reason, "PAUSED_INSTANCE", "paused instance reject reason")
    Test.eq(countCommKind(wow, "SNAP"), 0, "paused instance should not emit SNAP")
end)

Test.it("missing entry returns NO_ENTRY immediately", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "REQ",
        key = "Missingone-TestRealm",
        knownRev = 0,
        wantRev = 5,
        requestId = "req-missing",
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    local reject = lastCommByKind(wow, "RERR")
    Test.truthy(reject, "missing entry should reject")
    Test.eq(reject.reason, "NO_ENTRY", "missing entry reason")
end)

Test.it("missing requested block returns NO_REQUESTED_BLOCK", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-TestRealm"
    local selfKey = data:GetPlayerKey()

    seedProfession(data, selfKey, "Cooking", 99002, { sourceType = "owner" })
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "REQ",
        key = selfKey,
        knownRev = 0,
        wantRev = 1,
        requestId = "req-block",
        requestedBlocks = {
            data:BuildSyncBlockKey(selfKey, "Alchemy"),
        },
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    local reject = lastCommByKind(wow, "RERR")
    Test.truthy(reject, "missing requested block should reject")
    Test.eq(reject.reason, "NO_REQUESTED_BLOCK", "missing requested block reason")
end)

Test.it("empty snapshot build returns EMPTY_SNAPSHOT", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Peerone-TestRealm"
    local selfKey = data:GetPlayerKey()
    local originalBuild = data.BuildSnapshotChunks

    seedProfession(data, selfKey, "Cooking", 99003, { sourceType = "owner", rev = 1 })
    data.BuildSnapshotChunks = function()
        return {}
    end

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "REQ",
        key = selfKey,
        knownRev = 0,
        wantRev = 1,
        requestId = "req-empty",
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    data.BuildSnapshotChunks = originalBuild
    local reject = lastCommByKind(wow, "RERR")
    Test.truthy(reject, "empty snapshot should reject")
    Test.eq(reject.reason, "EMPTY_SNAPSHOT", "empty snapshot reason")
end)

Test.it("requester clears in-flight state on permanent RERR", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    addon.Sync:SetInFlightRequest({
        source = peerKey,
        memberKey = peerKey,
        rev = 7,
        why = "index",
        startedAt = time(),
        lastProgressAt = time(),
        attempts = 1,
        requestId = "req-live",
    })

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "RERR",
        key = peerKey,
        requestId = "req-live",
        reason = "NO_ENTRY",
        retryable = false,
        sender = peerKey,
    }), {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.falsy(addon.Sync:GetInFlightRequest(peerKey), "RERR should clear in-flight request")
    Test.eq(addon.Sync.telemetry.rejectsTotal or 0, 1, "reject telemetry should increment")
    Test.eq(addon.Sync.telemetry.lastRejectReason, "NO_ENTRY", "last reject reason should be recorded")
end)

Test.it("auto-tick does not queue a peer already in backoff", function()
    local addon, _wow, _data = freshAddon()
    local peerKey = "Backoffpeer-TestRealm"

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.8.1" }
    addon.Sync.registry[peerKey] = {
        owner = peerKey,
        rev = 10,
        updatedAt = 1000,
    }
    addon.Sync.peerBackoffUntil[peerKey] = time() + 30

    addon.Sync:AutoSyncTick()

    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "auto-tick should skip backoff peer")
    Test.eq(addon.Sync.telemetry.queuedBackoff or 0, 1, "queuedBackoff telemetry should increment")
end)

Test.it("queue dispatch skips oldest backoffed peer and continues with healthy peer", function()
    local addon, wow, _data = freshAddon()
    local backoffPeer = "Backoffpeer-TestRealm"
    local healthyPeer = "Healthypeer-TestRealm"

    addon.Sync.onlineNodes[backoffPeer] = { lastSeen = time(), version = "1.8.1" }
    addon.Sync.onlineNodes[healthyPeer] = { lastSeen = time(), version = "1.8.1" }
    addon.Sync.peerBackoffUntil[backoffPeer] = time() + 60
    addon.Sync.pendingRequests["Memberone-TestRealm"] = {
        source = backoffPeer,
        memberKey = "Memberone-TestRealm",
        rev = 4,
        why = "auto-tick",
        queuedAt = time() - 10,
    }
    addon.Sync.pendingRequests["Membertwo-TestRealm"] = {
        source = healthyPeer,
        memberKey = "Membertwo-TestRealm",
        rev = 5,
        why = "index",
        queuedAt = time(),
    }

    addon.Sync:ProcessRequestQueue()

    Test.truthy(addon.Sync:GetInFlightRequest("Membertwo-TestRealm"), "healthy peer should dispatch")
    Test.eq(addon.Sync:GetInFlightRequest("Membertwo-TestRealm").source, healthyPeer, "healthy source should win")
    Test.eq(addon.Sync.pendingRequests["Memberone-TestRealm"], nil, "automatic backoff request should be purged")
    Test.eq(countCommKind(wow, "REQ"), 1, "only healthy REQ should be sent")
end)

Test.it("IDX skips self-owner hints without queuing direct request state", function()
    local addon, wow, data = freshAddon()
    local coordinatorKey = "Coordinator-TestRealm"
    local selfKey = data:GetPlayerKey()
    local before = captureIdleRequestState(addon.Sync)

    wow.SetGuildRoster({ coordinatorKey })
    data:RebuildOnlineCache()
    addon.Sync.coordinatorKey = coordinatorKey

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "IDX",
        key = selfKey,
        owner = selfKey,
        rev = 9,
        updatedAt = 900,
        sender = coordinatorKey,
    }), {
        sender = coordinatorKey,
        distribution = "GUILD",
    })

    assertIdleRequestState(addon.Sync, before, "self-owner IDX")
    Test.eq(countCommKind(wow, "REQ"), 0, "self-owner IDX should not emit REQ traffic")
    Test.eq(addon.Sync.telemetry.indexSkippedLocalOwners or 0, 1, "self-owner IDX should increment local-owner skip telemetry")
    Test.eq(addon.Sync.telemetry.indexSkippedImpossibleOwners or 0, 0, "self-owner IDX should not increment impossible-owner telemetry")
end)

Test.it("IDX skips offline-owner replica hints without queuing impossible requests", function()
    local addon, wow, data = freshAddon()
    local coordinatorKey = "Coordinator-TestRealm"
    local offlineOwner = "Offlineowner-TestRealm"
    local before = captureIdleRequestState(addon.Sync)

    wow.SetGuildRoster({ coordinatorKey })
    data:RebuildOnlineCache()
    addon.Sync.coordinatorKey = coordinatorKey

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "IDX",
        key = offlineOwner,
        owner = offlineOwner,
        rev = 11,
        updatedAt = 1100,
        sender = coordinatorKey,
    }), {
        sender = coordinatorKey,
        distribution = "GUILD",
    })

    assertIdleRequestState(addon.Sync, before, "offline-owner IDX")
    Test.eq(countCommKind(wow, "REQ"), 0, "offline-owner IDX should not emit REQ traffic")
    Test.eq(addon.Sync.telemetry.indexSkippedLocalOwners or 0, 0, "offline-owner IDX should not increment local-owner telemetry")
    Test.eq(addon.Sync.telemetry.indexSkippedImpossibleOwners or 0, 1, "offline-owner IDX should increment impossible-owner telemetry")
end)

Test.it("manifest health stays good while snapshot health is bad", function()
    local addon, _wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.8.1" }
    addon.Sync:MarkManifestPeerSuccess(peerKey)
    addon.Sync:MarkPeerFailure(peerKey, "initial-timeout", { why = "index" })
    addon.Sync:MarkPeerFailure(peerKey, "initial-timeout", { why = "index" })
    local breakdown = addon.Sync:GetPeerEligibilityBreakdown()

    Test.truthy((addon.Sync.peerHealth[peerKey].manifestSuccesses or 0) >= 1, "manifest health should record success")
    Test.truthy(addon.Sync:IsPeerBackoffActive(peerKey), "snapshot failures should back off the peer")
    Test.eq(breakdown.manifestHealthy, 1, "manifest health count")
    Test.eq(breakdown.snapshotHealthy, 0, "snapshot health count")
    Test.eq(breakdown.manifestOnly, 1, "manifest-only count")
end)

Test.it("stale partial manifests soft-timeout before hard prune", function()
    local addon, wow, _data = freshAddon()
    addon.debugMode = true

    addon.Sync.partialManifestReceive["Peerone-TestRealm"] = {
        ["manifest-1"] = {
            builtAt = time() - 90,
            memberKey = "Peerone-TestRealm",
            total = 2,
            seen = { [1] = true },
            blocks = {},
        },
    }

    addon.Sync:PrunePartialManifestReceives()

    local softState = addon.Sync.partialManifestReceive["Peerone-TestRealm"]
        and addon.Sync.partialManifestReceive["Peerone-TestRealm"]["manifest-1"]
    Test.truthy(softState, "first timeout with received chunks should keep the partial open for recovery")
    Test.truthy(softState.recoveryRequestedAt, "soft timeout should mark recovery request state")
    Test.eq(addon.Sync.telemetry.manifestSoftTimeouts or 0, 1, "soft timeout telemetry")

    wow.AdvanceTime(addon.Sync._private.constants.SESSION_TIMEOUT + 1)
    addon.Sync:PrunePartialManifestReceives()

    Test.eq(addon.Sync.partialManifestReceive["Peerone-TestRealm"], nil, "stale partial manifest should be pruned")
    Test.eq(addon.Sync.telemetry.partialManifestPruned or 0, 1, "partial manifest prune telemetry")
    Test.truthy(printLogContains(wow, "Manifest prune peer=Peerone-TestRealm manifestId=manifest-1 received=1/2 reason=timeout"), "prune diagnostics should include manifest details")
end)

Test.it("duplicate crafter rows are collapsed per member", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "Crafterone-TestRealm"

    seedProfession(data, memberKey, "Alchemy", 99501, { sourceType = "owner" })
    seedProfession(data, memberKey, "Cooking", 99501, { sourceType = "owner" })

    local index = data:BuildRecipeIndex()
    local row = index[99501]
    local diagnostics = data:GetCatalogDiagnostics()

    Test.truthy(row, "recipe index row should exist")
    Test.eq(#(row.crafterRows or {}), 1, "duplicate crafter rows should collapse")
    Test.eq(row.crafterCount or 0, 1, "crafter count should remain unique")
    Test.eq(diagnostics.duplicateCrafterRowsCollapsed or 0, 1, "catalog diagnostics should record collapse")
    Test.eq(addon.Sync.telemetry.duplicateCrafterRowsCollapsed or 0, 1, "sync telemetry should record collapse")
end)

io.write(string.format("Sync reliability: %d test(s) passed\n", Test.count))
