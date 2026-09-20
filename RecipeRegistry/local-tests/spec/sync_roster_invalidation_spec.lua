local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
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

local function rosterRow(memberKey, opts)
    opts = opts or {}
    return {
        name = memberKey,
        rankName = opts.rankName or "Member",
        rankIndex = opts.rankIndex or 5,
        level = opts.level or 70,
        classDisplayName = opts.classDisplayName or "Mage",
        zone = opts.zone or "Shattrath",
        publicNote = opts.publicNote or "",
        officerNote = opts.officerNote or "",
        online = opts.online ~= false,
        status = opts.status or "",
        classFileName = opts.classFileName or "MAGE",
        yearsOffline = opts.yearsOffline,
        monthsOffline = opts.monthsOffline,
        daysOffline = opts.daysOffline,
        hoursOffline = opts.hoursOffline,
    }
end

local function cancelSyncTimers(addon)
    if addon.Sync and addon.Sync._helloTimer then
        addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
        addon.Sync._helloTimer = nil
    end
    if addon.Data and addon.Data._syncIndexPrepareTimer then
        addon.Data:CancelTimer(addon.Data._syncIndexPrepareTimer, true)
        addon.Data._syncIndexPrepareTimer = nil
    end
end

local function runMaintenanceJobs(addon, maxSteps)
    for _ = 1, (maxSteps or 10) do
        addon.Performance:RunNextStep()
        if not addon.Performance:HasPendingJobs("maintenance") then
            break
        end
    end
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

local function primeSyncReady(addon, wow, data, rosterRows, reason)
    wow.SetGuildRoster(rosterRows)
    Loader.PrimeSyncReady(addon, {
        reason = reason or "roster-prime",
        runTimers = false,
    })
    addon.Sync.warmupUntil = 0
    addon.Sync.worldTransitionUntil = 0
    cancelSyncTimers(addon)
    addon.Sync:ResetTelemetry()
end

io.write("Sync roster invalidation\n")

Test.it("roster_snapshot_login_only_spec requests one login snapshot and completes on the first usable roster update", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    wow.SetGuildRoster({
        rosterRow(ownerKey),
    })

    addon:OnPlayerLogin()
    addon:OnPlayerEnteringWorld(nil, true, false)

    Test.truthy(data:IsRosterSnapshotPending(), "login should leave the roster snapshot pending until the update arrives")
    Test.eq(wow.GetState().guildRosterRequested, 1, "login should request the guild roster once")

    addon.Sync.worldTransitionUntil = 0
    addon:OnGuildRosterUpdate()

    local rosterState = data:GetRosterPreflightState()
    Test.falsy(rosterState.pending, "first usable roster update should clear the pending snapshot")
    Test.truthy(rosterState.trusted, "first usable roster update should mark the preflight trusted")
    Test.truthy(addon.Sync.rosterPreflightReady, "sync runtime should observe the roster preflight readiness")
end)

Test.it("roster_update_after_snapshot_ignored_spec ignores follow-up roster updates for sync once preflight is complete", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    primeSyncReady(addon, wow, data, {
        rosterRow(ownerKey),
    }, "ignored-prime")

    local dirtyCalls = 0
    local prepareCalls = 0
    local resetCalls = 0
    local helloCalls = 0
    local originalMarkDirty = data.MarkSyncIndexDirty
    local originalPrepare = data.ScheduleSyncIndexPrepare
    local originalReset = addon.Sync.ResetDiscoveryRetry
    local originalHello = addon.Sync.ScheduleHello

    data.MarkSyncIndexDirty = function(self, ...)
        dirtyCalls = dirtyCalls + 1
        return originalMarkDirty(self, ...)
    end
    data.ScheduleSyncIndexPrepare = function(self, ...)
        prepareCalls = prepareCalls + 1
        return originalPrepare(self, ...)
    end
    addon.Sync.ResetDiscoveryRetry = function(self, ...)
        resetCalls = resetCalls + 1
        return originalReset(self, ...)
    end
    addon.Sync.ScheduleHello = function(self, ...)
        helloCalls = helloCalls + 1
        return originalHello(self, ...)
    end

    wow.SetGuildRoster({
        rosterRow(ownerKey, { online = false }),
    })
    addon:ProcessCoalescedGuildRosterUpdate("after-snapshot")

    Test.eq(dirtyCalls, 0, "follow-up roster updates should not dirty the sync index")
    Test.eq(prepareCalls, 0, "follow-up roster updates should not schedule index preparation")
    Test.eq(resetCalls, 0, "follow-up roster updates should not reset discovery retry")
    Test.eq(helloCalls, 0, "follow-up roster updates should not schedule hello")
    Test.truthy((addon.Sync.telemetry.rosterUpdateIgnoredForSync or 0) >= 1, "follow-up roster updates should be classified as ignored for sync")
    Test.truthy((addon.Sync.telemetry.rosterSyncNoopUpdates or 0) >= 1, "follow-up roster updates should count as sync noops")
end)

