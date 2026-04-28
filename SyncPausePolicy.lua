local Addon = _G.RecipeRegistry
local SyncPausePolicy = Addon:NewModule("SyncPausePolicy", "AceEvent-3.0")
Addon.SyncPausePolicy = SyncPausePolicy

local function isInInstance()
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
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "RefreshPauseState")
    self:RegisterEvent("RAID_ROSTER_UPDATE", "RefreshPauseState")
    self:RefreshPauseState()
end

function SyncPausePolicy:IsSensitiveSyncContext()
    return InCombatLockdown()
        or IsInRaid()
        or isInInstance()
end

function SyncPausePolicy:ShouldPauseOutbound()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:ShouldPauseInboundApply()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:AutoResumeWhenSafe()
    self:RefreshPauseState()
end

function SyncPausePolicy:RefreshPauseState()
    local paused = self:IsSensitiveSyncContext()
    if Addon.Performance then
        if paused then
            Addon.Performance:PauseCategory("sync-outbound")
            Addon.Performance:PauseCategory("sync-inbound")
            Addon.Performance:PauseCategory("bootstrap")
        else
            Addon.Performance:ResumeCategory("sync-outbound")
            Addon.Performance:ResumeCategory("sync-inbound")
            Addon.Performance:ResumeCategory("bootstrap")
        end
    end
    if Addon.Sync and Addon.Sync.RecordPauseCycle then
        Addon.Sync:RecordPauseCycle(paused)
    end
    Addon:RequestRefresh("sync-pause")
end
