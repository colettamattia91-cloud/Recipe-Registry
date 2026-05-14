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

local countKeys = Private.countKeys
local isMockKey = Private.isMockKey
local newSyncTelemetry = Private.newSyncTelemetry
local compareSemver = Addon.BuildInfo and Addon.BuildInfo.CompareSemver or nil

local NODE_TIMEOUT = Constants.NODE_TIMEOUT
local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
local MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH = Constants.MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH
local MANIFEST_CATCHUP_DRAIN_DELAY = Constants.MANIFEST_CATCHUP_DRAIN_DELAY
local MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH = Constants.MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH
local MANIFEST_REFRESH_REQUEST_COOLDOWN = Constants.MANIFEST_REFRESH_REQUEST_COOLDOWN
local OFFLINE_DEBUG_LOG_LIMIT = Constants.OFFLINE_DEBUG_LOG_LIMIT
local PEER_BACKOFF_FAILURE_THRESHOLD = Constants.PEER_BACKOFF_FAILURE_THRESHOLD
local PEER_BACKOFF_SECONDS = Constants.PEER_BACKOFF_SECONDS
local HELLO_AUTO_BACKOFF_SECONDS = Constants.HELLO_AUTO_BACKOFF_SECONDS
local POST_WORLD_GRACE_SECONDS = Constants.POST_WORLD_GRACE_SECONDS
local POST_INSTANCE_GRACE_SECONDS = Constants.POST_INSTANCE_GRACE_SECONDS
local POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = Constants.POST_RELOAD_IN_INSTANCE_GRACE_SECONDS
local HELLO_INTERVAL = Constants.HELLO_INTERVAL
local AUTO_SYNC_INTERVAL = Constants.AUTO_SYNC_INTERVAL
local COORDINATOR_RECOMPUTE_DELAY = Constants.COORDINATOR_RECOMPUTE_DELAY
local MAX_OUTBOUND_CHUNKS = Constants.MAX_OUTBOUND_CHUNKS
local MAX_MANIFEST_CHUNKS = Constants.MAX_MANIFEST_CHUNKS
local MAX_INBOUND_CHUNKS = Constants.MAX_INBOUND_CHUNKS
local MAX_INBOUND_FINALIZE_QUEUE = Constants.MAX_INBOUND_FINALIZE_QUEUE
local MAX_PARTIAL_RECEIVES = Constants.MAX_PARTIAL_RECEIVES
local MAX_PARTIAL_MANIFESTS_TOTAL = Constants.MAX_PARTIAL_MANIFESTS_TOTAL
local MAX_PARTIAL_MANIFESTS_PER_PEER = Constants.MAX_PARTIAL_MANIFESTS_PER_PEER
local MAX_MANIFEST_CATCHUP_QUEUE = Constants.MAX_MANIFEST_CATCHUP_QUEUE
local MAX_PENDING_REQUESTS = Constants.MAX_PENDING_REQUESTS

local LIFECYCLE_DEBUG_LIMIT = 20
local VERSION_NOTICE_COOLDOWN = 12 * 60 * 60

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

local function normalizeBuildChannel(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local lowered = value:lower()
    if lowered == "legacy" then
        return nil
    end
    if lowered == "dev" then
        return "dev"
    end
    if lowered == "release" or lowered == "beta" then
        return "release"
    end
    return "unsupported"
end

local MODERN_ONLY_PURPOSES = {
    ["manifest-large"] = true,
    ["manifest-recovery"] = true,
    ["post-wipe"] = true,
    ["offline-replica"] = true,
    ["catchup-offline"] = true,
    ["snapshot-replica"] = true,
    ["auto-tick-modern"] = true,
}

local MANI_RELIABLE_PURPOSES = {
    ["manifest-large"] = true,
    ["manifest-recovery"] = true,
    ["post-wipe"] = true,
}

local CHUNK_WINDOW_PURPOSES = {
    ["offline-replica"] = true,
    ["catchup-offline"] = true,
    ["snapshot-replica"] = true,
}

local function isAssumedModernCapabilityPurpose(purpose, request)
    if purpose ~= "manifest-large" then
        return false
    end
    request = request or {}
    if request.allowOfflinePeer then
        return false
    end
    local why = tostring(request.why or "")
    return why ~= "manifest-partial-timeout"
        and why ~= "request-repair"
        and why ~= "post-wipe"
        and why ~= "database-wipe"
end

local function summarizeCapabilities(payload)
    local caps = {}
    local source = type(payload) == "table" and payload or {}
    local nested = type(source.capabilities) == "table" and source.capabilities or {}
    if nested.chunkWindow ~= nil then caps.chunkWindow = nested.chunkWindow == true end
    if nested.maniReliable ~= nil then caps.maniReliable = nested.maniReliable == true end
    if nested.snapCodec ~= nil then caps.snapCodec = nested.snapCodec == true end
    if nested.manifestShards ~= nil then caps.manifestShards = nested.manifestShards == true end
    if source.chunkWindow ~= nil then caps.chunkWindow = source.chunkWindow == true end
    if source.maniReliable ~= nil then caps.maniReliable = source.maniReliable == true end
    if source.snapCodec ~= nil then caps.snapCodec = source.snapCodec == true end
    if source.manifestShards ~= nil then caps.manifestShards = source.manifestShards == true end
    return caps
end

local function getDeclaredCapabilities(versionInfo, capsInfo)
    local capabilities = type(versionInfo) == "table" and type(versionInfo.capabilities) == "table" and cloneCapabilities(versionInfo.capabilities) or {}
    if next(capabilities) == nil and type(capsInfo) == "table" then
        if type(capsInfo.capabilities) == "table" then
            capabilities = cloneCapabilities(capsInfo.capabilities)
        end
        if capsInfo.chunkWindow ~= nil then capabilities.chunkWindow = capsInfo.chunkWindow == true end
        if capsInfo.maniReliable ~= nil then capabilities.maniReliable = capsInfo.maniReliable == true end
        if capsInfo.snapCodecCap ~= nil then capabilities.snapCodec = capsInfo.snapCodecCap == true end
        if capsInfo.manifestShards ~= nil then capabilities.manifestShards = capsInfo.manifestShards == true end
    end
    return next(capabilities) ~= nil and capabilities or nil
end

local function countNestedEntries(groups)
    local total = 0
    for _, bucket in pairs(groups or {}) do
        if type(bucket) == "table" then
            total = total + countKeys(bucket)
        end
    end
    return total
end

local function manifestReceiveProgressStamp(state)
    if type(state) ~= "table" then
        return 0
    end
    return tonumber(state.lastProgressAt or state.lastReceivedAt or state.firstReceivedAt or state.builtAt or 0) or 0
end

function Sync:OnInitialize()
    self.onlineNodes = {}
    self.registry = {}
    self.peerCaps = {}
    self.peerVersions = {}
    self.pendingRequests = {}
    self.partialReceive = {}
    self.completedIncomingSessions = {}
    self.outgoingSessions = {}
    self.coordinatorKey = nil
    self.inFlightRequests = {}
    self.inFlight = nil
    self.lastAdvertisedRev = nil
    self._lastCoordinatorChangeAt = 0
    self.lastHelloAt = 0
    self.outboundChunkQueue = {}
    self.manifestChunkQueue = {}
    self.inboundChunkQueue = {}
    self.inboundFinalizeQueue = {}
    self.peerPacing = {}
    self.partialManifestReceive = {}
    self.abandonedManifestReceives = {}
    self.completedManifestReceives = {}
    self.manifestChunkSendCache = {}
    self.manifestAttemptCounters = {}
    self._lastManifestSentAt = {}
    self._lastManifestAnnouncedId = {}
    self._helloManifestRefreshRequested = {}
    self._lastHelloSeenAt = {}
    self._lastManifestReceivedAt = {}
    self.pendingManifestPeers = {}
    self._warmupDeferredManifestPeers = {}
    self._warmupDeferredManifestRefreshPeers = {}
    self._pendingManifestComparePeers = {}
    self._pendingWarmupManifestBroadcastReason = nil
    self.manifestCatchupQueue = {}
    self._manifestCatchupJobActive = false
    self.peerBackoffUntil = {}
    self.peerHealth = {}
    self.recentRejects = {}
    self.warmupUntil = 0
    self.warmupReason = nil
    self.worldTransitionUntil = 0
    self.worldTransitionReason = nil
    self.transitionDrainQueue = {}
    self._transitionDrainJobActive = false
    self._coalescedManifestReason = nil
    self._coalescedManifestFirstAt = 0
    self._sessionIdCounter = 0
    self._requestDispatchCounter = 0
    self.telemetry = newSyncTelemetry()
    self.offlineDebugLog = {}
    self.lifecycleDebugLog = {}
end

function Sync:ResetTelemetry()
    self.telemetry = newSyncTelemetry()
    self.offlineDebugLog = {}
    self.lifecycleDebugLog = {}
end

function Sync:ResetRuntimeQueues(reason, opts)
    opts = opts or {}
    if opts.clearDiscovery then
        self.onlineNodes = {}
        self.registry = {}
        self.peerCaps = {}
        self.peerVersions = {}
        self.coordinatorKey = nil
        self.lastHelloAt = 0
        self._lastCoordinatorChangeAt = 0
    end
    self.pendingRequests = {}
    self.partialReceive = {}
    self.completedIncomingSessions = {}
    self.outgoingSessions = {}
    self.peerCaps = {}
    self.peerVersions = {}
    self.inFlightRequests = {}
    self.inFlight = nil
    self.outboundChunkQueue = {}
    self.manifestChunkQueue = {}
    self.inboundChunkQueue = {}
    self.inboundFinalizeQueue = {}
    self.peerPacing = {}
    self.partialManifestReceive = {}
    self.abandonedManifestReceives = {}
    self.completedManifestReceives = {}
    self.manifestChunkSendCache = {}
    self.manifestAttemptCounters = {}
    self._helloManifestRefreshRequested = {}
    self._lastHelloSeenAt = {}
    self._lastManifestReceivedAt = {}
    self.pendingManifestPeers = {}
    self._warmupDeferredManifestPeers = {}
    self._warmupDeferredManifestRefreshPeers = {}
    self._pendingManifestComparePeers = {}
    self._pendingWarmupManifestBroadcastReason = nil
    self.manifestCatchupQueue = {}
    self._manifestCatchupJobActive = false
    self.peerBackoffUntil = {}
    self.peerHealth = {}
    self.recentRejects = {}
    self.warmupUntil = 0
    self.warmupReason = nil
    self.worldTransitionUntil = 0
    self.worldTransitionReason = nil
    self.transitionDrainQueue = {}
    self._transitionDrainJobActive = false
    self._coalescedManifestReason = nil
    self._coalescedManifestFirstAt = 0
    self._sessionIdCounter = 0
    self._requestDispatchCounter = 0
    self.lifecycleDebugLog = {}
    if opts.clearManifestPeerState ~= false then
        self._lastManifestSentAt = {}
        self._lastManifestAnnouncedId = {}
    end
    if self._warmupTimer then
        self:CancelTimer(self._warmupTimer, true)
        self._warmupTimer = nil
    end
    if self._coalescedManifestTimer then
        self:CancelTimer(self._coalescedManifestTimer, true)
        self._coalescedManifestTimer = nil
    end
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer, true)
        self._transitionTimer = nil
    end
    self:RecomputeCoordinator()
    if opts.kickoffResync then
        self:KickoffDatabaseResync()
    end
    Addon:RequestRefresh("queue")
    if opts.userVisible then
        Addon:Print("Sync runtime reset. Saved recipes were kept and a fresh guild resync was requested.")
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