Test.it("roster_update_no_index_dirty_spec keeps the fingerprint stable when the snapshot changes no known-owner eligibility", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    primeSyncReady(addon, wow, data, {
        rosterRow(ownerKey),
    }, "no-dirty-prime")

    data:ClearSyncIndexDirty("no-dirty-baseline")
    data:PrepareSyncIndexNow("no-dirty-baseline")
    cancelSyncTimers(addon)
    addon.Sync:ResetTelemetry()

    data:RequestRosterSnapshot("login", {
        force = true,
        source = "test",
    })
    wow.SetGuildRoster({
        rosterRow(ownerKey),
    })
    addon:OnGuildRosterUpdate()

    local state = data:GetSyncIndexDebugState()
    Test.falsy(state.globalFingerprintDirty, "snapshot without eligibility changes should not dirty the global fingerprint")
    Test.eq(addon.Data._syncIndexPrepareTimer, nil, "snapshot without eligibility changes should not schedule a rebuild")
end)

Test.it("cleanup_snapshot_supplied_spec uses the provided snapshot without requesting a fresh guild roster", function()
    local addon, wow, data = freshAddon()
    local ownerKeys = {}

    for index = 1, 8 do
        local ownerKey = string.format("Cleanup%02d-TestRealm", index)
        ownerKeys[#ownerKeys + 1] = ownerKey
        seedProfession(data, ownerKey, "Alchemy", { 10000 + index }, {
            reason = "cleanup-snapshot-seed-" .. tostring(index),
            sourceType = "replica",
            professionSourceType = "replica",
        })
    end

    wow.SetGuildRoster({
        rosterRow("Cleanup01-TestRealm"),
        rosterRow("Cleanup02-TestRealm"),
        rosterRow("Cleanup03-TestRealm"),
        rosterRow("Cleanup04-TestRealm"),
        rosterRow("Cleanup05-TestRealm"),
        rosterRow("Cleanup06-TestRealm"),
        rosterRow("Cleanup07-TestRealm"),
        rosterRow("Cleanup08-TestRealm"),
    })

    local snapshot = {
        ["Cleanup01-TestRealm"] = true,
        ["Cleanup02-TestRealm"] = true,
    }
    local beforeRequests = wow.GetState().guildRosterRequested
    local started, reason = addon.GuildLifecycleMaintenance:StartCleanup({
        force = true,
        label = "cleanup-snapshot-supplied",
        snapshot = snapshot,
        memberKeys = ownerKeys,
        updateLastRunAt = false,
    })
    local info = addon.GuildLifecycleMaintenance:GetLastRunInfo()

    Test.falsy(started, "cleanup should reject an implausibly small supplied snapshot")
    Test.eq(reason, "roster-too-small", "supplied snapshot reason")
    Test.eq(wow.GetState().guildRosterRequested, beforeRequests, "supplied snapshots should not request the guild roster again")
    Test.truthy(info and info.snapshotCount == 2, "cleanup should use the supplied snapshot counts")
end)

Test.it("cleanup_snapshot_fallback_spec may request a guild roster when no snapshot is supplied", function()
    local addon, wow, data = freshAddon()
    local ownerKey = "Cleanupfallback-TestRealm"

    seedProfession(data, ownerKey, "Alchemy", { 11001 }, {
        reason = "cleanup-fallback-seed",
        sourceType = "replica",
        professionSourceType = "replica",
    })
    wow.SetGuildRoster({
        rosterRow(ownerKey),
    })

    local beforeRequests = wow.GetState().guildRosterRequested
    local started, reason = addon.GuildLifecycleMaintenance:StartCleanup({
        force = true,
        label = "cleanup-snapshot-fallback",
        memberKeys = { ownerKey },
        updateLastRunAt = false,
    })

    Test.truthy(started, "cleanup should start on the fallback path")
    Test.eq(reason, nil, "fallback cleanup reason")
    Test.eq(wow.GetState().guildRosterRequested, beforeRequests + 1, "fallback cleanup may request the guild roster")

    runMaintenanceJobs(addon, 10)

    Test.falsy(addon.GuildLifecycleMaintenance:IsCleanupRunning(), "fallback cleanup should complete")
    Test.eq(addon.Sync and addon.Sync._helloTimer or nil, nil, "cleanup without mutations should not start a new sync cycle")
end)

Test.it("roster_telemetry_classification_spec counts presence, heavy, and noop roster updates separately", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    primeSyncReady(addon, wow, data, {
        rosterRow(ownerKey),
    }, "telemetry-prime")

    addon.Sync:ResetTelemetry()

    wow.SetGuildRoster({
        rosterRow(ownerKey, { online = false }),
    })
    addon:ProcessCoalescedGuildRosterUpdate("telemetry-presence")
    Test.eq(addon.Sync.telemetry.rosterPresenceOnlyUpdates or 0, 1, "presence-only updates should increment only the presence counter")
    Test.eq(addon.Sync.telemetry.rosterHeavyUpdates or 0, 0, "presence-only updates should not increment the heavy counter")

    wow.SetGuildRoster({
        rosterRow(ownerKey, { online = false }),
        rosterRow("Heavypeer-TestRealm", {
            classDisplayName = "Priest",
            classFileName = "PRIEST",
        }),
    })
    addon:ProcessCoalescedGuildRosterUpdate("telemetry-heavy")
    Test.eq(addon.Sync.telemetry.rosterPresenceOnlyUpdates or 0, 1, "heavy updates should not backfill the presence counter")
    Test.eq(addon.Sync.telemetry.rosterHeavyUpdates or 0, 1, "heavy updates should increment the heavy counter exactly once")

    wow.SetGuildRoster({
        rosterRow(ownerKey, { online = false }),
        rosterRow("Heavypeer-TestRealm", {
            classDisplayName = "Priest",
            classFileName = "PRIEST",
        }),
    })
    addon:ProcessCoalescedGuildRosterUpdate("telemetry-noop")
    Test.eq(addon.Sync.telemetry.rosterPresenceOnlyUpdates or 0, 1, "noop updates should not increment the presence counter")
    Test.eq(addon.Sync.telemetry.rosterHeavyUpdates or 0, 1, "noop updates should not increment the heavy counter")
end)

Test.it("known_owners_only_spec evaluates only known Recipe Registry owners even against a large roster", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteA = "OwnerA-TestRealm"
    local remoteB = "OwnerB-TestRealm"
    local rosterRows = {
        rosterRow(ownerKey),
        rosterRow(remoteA, { classDisplayName = "Priest", classFileName = "PRIEST" }),
        rosterRow(remoteB, { classDisplayName = "Warlock", classFileName = "WARLOCK" }),
    }

    addon:GetDebugLogDB().enabled = true
    seedProfession(data, ownerKey, "Alchemy", { 1001 }, { reason = "known-owner-local" })
    seedProfession(data, remoteA, "Tailoring", { 2001 }, { reason = "known-owner-remote-a", sourceType = "replica", professionSourceType = "replica" })
    seedProfession(data, remoteB, "Enchanting", { 3001 }, { reason = "known-owner-remote-b", sourceType = "replica", professionSourceType = "replica" })
    data:ClearSyncIndexDirty("known-owner-only-baseline")
    data:PrepareSyncIndexNow("known-owner-only-baseline")

    for index = 1, 797 do
        rosterRows[#rosterRows + 1] = rosterRow(string.format("Unknown%03d-TestRealm", index), {
            classDisplayName = "Warrior",
            classFileName = "WARRIOR",
        })
    end

    data:RequestRosterSnapshot("login", {
        force = true,
        source = "test",
    })
    wow.SetGuildRoster(rosterRows)
    addon:OnGuildRosterUpdate()

    Test.eq(countDebugLogLines(addon, "roster-known-owner-check owner="), 3, "only the three known owners should be evaluated")
    Test.eq(addon.Sync.telemetry.rosterUnknownMembersIgnored or 0, 797, "unknown guild members should be ignored for sync purposes")
    Test.eq(countDebugLogLines(addon, "global-fingerprint-dirty reason=roster-update"), 0, "unknown members should not dirty the fingerprint")
end)

