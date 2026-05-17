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
local HELLO_INTERVAL = Constants.HELLO_INTERVAL
local AUTO_SYNC_INTERVAL = Constants.AUTO_SYNC_INTERVAL
local OUTBOUND_PUMP_DELAY = Constants.OUTBOUND_PUMP_DELAY or 0.05
local PEER_BACKOFF_SECONDS = Constants.PEER_BACKOFF_SECONDS or 45
local POST_WORLD_GRACE_SECONDS = Constants.POST_WORLD_GRACE_SECONDS or 12
local POST_INSTANCE_GRACE_SECONDS = Constants.POST_INSTANCE_GRACE_SECONDS or 15
local POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = Constants.POST_RELOAD_IN_INSTANCE_GRACE_SECONDS or 30

local LIFECYCLE_DEBUG_LIMIT = 20
local VERSION_NOTICE_COOLDOWN = 12 * 60 * 60

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

local function summarizeCapabilities(payload)
    local caps = {}
    local source = type(payload) == "table" and payload or {}
    local nested = type(source.capabilities) == "table" and source.capabilities or {}
    if nested.chunkWindow ~= nil then caps.chunkWindow = nested.chunkWindow == true end
    if nested.indexDiffSync ~= nil then caps.indexDiffSync = nested.indexDiffSync == true end
    if nested.blockPullSync ~= nil then caps.blockPullSync = nested.blockPullSync == true end
    if source.chunkWindow ~= nil then caps.chunkWindow = source.chunkWindow == true end
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
        if capsInfo.chunkWindow ~= nil then capabilities.chunkWindow = capsInfo.chunkWindow == true end
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
    self.lifecycleDebugLog = {}
    self.offlineDebugLog = {}
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
    self.telemetry = newSyncTelemetry()
end

function Sync:ResetTelemetry()
    self.telemetry = newSyncTelemetry()
    self.lifecycleDebugLog = {}
    self.offlineDebugLog = {}
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
    self.activeHelloCycle = nil
    self.lastSelectedSeed = nil
    self.outboundSeedSession = nil
    self.helloCycleCounter = 0
    self._seedSessionCounter = 0
    self.warmupUntil = 0
    self.warmupReason = nil
    self.worldTransitionUntil = 0
    self.worldTransitionReason = nil
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
    if self._outboundPumpTimer then
        self:CancelTimer(self._outboundPumpTimer, true)
        self._outboundPumpTimer = nil
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

function Sync:KickoffDatabaseResync()
    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty("database-resync", nil, {
            full = true,
        })
    end
    self:ScheduleHelloCycle("database-resync", 0.5)
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
                if caps.canReceiveReq == false then
                    self:SetPeerIneligibleReason(peerKey, "peer-cannot-receive-req")
                    return false, "peer-cannot-receive-req"
                end
            end
            if purpose == "serve" and caps.canSendSnap == false then
                self:SetPeerIneligibleReason(peerKey, "peer-cannot-send-snap")
                return false, "peer-cannot-send-snap"
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

function Sync:OnGuildRosterUpdate()
    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty("roster-update", nil, {
            full = true,
        })
    end
    self:ScheduleHelloCycle("roster-update", 0.5)
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

function Sync:ScheduleHello(delay)
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        self.telemetry.transitionSkippedHello = (self.telemetry.transitionSkippedHello or 0) + 1
        return
    end
    if self:ShouldDeferHeavyLifecycleWork("hello") then
        return
    end
    if self._helloTimer then
        return
    end
    self._helloTimer = self:ScheduleTimer(function()
        self._helloTimer = nil
        self:BroadcastHello()
    end, delay or 0.5)
end

