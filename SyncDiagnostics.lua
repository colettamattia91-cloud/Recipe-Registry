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
        self.telemetry.pausedSyncCycles = (self.telemetry.pausedSyncCycles or 0) + 1
    end
end

function Sync:RecordMergeSkip(reason)
    if reason == "equivalent" then
        self.telemetry.skippedEquivalentMerges = (self.telemetry.skippedEquivalentMerges or 0) + 1
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

function Sync:GetRuntimeObservabilitySnapshot()
    local indexDebug = Addon.Data and Addon.Data.GetSyncIndexDebugState and Addon.Data:GetSyncIndexDebugState() or {}
    local cycle = self.activeHelloCycle or {}
    local session = self.outboundSeedSession or {}
    return {
        transitionActive = self.IsInWorldTransition and self:IsInWorldTransition() or false,
        transitionReason = self.worldTransitionReason,
        transitionRemaining = self.GetWorldTransitionRemaining and self:GetWorldTransitionRemaining() or 0,
        runtimeQueuePressure = self.telemetry and self.telemetry.runtimeQueuePressure or 0,
        indexReady = indexDebug.indexReady == true,
        indexStatus = indexDebug.indexStatus,
        trustedRoster = indexDebug.trustedRoster == true,
        trustedRosterReason = indexDebug.trustedRosterReason,
        localSummary = {
            syncModel = indexDebug.syncModel,
            activeOwnerCount = indexDebug.activeOwnerCount or 0,
            activeBlockCount = indexDebug.activeBlockCount or 0,
            activeContentCount = indexDebug.activeContentCount or 0,
            globalFingerprint = indexDebug.globalFingerprint,
            globalFingerprintDirty = indexDebug.globalFingerprintDirty == true,
        },
        cache = indexDebug.cache or {},
        activeHelloId = cycle.helloId,
        selectedSeedKey = cycle.selectedSeedKey or self.lastSelectedSeed and self.lastSelectedSeed.peerKey or nil,
        outboundSession = {
            sessionId = session.sessionId,
            state = session.state,
            seedKey = session.seedKey,
            diffRequestId = session.diffRequestId,
            activeBlockKey = session.activeBlockKey,
            wantedBlocks = #(session.wantedBlocks or {}),
            nextWantedIndex = session.nextWantedIndex or 1,
            startedAt = session.startedAt or 0,
            lastProgressAt = session.lastProgressAt or 0,
            abortReason = session.abortReason,
            completedReason = session.completedReason,
        },
    }
end

function Sync:GetUiState()
    local pauseState = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false
    local bootstrapState = Addon.BootstrapSync and Addon.BootstrapSync:GetUiState() or nil
    local runtime = self:GetRuntimeObservabilitySnapshot()
    return {
        role = "IndexDiffBlockPullClient",
        onlineNodes = countKeys(self.onlineNodes),
        queued = 0,
        activeRequests = self:GetActiveRequestCount(),
        inFlight = nil,
        outgoing = 0,
        autoSync = true,
        paused = pauseState,
        warmup = self:IsInWarmup(),
        transition = runtime.transitionActive,
        transitionRemaining = runtime.transitionRemaining,
        bootstrap = bootstrapState,
        indexReady = runtime.indexReady,
        indexStatus = runtime.indexStatus,
        trustedRoster = runtime.trustedRoster,
        trustedRosterReason = runtime.trustedRosterReason,
        localSummary = runtime.localSummary,
        selectedSeedKey = runtime.selectedSeedKey,
        outboundSession = runtime.outboundSession,
        telemetry = self.telemetry,
    }
end

