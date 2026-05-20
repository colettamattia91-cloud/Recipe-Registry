local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function freshReleaseAddon()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        if file ~= "MockSync.lua" then
            files[#files + 1] = file
        end
    end
    local addon, wow = Loader.Load({ files = files })
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

local function countLegacyGuildComm(wow)
    return countGuildCommKind(wow, "AD")
        + countGuildCommKind(wow, "IDX")
        + countGuildCommKind(wow, "MANI")
        + countGuildCommKind(wow, "MREQ")
end

local function seedLocalProfession(data, professionKey, recipeKeys, opts)
    opts = opts or {}
    local memberKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end
    entry.updatedAt = opts.updatedAt or 1234
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[professionKey] = data:NormalizeProfessionBlock(entry, professionKey, {
        recipes = recipes,
        count = #recipeKeys,
        skillRank = opts.skillRank or 350,
        skillMaxRank = opts.skillMaxRank or 375,
        specialization = opts.specialization,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = entry.updatedAt,
        lastUpdatedAt = entry.updatedAt,
    })
    data:MarkSyncIndexDirty(opts.reason or "slash-seed", data:BuildSyncBlockKey(memberKey, professionKey))
    return entry
end

io.write("Slash command output\n")

Test.it("prints the complete modern main command surface", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("help")

    Test.truthy(printLogContains(wow, "Commands:"), "main help header")
    Test.truthy(printLogContains(wow, "/rr rescan - queue a profession scan"), "rescan help")
    Test.truthy(printLogContains(wow, "/rr version, /rr versions, /rr dump, /rr self [profession], /rr sync [debug, diag, peers, sessions, log], /rr offline, /rr pull"), "diagnostic help")
    Test.truthy(printLogContains(wow, "offlinewipe"), "offlinewipe scenario in help")
    Test.truthy(printLogContains(wow, "/rr options, /rr mini, /rr debug, /rr debug log"), "debug command in help")
    Test.truthy(printLogContains(wow, "/rr clean [check], /rr wipe"), "maintenance commands in help")
    Test.truthy(printLogDoesNotContain(wow, "/rr manifest"), "manifest command should be removed from help")
    Test.truthy(printLogDoesNotContain(wow, "syncreset"), "syncreset should stay hidden from public help")
    Test.truthy(printLogDoesNotContain(wow, "|"), "main help should avoid WoW chat control pipe characters")
end)

Test.it("prints the same main help for unknown and removed manifest commands", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("does-not-exist")
    addon:SlashHandler("manifest")

    Test.truthy(printLogContains(wow, "Commands:"), "fallback help header")
    Test.truthy(printLogContains(wow, "/rr self [profession]"), "fallback self help")
    Test.truthy(printLogContains(wow, "offlinewipe"), "fallback mock scenario help")
    Test.truthy(printLogDoesNotContain(wow, "Manifest local="), "removed manifest command should not print legacy diagnostics")
end)

Test.it("hides mock commands from release help when the mock module is absent", function()
    local addon, wow = freshReleaseAddon()

    addon:SlashHandler("help")
    Test.truthy(printLogDoesNotContain(wow, "/rr mock"), "release help should not advertise unavailable mock tooling")

    addon:SlashHandler("mock help")
    Test.truthy(printLogContains(wow, "Mock sync module not available."), "hidden mock command should fail safely if invoked")
end)

Test.it("manages persistent debug log commands with the sync scope", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("debug log status")
    Test.truthy(printLogContains(wow, "Debug log disabled"), "debug log status output")

    addon:SlashHandler("debug log on")
    addon:Trace("sync", "test sync trace")
    addon:SlashHandler("debug log show 5 sync")
    Test.truthy(printLogContains(wow, "Debug log enabled."), "debug log enable output")
    Test.truthy(printLogContains(wow, "Debug log entries: 1 scope=sync"), "debug log show header")
    Test.truthy(printLogContains(wow, "scope=sync test sync trace"), "debug log entry output")

    addon:SlashHandler("debug log scope transfer off")
    addon:SlashHandler("debug log clear")
    Test.truthy(printLogContains(wow, "Debug log scope transfer disabled."), "debug log scope output")
    Test.truthy(printLogContains(wow, "Debug log cleared."), "debug log clear output")
    Test.eq(#(addon:GetDebugLogDB().entries or {}), 0, "debug log entries should reset")
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
    Test.truthy(printLogContains(wow, "scan diagnostics"), "perf help should mention scan diagnostics")
    Test.truthy(printLogContains(wow, "scan counters"), "perf help should mention scan counters")

    addon:SlashHandler("perf dump")
    Test.truthy(printLogDoesNotContain(wow, "Perf steps="), "perf dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Role="), "sync dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Scan signals=1"), "scan dump should be hidden without debug")
    Test.truthy(printLogDoesNotContain(wow, "Sync index ready="), "sync index cache dump should be hidden without debug")

    addon.debugMode = true
    addon:SlashHandler("perf dump")
    Test.truthy(printLogContains(wow, "Perf steps="), "perf dump status")
    Test.truthy(printLogContains(wow, "Buckets rosterEvents=4"), "bucket perf dump status")
    Test.truthy(printLogContains(wow, "RR Sync Ready:"), "sync dump status")
    Test.truthy(printLogContains(wow, "Scan signals=1"), "scan dump status")
    Test.truthy(printLogContains(wow, "Sync index ready="), "sync index cache dump status")

    addon:SlashHandler("perf reset")
    Test.truthy(printLogContains(wow, "Performance, sync, scan, and cache counters reset."), "perf reset output")
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
    wow.RunTimers(5)

    Test.truthy(data:HasAnyScanPending(), "manual rescan should remain pending")
    Test.eq(data:GetScanTelemetry().signals, 1, "manual rescan should record a scan signal")
    Test.eq(data:GetScanTelemetry().scansSkipped, 2, "inactive trade/craft APIs should be skipped")
    Test.eq(countLegacyGuildComm(wow), 0, "manual rescan should not emit legacy sync traffic")
    Test.truthy(addon.Sync._helloTimer ~= nil or type(addon.Sync.lastHelloScheduleReason) == "string", "manual rescan should schedule a delayed hello")
    Test.eq(countGuildCommKind(wow, "HELLO"), 0, "manual rescan should not broadcast hello inline")
    Test.truthy(printLogContains(wow, "Profession rescan queued. Open or refresh a profession to complete pending scans."), "queued rescan output")
end)

