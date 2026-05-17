local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function primeSyncReady(addon, wow, data, rosterRows, reason)
    wow.SetGuildRoster(rosterRows)
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "roster-prime",
        runTimers = false,
    })
end

local function seedProfession(data, memberKey, professionKey, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end
    entry.guildStatus = opts.guildStatus or "active"
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[professionKey] = {
        recipes = recipes,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = opts.professionGuildStatus or entry.guildStatus,
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkSyncIndexDirty(opts.reason or "roster-seed")
end

local function countDebugLogLines(addon, needle)
    local total = 0
    for _, entry in ipairs(addon:GetDebugLogEntries(500, "sync")) do
        if tostring(entry.message or ""):find(needle, 1, true) then
            total = total + 1
        end
    end
    return total
end

io.write("Sync roster invalidation\n")

Test.it("presence-only roster updates do not dirty the sync index or emit dirty logs", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    addon:GetDebugLogDB().enabled = true

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    }, "presence-only-prime")
    seedProfession(data, ownerKey, "Alchemy", { 1001, 1002 }, {
        reason = "presence-only-seed",
    })
    data:PrepareSyncIndexNow("presence-only-ready")
    addon.Sync:RefreshSyncReadyState("presence-only-ready")
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = time()
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Data._syncIndexPrepareTimer = nil
    addon.Sync:ResetTelemetry()
    addon:GetDebugLogDB().enabled = true

    wow.SetGuildRoster({
        { name = ownerKey, online = false, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    addon:ProcessCoalescedGuildRosterUpdate("presence-only")

    local state = data:GetSyncIndexDebugState()
    Test.falsy(state.globalFingerprintDirty, "presence-only update should not dirty the global fingerprint")
    Test.eq(addon.Sync.telemetry.globalFingerprintDirty or 0, 0, "presence-only update should not increment dirty telemetry")
    Test.eq(addon.Data._syncIndexPrepareTimer, nil, "presence-only update should not schedule a full index prepare")
    Test.eq(addon.Sync._helloTimer, nil, "presence-only update should not schedule hello")
    Test.eq(countDebugLogLines(addon, "global-fingerprint-dirty reason=roster-update"), 0, "presence-only update should not emit roster dirty logs")
end)

Test.it("unknown roster members do not affect the sync fingerprint or hello scheduling", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    }, "unknown-member-prime")
    seedProfession(data, ownerKey, "Alchemy", { 2001 }, {
        reason = "unknown-member-seed",
    })
    data:PrepareSyncIndexNow("unknown-member-ready")
    addon.Sync:RefreshSyncReadyState("unknown-member-ready")
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = time()
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Data._syncIndexPrepareTimer = nil
    addon.Sync:ResetTelemetry()

    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = "Unknownpeer-TestRealm", online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Warlock", classFileName = "WARLOCK" },
    })
    addon:ProcessCoalescedGuildRosterUpdate("unknown-member")

    local state = data:GetSyncIndexDebugState()
    Test.falsy(state.globalFingerprintDirty, "unknown roster members should not dirty the fingerprint")
    Test.eq(addon.Sync._helloTimer, nil, "unknown roster members should not schedule hello on their own")
    Test.truthy((addon.Sync.telemetry.rosterUnknownMembersIgnored or 0) >= 1, "unknown roster members should be counted as ignored for sync")
end)

Test.it("known owners leaving the guild dirty only the affected blocks and schedule recovery", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteKey = "Knownpeer-TestRealm"

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = remoteKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Priest", classFileName = "PRIEST" },
    }, "known-owner-prime")
    seedProfession(data, ownerKey, "Alchemy", { 3001 }, {
        reason = "known-owner-local",
    })
    seedProfession(data, remoteKey, "Tailoring", { 4001, 4002 }, {
        reason = "known-owner-remote",
        sourceType = "replica",
        professionSourceType = "replica",
    })
    data:PrepareSyncIndexNow("known-owner-ready")
    addon.Sync:RefreshSyncReadyState("known-owner-ready")
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = time()
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Data._syncIndexPrepareTimer = nil
    addon.Sync:ResetTelemetry()

    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    addon:ProcessCoalescedGuildRosterUpdate("known-owner-left")

    local remoteBlockKey = data:BuildSyncBlockKey(remoteKey, "Tailoring")
    local cache = data._syncIndexCache or {}
    Test.truthy(cache.dirtyBlocks and cache.dirtyBlocks[remoteBlockKey] == true, "known owner departure should dirty the affected block")
    Test.truthy(cache.globalFingerprintDirty == true, "known owner departure should dirty the global fingerprint")
    Test.truthy(addon.Data._syncIndexPrepareTimer ~= nil, "known owner departure should schedule index prepare")
    Test.truthy(addon.Sync._helloTimer ~= nil, "known owner departure should schedule hello through the coalesced path")
end)

