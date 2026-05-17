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

local function isInCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true or false
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
    return isInCombat() or isInSensitiveInstance()
end

function SyncPausePolicy:GetProtocolPauseReason(kind)
    kind = tostring(kind or "")
    if isInSensitiveInstance() then
        return "PAUSED_INSTANCE"
    end
    return nil
end

function SyncPausePolicy:ShouldPauseOutbound(kind)
    return self:GetProtocolPauseReason(kind) ~= nil
end

function SyncPausePolicy:ShouldPauseInboundApply()
    return isInSensitiveInstance()
end

function SyncPausePolicy:ShouldPauseProtocolTraffic(kind)
    return self:GetProtocolPauseReason(kind) ~= nil
end

function SyncPausePolicy:ShouldPauseHeavyUI()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:ShouldPauseTooltipRebuild()
    return self:IsSensitiveSyncContext()
end

function SyncPausePolicy:AutoResumeWhenSafe()
    self:RefreshPauseState()
end

function SyncPausePolicy:RefreshPauseState()
    local inCombat = isInCombat()
    local inInstance = isInSensitiveInstance()
    local protocolPaused = inInstance
    local heavyUiPaused = inCombat or inInstance
    if Addon.Performance then
        if protocolPaused then
            Addon.Performance:PauseCategory("sync-outbound")
            Addon.Performance:PauseCategory("sync-inbound")
            Addon.Performance:PauseCategory("sync-runtime")
            Addon.Performance:PauseCategory("bootstrap")
            Addon.Performance:PauseCategory("maintenance")
        else
            Addon.Performance:ResumeCategory("sync-outbound")
            Addon.Performance:ResumeCategory("sync-inbound")
            Addon.Performance:ResumeCategory("sync-runtime")
            Addon.Performance:ResumeCategory("bootstrap")
            Addon.Performance:ResumeCategory("maintenance")
        end
        if heavyUiPaused then
            Addon.Performance:PauseCategory("ui")
        else
            Addon.Performance:ResumeCategory("ui")
        end
    end
    if protocolPaused and Addon.Sync and Addon.Sync.ClearInboundSeedSessions then
        Addon.Sync:ClearInboundSeedSessions(inInstance and "instance-pause" or "protocol-pause")
    end
    if protocolPaused and Addon.Sync and Addon.Sync.AbortOutboundSeedSession then
        local session = Addon.Sync.outboundSeedSession
        if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
            Addon.Sync:AbortOutboundSeedSession(inInstance and "instance-pause" or "protocol-pause")
        end
    end
    if self._wasPaused and not heavyUiPaused and Addon.Sync and Addon.Sync.EnterWarmup then
        if self._wasInstance then
            Addon.Sync:EnterWarmup("instance-exit", 15)
        elseif self._wasCombat then
            Addon.Sync:EnterWarmup("combat-exit", 6)
        end
    end
    if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
        if protocolPaused then
            Addon.Data:ScheduleSyncIndexPrepare(inInstance and "instance-pause" or "protocol-pause", 1)
        elseif self._wasPaused then
            Addon.Data:ScheduleSyncIndexPrepare("pause-recovery", 0.5)
        end
    end
    if self._wasPaused and not protocolPaused and Addon.Sync and Addon.Sync.ScheduleHello then
        if Addon.Sync.RefreshSyncReadyState then
            Addon.Sync:RefreshSyncReadyState("pause-recovery")
        end
        Addon.Sync:ScheduleHello("pause-recovery")
    elseif Addon.Sync and Addon.Sync.RefreshSyncReadyState then
        Addon.Sync:RefreshSyncReadyState(protocolPaused and "paused" or "pause-state")
    end
    if Addon.Sync and Addon.Sync.RecordPauseCycle then
        Addon.Sync:RecordPauseCycle(heavyUiPaused)
    end
    self._wasPaused = heavyUiPaused
    self._wasInstance = inInstance
    self._wasCombat = inCombat
    Addon:RequestRefresh("sync-pause")
end
