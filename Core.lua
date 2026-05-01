local ADDON_NAME = "RecipeRegistry"

local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceTimer-3.0"
)

_G.RecipeRegistry = Addon
Addon.DISPLAY_VERSION = "1.5.2"
Addon.WIRE_VERSION = 2
Addon.ADDON_PREFIX = "RRG1"
Addon.debugMode = false
Addon.perfDebugMode = false
Addon._refreshReasons = {}

local function safecall(fn, ...)
    if type(fn) == "function" then
        local ok, err = pcall(fn, ...)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555Recipe Registry error:|r " .. tostring(err))
        end
    end
end

function Addon:Debug(...)
    if not self.debugMode then return end
    local out = {}
    for i = 1, select("#", ...) do
        out[#out + 1] = tostring(select(i, ...))
    end
    self:Print("|cff8888ff[debug]|r " .. table.concat(out, " "))
end

local function copySet(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function trimInput(text)
    return (text and text:match("^%s*(.-)%s*$")) or ""
end

local function splitCommand(text)
    local trimmed = trimInput(text)
    if trimmed == "" then
        return "", ""
    end

    local cmd, rest = trimmed:match("^(%S+)%s*(.-)$")
    return cmd or "", rest or ""
end

local function printPerfHelp(self)
    self:Print("/rr perf toggle - mostra o nasconde il pannello performance/debug.")
    self:Print("/rr perf dump - stampa scheduler, code e contatori sync correnti.")
    self:Print("/rr perf reset - azzera i contatori performance e sync.")
end

local function printMockHelp(self)
    self:Print("/rr mock status - stato attuale del mock e ultimi contatori.")
    self:Print("/rr mock start light|medium|heavy|burst - carico snapshot diretto crescente.")
    self:Print("/rr mock start bootstrap - trasferimento pesante in stile bootstrap.")
    self:Print("/rr mock start traffic - test completo HELLO/MANI/REQ/SNAP.")
    self:Print("/rr mock start offline - convergenza di owner offline via peer replica.")
    self:Print("/rr mock start offlinewipe - simula wipe locale + owner offline sconosciuti via replica.")
    self:Print("/rr mock start trafficburst - stress test del traffico replica.")
    self:Print("/rr mock start roster - simula roster cleanup con stale e prune.")
    self:Print("/rr mock start rosterheavy - variante più pesante del test roster.")
    self:Print("/rr mock cleanup - rimuove dati/stato mock locali dal client.")
    self:Print("/rr mock reset - azzera i contatori mock.")
    self:Print("/rr mock stop - ferma il worker mock locale e riapre il traffico reale.")
end

function Addon:OnInitialize()
    self:RegisterChatCommand("rr", "SlashHandler")
    self:RegisterChatCommand("reciperegistry", "SlashHandler")
end

function Addon:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
    self:RegisterEvent("NEW_RECIPE_LEARNED", "OnRecipeSignal")
    self:RegisterEvent("SPELLS_CHANGED", "OnRecipeSignal")
    self:RegisterEvent("SKILL_LINES_CHANGED", "OnRecipeSignal")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "OnItemInfoReceived")
    self:ScheduleTimer(function()
        if self.MinimapButton then self.MinimapButton:Refresh() end
        if self.UI then self.UI:CreateMainFrame() end
    end, 0.2)
end

function Addon:OnPlayerEnteringWorld(_event, isLogin, isReload)
    if not IsInGuild() then
        self:Debug("Not in guild, addon idle")
        return
    end

    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end

    if isLogin or isReload then
        self:ScheduleTimer("OnLoginReady", 4)
    else
        if self.Sync then
            self.Sync:ScheduleHello(2)
        end
    end
end

function Addon:OnLoginReady()
    if self.Data then
        self.Data:DetectProfessions()
    end
    if self.Sync then
        self.Sync:Startup()
    end
    self:RequestRefresh("login")
end

function Addon:OnTradeSkillShow()
    -- Defer scan so the Blizzard TradeSkillFrame finishes initialising first.
    if self._tradeSkillScanTimer then
        self:CancelTimer(self._tradeSkillScanTimer, true)
    end
    self._tradeSkillScanTimer = self:ScheduleTimer(function()
        self._tradeSkillScanTimer = nil
        if not (TradeSkillFrame and TradeSkillFrame:IsShown()) then return end
        if self.Data then
            local changed = self.Data:ScanTradeSkill()
            if changed and self.Sync then
                self.Sync:AdvertiseLocalRevision("trade-scan")
            end
        end
    end, 0.3)
end

function Addon:OnCraftShow()
    if self._craftScanTimer then
        self:CancelTimer(self._craftScanTimer, true)
    end
    self._craftScanTimer = self:ScheduleTimer(function()
        self._craftScanTimer = nil
        if not (CraftFrame and CraftFrame:IsShown()) then return end
        if self.Data then
            local changed = self.Data:ScanCraft()
            if changed and self.Sync then
                self.Sync:AdvertiseLocalRevision("craft-scan")
            end
        end
    end, 0.3)
end

function Addon:OnRecipeSignal()
    if self._recipeSignalTimer then
        self:CancelTimer(self._recipeSignalTimer, true)
    end
    self._recipeSignalTimer = self:ScheduleTimer("ProcessRecipeSignal", 1.0)
end

function Addon:ProcessRecipeSignal()
    self._recipeSignalTimer = nil
    if self.Data then
        self.Data:DetectProfessions()
        -- A real recipe change happened: force a fresh scan on the next profession open.
        self.Data._scanNeeded = true
        local changed = false
        if TradeSkillFrame and TradeSkillFrame:IsShown() then
            changed = self.Data:ScanTradeSkill() or changed
        end
        if CraftFrame and CraftFrame:IsShown() then
            changed = self.Data:ScanCraft() or changed
        end
        if changed and self.Sync then
            self.Sync:AdvertiseLocalRevision("recipe-event")
        end
    end
end

function Addon:OnGuildRosterUpdate()
    if self.Data then
        self.Data:RebuildOnlineCache()
        self.Data:InvalidateRecipeCaches("presence")
    end
    if self.Sync then
        self.Sync:OnGuildRosterUpdate()
    end
    self:RequestRefresh("roster")
end

function Addon:OnItemInfoReceived()
    if self._itemInfoTimer then return end
    self._itemInfoTimer = self:ScheduleTimer(function()
        self._itemInfoTimer = nil
        if self.Data then
            -- Item cache fills in names/icons progressively; keep heavy detail data
            -- cached and only rebuild recipe rows/search text that depend on labels.
            self.Data:InvalidateRecipeCaches("list")
        end
        self:RequestRefresh("item-cache")
    end, 0.5)
end

function Addon:RequestRefresh(reason)
    if self.Performance and self.Performance.MarkUIRefreshNeeded then
        self.Performance:MarkUIRefreshNeeded(reason)
        return
    end

    if reason then self._refreshReasons[reason] = true end
    if not (self.UI and self.UI.frame and self.UI.frame:IsShown()) then return end
    if self._refreshTimer then return end

    self._refreshTimer = self:ScheduleTimer(function()
        self._refreshTimer = nil
        local reasons = copySet(self._refreshReasons)
        self._refreshReasons = {}
        safecall(function()
            if self.UI and self.UI.Refresh then
                self.UI:Refresh(reasons)
            end
        end)
    end, 0.25)
end

function Addon:SlashHandler(input)
    local cmd, rest = splitCommand(input)
    cmd = cmd:lower()

    if cmd == "" or cmd == "show" then
        if self.UI then self.UI:Toggle() end
        return
    end

    if cmd == "debug" then
        self.debugMode = not self.debugMode
        self:Print("Debug " .. (self.debugMode and "enabled" or "disabled"))
        return
    end

    if cmd == "perf" then
        local perfCmd = trimInput(rest):lower()
        if perfCmd == "help" then
            printPerfHelp(self)
            return
        end
        if perfCmd == "" or perfCmd == "show" or perfCmd == "toggle" then
            self.perfDebugMode = not self.perfDebugMode
            if self.UI and self.UI.RefreshDebugVisibility then
                self.UI:RefreshDebugVisibility()
            end
            self:RequestRefresh("perf")
            self:Print("Performance debug " .. (self.perfDebugMode and "enabled" or "disabled"))
            return
        end
        if perfCmd == "dump" or perfCmd == "status" then
            if self.Performance and self.Performance.DumpDebugStatus then
                self.Performance:DumpDebugStatus()
            end
            if self.Sync and self.Sync.DumpStatus then
                self.Sync:DumpStatus()
            end
            return
        end
        if perfCmd == "reset" or perfCmd == "clear" then
            if self.Performance and self.Performance.ResetTelemetry then
                self.Performance:ResetTelemetry()
            end
            if self.Sync and self.Sync.ResetTelemetry then
                self.Sync:ResetTelemetry()
            end
            self:RequestRefresh("perf")
            self:Print("Performance counters reset.")
            return
        end
        self:Print("Usage: /rr perf [toggle|dump|reset|help]")
        return
    end

    if cmd == "mock" then
        local mockCmd, mockRest = splitCommand(rest)
        mockCmd = mockCmd:lower()
        mockRest = trimInput(mockRest):lower()
        if not self.MockSync then
            self:Print("Mock sync module not available.")
            return
        end
        if mockCmd == "help" then
            printMockHelp(self)
            return
        end
        if mockCmd == "" or mockCmd == "status" then
            self.MockSync:DumpStatus()
            return
        end
        if mockCmd == "start" then
            local scenario = mockRest ~= "" and mockRest or "medium"
            local ok, err = self.MockSync:StartScenario(scenario)
            if ok then
                self:Print("Mock sync started: " .. scenario)
            else
                self:Print("Mock sync start failed: " .. tostring(err))
            end
            return
        end
        if mockCmd == "stop" then
            self.MockSync:Stop()
            self:Print("Mock sync stopped.")
            return
        end
        if mockCmd == "cleanup" or mockCmd == "clean" then
            local removedMembers, removedRegistry, removedOnlineNodes, removedPending = self.MockSync:Cleanup()
            self:Print(string.format(
                "Mock cleanup complete. members=%d registry=%d nodes=%d pending=%d",
                removedMembers or 0,
                removedRegistry or 0,
                removedOnlineNodes or 0,
                removedPending or 0
            ))
            return
        end
        if mockCmd == "reset" then
            self.MockSync:ResetTelemetry()
            self:Print("Mock sync counters reset.")
            self:RequestRefresh("mock")
            return
        end
        self:Print("Usage: /rr mock [status|start <light|medium|heavy|burst|bootstrap|traffic|offline|offlinewipe|trafficburst|roster|rosterheavy>|stop|cleanup|reset|help]")
        return
    end

    if cmd == "dump" then
        if self.Data then self.Data:DumpSummary() end
        return
    end

    if cmd == "atlas" or cmd == "al" then
        if self.Data then self.Data:DumpAtlasLootStatus() end
        return
    end

    if cmd == "r" or cmd == "recipe" then
        if self.Data then self.Data:DebugRecipeItem(tonumber(rest or "")) end
        return
    end

    if cmd == "s" or cmd == "spell" then
        if self.Data then self.Data:DebugSpell(tonumber(rest or "")) end
        return
    end

    if cmd == "i" or cmd == "item" or cmd == "created" then
        if self.Data then self.Data:DebugCreatedItem(tonumber(rest or "")) end
        return
    end

    if cmd == "wipe" or cmd == "reset" then
        if self.Data then self.Data:WipeDatabase() end
        return
    end

    if cmd == "sync" or cmd == "comms" then
        if self.Sync then self.Sync:DumpStatus() end
        return
    end

    if cmd == "offline" or cmd == "replica" then
        if self.Sync and self.Sync.DumpOfflineSyncStatus then
            self.Sync:DumpOfflineSyncStatus()
        end
        return
    end

    if cmd == "manifest" or cmd == "publish" then
        local target = trimInput(rest)
        if target ~= "" and self.Sync and self.Sync.RequestManifestRefresh then
            self.Sync:RequestManifestRefresh(target)
            self:Print("Requested fresh manifest from " .. target .. ".")
            return
        end
        if self.Data and self.Data.DumpManifestSummary then
            self.Data:DumpManifestSummary()
        end
        return
    end

    if cmd == "prices" or cmd == "price" then
        if self.Market then self.Market:DumpStatus(rest) end
        return
    end

    if cmd == "share" then
        if self.UI then self.UI:ShareSelectedRecipe(rest) end
        return
    end

    if cmd == "options" or cmd == "opt" or cmd == "config" then
        if InterfaceOptionsFrame_OpenToCategory and self.Options and self.Options.panel then
            InterfaceOptionsFrame_OpenToCategory(self.Options.panel)
            InterfaceOptionsFrame_OpenToCategory(self.Options.panel)
        else
            self:Print("Options panel not available yet.")
        end
        return
    end

    if cmd == "rescan" then
        if self.Data then
            self.Data:DetectProfessions()
            self:Print("Open profession windows to refresh recipe lists.")
        end
        return
    end

    if cmd == "pull" then
        if self.Sync then self.Sync:RequestGuildCatchup(rest, false) end
        return
    end

    if cmd == "mini" or cmd == "minimap" then
        if self.MinimapButton then self.MinimapButton:ToggleHidden() end
        return
    end

    if cmd == "clean" then
        if self.Data then
            local removed = self.Data:CleanInvalidRecipes()
            self:Print(string.format("Cleaned %d invalid recipe(s) from database.", removed))
        end
        return
    end

    if cmd == "help" then
        self:Print("Commands: /rr, /rr options, /rr mini, /rr sync, /rr perf [toggle|dump|reset|help], /rr mock [status|start <light|medium|heavy|burst|bootstrap|traffic|offline|trafficburst|roster|rosterheavy>|stop|cleanup|reset|help], /rr prices <item name|link>, /rr share [guild|party|raid|say], /rr pull, /rr clean, /rr atlas, /rr r <recipeItemID>, /rr s <spellID>, /rr i <createdItemID>, /rr dump, /rr wipe")
        return
    end

    self:Print("Commands: /rr, /rr options, /rr mini, /rr sync, /rr perf [toggle|dump|reset|help], /rr mock [status|start <light|medium|heavy|burst|bootstrap|traffic|offline|trafficburst|roster|rosterheavy>|stop|cleanup|reset|help], /rr prices <item name|link>, /rr share [guild|party|raid|say], /rr pull, /rr clean, /rr atlas, /rr r <recipeItemID>, /rr s <spellID>, /rr i <createdItemID>, /rr dump, /rr wipe")
end
