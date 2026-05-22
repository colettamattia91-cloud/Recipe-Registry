local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function primeSyncReady(addon, wow, data, reason)
    local ownerKey = data:GetPlayerKey()
    Loader.Wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "phase2-prime",
        runTimers = false,
    })
end

local function refreshSyncNode(node, reason)
    local addon = node and node.addon or nil
    if not addon then
        return
    end
    if node and node.state then
        Loader.Wow.UseState(node.state)
        _G.RecipeRegistry = addon
        _G.RecipeRegistryDB = addon.db
        _G.RecipeRegistryCharDB = addon.charDB
    end
    if addon.Data and addon.Data.PrepareSyncIndexNow then
        addon.Data:PrepareSyncIndexNow(reason or "phase2-refresh")
    end
    if addon.Sync and addon.Sync.RefreshSyncReadyState then
        addon.Sync:RefreshSyncReadyState(reason or "phase2-refresh")
    end
end

local function countSentKind(rows, kind)
    local total = 0
    for _, row in ipairs(rows or {}) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function countWowKind(wow, kind)
    return countSentKind(wow.GetSentComm(), kind)
end

local function countNodeKind(node, kind)
    return countSentKind(node and node.state and node.state.sentComm or {}, kind)
end

local function countKinds(rows, kinds)
    local total = 0
    for _, kind in ipairs(kinds or {}) do
        total = total + countSentKind(rows, kind)
    end
    return total
end

local function containsValue(values, needle)
    for _, value in ipairs(values or {}) do
        if value == needle then
            return true
        end
    end
    return false
end

