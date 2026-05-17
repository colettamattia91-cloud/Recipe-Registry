local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function countSentKind(rows, kind)
    local total = 0
    for _, row in ipairs(rows or {}) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function countKinds(rows, kinds)
    local total = 0
    for _, kind in ipairs(kinds or {}) do
        total = total + countSentKind(rows, kind)
    end
    return total
end

local function activeLegacyKinds()
    return {
        "AD",
        "IDX",
        "MANI",
        "MREQ",
    }
end

local function seedProfession(data, memberKey, professionKey, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end
    entry.guildStatus = "active"
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[professionKey] = {
        recipes = recipes,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        specialization = opts.specialization,
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = "active",
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkSyncIndexDirty(opts.reason or "test-seed")
    return entry
end

io.write("Sync phase 3/4 block pull\n")

Test.it("selected seed exchanges INDEX_DIFF and sequential BLOCK_PULL/BLOCK_SNAPSHOT only", function()
    local bus = CommBus.New({
        names = { "Requester", "Seed", "Smaller" },
    })
    local requester = bus:AddNode("Requester")
    local seed = bus:AddNode("Seed")
    local smaller = bus:AddNode("Smaller")

    bus:SeedSelfProfession(requester, {
        profession = "Alchemy",
        recipeCount = 1,
        baseRecipe = 1000,
    })
    bus:SeedSelfProfession(seed, {
        profession = "Alchemy",
        recipeCount = 3,
        baseRecipe = 2000,
    })
    bus:Activate(seed)
    seedProfession(seed.addon.Data, seed.key, "Tailoring", { 3001, 3002 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "seed-tailoring",
    })
    bus:SeedSelfProfession(smaller, {
        profession = "Alchemy",
        recipeCount = 2,
        baseRecipe = 4000,
    })

    requester.addon.Data:MarkSyncIndexDirty("requester-start")
    seed.addon.Data:MarkSyncIndexDirty("seed-start")
    smaller.addon.Data:MarkSyncIndexDirty("smaller-start")

    bus:Activate(requester)
    requester.addon.Sync:BroadcastHello()

    local settled = bus:RunUntil(function()
        local session = requester.addon.Sync.outboundSeedSession
        return session and session.state == "completed"
    end, {
        maxTicks = 220,
    })

    Test.truthy(settled, "requester should complete one outbound seed session")
    Test.eq(requester.addon.Sync.activeHelloCycle.selectedSeedKey, seed.key, "largest seed should be selected")
    Test.eq(countSentKind(requester.state.sentComm, "INDEX_DIFF_REQUEST"), 1, "requester should send one index diff request")
    Test.eq(countSentKind(seed.state.sentComm, "INDEX_DIFF_RESPONSE"), 1, "selected seed should answer with one index diff response")
    Test.eq(countSentKind(smaller.state.sentComm, "INDEX_DIFF_RESPONSE"), 0, "non-selected peer should not send index diff response")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 2, "requester should pull two offered blocks")
    Test.eq(countSentKind(seed.state.sentComm, "BLOCK_SNAPSHOT"), 2, "selected seed should send one snapshot per offered block")
    Test.eq(countKinds(requester.state.sentComm, activeLegacyKinds()), 0, "requester should not emit legacy traffic")
    Test.eq(countKinds(seed.state.sentComm, activeLegacyKinds()), 0, "seed should not emit legacy traffic")

    local replica = requester.addon.Data:GetMember(seed.key)
    Test.truthy(replica, "requester should store pulled seed owner")
    Test.truthy(replica.professions.Alchemy, "alchemy block should be merged")
    Test.truthy(replica.professions.Tailoring, "tailoring block should be merged")
    Test.eq(replica.professions.Alchemy.count or 0, 3, "alchemy count should match seed")
    Test.eq(replica.professions.Tailoring.count or 0, 2, "tailoring count should match seed")
end)

Test.it("requester does not ask for block N+1 before block N snapshot is merged", function()
    local delayedBlockKey = nil
    local delayedOnce = false
    local bus = CommBus.New({
        names = { "DelayedRequester", "DelayedSeed" },
        routeHook = function(_, senderNode, targetNode, row, payload)
            if senderNode and targetNode
                and senderNode.name == "DelayedSeed"
                and targetNode.name == "DelayedRequester"
                and type(payload) == "table"
                and payload.kind == "BLOCK_SNAPSHOT"
                and payload.blockKey == delayedBlockKey
                and not delayedOnce
            then
                delayedOnce = true
                return "delay", 5
            end
        end,
    })
    local requester = bus:AddNode("DelayedRequester")
    local seed = bus:AddNode("DelayedSeed")

    bus:SeedSelfProfession(seed, {
        profession = "Alchemy",
        recipeCount = 3,
        baseRecipe = 5000,
    })
    bus:Activate(seed)
    seedProfession(seed.addon.Data, seed.key, "Tailoring", { 6001, 6002 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "delay-tailoring",
    })
    delayedBlockKey = seed.addon.Data:BuildSyncBlockKey(seed.key, "Alchemy")

    bus:Activate(requester)
    requester.addon.Sync:BroadcastHello()

    local sawFirstPull = bus:RunUntil(function()
        return countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST") >= 1
    end, {
        maxTicks = 120,
    })

    Test.truthy(sawFirstPull, "first block pull should be sent")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 1, "only the first block pull should be sent while snapshot one is delayed")

    local settled = bus:RunUntil(function()
        local session = requester.addon.Sync.outboundSeedSession
        return session and session.state == "completed"
    end, {
        maxTicks = 240,
    })

    Test.truthy(settled, "delayed session should still complete")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 2, "second pull should be sent only after first merge completes")
