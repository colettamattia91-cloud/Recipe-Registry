local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local PEER_COUNT = 240

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function key(prefix, index)
    return string.format("%s%03d-TestRealm", prefix, index)
end

local function makeRemote(data, index)
    local peerKey = key("Scalepeer", index)
    local ownerKey = key("Scaleowner", index)
    local profession = "Alchemy"
    local recipeKey = 120000 + index
    local revision = 5000 + index
    local blockKey = data:BuildSyncBlockKey(ownerKey, profession)
    return {
        peerKey = peerKey,
        ownerKey = ownerKey,
        profession = profession,
        recipeKey = recipeKey,
        revision = revision,
        updatedAt = 7000 + index,
        block = {
            blockKey = blockKey,
            ownerCharacter = ownerKey,
            professionKey = profession,
            revision = revision,
            lastUpdatedAt = 7000 + index,
            sourceType = "replica",
            guildStatus = "active",
            lastSeenInGuildAt = 7000 + index,
            count = 1,
            fingerprint = tostring(recipeKey),
        },
    }
end

local function withModernVersion(addon, payload)
    payload = payload or {}
    payload.addonVersion = payload.addonVersion or addon.ADDON_VERSION
    payload.wireVersion = payload.wireVersion or addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or addon.BUILD_CHANNEL
    payload.caps = payload.caps or (addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil)
    return payload
end

local function deliverPeerAnnouncement(addon, wow, remote)
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        sender = remote.peerKey,
        key = remote.peerKey,
        rev = 0,
        updatedAt = remote.updatedAt,
        version = "scale-test",
    }), { sender = remote.peerKey, distribution = "GUILD" })

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "MANI",
        sender = remote.peerKey,
        manifestId = "scale:" .. remote.peerKey,
        builtAt = remote.updatedAt,
        memberKey = remote.peerKey,
        totals = { blocks = 1, recipes = 1 },
        seq = 1,
        total = 1,
        blocks = { remote.block },
    }), { sender = remote.peerKey, distribution = "WHISPER" })
end

local function deliverSnapshotForRequest(addon, wow, remote, requestPayload)
    wow.DeliverComm(addon.Sync, {
        kind = "SNAP",
        sender = remote.peerKey,
        sessionId = "scale-snap:" .. remote.ownerKey .. ":" .. tostring(requestPayload.wantRev or remote.revision),
        key = remote.ownerKey,
        rev = remote.revision,
        updatedAt = remote.updatedAt,
        sourceType = "replica",
        profession = remote.profession,
        skillRank = 375,
        skillMaxRank = 375,
        recipeKeys = { remote.recipeKey },
        seq = 1,
        total = 1,
    }, { sender = remote.peerKey, distribution = "WHISPER" })
end

local function countScaleOwners(data)
    local count = 0
    local stale = 0
    local mock = 0
    for memberKey, entry in pairs(data:GetMembersDB()) do
        if type(memberKey) == "string" and memberKey:find("Scaleowner", 1, true) == 1 then
            count = count + 1
            if (entry.guildStatus or "active") ~= "active" then stale = stale + 1 end
            if entry.isMock then mock = mock + 1 end
        end
    end
    return count, stale, mock
end

local function pendingCost(sync)
    local owners = 0
    local blocks = 0
    for _, request in pairs(sync.pendingRequests or {}) do
        owners = owners + 1
        blocks = blocks + math.max(1, #(request.requestedBlocks or {}))
    end
    for _, request in pairs(sync.GetInFlightRequests and sync:GetInFlightRequests() or {}) do
        owners = owners + 1
        blocks = blocks + math.max(1, #(request.requestedBlocks or {}))
    end
    return owners, blocks
end

io.write("Manifest comm scale\n")

Test.it("converges hundreds of manifest catch-up requests through comm boundary under caps", function()
    local addon, wow, data = freshAddon()
    local remotes = {}
    local sentCursor = 0
    local maxOutstandingOwners = 0
    local maxOutstandingBlocks = 0

    for index = 1, PEER_COUNT do
        local remote = makeRemote(data, index)
        remotes[remote.ownerKey] = remote
        deliverPeerAnnouncement(addon, wow, remote)
    end

    Test.gte(addon.Sync.telemetry.manifestCatchupDeferred, 1, "large scale run should defer catch-up")

    local converged = false
    for _ = 1, 5000 do
        addon.Performance:RunNextStep()
        addon.Sync:ProcessRequestQueue()

        local owners, blocks = pendingCost(addon.Sync)
        if owners > maxOutstandingOwners then maxOutstandingOwners = owners end
        if blocks > maxOutstandingBlocks then maxOutstandingBlocks = blocks end

        local sent = wow.GetSentComm()
        while sentCursor < #sent do
            sentCursor = sentCursor + 1
            local row = sent[sentCursor]
            local payload = row and row.message
            if type(payload) == "table" and payload.kind == "REQ" then
                local remote = remotes[payload.key]
                Test.truthy(remote, "REQ should target a known scale owner")
                deliverSnapshotForRequest(addon, wow, remote, payload)
            end
        end

        addon.Sync:ProcessInboundQueue()
        addon.Sync:ProcessInboundQueue()

        local ownerCount = countScaleOwners(data)
        if ownerCount == PEER_COUNT
            and #(addon.Sync.manifestCatchupQueue or {}) == 0
            and Test.countKeys(addon.Sync.pendingRequests) == 0
            and addon.Sync:GetActiveRequestCount() == 0
            and #addon.Sync.inboundChunkQueue == 0
            and #addon.Sync.inboundFinalizeQueue == 0 then
            converged = true
            break
        end
        wow.AdvanceTime(0.25)
    end

    local ownerCount, staleCount, mockCount = countScaleOwners(data)
    Test.truthy(converged, "scale comm scenario should converge")
    Test.eq(ownerCount, PEER_COUNT, "all scale owners should be applied")
    Test.eq(staleCount, 0, "scale owners should not be stale")
    Test.eq(mockCount, 0, "scale owners should not be mock data")
    Test.gte(8, maxOutstandingOwners, "outstanding request owners should stay under cap")
    Test.gte(32, maxOutstandingBlocks, "outstanding requested blocks should stay under cap")
    Test.gte(addon.Sync.telemetry.requestConcurrencyMax or 0, 2, "scale run should actually use the bounded parallel request window")
    Test.truthy((addon.Sync.telemetry.requestConcurrencyMax or 0) <= addon.Sync:GetMaxConcurrentRequests(), "request concurrency should remain bounded even under scale load")
    Test.eq(#(addon.Sync.manifestCatchupQueue or {}), 0, "deferred queue should drain")
    Test.eq(addon.Sync.telemetry.manifestCatchupQueued, PEER_COUNT, "all catch-up requests should queue")
    Test.eq(addon.Sync.telemetry.replicaOwnersApplied, PEER_COUNT, "all replica owners should apply")
    Test.eq(addon.Sync.telemetry.replicaNewOwnersApplied, PEER_COUNT, "all scale owners should be new")
end)

io.write(string.format("Manifest comm scale: %d test(s) passed\n", Test.count))