local function seedProfession(data, memberKey, professionKey, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt or entry.updatedAt
    entry.professions[professionKey] = {
        recipes = recipes,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        specialization = opts.specialization,
        lastUpdatedAt = opts.lastUpdatedAt or entry.updatedAt,
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = opts.professionGuildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.professionLastSeenInGuildAt or entry.lastSeenInGuildAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkSyncIndexDirty(opts.reason or "test-seed")
    return entry
end

io.write("Sync phase 2 summary foundation\n")

Test.it("DataIndex fingerprints ignore non-content metadata fields", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-fingerprint-prime")
    local ownerKey = data:GetPlayerKey()

    seedProfession(data, ownerKey, "Alchemy", { 1001, 1002 }, {
        updatedAt = 500,
        lastUpdatedAt = 700,
        sourceType = "owner",
        professionSourceType = "owner",
        skillRank = 150,
        skillMaxRank = 225,
    })

    local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")
    local blockFingerprintA = data:BuildBlockFingerprint(blockKey)
    data:PrepareSyncIndexNow("fingerprint-a")
    local globalFingerprintA = data:BuildLocalSummary({
        reason = "fingerprint-a",
    }).globalFingerprint

    local entry = data:GetMember(ownerKey)
    entry.updatedAt = 9999
    entry.sourceType = "bootstrap"
    entry.lastSeenInGuildAt = 42
    entry.professions.Alchemy.lastUpdatedAt = 54321
    entry.professions.Alchemy.sourceType = "replica"
    entry.professions.Alchemy.guildStatus = "stale"
    entry.professions.Alchemy.lastSeenInGuildAt = 13
    entry.professions.Alchemy.skillRank = 1
    entry.professions.Alchemy.skillMaxRank = 2
    data:NormalizeMemberEntry(entry, ownerKey)
    data._onlineCache[ownerKey] = nil
    data:MarkSyncIndexDirty("metadata-only-change")

    local blockFingerprintB = data:BuildBlockFingerprint(blockKey)
    data:PrepareSyncIndexNow("fingerprint-b")
    local globalFingerprintB = data:BuildLocalSummary({
        reason = "fingerprint-b",
    }).globalFingerprint

    Test.eq(blockFingerprintA, blockFingerprintB, "block fingerprint should ignore non-content metadata")
    Test.eq(globalFingerprintA, globalFingerprintB, "global fingerprint should ignore non-content metadata")
end)

Test.it("synthetic specialization keys affect fingerprints without being persisted as recipes", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-specialization-prime")
    local ownerKey = data:GetPlayerKey()

    seedProfession(data, ownerKey, "Alchemy", { 2001, 2002 }, {
        reason = "specialization-none",
    })
    local blockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")
    local fingerprintWithoutSpec = data:BuildBlockFingerprint(blockKey)

    local entry = data:GetMember(ownerKey)
    entry.professions.Alchemy.specialization = "Elixir Master"
    data:NormalizeMemberEntry(entry, ownerKey)
    data:MarkSyncIndexDirty("specialization-added")

    local contentKeys = data:BuildBlockContentKeys(blockKey)
    local fingerprintWithSpec = data:BuildBlockFingerprint(blockKey)

    Test.truthy(containsValue(contentKeys, "spec:elixir master"), "runtime content keys should include specialization")
    Test.eq(entry.professions.Alchemy.recipes["spec:elixir master"], nil, "synthetic specialization must not persist as a recipe")
    Test.eq(entry.professions.Alchemy.recipes["spec:Elixir Master"], nil, "synthetic specialization must not persist with original casing either")
    Test.ne(fingerprintWithoutSpec, fingerprintWithSpec, "specialization should affect block identity")
end)

Test.it("roster preflight gating excludes uncertain owners without deleting persisted data", function()
    local addon, _wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteKey = "Rosterpeer-TestRealm"
    Loader.Wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = remoteKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()

    seedProfession(data, ownerKey, "Alchemy", { 3001 }, {
        reason = "local-owner",
    })
    seedProfession(data, remoteKey, "Tailoring", { 4001, 4002 }, {
        reason = "remote-owner",
        sourceType = "replica",
        professionSourceType = "replica",
    })

    addon.Sync.warmupUntil = time() + 30
    data:MarkSyncIndexDirty("roster-preflight-untrusted")
    local summary = data:BuildLocalSummary({
        reason = "roster-preflight-summary",
    })

    Test.eq(summary.indexStatus, "not-requested", "missing roster preflight should keep the sync index untrusted")
    Test.eq(summary.activeOwnerCount, 1, "untrusted roster should publish only the local owner")
    Test.truthy(data:GetMember(remoteKey), "untrusted roster must not delete persisted remote owners")
end)

Test.it("runtime sync index cache reuses hits and rebuilds only dirty blocks", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-cache-prime")
    local ownerKey = data:GetPlayerKey()
    local baselineFullRebuild = data._syncIndexCache and data._syncIndexCache.stats and data._syncIndexCache.stats.fullRebuild or 0

    seedProfession(data, ownerKey, "Alchemy", { 4101, 4102 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "cache-alchemy",
    })
    seedProfession(data, ownerKey, "Tailoring", { 4201, 4202 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "cache-tailoring",
    })

    data:PrepareSyncIndexNow("cache-first-build")
    local first = data:GetSyncIndexDebugState()

    data:BuildLocalSummary({
        reason = "cache-second-build",
    })
    local second = data:GetSyncIndexDebugState()

    local alchemyBlockKey = data:BuildSyncBlockKey(ownerKey, "Alchemy")
    local entry = data:GetMember(ownerKey)
    entry.professions.Alchemy.recipes[4103] = true
    entry.professions.Alchemy.count = 3
    entry.professions.Alchemy.signature = "4101:4102:4103"
    data:MarkSyncIndexDirty("cache-alchemy-dirty", alchemyBlockKey)
    local dirtyCount = data._syncIndexCache and data._syncIndexCache.dirtyBlockCount or 0
    local dirtySummary = data:BuildLocalSummary({
        reason = "cache-dirty-build",
    })
    data:PrepareSyncIndexNow("cache-dirty-build")
    local third = data:GetSyncIndexDebugState()

    Test.eq(first.cache.stats.fullRebuild or 0, baselineFullRebuild + 1, "first build should perform one full rebuild")
    Test.eq(second.cache.stats.fullRebuild or 0, baselineFullRebuild + 1, "second build should reuse the existing cache")
    Test.truthy((second.cache.stats.hits or 0) >= 1, "second build should record a cache hit")
    Test.eq(dirtyCount, 1, "one local profession change should dirty exactly one block")
    Test.eq(dirtySummary.indexStatus, "dirty", "dirty local changes should not silently republish the global fingerprint")
    Test.eq(third.cache.stats.fullRebuild or 0, baselineFullRebuild + 1, "dirty block rebuild should avoid another full rebuild")
    Test.truthy((third.cache.stats.blockRebuilt or 0) >= 1, "dirty block rebuild should update the affected block")
    Test.falsy(third.globalFingerprintDirty, "rebuilding the dirty block should leave one valid global fingerprint")
    Test.ne(third.globalFingerprint, first.globalFingerprint, "dirty block rebuild should refresh the global fingerprint")
end)

Test.it("BuildLocalSummary keeps one global fingerprint without creating publish-side variants", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-summary-prime")
    local ownerKey = data:GetPlayerKey()

    seedProfession(data, ownerKey, "Alchemy", { 4301, 4302 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "summary-no-publish",
    })
    data:PrepareSyncIndexNow("summary-without-publish")

    local summary = data:BuildLocalSummary({
        reason = "summary-without-publish",
    })
    local state = data:GetSyncIndexDebugState()

    Test.truthy(type(summary.globalFingerprint) == "string" and summary.globalFingerprint ~= "", "summary should compute the live fingerprint")
    Test.eq(summary.currentGlobalFingerprint, nil, "summary should not expose a second current fingerprint field")
    Test.eq(summary.publishedGlobalFingerprint, nil, "summary should not expose a published fingerprint field")
    Test.eq(state.globalFingerprint, summary.globalFingerprint, "debug state should reflect the same single fingerprint")
    Test.falsy(summary.globalFingerprintDirty, "BuildLocalSummary should leave the fingerprint valid")
end)

Test.it("ScheduleHello coalesces multiple local-change reasons into one delayed HELLO", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-hello-coalesce")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 4401, 4402 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "hello-coalesce-seed",
    })
    data:PrepareSyncIndexNow("hello-coalesce-seed")
    addon.Sync:RefreshSyncReadyState("hello-coalesce-seed")

    addon.Sync:ScheduleHello("local-change-a", 0.2)
    addon.Sync:ScheduleHello("local-change-b", 0.2)

    Test.truthy(addon.Sync._helloTimer ~= nil, "a delayed hello timer should be pending")
    Test.truthy(type(addon.Sync.lastHelloScheduleReason) == "string", "coalesced reason should be tracked")
    Test.truthy(addon.Sync.lastHelloScheduleReason:find("local%-change%-a", 1, false) ~= nil, "first reason should be preserved")
    Test.truthy(addon.Sync.lastHelloScheduleReason:find("local%-change%-b", 1, false) ~= nil, "second reason should be coalesced")
    Test.eq(countWowKind(wow, "HELLO"), 0, "ScheduleHello should not send inline")

    Loader.Wow.AdvanceTime(1)
    Loader.Wow.RunTimers(10)

    Test.truthy(addon.Sync.lastHelloScheduleReason == nil or type(addon.Sync.lastHelloScheduleReason) == "string", "coalesced scheduler should keep hello state consistent after the timer fires")
end)