function Sync:ResetRuntimeStateForDatabaseWipe()
    self.lastAdvertisedRev = nil
    self:ResetRuntimeQueues("database-wipe", {
        clearDiscovery = true,
        clearManifestPeerState = true,
        kickoffResync = false,
        userVisible = false,
    })
end

function Sync:KickoffDatabaseResync()
    self:RequestManifestRefresh()
    self:ScheduleHello(0.5)
end

function Sync:PushOfflineDebugEvent(kind, detail)
    local stamp = date and date("%H:%M:%S") or tostring(time())
    local line = string.format("%s %s %s", tostring(stamp), tostring(kind or "event"), tostring(detail or ""))
    self.offlineDebugLog[#self.offlineDebugLog + 1] = line
    while #self.offlineDebugLog > OFFLINE_DEBUG_LOG_LIMIT do
        table.remove(self.offlineDebugLog, 1)
    end
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
        allowLegacyReleasePeers = Addon.ALLOW_LEGACY_RELEASE_PEERS == true,
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
            if localInfo.allowLegacyReleasePeers then
                return "legacy"
            end
            return "channel-mismatch"
        end
        if remoteChannel ~= localInfo.buildChannel then
            return "channel-mismatch"
        end
    end

    local wireVersion = tonumber(peer.wireVersion or 0) or 0
    if wireVersion <= 0 then
        return "legacy"
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
        if localInfo.allowLegacyReleasePeers then
            return true, "legacy-release", "legacy"
        end
        return false, "missing-build-channel", "legacy"
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
    info.buildChannel = normalizeBuildChannel(info.buildChannel or existing and existing.buildChannel) or "legacy"
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
    if not info then
        return
    end
    info.ineligibleReason = reason and tostring(reason) or nil
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

function Sync:ShouldAcceptInboundPayload(_payload, peerKey)
    local info = peerKey and self:GetPeerVersionInfo(peerKey) or nil
    local compatibility = info and (info.compatibility or self:ComputePeerCompatibility(info)) or "unknown"
    if compatibility == "legacy" or compatibility == "remote-newer-wire" or compatibility == "remote-older-wire" then
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
        if remoteChannel == "dev" or remoteChannel == "legacy" or remoteChannel == "unsupported" then
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
            notice.lastNoticedPeer = tostring(peerKey)
            notice.lastNoticedWireVersion = tostring(info.wireVersion or "")
            self.telemetry.lastVersionNoticePeer = tostring(peerKey)
            self.telemetry.lastVersionNoticeRemote = tostring(info.wireVersion or "")
            self.telemetry.newerProtocolSeen = (self.telemetry.newerProtocolSeen or 0) + 1
        end
        return
    end

    if not (Addon.BuildInfo and Addon.BuildInfo.IsRemoteNewer) then
        return
    end
    if not Addon.BuildInfo.IsRemoteNewer(info.addonVersion, Addon.ADDON_VERSION or Addon.DISPLAY_VERSION) then
        return
    end
    if info.compatibility ~= "compatible" then
        return
    end
    local noticedCmp = notice.lastNoticedVersion and compareSemver(info.addonVersion, notice.lastNoticedVersion) or nil
    local isStrictlyNewerNotice = notice.lastNoticedVersion == nil or noticedCmp == 1
    if not isStrictlyNewerNotice and (now - (notice.lastUpdateNoticeAt or 0)) < VERSION_NOTICE_COOLDOWN then
        return
    end

    Addon:Print(string.format(
        "Recipe Registry: a newer version was detected from %s. You are using %s; latest seen is %s.",
        tostring(peerKey),
        tostring(Addon.ADDON_VERSION or Addon.DISPLAY_VERSION or "?"),
        tostring(info.addonVersion or "unknown")
    ))
    notice.latestRemoteVersionSeen = info.addonVersion
    notice.lastNoticedVersion = info.addonVersion
    notice.lastUpdateNoticeAt = now
    notice.lastNoticedPeer = tostring(peerKey)
    self.telemetry.lastVersionNoticePeer = tostring(peerKey)
    self.telemetry.lastVersionNoticeRemote = tostring(info.addonVersion or "unknown")
    self.telemetry.latestRemoteVersionSeen = tostring(info.addonVersion or "unknown")
    self.telemetry.newerVersionSeen = (self.telemetry.newerVersionSeen or 0) + 1
end

function Sync:GetPeerBackoffRemaining(sourceKey)
    if not self:IsPeerBackoffActive(sourceKey) then return 0 end
    return max(0, (self.peerBackoffUntil[sourceKey] or 0) - time())
end

function Sync:GetPeerBackoffConfig(request)
    local why = tostring(request and request.why or "")
    if Private.isHelloAutoReason(why) then
        return 1, HELLO_AUTO_BACKOFF_SECONDS
    end
    if why == "advertise-auto" or why == "auto-tick" or why == "index" or why == "manifest" then
        return PEER_BACKOFF_FAILURE_THRESHOLD, 30
    end
    return PEER_BACKOFF_FAILURE_THRESHOLD, PEER_BACKOFF_SECONDS
end

function Sync:ClearPeerBackoff(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then return end
    if self.peerBackoffUntil then
        self.peerBackoffUntil[sourceKey] = nil
    end
    if self.peerHealth and self.peerHealth[sourceKey] then
        self.peerHealth[sourceKey].backoffUntil = 0
        self.peerHealth[sourceKey].snapshotBackoffUntil = 0
    end
end

function Sync:MarkPeerFailure(sourceKey, reason, request)
    if not self:IsValidSyncMemberKey(sourceKey) then return end
    self.peerHealth = self.peerHealth or {}
    self.peerBackoffUntil = self.peerBackoffUntil or {}
    local health = self.peerHealth[sourceKey] or {
        successes = 0,
        failures = 0,
        consecutiveFailures = 0,
        lastSuccessAt = 0,
        lastFailureAt = 0,
        manifestSuccesses = 0,
        manifestFailures = 0,
        snapshotSuccesses = 0,
        snapshotFailures = 0,
        snapshotBackoffUntil = 0,
        snapshotQuarantineUntil = 0,
    }
    health.failures = (health.failures or 0) + 1
    health.consecutiveFailures = (health.consecutiveFailures or 0) + 1
    health.lastFailureAt = time()
    health.lastFailureReason = tostring(reason or "timeout")
    local threshold, backoffSeconds = self:GetPeerBackoffConfig(request)
    if (health.consecutiveFailures or 0) >= (threshold or PEER_BACKOFF_FAILURE_THRESHOLD) then
        health.backoffUntil = time() + (backoffSeconds or PEER_BACKOFF_SECONDS)
        health.snapshotBackoffUntil = health.backoffUntil
        self.peerBackoffUntil[sourceKey] = health.backoffUntil
        self.telemetry.peerBackoffApplied = (self.telemetry.peerBackoffApplied or 0) + 1
        Addon:Debug("Peer backoff", tostring(sourceKey), "for", tostring(backoffSeconds or PEER_BACKOFF_SECONDS), "seconds", tostring(reason or "timeout"))
    else
        health.backoffUntil = 0
        health.snapshotBackoffUntil = 0
        self.peerBackoffUntil[sourceKey] = nil
    end
    health.snapshotFailures = (health.snapshotFailures or 0) + 1
    if (health.consecutiveFailures or 0) >= 3 then
        health.snapshotQuarantineUntil = time() + 900
    end
    self.peerHealth[sourceKey] = health
    self:PurgeAutomaticPendingRequestsForPeer(sourceKey, reason or "failure")
end

function Sync:MarkPeerSuccess(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then return end
    self.peerHealth = self.peerHealth or {}
    self.peerBackoffUntil = self.peerBackoffUntil or {}
    local health = self.peerHealth[sourceKey] or {
        successes = 0,
        failures = 0,
        consecutiveFailures = 0,
        lastSuccessAt = 0,
        lastFailureAt = 0,
        manifestSuccesses = 0,
        manifestFailures = 0,
        snapshotSuccesses = 0,
        snapshotFailures = 0,
        snapshotBackoffUntil = 0,
        snapshotQuarantineUntil = 0,
    }
    health.successes = (health.successes or 0) + 1
    health.snapshotSuccesses = (health.snapshotSuccesses or 0) + 1
    health.consecutiveFailures = 0
    health.lastSuccessAt = time()
    health.backoffUntil = 0
    health.snapshotBackoffUntil = 0
    health.snapshotQuarantineUntil = 0
    self.peerHealth[sourceKey] = health
    self.peerBackoffUntil[sourceKey] = nil
    self.lastSnapshotSuccessAt = time()
end

function Sync:MarkManifestPeerSuccess(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then return end
    self.peerHealth = self.peerHealth or {}
    local health = self.peerHealth[sourceKey] or {
        successes = 0,
        failures = 0,
        consecutiveFailures = 0,
        lastSuccessAt = 0,
        lastFailureAt = 0,
        manifestSuccesses = 0,
        manifestFailures = 0,
        snapshotSuccesses = 0,
        snapshotFailures = 0,
        snapshotBackoffUntil = 0,
        snapshotQuarantineUntil = 0,
    }
    health.manifestSuccesses = (health.manifestSuccesses or 0) + 1
    health.lastManifestSuccessAt = time()
    self.peerHealth[sourceKey] = health
end

function Sync:BuildRequestRejectKey(peerKey, request)
    local requestedBlocks = request and request.requestedBlocks or {}
    return table.concat({
        tostring(peerKey or ""),
        tostring(request and request.memberKey or ""),
        tostring(request and request.rev or 0),
        table.concat(requestedBlocks, "\030"),
    }, "\031")
end

function Sync:RememberPeerReject(peerKey, request, reason, retryable, retryAfter)
    if not self:IsValidSyncMemberKey(peerKey) then
        return
    end
    local rejectKey = self:BuildRequestRejectKey(peerKey, request)
    self.recentRejects = self.recentRejects or {}
    self.recentRejects[rejectKey] = {
        reason = tostring(reason or "reject"),
        retryable = retryable == true,
        expiresAt = time() + max(30, tonumber(retryAfter) or 120),
    }
end

function Sync:GetRecentPeerReject(peerKey, request)
    local rejectKey = self:BuildRequestRejectKey(peerKey, request)
    local row = self.recentRejects and self.recentRejects[rejectKey] or nil
    if not row then
        return nil
    end
    if (row.expiresAt or 0) <= time() then
        self.recentRejects[rejectKey] = nil
        return nil
    end
    return row
end

function Sync:PurgeAutomaticPendingRequestsForPeer(sourceKey, _reason)
    if not self:IsValidSyncMemberKey(sourceKey) then
        return 0
    end
    local removed = 0
    for memberKey, request in pairs(self.pendingRequests or {}) do
        if request and request.source == sourceKey and not Private.isManualReason(request.why) then
            self.pendingRequests[memberKey] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        self.telemetry.purgedBackoffRequests = (self.telemetry.purgedBackoffRequests or 0) + removed
    end
    return removed
end

function Sync:CanExchangeDataWithPeer(peerKey, purpose, request)
    purpose = tostring(purpose or "request")
    request = request or {}
    if not self:IsValidSyncMemberKey(peerKey) then
        return false, "invalid-peer"
    end
    if self:IsMockKey(peerKey) and not self:ShouldAllowLocalMockTraffic(peerKey, request.memberKey or peerKey) then
        return false, "mock-peer"
    end
    local peerVersion = self.GetPeerVersionInfo and self:GetPeerVersionInfo(peerKey) or nil
    local caps = self.GetPeerCaps and self:GetPeerCaps(peerKey) or nil
    if peerVersion then
        local compatibility = peerVersion.compatibility or self:ComputePeerCompatibility(peerVersion)
        if compatibility == "channel-mismatch" then
            self:SetPeerIneligibleReason(peerKey, "channel-mismatch")
            self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
            self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
            return false, "channel-mismatch"
        end
        if compatibility == "legacy" and purpose ~= "diagnostics" then
            self:SetPeerIneligibleReason(peerKey, "legacy")
            self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
            self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
            return false, "legacy-peer"
        end
        if compatibility == "remote-newer-wire" or compatibility == "remote-older-wire" then
            self:SetPeerIneligibleReason(peerKey, compatibility)
            self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
            self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
            return false, "wire-mismatch"
        end
        if MODERN_ONLY_PURPOSES[purpose] then
            local capabilities = getDeclaredCapabilities(peerVersion, caps)
            local hasCapabilityDeclaration = caps ~= nil
                or (type(peerVersion.capabilities) == "table" and next(peerVersion.capabilities) ~= nil)
            if not capabilities then
                if not hasCapabilityDeclaration
                    and compatibility == "compatible"
                    and isAssumedModernCapabilityPurpose(purpose, request) then
                    self.telemetry.assumedModernCapabilities = (self.telemetry.assumedModernCapabilities or 0) + 1
                    self.telemetry.assumedModernCapabilityPeer = peerKey
                    self.telemetry.assumedModernCapabilityPurpose = purpose
                else
                    self:SetPeerIneligibleReason(peerKey, "missing-required-capability")
                    self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
                    self.telemetry.skippedMissingCapability = (self.telemetry.skippedMissingCapability or 0) + 1
                    return false, "missing-required-capability"
                end
            end
            if capabilities and MANI_RELIABLE_PURPOSES[purpose] and capabilities.maniReliable ~= true then
                self:SetPeerIneligibleReason(peerKey, "missing-mani-reliable")
                self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
                self.telemetry.skippedMissingCapability = (self.telemetry.skippedMissingCapability or 0) + 1
                return false, "missing-mani-reliable"
            end
            if capabilities and CHUNK_WINDOW_PURPOSES[purpose] and capabilities.chunkWindow ~= true then
                self:SetPeerIneligibleReason(peerKey, "missing-chunk-window")
                self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
                self.telemetry.skippedMissingCapability = (self.telemetry.skippedMissingCapability or 0) + 1
                return false, "missing-chunk-window"
            end
        end
    end
    local allowSpeculativeManifest = purpose == "manifest-large"
        and not request.allowOfflinePeer
        and not peerVersion
    if peerKey ~= self:GetSelfKey()
        and not request.allowOfflinePeer
        and not allowSpeculativeManifest
        and not (self.onlineNodes and self.onlineNodes[peerKey]) then
        return false, "offline"
    end
    local allowManual = Private.isManualReason(request.why)
    if self:IsPeerBackoffActive(peerKey) and not allowManual then
        return false, "backoff"
    end
    local health = self.peerHealth and self.peerHealth[peerKey] or nil
    if health and (health.snapshotQuarantineUntil or 0) > time() and not allowManual then
        return false, "quarantine"
    end
    local recentReject = self:GetRecentPeerReject(peerKey, request)
    if recentReject and recentReject.retryable ~= true then
        self:SetPeerIneligibleReason(peerKey, "recent-reject:" .. tostring(recentReject.reason or "reject"))
        return false, "recent-reject:" .. tostring(recentReject.reason or "reject")
    end
    if caps then
        if caps.isPausedForSync == true and not allowManual then
            self:SetPeerIneligibleReason(peerKey, "peer-paused")
            return false, "peer-paused"
        end
        if purpose == "request" or purpose == "dispatch" or purpose == "manifest-large" then
            if caps.canReceiveReq == false then
                self:SetPeerIneligibleReason(peerKey, "peer-cannot-receive-req")
                return false, "peer-cannot-receive-req"
            end
            if (purpose == "request" or purpose == "dispatch") and caps.canSendSnap == false then
                self:SetPeerIneligibleReason(peerKey, "peer-cannot-send-snap")
                return false, "peer-cannot-send-snap"
            end
            if caps.wireVersion and (caps.wireVersion > Addon.WIRE_VERSION or caps.wireVersion < (Addon.MIN_SUPPORTED_WIRE_VERSION or Addon.WIRE_VERSION)) then
                self:SetPeerIneligibleReason(peerKey, "wire-mismatch")
                self.telemetry.versionIneligiblePeers = (self.telemetry.versionIneligiblePeers or 0) + 1
                self.telemetry.skippedVersionIncompatible = (self.telemetry.skippedVersionIncompatible or 0) + 1
                return false, "wire-mismatch"
            end
        end
    end
    self:SetPeerIneligibleReason(peerKey, nil)
    return true, "eligible"
end

function Sync:GetPeerEligibilityBreakdown()
    local eligible = 0
    local ineligible = 0
    local manifestHealthy = 0
    local snapshotHealthy = 0
    local manifestOnly = 0

    for peerKey in pairs(self.onlineNodes or {}) do
        if self:IsValidSyncMemberKey(peerKey) and peerKey ~= self:GetSelfKey() then
            local caps = self.GetPeerCaps and self:GetPeerCaps(peerKey) or nil
            local health = self.peerHealth and self.peerHealth[peerKey] or nil
            if caps or (health and (health.manifestSuccesses or 0) > 0) then
                manifestHealthy = manifestHealthy + 1
            end
            local peerEligible = self:CanExchangeDataWithPeer(peerKey, "dispatch", {
                source = peerKey,
                memberKey = peerKey,
                why = "diagnostic",
            })
            if peerEligible then
                eligible = eligible + 1
                snapshotHealthy = snapshotHealthy + 1
            else
                ineligible = ineligible + 1
                if caps or (health and (health.manifestSuccesses or 0) > 0) then
                    manifestOnly = manifestOnly + 1
                end
            end
        end
    end

    return {
        eligible = eligible,
        ineligible = ineligible,
        manifestHealthy = manifestHealthy,
        snapshotHealthy = snapshotHealthy,
        manifestOnly = manifestOnly,
    }
end

function Sync:GetPeerHealthScore(sourceKey)
    local health = self.peerHealth and self.peerHealth[sourceKey] or nil
    if not health then return 0 end
    local score = ((health.successes or 0) * 20) - ((health.failures or 0) * 25)
    if (health.lastSuccessAt or 0) > 0 and (time() - (health.lastSuccessAt or 0)) <= 60 then
        score = score + 15
    end
    if (health.lastFailureAt or 0) > 0 and (time() - (health.lastFailureAt or 0)) <= 60 then
        score = score - 15
    end
    return score
end

function Sync:OnGuildRosterUpdate()
    self:PruneOnlineNodes()
    self:RecomputeCoordinator()
end

function Sync:IsRosterFresh(maxAge)
    if not (Addon.Data and Addon.Data.NeedsGuildRosterRefresh) then
        return true
    end
    return not Addon.Data:NeedsGuildRosterRefresh(maxAge or Constants.ROSTER_FRESHNESS_MAX_AGE)
end

function Sync:EnsureFreshRoster(reason, opts)
    opts = opts or {}
    if self:IsRosterFresh(opts.maxAge) then
        return true
    end
    if Addon.Data and Addon.Data.RequestGuildRosterRefresh then
        local requested = Addon.Data:RequestGuildRosterRefresh(reason or "sync", {
            force = opts.force == true,
            cooldown = opts.cooldown or Constants.ROSTER_REFRESH_REQUEST_COOLDOWN,
        })
        if requested then
            self.telemetry.rosterRefreshRequests = (self.telemetry.rosterRefreshRequests or 0) + 1
        end
    end
    return false
end

function Sync:QueuePendingManifestComparePeer(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then return end
    self._pendingManifestComparePeers = self._pendingManifestComparePeers or {}
    self._pendingManifestComparePeers[peerKey] = true
    self.telemetry.manifestCompareDeferred = (self.telemetry.manifestCompareDeferred or 0) + 1
end

function Sync:ShouldDeferInlineManifestFallback(_reason)
    return self:ShouldDeferHeavyLifecycleWork("manifest-fallback")
end

function Sync:GetInFlightRequests()
    self.inFlightRequests = self.inFlightRequests or {}
    if self.inFlight
        and self:IsRequestShapeValid(self.inFlight)
        and not self.inFlightRequests[self.inFlight.memberKey] then
        self.inFlightRequests[self.inFlight.memberKey] = self.inFlight
    end
    return self.inFlightRequests
end

function Sync:RefreshPrimaryInFlight()
    local primary
    for _, request in pairs(self:GetInFlightRequests()) do
        if self:IsRequestShapeValid(request)
            and (
                not primary
                or (request.startedAt or 0) < (primary.startedAt or 0)
                or (
                    (request.startedAt or 0) == (primary.startedAt or 0)
                    and (request.dispatchOrder or 0) < (primary.dispatchOrder or 0)
                )
            ) then
            primary = request
        end
    end
    self.inFlight = primary
    return primary
end

function Sync:GetInFlightRequest(memberKey)
    if not memberKey then
        return self:RefreshPrimaryInFlight()
    end
    return self:GetInFlightRequests()[memberKey]
end

function Sync:GetActiveRequestCount()
    return countKeys(self:GetInFlightRequests())
end

function Sync:GetMaxConcurrentRequests()
    return Constants.MAX_CONCURRENT_REQUESTS or 1
end

function Sync:SetInFlightRequest(request)
    if not self:IsRequestShapeValid(request) then return nil end
    local requests = self:GetInFlightRequests()
    requests[request.memberKey] = request
    return self:RefreshPrimaryInFlight()
end

function Sync:ClearInFlightRequest(memberKey)
    if not memberKey then
        self.inFlightRequests = {}
        self.inFlight = nil
        return nil
    end
    if self.inFlight and self.inFlight.memberKey == memberKey then
        self.inFlight = nil
    end
    local requests = self:GetInFlightRequests()
    requests[memberKey] = nil
    return self:RefreshPrimaryInFlight()
end

function Sync:ScheduleHello(delay)
    if self:ShouldDeferHeavyLifecycleWork("hello") then
        self.telemetry.transitionSkippedHello = (self.telemetry.transitionSkippedHello or 0) + 1
        self.telemetry.transitionDeferrals = (self.telemetry.transitionDeferrals or 0) + 1
        self:QueueTransitionDrainWork({
            kind = "hello",
            reason = "deferred-hello",
        })
        return
    end
    self:ScheduleTimer("BroadcastHello", delay or 0.5)
end

function Sync:ScheduleQueuePump(delay)
    if self._queuePumpTimer then return end
    self._queuePumpTimer = self:ScheduleTimer(function()
        self._queuePumpTimer = nil
        self:ProcessRequestQueue()
    end, delay or 0.05)
end

function Sync:EnterWarmup(reason, seconds)
    local duration = max(1, tonumber(seconds) or POST_WORLD_GRACE_SECONDS)
    local untilAt = time() + duration
    if (self.warmupUntil or 0) < untilAt then
        self.warmupUntil = untilAt
    end
    self.warmupReason = tostring(reason or self.warmupReason or "warmup")
    for _, request in pairs(self:GetInFlightRequests()) do
        request.startedAt = time()
        request.lastProgressAt = time()
    end
    for _, state in pairs(self.partialReceive or {}) do
        state.lastProgressAt = time()
    end
    if self._warmupTimer then
        self:CancelTimer(self._warmupTimer, true)
        self._warmupTimer = nil
    end
    self._warmupTimer = self:ScheduleTimer(function()
        self._warmupTimer = nil
        self:HandleWarmupExpired()
    end, duration)
    self:PushLifecycleEvent("WARMUP_START", tostring(self.warmupReason))
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
    local duration = max(1, tonumber(seconds) or POST_WORLD_GRACE_SECONDS)
    local untilAt = time() + duration
    if (self.worldTransitionUntil or 0) < untilAt then
        self.worldTransitionUntil = untilAt
    end
    self.worldTransitionReason = tostring(reason or self.worldTransitionReason or "world-transition")
    self:PushLifecycleEvent("TRANSITION_GATE_START", string.format("%s %ds", tostring(self.worldTransitionReason), duration))
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer, true)
        self._transitionTimer = nil
    end
    self._transitionTimer = self:ScheduleTimer(function()
        self._transitionTimer = nil
        self:ScheduleTransitionDrain("transition-expired")
    end, duration)
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
    local pressure = 0
    pressure = pressure + min(100, math.floor((#(self.outboundChunkQueue or {}) / max(1, MAX_OUTBOUND_CHUNKS)) * 100))
    pressure = pressure + min(100, math.floor((#(self.manifestChunkQueue or {}) / max(1, MAX_MANIFEST_CHUNKS)) * 100))
    pressure = pressure + min(100, math.floor((#(self.inboundChunkQueue or {}) / max(1, MAX_INBOUND_CHUNKS)) * 100))
    pressure = pressure + min(100, math.floor((#(self.inboundFinalizeQueue or {}) / max(1, MAX_INBOUND_FINALIZE_QUEUE)) * 100))
    pressure = pressure + min(100, math.floor((countKeys(self.pendingRequests or {}) / max(1, MAX_PENDING_REQUESTS)) * 100))
    pressure = pressure + min(100, math.floor((countKeys(self.partialReceive or {}) / max(1, MAX_PARTIAL_RECEIVES)) * 100))
    pressure = pressure + min(100, math.floor((countNestedEntries(self.partialManifestReceive) / max(1, MAX_PARTIAL_MANIFESTS_TOTAL)) * 100))
    pressure = pressure + min(100, math.floor((#(self.manifestCatchupQueue or {}) / max(1, MAX_MANIFEST_CATCHUP_QUEUE)) * 100))
    pressure = math.floor(pressure / 8)
    self.telemetry.runtimeQueuePressure = pressure
    self.telemetry.outboundChunkQueueMax = max(self.telemetry.outboundChunkQueueMax or 0, #(self.outboundChunkQueue or {}))
    self.telemetry.manifestChunkQueueMax = max(self.telemetry.manifestChunkQueueMax or 0, #(self.manifestChunkQueue or {}))
    self.telemetry.inboundChunkQueueMax = max(self.telemetry.inboundChunkQueueMax or 0, #(self.inboundChunkQueue or {}))
    self.telemetry.inboundFinalizeQueueMax = max(self.telemetry.inboundFinalizeQueueMax or 0, #(self.inboundFinalizeQueue or {}))
    self.telemetry.partialReceiveMax = max(self.telemetry.partialReceiveMax or 0, countKeys(self.partialReceive or {}))
    self.telemetry.partialManifestReceiveMax = max(self.telemetry.partialManifestReceiveMax or 0, countNestedEntries(self.partialManifestReceive))
    self.telemetry.pendingRequestMax = max(self.telemetry.pendingRequestMax or 0, countKeys(self.pendingRequests or {}))
    return pressure
end

function Sync:ShouldDeferHeavyLifecycleWork(reason)
    local normalized = tostring(reason or "")
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseHeavyUI() then
        return true, "sensitive-context"
    end
    if self:IsInWarmup() then
        return true, "warmup"
    end
    if self:IsInWorldTransition() then
        return true, "world-transition"
    end
    if self:EstimateRuntimeQueuePressure() >= 70 then
        return true, "queue-pressure"
    end
    if (normalized == "ui" or normalized == "roster-ui")
        and not (Addon.UI and Addon.UI.frame and Addon.UI.frame:IsShown()) then
        return true, "ui-hidden"
    end
    return false, nil
end

function Sync:QueueTransitionDrainWork(item, atFront)
    if type(item) ~= "table" or not item.kind then return end
    self.transitionDrainQueue = self.transitionDrainQueue or {}
    if atFront then
        table.insert(self.transitionDrainQueue, 1, item)
    else
        self.transitionDrainQueue[#self.transitionDrainQueue + 1] = item
    end
end

function Sync:RunTransitionDrainStep(state, _budget)
    state = state or {}
    if self:IsInWarmup() or self:IsInWorldTransition() then
        local waitFor = self:IsInWarmup() and self:GetWarmupRemaining() or self:GetWorldTransitionRemaining()
        state.nextRunAt = time() + max(1, waitFor)
        return true, state
    end

    local item = self.transitionDrainQueue and self.transitionDrainQueue[1] or nil
    if not item then
        return false, state
    end

    remove(self.transitionDrainQueue, 1)
    self.telemetry.transitionDrainSteps = (self.telemetry.transitionDrainSteps or 0) + 1
    self:PushLifecycleEvent("TRANSITION_DRAIN_STEP", tostring(item.kind))

    if item.kind == "manifest-peer" then
        if item.peerKey and self.onlineNodes and self.onlineNodes[item.peerKey] then
            self:SendManifestToPeer(item.peerKey, item.why or "transition")
        end
    elseif item.kind == "manifest-refresh" then
        if item.peerKey and self.onlineNodes and self.onlineNodes[item.peerKey] then
            self:RequestManifestRefresh(item.peerKey, { reason = item.reason or "transition" })
        end
    elseif item.kind == "broadcast-manifest" then
        self:BroadcastManifestToOnlinePeers(item.why or "transition", {
            ignoreWarmup = true,
            ignoreTransition = true,
        })
    elseif item.kind == "manifest-compare-flush" then
        self:FlushPendingManifestComparePeers(item.reason or "transition")
    elseif item.kind == "catchup" then
        self:ScheduleManifestCatchupDrain()
    elseif item.kind == "tooltip" then
        if Addon.Tooltip and Addon.Tooltip.OnSyncWarmupEnded then
            Addon.Tooltip:OnSyncWarmupEnded()
        end
    elseif item.kind == "hello" then
        self:BroadcastHello()
    elseif item.kind == "ui" then
        Addon:RequestRefresh(item.reason or "transition")
    end

    state.nextRunAt = time() + 1
    return #(self.transitionDrainQueue or {}) > 0, state
end

function Sync:ScheduleTransitionDrain(reason)
    if self._transitionDrainJobActive then return end
    if #(self.transitionDrainQueue or {}) == 0 then return end
    self._transitionDrainJobActive = true
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        self:ScheduleTimer(function()
            self._transitionDrainJobActive = false
            local keepGoing = self:RunTransitionDrainStep({ nextRunAt = time() }, 1)
            if keepGoing then
                self:ScheduleTransitionDrain(reason)
            end
        end, 1)
        return
    end

    Addon.Performance:ScheduleJob("transition-drain", function(state)
        state = state or {}
        state.nextRunAt = state.nextRunAt or time()
        if time() < state.nextRunAt then
            return true, state
        end
        local keepGoing, nextState = self:RunTransitionDrainStep(state, 1)
        if not keepGoing then
            self._transitionDrainJobActive = false
            return false, nextState
        end
        return true, nextState
    end, {
        category = "sync-manifest-catchup",
        label = reason or "transition-drain",
        budgetMs = 1,
        state = {
            nextRunAt = time() + 1,
        },
    })
end

function Sync:QueueWarmupManifestPeer(peerKey, why)
    if not self:IsValidSyncMemberKey(peerKey) then return end
    self._warmupDeferredManifestPeers = self._warmupDeferredManifestPeers or {}
    self._warmupDeferredManifestPeers[peerKey] = why or "warmup"
end

function Sync:QueueWarmupManifestRefresh(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then return end
    self._warmupDeferredManifestRefreshPeers = self._warmupDeferredManifestRefreshPeers or {}
    self._warmupDeferredManifestRefreshPeers[peerKey] = true
end

function Sync:ShouldRequestManifestRefresh(peerKey, opts)
    opts = opts or {}
    if not self:IsValidSyncMemberKey(peerKey) then return false end
    if opts.force == true or opts.ignoreCooldown == true then return true end

    local now = time()
    local lastRequestAt = self._helloManifestRefreshRequested and self._helloManifestRefreshRequested[peerKey] or 0
    if lastRequestAt > 0 and (now - lastRequestAt) < MANIFEST_REFRESH_REQUEST_COOLDOWN then
        return false
    end

    local lastManifestAt = self._lastManifestReceivedAt and self._lastManifestReceivedAt[peerKey] or 0
    return lastManifestAt == 0 or (now - lastManifestAt) > NODE_TIMEOUT
end

function Sync:RecordManifestRefreshRequest(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then return end
    self._helloManifestRefreshRequested = self._helloManifestRefreshRequested or {}
    self._helloManifestRefreshRequested[peerKey] = time()
end

function Sync:RecordManifestReceived(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then return end
    self._lastManifestReceivedAt = self._lastManifestReceivedAt or {}
    self._lastManifestReceivedAt[peerKey] = time()
end

function Sync:HandleWarmupExpired()
    if self:IsInWarmup() then
        local delay = max(0.5, self:GetWarmupRemaining())
        self._warmupTimer = self:ScheduleTimer(function()
            self._warmupTimer = nil
            self:HandleWarmupExpired()
        end, delay)
        return
    end

    self.warmupUntil = 0
    self:PushLifecycleEvent("WARMUP_END", tostring(self.warmupReason or "warmup"))
    local peers = self._warmupDeferredManifestPeers or {}
    self._warmupDeferredManifestPeers = {}
    for peerKey, why in pairs(peers) do
        if self.onlineNodes and self.onlineNodes[peerKey] then
            self.telemetry.transitionDeferredManifestPeers = (self.telemetry.transitionDeferredManifestPeers or 0) + 1
            self:QueueTransitionDrainWork({
                kind = "manifest-peer",
                peerKey = peerKey,
                why = why or "warmup",
            })
        end
    end

    local refreshPeers = self._warmupDeferredManifestRefreshPeers or {}
    self._warmupDeferredManifestRefreshPeers = {}
    for peerKey in pairs(refreshPeers) do
        if self.onlineNodes and self.onlineNodes[peerKey] then
            self.telemetry.transitionDeferredManifestPeers = (self.telemetry.transitionDeferredManifestPeers or 0) + 1
            self:QueueTransitionDrainWork({
                kind = "manifest-refresh",
                peerKey = peerKey,
                reason = "warmup",
            })
        end
    end

    if self._pendingManifestComparePeers and next(self._pendingManifestComparePeers) ~= nil then
        self:QueueTransitionDrainWork({
            kind = "manifest-compare-flush",
            reason = "warmup-expired",
        }, true)
    end

    local why = self._pendingWarmupManifestBroadcastReason
    self._pendingWarmupManifestBroadcastReason = nil
    if why then
        self:QueueTransitionDrainWork({
            kind = "broadcast-manifest",
            why = why,
        })
    end
    if #(self.manifestCatchupQueue or {}) > 0 then
        self.telemetry.transitionDeferredCatchup = (self.telemetry.transitionDeferredCatchup or 0) + 1
        self:QueueTransitionDrainWork({ kind = "catchup" })
    end
    if Addon.Tooltip and Addon.Tooltip.OnSyncWarmupEnded then
        self.telemetry.transitionDeferredTooltip = (self.telemetry.transitionDeferredTooltip or 0) + 1
        self:QueueTransitionDrainWork({ kind = "tooltip" })
    end
    self.telemetry.transitionDeferredUI = (self.telemetry.transitionDeferredUI or 0) + 1
    self:QueueTransitionDrainWork({
        kind = "ui",
        reason = "transition-resume",
    })
    if #(self.transitionDrainQueue or {}) > 0 then
        self:ScheduleTransitionDrain("warmup-expired")
    end
end

function Sync:DropObsoleteManifestChunks(_reason)
    local queue = self.manifestChunkQueue or {}
    if #queue <= MAX_MANIFEST_CHUNKS then
        return 0
    end

    local newestByPeer = {}
    local seenChunkKeys = {}
    for _, queued in ipairs(queue) do
        local peerKey = queued and queued.peer or nil
        local payload = queued and queued.payload or nil
        local manifestId = payload and payload.manifestId or nil
        if peerKey and manifestId then
            newestByPeer[peerKey] = manifestId
        end
    end

    local kept = {}
    local removed = 0
    for index = #queue, 1, -1 do
        local queued = queue[index]
        local peerKey = queued and queued.peer or nil
        local payload = queued and queued.payload or nil
        local manifestId = payload and payload.manifestId or nil
        local dedupeKey = table.concat({
            tostring(peerKey or ""),
            tostring(manifestId or ""),
            tostring(payload and payload.seq or 0),
        }, "\031")
        if seenChunkKeys[dedupeKey] then
            removed = removed + 1
        elseif #kept >= MAX_MANIFEST_CHUNKS then
            removed = removed + 1
        elseif peerKey and manifestId and newestByPeer[peerKey] ~= manifestId then
            removed = removed + 1
        else
            seenChunkKeys[dedupeKey] = true
            kept[#kept + 1] = queued
        end
    end

    if removed > 0 then
        local normalized = {}
        for index = #kept, 1, -1 do
            normalized[#normalized + 1] = kept[index]
        end
        self.manifestChunkQueue = normalized
    end
    return removed
end

function Sync:DropDuplicateOutboundChunks(_reason)
    local queue = self.outboundChunkQueue or {}
    if #queue <= MAX_OUTBOUND_CHUNKS then
        return 0
    end

    local kept = {}
    local seen = {}
    local removed = 0
    for index = #queue, 1, -1 do
        local queued = queue[index]
        local block = queued and queued.block or nil
        local dedupeKey = table.concat({
            tostring(queued and queued.peer or ""),
            tostring(block and block.sessionId or ""),
            tostring(block and block.seq or ""),
            tostring(block and block.key or ""),
        }, "\031")
        if seen[dedupeKey] or #kept >= MAX_OUTBOUND_CHUNKS then
            removed = removed + 1
        else
            seen[dedupeKey] = true
            kept[#kept + 1] = queued
        end
    end
    if removed > 0 then
        local normalized = {}
        for index = #kept, 1, -1 do
            normalized[#normalized + 1] = kept[index]
        end
        self.outboundChunkQueue = normalized
    end
    return removed
end

function Sync:ReleaseCompletedTransferState(memberKey, sessionId, _reason)
    local released = 0
    if memberKey and self.partialReceive and self.partialReceive[memberKey] then
        local state = self.partialReceive[memberKey]
        if not sessionId or state.sessionId == sessionId then
            self.partialReceive[memberKey] = nil
            released = released + 1
        end
    end

    if sessionId and self.outgoingSessions and self.outgoingSessions[sessionId] then
        self.outgoingSessions[sessionId] = nil
        released = released + 1
    end

    if sessionId and self.outboundChunkQueue and #self.outboundChunkQueue > 0 then
        local kept = {}
        for _, queued in ipairs(self.outboundChunkQueue) do
            if not (queued and queued.block and queued.block.sessionId == sessionId) then
                kept[#kept + 1] = queued
            else
                released = released + 1
            end
        end
        self.outboundChunkQueue = kept
    end

    if released > 0 then
        self.telemetry.releasedIncomingStates = (self.telemetry.releasedIncomingStates or 0) + released
    end
    return released
end

function Sync:EnforceRuntimeQueueCaps(_reason)
    local pruned = 0
    pruned = pruned + self:DropDuplicateOutboundChunks("cap")
    pruned = pruned + self:DropObsoleteManifestChunks("cap")

    while #(self.outboundChunkQueue or {}) > MAX_OUTBOUND_CHUNKS do
        remove(self.outboundChunkQueue, 1)
        pruned = pruned + 1
    end
    while #(self.inboundChunkQueue or {}) > MAX_INBOUND_CHUNKS do
        remove(self.inboundChunkQueue, 1)
        pruned = pruned + 1
    end
    while #(self.inboundFinalizeQueue or {}) > MAX_INBOUND_FINALIZE_QUEUE do
        remove(self.inboundFinalizeQueue, 1)
        pruned = pruned + 1
    end
    while #(self.manifestCatchupQueue or {}) > MAX_MANIFEST_CATCHUP_QUEUE do
        remove(self.manifestCatchupQueue, 1)
        pruned = pruned + 1
    end

    local partialCount = countKeys(self.partialReceive or {})
    if partialCount > MAX_PARTIAL_RECEIVES then
        local rows = {}
        for memberKey, state in pairs(self.partialReceive or {}) do
            rows[#rows + 1] = {
                memberKey = memberKey,
                stamp = tonumber(state and state.lastProgressAt or 0) or 0,
            }
        end
        sort(rows, function(a, b) return a.stamp < b.stamp end)
        for index = 1, (partialCount - MAX_PARTIAL_RECEIVES) do
            local row = rows[index]
            if row and self.partialReceive[row.memberKey] then
                self.partialReceive[row.memberKey] = nil
                pruned = pruned + 1
            end
        end
    end

    local nestedTotal = countNestedEntries(self.partialManifestReceive)
    if nestedTotal > MAX_PARTIAL_MANIFESTS_TOTAL then
        for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
            while countKeys(manifests) > MAX_PARTIAL_MANIFESTS_PER_PEER do
                local oldestKey
                local oldestStamp
                for manifestId, state in pairs(manifests or {}) do
                    local stamp = manifestReceiveProgressStamp(state)
                    if not oldestKey or stamp < oldestStamp then
                        oldestKey = manifestId
                        oldestStamp = stamp
                    end
                end
                if not oldestKey then break end
                manifests[oldestKey] = nil
                pruned = pruned + 1
            end
            if next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    local pendingCount = countKeys(self.pendingRequests or {})
    if pendingCount > MAX_PENDING_REQUESTS then
        local rows = {}
        for memberKey, request in pairs(self.pendingRequests or {}) do
            rows[#rows + 1] = {
                memberKey = memberKey,
                stamp = tonumber(request and request.queuedAt or 0) or 0,
            }
        end
        sort(rows, function(a, b) return a.stamp < b.stamp end)
        for index = 1, (pendingCount - MAX_PENDING_REQUESTS) do
            local row = rows[index]
            if row and self.pendingRequests[row.memberKey] then
                self.pendingRequests[row.memberKey] = nil
                pruned = pruned + 1
            end
        end
    end

    if pruned > 0 then
        self.telemetry.queueCapPrunes = (self.telemetry.queueCapPrunes or 0) + pruned
    end
    self:EstimateRuntimeQueuePressure()
    return pruned
end

function Sync:IsPeerBackoffActive(sourceKey)
    if not self:IsValidSyncMemberKey(sourceKey) then return false end
    local untilAt = self.peerBackoffUntil and self.peerBackoffUntil[sourceKey] or nil
    if not untilAt then return false end
    if untilAt <= time() then
        self.peerBackoffUntil[sourceKey] = nil
        if self.peerHealth and self.peerHealth[sourceKey] then
            self.peerHealth[sourceKey].backoffUntil = 0
        end
        return false
    end
    return true
end

function Sync:TouchNode(key, version)
    if not self:IsValidSyncMemberKey(key) then return end
    self.onlineNodes[key] = self.onlineNodes[key] or {}
    self.onlineNodes[key].lastSeen = time()
    self.onlineNodes[key].version = version or self.onlineNodes[key].version

    local selfKey = self:GetSelfKey()
    self.onlineNodes[selfKey] = self.onlineNodes[selfKey] or { version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION }
    self.onlineNodes[selfKey].lastSeen = time()

    if self._recomputeTimer then return end
    self._recomputeTimer = self:ScheduleTimer(function()
        self._recomputeTimer = nil
        self:RecomputeCoordinator()
    end, COORDINATOR_RECOMPUTE_DELAY)
end

function Sync:PruneOnlineNodes()
    local now = time()
    for key, info in pairs(self.onlineNodes) do
        if info.lastSeen and (now - info.lastSeen) > NODE_TIMEOUT then
            self.onlineNodes[key] = nil
            self._lastManifestSentAt[key] = nil
            self._lastManifestAnnouncedId[key] = nil
            self._helloManifestRefreshRequested[key] = nil
            self._lastHelloSeenAt[key] = nil
            self._lastManifestReceivedAt[key] = nil
            self.abandonedManifestReceives[key] = nil
            self.completedManifestReceives[key] = nil
            self.peerBackoffUntil[key] = nil
            self.peerVersions[key] = nil
            if self.peerHealth then
                self.peerHealth[key] = nil
            end
        end
    end
end

function Sync:PrunePartialManifestReceives()
    local now = time()
    local removed = 0
    local oldestAge = 0

    for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
        if not self:IsValidSyncMemberKey(peerKey) or type(manifests) ~= "table" then
            if type(manifests) == "table" then
                for manifestId, state in pairs(manifests) do
                    local seenCount = type(state) == "table" and countKeys(state.seen) or 0
                    local total = type(state) == "table" and (tonumber(state.total or 0) or 0) or 0
                    Addon:Debug(string.format(
                        "Manifest prune peer=%s manifestId=%s received=%d/%d reason=%s",
                        tostring(peerKey),
                        tostring(manifestId or "unknown"),
                        seenCount,
                        total,
                        self:IsValidSyncMemberKey(peerKey) and "invalid-state" or "invalid-peer"
                    ))
                end
            else
                Addon:Debug(string.format(
                    "Manifest prune peer=%s manifestId=%s received=%d/%d reason=%s",
                    tostring(peerKey),
                    "unknown",
                    0,
                    0,
                    "invalid-peer"
                ))
            end
            removed = removed + math.max(1, countKeys(manifests))
            self.partialManifestReceive[peerKey] = nil
        else
            for manifestId, state in pairs(manifests) do
                local progressStamp = manifestReceiveProgressStamp(state)
                if progressStamp > 0 then
                    oldestAge = max(oldestAge, max(0, now - progressStamp))
                end
                local timedOut = progressStamp > 0 and (now - progressStamp) > SESSION_TIMEOUT
                if type(state) ~= "table" or timedOut then
                    local seenCount = type(state) == "table" and countKeys(state.seen) or 0
                    local total = type(state) == "table" and (tonumber(state.total or 0) or 0) or 0
                    local reason = type(state) ~= "table" and "invalid-state" or "timeout"
                    local missingSeqs = type(state) == "table" and self.GetMissingSeqs and self:GetMissingSeqs(state) or {}
                    local diagnostics = self.GetManifestBatchDiagnostics and self:GetManifestBatchDiagnostics(peerKey, manifestId, "receive") or nil
                    local canRecoverMissingSeqs = reason == "timeout"
                        and seenCount > 0
                        and total > seenCount
                        and #missingSeqs > 0
                        and self:IsValidSyncMemberKey(peerKey)
                    if canRecoverMissingSeqs and not state.recoveryRequestedAt then
                        state.recoveryRequestedAt = now
                        state.recoveryReason = "manifest-missing-seqs"
                        state.recoveryMissingSeqs = missingSeqs
                        self.telemetry.manifestSoftTimeouts = (self.telemetry.manifestSoftTimeouts or 0) + 1
                        self.telemetry.manifestPartialTimeouts = (self.telemetry.manifestPartialTimeouts or 0) + 1
                        self.telemetry.manifestPartialRecoveryRequests = (self.telemetry.manifestPartialRecoveryRequests or 0) + 1
                        self.telemetry.manifestRecoveryRequests = (self.telemetry.manifestRecoveryRequests or 0) + 1
                        self.telemetry.manifestMissingSeqRequests = (self.telemetry.manifestMissingSeqRequests or 0) + 1
                        self.telemetry.lastManifestRecoveryPeer = peerKey
                        self.telemetry.lastManifestRecoveryId = manifestId
                        if diagnostics then
                            diagnostics.receivedSeqCount = seenCount
                            diagnostics.missingSeqs = missingSeqs
                            diagnostics.recoveryRequested = true
                            diagnostics.recoveryMode = "missing-seqs"
                        end
                        Addon:Debug(string.format(
                            "Manifest soft-timeout peer=%s manifestId=%s received=%d/%d missingSeqs=%s",
                            tostring(peerKey),
                            tostring(manifestId or "unknown"),
                            seenCount,
                            total,
                            table.concat(missingSeqs, ",")
                        ))
                        Addon:Trace("manifest", string.format(
                            "soft-timeout peer=%s manifestId=%s received=%d/%d attempt=%s missing=%s",
                            tostring(peerKey),
                            tostring(manifestId or "unknown"),
                            seenCount,
                            total,
                            tostring(state.manifestAttempt or 1),
                            table.concat(missingSeqs, ",")
                        ))
                        self:RequestManifestRefresh(peerKey, {
                            ignoreCooldown = true,
                            reason = "manifest-missing-seqs",
                            manifestId = manifestId,
                            manifestAttempt = state.manifestAttempt,
                            missingSeqs = missingSeqs,
                        })
                    elseif not canRecoverMissingSeqs
                        or not state.recoveryRequestedAt
                        or (now - state.recoveryRequestedAt) > SESSION_TIMEOUT then
                        if diagnostics then
                            diagnostics.receivedSeqCount = seenCount
                            diagnostics.missingSeqs = missingSeqs
                            diagnostics.pruned = true
                            diagnostics.pruneReason = reason
                        end
                        Addon:Debug(string.format(
                            "Manifest prune peer=%s manifestId=%s received=%d/%d reason=%s",
                            tostring(peerKey),
                            tostring(manifestId or "unknown"),
                            seenCount,
                            total,
                            reason
                        ))
                        Addon:Trace("manifest", string.format(
                            "hard-prune peer=%s manifestId=%s received=%d/%d attempt=%s reason=%s",
                            tostring(peerKey),
                            tostring(manifestId or "unknown"),
                            seenCount,
                            total,
                            tostring(type(state) == "table" and state.manifestAttempt or "none"),
                            tostring(reason)
                        ))
                        manifests[manifestId] = nil
                        if reason == "timeout" and self.MarkManifestReceiveAbandoned then
                            self:MarkManifestReceiveAbandoned(peerKey, manifestId, state.manifestAttempt)
                        end
                        removed = removed + 1
                        self.telemetry.manifestHardPrunes = (self.telemetry.manifestHardPrunes or 0) + 1
                        self.telemetry.manifestPartialPrunes = (self.telemetry.manifestPartialPrunes or 0) + 1
                        self.telemetry.lastManifestPruneReason = reason
                    end
                end
            end
            if next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    if removed > 0 then
        self.telemetry.prunedPartialManifestReceives = (self.telemetry.prunedPartialManifestReceives or 0) + removed
        self.telemetry.partialManifestPruned = (self.telemetry.partialManifestPruned or 0) + removed
    end
    self.telemetry.oldestPartialManifestAge = oldestAge
end

function Sync:PruneTricklePeerState()
    local trickle = Addon.TrickleSync
    if not trickle then return end

    local now = time()
    local removedPeers = 0
    local removedQueues = 0

    for peerKey, state in pairs(trickle.peerState or {}) do
        local lastManifestAt = type(state) == "table" and (tonumber(state.lastManifestAt or 0) or 0) or 0
        local isOnline = self.onlineNodes and self.onlineNodes[peerKey] ~= nil
        if not self:IsValidSyncMemberKey(peerKey)
            or ((not isOnline) and lastManifestAt > 0 and (now - lastManifestAt) > NODE_TIMEOUT) then
            trickle.peerState[peerKey] = nil
            removedPeers = removedPeers + 1
            if trickle.outboundQueue and trickle.outboundQueue[peerKey] then
                trickle.outboundQueue[peerKey] = nil
                removedQueues = removedQueues + 1
            end
        end
    end

    for peerKey, queue in pairs(trickle.outboundQueue or {}) do
        local state = trickle.peerState and trickle.peerState[peerKey] or nil
        local lastManifestAt = type(state) == "table" and (tonumber(state.lastManifestAt or 0) or 0) or 0
        local isOnline = self.onlineNodes and self.onlineNodes[peerKey] ~= nil
        if not self:IsValidSyncMemberKey(peerKey)
            or ((not isOnline) and lastManifestAt > 0 and (now - lastManifestAt) > NODE_TIMEOUT)
            or (#(queue or {}) == 0 and not state) then
            trickle.outboundQueue[peerKey] = nil
            removedQueues = removedQueues + 1
        end
    end

    if removedPeers > 0 then
        self.telemetry.prunedTricklePeerState = (self.telemetry.prunedTricklePeerState or 0) + removedPeers
    end
    if removedQueues > 0 then
        self.telemetry.prunedTrickleOutboundQueues = (self.telemetry.prunedTrickleOutboundQueues or 0) + removedQueues
    end
end

function Sync:PruneState()
    self:PruneOnlineNodes()
    self:PruneOutgoingSessions()
    self:PrunePartialReceives()
    self:PrunePartialManifestReceives()
    if self.PruneManifestRecoveryCaches then
        self:PruneManifestRecoveryCaches()
    end
    self:PruneTricklePeerState()
    self:EnforceRuntimeQueueCaps("prune")
    self:RecomputeCoordinator()
end

function Sync:RecomputeCoordinator()
    local rosterFresh = self:IsRosterFresh()
    if not rosterFresh then
        self:EnsureFreshRoster("coordinator")
        rosterFresh = self:IsRosterFresh()
    end
    local keys = {}
    for key in pairs(self.onlineNodes) do
        if self:IsValidSyncMemberKey(key)
            and not self:IsMockKey(key)
            and ((not rosterFresh) or Addon.Data:IsMemberOnline(key) or key == self:GetSelfKey()) then
            keys[#keys + 1] = key
        end
    end
    if #keys == 0 then
        keys[1] = self:GetSelfKey()
    end
    sort(keys)
    local nextCoordinator = keys[1]
    if nextCoordinator ~= self.coordinatorKey then
        self.coordinatorKey = nextCoordinator
        self._lastCoordinatorChangeAt = time()
        Addon:Debug("Coordinator changed to", tostring(nextCoordinator))
        Addon:RequestRefresh("coordinator")
    end
end

function Sync:IsCoordinator()
    return self.coordinatorKey == self:GetSelfKey()
end

function Sync:RecordRevisionHint(memberKey, rev, updatedAt, owner, meta)
    if not self:IsValidSyncMemberKey(memberKey) then return end
    if owner and not self:IsValidSyncMemberKey(owner) then owner = memberKey end
    meta = meta or {}
    local row = self.registry[memberKey] or { owner = owner or memberKey, rev = 0, updatedAt = 0 }
    if owner then row.owner = owner end
    if (rev or 0) >= (row.rev or 0) then
        row.rev = rev or row.rev or 0
        row.updatedAt = updatedAt or row.updatedAt or 0
    end
    if meta.isMock ~= nil then
        row.isMock = meta.isMock and true or false
    elseif row.isMock == nil and isMockKey(memberKey) then
        row.isMock = true
    end
    row.lastSeen = time()
    self.registry[memberKey] = row
end

function Sync:GetKnownOwner(memberKey)
    local row = self.registry[memberKey]
    if row and self:IsValidSyncMemberKey(row.owner) then return row.owner end
    return memberKey
end

function Sync:GetKnownRevision(memberKey)
    local row = self.registry[memberKey]
    return row and (row.rev or 0) or 0
end

function Sync:GetManifestCatchupOutstandingCost()
    local owners = 0
    local blocks = 0
    for _, request in pairs(self.pendingRequests or {}) do
        owners = owners + 1
        local requestedBlocks = request and request.requestedBlocks or nil
        blocks = blocks + math.max(1, #(requestedBlocks or {}))
    end
    for _, request in pairs(self:GetInFlightRequests()) do
        owners = owners + 1
        blocks = blocks + math.max(1, #(request.requestedBlocks or {}))
    end
    return owners, blocks
end

function Sync:ShouldDeferManifestCatchup()
    if self:IsInWarmup() then
        return "warmup", max(MANIFEST_CATCHUP_DRAIN_DELAY, self:GetWarmupRemaining())
    end
    if self:IsInWorldTransition() then
        return "world-transition", max(MANIFEST_CATCHUP_DRAIN_DELAY, self:GetWorldTransitionRemaining())
    end
    if #(self.outboundChunkQueue or {}) > 8 or #(self.manifestChunkQueue or {}) > 8 then
        return "outbound-busy", 0.5
    end
    if #self.inboundChunkQueue > 10 or #self.inboundFinalizeQueue > 4 then
        return "inbound-busy", 0.5
    end
    local ownersQueued = self:GetManifestCatchupOutstandingCost()
    if ownersQueued >= MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH then
        return "request-cap", 0.35
    end
    return nil, MANIFEST_CATCHUP_DRAIN_DELAY
end

function Sync:AutoSyncTick()
    if not IsInGuild() then return end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("REQ") then
        self.telemetry.pausedSyncCycles = self.telemetry.pausedSyncCycles + 1
        return
    end
    if self:IsInWorldTransition() then
        self.telemetry.transitionDeferrals = (self.telemetry.transitionDeferrals or 0) + 1
        self:EstimateRuntimeQueuePressure()
        return
    end

    if countKeys(self.onlineNodes) == 0 then
        if (time() - (self.lastHelloAt or 0)) > 10 then
            self:BroadcastHello()
        end
        return
    end

    if self:GetActiveRequestCount() < self:GetMaxConcurrentRequests() and not self:IsInWarmup() then
        for key, hint in pairs(self.registry) do
            if not self:IsMockKey(key) and not self:IsMockKey(hint.owner) then
                local localEntry = Addon.Data:GetMember(key)
                local localRev = localEntry and localEntry.rev or 0
                if (hint.rev or 0) > localRev then
                    self:QueueRequest(hint.owner or key, key, hint.rev or 0, "auto-tick")
                end
            end
        end
    elseif self:IsInWarmup() then
        self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
    end

    if (time() - (self.lastHelloAt or 0)) > HELLO_INTERVAL then
        self:BroadcastHello()
    end
end

function Sync:EnsureBackgroundWorkers()
    if self._workersReady or not Addon.Performance then return end
    self._workersReady = true
    Addon.Performance:ScheduleJob("sync-outbound-loop", function()
        return self:SendNextLowPriorityChunk()
    end, {
        category = "sync-outbound",
        label = "sync-outbound-loop",
        budgetMs = 2,
    })
    Addon.Performance:ScheduleJob("sync-inbound-loop", function()
        return self:ProcessInboundQueue()
    end, {
        category = "sync-inbound",
        label = "sync-inbound-loop",
        budgetMs = 2,
    })
end
