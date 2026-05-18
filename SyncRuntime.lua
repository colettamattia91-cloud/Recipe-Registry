local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local pairs = pairs
local sort = table.sort
local max = math.max
local min = math.min
local remove = table.remove
local random = math.random

local countKeys = Private.countKeys
local isMockKey = Private.isMockKey
local newSyncTelemetry = Private.newSyncTelemetry
local compareSemver = Addon.BuildInfo and Addon.BuildInfo.CompareSemver or nil

local NODE_TIMEOUT = Constants.NODE_TIMEOUT
local HELLO_INTERVAL = Constants.HELLO_INTERVAL
local AUTO_SYNC_INTERVAL = Constants.AUTO_SYNC_INTERVAL
local PEER_BACKOFF_SECONDS = Constants.PEER_BACKOFF_SECONDS or 45
local POST_WORLD_GRACE_SECONDS = Constants.POST_WORLD_GRACE_SECONDS or 12
local POST_INSTANCE_GRACE_SECONDS = Constants.POST_INSTANCE_GRACE_SECONDS or 15
local POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = Constants.POST_RELOAD_IN_INSTANCE_GRACE_SECONDS or 30
local RECENT_SYNC_EVENTS_LIMIT = Constants.RECENT_SYNC_EVENTS_LIMIT or 50

local LIFECYCLE_DEBUG_LIMIT = 20
local VERSION_NOTICE_COOLDOWN = 12 * 60 * 60
local DISCOVERY_RETRY_INITIAL_SECONDS = Constants.DISCOVERY_RETRY_INITIAL_SECONDS or 20
local DISCOVERY_RETRY_STEP_SECONDS = Constants.DISCOVERY_RETRY_STEP_SECONDS or 20
local DISCOVERY_RETRY_MAX_SECONDS = Constants.DISCOVERY_RETRY_MAX_SECONDS or 300

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

local function cloneTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function isDiscoveryReason(reason)
    local text = tostring(reason or "")
    return text:find("^discovery%-") ~= nil
end

local function shouldResetDiscoveryRetry(reason)
    local text = tostring(reason or "")
    if text == "" then
        return false
    end
    if text:find("^deferred:") or text:find("^retry:") or text:find("^hello%-auto") then
        return false
    end
    return not isDiscoveryReason(text)
end

local function normalizeBuildChannel(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local lowered = value:lower()
    if lowered == "dev" then
        return "dev"
    end
    if lowered == "release" or lowered == "beta" then
        return "release"
    end
    return "unsupported"
end

local function summarizeCapabilities(payload)
    local caps = {}
    local source = type(payload) == "table" and payload or {}
    local nested = type(source.capabilities) == "table" and source.capabilities or {}
    if nested.indexDiffSync ~= nil then caps.indexDiffSync = nested.indexDiffSync == true end
    if nested.blockPullSync ~= nil then caps.blockPullSync = nested.blockPullSync == true end
    if source.indexDiffSync ~= nil then caps.indexDiffSync = source.indexDiffSync == true end
    if source.blockPullSync ~= nil then caps.blockPullSync = source.blockPullSync == true end
    return caps
end

local function getDeclaredCapabilities(versionInfo, capsInfo)
    local capabilities = type(versionInfo) == "table" and type(versionInfo.capabilities) == "table" and cloneCapabilities(versionInfo.capabilities) or {}
    if next(capabilities) == nil and type(capsInfo) == "table" then
        if type(capsInfo.capabilities) == "table" then
            capabilities = cloneCapabilities(capsInfo.capabilities)
        end
        if capsInfo.indexDiffSync ~= nil then capabilities.indexDiffSync = capsInfo.indexDiffSync == true end
        if capsInfo.blockPullSync ~= nil then capabilities.blockPullSync = capsInfo.blockPullSync == true end
    end
    return next(capabilities) ~= nil and capabilities or nil
end

local function isCompatiblePurpose(purpose)
    return purpose == "dispatch"
        or purpose == "serve"
        or purpose == "summary"
        or purpose == "index-diff"
        or purpose == "block-pull"
        or purpose == "hello"
end

function Sync:OnInitialize()
    self.onlineNodes = {}
    self.peerCaps = {}
    self.peerVersions = {}
    self.peerBackoffUntil = {}
    self.peerHealth = {}
    self.pendingRequests = {}
    self.inFlightRequests = {}
    self.inFlight = nil
    self.outgoingSessions = {}
    self.partialReceive = {}
    self.inboundSeedSessions = {}
    self.lifecycleDebugLog = {}
    self.offlineDebugLog = {}
    self.recentSyncEvents = {}
    self.helloCycleCounter = 0
    self.activeHelloCycle = nil
    self.lastSelectedSeed = nil
    self.outboundSeedSession = nil
    self._seedSessionCounter = 0
    self.lastHelloAt = 0
    self.warmupUntil = 0
    self.warmupReason = nil
    self.worldTransitionUntil = 0
    self.worldTransitionReason = nil
    self.savedVariablesReady = self._savedVariablesReadyBootstrap == true
    self.playerReady = false
    self.rosterPreflightReady = false
    self.rosterPreflightReason = "not-ready"
    self.indexReady = false
    self.indexStatus = "missing"
    self.syncReady = false
    self.lastSyncReadyChangeAt = 0
    self.lastSyncReadyReason = "boot"
    self.lastSyncNotReadyReason = "saved-variables"
    self.discoveryRetryDelay = DISCOVERY_RETRY_INITIAL_SECONDS
    self.discoveryRetryMisses = 0
    self.lastDiscoveryRetryReason = nil
    self.telemetry = newSyncTelemetry()
end

function Sync:ResetTelemetry()
    self.telemetry = newSyncTelemetry()
    self.lifecycleDebugLog = {}
    self.offlineDebugLog = {}
    self.recentSyncEvents = {}
end

function Sync:ResetRuntimeQueues(reason, opts)
    opts = opts or {}
    if opts.clearDiscovery then
        self.onlineNodes = {}
        self.peerCaps = {}
        self.peerVersions = {}
        self.peerBackoffUntil = {}
        self.peerHealth = {}
        self.lastHelloAt = 0
    end
    self.pendingRequests = {}
    self.inFlightRequests = {}
    self.inFlight = nil
    self.outgoingSessions = {}
    self.partialReceive = {}
    self.inboundSeedSessions = {}
    self.activeHelloCycle = nil
    self.lastSelectedSeed = nil
    self.outboundSeedSession = nil
    self.helloCycleCounter = 0
    self._seedSessionCounter = 0
    self.warmupUntil = 0
    self.warmupReason = nil
    self.worldTransitionUntil = 0
    self.worldTransitionReason = nil
    self:ResetDiscoveryRetry("runtime-reset")
    if self._helloCycleTimer then
        self:CancelTimer(self._helloCycleTimer, true)
        self._helloCycleTimer = nil
    end
    if self._helloTimer then
        self:CancelTimer(self._helloTimer, true)
        self._helloTimer = nil
    end
    if self._queuePumpTimer then
        self:CancelTimer(self._queuePumpTimer, true)
        self._queuePumpTimer = nil
    end
    if self._warmupTimer then
        self:CancelTimer(self._warmupTimer, true)
        self._warmupTimer = nil
    end
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer, true)
        self._transitionTimer = nil
    end
    if opts.kickoffResync then
        self:KickoffDatabaseResync()
    end
    self:RefreshSyncReadyState(reason or "runtime-reset")
    Addon:RequestRefresh("queue")
    if opts.userVisible then
        Addon:Print("Sync runtime reset. Saved recipes were kept and a fresh hello cycle was scheduled.")
    else
        Addon:SystemPrint("Sync runtime reset: " .. tostring(reason or "manual"))
    end
end

