local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private

local time = time
local pairs = pairs
local sort = table.sort
local min = math.min
local max = math.max

local countKeys = Private.countKeys
local shallowCopyArray = Private.shallowCopyArray

function Sync:RecordPauseCycle(paused)
    if paused then
        self.telemetry.pausedSyncCycles = self.telemetry.pausedSyncCycles + 1
    end
end

function Sync:RecordMergeSkip(reason)
    if reason == "equivalent" then
        self.telemetry.skippedEquivalentMerges = self.telemetry.skippedEquivalentMerges + 1
    end
end

function Sync:GetPeerBackoffSummary(limit)
    limit = limit or 3
    local rows = {}
    for peerKey, untilAt in pairs(self.peerBackoffUntil or {}) do
        if untilAt and untilAt > time() then
            rows[#rows + 1] = {
                peerKey = peerKey,
                remaining = untilAt - time(),
            }
        end
    end
    sort(rows, function(a, b)
        if a.remaining ~= b.remaining then
            return a.remaining > b.remaining
        end
        return tostring(a.peerKey) < tostring(b.peerKey)
    end)

    local parts = {}
    for index = 1, min(limit, #rows) do
        parts[#parts + 1] = string.format("%s(%ds)", tostring(rows[index].peerKey), max(0, math.floor(rows[index].remaining)))
    end
    return #rows, (#parts > 0 and table.concat(parts, ", ") or "none")
end

local function getOldestStateAge(states, fieldName)
    local oldestAge = 0
    local now = time()
    for _, state in pairs(states or {}) do
        if type(state) == "table" then
            local stamp = tonumber(state[fieldName] or 0) or 0
            if stamp > 0 then
                oldestAge = max(oldestAge, max(0, now - stamp))
            end
        end
    end
    return oldestAge
end

local function getNestedStateSummary(groups, fieldName)
    local parentCount = 0
    local totalCount = 0
    local oldestAge = 0
    local now = time()

    for _, bucket in pairs(groups or {}) do
        if type(bucket) == "table" then
            local bucketCount = 0
            for _, state in pairs(bucket) do
                bucketCount = bucketCount + 1
                totalCount = totalCount + 1
                if type(state) == "table" then
                    local stamp = tonumber(state[fieldName] or 0) or 0
                    if stamp > 0 then
                        oldestAge = max(oldestAge, max(0, now - stamp))
                    end
                end
            end
            if bucketCount > 0 then
                parentCount = parentCount + 1
            end
        end
    end

    return parentCount, totalCount, oldestAge
end

local function getTrickleRuntimeSummary()
    local trickle = Addon.TrickleSync
    local summary = {
        peerState = 0,
        residentManifests = 0,
        queuedPeers = 0,
        queuedBlocks = 0,
        maxQueuedBlocks = 0,
        oldestManifestAge = 0,
        queueCapHits = 0,
        queueCapDrops = 0,
    }
    if not trickle then
        return summary
    end

    local now = time()
    for _, state in pairs(trickle.peerState or {}) do
        summary.peerState = summary.peerState + 1
        if type(state) == "table" and type(state.manifest) == "table" then
            summary.residentManifests = summary.residentManifests + 1
            local stamp = tonumber(state.lastManifestAt or 0) or 0
            if stamp > 0 then
                summary.oldestManifestAge = max(summary.oldestManifestAge, max(0, now - stamp))
            end
        end
    end

    for _, queue in pairs(trickle.outboundQueue or {}) do
        local depth = #(queue or {})
        if depth > 0 then
            summary.queuedPeers = summary.queuedPeers + 1
            summary.queuedBlocks = summary.queuedBlocks + depth
            summary.maxQueuedBlocks = max(summary.maxQueuedBlocks, depth)
        end
    end

    local telemetry = trickle.GetManifestChunkTelemetry and trickle:GetManifestChunkTelemetry() or trickle.telemetry or {}
    summary.queueCapHits = telemetry.queueCapHits or 0
    summary.queueCapDrops = telemetry.queueCapDrops or 0

    return summary
end

function Sync:GetRuntimeObservabilitySnapshot()
    local partialManifestPeers, partialManifestOpen, partialManifestOldestAge = getNestedStateSummary(self.partialManifestReceive, "builtAt")
    local trickle = getTrickleRuntimeSummary()
    local manifestDebug = Addon.Data and Addon.Data.GetManifestDebugSnapshot and Addon.Data:GetManifestDebugSnapshot() or nil
    local manifestTelemetry = manifestDebug and manifestDebug.telemetry or {}

    return {
        partialReceives = countKeys(self.partialReceive),
        partialReceiveOldestAge = getOldestStateAge(self.partialReceive, "lastProgressAt"),
        outgoingOldestAge = getOldestStateAge(self.outgoingSessions, "createdAt"),
        transitionActive = self.IsInWorldTransition and self:IsInWorldTransition() or false,
        transitionReason = self.worldTransitionReason,
        transitionRemaining = self.GetWorldTransitionRemaining and self:GetWorldTransitionRemaining() or 0,
        transitionQueued = #(self.transitionDrainQueue or {}),
        partialManifestPeers = partialManifestPeers,
        partialManifestOpen = partialManifestOpen,
        partialManifestOldestAge = partialManifestOldestAge,
        tricklePeerState = trickle.peerState,
        trickleResidentManifests = trickle.residentManifests,
        trickleQueuedPeers = trickle.queuedPeers,
        trickleQueuedBlocks = trickle.queuedBlocks,
        trickleMaxQueuedBlocks = trickle.maxQueuedBlocks,
        trickleOldestManifestAge = trickle.oldestManifestAge,
        trickleQueueCapHits = trickle.queueCapHits,
        trickleQueueCapDrops = trickle.queueCapDrops,
        manifestFallbackBuilds = manifestTelemetry.syncFallbackBuilds or 0,
        manifestFallbackDeferrals = manifestTelemetry.syncFallbackDeferrals or 0,
        manifestDeferredRequests = manifestTelemetry.deferredRequests or 0,
        runtimeQueuePressure = self.telemetry and self.telemetry.runtimeQueuePressure or 0,
    }
end

function Sync:GetUiState()
    local pauseState = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false
    local bootstrapState = Addon.BootstrapSync and Addon.BootstrapSync:GetUiState() or nil
    local runtime = self:GetRuntimeObservabilitySnapshot()
    local primary = self:GetInFlightRequest()
    return {
        role = self:IsCoordinator() and "Coordinator" or "Client",
        coordinatorKey = self.coordinatorKey,
        onlineNodes = countKeys(self.onlineNodes),
        registry = countKeys(self.registry),
        queued = countKeys(self.pendingRequests),
        activeRequests = self:GetActiveRequestCount(),
        inFlight = primary and primary.memberKey or nil,
        outgoing = countKeys(self.outgoingSessions),
        outboundChunks = #self.outboundChunkQueue,
        manifestChunks = #(self.manifestChunkQueue or {}),
        inboundChunks = #self.inboundChunkQueue,
        autoSync = true,
        paused = pauseState,
        warmup = self:IsInWarmup(),
        transition = runtime.transitionActive,
        transitionRemaining = runtime.transitionRemaining,
        bootstrap = bootstrapState,
        partialReceives = runtime.partialReceives,
        partialManifestOpen = runtime.partialManifestOpen,
        trickleQueuedBlocks = runtime.trickleQueuedBlocks,
        telemetry = self.telemetry,
    }
end

function Sync:GetDebugSnapshot()
    local oldestPending = self:GetOldestPendingRequest()
    local backoffCount, backoffList = self:GetPeerBackoffSummary(3)
    local runtime = self:GetRuntimeObservabilitySnapshot()
    local primary = self:GetInFlightRequest()
    return {
        onlineNodes = countKeys(self.onlineNodes),
        registry = countKeys(self.registry),
        pendingRequests = countKeys(self.pendingRequests),
        activeRequests = self:GetActiveRequestCount(),
        outgoingSessions = countKeys(self.outgoingSessions),
        outboundChunks = #self.outboundChunkQueue,
        manifestChunks = #(self.manifestChunkQueue or {}),
        inboundChunks = #self.inboundChunkQueue,
        inboundFinalize = #self.inboundFinalizeQueue,
        inFlight = primary and primary.memberKey or nil,
        paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false,
        warmup = self:IsInWarmup(),
        warmupRemaining = self:GetWarmupRemaining(),
        warmupReason = self.warmupReason,
        transition = runtime.transitionActive,
        transitionRemaining = runtime.transitionRemaining,
        transitionReason = runtime.transitionReason,
        isolated = self:IsRealTrafficSuppressed(),
        peerBackoffCount = backoffCount,
        peerBackoffList = backoffList,
        oldestPendingAge = oldestPending and max(0, time() - (oldestPending.queuedAt or time())) or 0,
        oldestPendingSource = oldestPending and oldestPending.source or nil,
        oldestPendingWhy = oldestPending and oldestPending.why or nil,
        inFlightAge = primary and max(0, time() - (primary.startedAt or time())) or 0,
        inFlightAttempts = primary and (primary.attempts or 0) or 0,
        inFlightSource = primary and primary.source or nil,
        inFlightWhy = primary and primary.why or nil,
        partialReceives = runtime.partialReceives,
        partialReceiveOldestAge = runtime.partialReceiveOldestAge,
        outgoingOldestAge = runtime.outgoingOldestAge,
        partialManifestPeers = runtime.partialManifestPeers,
        partialManifestOpen = runtime.partialManifestOpen,
        partialManifestOldestAge = runtime.partialManifestOldestAge,
        tricklePeerState = runtime.tricklePeerState,
        trickleResidentManifests = runtime.trickleResidentManifests,
        trickleQueuedPeers = runtime.trickleQueuedPeers,
        trickleQueuedBlocks = runtime.trickleQueuedBlocks,
        trickleMaxQueuedBlocks = runtime.trickleMaxQueuedBlocks,
        trickleOldestManifestAge = runtime.trickleOldestManifestAge,
        manifestFallbackBuilds = runtime.manifestFallbackBuilds,
        manifestDeferredRequests = runtime.manifestDeferredRequests,
        lifecycleDebugLog = shallowCopyArray(self.lifecycleDebugLog),
        telemetry = self.telemetry,
        offlineDebugLog = shallowCopyArray(self.offlineDebugLog),
    }
end

function Sync:DumpVersionStatus()
    local info = self:GetLocalVersionInfo()
    local notice = Addon.Data and Addon.Data.GetUpdateNoticeState and Addon.Data:GetUpdateNoticeState() or {}
    Addon:Print(string.format(
        "Recipe Registry: version=%s wire=%s minWire=%s channel=%s prefix=%s build=%s",
        tostring(info.addonVersion or "?"),
        tostring(info.wireVersion or "?"),
        tostring(info.minSupportedWireVersion or info.wireVersion or "?"),
        tostring(info.buildChannel or "release"),
        tostring(info.commPrefix or Addon.ADDON_PREFIX or "?"),
        tostring(info.buildId or "n/a")
    ))
    Addon:Print(string.format(
        "Capabilities: chunkWindow=%s maniReliable=%s snapCodec=%s manifestShards=%s latestRemoteVersionSeen=%s lastNoticedVersion=%s lastUpdateNoticeAt=%s",
        tostring(info.capabilities and info.capabilities.chunkWindow == true),
        tostring(info.capabilities and info.capabilities.maniReliable == true),
        tostring(info.capabilities and info.capabilities.snapCodec == true),
        tostring(info.capabilities and info.capabilities.manifestShards == true),
        tostring(notice.latestRemoteVersionSeen or "none"),
        tostring(notice.lastNoticedVersion or "none"),
        tostring(notice.lastUpdateNoticeAt or 0)
    ))
end

function Sync:DumpPeerVersions()
    self:DumpVersionStatus()

    local rows = {}
    for peerKey, info in pairs(self.peerVersions or {}) do
        if self:IsValidSyncMemberKey(peerKey) then
            rows[#rows + 1] = {
                peerKey = peerKey,
                info = info,
                relation = self:GetPeerVersionRelation(peerKey),
            }
        end
    end
    sort(rows, function(left, right)
        return tostring(left.peerKey) < tostring(right.peerKey)
    end)

    if #rows == 0 then
        Addon:Print("Peers: none")
        return
    end

    Addon:Print("Peers:")
    for _, row in ipairs(rows) do
        local info = row.info or {}
        Addon:Print(string.format(
            "- %s version=%s wire=%s channel=%s status=%s relation=%s ineligible=%s build=%s",
            tostring(row.peerKey),
            tostring(info.addonVersion or "unknown"),
            tostring(info.wireVersion or "unknown"),
            tostring(info.buildChannel or "unknown"),
            tostring(info.compatibility or "unknown"),
            tostring(row.relation or "unknown"),
            tostring(info.ineligibleReason or "none"),
            tostring(info.buildId or "n/a")
        ))
    end
end

function Sync:DumpOfflineSyncStatus()
    local t = self.telemetry or {}
    local runtime = self:GetRuntimeObservabilitySnapshot()
    Addon:SystemPrint(string.format(
        "Offline sync manifests owners=%d blocks=%d queued=%d served=%d applied=%d newOwners=%d",
        t.replicaManifestOwnersSeen or 0,
        t.replicaManifestBlocksSeen or 0,
        t.replicaRequestsQueued or 0,
        t.replicaRequestsServed or 0,
        t.replicaOwnersApplied or 0,
        t.replicaNewOwnersApplied or 0
    ))
    Addon:SystemPrint(string.format(
        "Offline runtime partialPeers=%d partialOpen=%d residentPeers=%d queuedPeers=%d queuedBlocks=%d fallbackBuilds=%d deferred=%d",
        runtime.partialManifestPeers or 0,
        runtime.partialManifestOpen or 0,
        runtime.trickleResidentManifests or 0,
        runtime.trickleQueuedPeers or 0,
        runtime.trickleQueuedBlocks or 0,
        runtime.manifestFallbackBuilds or 0,
        runtime.manifestDeferredRequests or 0
    ))
    if #(self.offlineDebugLog or {}) == 0 then
        Addon:SystemPrint("Offline sync recent: none")
        return
    end
    Addon:SystemPrint("Offline sync recent:")
    for index = 1, #self.offlineDebugLog do
        Addon:SystemPrint("  " .. tostring(self.offlineDebugLog[index]))
    end
end

function Sync:CleanupMockState()
    local removedRegistry = 0
    local removedOnlineNodes = 0
    local removedPendingRequests = 0

    for key, row in pairs(self.registry or {}) do
        if self:IsMockKey(key) or (row and row.isMock) then
            self.registry[key] = nil
            removedRegistry = removedRegistry + 1
        end
    end

    for key in pairs(self.onlineNodes or {}) do
        if self:IsMockKey(key) then
            self.onlineNodes[key] = nil
            removedOnlineNodes = removedOnlineNodes + 1
        end
    end

    for memberKey, info in pairs(self.pendingRequests or {}) do
        if self:IsMockKey(memberKey) or self:IsMockKey(info and info.source) then
            self.pendingRequests[memberKey] = nil
            removedPendingRequests = removedPendingRequests + 1
        end
    end

    for memberKey, info in pairs(self.partialReceive or {}) do
        if self:IsMockKey(memberKey) or self:IsMockKey(info and info.source) then
            self.partialReceive[memberKey] = nil
        end
    end

    for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
        if self:IsMockKey(peerKey) then
            self.partialManifestReceive[peerKey] = nil
        elseif type(manifests) == "table" then
            for manifestId, state in pairs(manifests) do
                if self:IsMockKey(state and state.memberKey) then
                    manifests[manifestId] = nil
                end
            end
            if next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    for peerKey in pairs(self._lastManifestSentAt or {}) do
        if self:IsMockKey(peerKey) then
            self._lastManifestSentAt[peerKey] = nil
        end
    end
    for peerKey in pairs(self._lastManifestAnnouncedId or {}) do
        if self:IsMockKey(peerKey) then
            self._lastManifestAnnouncedId[peerKey] = nil
        end
    end
    for peerKey in pairs(self._helloManifestRefreshRequested or {}) do
        if self:IsMockKey(peerKey) then
            self._helloManifestRefreshRequested[peerKey] = nil
        end
    end
    for peerKey in pairs(self._lastManifestReceivedAt or {}) do
        if self:IsMockKey(peerKey) then
            self._lastManifestReceivedAt[peerKey] = nil
        end
    end
    for peerKey in pairs(self._pendingManifestComparePeers or {}) do
        if self:IsMockKey(peerKey) then
            self._pendingManifestComparePeers[peerKey] = nil
        end
    end

    for sessionId, state in pairs(self.outgoingSessions or {}) do
        if self:IsMockKey(state and state.memberKey) or self:IsMockKey(state and state.targetKey) then
            self.outgoingSessions[sessionId] = nil
        end
    end

    local keptOutbound = {}
    for index = 1, #(self.outboundChunkQueue or {}) do
        local item = self.outboundChunkQueue[index]
        if not self:IsMockKey(item and item.peer) and not self:IsMockKey(item and item.block and item.block.key) then
            keptOutbound[#keptOutbound + 1] = item
        end
    end
    self.outboundChunkQueue = keptOutbound

    local keptManifest = {}
    for index = 1, #(self.manifestChunkQueue or {}) do
        local item = self.manifestChunkQueue[index]
        if not self:IsMockKey(item and item.peer) and not self:IsMockKey(item and item.payload and item.payload.memberKey) then
            keptManifest[#keptManifest + 1] = item
        end
    end
    self.manifestChunkQueue = keptManifest

    local keptCatchup = {}
    for index = 1, #(self.manifestCatchupQueue or {}) do
        local item = self.manifestCatchupQueue[index]
        if not self:IsMockKey(item and item.senderKey) and not self:IsMockKey(item and item.ownerCharacter) then
            keptCatchup[#keptCatchup + 1] = item
        end
    end
    self.manifestCatchupQueue = keptCatchup

    local keptInbound = {}
    for index = 1, #(self.inboundChunkQueue or {}) do
        local item = self.inboundChunkQueue[index]
        if not self:IsMockKey(item and item.key) and not self:IsMockKey(item and item.sender) then
            keptInbound[#keptInbound + 1] = item
        end
    end
    self.inboundChunkQueue = keptInbound

    local keptFinalize = {}
    for index = 1, #(self.inboundFinalizeQueue or {}) do
        local item = self.inboundFinalizeQueue[index]
        if not self:IsMockKey(item and item.memberKey) and not self:IsMockKey(item and item.sender) then
            keptFinalize[#keptFinalize + 1] = item
        end
    end
    self.inboundFinalizeQueue = keptFinalize

    for memberKey, request in pairs(self:GetInFlightRequests()) do
        if self:IsMockKey(memberKey) or self:IsMockKey(request and request.source) then
            self:ClearInFlightRequest(memberKey)
        end
    end

    self:RecomputeCoordinator()
    Addon:RequestRefresh("mock-cleanup")
    return removedRegistry, removedOnlineNodes, removedPendingRequests
end

function Sync:CleanCorruptState(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local stats = {
        removed = 0,
        registry = 0,
        onlineNodes = 0,
        pendingRequests = 0,
        partialReceives = 0,
        outgoingSessions = 0,
        queues = 0,
        inFlight = 0,
    }

    local function drop(tbl, key, field)
        stats.removed = stats.removed + 1
        stats[field] = (stats[field] or 0) + 1
        if not dryRun then
            tbl[key] = nil
        end
    end

    for key, row in pairs(self.registry or {}) do
        if not self:IsValidSyncMemberKey(key) or (row and row.owner and not self:IsValidSyncMemberKey(row.owner)) then
            drop(self.registry, key, "registry")
        end
    end

    for key in pairs(self.onlineNodes or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.onlineNodes, key, "onlineNodes")
        end
    end

    for memberKey, info in pairs(self.pendingRequests or {}) do
        if not self:IsRequestShapeValid(info) then
            drop(self.pendingRequests, memberKey, "pendingRequests")
        end
    end

    for memberKey, info in pairs(self.partialReceive or {}) do
        if not self:IsValidSyncMemberKey(memberKey)
            or (info and info.source and not self:IsValidSyncMemberKey(info.source)) then
            drop(self.partialReceive, memberKey, "partialReceives")
        end
    end

    for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
        if not self:IsValidSyncMemberKey(peerKey) then
            drop(self.partialManifestReceive, peerKey, "partialReceives")
        elseif type(manifests) == "table" then
            for manifestId, state in pairs(manifests) do
                if state and state.memberKey and not self:IsValidSyncMemberKey(state.memberKey) then
                    stats.removed = stats.removed + 1
                    stats.partialReceives = stats.partialReceives + 1
                    if not dryRun then
                        manifests[manifestId] = nil
                    end
                end
            end
            if not dryRun and next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    for key in pairs(self._lastManifestSentAt or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._lastManifestSentAt, key, "queues")
        end
    end
    for key in pairs(self._lastManifestAnnouncedId or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._lastManifestAnnouncedId, key, "queues")
        end
    end
    for key in pairs(self._helloManifestRefreshRequested or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._helloManifestRefreshRequested, key, "queues")
        end
    end
    for key in pairs(self._lastManifestReceivedAt or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._lastManifestReceivedAt, key, "queues")
        end
    end
    for key in pairs(self.pendingManifestPeers or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.pendingManifestPeers, key, "queues")
        end
    end
    for key in pairs(self._pendingManifestComparePeers or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._pendingManifestComparePeers, key, "queues")
        end
    end
    for key in pairs(self.peerPacing or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.peerPacing, key, "queues")
        end
    end

    for sessionId, state in pairs(self.outgoingSessions or {}) do
        if not self:IsValidSyncMemberKey(state and state.memberKey)
            or not self:IsValidSyncMemberKey(state and state.targetKey) then
            drop(self.outgoingSessions, sessionId, "outgoingSessions")
        end
    end

    local function keepQueue(src, validFn)
        local kept = {}
        for index = 1, #(src or {}) do
            local item = src[index]
            if validFn(item) then
                kept[#kept + 1] = item
            else
                stats.removed = stats.removed + 1
                stats.queues = stats.queues + 1
            end
        end
        return kept
    end

    if not dryRun then
        self.outboundChunkQueue = keepQueue(self.outboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.block and item.block.key)
        end)
        self.manifestChunkQueue = keepQueue(self.manifestChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.payload and item.payload.memberKey)
        end)
        self.manifestCatchupQueue = keepQueue(self.manifestCatchupQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.senderKey)
                and self:IsValidSyncMemberKey(item and item.ownerCharacter)
        end)
        self.inboundChunkQueue = keepQueue(self.inboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.key)
                and self:IsValidSyncMemberKey(item and item.sender)
        end)
        self.inboundFinalizeQueue = keepQueue(self.inboundFinalizeQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.memberKey)
                and (not item.sender or self:IsValidSyncMemberKey(item.sender))
        end)
    else
        keepQueue(self.outboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.block and item.block.key)
        end)
        keepQueue(self.manifestChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.payload and item.payload.memberKey)
        end)
        keepQueue(self.manifestCatchupQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.senderKey)
                and self:IsValidSyncMemberKey(item and item.ownerCharacter)
        end)
        keepQueue(self.inboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.key)
                and self:IsValidSyncMemberKey(item and item.sender)
        end)
        keepQueue(self.inboundFinalizeQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.memberKey)
                and (not item.sender or self:IsValidSyncMemberKey(item.sender))
        end)
    end

    for memberKey, request in pairs(self:GetInFlightRequests()) do
        if not self:IsRequestShapeValid(request) then
            stats.removed = stats.removed + 1
            stats.inFlight = stats.inFlight + 1
            if not dryRun then
                self:ClearInFlightRequest(memberKey)
            end
        end
    end

    if stats.removed > 0 and not dryRun then
        self:RecomputeCoordinator()
        Addon:RequestRefresh("clean-sync")
    end
    return stats