function Sync:GetDebugSnapshot()
    local backoffCount, backoffList = self:GetPeerBackoffSummary(3)
    local runtime = self:GetRuntimeObservabilitySnapshot()
    return {
        onlineNodes = countKeys(self.onlineNodes),
        pendingRequests = 0,
        activeRequests = self:GetActiveRequestCount(),
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
        indexReady = runtime.indexReady,
        indexStatus = runtime.indexStatus,
        trustedRoster = runtime.trustedRoster,
        trustedRosterReason = runtime.trustedRosterReason,
        localSummary = runtime.localSummary,
        cache = runtime.cache,
        selectedSeedKey = runtime.selectedSeedKey,
        outboundSession = runtime.outboundSession,
        telemetry = self.telemetry,
        lifecycleDebugLog = shallowCopyArray(self.lifecycleDebugLog),
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
        "Capabilities: indexDiffSync=%s blockPullSync=%s latestRemoteVersionSeen=%s lastNoticedVersion=%s lastUpdateNoticeAt=%s",
        tostring(info.capabilities and info.capabilities.indexDiffSync == true),
        tostring(info.capabilities and info.capabilities.blockPullSync == true),
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
    Addon:SystemPrint(string.format(
        "Offline sync blocks served=%d received=%d merged=%d cacheHit=%d cacheMiss=%d",
        t.blockSnapshotSent or 0,
        t.blockSnapshotReceived or 0,
        t.blockMergedImmediate or 0,
        t.syncIndexCacheHit or 0,
        t.syncIndexCacheMiss or 0
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
    local removedOnlineNodes = 0
    for key in pairs(self.onlineNodes or {}) do
        if self:IsMockKey(key) then
            self.onlineNodes[key] = nil
            self.peerCaps[key] = nil
            self.peerVersions[key] = nil
            self.peerBackoffUntil[key] = nil
            self.peerHealth[key] = nil
            removedOnlineNodes = removedOnlineNodes + 1
        end
    end
    if self:IsMockKey(self.outboundSeedSession and self.outboundSeedSession.seedKey) then
        self.outboundSeedSession = nil
    end
    Addon:RequestRefresh("mock-cleanup")
    return 0, removedOnlineNodes, 0
end

function Sync:CleanCorruptState(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local stats = {
        removed = 0,
        onlineNodes = 0,
        peerVersions = 0,
        peerCaps = 0,
        peerBackoff = 0,
    }

    local function drop(tbl, key, field)
        stats.removed = stats.removed + 1
        stats[field] = (stats[field] or 0) + 1
        if not dryRun then
            tbl[key] = nil
        end
    end

    for key in pairs(self.onlineNodes or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.onlineNodes, key, "onlineNodes")
        end
    end
    for key in pairs(self.peerVersions or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.peerVersions, key, "peerVersions")
        end
    end
    for key in pairs(self.peerCaps or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.peerCaps, key, "peerCaps")
        end
    end
    for key in pairs(self.peerBackoffUntil or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.peerBackoffUntil, key, "peerBackoff")
        end
    end

    if stats.removed > 0 and not dryRun then
        Addon:RequestRefresh("clean-sync")
    end
    return stats
end

function Sync:DumpStatus()
    local backoffCount, backoffList = self:GetPeerBackoffSummary(3)
    local runtime = self:GetRuntimeObservabilitySnapshot()
    local eligibility = self:GetPeerEligibilityBreakdown() or {}
    local localVersion = self:GetLocalVersionInfo()
    local tel = self.telemetry or {}
    Addon:Print(string.format(
        "Role=Client onlineNodes=%d queued=%d activeReq=%d paused=%s warmup=%s transition=%s(%ds) isolated=%s channel=%s prefix=%s wire=%s",
        countKeys(self.onlineNodes),
        0,
        self:GetActiveRequestCount(),
        tostring(Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false),
        tostring(self:IsInWarmup()),
        tostring(runtime.transitionActive or false),
        runtime.transitionRemaining or 0,
        tostring(self:IsRealTrafficSuppressed()),
        tostring(localVersion.buildChannel or "release"),
        tostring(localVersion.commPrefix or Addon.ADDON_PREFIX or "?"),
        tostring(localVersion.wireVersion or "?")
    ))
    Addon:Print(string.format(
        "HELLO/SUMMARY helloSent=%d summarySent=%d summaryReceived=%d seedSelected=%d selectedPeer=%s selectedReason=%s",
        tel.helloSent or 0,
        tel.summarySent or 0,
        tel.summaryReceived or 0,
        tel.seedSelected or 0,
        tostring(tel.lastSelectedPeer or "none"),
        tostring(tel.lastSelectedReason or "none")
    ))
    Addon:Print(string.format(
        "INDEX_DIFF reqSent=%d reqRecv=%d respSent=%d respRecv=%d offered=%d reasons=%s",
        tel.indexDiffRequestSent or 0,
        tel.indexDiffRequestReceived or 0,
        tel.indexDiffResponseSent or 0,
        tel.indexDiffResponseReceived or 0,
        tel.blocksOffered or 0,
        tostring(tel.lastBlockOfferReasons or "none")
    ))
    Addon:Print(string.format(
        "BLOCK_PULL sent=%d started=%d delayed=%d snapSent=%d snapRecv=%d merged=%d recomputed=%d lastBlock=%s lastFingerprint=%s",
        tel.blockPullRequestSent or 0,
        tel.blockPullStarted or 0,
        tel.blockPullDelayed or 0,
        tel.blockSnapshotSent or 0,
        tel.blockSnapshotReceived or 0,
        tel.blockMergedImmediate or 0,
        tel.blockFingerprintRecomputed or 0,
        tostring(tel.lastMergedBlockKey or "none"),
        tostring(tel.lastMergedBlockFingerprint or "none")
    ))
    Addon:Print(string.format(
        "Cache hit=%d miss=%d blockRebuilt=%d fullRebuild=%d globalRecomputed=%d dirtyBlocks=%d ready=%s status=%s trustedRoster=%s reason=%s",
        tel.syncIndexCacheHit or 0,
        tel.syncIndexCacheMiss or 0,
        tel.syncIndexBlockRebuilt or 0,
        tel.syncIndexFullRebuild or 0,
        tel.syncIndexGlobalRecomputed or 0,
        tel.syncIndexDirtyBlockCount or 0,
        tostring(runtime.indexReady),
        tostring(runtime.indexStatus or "unknown"),
        tostring(runtime.trustedRoster),
        tostring(runtime.trustedRosterReason or "unknown")
    ))
    Addon:Print(string.format(
        "Session state=%s seed=%s wanted=%d next=%d abort=%s complete=%s globalDirty=%s globalFingerprint=%s",
        tostring(runtime.outboundSession.state or "idle"),
        tostring(runtime.outboundSession.seedKey or "none"),
        runtime.outboundSession.wantedBlocks or 0,
        runtime.outboundSession.nextWantedIndex or 1,
        tostring(runtime.outboundSession.abortReason or "none"),
        tostring(runtime.outboundSession.completedReason or "none"),
        tostring(runtime.localSummary.globalFingerprintDirty or false),
        tostring(runtime.localSummary.globalFingerprint or "none")
    ))
    Addon:Print(string.format(
        "Version peers=%d eligible=%d ineligible=%d channelDrops=%d versionSkips=%d capSkips=%d newerVersionSeen=%d newerProtocolSeen=%d backoff=%d [%s]",
        countKeys(self.peerVersions),
        eligibility.eligible or 0,
        eligibility.ineligible or 0,
        tel.buildChannelDrops or 0,
        tel.skippedVersionIncompatible or 0,
        tel.skippedMissingCapability or 0,
        tel.newerVersionSeen or 0,
        tel.newerProtocolSeen or 0,
        backoffCount or 0,
        backoffList or "none"
    ))
end
