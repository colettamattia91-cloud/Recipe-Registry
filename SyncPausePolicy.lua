local Addon = _G.RecipeRegistry
local SyncPausePolicy = Addon:NewModule("SyncPausePolicy", "AceEvent-3.0")
Addon.SyncPausePolicy = SyncPausePolicy

local function isInSensitiveInstance()
    if type(IsInInstance) ~= "function" then
        return false
    end
    local inInstance = IsInInstance()
    return inInstance == true
end

function SyncPausePolicy:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "RefreshPauseState")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "RefreshPauseState")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshPauseState")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "RefreshPauseState")
    self._wasPaused = false
    self._wasInstance = false
    self._wasCombat = false
    self:RefreshPauseState()
end

function SyncPausePolicy:IsSensitiveSyncContext()
    return InCombatLockdown()
        or isInSensitiveInstance()
end

function SyncPausePolicy:ShouldPauseOutbound()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:ShouldPauseInboundApply()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:ShouldPauseProtocolTraffic()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:AutoResumeWhenSafe()
    self:RefreshPauseState()
end

function SyncPausePolicy:RefreshPauseState()
    local inCombat = InCombatLockdown()
    local inInstance = isInSensitiveInstance()
    local paused = inCombat or inInstance
    if Addon.Performance then
        if paused then
            Addon.Performance:PauseCategory("sync-outbound")
            Addon.Performance:PauseCategory("sync-inbound")
            Addon.Performance:PauseCategory("sync-manifest")
            Addon.Performance:PauseCategory("bootstrap")
            Addon.Performance:PauseCategory("maintenance")
            Addon.Performance:PauseCategory("ui")
        else
            Addon.Performance:ResumeCategory("sync-outbound")
            Addon.Performance:ResumeCategory("sync-inbound")
            Addon.Performance:ResumeCategory("sync-manifest")
            Addon.Performance:ResumeCategory("bootstrap")
            Addon.Performance:ResumeCategory("maintenance")
            Addon.Performance:ResumeCategory("ui")
        end
    end
    if self._wasPaused and not paused and Addon.Sync and Addon.Sync.EnterWarmup then
        if self._wasInstance then
            Addon.Sync:EnterWarmup("instance-exit", 15)
        elseif self._wasCombat then
            Addon.Sync:EnterWarmup("combat-exit", 6)
        end
    end
    if Addon.Sync and Addon.Sync.RecordPauseCycle then
        Addon.Sync:RecordPauseCycle(paused)
    end
    self._wasPaused = paused
    self._wasInstance = inInstance
    self._wasCombat = inCombat
    Addon:RequestRefresh("sync-pause")
end