end

function Sync:DumpStatus()
    local oldestPending = self:GetOldestPendingRequest()
    local backoffCount, backoffList = self:GetPeerBackoffSummary(3)
    local role = self:IsCoordinator() and "Coordinator" or "Client"
    local runtime = self:GetRuntimeObservabilitySnapshot()
    local primary = self:GetInFlightRequest()
    local eligibility = self.GetPeerEligibilityBreakdown and self:GetPeerEligibilityBreakdown() or {}
    local localVersion = self:GetLocalVersionInfo()
    Addon:Print(string.format(
        "Role=%s coordinator=%s onlineNodes=%d registry=%d queued=%d activeReq=%d inFlight=%s outgoing=%d outboundChunks=%d manifestChunks=%d inboundChunks=%d manifestPending=%d paused=%s warmup=%s transition=%s(%ds) isolated=%s channel=%s prefix=%s wire=%s",
        role,
        tostring(self.coordinatorKey),
        countKeys(self.onlineNodes),
        countKeys(self.registry),
        countKeys(self.pendingRequests),
        self:GetActiveRequestCount(),
        primary and primary.memberKey or "none",
        countKeys(self.outgoingSessions),
        #self.outboundChunkQueue,
        #(self.manifestChunkQueue or {}),
        #self.inboundChunkQueue,
        countKeys(self.pendingManifestPeers),
        tostring(Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false),
        tostring(self:IsInWarmup()),
        tostring(runtime.transitionActive or false),
        runtime.transitionRemaining or 0,
        tostring(self:IsRealTrafficSuppressed()),
        tostring(localVersion.buildChannel or "release"),
        tostring(localVersion.commPrefix or Addon.ADDON_PREFIX or "?"),
        tostring(localVersion.wireVersion or "?")
    ))
    local tel = self.telemetry or {}
    Addon:Print(string.format(
        "Manifest requests=%d sent=%d received=%d queued=%d cooldownSkips=%d unchangedSkips=%d identicalSkips=%d forceReplies=%d deferred=%d flushes=%d maxQueue=%d catchupCandidates=%d catchupQueued=%d catchupDeferred=%d catchupDrained=%d catchupSkipOnline=%d catchupSkipStale=%d catchupQueue=%d catchupMax=%d avoided=%d",
        tel.manifestBuildRequests or 0,
        tel.manifestChunksSent or 0,
        tel.manifestChunksReceived or 0,
        tel.manifestChunksQueued or 0,
        tel.manifestCooldownSkips or 0,
        tel.manifestUnchangedSkips or 0,
        tel.manifestIdenticalBlockSkips or 0,
        tel.manifestForceReplies or 0,
        tel.manifestDeferredSends or 0,
        tel.manifestPendingFlushes or 0,
        tel.manifestQueueMaxDepth or 0,
        tel.manifestCatchupCandidates or 0,
        tel.manifestCatchupQueued or 0,
        tel.manifestCatchupDeferred or 0,
        tel.manifestCatchupDrained or 0,
        tel.manifestCatchupSkippedOnlineOwners or 0,
        tel.manifestCatchupSkippedStaleOwners or 0,
        #(self.manifestCatchupQueue or {}),
        tel.manifestCatchupMaxDeferred or 0,
        tel.manifestRequestsAvoided or 0
    ))
    Addon:Print(string.format(
        "Manifest recovery=%d timeouts=%d prunes=%d recovered=%d completed=%d compareFired=%d sendFailures=%d sendRetries=%d coalesced=%d superseded=%d lastPrune=%s lastRecovery=%s/%s",
        tel.manifestRecoveryRequests or 0,
        tel.manifestPartialTimeouts or 0,
        tel.manifestPartialPrunes or 0,
        tel.manifestPartialRecovered or 0,
        tel.manifestReceiveCompleted or 0,
        tel.manifestCompareFired or 0,
        tel.manifestChunkSendFailures or 0,
        tel.manifestChunkSendRetries or 0,
        tel.manifestChunkBatchesCoalesced or 0,
        tel.manifestSuperseded or 0,
        tostring(tel.lastManifestPruneReason or "none"),
        tostring(tel.lastManifestRecoveryPeer or "none"),
        tostring(tel.lastManifestRecoveryId or "none")
    ))
    Addon:Print(string.format(
        "Requests oldestAge=%ds oldestSource=%s oldestWhy=%s activeReq=%d/%d inFlightAge=%ds inFlightAttempts=%d inFlightSource=%s inFlightWhy=%s requestId=%s peerBackoff=%d [%s] retries=%d drops=%d initialTO=%d progressTO=%d sessionTO=%d rejects=%d lastReject=%s/%s warmupDefers=%d transitionDefers=%d skippedHello=%d",
        oldestPending and max(0, time() - (oldestPending.queuedAt or time())) or 0,
        oldestPending and tostring(oldestPending.source) or "none",
        oldestPending and tostring(oldestPending.why or "") or "none",
        self:GetActiveRequestCount(),
        self:GetMaxConcurrentRequests(),
        primary and max(0, time() - (primary.startedAt or time())) or 0,
        primary and (primary.attempts or 0) or 0,
        primary and tostring(primary.source or "none") or "none",
        primary and tostring(primary.why or "") or "none",
        primary and tostring(primary.requestId or "none") or "none",
        backoffCount or 0,
        backoffList or "none",
        tel.requestRetries or 0,
        tel.requestDrops or 0,
        tel.requestTimeoutInitial or 0,
        tel.requestTimeoutProgress or 0,
        tel.requestTimeoutSession or 0,
        tel.rejectsTotal or 0,
        tostring(tel.lastRejectPeer or "none"),
        tostring(tel.lastRejectReason or "none"),
        tel.warmupDeferrals or 0,
        tel.transitionDeferrals or 0,
        tel.transitionSkippedHello or 0
    ))
    Addon:Print(string.format(
        "Peer health eligible=%d ineligible=%d manifestHealthy=%d snapshotHealthy=%d manifestOnly=%d skippedNotEligible=%d queuedBackoff=%d purgedBackoff=%d deferredBackoff=%d",
        eligibility.eligible or 0,
        eligibility.ineligible or 0,
        eligibility.manifestHealthy or 0,
        eligibility.snapshotHealthy or 0,
        eligibility.manifestOnly or 0,
        tel.skippedNotDataEligible or 0,
        tel.queuedBackoff or 0,
        tel.purgedBackoffRequests or 0,
        tel.deferredBackoffRequests or 0
    ))
    Addon:Print(string.format(
        "Version peers=%d channelDrops=%d ignoredPeers=%d ineligible=%d skippedVersion=%d skippedCapability=%d newerVersionSeen=%d newerProtocolSeen=%d activeCommPrefix=%s latestRemoteVersionSeen=%s lastNotice=%s/%s lastDrop=%s/%s/%s",
        countKeys(self.peerVersions),
        tel.buildChannelDrops or 0,
        tel.ignoredBuildChannelPeers or 0,
        tel.versionIneligiblePeers or 0,
        tel.skippedVersionIncompatible or 0,
        tel.skippedMissingCapability or 0,
        tel.newerVersionSeen or 0,
        tel.newerProtocolSeen or 0,
        tostring(tel.activeCommPrefix or Addon.ADDON_PREFIX or "unknown"),
        tostring(tel.latestRemoteVersionSeen or "none"),
        tostring(tel.lastVersionNoticePeer or "none"),
        tostring(tel.lastVersionNoticeRemote or "none"),
        tostring(tel.lastBuildChannelDropPeer or "none"),
        tostring(tel.lastBuildChannelDropRemote or "none"),
        tostring(tel.lastBuildChannelDropReason or "none")
    ))
    Addon:Print(string.format(
        "Runtime partialRecv=%d partialAge=%ds partialManifestPeers=%d partialManifestOpen=%d partialManifestAge=%ds transitionQueue=%d pressure=%d tricklePeers=%d residentPeers=%d queuedPeers=%d queuedBlocks=%d maxPeerQueue=%d queueCap=%d/%d outgoingAge=%ds prunes=out:%d part:%d mani:%d partialManifest:%d trickle:%d/%d runtimeCap=%d fallbackBuilds=%d fallbackDefers=%d deferredManifest=%d",
        runtime.partialReceives or 0,
        runtime.partialReceiveOldestAge or 0,
        runtime.partialManifestPeers or 0,
        runtime.partialManifestOpen or 0,
        runtime.partialManifestOldestAge or 0,
        runtime.transitionQueued or 0,
        runtime.runtimeQueuePressure or 0,
        runtime.tricklePeerState or 0,
        runtime.trickleResidentManifests or 0,
        runtime.trickleQueuedPeers or 0,
        runtime.trickleQueuedBlocks or 0,
        runtime.trickleMaxQueuedBlocks or 0,
        runtime.trickleQueueCapHits or 0,
        runtime.trickleQueueCapDrops or 0,
        runtime.outgoingOldestAge or 0,
        tel.prunedOutgoingSessions or 0,
        tel.prunedPartialReceives or 0,
        tel.prunedPartialManifestReceives or 0,
        tel.partialManifestPruned or 0,
        tel.prunedTricklePeerState or 0,
        tel.prunedTrickleOutboundQueues or 0,
        tel.queueCapPrunes or 0,
        runtime.manifestFallbackBuilds or 0,
        runtime.manifestFallbackDeferrals or 0,
        runtime.manifestDeferredRequests or 0
    ))
    local rawBytes = tel.snapCodecRawBytes or 0
    local encodedBytes = tel.snapCodecEncodedBytes or 0
    local ratio = encodedBytes > 0 and (rawBytes / encodedBytes) or 0
    local codecEnabled = self.IsSnapshotCodecEnabled and self:IsSnapshotCodecEnabled() or false
    local codecSupported = self.GetSnapshotCodecSupport and self:GetSnapshotCodecSupport() ~= nil or false
    local codecErrors = (tel.snapCodecFallbackNoLib or 0)
        + (tel.snapCodecCompressErrors or 0)
        + (tel.snapCodecEncodeErrors or 0)
        + (tel.snapCodecDecodeNoLib or 0)
        + (tel.snapCodecDecodeErrors or 0)
        + (tel.snapCodecDecompressErrors or 0)
        + (tel.snapCodecDeserializeErrors or 0)
        + (tel.snapCodecDropped or 0)
    Addon:Print(string.format(
        "Snapshot codec enabled=%s supported=%s encoded=%d decoded=%d skippedSmall=%d noPeerCap=%d rawKB=%.1f encodedKB=%.1f ratio=%.2f maxEncMs=%.2f maxDecMs=%.2f errors=%d",
        tostring(codecEnabled),
        tostring(codecSupported),
        tel.snapCodecEncoded or 0,
        tel.snapCodecDecoded or 0,
        tel.snapCodecSkippedSmall or 0,
        tel.snapCodecFallbackNoPeerCap or 0,
        rawBytes / 1024,
        encodedBytes / 1024,
        ratio,
        tel.snapCodecMaxEncodeMs or 0,
        tel.snapCodecMaxDecodeMs or 0,
        codecErrors
    ))
end