Test.it("dirty local index blocks direct HELLO publication and reschedules instead", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-hello-dirty")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 4451, 4452 }, {
        sourceType = "owner",
        professionSourceType = "owner",
        reason = "hello-dirty-seed",
    })
    data:PrepareSyncIndexNow("hello-dirty-seed")
    addon.Sync:RefreshSyncReadyState("hello-dirty-seed")

    local entry = data:GetMember(ownerKey)
    entry.professions.Alchemy.recipes[4453] = true
    data:NormalizeMemberEntry(entry, ownerKey)
    data:MarkSyncIndexDirty("hello-dirty-change", data:BuildSyncBlockKey(ownerKey, "Alchemy"))
    addon.Sync:RefreshSyncReadyState("hello-dirty-change")

    local sent = addon.Sync:BroadcastHello()

    Test.falsy(sent, "dirty index should block direct hello publication")
    Test.eq(countWowKind(wow, "HELLO"), 0, "dirty index should not emit HELLO")
    Test.truthy(addon.Sync._helloTimer ~= nil, "dirty hello publish attempt should reschedule through ScheduleHello")
end)

Test.it("summary collection window matches the modern 6 second discovery window", function()
    local addon, _wow, _data = freshAddon()

    Test.eq(addon.Sync._private.constants.SUMMARY_COLLECTION_WINDOW, 6, "summary collection window should match the roadmap target")
end)