end)

Test.it("INDEX_DIFF_REQUEST and BLOCK_PULL_REQUEST stay minimal on the wire", function()
    local bus = CommBus.New({
        names = { "MinimalRequester", "MinimalSeed" },
    })
    local requester = bus:AddNode("MinimalRequester")
    local seed = bus:AddNode("MinimalSeed")

    bus:SeedSelfProfession(requester, {
        profession = "Alchemy",
        recipeCount = 1,
        baseRecipe = 6100,
    })
    bus:SeedSelfProfession(seed, {
        profession = "Alchemy",
        recipeCount = 3,
        baseRecipe = 7100,
    })
    requester.addon.Data:MarkSyncIndexDirty("minimal-requester")
    seed.addon.Data:MarkSyncIndexDirty("minimal-seed")

    bus:Activate(requester)
    requester.addon.Sync:BroadcastHello()

    local sentPull = bus:RunUntil(function()
        return countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST") >= 1
    end, {
        maxTicks = 200,
    })

    Test.truthy(sentPull, "requester should reach the block pull stage")

    local diffPayload
    local pullPayload
    for _, row in ipairs(requester.state.sentComm or {}) do
        local message = row.message
        if type(message) == "table" and message.kind == "INDEX_DIFF_REQUEST" then
            diffPayload = message
        elseif type(message) == "table" and message.kind == "BLOCK_PULL_REQUEST" then
            pullPayload = message
            break
        end
    end

    Test.truthy(diffPayload, "index diff request payload should be captured")
    Test.truthy(type(diffPayload.requestId) == "string" and diffPayload.requestId ~= "", "index diff request id")
    Test.truthy(type(diffPayload.blocks) == "table", "index diff request should carry block digests")
    Test.eq(diffPayload.sessionId, nil, "index diff request should not carry sessionId")
    Test.eq(diffPayload.helloId, nil, "index diff request should not carry helloId")
    Test.eq(diffPayload.cycleId, nil, "index diff request should not carry cycleId")
    Test.eq(diffPayload.globalFingerprint, nil, "index diff request should not carry global fingerprint")
    Test.eq(diffPayload.activeOwnerCount, nil, "index diff request should not carry owner counts")
    Test.eq(diffPayload.activeBlockCount, nil, "index diff request should not carry block counts")
    Test.eq(diffPayload.activeContentCount, nil, "index diff request should not carry content counts")
    Test.eq(diffPayload.recipeKeys, nil, "index diff request should not carry recipe payload")
    Test.eq(diffPayload.metadata, nil, "index diff request should not carry metadata payload")

    Test.truthy(pullPayload, "block pull request payload should be captured")
    Test.truthy(type(pullPayload.requestId) == "string" and pullPayload.requestId ~= "", "block pull request id")
    Test.truthy(type(pullPayload.blockKey) == "string" and pullPayload.blockKey ~= "", "block pull request block key")
    Test.eq(pullPayload.expectedFingerprint, nil, "block pull request should not carry expectedFingerprint")
    Test.eq(pullPayload.offeredFingerprint, nil, "block pull request should not carry offeredFingerprint")
    Test.eq(pullPayload.knownFingerprint, nil, "block pull request should not carry knownFingerprint")
    Test.eq(pullPayload.knownRev, nil, "block pull request should not carry knownRev")
    Test.eq(pullPayload.wantRev, nil, "block pull request should not carry wantRev")
    Test.eq(pullPayload.sessionId, nil, "block pull request should not carry sessionId")
    Test.eq(pullPayload.helloId, nil, "block pull request should not carry helloId")
    Test.eq(pullPayload.cycleId, nil, "block pull request should not carry cycleId")
    Test.eq(pullPayload.metadata, nil, "block pull request should not carry metadata")
end)

