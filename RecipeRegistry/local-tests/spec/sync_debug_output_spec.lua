local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
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
    entry.guildStatus = "active"
    entry.sourceType = opts.sourceType or "owner"
    entry.updatedAt = opts.updatedAt or 100
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[professionKey] = {
        recipes = recipes,
        skillRank = opts.skillRank or 75,
        skillMaxRank = opts.skillMaxRank or 150,
        sourceType = opts.professionSourceType or entry.sourceType,
        guildStatus = "active",
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkSyncIndexDirty(opts.reason or "sync-debug-seed")
end

local function primeSyncReady(addon, wow, data, reason)
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "sync-debug-prime",
        runTimers = false,
    })
end

io.write("Sync debug output\n")

Test.it("slash sync output prints the compact modern status without legacy terminology", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "sync-debug-output")
    local ownerKey = data:GetPlayerKey()
    seedProfession(data, ownerKey, "Alchemy", { 92001, 92002 }, {
        reason = "sync-debug-output-seed",
    })
    data:PrepareSyncIndexNow("sync-debug-output-seed")
    addon.Sync:RefreshSyncReadyState("sync-debug-output-seed")
    addon.Sync:ScheduleHello("sync-debug-output", 15)
    addon.Sync:RecordSyncEvent("helloScheduled", {
        reason = "sync-debug-output",
    })

    addon:SlashHandler("sync")
    addon:SlashHandler("sync debug")

    Test.truthy(printLogContains(wow, "RR Sync Ready:"), "sync readiness line")
    Test.truthy(printLogContains(wow, "HELLO sent="), "hello line")
    Test.truthy(printLogContains(wow, "Outbound seed="), "outbound session line")
    Test.truthy(printLogContains(wow, "Inbound seed sessions="), "inbound line")
    Test.truthy(printLogContains(wow, "Index status="), "index line")
    Test.truthy(printLogContains(wow, "Last noSeed="), "last blocker line")
    Test.truthy(printLogContains(wow, "Version addon="), "debug version line")
    Test.truthy(printLogContains(wow, "Seed selected="), "debug seed selection line")
    Test.falsy(printLogContains(wow, "manifest"), "sync output should not reference manifest")
    Test.falsy(printLogContains(wow, "coordinator"), "sync output should not reference coordinator")
    Test.falsy(printLogContains(wow, "revision"), "sync output should not reference revision")
end)

Test.it("sync sessions and sync log expose bounded session and event details", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "sync-debug-sessions")
    local peerKey = "Debugpeer-TestRealm"
    local caps = addon.Sync:GetLocalProtocolCaps()

    addon.Sync:ObservePeerVersion(peerKey, {
        sender = peerKey,
        addonVersion = addon.ADDON_VERSION,
        wireVersion = addon.WIRE_VERSION,
        buildChannel = addon.BUILD_CHANNEL,
        caps = caps,
    })
    addon.Sync:RecordPeerCaps(peerKey, caps)
    addon.Sync:RegisterInboundSeedSession(peerKey, "REQ:debug", {
        { blockKey = peerKey .. "::Alchemy" },
    })
    addon.Sync:RecordSyncEvent("seedSelected", {
        peer = peerKey,
        requestId = "REQ:debug",
        reason = "highest-content",
    })

    addon:SlashHandler("sync sessions")
    addon:SlashHandler("sync log")

    Test.truthy(printLogContains(wow, "Inbound[1] peer=Debugpeer-TestRealm"), "session detail line")
    Test.truthy(printLogContains(wow, "Sync log entries="), "log header")
    Test.truthy(printLogContains(wow, "seedSelected"), "log event line")
end)

io.write(string.format("Sync debug output: %d test(s) passed\n", Test.count))