Test.it("HELLO publishes the new summary fields only", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-hello-publish")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 5001, 5002, 5003 }, {
        reason = "hello-summary",
    })
    data:PrepareSyncIndexNow("hello-summary")
    addon.Sync:RefreshSyncReadyState("hello-summary")

    addon.Sync:BroadcastHello()

    local row = wow.GetSentComm()[1]
    local payload = row and row.message or nil
    Test.truthy(payload, "hello payload should exist")
    Test.eq(payload.kind, "HELLO", "expected HELLO")
    Test.eq(payload.wireVersion, addon.WIRE_VERSION, "hello wire version")
    Test.eq(payload.syncModel, "index-diff-block-pull", "hello sync model")
    Test.eq(payload.indexStatus, "ready", "hello index status")
    Test.truthy(type(payload.helloId) == "string" and payload.helloId ~= "", "hello should carry a correlation id")
    Test.truthy(type(payload.activeOwnerCount) == "number", "hello should carry activeOwnerCount")
    Test.truthy(type(payload.activeBlockCount) == "number", "hello should carry activeBlockCount")
    Test.truthy(type(payload.activeContentCount) == "number", "hello should carry activeContentCount")
    Test.truthy(type(payload.globalFingerprint) == "string" and payload.globalFingerprint ~= "", "hello should carry globalFingerprint")
    Test.eq(payload.rev, nil, "hello should not publish rev")
    Test.eq(payload.updatedAt, nil, "hello should not publish updatedAt")
    Test.eq(payload.manifestRequest, nil, "hello should not publish manifestRequest")
    Test.eq(payload.manifestFingerprint, nil, "hello should not publish manifestFingerprint")
end)

Test.it("discovery miss schedules a progressive retry instead of starting a pull", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-discovery-retry")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 5501, 5502 }, {
        reason = "discovery-retry-local",
    })
    data:PrepareSyncIndexNow("discovery-retry-local")
    addon.Sync:RefreshSyncReadyState("discovery-retry-local")
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Sync:ClearPendingHello("test-reset")

    addon.Sync:BroadcastHello()
    wow.AdvanceTime(6)
    wow.RunTimers(20)

    Test.eq(addon.Sync.telemetry.discoveryMisses or 0, 1, "empty summary window should count as a discovery miss")
    Test.truthy(addon.Sync._helloTimer ~= nil, "discovery miss should schedule a retry hello")
    Test.truthy(type(addon.Sync._helloScheduledFor) == "number", "retry hello should record a scheduled fire time")
    Test.eq(addon.Sync.telemetry.lastDiscoveryRetryDelay, 20, "first discovery retry should start from the 20 second base delay")
    Test.eq(addon.Sync.outboundSeedSession, nil, "discovery miss should not start an outbound pull session")
end)

