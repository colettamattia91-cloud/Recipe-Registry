local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
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
        publicNote = "",
        officerNote = "",
        online = opts.online == true,
        status = opts.status or "",
        classFileName = opts.classFileName or "MAGE",
    }
end

local function rowByKey(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        out[row.memberKey] = row
    end
    return out
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

io.write("Addon adoption status\n")

Test.it("migrates addon peer storage without creating crafter members", function()
    local addon, wow, data = freshAddon()
    local peerKey = "Addonpeer-TestRealm"

    Test.eq(data:GetSchemaVersion(), 3, "saved variable schema should migrate to 3")
    Test.eq(type(data:GetAddonPeersDB()), "table", "addon peer storage should exist")
    Test.eq(data:GetMember(peerKey), nil, "addon peer memory should not create member records")

    addon.Sync:ObservePeerVersion(peerKey, {
        kind = "HELLO",
        sender = peerKey,
        addonVersion = "2.0.5",
        wireVersion = 4,
        buildChannel = "release",
        buildId = "test-build",
    })

    local firstSeenAt = data:GetAddonPeer(peerKey).firstSeenAt
    Test.eq(data:GetAddonPeer(peerKey).addonVersion, "2.0.5", "HELLO should persist addon version")
    Test.eq(data:GetMember(peerKey), nil, "observed addon peers should stay separate from members")

    wow.AdvanceTime(20)
    addon.Sync:TouchNode(peerKey, nil)
    Test.eq(data:GetAddonPeer(peerKey).firstSeenAt, firstSeenAt, "traffic touch should preserve first seen")
    Test.eq(data:GetAddonPeer(peerKey).lastSeenAt, firstSeenAt + 20, "traffic touch should refresh last seen")

    addon.Sync:TouchNode("Unknownpeer-TestRealm", nil)
    Test.eq(data:GetAddonPeer("Unknownpeer-TestRealm"), nil, "traffic touch should not create unknown peers")
end)

Test.it("builds guild addon status rows across all documented states", function()
    local addon, _wow, data = freshAddon()
    local selfKey = data:GetPlayerKey()
    local now = time()
    local staleSeconds = 31 * 86400

    Loader.Wow.SetGuildRoster({
        rosterRow(selfKey, { online = true, rankName = "Guild Master" }),
        rosterRow("Addononline-TestRealm", { online = true, rankName = "Raider" }),
        rosterRow("Onlinenone-TestRealm", { online = true, rankName = "Trial" }),
        rosterRow("Seenpeer-TestRealm", { online = false, rankName = "Officer" }),
        rosterRow("Stalepeer-TestRealm", { online = false, rankName = "Veteran" }),
        rosterRow("Neverpeer-TestRealm", { online = false, rankName = "Social" }),
    })
    data:RebuildOnlineCache()

    data:RecordAddonPeer("Addononline-TestRealm", {
        kind = "HELLO",
        addonVersion = "2.0.5",
        wireVersion = 4,
        buildChannel = "release",
        buildId = "active",
    }, now)
    data:RecordAddonPeer("Seenpeer-TestRealm", {
        kind = "HELLO",
        addonVersion = "2.0.4",
        wireVersion = 4,
        buildChannel = "release",
        buildId = "recent",
    }, now - (5 * 86400))
    data:RecordAddonPeer("Stalepeer-TestRealm", {
        kind = "HELLO",
        addonVersion = "2.0.3",
        wireVersion = 4,
        buildChannel = "release",
        buildId = "stale",
    }, now - staleSeconds)

    local rows, summary = data:GetGuildAddonStatusRows({
        staleAfterDays = 30,
    })
    local byKey = rowByKey(rows)

    Test.truthy(summary.rosterReady, "roster should be ready")
    Test.eq(summary.rosterTotal, 6, "all roster rows should be counted")
    Test.eq(summary.shownRows, 6, "all roster rows should be shown without search")
    Test.eq(summary.addonPeersActive, 2, "local player plus online peer should count as active addon peers")
    Test.eq(byKey[selfKey].addonStatusKey, "online_with_addon", "local player should always appear with addon")
    Test.eq(byKey["Addononline-TestRealm"].addonStatusKey, "online_with_addon", "online peer with HELLO")
    Test.eq(byKey["Onlinenone-TestRealm"].addonStatusKey, "online_addon_not_seen", "online member without observed addon")
    Test.eq(byKey["Seenpeer-TestRealm"].addonStatusKey, "seen_before", "offline recent peer")
    Test.eq(byKey["Stalepeer-TestRealm"].addonStatusKey, "not_seen_recently", "stale peer threshold")
    Test.eq(byKey["Neverpeer-TestRealm"].addonStatusKey, "never_seen", "member never observed")

    local statusRows = data:GetGuildAddonStatusRows({
        searchText = "not seen recently",
        staleAfterDays = 30,
    })
    Test.eq(#statusRows, 1, "status search should match status labels")
    Test.eq(statusRows[1].memberKey, "Stalepeer-TestRealm", "status search result")

    local rankRows = data:GetGuildAddonStatusRows({
        searchText = "officer",
        staleAfterDays = 30,
    })
    Test.eq(#rankRows, 1, "rank search should match roster rank")
    Test.eq(rankRows[1].memberKey, "Seenpeer-TestRealm", "rank search result")
end)

Test.it("prints adoption diagnostics without debug mode", function()
    local addon, wow, data = freshAddon()
    local selfKey = data:GetPlayerKey()

    Loader.Wow.SetGuildRoster({
        rosterRow(selfKey, { online = true }),
        rosterRow("Addononline-TestRealm", { online = true }),
    })
    data:RebuildOnlineCache()
    data:RecordAddonPeer("Addononline-TestRealm", {
        kind = "HELLO",
        addonVersion = "2.0.5",
        wireVersion = 4,
        buildChannel = "release",
    })

    addon:SlashHandler("adoption")

    Test.truthy(printLogContains(wow, "Addon status: roster=2 shown=2 addonActive=2 staleAfter=30d"), "adoption summary output")
    Test.truthy(printLogContains(wow, "Addon status counts:"), "adoption counts output")
end)

io.write(string.format("Addon adoption status: %d test(s) passed\n", Test.count))
