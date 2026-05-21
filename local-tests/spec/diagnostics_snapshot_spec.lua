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
    entry.guildStatus = "active"
    entry.sourceType = opts.sourceType or "owner"
    entry.updatedAt = opts.updatedAt or 100
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
    data:MarkSyncIndexDirty(opts.reason or "diagnostics-seed")
end

local function primeSyncReady(addon, wow, data, reason)
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "diagnostics-prime",
        runTimers = false,
    })
end

io.write("Diagnostics snapshot\n")

Test.it("runtime observability snapshot exposes the modern debug sections only", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "diagnostics-snapshot")
    local ownerKey = data:GetPlayerKey()

    seedProfession(data, ownerKey, "Alchemy", { 91001, 91002 }, {
        reason = "diagnostics-snapshot-seed",
    })
    data:PrepareSyncIndexNow("diagnostics-snapshot-seed")
    addon.Sync:RefreshSyncReadyState("diagnostics-snapshot-seed")
    addon.Sync:ScheduleHello("diagnostics-snapshot", 30)
    addon.Sync:RecordSyncEvent("payloadCheck", {
        reason = "bounded",
        extra = "no-payloads",
        blockKey = ownerKey .. "::Alchemy",
        blockPayload = { hidden = true },
        recipeKeys = { 1, 2, 3 },
    })

    local snapshot = addon.Sync:GetRuntimeObservabilitySnapshot()
    local alpha = addon.Sync:GetAlphaDebugSnapshot()

    Test.truthy(type(snapshot.readiness) == "table", "snapshot readiness section")
    Test.truthy(type(snapshot.hello) == "table", "snapshot hello section")
    Test.truthy(type(snapshot.discoveryRetry) == "table", "snapshot discovery retry section")
    Test.truthy(type(snapshot.outboundSession) == "table", "snapshot outbound session section")
    Test.truthy(type(snapshot.inboundSeed) == "table", "snapshot inbound seed section")
    Test.truthy(type(snapshot.index) == "table", "snapshot index section")
    Test.truthy(type(snapshot.compatibility) == "table", "snapshot compatibility section")
    Test.truthy(type(alpha.recentEventLog) == "table", "alpha snapshot recent log")
    Test.truthy(type(alpha.addonVersion) == "string", "alpha snapshot addon version")
    Test.eq(alpha.index.blocks, nil, "alpha snapshot should not expose full index blocks")
    Test.eq(alpha.outboundSession.blockPayload, nil, "alpha snapshot should not expose block payloads")

    local lastEvent = alpha.recentEventLog[#alpha.recentEventLog] or {}
    Test.eq(lastEvent.blockPayload, nil, "recent sync log should not persist payloads")
    Test.eq(lastEvent.recipeKeys, nil, "recent sync log should not persist recipe arrays")
end)

io.write(string.format("Diagnostics snapshot: %d test(s) passed\n", Test.count))
