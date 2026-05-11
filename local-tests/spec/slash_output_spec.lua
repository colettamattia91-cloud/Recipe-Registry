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

local function printLogDoesNotContain(wow, needle)
    return not printLogContains(wow, needle)
end

local function countGuildCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if row.distribution == "GUILD" and type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
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

io.write("Slash command output\n")

Test.it("prints the complete main command surface", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("help")

    Test.truthy(printLogContains(wow, "Commands:"), "main help header")
    Test.truthy(printLogContains(wow, "/rr rescan - queue a profession scan"), "rescan help")
    Test.truthy(printLogContains(wow, "/rr dump, /rr self [profession], /rr sync, /rr offline, /rr manifest [target or verbose], /rr pull"), "diagnostic help")
    Test.truthy(printLogContains(wow, "offlinewipe"), "offlinewipe scenario in help")
    Test.truthy(printLogContains(wow, "/rr options, /rr mini, /rr debug, /rr version, /rr ver"), "debug/version command in help")
    Test.truthy(printLogContains(wow, "/rr clean [check], /rr wipe"), "maintenance commands in help")
    Test.truthy(printLogDoesNotContain(wow, "syncreset"), "syncreset should stay hidden from public help")
    Test.truthy(printLogDoesNotContain(wow, "|"), "main help should avoid WoW chat control pipe characters")
end)

Test.it("runs manual version checks from slash commands", function()
    local addon, wow = freshAddon()
    local peerKey = "Versionpeer-TestRealm"

    addon.Sync:TouchNode(peerKey, "1.8.1")
    addon:SlashHandler("version")

    Test.eq(countCommKind(wow, "VREQ"), 1, "manual version should send one VREQ")
    Test.truthy(printLogContains(wow, "Requested version check from 1 peer(s)."), "version command should print request count")
    Test.truthy(printLogContains(wow, "Version local="), "version command should print version summary")

    addon:SlashHandler("ver")
    Test.eq(countCommKind(wow, "VREQ"), 1, "short alias should not duplicate an in-flight VREQ")
end)

Test.it("prints corrupt data cleanup check output", function()
    local addon, wow = freshAddon()

    addon.Data.db.global.members["Bad:Owner-TestRealm"] = {
        owner = "Bad:Owner-TestRealm",
        professions = {},
    }

    addon:SlashHandler("clean check")

    Test.truthy(printLogContains(wow, "Cleanup check:"), "cleanup check output")
    Test.truthy(printLogContains(wow, "members=1"), "cleanup check member count")
    Test.truthy(printLogContains(wow, "Run /rr clean to apply"), "cleanup dry-run guidance")
    Test.truthy(addon.Data.db.global.members["Bad:Owner-TestRealm"], "cleanup check should not mutate data")
end)

Test.it("prints the same main help for unknown commands", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("does-not-exist")

    Test.truthy(printLogContains(wow, "Commands:"), "fallback help header")
    Test.truthy(printLogContains(wow, "/rr self [profession]"), "fallback self help")
    Test.truthy(printLogContains(wow, "offlinewipe"), "fallback mock scenario help")
end)

Test.it("hides perf dump diagnostics unless debug is enabled", function()
    local addon, wow, data = freshAddon()

    data:MarkScanNeeded(nil, "test")
    addon.bucketTelemetry = {
        rosterEventsAbsorbed = 4,
        rosterBuckets = 2,
        rosterDeferred = 1,
        itemEventsAbsorbed = 3,
        itemBuckets = 1,
        lastRosterBucketAt = 111,
        lastItemBucketAt = 222,
    }

    addon:SlashHandler("perf help")
    Test.truthy(printLogContains(wow, "diagnostica scan"), "perf help should mention scan diagnostics")
    Test.truthy(printLogContains(wow, "contatori scan"), "perf help should mention scan counters")

    addon:SlashHandler("perf nope")
    Test.truthy(printLogContains(wow, "Usage: /rr perf [toggle, dump, reset, help]"), "perf usage output")

    addon:SlashHandler("perf dump")
    Test.truthy(printLogDoesNotContain(wow, "Perf steps="), "perf dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Role="), "sync dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Scan signals=1"), "scan dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Manifest cache ready="), "manifest cache dump should be hidden without debug")

    addon.debugMode = true
    addon:SlashHandler("perf dump")
    Test.truthy(printLogContains(wow, "Perf steps="), "perf dump status")
    Test.truthy(printLogContains(wow, "Buckets rosterEvents=4"), "bucket perf dump status")
    Test.truthy(printLogContains(wow, "Role="), "sync dump status")
    Test.truthy(printLogContains(wow, "Scan signals=1"), "scan dump status")
    Test.truthy(printLogContains(wow, "Manifest cache ready="), "manifest cache dump status")
    Test.truthy(printLogContains(wow, "fallback="), "manifest cache fallback telemetry")

    addon:SlashHandler("perf reset")
    Test.truthy(printLogContains(wow, "Performance, sync, scan, and manifest counters reset."), "perf reset output")
    Test.eq(data:GetScanTelemetry().signals, 0, "perf reset should clear scan counters")
    Test.eq(addon.bucketTelemetry.rosterEventsAbsorbed, 0, "perf reset should clear bucket telemetry")
    Test.eq(addon.bucketTelemetry.itemEventsAbsorbed, 0, "perf reset should clear item bucket telemetry")
