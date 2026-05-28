local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function disableUncataloguedGate(addon)
    -- This spec seeds synthetic recipe keys not present in the metadata
    -- dataset; keep the last-gate uncatalogued cleanup off so the seeded
    -- rows survive the filter predicate.
    if addon and addon.db and addon.db.profile and addon.db.profile.recipePrefilters then
        addon.db.profile.recipePrefilters.hideUncataloguedRecipes = false
    end
end

local function freshAddon()
    local addon, wow = Loader.Load()
    disableUncataloguedGate(addon)
    return addon, wow, addon.Data
end

local function freshAddonWithUi()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "UI/MainFrame.lua"
    local addon, wow = Loader.Load({
        files = files,
    })
    disableUncataloguedGate(addon)
    return addon, wow, addon.Data, addon.UI
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

Test.it("filters and sorts addon status rows from table headers", function()
    local addon, _wow, data, ui = freshAddonWithUi()
    local selfKey = data:GetPlayerKey()
    local now = time()
    addon.ADDON_VERSION = "2.0.4"
    addon.DISPLAY_VERSION = "2.0.4"

    Loader.Wow.SetGuildRoster({
        rosterRow(selfKey, { online = true }),
        rosterRow("Addononline-TestRealm", { online = true }),
        rosterRow("Onlinenone-TestRealm", { online = true }),
        rosterRow("Seenpeer-TestRealm", { online = false }),
        rosterRow("Stalepeer-TestRealm", { online = false }),
        rosterRow("Neverpeer-TestRealm", { online = false }),
    })
    data:RebuildOnlineCache()
    data:RecordAddonPeer("Addononline-TestRealm", { addonVersion = "2.0.5" }, now)
    data:RecordAddonPeer("Seenpeer-TestRealm", { addonVersion = "2.0.4" }, now - (5 * 86400))
    data:RecordAddonPeer("Stalepeer-TestRealm", { addonVersion = "2.0.3" }, now - (31 * 86400))

    local rows = data:GetGuildAddonStatusRows({
        staleAfterDays = 30,
    })

    ui.addonStatusFilters = { status = "never_seen", roster = "all", version = "all" }
    ui.addonStatusSortKey = "name"
    ui.addonStatusSortDir = "asc"
    local neverSeen = ui:BuildAddonStatusDisplayRows(rows)
    Test.eq(neverSeen[1].rowType, "addonStatusTableHeader", "status table should start with a table header")
    Test.eq(#neverSeen, 2, "status filter should keep only matching members")
    Test.eq(neverSeen[2].memberKey, "Neverpeer-TestRealm", "never-seen filter result")

    ui.addonStatusFilters = { status = "all", roster = "online", version = "all" }
    local onlineRows = ui:BuildAddonStatusDisplayRows(rows)
    Test.eq(#onlineRows, 4, "presence filter should keep the header plus online members")

    ui.addonStatusFilters = { status = "all", roster = "all", version = "old" }
    local oldRows = ui:BuildAddonStatusDisplayRows(rows)
    Test.eq(#oldRows, 2, "version filter should keep the header plus old addon versions")
    Test.eq(oldRows[2].memberKey, "Stalepeer-TestRealm", "old-version filter result")

    ui.addonStatusFilters = { status = "all", roster = "all", version = "all" }
    ui.addonStatusSortKey = "lastSeen"
    ui.addonStatusSortDir = "desc"
    local byLastSeen = ui:BuildAddonStatusDisplayRows(rows)
    Test.truthy((byLastSeen[2].lastSeenAt or 0) >= (byLastSeen[3].lastSeenAt or 0), "last-seen sort should order descending")
end)

Test.it("routes addon status headers through the status row renderer", function()
    local _addon, _wow, _data, ui = freshAddonWithUi()
    local rendered = {}

    ui.BindAddonStatusRow = function(_self, _row, _rowIdx, rowData)
        rendered[#rendered + 1] = rowData.rowType
    end

    ui:BindRecipeRow({}, 1, { rowType = "addonStatusTableHeader" })
    ui:BindRecipeRow({}, 2, { rowType = "addonStatus", memberKey = "Peer-TestRealm" })

    Test.eq(rendered[1], "addonStatusTableHeader", "table header should not render as a recipe row")
    Test.eq(rendered[2], "addonStatus", "member row should still use the status renderer")
end)

Test.it("builds favorites without launching a global recipe-list job", function()
    local addon, _wow, data, ui = freshAddonWithUi()

    addon.charDB.favorites = {
        ["favorite-recipe"] = true,
    }
    ui.selectedProfession = "Favorites"
    ui.recipeSearchText = ""
    ui.addonStatusSearchText = "status-only-search"
    ui.searchText = ui.addonStatusSearchText
    ui.frame = {
        recipeHeader = { SetText = function(self, text) self.text = text end },
        sortSwitch = {
            Show = function(self) self.visible = true end,
            Hide = function(self) self.visible = false end,
            Enable = function(self) self.enabled = true end,
            SetLabel = function(self, text) self.label = text end,
        },
        recipeContent = { SetHeight = function(self, height) self.height = height end },
        recipeRows = {},
    }
    ui.RenderVisibleRecipeRows = function() end
    ui.RefreshSummaryCards = function() end
    ui.RefreshDetailPanel = function() end

    data._recipeIndex = nil
    data.BuildRecipeListAsync = function()
        error("favorites should not build the global recipe list")
    end
    data.GetMembersDB = function()
        return {
            ["Crafter-TestRealm"] = {
                updatedAt = time(),
                professions = {
                    Alchemy = {
                        skillRank = 375,
                        recipes = {
                            ["favorite-recipe"] = true,
                            ["other-recipe"] = true,
                        },
                    },
                },
            },
        }
    end
    data.IsUserVisibleMember = function()
        return true
    end
    data.IsMemberOnline = function(_self, memberKey)
        return memberKey == "Crafter-TestRealm"
    end
    data.GetRecipeDisplayInfo = function(_self, recipeKey)
        return {
            recipeKey = recipeKey,
            label = recipeKey == "favorite-recipe" and "Favorite recipe" or "Other recipe",
            recipeSearchText = recipeKey == "favorite-recipe" and "favorite recipe" or "other recipe",
            searchText = recipeKey == "favorite-recipe" and "favorite recipe" or "other recipe",
        }
    end

    ui:RefreshRecipeList()

    Test.eq(#ui.currentRecipeRows, 1, "favorites should keep matching favorite rows")
    Test.eq(ui.currentRecipeRows[1].recipeKey, "favorite-recipe", "favorite row should remain visible")
    Test.eq(ui.currentRecipeRows[1].crafterCount, 1, "favorite row should keep crafter counts")
end)

io.write(string.format("Addon adoption status: %d test(s) passed\n", Test.count))