function Sync:PushLifecycleEvent(kind, detail)
    local stamp = date and date("%H:%M:%S") or tostring(time())
    local line = string.format("%s %s %s", tostring(stamp), tostring(kind or "event"), tostring(detail or ""))
    self.lifecycleDebugLog = self.lifecycleDebugLog or {}
    self.lifecycleDebugLog[#self.lifecycleDebugLog + 1] = line
    while #self.lifecycleDebugLog > LIFECYCLE_DEBUG_LIMIT do
        remove(self.lifecycleDebugLog, 1)
    end
end

function Sync:RecordSyncEvent(event, fields)
    local row = {
        t = time(),
        event = tostring(event or "event"),
    }
    if type(fields) == "table" then
        if fields.reason ~= nil then row.reason = tostring(fields.reason) end
        if fields.peer ~= nil then row.peer = tostring(fields.peer) end
        if fields.requestId ~= nil then row.requestId = tostring(fields.requestId) end
        if fields.blockKey ~= nil then row.blockKey = tostring(fields.blockKey) end
        if fields.extra ~= nil then row.extra = tostring(fields.extra) end
    end
    self.recentSyncEvents = self.recentSyncEvents or {}
    self.recentSyncEvents[#self.recentSyncEvents + 1] = row
    while #self.recentSyncEvents > RECENT_SYNC_EVENTS_LIMIT do
        remove(self.recentSyncEvents, 1)
    end
    self:PushLifecycleEvent(row.event, row.reason or row.extra or "")
    return row
end

function Sync:GetRecentSyncEvents(limit)
    local rows = {}
    local source = self.recentSyncEvents or {}
    local maxRows = tonumber(limit or #source) or #source
    if maxRows < 0 then
        maxRows = 0
    end
    local startIndex = max(1, #source - maxRows + 1)
    for index = startIndex, #source do
        local row = source[index]
        rows[#rows + 1] = {
            t = row.t,
            event = row.event,
            reason = row.reason,
            peer = row.peer,
            requestId = row.requestId,
            blockKey = row.blockKey,
            extra = row.extra,
        }
    end
    return rows
end

function Sync:PushOfflineDebugEvent(kind, detail)
    local stamp = date and date("%H:%M:%S") or tostring(time())
    local line = string.format("%s %s %s", tostring(stamp), tostring(kind or "event"), tostring(detail or ""))
    self.offlineDebugLog[#self.offlineDebugLog + 1] = line
    while #self.offlineDebugLog > 12 do
        remove(self.offlineDebugLog, 1)
    end
end

function Sync:ResetRuntimeStateForDatabaseWipe()
    self:ResetRuntimeQueues("database-wipe", {
        clearDiscovery = true,
        kickoffResync = false,
        userVisible = false,
    })
end

function Sync:SetSavedVariablesReady(reason)
    if not self.telemetry then
        self.telemetry = newSyncTelemetry()
    end
    self.savedVariablesReady = true
    self.lastSavedVariablesReadyReason = tostring(reason or "saved-variables")
    self.telemetry.savedVariablesReadyAt = time()
    self:RecordSyncEvent("savedVariablesReady", {
        reason = self.lastSavedVariablesReadyReason,
    })
    return self:RefreshSyncReadyState("saved-variables-ready")
end

function Sync:SetPlayerReady(reason)
    if not self.telemetry then
        self.telemetry = newSyncTelemetry()
    end
    self.playerReady = true
    self.lastPlayerReadyReason = tostring(reason or "player-login")
    self.telemetry.playerReadyAt = time()
    self:RecordSyncEvent("playerReady", {
        reason = self.lastPlayerReadyReason,
    })
    return self:RefreshSyncReadyState("player-ready")
end

function Sync:ResetDiscoveryRetry(reason)
    if not self.telemetry then
        self.telemetry = newSyncTelemetry()
    end
    self.discoveryRetryDelay = DISCOVERY_RETRY_INITIAL_SECONDS
    self.discoveryRetryMisses = 0
    self.lastDiscoveryRetryReason = tostring(reason or "reset")
    self.telemetry.discoveryRetryReset = (self.telemetry.discoveryRetryReset or 0) + 1
    self.telemetry.discoveryRetryMisses = 0
    self.telemetry.discoveryRetryDelay = self.discoveryRetryDelay
    self.telemetry.discoveryRetryNextAt = 0
    self.telemetry.lastDiscoveryRetryReason = self.lastDiscoveryRetryReason
    return true
end

function Sync:HasActiveOutboundSeedSession()
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    local state = tostring(session.state or "")
    return state ~= "" and state ~= "completed" and state ~= "aborted"
end

function Sync:GetNextDiscoveryRetryDelay()
    local delay = tonumber(self.discoveryRetryDelay or DISCOVERY_RETRY_INITIAL_SECONDS) or DISCOVERY_RETRY_INITIAL_SECONDS
    if delay < DISCOVERY_RETRY_INITIAL_SECONDS then
        delay = DISCOVERY_RETRY_INITIAL_SECONDS
    end
    if delay > DISCOVERY_RETRY_MAX_SECONDS then
        delay = DISCOVERY_RETRY_MAX_SECONDS
    end
    return delay
end

function Sync:ScheduleDiscoveryRetry(reason)
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        return false, "outbound-session-active"
    end
    if self._helloTimer then
        return false, "hello-already-scheduled"
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("HELLO") then
        return false, "paused"
    end
    self:RefreshSyncReadyState(reason or "discovery-retry")
    if self.syncReady ~= true then
        return false, self.lastSyncNotReadyReason or "not-ready"
    end

    local delay = self:GetNextDiscoveryRetryDelay()
    self.discoveryRetryMisses = (self.discoveryRetryMisses or 0) + 1
    self.discoveryRetryDelay = min(DISCOVERY_RETRY_MAX_SECONDS, delay + DISCOVERY_RETRY_STEP_SECONDS)
    if delay >= DISCOVERY_RETRY_MAX_SECONDS then
        self.telemetry.discoveryRetryCapHits = (self.telemetry.discoveryRetryCapHits or 0) + 1
    end
    self.telemetry.discoveryRetryScheduled = (self.telemetry.discoveryRetryScheduled or 0) + 1
    self.telemetry.discoveryRetryMisses = self.discoveryRetryMisses
    self.telemetry.discoveryRetryDelay = delay
    self.telemetry.lastDiscoveryRetryDelay = delay
    self.telemetry.lastDiscoveryRetryReason = tostring(reason or "discovery-retry")
    local scheduled = self:ScheduleHello(
        tostring(reason or "discovery-retry"),
        delay + (random() * (Constants.HELLO_RESCHEDULE_JITTER_SECONDS or 0))
    )
    self.telemetry.discoveryRetryNextAt = self._helloScheduledFor or 0
    self:RecordSyncEvent("discoveryRetryScheduled", {
        reason = tostring(reason or "discovery-retry"),
        extra = string.format("misses=%d delay=%d", self.discoveryRetryMisses or 0, delay),
    })
    return scheduled
end

function Sync:RefreshSyncReadyState(reason)
    if not self.telemetry then
        self.telemetry = newSyncTelemetry()
    end
    local previousRosterReady = self.rosterPreflightReady == true
    local previousRosterReason = self.rosterPreflightReason
    local previousIndexReady = self.indexReady == true
    local previousIndexStatus = self.indexStatus
    local sessionActive = self:HasActiveOutboundSeedSession()
    local rosterState = Addon.Data and Addon.Data.GetRosterTrustState and Addon.Data:GetRosterTrustState() or nil
    self.rosterPreflightReady = type(rosterState) == "table" and rosterState.trusted == true or false
    self.rosterPreflightReason = type(rosterState) == "table" and tostring(rosterState.reason or "unknown") or "unavailable"
    if self.rosterPreflightReady then
        self.telemetry.rosterPreflightReadyAt = time()
    end

    local indexState = Addon.Data and Addon.Data.GetSyncIndexReadiness and Addon.Data:GetSyncIndexReadiness({
        reason = reason or "sync-ready",
        schedule = not sessionActive,
        delay = 0.5,
    }) or nil
    self.indexReady = type(indexState) == "table" and indexState.ready == true or false
    self.indexStatus = type(indexState) == "table" and tostring(indexState.indexStatus or "unknown") or "missing"
    if self.indexReady then
        self.telemetry.indexReadyAt = time()
    end
    if previousRosterReady ~= self.rosterPreflightReady or previousRosterReason ~= self.rosterPreflightReason then
        self:RecordSyncEvent(self.rosterPreflightReady and "rosterPreflightReady" or "rosterPreflightNotReady", {
            reason = self.rosterPreflightReason,
        })
    end
    if previousIndexReady ~= self.indexReady or previousIndexStatus ~= self.indexStatus then
        local indexEvent = self.indexReady and "indexReady"
            or (self.indexStatus == "dirty" and "indexDirty" or "indexNotReady")
        self:RecordSyncEvent(indexEvent, {
            reason = self.indexStatus,
        })
    end

    local paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("HELLO") or false
    local saturationThreshold = Constants.SUMMARY_SATURATION_THRESHOLD or 80
    local saturated = self:EstimateRuntimeQueuePressure() >= saturationThreshold
    local worldReady = not self:IsInWarmup() and not self:IsInWorldTransition()
    self.indexUsableForActivePull = sessionActive
        and self.savedVariablesReady == true
        and self.playerReady == true
        and worldReady
        and self.rosterPreflightReady == true
        and self.indexStatus == "dirty"
        and not paused
        and not saturated
    local nextReady = self.savedVariablesReady == true
        and self.playerReady == true
        and worldReady
        and self.rosterPreflightReady == true
        and self.indexReady == true
        and not paused
        and not saturated

    local previous = self.syncReady == true
    self.syncReady = nextReady == true
    self.lastSyncReadyChangeAt = time()
    self.lastSyncReadyReason = tostring(reason or "sync-ready")

    if self.syncReady then
        self.lastSyncNotReadyReason = nil
        if not previous then
            self:ResetDiscoveryRetry("sync-ready")
            self:ScheduleHello("sync-ready")
            self:RecordSyncEvent("syncReady", {
                reason = self.lastSyncReadyReason,
                extra = "true",
            })
        end
    else
        if self.savedVariablesReady ~= true then
            self.lastSyncNotReadyReason = "saved-variables"
        elseif self.playerReady ~= true then
            self.lastSyncNotReadyReason = "player"
        elseif not worldReady then
            self.lastSyncNotReadyReason = self:IsInWorldTransition() and "world-transition" or "warmup"
        elseif self.rosterPreflightReady ~= true then
            self.lastSyncNotReadyReason = self.rosterPreflightReason or "roster-unready"
        elseif self.indexReady ~= true then
            self.lastSyncNotReadyReason = self.indexStatus or "index-not-ready"
        elseif paused then
            self.lastSyncNotReadyReason = "paused"
        else
            self.lastSyncNotReadyReason = "runtime-saturated"
        end
        self.telemetry.lastReadinessGateFailure = self.lastSyncNotReadyReason
        if previous or self.telemetry.lastSyncNotReadyReason ~= self.lastSyncNotReadyReason then
            self:RecordSyncEvent("syncReady", {
                reason = self.lastSyncNotReadyReason,
                extra = "false",
            })
        end
    end

    self.telemetry.syncReadyTransitions = (self.telemetry.syncReadyTransitions or 0) + (previous ~= self.syncReady and 1 or 0)
    self.telemetry.lastSyncReadyState = self.syncReady == true and "ready" or "not-ready"
    self.telemetry.lastSyncReady = self.syncReady == true
    self.telemetry.lastSyncReadyReason = self.syncReady == true and self.lastSyncReadyReason or self.lastSyncNotReadyReason
    self.telemetry.lastSyncNotReadyReason = self.lastSyncNotReadyReason
    return self.syncReady, self.syncReady and "ready" or self.lastSyncNotReadyReason
end

function Sync:IsSyncReady()
    return self.syncReady == true
end

function Sync:CanAdvanceOutboundPullSession()
    return self.indexUsableForActivePull == true and self:HasActiveOutboundSeedSession()
end

-- Inbound serving (BLOCK_SNAPSHOT, INDEX_DIFF_RESPONSE, CanServeInboundSeed)
-- must stay alive while our own globalFingerprint is being recomputed. The
-- cached block data + live DB are valid even when indexStatus="dirty" (e.g.,
-- after a roster eligibility change or after we just merged a block). Refusing
-- to serve in that brief window stalls peers with block-response-timeout and
-- breaks the architecture's promise of concurrent seeders.
function Sync:CanServeCachedBlocks()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_SNAPSHOT") then
        return false, "paused"
    end
    if self.savedVariablesReady ~= true then
        return false, "saved-variables"
    end
    if self.playerReady ~= true then
        return false, "player"
    end
    if self:IsInWarmup() then
        return false, "warmup"
    end
    if self:IsInWorldTransition() then
        return false, "world-transition"
    end
    if self.rosterPreflightReady ~= true then
        return false, self.rosterPreflightReason or "roster-unready"
    end
    if self.indexStatus ~= "ready" and self.indexStatus ~= "dirty" then
        return false, self.indexStatus or "index-not-ready"
    end
    if self:EstimateRuntimeQueuePressure() >= 95 then
        return false, "saturated"
    end
    return true, "serving-allowed"
end

function Sync:CanRunSyncProtocol(kind)
    self:RefreshSyncReadyState("protocol:" .. tostring(kind or "sync"))
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(kind) then
        return false, "paused"
    end
    if self.syncReady ~= true then
        if kind == "BLOCK_PULL_REQUEST" and self:CanAdvanceOutboundPullSession() then
            return true, "active-pull-dirty-index"
        end
        if kind == "BLOCK_SNAPSHOT" or kind == "INDEX_DIFF_RESPONSE" then
            local allowed, servingReason = self:CanServeCachedBlocks()
            if allowed then
                return true, "serving-cached-blocks"
            end
            return false, servingReason or self.lastSyncNotReadyReason or "not-ready"
        end
        return false, self.lastSyncNotReadyReason or "not-ready"
    end
    return true, "ready"
end

function Sync:KickoffDatabaseResync()
    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty("database-resync", nil, {
            full = true,
        })
    end
    if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
        Addon.Data:ScheduleSyncIndexPrepare("database-resync", 0.5)
    end
    self:ResetDiscoveryRetry("database-resync")
    self:RefreshSyncReadyState("database-resync")
    self:ScheduleHello("database-resync")
end

function Sync:GetLocalVersionInfo()
    if Addon.BuildInfo and Addon.BuildInfo.GetLocalVersionInfo then
        return Addon.BuildInfo.GetLocalVersionInfo()
    end
    return {
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        minSupportedWireVersion = Addon.MIN_SUPPORTED_WIRE_VERSION or Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL or "release",
        buildId = Addon.BUILD_ID,
        commPrefix = Addon.COMM_PREFIX or Addon.ADDON_PREFIX,
        capabilities = cloneCapabilities(Addon.CAPABILITIES),
    }
end

function Sync:ComputePeerCompatibility(peer)
    if type(peer) ~= "table" then
        return "unknown"
    end

    local localInfo = self:GetLocalVersionInfo()
    local remoteChannel = normalizeBuildChannel(peer.buildChannel)
    if localInfo.buildChannel == "dev" then
        if remoteChannel ~= "dev" then
            return "channel-mismatch"
        end
    else
        if remoteChannel == "dev" or remoteChannel == "unsupported" then
            return "channel-mismatch"
        end
        if not remoteChannel then
            return "channel-mismatch"
        end
        if remoteChannel ~= localInfo.buildChannel then
            return "channel-mismatch"
        end
    end

    local wireVersion = tonumber(peer.wireVersion or 0) or 0
    if wireVersion <= 0 then
        return "remote-older-wire"
    end
    if wireVersion > (localInfo.wireVersion or Addon.WIRE_VERSION or 0) then
        return "remote-newer-wire"
    end
    if wireVersion < (localInfo.minSupportedWireVersion or Addon.MIN_SUPPORTED_WIRE_VERSION or Addon.WIRE_VERSION or 0) then
        return "remote-older-wire"
    end
    return "compatible"
end

function Sync:IsInboundBuildChannelAllowed(payload, _sender)
    local localInfo = self:GetLocalVersionInfo()
    local remoteChannel = normalizeBuildChannel(payload and payload.buildChannel)

    if localInfo.buildChannel == "dev" then
        if remoteChannel == "dev" then
            return true, "allowed", remoteChannel
        end
        return false, remoteChannel and "channel-mismatch" or "missing-build-channel", remoteChannel or "unknown"
    end

    if remoteChannel == "dev" or remoteChannel == "unsupported" then
        return false, "channel-mismatch", remoteChannel
    end
    if not remoteChannel then
        return false, "missing-build-channel", "unknown"
    end
    if remoteChannel ~= localInfo.buildChannel then
        return false, "channel-mismatch", remoteChannel
    end
    return true, "allowed", remoteChannel
end

function Sync:RegisterBuildChannelDrop(peerKey, payload, reason, remoteChannel)
    self.telemetry.buildChannelDrops = (self.telemetry.buildChannelDrops or 0) + 1
    self.telemetry.ignoredBuildChannelPeers = (self.telemetry.ignoredBuildChannelPeers or 0) + 1
    self.telemetry.lastBuildChannelDropPeer = tostring(peerKey or payload and payload.sender or "unknown")
    self.telemetry.lastBuildChannelDropRemote = tostring(remoteChannel or payload and payload.buildChannel or "unknown")
    self.telemetry.lastBuildChannelDropReason = tostring(reason or "channel-mismatch")
end

function Sync:ObservePeerVersion(peerKey, payload)
    if not self:IsValidSyncMemberKey(peerKey) then
        return nil
    end

    local caps = type(payload) == "table" and payload.caps or nil
    local existing = self.peerVersions and self.peerVersions[peerKey] or nil
    local info = {
        peerKey = peerKey,
        addonVersion = type(payload) == "table" and (payload.addonVersion or payload.version) or nil,
        wireVersion = type(payload) == "table" and (payload.wireVersion or (type(caps) == "table" and caps.wireVersion or nil)) or nil,
        buildChannel = type(payload) == "table" and (payload.buildChannel or (type(caps) == "table" and caps.buildChannel or nil)) or nil,
        buildId = type(payload) == "table" and (payload.buildId or (type(caps) == "table" and caps.buildId or nil)) or nil,
        capabilities = summarizeCapabilities(type(caps) == "table" and caps or payload),
        firstSeenAt = existing and existing.firstSeenAt or time(),
        lastSeenAt = time(),
    }

    info.addonVersion = info.addonVersion or existing and existing.addonVersion or "unknown"
    info.wireVersion = tonumber(info.wireVersion or existing and existing.wireVersion or 0) or 0
    info.buildChannel = normalizeBuildChannel(info.buildChannel or existing and existing.buildChannel) or "unknown"
    info.buildId = info.buildId or existing and existing.buildId or nil
    if next(info.capabilities) == nil and existing and type(existing.capabilities) == "table" then
        info.capabilities = cloneCapabilities(existing.capabilities)
    end
    info.compatibility = self:ComputePeerCompatibility(info)
    info.ineligibleReason = existing and existing.ineligibleReason or nil

    self.peerVersions = self.peerVersions or {}
    self.peerVersions[peerKey] = info
    return info
end

function Sync:GetPeerVersionInfo(peerKey)
    return self.peerVersions and self.peerVersions[peerKey] or nil
end

function Sync:GetPeerVersionRelation(peerKey)
    local info = self:GetPeerVersionInfo(peerKey)
    if not info or not compareSemver then
        return "unknown"
    end
    local cmp = compareSemver(info.addonVersion, Addon.ADDON_VERSION or Addon.DISPLAY_VERSION)
    if cmp == nil then
        return "unknown"
    end
    if cmp > 0 then
        return "newer-remote"
    end
    if cmp < 0 then
        return "newer-local"
    end
    return "same-version"
end

function Sync:SetPeerIneligibleReason(peerKey, reason)
    if not self:IsValidSyncMemberKey(peerKey) then
        return
    end
    self.peerVersions = self.peerVersions or {}
    local info = self.peerVersions[peerKey]
    if info then
        info.ineligibleReason = reason
    end
end

function Sync:RecordLatestRemoteVersion(remoteVersion)
    if not remoteVersion or not compareSemver then
        return
    end
    if compareSemver(remoteVersion, remoteVersion) == nil then
        return
    end
    local notice = Addon.Data and Addon.Data.GetUpdateNoticeState and Addon.Data:GetUpdateNoticeState() or nil
    if not notice then
        return
    end
    local current = notice.latestRemoteVersionSeen
    local isNewer = current == nil or compareSemver(remoteVersion, current) == 1
    if isNewer then
        notice.latestRemoteVersionSeen = remoteVersion
    end
    self.telemetry.latestRemoteVersionSeen = tostring(notice.latestRemoteVersionSeen or remoteVersion)
end

function Sync:ShouldAcceptInboundPayload(payload, peerKey)
    local info = peerKey and self:GetPeerVersionInfo(peerKey) or nil
    if type(info) ~= "table" then
        if not (type(payload) == "table" and type(payload.kind) == "string") then
            return false
        end
        if payload.kind == "HELLO" then
            return true
        end
        local cycle = self.activeHelloCycle
        if payload.kind == "SUMMARY"
            and type(cycle) == "table"
            and payload.helloId
            and cycle.helloId
            and payload.helloId == cycle.helloId
        then
            return true
        end
        local session = self.outboundSeedSession
        if type(session) == "table" and payload.sender == session.seedKey then
            if payload.kind == "INDEX_DIFF_RESPONSE" and session.state == "waiting-index-diff" then
                return true
            end
            if payload.kind == "BLOCK_SNAPSHOT" and session.state == "waiting-block" then
                return true
            end
        end
        return false
    end
    local compatibility = info.compatibility or self:ComputePeerCompatibility(info)
    if compatibility == "remote-newer-wire" or compatibility == "remote-older-wire" then
        return false
    end
    return compatibility ~= "channel-mismatch"
end

function Sync:MaybeNotifyPeerVersion(peerKey, info)
    info = info or self:GetPeerVersionInfo(peerKey)
    if type(info) ~= "table" then
        return
    end
    local notice = Addon.Data and Addon.Data.GetUpdateNoticeState and Addon.Data:GetUpdateNoticeState() or nil
    if not notice then
        return
    end
    local localChannel = tostring(Addon.BUILD_CHANNEL or "release")
    local remoteChannel = tostring(info.buildChannel or "unknown")
    if localChannel == "dev" then
        if remoteChannel ~= "dev" then
            return
        end
    else
        if remoteChannel == "dev" or remoteChannel == "unsupported" or remoteChannel == "unknown" then
            return
        end
    end
    if not compareSemver then
        return
    end

    self:RecordLatestRemoteVersion(info.addonVersion)

    local now = time()
    if info.compatibility == "remote-newer-wire" then
        local wireCmp = compareSemver(tostring(info.wireVersion or ""), tostring(notice.lastNoticedWireVersion or ""))
        local isStrictlyNewerWire = notice.lastNoticedWireVersion == nil or wireCmp == 1
        if isStrictlyNewerWire or (now - (notice.lastProtocolNoticeAt or 0)) >= VERSION_NOTICE_COOLDOWN then
            Addon:Print(string.format(
                "Recipe Registry: newer sync protocol detected from %s. Local wire=%s remote wire=%s.",
                tostring(peerKey),
                tostring(Addon.WIRE_VERSION or "?"),
                tostring(info.wireVersion or "?")
            ))
            notice.lastProtocolNoticeAt = now
            notice.lastNoticedWireVersion = info.wireVersion
            self.telemetry.lastVersionNoticePeer = peerKey
            self.telemetry.lastVersionNoticeRemote = tostring(info.wireVersion or "unknown")
            self.telemetry.newerProtocolSeen = (self.telemetry.newerProtocolSeen or 0) + 1
        end
        return
    end

    local cmp = compareSemver(info.addonVersion, Addon.ADDON_VERSION or Addon.DISPLAY_VERSION)
    if cmp == nil or cmp <= 0 then
        return
    end
    local sameVersionCooldown = tostring(notice.lastNoticedVersion or "") == tostring(info.addonVersion or "")
        and (now - (notice.lastUpdateNoticeAt or 0)) < VERSION_NOTICE_COOLDOWN
    if sameVersionCooldown then
        return
    end

    Addon:Print(string.format(
        "Recipe Registry: a newer version was detected from %s (%s).",
        tostring(peerKey),
        tostring(info.addonVersion or "unknown")
    ))
    notice.lastNoticedVersion = info.addonVersion
    notice.lastUpdateNoticeAt = now
    notice.lastNoticedPeer = peerKey
    self.telemetry.lastVersionNoticePeer = peerKey
    self.telemetry.lastVersionNoticeRemote = tostring(info.addonVersion or "unknown")
    self.telemetry.newerVersionSeen = (self.telemetry.newerVersionSeen or 0) + 1
end

function Sync:ShouldAllowLocalMockTraffic(sourceKey, memberKey)
    return Addon.MockSync
        and Addon.MockSync.IsLocalTrafficEnabled
        and Addon.MockSync:IsLocalTrafficEnabled(sourceKey, memberKey)
        or false
end

function Sync:MarkPeerSuccess(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then
        return
    end
    self.peerHealth = self.peerHealth or {}
    self.peerBackoffUntil = self.peerBackoffUntil or {}
    local health = self.peerHealth[sourceKey] or {
        successes = 0,
        failures = 0,
        consecutiveFailures = 0,
        lastSuccessAt = 0,
        lastFailureAt = 0,
    }
    health.successes = (health.successes or 0) + 1
    health.consecutiveFailures = 0
    health.lastSuccessAt = time()
    self.peerHealth[sourceKey] = health
    self.peerBackoffUntil[sourceKey] = nil
    self.lastSnapshotSuccessAt = time()
end

function Sync:CanExchangeDataWithPeer(peerKey, purpose, request)
    purpose = tostring(purpose or "dispatch")
    request = request or {}
    if not self:IsValidSyncMemberKey(peerKey) then
        return false, "invalid-peer"
    end
    if self:IsMockKey(peerKey) and not self:ShouldAllowLocalMockTraffic(peerKey, request.memberKey or peerKey) then
        return false, "mock-peer"
    end

    local peerVersion = self:GetPeerVersionInfo(peerKey)
    if type(peerVersion) ~= "table" then
        self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
        self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
        return false, "unknown-peer"
    end

    local compatibility = peerVersion.compatibility or self:ComputePeerCompatibility(peerVersion)
    if compatibility == "channel-mismatch" then
        self:SetPeerIneligibleReason(peerKey, "channel-mismatch")
        self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
        self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
        return false, "channel-mismatch"
    end
    if compatibility == "remote-newer-wire" or compatibility == "remote-older-wire" then
        self:SetPeerIneligibleReason(peerKey, compatibility)
        self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
        self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
        return false, "wire-mismatch"
    end

    if isCompatiblePurpose(purpose) then
        local caps = self.GetPeerCaps and self:GetPeerCaps(peerKey) or nil
        local declared = getDeclaredCapabilities(peerVersion, caps)
        if declared then
            if declared.indexDiffSync ~= true or declared.blockPullSync ~= true then
                self:SetPeerIneligibleReason(peerKey, "missing-required-capability")
                self.telemetry.skippedMissingCapability = (self.telemetry.skippedMissingCapability or 0) + 1
                return false, "missing-required-capability"
            end
        else
            self.telemetry.assumedModernCapabilities = (self.telemetry.assumedModernCapabilities or 0) + 1
            self.telemetry.assumedModernCapabilityPeer = peerKey
            self.telemetry.assumedModernCapabilityPurpose = purpose
        end

        if type(caps) == "table" then
            if caps.isPausedForSync == true then
                self:SetPeerIneligibleReason(peerKey, "peer-paused")
                return false, "peer-paused"
            end
            if purpose == "dispatch" or purpose == "index-diff" or purpose == "block-pull" then
                if caps.canReceiveBlockPull == false then
                    self:SetPeerIneligibleReason(peerKey, "peer-cannot-receive-block-pull")
                    return false, "peer-cannot-receive-block-pull"
                end
            end
            if purpose == "serve" and caps.canSendBlockSnapshot == false then
                self:SetPeerIneligibleReason(peerKey, "peer-cannot-send-block-snapshot")
                return false, "peer-cannot-send-block-snapshot"
            end
        end
    end

    self:SetPeerIneligibleReason(peerKey, nil)
    return true, "eligible"
end

function Sync:GetPeerEligibilityBreakdown()
    local eligible = 0
    local ineligible = 0

    for peerKey in pairs(self.onlineNodes or {}) do
        if self:IsValidSyncMemberKey(peerKey) and peerKey ~= self:GetSelfKey() then
            local peerEligible = self:CanExchangeDataWithPeer(peerKey, "dispatch", {
                source = peerKey,
                memberKey = peerKey,
            })
            if peerEligible then
                eligible = eligible + 1
            else
                ineligible = ineligible + 1
            end
        end
    end

    return {
        eligible = eligible,
        ineligible = ineligible,
    }
end

local function applyRosterSnapshotOutcome(self, outcome)
    outcome = type(outcome) == "table" and outcome or {}
    local telemetry = self.telemetry or {}

    telemetry.rosterKnownOwnersChecked = (telemetry.rosterKnownOwnersChecked or 0) + (outcome.knownOwnersChecked or 0)
    telemetry.rosterUnknownMembersIgnored = (telemetry.rosterUnknownMembersIgnored or 0) + (outcome.unknownMembersIgnored or 0)

    if not outcome.knownOwnerEligibilityChanged then
        return false
    end

    local dirtied = false
    if outcome.fullDirty and Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty("known-owner-eligibility-change", nil, {
            full = true,
        })
        dirtied = true
    else
        dirtied = #((outcome and outcome.affectedBlockKeys) or {}) > 0
    end

    if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
        Addon.Data:ScheduleSyncIndexPrepare("known-owner-eligibility-change", 0.5)
    end
    if dirtied then
        self:ResetDiscoveryRetry("known-owner-eligibility-change")
        self:ScheduleHello("known-owner-eligibility-change")
    end
    return dirtied
end

-- Bootstrap the roster preflight if it was never requested. This handles the
-- common race where PLAYER_ENTERING_WORLD fires with IsInGuild()==false (guild
-- data not yet loaded), Core.lua bails out, and no RequestRosterSnapshot is
-- ever issued. Without this, the sync stays stuck forever even though the
-- guild becomes available a few frames later. Returns true if a fresh request
-- was issued (caller may then reconsult IsRosterSnapshotPending).
function Sync:EnsureRosterPreflightRequested(reason, opts)
    opts = type(opts) == "table" and opts or {}
    local data = Addon.Data
    if not (data and data.GetRosterPreflightState and data.RequestRosterSnapshot) then
        return false, "data-unavailable"
    end
    local inGuild = type(IsInGuild) == "function" and IsInGuild() == true or false
    if not inGuild then
        return false, "not-in-guild"
    end
    local state = data:GetRosterPreflightState() or {}
    if state.trusted == true then
        return false, "already-trusted"
    end
    if state.pending == true then
        return false, "already-pending"
    end
    local ok, status = data:RequestRosterSnapshot("auto-bootstrap:" .. tostring(reason or "unknown"), {
        force = false,
        cooldown = tonumber(opts.cooldown or 0) or 0,
        source = opts.source or "auto-bootstrap",
    })
    Addon:Tracef("sync",
        "roster-preflight-bootstrap reason=%s issued=%s status=%s",
        tostring(reason or "unknown"),
        tostring(ok == true),
        tostring(status or "n/a")
    )
    return ok == true, status
end

function Sync:OnRosterPreflightWatchdog(reason)
    local rosterPending = Addon.Data and Addon.Data.IsRosterSnapshotPending and Addon.Data:IsRosterSnapshotPending() or false

    if not rosterPending then
        local bootstrapped = self:EnsureRosterPreflightRequested(reason or "login-watchdog")
        if bootstrapped then
            rosterPending = Addon.Data.IsRosterSnapshotPending and Addon.Data:IsRosterSnapshotPending() or false
        end
    end
    if not rosterPending then
        return false, "not-pending"
    end

    local ok, status, outcome = Addon.Data:ProcessPendingRosterSnapshot(reason or "login-watchdog", {
        allowFallback = true,
        source = "watchdog",
    })
    if not ok then
        return false, status or "failed"
    end

    applyRosterSnapshotOutcome(self, outcome)
    self:RefreshSyncReadyState(reason or "login-watchdog")
    return true, status or "processed"
end

function Sync:OnGuildRosterUpdate(context)
    context = type(context) == "table" and context or {}
    local reason = tostring(context.reason or "roster-update")
    local telemetry = self.telemetry or {}
    local rosterPending = Addon.Data and Addon.Data.IsRosterSnapshotPending and Addon.Data:IsRosterSnapshotPending() or false

    if not rosterPending then
        -- Try to bootstrap if the preflight was never requested. This is the
        -- recovery path for the IsInGuild()==false race at PLAYER_ENTERING_WORLD.
        local bootstrapped = self:EnsureRosterPreflightRequested(reason)
        if bootstrapped and Addon.Data.IsRosterSnapshotPending then
            rosterPending = Addon.Data:IsRosterSnapshotPending()
        end
    end

    if not rosterPending then
        -- Pure noop: roster already trusted or we're not in guild. Bump counters
        -- but do NOT emit a per-event trace — GUILD_ROSTER_UPDATE fires often
        -- and floods the log with no actionable signal.
        telemetry.rosterSyncNoopUpdates = (telemetry.rosterSyncNoopUpdates or 0) + 1
        telemetry.rosterUpdateIgnoredForSync = (telemetry.rosterUpdateIgnoredForSync or 0) + 1
        return false
    end

    local ok, status, outcome = Addon.Data:ProcessPendingRosterSnapshot(reason, {
        allowFallback = false,
        source = "event",
    })
    if not ok then
        if status == "not-usable" then
            telemetry.rosterUpdateIgnoredForSync = (telemetry.rosterUpdateIgnoredForSync or 0) + 1
        end
        Addon:Tracef("sync",
            "roster-update-process-failed reason=%s status=%s",
            tostring(reason),
            tostring(status or "unknown")
        )
        return false
    end

    telemetry.rosterSyncRelevantUpdates = (telemetry.rosterSyncRelevantUpdates or 0) + 1
    telemetry.lastRosterSyncRelevantReason = outcome and outcome.reason or reason
    applyRosterSnapshotOutcome(self, outcome)
    self:RefreshSyncReadyState(reason)
    return true
end

function Sync:GetInFlightRequests()
    self.inFlightRequests = self.inFlightRequests or {}
    return self.inFlightRequests
end

function Sync:RefreshPrimaryInFlight()
    self.inFlight = nil
    return nil
end

function Sync:GetInFlightRequest(memberKey)
    if not memberKey then
        return nil
    end
    return self:GetInFlightRequests()[memberKey]
end

function Sync:GetActiveRequestCount()
    return 0
end

function Sync:GetMaxConcurrentRequests()
    return Constants.MAX_CONCURRENT_REQUESTS or 1
end

function Sync:SetInFlightRequest(_request)
    return nil
end

function Sync:ClearInFlightRequest(memberKey)
    if memberKey then
        self:GetInFlightRequests()[memberKey] = nil
    end
    self.inFlight = nil
    return nil
end

function Sync:GetPendingHelloReason()
    local reasons = {}
    for reason in pairs(self._pendingHelloReasons or {}) do
        reasons[#reasons + 1] = tostring(reason)
    end
    if #reasons == 0 then
        return "hello"
    end
    sort(reasons)
    return table.concat(reasons, ",")
end

function Sync:ClearPendingHello(reason)
    self._pendingHelloReasons = {}
    self._pendingHelloCycleReason = nil
    self.lastHelloScheduleReason = nil
    self.lastHelloScheduleClearedAt = time()
    self.lastHelloScheduleClearReason = tostring(reason or "sent")
end

function Sync:ShouldDeferHelloBroadcast()
    local ready, readyReason = self:CanRunSyncProtocol("HELLO")
    if not ready then
        return true, readyReason or "not-ready"
    end
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        return true, "outbound-session-active"
    end
    return false, "ready"
end

function Sync:ScheduleHello(reason, delay)
    local helloReason = tostring(reason or "hello")
    if shouldResetDiscoveryRetry(helloReason) then
        self:ResetDiscoveryRetry(helloReason)
    end
    self._pendingHelloReasons = self._pendingHelloReasons or {}
    self._pendingHelloReasons[helloReason] = true
    self._pendingHelloCycleReason = self:GetPendingHelloReason()
    self.lastHelloScheduleReason = self._pendingHelloCycleReason
    self.lastHelloScheduledAt = time()
    self.telemetry.helloScheduled = (self.telemetry.helloScheduled or 0) + 1

    if self._helloTimer then
        self.telemetry.coalescedHelloSchedules = (self.telemetry.coalescedHelloSchedules or 0) + 1
        self.telemetry.helloScheduleCoalesced = (self.telemetry.helloScheduleCoalesced or 0) + 1
        self.telemetry.lastHelloScheduledReason = self.lastHelloScheduleReason
        return true
    end

    local nextDelay = tonumber(delay)
    if nextDelay == nil then
        nextDelay = Constants.HELLO_RESCHEDULE_DELAY_SECONDS or 5
        local jitterWindow = tonumber(Constants.HELLO_RESCHEDULE_JITTER_SECONDS or 0) or 0
        if jitterWindow > 0 then
            nextDelay = nextDelay + (random() * jitterWindow)
        end
    end
    if (self.lastHelloAt or 0) > 0 then
        local cooldown = tonumber(Constants.POST_SYNC_HELLO_COOLDOWN_SECONDS or 0) or 0
        local remaining = max(0, cooldown - max(0, time() - (self.lastHelloAt or 0)))
        if remaining > nextDelay then
            nextDelay = remaining
        end
    end

    self._helloScheduledFor = time() + max(0, nextDelay)
    self.telemetry.lastHelloScheduledReason = self.lastHelloScheduleReason
    self.telemetry.lastHelloScheduledDelay = nextDelay
    self.telemetry.lastHelloDueAt = self._helloScheduledFor
    self:RecordSyncEvent("helloScheduled", {
        reason = self.lastHelloScheduleReason,
        extra = string.format("delay=%.1f", nextDelay),
    })
    self._helloTimer = self:ScheduleTimer(function()
        self._helloTimer = nil
        self._helloScheduledFor = nil
        local deferSend, deferReason = self:ShouldDeferHelloBroadcast()
        if deferSend then
            self.telemetry.deferredHelloSchedules = (self.telemetry.deferredHelloSchedules or 0) + 1
            self.telemetry.helloDeferredReason = tostring(deferReason or "unknown")
            if deferReason == "paused" then
                self.telemetry.helloDeferredPaused = (self.telemetry.helloDeferredPaused or 0) + 1
            elseif deferReason == "outbound-session-active" then
                self.telemetry.helloDeferredOutboundActive = (self.telemetry.helloDeferredOutboundActive or 0) + 1
            else
                self.telemetry.helloDeferredNotReady = (self.telemetry.helloDeferredNotReady or 0) + 1
            end
            self:RecordSyncEvent("helloDeferred", {
                reason = deferReason,
            })
            self:ScheduleHello("deferred:" .. tostring(deferReason or "unknown"))
            return
        end
        local sent = self:BroadcastHello()
        if sent then
            self:ClearPendingHello("sent")
        else
            self:ScheduleHello("retry:hello-send-failed")
        end
    end, max(0, nextDelay))
    return true
end

function Sync:BeginHelloCycle(reason)
    self.helloCycleCounter = (self.helloCycleCounter or 0) + 1
    local helloId = string.format("%s:%d:%d", tostring(self:GetSelfKey() or "unknown"), tonumber(time() or 0) or 0, self.helloCycleCounter)
    if self._helloCycleTimer then
        self:CancelTimer(self._helloCycleTimer, true)
        self._helloCycleTimer = nil
    end
    self.activeHelloCycle = {
        cycleId = self.helloCycleCounter,
        helloId = helloId,
        reason = tostring(reason or self._pendingHelloCycleReason or "hello"),
        startedAt = time(),
        summaries = {},
        selectedSeedKey = nil,
        selectedSeed = nil,
        selectionCompletedAt = 0,
        closesAt = time() + (Constants.SUMMARY_COLLECTION_WINDOW or 0),
    }
    self.telemetry.summaryWindowOpened = (self.telemetry.summaryWindowOpened or 0) + 1
    self:RecordSyncEvent("summaryWindowOpened", {
        reason = tostring(reason or self._pendingHelloCycleReason or "hello"),
        requestId = helloId,
    })
    return self.activeHelloCycle
end

function Sync:IsSummarySaturated()
    local pressure = self:EstimateRuntimeQueuePressure()
    return pressure >= (Constants.SUMMARY_SATURATION_THRESHOLD or 80)
end

function Sync:RecordSummary(peerKey, payload)
    if not self:IsValidSyncMemberKey(peerKey) then
        return false
    end
    local cycle = self.activeHelloCycle
    if type(cycle) ~= "table" then
        return false
    end
    if payload.helloId and cycle.helloId and payload.helloId ~= cycle.helloId then
        return false
    end
    cycle.summaries[peerKey] = {
        peerKey = peerKey,
        helloId = payload.helloId,
        activeOwnerCount = tonumber(payload.activeOwnerCount or 0) or 0,
        activeBlockCount = tonumber(payload.activeBlockCount or 0) or 0,
        activeContentCount = tonumber(payload.activeContentCount or 0) or 0,
        globalFingerprint = payload.globalFingerprint,
        receivedAt = time(),
    }
    local localSummary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "summary-received",
        allowDeferred = true,
    }) or nil
    if type(localSummary) == "table"
        and tostring(localSummary.indexStatus or "") == "ready"
        and tostring(payload.globalFingerprint or "") ~= tostring(localSummary.globalFingerprint or "")
    then
        self:ResetDiscoveryRetry("useful-summary")
    end
    self.telemetry.summaryReceived = (self.telemetry.summaryReceived or 0) + 1
    self.telemetry.lastSummaryCount = countKeys(cycle.summaries)
    self:RecordSyncEvent("summaryReceived", {
        peer = peerKey,
        requestId = payload.helloId,
        extra = string.format("count=%d", self.telemetry.lastSummaryCount or 0),
    })
    Addon:Tracef("sync",
        "summary-received peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
        tostring(peerKey),
        tostring(payload.helloId or "none"),
        tonumber(payload.activeOwnerCount or 0) or 0,
        tonumber(payload.activeBlockCount or 0) or 0,
        tonumber(payload.activeContentCount or 0) or 0,
        tostring(payload.globalFingerprint or "none")
    )
    return true
end

function Sync:SelectOutboundSeed(cycleId)
    local cycle = self.activeHelloCycle
    if type(cycle) ~= "table" then
        return nil
    end
    if cycleId and cycle.cycleId ~= cycleId then
        return nil
    end
    if cycle.selectedSeedKey then
        return cycle.selectedSeedKey
    end

    local localSummary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "seed-selection",
        allowDeferred = true,
    }) or nil
    local rows = {}
    local rejectReasons = {}
    local candidateCount = 0
    for peerKey, summary in pairs(cycle.summaries or {}) do
        if self:IsValidSyncMemberKey(peerKey) and type(summary) == "table" then
            candidateCount = candidateCount + 1
            local rejectReason = nil
            if tostring(summary.globalFingerprint or "") == tostring(localSummary and localSummary.globalFingerprint or "") then
                rejectReason = "same-global-fingerprint"
            else
                local eligible, eligibleReason = self:CanExchangeDataWithPeer(peerKey, "dispatch", {
                    source = peerKey,
                    memberKey = peerKey,
                })
                if eligible then
                    rows[#rows + 1] = summary
                else
                    rejectReason = tostring(eligibleReason or "ineligible")
                end
            end
            if rejectReason then
                rejectReasons[rejectReason] = (rejectReasons[rejectReason] or 0) + 1
            end
        end
    end
    self.telemetry.seedCandidatesSeen = (self.telemetry.seedCandidatesSeen or 0) + candidateCount
    self.telemetry.seedCandidatesRejected = (self.telemetry.seedCandidatesRejected or 0) + (candidateCount - #rows)
    self.telemetry.lastSeedCandidateCount = candidateCount
    local rejectParts = {}
    for rejectReason, count in pairs(rejectReasons) do
        rejectParts[#rejectParts + 1] = string.format("%s=%d", tostring(rejectReason), tonumber(count or 0) or 0)
    end
    sort(rejectParts)
    self.telemetry.lastSeedRejectReasons = #rejectParts > 0 and table.concat(rejectParts, ",") or "none"

    table.sort(rows, function(left, right)
        if (left.activeContentCount or 0) ~= (right.activeContentCount or 0) then
            return (left.activeContentCount or 0) > (right.activeContentCount or 0)
        end
        if (left.activeBlockCount or 0) ~= (right.activeBlockCount or 0) then
            return (left.activeBlockCount or 0) > (right.activeBlockCount or 0)
        end
        if (left.activeOwnerCount or 0) ~= (right.activeOwnerCount or 0) then
            return (left.activeOwnerCount or 0) > (right.activeOwnerCount or 0)
        end
        local leftBackoff = self:IsPeerBackoffActive(left.peerKey) and 1 or 0
        local rightBackoff = self:IsPeerBackoffActive(right.peerKey) and 1 or 0
        if leftBackoff ~= rightBackoff then
            return leftBackoff < rightBackoff
        end
        return tostring(left.peerKey or "") < tostring(right.peerKey or "")
    end)

    cycle.selectionCompletedAt = time()
    self.telemetry.summaryWindowClosed = (self.telemetry.summaryWindowClosed or 0) + 1
    self.telemetry.lastSummaryWindowCloseAt = cycle.selectionCompletedAt
    self.telemetry.lastSummaryCount = countKeys(cycle.summaries or {})
    self:RecordSyncEvent("summaryWindowClosed", {
        requestId = cycle.helloId,
        extra = string.format("received=%d candidates=%d", self.telemetry.lastSummaryCount or 0, candidateCount),
    })
    if #rows == 0 then
        self.telemetry.discoveryMisses = (self.telemetry.discoveryMisses or 0) + 1
        self.telemetry.lastNoSeedReason = candidateCount == 0 and "no-summary" or "no-useful-seed"
        self.telemetry.lastNoSummaryAt = time()
        Addon:Tracef("sync",
            "seed-selection-none helloId=%s reason=no-different-ready-summary",
            tostring(cycle.helloId or "none")
        )
        self:RecordSyncEvent("noSeed", {
            reason = self.telemetry.lastNoSeedReason,
            requestId = cycle.helloId,
            extra = self.telemetry.lastSeedRejectReasons,
        })
        self:ScheduleDiscoveryRetry("discovery-miss")
        return nil
    end

    local selected = rows[1]
    self:ResetDiscoveryRetry("seed-selected")
    cycle.selectedSeedKey = selected.peerKey
    cycle.selectedSeed = selected
    self.lastSelectedSeed = cloneTable(selected)
    self.telemetry.seedSelected = (self.telemetry.seedSelected or 0) + 1
    self.telemetry.lastSelectedPeer = selected.peerKey
    self.telemetry.lastSelectedReason = "highest-content"
    self:RecordSyncEvent("seedSelected", {
        peer = selected.peerKey,
        requestId = cycle.helloId,
        reason = "highest-content",
    })
    Addon:Tracef("sync",
        "seed-selected peer=%s reason=highest-content owners=%d blocks=%d content=%d",
        tostring(selected.peerKey),
        tonumber(selected.activeOwnerCount or 0) or 0,
        tonumber(selected.activeBlockCount or 0) or 0,
        tonumber(selected.activeContentCount or 0) or 0
    )

    self._seedSessionCounter = (self._seedSessionCounter or 0) + 1
    self.outboundSeedSession = {
        sessionId = string.format("%s:%d:%d", tostring(self:GetSelfKey() or "unknown"), tonumber(time() or 0) or 0, self._seedSessionCounter),
        seedKey = selected.peerKey,
        cycleId = cycle.cycleId,
        helloId = cycle.helloId,
        state = "seed-selected",
        startedAt = time(),
        lastProgressAt = time(),
        wantedBlocks = {},
        offeredBlocks = {},
        nextWantedIndex = 1,
    }
    self:ScheduleQueuePump(0)
    return selected.peerKey
end

function Sync:AbortOutboundSeedSession(reason)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.nextBlockTimer then
        self:CancelTimer(session.nextBlockTimer, true)
        session.nextBlockTimer = nil
    end
    session.state = "aborted"
    session.abortReason = tostring(reason or "aborted")
    session.abortedAt = time()
    session.lastProgressAt = session.abortedAt
    if Addon.Data and Addon.Data.RefreshGlobalFingerprint then
        if (session.successfulBlockMerges or 0) > 0 then
            Addon.Data:RefreshGlobalFingerprint("seed-session-abort:" .. session.abortReason)
        elseif Addon.Data.IsSyncIndexDirty and Addon.Data:IsSyncIndexDirty() then
            Addon.Data:RefreshGlobalFingerprint("seed-session-abort-local-dirty:" .. session.abortReason)
        end
    end
    self.telemetry.outboundSessionAborted = (self.telemetry.outboundSessionAborted or 0) + 1
    self.telemetry.lastAbortReason = session.abortReason
    self.telemetry.successfulBlockMerges = session.successfulBlockMerges or 0
    Addon:Tracef("sync",
        "session-abort peer=%s reason=%s",
        tostring(session.seedKey or "unknown"),
        tostring(session.abortReason)
    )
    if (session.successfulBlockMerges or 0) > 0 then
        self:ResetDiscoveryRetry("seed-session-abort-partial")
    else
        self:ResetDiscoveryRetry("seed-session-abort-retry")
    end
    self:RefreshSyncReadyState(session.abortReason)
    self:ScheduleHello((session.successfulBlockMerges or 0) > 0 and "seed-session-abort-partial" or "seed-session-abort-retry")
    self:RecordSyncEvent("outboundSessionAborted", {
        peer = session.seedKey,
        reason = session.abortReason,
        requestId = session.diffRequestId,
        blockKey = session.activeBlockKey,
    })
    return true
end

function Sync:CompleteOutboundSeedSession(reason)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.nextBlockTimer then
        self:CancelTimer(session.nextBlockTimer, true)
        session.nextBlockTimer = nil
    end
    session.state = "completed"
    session.completedAt = time()
    session.lastProgressAt = session.completedAt
    session.completedReason = tostring(reason or "complete")
    if Addon.Data and Addon.Data.RefreshGlobalFingerprint and (session.successfulBlockMerges or 0) > 0 then
        Addon.Data:RefreshGlobalFingerprint("seed-session-complete:" .. session.completedReason)
    end
    self.telemetry.outboundSessionCompleted = (self.telemetry.outboundSessionCompleted or 0) + 1
    self.telemetry.lastSessionCompleteReason = session.completedReason
    self.telemetry.successfulBlockMerges = session.successfulBlockMerges or 0
    Addon:Tracef("sync",
        "session-complete peer=%s reason=%s",
        tostring(session.seedKey or "unknown"),
        tostring(session.completedReason)
    )
    if (session.successfulBlockMerges or 0) > 0 then
        self:ResetDiscoveryRetry("seed-session-complete")
        self:RefreshSyncReadyState(session.completedReason)
        self:ScheduleHello("seed-session-complete")
    end
    self:RecordSyncEvent("outboundSessionCompleted", {
        peer = session.seedKey,
        reason = session.completedReason,
        requestId = session.diffRequestId,
    })
    return true
end

function Sync:GetInboundSeedSessionCount()
    local total = 0
    for _, sessions in pairs(self.inboundSeedSessions or {}) do
        total = total + countKeys(sessions)
    end
    return total
end

function Sync:PruneInboundSeedSessions()
    local timeout = Constants.SESSION_TIMEOUT or 60
    for requesterKey, sessions in pairs(self.inboundSeedSessions or {}) do
        for requestId, session in pairs(sessions or {}) do
            local lastActivity = tonumber(session and session.lastActivity or session and session.createdAt or 0) or 0
            if lastActivity > 0 and (time() - lastActivity) > timeout then
                sessions[requestId] = nil
            end
        end
        if next(sessions or {}) == nil then
            self.inboundSeedSessions[requesterKey] = nil
        end
    end
    self.telemetry.inboundSeedSessionsActive = self:GetInboundSeedSessionCount()
end

function Sync:ClearInboundSeedSessions(reason)
    local cleared = self:GetInboundSeedSessionCount()
    self.inboundSeedSessions = {}
    self.telemetry.inboundSeedSessionsActive = 0
    if cleared > 0 then
        self.telemetry.inboundSeedSessionsCleared = (self.telemetry.inboundSeedSessionsCleared or 0) + cleared
        if tostring(reason or ""):find("pause", 1, true) then
            self.telemetry.inboundSeedSessionsClearedPause = (self.telemetry.inboundSeedSessionsClearedPause or 0) + cleared
        end
        Addon:Tracef("sync",
            "inbound-seed-sessions-cleared reason=%s cleared=%d",
            tostring(reason or "unspecified"),
            cleared
        )
        self:RecordSyncEvent("inboundSeedSessionCleared", {
            reason = reason,
            extra = string.format("cleared=%d", cleared),
        })
    end
    return cleared
end

function Sync:RegisterInboundSeedSession(requesterKey, requestId, offeredBlocks)
    if not self:IsValidSyncMemberKey(requesterKey) or type(requestId) ~= "string" or requestId == "" then
        return nil, "invalid"
    end

    self:PruneInboundSeedSessions()
    local existingSessions = self.inboundSeedSessions[requesterKey] or {}
    local existing = existingSessions[requestId]
    if not existing then
        local peerCap = Constants.MAX_INBOUND_SEED_SESSIONS_PER_PEER or 1
        if countKeys(existingSessions) >= peerCap and peerCap > 0 then
            self.telemetry.inboundSeedSessionsRejected = (self.telemetry.inboundSeedSessionsRejected or 0) + 1
            self.telemetry.inboundSeedSessionsRejectedCap = (self.telemetry.inboundSeedSessionsRejectedCap or 0) + 1
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = requesterKey,
                requestId = requestId,
                reason = "per-requester-cap",
            })
            return nil, "per-requester-cap"
        end
        local globalCap = Constants.MAX_INBOUND_SEED_SESSIONS or 4
        if self:GetInboundSeedSessionCount() >= globalCap and globalCap > 0 then
            self.telemetry.inboundSeedSessionsRejected = (self.telemetry.inboundSeedSessionsRejected or 0) + 1
            self.telemetry.inboundSeedSessionsRejectedCap = (self.telemetry.inboundSeedSessionsRejectedCap or 0) + 1
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = requesterKey,
                requestId = requestId,
                reason = "global-cap",
            })
            return nil, "global-cap"
        end
    end

    local offeredBlockSet = {}
    for index = 1, #(offeredBlocks or {}) do
        local row = offeredBlocks[index]
        if type(row) == "table" and type(row.blockKey) == "string" and row.blockKey ~= "" then
            offeredBlockSet[row.blockKey] = true
        end
    end

    local session = existing or {
        requesterKey = requesterKey,
        requestId = requestId,
        servedBlocks = 0,
        createdAt = time(),
        state = "ready",
    }
    session.offeredBlocks = offeredBlockSet
    session.offeredBlockCount = countKeys(offeredBlockSet)
    session.lastActivity = time()
    session.state = "ready"
    existingSessions[requestId] = session
    self.inboundSeedSessions[requesterKey] = existingSessions
    self.telemetry.inboundSeedSessionsActive = self:GetInboundSeedSessionCount()
    self.telemetry.inboundSeedSessionsMax = Constants.MAX_INBOUND_SEED_SESSIONS or 4
    self.telemetry.lastInboundRequester = requesterKey
    self.telemetry.lastInboundRequestId = requestId
    self:RecordSyncEvent("inboundSeedSessionOpened", {
        peer = requesterKey,
        requestId = requestId,
        extra = string.format("offered=%d", session.offeredBlockCount or 0),
    })
    return session, "ready"
end

function Sync:GetInboundSeedSession(requesterKey)
    if not self:IsValidSyncMemberKey(requesterKey) then
        return nil
    end
    self:PruneInboundSeedSessions()
    local sessions = self.inboundSeedSessions and self.inboundSeedSessions[requesterKey] or nil
    local newest = nil
    for _, session in pairs(sessions or {}) do
        if newest == nil or (session.lastActivity or 0) > (newest.lastActivity or 0) then
            newest = session
        end
    end
    return newest
end

function Sync:CanServeInboundSeed(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then
        return false, "invalid-peer"
    end
    self:PruneInboundSeedSessions()
    local eligible = self:CanExchangeDataWithPeer(peerKey, "serve", {
        source = peerKey,
        memberKey = peerKey,
    })
    if not eligible then
        return false, "ineligible"
    end
    local allowed, reason = self:CanServeCachedBlocks()
    if not allowed then
        if reason == "paused" then
            self.telemetry.inboundSeedSessionsRejectedPaused = (self.telemetry.inboundSeedSessionsRejectedPaused or 0) + 1
        elseif reason == "saturated" then
            -- counter recorded via event below
        else
            self.telemetry.inboundSeedSessionsRejectedNotReady = (self.telemetry.inboundSeedSessionsRejectedNotReady or 0) + 1
        end
        self:RecordSyncEvent("inboundSeedSessionRejected", {
            peer = peerKey,
            reason = reason or self.lastSyncNotReadyReason or "not-ready",
        })
        return false, reason or self.lastSyncNotReadyReason or "not-ready"
    end
    return true, "ready"
end

function Sync:ScheduleQueuePump(delay)
    if self._queuePumpTimer then
        return
    end
    self._queuePumpTimer = self:ScheduleTimer(function()
        self._queuePumpTimer = nil
        self:ProcessRequestQueue()
    end, delay or 0.05)
end

function Sync:EnterWarmup(reason, seconds)
    self.warmupReason = tostring(reason or "warmup")
    self.warmupUntil = time() + max(0, tonumber(seconds or POST_WORLD_GRACE_SECONDS) or POST_WORLD_GRACE_SECONDS)
    self:ClearInboundSeedSessions("warmup")
    self:RecordSyncEvent("warmupEnter", {
        reason = self.warmupReason,
    })
    self:RefreshSyncReadyState(self.warmupReason)
    if self._warmupTimer then
        self:CancelTimer(self._warmupTimer, true)
    end
    self._warmupTimer = self:ScheduleTimer(function()
        self._warmupTimer = nil
        if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
            Addon.Data:ScheduleSyncIndexPrepare("warmup-recovery", 0.5)
        end
        self:RefreshSyncReadyState("warmup-recovery")
        self:ScheduleHello("warmup-recovery")
        self:RecordSyncEvent("warmupExit", {
            reason = "warmup-recovery",
        })
    end, max(0, self.warmupUntil - time()))
end

function Sync:IsInWarmup()
    return (self.warmupUntil or 0) > time()
end

function Sync:GetWarmupRemaining()
    if not self:IsInWarmup() then
        return 0
    end
    return max(0, (self.warmupUntil or 0) - time())
end

function Sync:EnterWorldTransition(reason, seconds)
    self.worldTransitionReason = tostring(reason or "transition")
    self.worldTransitionUntil = time() + max(0, tonumber(seconds or POST_WORLD_GRACE_SECONDS) or POST_WORLD_GRACE_SECONDS)
    self:ClearInboundSeedSessions("world-transition")
    self:RecordSyncEvent("worldTransitionEnter", {
        reason = self.worldTransitionReason,
    })
    self:RefreshSyncReadyState(self.worldTransitionReason)
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer, true)
    end
    self._transitionTimer = self:ScheduleTimer(function()
        self._transitionTimer = nil
        if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
            Addon.Data:ScheduleSyncIndexPrepare("world-transition-recovery", 0.5)
        end
        self:RefreshSyncReadyState("world-transition-recovery")
        self:ScheduleHello("world-transition-recovery")
        self:RecordSyncEvent("worldTransitionExit", {
            reason = "world-transition-recovery",
        })
    end, max(0, self.worldTransitionUntil - time()))
end

function Sync:IsInWorldTransition()
    return (self.worldTransitionUntil or 0) > time()
end

function Sync:GetWorldTransitionRemaining()
    if not self:IsInWorldTransition() then
        return 0
    end
    return max(0, (self.worldTransitionUntil or 0) - time())
end

function Sync:EstimateRuntimeQueuePressure()
    if not self.telemetry then
        self.telemetry = newSyncTelemetry()
    end
    local pressure = 0
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        pressure = pressure + 25
        if session.state == "waiting-block" or session.state == "waiting-index-diff" then
            pressure = pressure + 25
        end
    end
    if self:IsInWarmup() then
        pressure = pressure + 10
    end
    if self:IsInWorldTransition() then
        pressure = pressure + 20
    end
    self.telemetry.runtimeQueuePressure = min(100, pressure)
    return self.telemetry.runtimeQueuePressure
end

function Sync:ShouldDeferHeavyLifecycleWork(_reason)
    if self:IsInWarmup() then
        return true
    end
    if self:IsInWorldTransition() then
        return true
    end
    return self:EstimateRuntimeQueuePressure() >= 70
end

function Sync:IsPeerBackoffActive(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then
        return false
    end
    local untilAt = self.peerBackoffUntil and self.peerBackoffUntil[sourceKey] or nil
    if not untilAt then
        return false
    end
    if untilAt <= time() then
        self.peerBackoffUntil[sourceKey] = nil
        return false
    end
    return true
end

function Sync:TouchNode(key, version)
    if not self:IsValidSyncMemberKey(key) then
        return
    end
    self.onlineNodes[key] = self.onlineNodes[key] or {}
    self.onlineNodes[key].lastSeen = time()
    self.onlineNodes[key].version = version or self.onlineNodes[key].version

    local selfKey = self:GetSelfKey()
    self.onlineNodes[selfKey] = self.onlineNodes[selfKey] or { version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION }
    self.onlineNodes[selfKey].lastSeen = time()
end

function Sync:PruneOnlineNodes()
    local now = time()
    for key, info in pairs(self.onlineNodes or {}) do
        if info.lastSeen and (now - info.lastSeen) > NODE_TIMEOUT then
            self.onlineNodes[key] = nil
            self.peerBackoffUntil[key] = nil
            self.peerVersions[key] = nil
            self.peerCaps[key] = nil
            self.peerHealth[key] = nil
        end
    end
end

function Sync:PruneState()
    self:PruneOnlineNodes()
    self:EstimateRuntimeQueuePressure()
end

function Sync:AutoSyncTick()
    if type(IsInGuild) == "function" and not IsInGuild() then
        return
    end
    self:RefreshSyncReadyState("auto-sync")
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("HELLO") then
        self.telemetry.pausedSyncCycles = (self.telemetry.pausedSyncCycles or 0) + 1
        return
    end
    if self.syncReady ~= true then
        return
    end
    if self._helloTimer or self:HasActiveOutboundSeedSession() then
        return
    end
    local cycle = self.activeHelloCycle
    if type(cycle) == "table" and (cycle.selectionCompletedAt or 0) <= 0 then
        return
    end

    local sinceLastHello = time() - (self.lastHelloAt or 0)
    if (self.discoveryRetryMisses or 0) > 0 then
        if sinceLastHello >= self:GetNextDiscoveryRetryDelay() then
            self:ScheduleDiscoveryRetry("hello-auto-watchdog")
        end
        return
    end

    if countKeys(self.onlineNodes) == 0 then
        if sinceLastHello >= HELLO_INTERVAL then
            self:ScheduleHello("hello-auto-empty")
        end
        return
    end
    if sinceLastHello >= HELLO_INTERVAL then
        self:ScheduleHello("hello-auto-interval")
    end
end

function Sync:EnsureBackgroundWorkers()
    self._workersReady = true
end
