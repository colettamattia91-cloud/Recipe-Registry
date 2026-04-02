local ADDON_NAME = "RecipeRegistry"

local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceTimer-3.0"
)

_G.RecipeRegistry = Addon
Addon.DISPLAY_VERSION = "1.2.2"
Addon.WIRE_VERSION = 2
Addon.ADDON_PREFIX = "RRG1"
Addon.debugMode = false
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
    end
    if self.Sync then
        self.Sync:OnGuildRosterUpdate()
    end
    self:RequestRefresh("roster")
end

function Addon:RequestRefresh(reason)
    if reason then
        self._refreshReasons[reason] = true
    end
    -- Skip scheduling if our UI frame doesn't exist or isn't shown.
    if not (self.UI and self.UI.frame and self.UI.frame:IsShown()) then
        return
    end
    if self._refreshTimer then return end
    self._refreshTimer = self:ScheduleTimer(function()
        self._refreshTimer = nil
        self._refreshReasons = {}
        safecall(function()
            if self.UI and self.UI.Refresh then
                self.UI:Refresh()
            end
        end)
    end, 0.25)
end

function Addon:SlashHandler(input)
    local cmd, rest = self:GetArgs(input or "", 2)
    cmd = cmd and cmd:lower() or ""

    if cmd == "" or cmd == "show" then
        if self.UI then self.UI:Toggle() end
        return
    end

    if cmd == "debug" then
        self.debugMode = not self.debugMode
        self:Print("Debug " .. (self.debugMode and "enabled" or "disabled"))
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

    if cmd == "help" then
        self:Print("Commands: /rr, /rr options, /rr rescan, /rr mini, /rr sync, /rr prices <item name|link>, /rr share [guild|party|raid|say], /rr pull, /rr atlas, /rr r <recipeItemID>, /rr s <spellID>, /rr i <createdItemID>, /rr dump, /rr wipe")
        return
    end

    self:Print("Commands: /rr, /rr options, /rr rescan, /rr mini, /rr sync, /rr prices <item name|link>, /rr share [guild|party|raid|say], /rr pull, /rr atlas, /rr r <recipeItemID>, /rr s <spellID>, /rr i <createdItemID>, /rr dump, /rr wipe")
end