end)

Test.it("queues manual rescan when no profession API data is active", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 50, skillMaxRank = 75 },
    })

    addon:SlashHandler("rescan")

    Test.truthy(data:HasAnyScanPending(), "manual rescan should remain pending")
    Test.eq(data:GetScanTelemetry().signals, 1, "manual rescan should record a scan signal")
    Test.eq(data:GetScanTelemetry().scansSkipped, 2, "inactive trade/craft APIs should be skipped")
    Test.truthy(printLogContains(wow, "Profession rescan queued. Open or refresh a profession to complete pending scans."), "queued rescan output")
end)

Test.it("uses active TradeSkill API data during manual rescan", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 60, skillMaxRank = 75 },
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Manual Rescan Potion", itemID = 91001 },
    }, { shown = false })

    addon:SlashHandler("rescan")

    local entry = data:GetMember(data:GetPlayerKey())
    Test.falsy(_G.TradeSkillFrame:IsShown(), "TradeSkillFrame should not need to be visible")
    Test.falsy(data:HasAnyScanPending(), "active API scan should complete manual rescan")
    Test.truthy(entry and entry.professions and entry.professions.Alchemy, "Alchemy should be stored")
    Test.eq(entry.professions.Alchemy.count, 1, "Alchemy recipe count")
    Test.hasKey(entry.professions.Alchemy.recipes, 91001, "Alchemy recipe key")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "manual rescan should advertise changed data")
    Test.truthy(printLogDoesNotContain(wow, "Scanned Alchemy: 1 recipe(s) found."), "scan result output should be hidden without debug")
    Test.truthy(printLogContains(wow, "Profession rescan completed for active profession data."), "completed rescan output")
end)

Test.it("prints scan details when debug is enabled", function()
    local addon, wow, data = freshAddon()

    addon.debugMode = true
    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 60, skillMaxRank = 75 },
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Debug Rescan Potion", itemID = 91002 },
    }, { shown = false })

    addon:SlashHandler("rescan")

    Test.truthy(data:GetMember(data:GetPlayerKey()).professions.Alchemy, "debug scan should store Alchemy")
    Test.truthy(printLogContains(wow, "Scanned Alchemy: 1 recipe(s) found."), "debug scan result output")
    Test.truthy(printLogContains(wow, "Profession rescan completed for active profession data."), "completed rescan output")
end)

Test.it("hides DB, sync, manifest, and offline diagnostics unless debug is enabled", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("dump")
    Test.truthy(printLogDoesNotContain(wow, "Members="), "dump summary should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Scan signals="), "dump scan should be hidden without debug")

    addon:SlashHandler("sync")
    Test.truthy(printLogDoesNotContain(wow, "Role="), "sync output should be hidden without debug")

    addon:SlashHandler("manifest")
    Test.truthy(printLogDoesNotContain(wow, "Manifest local="), "manifest summary should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Manifest replica owners: none"), "manifest replica output should be hidden without debug")

    addon:SlashHandler("offline")
    Test.truthy(printLogDoesNotContain(wow, "Offline sync manifests owners="), "offline telemetry should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Offline sync recent: none"), "offline recent should be hidden without debug")

    addon.debugMode = true
    addon:SlashHandler("dump")
    Test.truthy(printLogContains(wow, "Members="), "dump summary output")
    Test.truthy(printLogContains(wow, "Scan signals="), "dump scan output")

    addon:SlashHandler("sync")
    Test.truthy(printLogContains(wow, "Role="), "sync output")
    Test.truthy(printLogContains(wow, "Runtime partialRecv="), "sync runtime observability output")

    addon:SlashHandler("manifest")
    Test.truthy(printLogContains(wow, "Manifest local="), "manifest summary output")
    Test.truthy(printLogContains(wow, "Manifest replica owners: none"), "manifest replica output")
    Test.truthy(printLogContains(wow, "Manifest runtime residentPeers="), "manifest runtime output")

    addon:SlashHandler("offline")
    Test.truthy(printLogContains(wow, "Offline sync manifests owners="), "offline telemetry output")
    Test.truthy(printLogContains(wow, "Offline runtime partialPeers="), "offline runtime output")
    Test.truthy(printLogContains(wow, "Offline sync recent: none"), "offline recent output")
