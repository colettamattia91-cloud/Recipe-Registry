local ADDON_NAME = "RecipeRegistry"

local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceTimer-3.0",
    "AceBucket-3.0"
)

_G.RecipeRegistry = Addon
Addon.debugMode = false
Addon.perfDebugMode = false
Addon._refreshReasons = {}

local time = time
local max = math.max
local min = math.min

local DEBUG_LOG_DEFAULTS = {
    enabled = false,
    maxEntries = 400,
    chatEcho = false,
    scopes = {
        sync = true,
        request = true,
        transfer = true,
        offline = true,
        version = true,
    },
    entries = {},
    nextSequence = 0,
}

local DEBUG_LOG_SCOPE_NAMES = {
    sync = true,
    request = true,
    transfer = true,
    offline = true,
    version = true,
}

local function cloneShallow(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function initDebugLogDB()
    if type(_G.RecipeRegistryLogDB) ~= "table" then
        _G.RecipeRegistryLogDB = {}
    end
    local db = _G.RecipeRegistryLogDB
    if type(db.enabled) ~= "boolean" then
        db.enabled = DEBUG_LOG_DEFAULTS.enabled
    end
    if type(db.maxEntries) ~= "number" or db.maxEntries < 50 then
        db.maxEntries = DEBUG_LOG_DEFAULTS.maxEntries
    end
    if type(db.chatEcho) ~= "boolean" then
        db.chatEcho = DEBUG_LOG_DEFAULTS.chatEcho
    end
    if type(db.scopes) ~= "table" then
        db.scopes = cloneShallow(DEBUG_LOG_DEFAULTS.scopes)
    else
        for scopeName in pairs(DEBUG_LOG_SCOPE_NAMES) do
            if type(db.scopes[scopeName]) ~= "boolean" then
                db.scopes[scopeName] = DEBUG_LOG_DEFAULTS.scopes[scopeName]
            end
        end
    end
    if type(db.entries) ~= "table" then
        db.entries = {}
    end
    if type(db.nextSequence) ~= "number" then
        db.nextSequence = 0
    end
    return db
end

function Addon:GetDebugLogDB()
    return initDebugLogDB()
end

function Addon:IsDebugLogEnabled(scope)
    local db = self:GetDebugLogDB()
    if db.enabled ~= true then
        return false
    end
    local normalizedScope = tostring(scope or ""):lower()
    if normalizedScope == "" then
        return true
    end
    return db.scopes[normalizedScope] == true
end

function Addon:WriteDebugLog(scope, message, fields)
    local normalizedScope = tostring(scope or "general"):lower()
    if not self:IsDebugLogEnabled(normalizedScope) then
        return false
    end

    local db = self:GetDebugLogDB()
    db.nextSequence = (db.nextSequence or 0) + 1

    local entry = {
        seq = db.nextSequence,
        at = time(),
        scope = normalizedScope,
        message = tostring(message or ""),
    }
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            entry[key] = value
        end
    end
    if self.Data and self.Data.GetPlayerKey then
        entry.localPlayer = self.Data:GetPlayerKey()
    end

    local entries = db.entries
    entries[#entries + 1] = entry
    -- Batched trim: instead of paying O(N) on every append once the buffer is
    -- full (table.remove(t, 1) shifts everything), let the buffer grow to ~2x
    -- the cap, then compact in one walk. Amortized O(1) per append; trim
    -- happens once every ~maxEntries traces.
    local cap = max(50, db.maxEntries or DEBUG_LOG_DEFAULTS.maxEntries)
    local count = #entries
    if count > cap * 2 then
        local startIndex = count - cap + 1
        local kept = {}
        for i = startIndex, count do
            kept[#kept + 1] = entries[i]
        end
        db.entries = kept
    end

    if db.chatEcho == true and self.debugMode then
        self:Print(string.format("|cff88ccff[trace:%s]|r %s", normalizedScope, entry.message))
    end
    return true
end

function Addon:Trace(scope, ...)
    -- Early gate before tostring/concat — the formatted args still get
    -- evaluated by the caller (Lua arg semantics), but at least we skip the
    -- parts/tostring/concat work when the scope is disabled. Hot-path callers
    -- should prefer Addon:Tracef which gates BEFORE the format string runs.
    if not self:IsDebugLogEnabled(scope) then
        return false
    end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return self:WriteDebugLog(scope, table.concat(parts, " "))
end

-- Lazy-formatting trace: skips string.format entirely when the scope is
-- disabled. Use this in hot paths (protocol dispatch, block-pull handlers,
-- merge, rebuild) where the trace arguments include tostring() calls or
-- format strings that would otherwise run unconditionally.
function Addon:Tracef(scope, fmt, ...)
    if not self:IsDebugLogEnabled(scope) then
        return false
    end
    local message
    if select("#", ...) > 0 then
        message = string.format(tostring(fmt or ""), ...)
    else
        message = tostring(fmt or "")
    end
    return self:WriteDebugLog(scope, message)
end

function Addon:GetDebugLogEntries(limit, scope)
    local db = self:GetDebugLogDB()
    local entries = db.entries or {}
    local normalizedScope = tostring(scope or ""):lower()
    local out = {}
    for index = #entries, 1, -1 do
        local entry = entries[index]
        if normalizedScope == "" or tostring(entry.scope or "") == normalizedScope then
            out[#out + 1] = entry
            if limit and #out >= limit then
                break
            end
        end
    end
    return out
end

function Addon:ClearDebugLog()
    local db = self:GetDebugLogDB()
    db.entries = {}
    db.nextSequence = 0
end

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

function Addon:SystemPrint(...)
    if not self.debugMode then return end
    self:Print(...)
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

local function scanResultChanged(result)
    if type(result) == "table" then
        return result.changed == true
    end
    return result == true
end

local function scanActiveProfessionData(self, opts)
    if not self.Data then return false end
    opts = opts or {}
    local changed = false
    if opts.source == "trade" then
        if self.Data.ScanTradeSkill then
            changed = scanResultChanged(self.Data:ScanTradeSkill(opts)) or changed
        end
        return changed
    end
    if opts.source == "craft" then
        if self.Data.ScanCraft then
            changed = scanResultChanged(self.Data:ScanCraft(opts)) or changed
        end
        return changed
    end
    if self.Data.ScanTradeSkill then
        changed = scanResultChanged(self.Data:ScanTradeSkill(opts)) or changed
    end
    if self.Data.ScanCraft then
        changed = scanResultChanged(self.Data:ScanCraft(opts)) or changed
    end
    return changed
end

local function markSyncIndexDirtyAndScheduleHello(self, reason, delay)
    if self.Data and self.Data.MarkSyncIndexDirty then
        self.Data:MarkSyncIndexDirty(reason)
        if self.Data.ScheduleSyncIndexPrepare then
            self.Data:ScheduleSyncIndexPrepare(reason, 0.2)
        end
    end
    if self.Sync and self.Sync.ScheduleHello then
        self.Sync:ScheduleHello(reason, delay or 0.5)
        if self.Sync.RefreshSyncReadyState then
            self.Sync:RefreshSyncReadyState(reason)
        end
    end
end

local function splitCommand(text)
    local trimmed = trimInput(text)
    if trimmed == "" then
        return "", ""
    end

    local cmd, rest = trimmed:match("^(%S+)%s*(.-)$")
    return cmd or "", rest or ""
end

local function normalizeDebugLogScope(scope)
    local normalized = trimInput(scope):lower()
    if normalized == "" then
        return nil
    end
    if DEBUG_LOG_SCOPE_NAMES[normalized] then
        return normalized
    end
    return nil
end

local MOCK_SCENARIOS = "light, medium, heavy, burst, bootstrap, traffic, offline, offlinewipe, trafficburst, roster, rosterheavy, rosterbad, integrity"

local function printMainHelp(self)
    self:Print("Commands:")
    self:Print("/rr - open or close the main window.")
    self:Print("/rr options, /rr mini, /rr debug, /rr debug log")
    self:Print("/rr rescan - queue a profession scan and scan active profession API data.")
    self:Print("/rr version, /rr versions, /rr dump, /rr self [profession], /rr sync [debug, diag, peers, sessions, log], /rr offline, /rr pull")
    self:Print("/rr perf [toggle, dump, reset, help]")
    if self.MockSync then
        self:Print("/rr mock [status, start <" .. MOCK_SCENARIOS .. ">, stop, cleanup, reset, help]")
    end
    self:Print("/rr prices <item name or link>, /rr share [guild, party, raid, say]")
    self:Print("/rr atlas, /rr r <recipeItemID>, /rr s <spellID>, /rr i <createdItemID>")
    self:Print("/rr clean [check], /rr wipe")
end

local function printPerfHelp(self)
    self:Print("/rr perf toggle - show or hide the performance/debug panel.")
    self:Print("/rr perf dump - print scheduler, queues, sync and scan diagnostics.")
    self:Print("/rr perf reset - clear performance, sync and scan counters.")
end

local function printDebugLogHelp(self)
    self:Print("/rr debug - enable or disable chat debug output.")
    self:Print("/rr debug log on|off|status|show [count] [scope]|clear")
    self:Print("/rr debug log scope <sync|request|transfer|offline|version> <on|off>")
    self:Print("/rr debug log echo on|off - mirror persistent traces to the debug chat.")
end

local function printMockHelp(self)
    self:Print("/rr mock status - current mock state and latest counters.")
    self:Print("/rr mock start light, medium, heavy, burst - increasing direct-snapshot load.")
    self:Print("/rr mock start bootstrap - heavy bootstrap-style transfer.")
    self:Print("/rr mock start traffic - full HELLO/SUMMARY/INDEX_DIFF/BLOCK_PULL exercise.")
    self:Print("/rr mock start offline - convergence of offline owners via a replica peer.")
    self:Print("/rr mock start offlinewipe - simulate local wipe + unknown offline owners via replica.")
    self:Print("/rr mock start trafficburst - replica traffic stress test.")
    self:Print("/rr mock start roster - simulate roster cleanup with stale + prune.")
    self:Print("/rr mock start rosterheavy - heavier variant of the roster test.")
    self:Print("/rr mock start rosterbad - check the incomplete-roster-snapshot guardrail.")
    self:Print("/rr mock start integrity - check partial-snapshot and merge protections.")
    self:Print("/rr mock cleanup - remove local mock data/state from the client.")
    self:Print("/rr mock reset - clear the mock counters.")
    self:Print("/rr mock stop - stop the local mock worker and resume real traffic.")
end

function Addon:OnInitialize()
    self:RegisterChatCommand("rr", "SlashHandler")
    self:RegisterChatCommand("reciperegistry", "SlashHandler")
    initDebugLogDB()
    self.bucketTelemetry = {
        rosterEventsAbsorbed = 0,
        rosterBuckets = 0,
        rosterDeferred = 0,
        itemEventsAbsorbed = 0,
        itemBuckets = 0,
        lastRosterBucketAt = 0,
        lastItemBucketAt = 0,
    }
end

function Addon:MarkSavedVariablesReady(reason)
    if self.Sync and self.Sync.SetSavedVariablesReady then
        self.Sync._savedVariablesReadyBootstrap = true
        self.Sync:SetSavedVariablesReady(reason or "addon-initialize")
        return true
    end
    return false
end

function Addon:OnEnable()
    self:RegisterEvent("PLAYER_LOGIN", "OnPlayerLogin")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
    self:RegisterEvent("NEW_RECIPE_LEARNED", "OnRecipeSignal")
    self:RegisterEvent("SPELLS_CHANGED", "OnSkillSignal")
    self:RegisterEvent("SKILL_LINES_CHANGED", "OnSkillSignal")
    self:RegisterBucketEvent("GUILD_ROSTER_UPDATE", 1.5, "OnGuildRosterBucket")
    self:RegisterBucketEvent("GET_ITEM_INFO_RECEIVED", 0.75, "OnItemInfoBucket")
    self:ScheduleTimer(function()
        if self.MinimapButton then self.MinimapButton:Refresh() end
        if self.UI then self.UI:CreateMainFrame() end
    end, 0.2)
end

function Addon:OnPlayerLogin()
    if self.Sync and self.Sync.Startup then
        self.Sync:Startup()
    end
    if self.Sync and self.Sync.SetPlayerReady then
        self.Sync:SetPlayerReady("player-login")
    end
    if self.Data then
        self.Data:DetectProfessions()
        if self.Data.ScheduleSyncIndexPrepare then
            self.Data:ScheduleSyncIndexPrepare("player-login", 0.2)
        end
    end
    if self.Data and self.Data.ScheduleSafeAutoClean then
        self:ScheduleTimer(function()
            self.Data:ScheduleSafeAutoClean({ maxMembersPerStep = 8 })
        end, 8)
    end
    -- Keep one watchdog for pathological reload/login paths, but readiness comes
    -- from PLAYER_LOGIN / PLAYER_ENTERING_WORLD / GUILD_ROSTER_UPDATE + index prep.
    self:ScheduleTimer("OnLoginReady", 10)
    self:RequestRefresh("login")
end

function Addon:OnPlayerEnteringWorld(_event, isLogin, isReload)
    if not IsInGuild() then
        self:Debug("Not in guild, addon idle")
        return
    end

    if self.Sync and self.Sync.EnterWorldTransition then
        local syncConstants = self.Sync._private and self.Sync._private.constants or {}
        local inInstance = IsInInstance and select(1, IsInInstance()) or false
        -- Pick the longest applicable grace for the event we're handling.
        -- Login and reload do a lot more work than a zone change (item
        -- cache priming, full guild roster fetch, AtlasLoot warmup,
        -- profession scan), so they get their own dedicated values.
        local duration
        if inInstance and (isLogin or isReload) then
            duration = syncConstants.POST_RELOAD_IN_INSTANCE_GRACE_SECONDS or 30
        elseif isLogin then
            duration = syncConstants.POST_LOGIN_GRACE_SECONDS or 30
        elseif isReload then
            duration = syncConstants.POST_RELOAD_GRACE_SECONDS or 25
        elseif inInstance then
            duration = syncConstants.POST_INSTANCE_GRACE_SECONDS or 15
        else
            duration = syncConstants.POST_WORLD_GRACE_SECONDS or 12
        end
        self.Sync:EnterWorldTransition(
            isLogin and "login"
                or (isReload and "reload")
                or (inInstance and "instance-enter")
                or "zone-enter",
            duration
        )
    end

    if (isLogin or isReload) and self.Data and self.Data.RequestRosterSnapshot then
        self.Data:RequestRosterSnapshot(isReload and "reload" or "login", {
            cooldown = 0,
            source = "player-entering-world",
        })
    end

    if self.Data and self.Data.ScheduleSyncIndexPrepare then
        self.Data:ScheduleSyncIndexPrepare("player-entering-world", 1)
    end
    if self.Sync and self.Sync.RefreshSyncReadyState then
        self.Sync:RefreshSyncReadyState("player-entering-world")
    end
end

function Addon:OnLoginReady()
    if self.Sync and self.Sync.OnRosterPreflightWatchdog then
        self.Sync:OnRosterPreflightWatchdog("login-watchdog")
    end
    if self.Sync and self.Sync.RefreshSyncReadyState then
        self.Sync:RefreshSyncReadyState("login-watchdog")
    end
end

local function countBucketEvents(events)
    local total = 0
    for _, count in pairs(events or {}) do
        if type(count) == "number" then
            total = total + count
        else
            total = total + 1
        end
    end
    return total
end

function Addon:OnTradeSkillShow()
    -- Defer scan so the Blizzard TradeSkillFrame finishes initialising first.
    if self._tradeSkillScanTimer then
        self:CancelTimer(self._tradeSkillScanTimer, true)
    end
    self._tradeSkillScanTimer = self:ScheduleTimer(function()
        self._tradeSkillScanTimer = nil
        if self.Data then
            local metadataChanged = self.Data:DetectProfessions() == true
            local changed = scanResultChanged(self.Data:ScanTradeSkill({
                reason = "profession-open",
                notifyMode = "auto",
            })) or metadataChanged
            if changed then
                markSyncIndexDirtyAndScheduleHello(self, "trade-scan", 0.5)
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
        if self.Data then
            local metadataChanged = self.Data:DetectProfessions() == true
            local changed = scanResultChanged(self.Data:ScanCraft({
                reason = "profession-open",
                notifyMode = "auto",
            })) or metadataChanged
            if changed then
                markSyncIndexDirtyAndScheduleHello(self, "craft-scan", 0.5)
            end
        end
    end, 0.3)
end

function Addon:OnRecipeSignal()
    if self._recipeSignalTimer then
        self:CancelTimer(self._recipeSignalTimer, true)
    end
    self._recipeSignalTimer = self:ScheduleTimer(function()
        self:ProcessRecipeSignal("recipe-learned")
    end, 1.0)
end

function Addon:ProcessRecipeSignal(reason)
    self._recipeSignalTimer = nil
    if self.Data then
        local scanReason = tostring(reason or "recipe-learned")
        local metadataChanged = self.Data:DetectProfessions() == true
        if self.Data.MarkScanNeeded then
            self.Data:MarkScanNeeded(nil, scanReason)
        else
            self.Data._scanNeeded = true
        end
        local changed = scanActiveProfessionData(self, {
            reason = scanReason,
            notifyMode = "auto",
        }) or metadataChanged
        if changed then
            markSyncIndexDirtyAndScheduleHello(self, scanReason, 0.5)
        end
    end
end

function Addon:OnSkillSignal(event)
    self._lastSkillSignalEvent = event or self._lastSkillSignalEvent or "SPELLS_CHANGED"
    if self._skillSignalTimer then
        self:CancelTimer(self._skillSignalTimer, true)
    end
    self._skillSignalTimer = self:ScheduleTimer(function()
        self:ProcessSkillSignal(self._lastSkillSignalEvent)
    end, 1.0)
end

function Addon:ProcessSkillSignal(event)
    self._skillSignalTimer = nil
    local signal = tostring(event or self._lastSkillSignalEvent or "SPELLS_CHANGED")
    self._lastSkillSignalEvent = nil
    if not self.Data then
        return
    end

    local profession, source
    if self.Data.GetVisibleTrackedProfessionContext then
        profession, source = self.Data:GetVisibleTrackedProfessionContext()
    end
    if not profession then
        if signal == "SKILL_LINES_CHANGED" then
            self.Data:RecordScanTelemetry("scanSkippedWeaponSkill")
        else
            self.Data:RecordScanTelemetry("scanSkippedGenericSkill")
        end
        return
    end

    local reason = signal == "SPELLS_CHANGED" and "spell-update" or "skill-event"
    local metadataChanged = self.Data:DetectProfessions() == true
    self.Data:MarkScanNeeded(profession, reason)
    local changed = scanActiveProfessionData(self, {
        reason = reason,
        notifyMode = "auto",
        source = source,
    }) or metadataChanged
    if changed then
        markSyncIndexDirtyAndScheduleHello(self, reason, 0.5)
    end
end

function Addon:ResetBucketTelemetry()
    self.bucketTelemetry = self.bucketTelemetry or {}
    self.bucketTelemetry.rosterEventsAbsorbed = 0
    self.bucketTelemetry.rosterBuckets = 0
    self.bucketTelemetry.rosterDeferred = 0
    self.bucketTelemetry.itemEventsAbsorbed = 0
    self.bucketTelemetry.itemBuckets = 0
    self.bucketTelemetry.lastRosterBucketAt = 0
    self.bucketTelemetry.lastItemBucketAt = 0
end

function Addon:GetBucketTelemetrySnapshot()
    self.bucketTelemetry = self.bucketTelemetry or {}
    return {
        rosterEventsAbsorbed = self.bucketTelemetry.rosterEventsAbsorbed or 0,
        rosterBuckets = self.bucketTelemetry.rosterBuckets or 0,
        rosterDeferred = self.bucketTelemetry.rosterDeferred or 0,
        itemEventsAbsorbed = self.bucketTelemetry.itemEventsAbsorbed or 0,
        itemBuckets = self.bucketTelemetry.itemBuckets or 0,
        lastRosterBucketAt = self.bucketTelemetry.lastRosterBucketAt or 0,
        lastItemBucketAt = self.bucketTelemetry.lastItemBucketAt or 0,
    }
end

function Addon:DumpBucketStatus()
    local snapshot = self:GetBucketTelemetrySnapshot()
    self:SystemPrint(string.format(
        "Buckets rosterEvents=%d rosterFlushes=%d rosterDeferred=%d lastRosterAt=%d itemEvents=%d itemFlushes=%d lastItemAt=%d",
        snapshot.rosterEventsAbsorbed or 0,
        snapshot.rosterBuckets or 0,
        snapshot.rosterDeferred or 0,
        snapshot.lastRosterBucketAt or 0,
        snapshot.itemEventsAbsorbed or 0,
        snapshot.itemBuckets or 0,
        snapshot.lastItemBucketAt or 0
    ))
end

function Addon:OnGuildRosterBucket(events)
    local absorbed = countBucketEvents(events)
    self.bucketTelemetry = self.bucketTelemetry or {}
    self.bucketTelemetry.rosterBuckets = (self.bucketTelemetry.rosterBuckets or 0) + 1
    self.bucketTelemetry.rosterEventsAbsorbed = (self.bucketTelemetry.rosterEventsAbsorbed or 0) + absorbed
    self.bucketTelemetry.lastRosterBucketAt = time()
    if self.Sync and self.Sync.telemetry then
        self.Sync.telemetry.rosterEventsSeen = (self.Sync.telemetry.rosterEventsSeen or 0) + absorbed
        self.Sync.telemetry.rosterEventsCoalesced = (self.Sync.telemetry.rosterEventsCoalesced or 0) + max(0, absorbed - 1)
    end
    if self.Sync and self.Sync.ShouldDeferHeavyLifecycleWork then
        local shouldDefer = self.Sync:ShouldDeferHeavyLifecycleWork("roster-ui")
        if shouldDefer then
            self.bucketTelemetry.rosterDeferred = (self.bucketTelemetry.rosterDeferred or 0) + 1
            self:ScheduleRosterUpdate("bucket")
            return
        end
    end
    self:ProcessCoalescedGuildRosterUpdate("bucket")
end

function Addon:OnItemInfoBucket(events)
    local absorbed = countBucketEvents(events)
    self.bucketTelemetry = self.bucketTelemetry or {}
    self.bucketTelemetry.itemBuckets = (self.bucketTelemetry.itemBuckets or 0) + 1
    self.bucketTelemetry.itemEventsAbsorbed = (self.bucketTelemetry.itemEventsAbsorbed or 0) + absorbed
    self.bucketTelemetry.lastItemBucketAt = time()
    if self.Data then
        self.Data:InvalidateRecipeCaches("list")
    end
    self:RequestRefresh("item-cache")
end

function Addon:ScheduleRosterUpdate(reason)
    if self._rosterUpdateTimer then
        return
    end
    self._rosterUpdateTimer = self:ScheduleTimer(function()
        self._rosterUpdateTimer = nil
        self:ProcessCoalescedGuildRosterUpdate(reason or "roster")
    end, 3)
end

function Addon:ProcessCoalescedGuildRosterUpdate(reason)
    local delta = self.Data and self.Data.RebuildOnlineCache and self.Data:RebuildOnlineCache() or nil
    local heavyUpdate = not delta
        or delta.membershipChanged
        or delta.guildStatusChanged
        or delta.knownMembersChanged
    local presenceOnly = delta
        and not heavyUpdate
        and (delta.presenceChanged or delta.onlineCountChanged)

    if self.Data and (heavyUpdate or presenceOnly) then
        self.Data:InvalidateRecipeCaches("presence")
    end
    if self.Sync then
        if presenceOnly and self.Sync.telemetry then
            self.Sync.telemetry.rosterPresenceOnlyUpdates = (self.Sync.telemetry.rosterPresenceOnlyUpdates or 0) + 1
        elseif heavyUpdate and self.Sync.telemetry then
            self.Sync.telemetry.rosterHeavyUpdates = (self.Sync.telemetry.rosterHeavyUpdates or 0) + 1
        end
        self.Sync:OnGuildRosterUpdate({
            reason = reason or "roster",
            delta = delta,
            heavyUpdate = heavyUpdate,
            presenceOnly = presenceOnly,
        })
    end
    if heavyUpdate or presenceOnly then
        self:RequestRefresh(reason or "roster")
    end
end

function Addon:OnGuildRosterUpdate()
    self:OnGuildRosterBucket({ direct = 1 })
end

function Addon:OnItemInfoReceived()
    self:OnItemInfoBucket({ direct = 1 })
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
        local debugCmd, debugRest = splitCommand(rest)
        debugCmd = debugCmd:lower()
        if debugCmd == "" or debugCmd == "toggle" then
            self.debugMode = not self.debugMode
            self:Print("Debug " .. (self.debugMode and "enabled" or "disabled"))
            return
        end
        if debugCmd == "help" then
            printDebugLogHelp(self)
            return
        end
        if debugCmd == "log" then
            local logCmd, logRest = splitCommand(debugRest)
            logCmd = logCmd:lower()
            local db = self:GetDebugLogDB()
            if logCmd == "" or logCmd == "status" then
                local enabledScopes = {}
                for scopeName in pairs(DEBUG_LOG_SCOPE_NAMES) do
                    if db.scopes[scopeName] == true then
                        enabledScopes[#enabledScopes + 1] = scopeName
                    end
                end
                table.sort(enabledScopes)
                self:Print(string.format(
                    "Debug log %s entries=%d max=%d echo=%s scopes=%s",
                    db.enabled and "enabled" or "disabled",
                    #(db.entries or {}),
                    db.maxEntries or DEBUG_LOG_DEFAULTS.maxEntries,
                    db.chatEcho and "on" or "off",
                    #enabledScopes > 0 and table.concat(enabledScopes, ",") or "none"
                ))
                return
            end
            if logCmd == "on" then
                db.enabled = true
                self:Print("Debug log enabled.")
                return
            end
            if logCmd == "off" then
                db.enabled = false
                self:Print("Debug log disabled.")
                return
            end
            if logCmd == "clear" or logCmd == "reset" then
                self:ClearDebugLog()
                self:Print("Debug log cleared.")
                return
            end
            if logCmd == "echo" then
                local echoMode = trimInput(logRest):lower()
                if echoMode == "on" or echoMode == "off" then
                    db.chatEcho = echoMode == "on"
                    self:Print("Debug log echo " .. (db.chatEcho and "enabled" or "disabled") .. ".")
                else
                    self:Print("Usage: /rr debug log echo on|off")
                end
                return
            end
            if logCmd == "scope" then
                local scopeToken, scopeRest = splitCommand(logRest)
                local scopeName = normalizeDebugLogScope(scopeToken)
                local scopeMode = trimInput(scopeRest):lower()
                if not scopeName then
                    self:Print("Usage: /rr debug log scope <sync|request|transfer|offline|version> <on|off>")
                    return
                end
                if scopeMode ~= "on" and scopeMode ~= "off" then
                    self:Print("Usage: /rr debug log scope <sync|request|transfer|offline|version> <on|off>")
                    return
                end
                db.scopes[scopeName] = scopeMode == "on"
                self:Print(string.format("Debug log scope %s %s.", scopeName, db.scopes[scopeName] and "enabled" or "disabled"))
                return
            end
            if logCmd == "show" then
                local firstToken, secondToken = splitCommand(logRest)
                local limit = 20
                local scopeName = nil
                if tonumber(firstToken) then
                    limit = min(200, max(1, tonumber(firstToken) or 20))
                    scopeName = normalizeDebugLogScope(secondToken)
                else
                    scopeName = normalizeDebugLogScope(firstToken)
                end
                local entries = self:GetDebugLogEntries(limit, scopeName)
                if #entries == 0 then
                    self:Print("Debug log entries: none")
                    return
                end
                self:Print(string.format("Debug log entries: %d%s", #entries, scopeName and (" scope=" .. scopeName) or ""))
                for index = #entries, 1, -1 do
                    local entry = entries[index]
                    self:Print(string.format(
                        "#%d t=%d scope=%s %s",
                        entry.seq or 0,
                        entry.at or 0,
                        tostring(entry.scope or "?"),
                        tostring(entry.message or "")
                    ))
                end
                return
            end
            printDebugLogHelp(self)
            return
        end
        printDebugLogHelp(self)
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
            if not self.debugMode then
                return
            end
            if self.Performance and self.Performance.DumpDebugStatus then
                self.Performance:DumpDebugStatus()
            end
            if self.DumpBucketStatus then
                self:DumpBucketStatus()
            end
            if self.Sync and self.Sync.DumpStatus then
                self.Sync:DumpStatus()
            end
            if self.Data and self.Data.DumpScanStatus then
                self.Data:DumpScanStatus()
            end
            if self.Data and self.Data.GetCatalogDiagnostics then
                local diagnostics = self.Data:GetCatalogDiagnostics()
                self:SystemPrint(string.format(
                    "Catalog duplicateCrafterRows=%d collapsed=%d lastRecipe=%s lastMember=%s",
                    diagnostics.duplicateCrafterRowsDetected or 0,
                    diagnostics.duplicateCrafterRowsCollapsed or 0,
                    tostring(diagnostics.lastDuplicateRecipeKey or "none"),
                    tostring(diagnostics.lastDuplicateMemberKey or "none")
                ))
            end
            if self.Data and self.Data.DumpSyncIndexStatus then
                self.Data:DumpSyncIndexStatus()
            end
            return
        end
        if perfCmd == "reset" or perfCmd == "clear" then
            if self.Performance and self.Performance.ResetTelemetry then
                self.Performance:ResetTelemetry()
            end
            if self.ResetBucketTelemetry then
                self:ResetBucketTelemetry()
            end
            if self.Sync and self.Sync.ResetTelemetry then
                self.Sync:ResetTelemetry()
            end
            if self.Data and self.Data.ResetScanTelemetry then
                self.Data:ResetScanTelemetry()
            end
            if self.Data and self.Data.ResetCatalogDiagnostics then
                self.Data:ResetCatalogDiagnostics()
            end
            self:RequestRefresh("perf")
            self:Print("Performance, sync, scan, and cache counters reset.")
            return
        end
        self:Print("Usage: /rr perf [toggle, dump, reset, help]")
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
                if err then
                    self:Print("Mock sync completed: " .. scenario .. " (" .. tostring(err) .. ")")
                else
                    self:Print("Mock sync started: " .. scenario)
                end
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
        self:Print("Usage: /rr mock [status, start <" .. MOCK_SCENARIOS .. ">, stop, cleanup, reset, help]")
        return
    end

    if cmd == "dump" then
        if not self.debugMode then
            return
        end
        if self.Data then self.Data:DumpSummary() end
        return
    end

    if cmd == "version" then
        if self.Sync and self.Sync.DumpVersionStatus then
            self.Sync:DumpVersionStatus()
        else
            self:Print(string.format(
                "Recipe Registry: version=%s wire=%s channel=%s prefix=%s build=%s",
                tostring(self.ADDON_VERSION or self.DISPLAY_VERSION or "?"),
                tostring(self.WIRE_VERSION or "?"),
                tostring(self.BUILD_CHANNEL or "release"),
                tostring(self.COMM_PREFIX or self.ADDON_PREFIX or "?"),
                tostring(self.BUILD_ID or "n/a")
            ))
        end
        return
    end

    if cmd == "versions" then
        if self.Sync and self.Sync.DumpPeerVersions then
            self.Sync:DumpPeerVersions()
        else
            self:Print("Peer version diagnostics not available.")
        end
        return
    end

    if cmd == "self" or cmd == "local" or cmd == "me" then
        if self.Data and self.Data.DumpLocalSyncStatus then
            self.Data:DumpLocalSyncStatus(rest)
        end
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

    if cmd == "syncreset" then
        if not self.debugMode then
            printMainHelp(self)
            return
        end
        if self.Sync and self.Sync.ResetRuntimeQueues then
            self.Sync:ResetRuntimeQueues("slash", {
                clearDiscovery = false,
                kickoffResync = true,
                userVisible = true,
            })
        end
        return
    end

    if cmd == "sync" or cmd == "comms" then
        local syncCmd = trimInput(rest):lower()
        if self.Sync then
            if syncCmd == "" then
                self.Sync:DumpStatus("summary")
            elseif syncCmd == "debug" or syncCmd == "diag" or syncCmd == "peers" or syncCmd == "sessions" or syncCmd == "log" then
                self.Sync:DumpStatus(syncCmd)
            else
                self:Print("Usage: /rr sync [debug, diag, peers, sessions, log]")
            end
        end
        return
    end

    if cmd == "offline" or cmd == "replica" then
        if not self.debugMode then
            return
        end
        if self.Sync and self.Sync.DumpOfflineSyncStatus then
            self.Sync:DumpOfflineSyncStatus()
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
        if self.Options and self.Options.Open and self.Options:Open() then
            self:Print("Opening Recipe Registry options.")
        else
            self:Print("Options panel not available yet.")
        end
        return
    end

    if cmd == "rescan" then
        if self.Data then
            local metadataChanged = self.Data:DetectProfessions() == true
            if self.Data.MarkScanNeeded then
                self.Data:MarkScanNeeded(nil, "manual")
            else
                self.Data._scanNeeded = true
            end
            local changed = scanActiveProfessionData(self, {
                reason = "manual",
                notifyMode = "manual",
            }) or metadataChanged
            markSyncIndexDirtyAndScheduleHello(self, "manual-rescan", 0.5)
            if self.Data.HasAnyScanPending and self.Data:HasAnyScanPending() then
                self:Print("Profession rescan queued. Open or refresh a profession to complete pending scans.")
            else
                self:Print("Profession rescan completed for active profession data.")
            end
        end
        return
    end

    if cmd == "pull" then
        if self.Sync then self.Sync:StartManualSyncPull(rest, false) end
        return
    end

    if cmd == "mini" or cmd == "minimap" then
        if self.MinimapButton then self.MinimapButton:ToggleHidden() end
        return
    end

    if cmd == "clean" or cmd == "repair" then
        local mode = trimInput(rest):lower()
        local dryRun = mode == "check" or mode == "dryrun" or mode == "dry-run" or mode == "preview"
        local dataStats = self.Data and self.Data.CleanCorruptData and self.Data:CleanCorruptData({ dryRun = dryRun }) or {}
        local syncStats = self.Sync and self.Sync.CleanCorruptState and self.Sync:CleanCorruptState({ dryRun = dryRun }) or {}
        local repaired = (dataStats.repairedBlocks or 0) + (dataStats.repairedCounts or 0) + (dataStats.repairedSignatures or 0)
        self:Print(string.format(
            "%s members=%d professions=%d recipes=%d mismatches=%d repaired=%d sync=%d.",
            dryRun and "Cleanup check:" or "Cleanup complete:",
            dataStats.removedMembers or 0,
            dataStats.removedProfessions or 0,
            dataStats.removedRecipes or 0,
            dataStats.mismatchedRecipes or 0,
            repaired,
            syncStats.removed or 0
        ))
        if dataStats.lastRecipeKey then
            self:Print(string.format(
                "Last recipe removed: %s from %s %s reason=%s%s",
                tostring(dataStats.lastRecipeKey),
                tostring(dataStats.lastMemberKey or "?"),
                tostring(dataStats.lastProfession or "?"),
                tostring(dataStats.lastReason or "?"),
                dataStats.lastActualProfession and (" actual=" .. tostring(dataStats.lastActualProfession)) or ""
            ))
        end
        if dryRun then
            self:Print("Run /rr clean to apply these cleanup changes.")
        end
        return
    end

    if cmd == "help" then
        printMainHelp(self)
        return
    end

    printMainHelp(self)
end