Test.it("next block pull is scheduled after the internal delay once a block merge completes", function()
    local bus = CommBus.New({
        names = { "PacingRequester", "PacingSeed" },
    })
    local requester = bus:AddNode("PacingRequester")
    local seed = bus:AddNode("PacingSeed")

    bus:SeedSelfProfession(requester, {
        profession = "Alchemy",
        recipeCount = 1,
        baseRecipe = 8100,
    })
    bus:SeedSelfProfession(seed, {
        profession = "Alchemy",
        recipeCount = 3,
        baseRecipe = 9100,
    })
    bus:Activate(seed)
    seedProfession(seed.addon.Data, seed.key, "Tailoring", { 9201, 9202 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "pacing-tailoring",
    })
    requester.addon.Data:MarkSyncIndexDirty("pacing-requester")
    seed.addon.Data:MarkSyncIndexDirty("pacing-seed")

    bus:Activate(requester)
    requester.addon.Sync:BroadcastHello()

    local scheduled = bus:RunUntil(function()
        local session = requester.addon.Sync.outboundSeedSession
        return session
            and session.state == "waiting-next-block-delay"
            and session.nextBlockTimer ~= nil
    end, {
        maxTicks = 200,
    })

    local session = requester.addon.Sync.outboundSeedSession or {}
    Test.truthy(scheduled, "next block pull should enter the paced delay state")
    Test.eq(requester.addon.Sync._private.constants.BLOCK_PULL_DELAY_SECONDS, 1.0, "internal block pull delay constant")
    Test.truthy(type(session.nextBlockReadyAt) == "number" and session.nextBlockReadyAt > time(), "next block ready timestamp")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 1, "second block pull should not be sent inline with the merge")

    local completed = bus:RunUntil(function()
        local currentSession = requester.addon.Sync.outboundSeedSession
        return currentSession and currentSession.state == "completed"
    end, {
        maxTicks = 240,
    })

    Test.truthy(completed, "paced block pull session should still complete")
    Test.eq(requester.addon.Sync.telemetry.blockPullDelayed or 0, 1, "delay telemetry should record the scheduled follow-up")
    Test.eq(countSentKind(requester.state.sentComm, "BLOCK_PULL_REQUEST"), 2, "second block pull should be sent after the delay")
end)

Test.it("index diff does not offer a lower-count block back to a richer requester", function()
    local addon, wow = Loader.Load()
    local data = addon.Data
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()

    seedProfession(data, ownerKey, "Alchemy", { 7001 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "local-one",
    })
    local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")

    local response = data:BuildIndexDiffResponse({
        blocks = {
            [blockKey] = {
                count = 2,
                fingerprint = "different-fingerprint",
            },
        },
    }, {
        reason = "higher-requester",
    })

    Test.eq(#(response.offeredBlocks or {}), 0, "seed should not offer a lower-count block back to the requester")
end)

Test.it("session timeout abort commits the pending global fingerprint", function()
    local addon, wow = Loader.Load()
    local data = addon.Data
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()

    seedProfession(data, ownerKey, "Alchemy", { 8001 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "baseline",
    })
    local baseline = data:BuildLocalSummary({
        reason = "baseline-summary",
    })

    seedProfession(data, ownerKey, "Alchemy", { 8001, 8002 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "changed-before-timeout",
    })
    local liveFingerprint = data:GetLiveSyncIndex({
        reason = "live-before-timeout",
    }).globalFingerprint
    addon.Sync.outboundSeedSession = {
        state = "waiting-index-diff",
        seedKey = "Timeoutpeer-TestRealm",
        sessionId = "timeout-session",
        startedAt = time() - 100,
        lastProgressAt = time() - 100,
    }

    addon.Sync:ProcessRequestQueue()

    local state = data:GetSyncIndexDebugState()
    Test.eq(addon.Sync.outboundSeedSession.state, "aborted", "session should abort on timeout")
    Test.ne(baseline.globalFingerprintCommitted, liveFingerprint, "test setup should change the live fingerprint")
    Test.eq(state.committedGlobalFingerprint, liveFingerprint, "abort should commit the pending global fingerprint")
    Test.falsy(state.globalFingerprintDirty, "abort commit should clear dirty state")
end)

io.write(string.format("Sync phase 3/4 block pull: %d test(s) passed\n", Test.count))