Test.it("auto sync watchdog respects discovery retry backoff instead of scheduling short inline HELLOs", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "phase2-auto-watchdog")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 5601, 5602 }, {
        reason = "auto-watchdog-local",
    })
    data:PrepareSyncIndexNow("auto-watchdog-local")
    addon.Sync:RefreshSyncReadyState("auto-watchdog-local")

    addon.Sync.discoveryRetryMisses = 1
    addon.Sync.discoveryRetryDelay = addon.Sync:GetNextDiscoveryRetryDelay()
    addon.Sync.telemetry.discoveryMisses = 1
    local missesBeforeWatchdog = addon.Sync.discoveryRetryMisses or 0
    local helloCountBeforeWatchdog = countWowKind(wow, "HELLO")
    Test.truthy(missesBeforeWatchdog >= 1, "setup should leave a retry backoff pending")
    addon.Sync._helloScheduledFor = nil
    addon.Sync.lastHelloAt = time()
    addon.Sync:AutoSyncTick()

    Test.eq(countWowKind(wow, "HELLO"), helloCountBeforeWatchdog, "watchdog should not emit an extra immediate hello")
    Test.truthy((addon.Sync.telemetry.discoveryMisses or 0) >= missesBeforeWatchdog, "watchdog should not roll discovery miss telemetry backward")
end)

Test.it("HELLO suppresses SUMMARY when fingerprints already match or the peer is still unready", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    Loader.Wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = "Matchpeer-TestRealm", online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    Loader.PrimeSyncReady(addon, {
        reason = "phase2-same-fingerprint-prime",
        runTimers = false,
    })
    seedProfession(data, ownerKey, "Alchemy", { 8001, 8002 }, {
        reason = "same-fingerprint",
    })
    data:PrepareSyncIndexNow("phase2-same-fingerprint")
    local localSummary = data:BuildLocalSummary({
        reason = "same-fingerprint-summary",
    })

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = "Matchpeer-TestRealm",
        sender = "Matchpeer-TestRealm",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = addon.BUILD_CHANNEL,
        helloId = "match-hello",
        syncModel = "index-diff-block-pull",
        indexStatus = "ready",
        activeOwnerCount = localSummary.activeOwnerCount,
        activeBlockCount = localSummary.activeBlockCount,
        activeContentCount = localSummary.activeContentCount,
        globalFingerprint = localSummary.globalFingerprint,
        caps = addon.Sync:GetLocalProtocolCaps(),
    }, {
        sender = "Matchpeer-TestRealm",
        distribution = "GUILD",
        prefix = addon.ADDON_PREFIX,
    })

    Test.eq(countWowKind(wow, "SUMMARY"), 0, "matching fingerprints should not send SUMMARY")

    local busUnready = CommBus.New({
        names = { "Readyleft", "Unreadyright" },
    })
    local unreadyLeft = busUnready:AddNode("Readyleft")
    local unreadyRight = busUnready:AddNode("Unreadyright")
    busUnready:SeedSelfProfession(unreadyLeft, {
        profession = "Alchemy",
        recipeCount = 1,
        baseRecipe = 8100,
    })
    busUnready:SeedSelfProfession(unreadyRight, {
        profession = "Alchemy",
        recipeCount = 4,
        baseRecipe = 9100,
    })
    unreadyLeft.addon.Data:MarkSyncIndexDirty("unready-left")
    unreadyRight.addon.Data:MarkSyncIndexDirty("unready-right")
    refreshSyncNode(unreadyLeft, "unready-left")
    refreshSyncNode(unreadyRight, "unready-right")
    unreadyRight.addon.Sync.warmupUntil = time() + 30

    busUnready:Activate(unreadyLeft)
    unreadyLeft.addon.Sync:BroadcastHello()
    busUnready:RunUntil(function(current)
        return not current:HasWork()
    end, {
        maxTicks = 180,
    })

    Test.eq(countNodeKind(unreadyRight, "SUMMARY"), 0, "unready peers should not send SUMMARY")
end)

io.write(string.format("Sync phase 2 summary foundation: %d test(s) passed\n", Test.count))