Test.it("known_owner_missing_from_guild_spec marks missing known owners stale and dirties only the affected blocks", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteKey = "Missingpeer-TestRealm"

    seedProfession(data, ownerKey, "Alchemy", { 4001 }, { reason = "missing-owner-local" })
    seedProfession(data, remoteKey, "Tailoring", { 5001, 5002 }, {
        reason = "missing-owner-remote",
        sourceType = "replica",
        professionSourceType = "replica",
    })
    cancelSyncTimers(addon)
    addon.Sync:ResetTelemetry()

    data:RequestRosterSnapshot("login", {
        force = true,
        source = "test",
    })
    wow.SetGuildRoster({
        rosterRow(ownerKey),
    })
    addon:OnGuildRosterUpdate()

    local remoteBlockKey = data:BuildSyncBlockKey(remoteKey, "Tailoring")
    local cache = data._syncIndexCache or {}
    Test.eq(data:GetMember(remoteKey).guildStatus, "stale", "missing known owner should become stale")
    Test.truthy(cache.dirtyBlocks and cache.dirtyBlocks[remoteBlockKey] == true, "missing known owner should dirty the affected block")
    Test.truthy(addon.Data._syncIndexPrepareTimer ~= nil, "missing known owner should schedule one prepare")
end)

Test.it("known_owner_offline_14d_spec marks known owners stale when last-online exceeds fourteen days", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local remoteKey = "Offlinepeer-TestRealm"

    wow.SetGuildRosterLastOnlineAvailable(true)
    seedProfession(data, ownerKey, "Alchemy", { 6001 }, { reason = "offline-local" })
    seedProfession(data, remoteKey, "Tailoring", { 7001 }, {
        reason = "offline-remote",
        sourceType = "replica",
        professionSourceType = "replica",
    })

    data:RequestRosterSnapshot("login", {
        force = true,
        source = "test",
    })
    wow.SetGuildRoster({
        rosterRow(ownerKey),
        rosterRow(remoteKey, {
            online = false,
            classDisplayName = "Priest",
            classFileName = "PRIEST",
            daysOffline = 15,
            hoursOffline = 0,
        }),
    })
    addon:OnGuildRosterUpdate()

    Test.eq(data:GetMember(remoteKey).guildStatus, "stale", "offline known owner should become stale after fourteen days")
    Test.truthy(addon.Data._syncIndexPrepareTimer ~= nil, "offline known owner should schedule index preparation")
end)