Test.it("trusted roster ready transition schedules one prepare but repeated ready updates stay sync-noop", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    }, "trusted-transition-prime")
    seedProfession(data, ownerKey, "Alchemy", { 5001 }, {
        reason = "trusted-transition-seed",
    })
    addon.Sync.warmupUntil = time() + 30
    data:BuildLocalSummary({
        reason = "trusted-transition-unready",
    })
    addon.Sync:RefreshSyncReadyState("trusted-transition-unready")
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = time()
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Data._syncIndexPrepareTimer = nil
    addon.Sync:ResetTelemetry()

    addon.Sync.warmupUntil = 0
    addon:ProcessCoalescedGuildRosterUpdate("trusted-transition-ready")
    Test.truthy(addon.Data._syncIndexPrepareTimer ~= nil, "trusted ready transition should schedule one prepare")
    local relevantAfterFirst = addon.Sync.telemetry.rosterSyncRelevantUpdates or 0

    addon.Data._syncIndexPrepareTimer = nil
    addon:ProcessCoalescedGuildRosterUpdate("trusted-transition-repeat")
    Test.eq(addon.Sync.telemetry.rosterSyncRelevantUpdates or 0, relevantAfterFirst, "repeated ready updates should not keep counting as sync relevant")
    Test.truthy((addon.Sync.telemetry.rosterSyncNoopUpdates or 0) >= 1, "repeated ready updates should be counted as sync noops")
end)

Test.it("trusted roster cleanup is throttled daily and evaluates only known addon owners", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteKey = "Cleanuppeer-TestRealm"
    local lifecycle = addon.GuildLifecycleMaintenance
    local captured = nil
    local originalStartCleanup = lifecycle.StartCleanup

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = remoteKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Priest", classFileName = "PRIEST" },
        { name = "Ignoredpeer-TestRealm", online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Warrior", classFileName = "WARRIOR" },
    }, "cleanup-throttle-prime")
    seedProfession(data, ownerKey, "Alchemy", { 6001 }, {
        reason = "cleanup-local",
    })
    seedProfession(data, remoteKey, "Tailoring", { 7001 }, {
        reason = "cleanup-remote",
        sourceType = "replica",
        professionSourceType = "replica",
    })
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = 0

    lifecycle.StartCleanup = function(self, opts)
        captured = opts
        return true
    end

    local ok, cleanupReason = data:MaybeRunTrustedRosterCleanup("trusted-roster-cleanup", {
        rosterState = { trusted = true },
        memberKeys = data:GetKnownSyncOwnerKeys(),
    })
    Test.truthy(ok, "cleanup should start when due and trusted")
    Test.eq(cleanupReason, "started", "cleanup start reason")
    Test.truthy(type(captured) == "table", "cleanup should receive options")
    Test.eq(#(captured.memberKeys or {}), 2, "cleanup should evaluate only known addon owners")

    local secondOk, secondReason = data:MaybeRunTrustedRosterCleanup("trusted-roster-cleanup", {
        rosterState = { trusted = true },
        memberKeys = data:GetKnownSyncOwnerKeys(),
    })
    Test.falsy(secondOk, "cleanup should not run again inside the throttle window")
    Test.eq(secondReason, "throttled", "cleanup throttle reason")
    Test.truthy((addon.Sync.telemetry.rosterCleanupSkippedThrottle or 0) >= 1, "cleanup throttle should be counted")

    lifecycle.StartCleanup = originalStartCleanup
end)

Test.it("repeated no-op roster events do not spam global fingerprint dirty state", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    addon:GetDebugLogDB().enabled = true

    primeSyncReady(addon, wow, data, {
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    }, "roster-spam-prime")
    seedProfession(data, ownerKey, "Alchemy", { 8001 }, {
        reason = "roster-spam-seed",
    })
    data:PrepareSyncIndexNow("roster-spam-ready")
    addon.Sync:RefreshSyncReadyState("roster-spam-ready")
    data:GetGlobalMeta().lastTrustedRosterCleanupAt = time()
    if addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    addon.Data._syncIndexPrepareTimer = nil
    addon.Sync:ResetTelemetry()
    addon:GetDebugLogDB().enabled = true

    for _ = 1, 35 do
        wow.SetGuildRoster({
            { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
            { name = "Unknownspam-TestRealm", online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Warrior", classFileName = "WARRIOR" },
        })
        addon:ProcessCoalescedGuildRosterUpdate("roster-spam")
    end

    Test.eq(addon.Sync.telemetry.globalFingerprintDirty or 0, 0, "no-op roster spam should not dirty the global fingerprint repeatedly")
    Test.eq(countDebugLogLines(addon, "global-fingerprint-dirty reason=roster-update block=none full=true dirtyBlocks=0"), 0, "no-op roster spam should not emit repeated roster dirty log lines")
end)

io.write(string.format("Sync roster invalidation: %d test(s) passed\n", Test.count))