end)

Test.it("prints local owner sync diagnostics and supports profession filtering", function()
    local addon, wow, data = freshAddon()
    addon.debugMode = true
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)

    entry.rev = 4
    entry.updatedAt = 1234
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = { [93001] = true },
        count = 1,
        skillRank = 350,
        skillMaxRank = 375,
        specialization = "Potion Master",
        blockRevision = 4,
        lastUpdatedAt = 1234,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = 1234,
    })

    addon:SlashHandler("self")
    Test.truthy(printLogContains(wow, "Local sync owner=" .. localKey .. " rev=4 updated=1234 professions=1 recipes=1"), "self summary output")
    Test.truthy(printLogContains(wow, "  Alchemy count=1 skill=350/375 spec=Potion Master blockRev=4 source=owner updated=1234"), "self profession output")

    addon:SlashHandler("self Alchemy")
    Test.truthy(printLogContains(wow, "  Alchemy count=1 skill=350/375 spec=Potion Master blockRev=4 source=owner updated=1234"), "filtered self profession output")

    addon:SlashHandler("self Tailoring")
    Test.truthy(printLogContains(wow, "Local sync profession not found: Tailoring."), "missing profession filter output")
end)

Test.it("keeps manifest output compact by default and verbose on request", function()
    local addon, wow, data = freshAddon()
    addon.debugMode = true

    local replica = data:GetOrCreateMember("Replicaone-Testrealm")
    replica.rev = 3
    replica.updatedAt = 100
    replica.sourceType = "replica"
    replica.professions.Alchemy = {
        recipes = { [92001] = true },
        count = 1,
        blockRevision = 3,
        lastUpdatedAt = 100,
        sourceType = "replica",
        guildStatus = "active",
    }

    local stale = data:GetOrCreateMember("Staleone-Testrealm")
    stale.guildStatus = "stale"
    stale.sourceType = "replica"
    stale.professions.Tailoring = {
        recipes = { [92002] = true },
        count = 1,
        blockRevision = 1,
        lastUpdatedAt = 90,
        sourceType = "replica",
        guildStatus = "stale",
    }

    addon:SlashHandler("manifest")
    Test.truthy(printLogContains(wow, "Manifest replica owners: 1 (use /rr manifest verbose for details)"), "compact replica manifest output")
    Test.truthy(printLogContains(wow, "Manifest stale excluded: 1 (use /rr manifest verbose for details)"), "compact stale manifest output")
    Test.truthy(printLogDoesNotContain(wow, "  Replicaone-Testrealm blocks="), "default manifest should not print replica detail")
    Test.truthy(printLogDoesNotContain(wow, "  Staleone-Testrealm professions="), "default manifest should not print stale detail")

    addon:SlashHandler("manifest verbose")
    Test.truthy(printLogContains(wow, "  Replicaone-Testrealm blocks=1 recipes=1 publish=replica authority=replica professions=Alchemy"), "verbose replica detail")
    Test.truthy(printLogContains(wow, "  Staleone-Testrealm professions=1"), "verbose stale detail")
end)

Test.it("prints target manifest request output", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("manifest Peerone")

    Test.truthy(printLogContains(wow, "Requested fresh manifest from Peerone."), "manifest target output")
end)

Test.it("prints mock help and usage with every scenario", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("mock help")
    Test.truthy(printLogContains(wow, "/rr mock start offlinewipe"), "offlinewipe help")
    Test.truthy(printLogContains(wow, "/rr mock start rosterheavy"), "rosterheavy help")
    Test.truthy(printLogContains(wow, "/rr mock start integrity"), "integrity help")
    Test.truthy(printLogDoesNotContain(wow, string.char(195, 131)), "mock help should not contain mojibake")

    addon:SlashHandler("mock nope")
    Test.truthy(printLogContains(wow, "Usage: /rr mock [status, start <light, medium, heavy, burst, bootstrap, traffic, offline, offlinewipe, trafficburst, roster, rosterheavy, rosterbad, integrity>, stop, cleanup, reset, help]"), "mock usage output")
    Test.truthy(printLogDoesNotContain(wow, "|"), "mock help and usage should avoid WoW chat control pipe characters")
end)

io.write(string.format("Slash command output: %d test(s) passed\n", Test.count))