function Sync:ScheduleHelloCycle(reason, delay)
    self.lastHelloCycleReason = tostring(reason or "unspecified")
    self.lastHelloCycleScheduledAt = time()
    self._pendingHelloCycleReason = self.lastHelloCycleReason
    self:ScheduleHello(delay)
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
    }
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
    self.telemetry.summaryReceived = (self.telemetry.summaryReceived or 0) + 1
    Addon:Trace("sync", string.format(
        "summary-received peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
        tostring(peerKey),
        tostring(payload.helloId or "none"),
        tonumber(payload.activeOwnerCount or 0) or 0,
        tonumber(payload.activeBlockCount or 0) or 0,
        tonumber(payload.activeContentCount or 0) or 0,
        tostring(payload.globalFingerprint or "none")
    ))
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
    }) or nil
    local rows = {}
    for peerKey, summary in pairs(cycle.summaries or {}) do
        if self:IsValidSyncMemberKey(peerKey)
            and type(summary) == "table"
            and tostring(summary.globalFingerprint or "") ~= tostring(localSummary and localSummary.globalFingerprint or "")
        then
            local eligible = self:CanExchangeDataWithPeer(peerKey, "dispatch", {
                source = peerKey,
                memberKey = peerKey,
            })
            if eligible then
                rows[#rows + 1] = summary
            end
        end
    end

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
    if #rows == 0 then
        Addon:Trace("sync", string.format(
            "seed-selection-none helloId=%s reason=no-different-ready-summary",
            tostring(cycle.helloId or "none")
        ))
        return nil
    end

    local selected = rows[1]
    cycle.selectedSeedKey = selected.peerKey
    cycle.selectedSeed = selected
    self.lastSelectedSeed = cloneTable(selected)
    self.telemetry.seedSelected = (self.telemetry.seedSelected or 0) + 1
    self.telemetry.lastSelectedPeer = selected.peerKey
    self.telemetry.lastSelectedReason = "highest-content"
    Addon:Trace("sync", string.format(
        "seed-selected peer=%s reason=highest-content owners=%d blocks=%d content=%d",
        tostring(selected.peerKey),
        tonumber(selected.activeOwnerCount or 0) or 0,
        tonumber(selected.activeBlockCount or 0) or 0,
        tonumber(selected.activeContentCount or 0) or 0
    ))

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
    if Addon.Data and Addon.Data.CommitGlobalFingerprint then
        Addon.Data:CommitGlobalFingerprint("seed-session-abort:" .. session.abortReason)
    end
    self.telemetry.outboundSessionAborted = (self.telemetry.outboundSessionAborted or 0) + 1
    self.telemetry.lastAbortReason = session.abortReason
    Addon:Trace("sync", string.format(
        "session-abort peer=%s reason=%s",
        tostring(session.seedKey or "unknown"),
        tostring(session.abortReason)
    ))
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
    if Addon.Data and Addon.Data.CommitGlobalFingerprint then
        Addon.Data:CommitGlobalFingerprint("seed-session-complete:" .. session.completedReason)
    end
    self.telemetry.outboundSessionCompleted = (self.telemetry.outboundSessionCompleted or 0) + 1
    self.telemetry.lastSessionCompleteReason = session.completedReason
    Addon:Trace("sync", string.format(
        "session-complete peer=%s reason=%s",
        tostring(session.seedKey or "unknown"),
        tostring(session.completedReason)
    ))
    return true
end

function Sync:CanServeInboundSeed(peerKey)
    if not self:IsValidSyncMemberKey(peerKey) then
        return false, "invalid-peer"
    end
    local eligible = self:CanExchangeDataWithPeer(peerKey, "serve", {
        source = peerKey,
        memberKey = peerKey,
    })
    if not eligible then
        return false, "ineligible"
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_SNAPSHOT") then
        return false, "paused"
    end
    if self:EstimateRuntimeQueuePressure() >= 95 then
        return false, "saturated"
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

function Sync:ScheduleOutboundPump(delay)
    if self._outboundPumpTimer then
        return
    end
    self._outboundPumpTimer = self:ScheduleTimer(function()
        self._outboundPumpTimer = nil
        self:SendNextLowPriorityChunk()
        if self:SendNextLowPriorityChunk() then
            self:ScheduleOutboundPump(OUTBOUND_PUMP_DELAY)
        end
    end, delay or OUTBOUND_PUMP_DELAY)
end

function Sync:EnterWarmup(reason, seconds)
    self.warmupReason = tostring(reason or "warmup")
    self.warmupUntil = time() + max(0, tonumber(seconds or POST_WORLD_GRACE_SECONDS) or POST_WORLD_GRACE_SECONDS)
    if self._warmupTimer then
        self:CancelTimer(self._warmupTimer, true)
    end
    self._warmupTimer = self:ScheduleTimer(function()
        self._warmupTimer = nil
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
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer, true)
    end
    self._transitionTimer = self:ScheduleTimer(function()
        self._transitionTimer = nil
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
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("HELLO") then
        self.telemetry.pausedSyncCycles = (self.telemetry.pausedSyncCycles or 0) + 1
        return
    end
    if self:IsInWorldTransition() then
        return
    end
    if countKeys(self.onlineNodes) == 0 then
        if (time() - (self.lastHelloAt or 0)) > 10 then
            self:BroadcastHello()
        end
        return
    end
    if (time() - (self.lastHelloAt or 0)) > HELLO_INTERVAL then
        self:BroadcastHello()
    end
end

function Sync:EnsureBackgroundWorkers()
    if self._workersReady or not Addon.Performance then
        return
    end
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
