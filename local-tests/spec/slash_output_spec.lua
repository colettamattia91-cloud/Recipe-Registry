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

local function freshUiAddon()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "MainFrame.lua"
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

local function countAddonComm(wow)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and type(row.message.kind) == "string" then
            total = total + 1
        end
    end
    return total
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
    Test.truthy(printLogContains(wow, "/rr version, /rr versions, /rr adoption, /rr dump, /rr self [profession], /rr sync [debug, diag, peers, sessions, log], /rr offline, /rr pull"), "diagnostic help")
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
    Test.eq(countAddonComm(wow), 0, "manual rescan should not emit inline sync traffic")
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

Test.it("shares selected recipes with chat-safe text and preserved links", function()
    local addon = freshUiAddon()
    local sent = {}

    _G.GetSpellLink = function(spellID)
        return string.format("|Henchant:%d|h[Enchant Weapon - Fiery Weapon]|h", spellID)
    end
    _G.SendChatMessage = function(message, channel, language, target)
        sent[#sent + 1] = {
            message = message,
            channel = channel,
            language = language,
            target = target,
        }
    end

    addon.UI.selectedRecipeKey = "Enchanting:13898"
    addon.Data.GetRecipeDetail = function()
        return {
            spellID = 13898,
            cost = {
                total = 106164,
                source = "Auctionator | TSM",
            },
            reagents = {
                { itemID = 10940, count = 4 },
                { name = "Strange | Dust", count = 2 },
            },
        }
    end

    addon:SlashHandler("share guild")

    Test.eq(#sent, 2, "share should send summary and mats lines")
    Test.eq(sent[1].channel, "GUILD", "share channel")
    Test.eq(sent[1].message, "[RR] |Henchant:13898|h[Enchant Weapon - Fiery Weapon]|h - Mats total: 10g 61s 64c - Source: Auctionator || TSM", "summary chat text")
    Test.truthy(sent[2].message:find("|Hitem:10940", 1, true) ~= nil, "reagent item link should be preserved")
    Test.truthy(sent[2].message:find("Strange || Dust", 1, true) ~= nil, "plain reagent names should escape pipes")
    Test.truthy(sent[1].message:find("|T", 1, true) == nil, "chat summary should not include texture escapes")
    Test.truthy(sent[1].message:find(" | ", 1, true) == nil, "chat summary should not include literal pipe separators")
end)

Test.it("shares selected recipes to guild by default", function()
    local addon = freshUiAddon()
    local sent = {}

    _G.SendChatMessage = function(message, channel, language, target)
        sent[#sent + 1] = {
            message = message,
            channel = channel,
            language = language,
            target = target,
        }
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.Data.GetRecipeDetail = function()
        return {
            label = "Elixir | of Defaults",
            cost = {
                total = 0,
                source = "Manual | Entry",
            },
        }
    end

    addon:SlashHandler("share")

    Test.eq(#sent, 1, "default share should send one summary line")
    Test.eq(sent[1].channel, "GUILD", "default share channel")
    Test.eq(sent[1].target, nil, "guild share should not include a channel target")
    Test.truthy(sent[1].message:find("Elixir || of Defaults", 1, true) ~= nil, "plain recipe label should escape pipes")
    Test.truthy(sent[1].message:find("Source: Manual || Entry", 1, true) ~= nil, "plain source should escape pipes")
end)

Test.it("reports share command errors without sending chat", function()
    local addon, wow = freshUiAddon()
    local sent = 0

    _G.SendChatMessage = function()
        sent = sent + 1
    end
    _G.GetChannelList = nil
    _G.GetChannelName = nil
    _G.ChatEdit_GetActiveWindow = nil

    addon:SlashHandler("share guild")
    addon:SlashHandler("share party")

    addon.UI.selectedRecipeKey = "Alchemy:missing"
    addon:SlashHandler("share nope")
    addon:SlashHandler("share channel:9")
    addon:SlashHandler("share reply")
    addon.Data.GetRecipeDetail = function()
        return nil
    end
    addon:SlashHandler("share guild")

    Test.eq(sent, 0, "failed share commands should not send chat")
    Test.truthy(printLogContains(wow, "No recipe selected."), "missing selected recipe output")
    Test.truthy(printLogContains(wow, "You are not in a party."), "unavailable party output")
    Test.truthy(printLogContains(wow, "Usage: /rr share [guild|party|raid|say|reply]"), "invalid share usage output")
    Test.truthy(printLogContains(wow, "No recent whisper target."), "missing reply target output")
    Test.truthy(printLogContains(wow, "No recipe details available."), "missing detail output")
end)

Test.it("shares selected recipes to the last whisper reply target", function()
    local addon = freshUiAddon()
    local sent = {}

    _G.ChatEdit_GetActiveWindow = nil
    _G.ChatEdit_GetLastTellTarget = function()
        return "Whisperfriend"
    end
    _G.SendChatMessage = function(message, channel, language, target)
        sent[#sent + 1] = {
            message = message,
            channel = channel,
            language = language,
            target = target,
        }
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.Data.GetRecipeDetail = function()
        return {
            label = "Elixir of Testing",
            cost = {
                total = 0,
                source = "N/A",
            },
        }
    end

    addon:SlashHandler("share r")

    Test.eq(#sent, 1, "share should send one summary line without reagents")
    Test.eq(sent[1].channel, "WHISPER", "reply share type")
    Test.eq(sent[1].target, "Whisperfriend", "reply share target")
    Test.truthy(sent[1].message:find("Elixir of Testing", 1, true) ~= nil, "reply summary")
end)

Test.it("prefers the active whisper edit box over the last whisper target", function()
    local addon = freshUiAddon()
    local sent = {}
    local editBox = {}

    function editBox:GetAttribute(key)
        if key == "chatType" then return "WHISPER" end
        if key == "tellTarget" then return "Intendedfriend" end
        return nil
    end

    _G.ChatEdit_GetActiveWindow = function()
        return editBox
    end
    _G.ChatEdit_GetLastTellTarget = function()
        return "Recentfriend"
    end
    _G.SendChatMessage = function(message, channel, language, target)
        sent[#sent + 1] = {
            message = message,
            channel = channel,
            language = language,
            target = target,
        }
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.Data.GetRecipeDetail = function()
        return {
            label = "Elixir of Intent",
            cost = {
                total = 0,
                source = "N/A",
            },
        }
    end

    addon:SlashHandler("share reply")

    Test.eq(#sent, 1, "reply share should send one summary line")
    Test.eq(sent[1].channel, "WHISPER", "active edit box share type")
    Test.eq(sent[1].target, "Intendedfriend", "active edit box target should win")
end)

Test.it("splits long shared reagent lists into chat-sized chunks", function()
    local addon = freshUiAddon()
    local sent = {}
    local reagents = {}

    for i = 1, 24 do
        reagents[#reagents + 1] = {
            itemID = 12000 + i,
            count = i,
        }
    end

    _G.SendChatMessage = function(message, channel, language, target)
        sent[#sent + 1] = {
            message = message,
            channel = channel,
            language = language,
            target = target,
        }
    end

    addon.UI.selectedRecipeKey = "Tailoring:bulk"
    addon.Data.GetRecipeDetail = function()
        return {
            label = "Bulk Cloth Test",
            cost = {
                total = 123,
                source = "N/A",
            },
            reagents = reagents,
        }
    end

    addon:SlashHandler("share guild")

    Test.gte(#sent, 3, "long reagent list should be split after the summary")
    Test.eq(sent[1].channel, "GUILD", "summary channel")
    for i = 2, #sent do
        Test.eq(sent[i].channel, "GUILD", "reagent chunk channel")
        Test.truthy(sent[i].message:find("^%[RR%] Mats:"), "reagent chunk prefix")
        Test.lte(#sent[i].message, 240, "reagent chunk should stay within chat chunk budget")
    end
end)

Test.it("opens a share dropdown with currently available channels", function()
    local addon = freshUiAddon()
    local added = {}
    local toggled = false

    _G.IsInGroup = function() return true end
    _G.ChatEdit_GetActiveWindow = nil
    _G.ChatEdit_GetLastTellTarget = function()
        return "Whisperfriend"
    end
    _G.EasyMenu = nil
    _G.UIDropDownMenu_CreateInfo = function()
        return {}
    end
    _G.UIDropDownMenu_AddButton = function(info)
        added[#added + 1] = info
    end
    _G.UIDropDownMenu_Initialize = function(frame, initializer, displayMode)
        frame.initialized = true
        frame.displayMode = displayMode
        initializer(frame, 1)
    end
    _G.ToggleDropDownMenu = function()
        toggled = true
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.UI.frame = {
        shareMenuFrame = {},
    }
    addon.UI.RefreshRecipeList = function()
        error("opening the share menu should not refresh recipes")
    end
    addon.UI.RefreshDetailPanel = function()
        error("opening the share menu should not refresh recipe details")
    end

    addon.UI:OpenShareMenu({})

    Test.truthy(toggled, "share dropdown should open through UIDropDownMenu")
    Test.eq(#added, 4, "share menu should include available standard and reply channels")
    Test.eq(added[1].text, "Guild", "guild menu item")
    Test.eq(added[2].text, "Say", "say menu item")
    Test.eq(added[3].text, "Party", "party menu item")
    Test.eq(added[4].text, "Reply: Whisperfriend", "reply menu item")
end)

Test.it("opens a share menu through EasyMenu when native dropdown helpers are unavailable", function()
    local addon = freshUiAddon()
    local menuSeen
    local anchor = {}
    local shown = 0

    _G.IsInGroup = nil
    _G.ChatEdit_GetActiveWindow = nil
    _G.ChatEdit_GetLastTellTarget = nil
    _G.UIDropDownMenu_CreateInfo = nil
    _G.UIDropDownMenu_AddButton = nil
    _G.UIDropDownMenu_Initialize = nil
    _G.ToggleDropDownMenu = nil
    _G.EasyMenu = function(menu)
        menuSeen = menu
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.UI.frame = {
        shareMenuFrame = {},
        shareMenuClickCatcher = {
            Show = function()
                shown = shown + 1
            end,
            Hide = function() end,
        },
    }

    addon.UI:OpenShareMenu(anchor)

    Test.truthy(menuSeen, "EasyMenu should receive a menu")
    Test.eq(#menuSeen, 2, "EasyMenu should include available standard channels")
    Test.eq(menuSeen[1].text, "Guild", "EasyMenu guild item")
    Test.eq(menuSeen[2].text, "Say", "EasyMenu say item")
    Test.eq(shown, 1, "click catcher should show for EasyMenu")
    Test.eq(addon.UI._shareMenuOpen, true, "share menu state should open")
end)

Test.it("opens the built-in fallback share menu when dropdown APIs are unavailable", function()
    local addon = freshUiAddon()
    local shown = 0

    local function fakeFrame()
        local frame = {
            points = {},
            scripts = {},
            shown = false,
        }
        function frame:SetBackdrop(backdrop) self.backdrop = backdrop end
        function frame:SetBackdropColor(r, g, b, a) self.backdropColor = { r, g, b, a } end
        function frame:SetBackdropBorderColor(r, g, b, a) self.borderColor = { r, g, b, a } end
        function frame:SetFrameStrata(strata) self.frameStrata = strata end
        function frame:SetFrameLevel(level) self.frameLevel = level end
        function frame:GetFrameLevel() return self.frameLevel or 0 end
        function frame:SetClampedToScreen(value) self.clampedToScreen = value end
        function frame:SetSize(width, height) self.width, self.height = width, height end
        function frame:SetHeight(height) self.height = height end
        function frame:ClearAllPoints() self.points = {} end
        function frame:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function frame:SetText(text) self.text = text end
        function frame:SetScript(script, fn) self.scripts[script] = fn end
        function frame:Show() self.shown = true end
        function frame:Hide() self.shown = false end
        return frame
    end

    _G.IsInGroup = nil
    _G.ChatEdit_GetActiveWindow = nil
    _G.ChatEdit_GetLastTellTarget = nil
    _G.UIDropDownMenu_CreateInfo = nil
    _G.UIDropDownMenu_AddButton = nil
    _G.UIDropDownMenu_Initialize = nil
    _G.ToggleDropDownMenu = nil
    _G.EasyMenu = nil
    _G.CreateFrame = function()
        return fakeFrame()
    end

    addon.UI.selectedRecipeKey = "Alchemy:9001"
    addon.UI.frame = {
        right = {},
        shareMenuClickCatcher = {
            Show = function()
                shown = shown + 1
            end,
            Hide = function() end,
            GetFrameLevel = function()
                return 7
            end,
        },
    }

    addon.UI:OpenShareMenu({})

    local popup = addon.UI.frame.fallbackShareMenu
    Test.truthy(popup, "fallback menu should be created")
    Test.truthy(popup.shown, "fallback menu should show")
    Test.eq(shown, 1, "click catcher should show for fallback menu")
    Test.eq(#popup.rows, 2, "fallback menu should include available standard channels")
    Test.eq(popup.rows[1].text, "Guild", "fallback guild item")
    Test.eq(popup.rows[2].text, "Say", "fallback say item")
    Test.eq(addon.UI._shareMenuOpen, true, "fallback share menu state should open")
end)

Test.it("closes open share dropdowns when the main UI closes", function()
    local addon = freshUiAddon()
    local closed = 0
    local shareHidden = false
    local fallbackHidden = false
    local clickCatcherHidden = 0
    local searchCleared = false

    _G.CloseDropDownMenus = function()
        closed = closed + 1
    end

    addon.UI._shareMenuOpen = true
    addon.UI.ClearSearch = function()
        searchCleared = true
    end
    addon.UI.frame = {
        shown = true,
        IsShown = function(self)
            return self.shown == true
        end,
        Hide = function(self)
            self.shown = false
            addon.UI:HandleFrameHidden()
        end,
        shareMenuFrame = {
            Hide = function()
                shareHidden = true
            end,
        },
        fallbackShareMenu = {
            Hide = function()
                fallbackHidden = true
            end,
        },
        shareMenuClickCatcher = {
            Hide = function()
                clickCatcherHidden = clickCatcherHidden + 1
            end,
        },
    }

    addon.UI:Close("test")

    Test.eq(addon.UI.frame.shown, false, "main frame should close")
    Test.eq(closed, 1, "native dropdowns should close once")
    Test.truthy(shareHidden, "UIDropDownMenu frame should hide")
    Test.truthy(fallbackHidden, "fallback menu should hide")
    Test.gte(clickCatcherHidden, 1, "share menu click catcher should hide")
    Test.truthy(searchCleared, "normal frame hide handling should still run")
    Test.eq(addon.UI._shareMenuOpen, false, "share menu state should reset")
end)

Test.it("manages the share menu click catcher independently of recipe refresh", function()
    local addon = freshUiAddon()
    local shown = 0
    local hidden = 0

    addon.UI.frame = {
        shareMenuClickCatcher = {
            Show = function()
                shown = shown + 1
            end,
            Hide = function()
                hidden = hidden + 1
            end,
        },
    }
    addon.UI.RefreshRecipeList = function()
        error("share menu click catcher state should not refresh recipes")
    end
    addon.UI.RefreshDetailPanel = function()
        error("share menu click catcher state should not refresh recipe details")
    end

    addon.UI:ShowShareMenuClickCatcher()
    addon.UI:HideShareMenuClickCatcher()

    Test.eq(shown, 1, "share menu click catcher should show")
    Test.eq(hidden, 1, "share menu click catcher should hide")
end)

Test.it("closing the share dropdown does not close the main UI", function()
    local addon = freshUiAddon()
    local shareHidden = false
    local clickCatcherHidden = false

    addon.UI._shareMenuOpen = true
    addon.UI.frame = {
        shown = true,
        IsShown = function(self)
            return self.shown == true
        end,
        Hide = function(self)
            self.shown = false
        end,
        shareMenuFrame = {
            Hide = function()
                shareHidden = true
            end,
        },
        shareMenuClickCatcher = {
            Hide = function()
                clickCatcherHidden = true
            end,
        },
    }

    addon.UI:CloseShareMenus()

    Test.eq(addon.UI.frame.shown, true, "main frame should remain open")
    Test.truthy(shareHidden, "share dropdown frame should hide")
    Test.truthy(clickCatcherHidden, "share menu click catcher should hide")
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