Test.it("last_online_unavailable_fallback_spec falls back to membership-only validation when last-online data is unavailable", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()
    local presentKey = "Presentpeer-TestRealm"
    local missingKey = "Missingpeer-TestRealm"

    addon:GetDebugLogDB().enabled = true
    wow.SetGuildRosterLastOnlineAvailable(false)
    seedProfession(data, ownerKey, "Alchemy", { 8001 }, { reason = "fallback-local" })
    seedProfession(data, presentKey, "Tailoring", { 9001 }, {
        reason = "fallback-present",
        sourceType = "replica",
        professionSourceType = "replica",
    })
    seedProfession(data, missingKey, "Enchanting", { 9101 }, {
        reason = "fallback-missing",
        sourceType = "replica",
        professionSourceType = "replica",
    })

    data:RequestRosterSnapshot("login", {
        force = true,
        source = "test",
    })
    wow.SetGuildRoster({
        rosterRow(ownerKey),
        rosterRow(presentKey, {
            online = false,
            classDisplayName = "Priest",
            classFileName = "PRIEST",
        }),
    })
    addon:OnGuildRosterUpdate()

    Test.eq(data:GetMember(presentKey).guildStatus, "active", "present owner should stay eligible under membership-only fallback")
    Test.eq(data:GetMember(missingKey).guildStatus, "stale", "missing owner should still become stale under membership-only fallback")
    Test.truthy(countDebugLogLines(addon, "roster-last-online-unavailable fallback=membership-only") >= 1, "fallback should be logged once")
end)

Test.it("no_roster_update_dirty_reason_spec never emits roster-update as a global fingerprint dirty reason", function()
    local addon, wow, data = freshAddon()
    local ownerKey = data:GetPlayerKey()

    addon:GetDebugLogDB().enabled = true
    primeSyncReady(addon, wow, data, {
        rosterRow(ownerKey),
    }, "dirty-reason-prime")
    addon:ClearDebugLog()

    for _ = 1, 25 do
        wow.SetGuildRoster({
            rosterRow(ownerKey),
            rosterRow("Unknownspam-TestRealm", {
                classDisplayName = "Warrior",
                classFileName = "WARRIOR",
            }),
        })
        addon:ProcessCoalescedGuildRosterUpdate("roster-spam")
    end

    Test.eq(countDebugLogLines(addon, "global-fingerprint-dirty reason=roster-update"), 0, "roster events should never dirty the fingerprint with the old reason")
end)

io.write(string.format("Sync roster invalidation: %d test(s) passed\n", Test.count))