Test.it("shows sync diagnostics in the modern compact format and still hides offline diagnostics unless debug is enabled", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("sync")
    addon:SlashHandler("offline")
    Test.truthy(printLogContains(wow, "RR Sync Ready:"), "sync output should be available for alpha diagnostics")
    Test.truthy(printLogContains(wow, "HELLO sent="), "sync output should include hello scheduler state")
    Test.truthy(printLogDoesNotContain(wow, "Offline sync blocks served="), "offline telemetry should be hidden without debug")

    addon.debugMode = true
    addon:SlashHandler("sync")
    addon:SlashHandler("offline")
    Test.truthy(printLogContains(wow, "Outbound seed="), "sync output")
    Test.truthy(printLogContains(wow, "Index status="), "sync cache output")
    Test.truthy(printLogContains(wow, "Offline sync blocks served="), "offline telemetry output")
    Test.truthy(printLogContains(wow, "Offline sync recent: none"), "offline recent output")
end)

Test.it("prints local owner sync diagnostics and supports profession filtering", function()
    local addon, wow, data = freshAddon()
    addon.debugMode = true

    seedLocalProfession(data, "Alchemy", { 93001 }, {
        specialization = "Potion Master",
        reason = "self-alchemy",
    })

    addon:SlashHandler("self")
    Test.truthy(printLogContains(wow, "Local sync owner=" .. data:GetPlayerKey() .. " professions=1 recipes=1"), "self summary output")
    Test.truthy(printLogContains(wow, "  Alchemy count=1 skill=350/375 spec=Potion Master recipes=93001"), "self profession output")

    addon:SlashHandler("self Alchemy")
    Test.truthy(printLogContains(wow, "  Alchemy count=1 skill=350/375 spec=Potion Master recipes=93001"), "filtered self profession output")

    addon:SlashHandler("self Tailoring")
    Test.truthy(printLogContains(wow, "Local sync profession not found: Tailoring."), "missing profession filter output")
end)

Test.it("prints pull output on the modern sync path", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("pull")

    Test.truthy(printLogContains(wow, "Scheduled a hello cycle for index-diff sync."), "pull output")
    Test.eq(countGuildCommKind(wow, "HELLO"), 0, "pull should schedule work instead of sending inline")
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
