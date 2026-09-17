local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local min = math.min
local max = math.max
local concat = table.concat

local countKeys = Private.countKeys
local shallowCopyArray = Private.shallowCopyArray

local function secondsRemaining(untilAt)
    local dueAt = tonumber(untilAt or 0) or 0
    if dueAt <= 0 then
        return 0
    end
    return max(0, dueAt - time())
end

local function boolText(value)
    return value == true and "true" or "false"
end

local function sortedReasonKeys(set)
    local rows = {}
    for reason in pairs(set or {}) do
        rows[#rows + 1] = tostring(reason)
    end
    sort(rows)
    return rows
end

local function summarizeInboundSessions(sync)
    local rows = {}
    for requesterKey, sessions in pairs(sync.inboundSeedSessions or {}) do
        for requestId, session in pairs(sessions or {}) do
            rows[#rows + 1] = {
                requesterKey = requesterKey,
                requestId = requestId,
                offeredBlocks = tonumber(session.offeredBlockCount or countKeys(session.offeredBlocks)) or 0,
                servedBlocks = tonumber(session.servedBlocks or 0) or 0,
                lastActivityAge = max(0, time() - (tonumber(session.lastActivity or session.createdAt or 0) or 0)),
                state = tostring(session.state or "ready"),
            }
        end
    end
    sort(rows, function(left, right)
        if left.requesterKey ~= right.requesterKey then
            return tostring(left.requesterKey) < tostring(right.requesterKey)
        end
        return tostring(left.requestId) < tostring(right.requestId)
    end)
    return rows
end

local function shallowCopyRows(rows)
    local out = {}
    for index = 1, #(rows or {}) do
        local row = rows[index]
        out[index] = {}
        for key, value in pairs(row or {}) do
            out[index][key] = value
        end
    end
    return out
end

local function summarizePeerVersions(sync)
    local rows = {}
    for peerKey, info in pairs(sync.peerVersions or {}) do
        rows[#rows + 1] = {
            peerKey = peerKey,
            addonVersion = info.addonVersion,
            wireVersion = info.wireVersion,
            buildChannel = info.buildChannel,
            compatibility = info.compatibility,
            ineligibleReason = info.ineligibleReason,
        }
    end
    sort(rows, function(left, right)
        return tostring(left.peerKey) < tostring(right.peerKey)
    end)
    return rows
end

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
    local tel = self.telemetry or {}
    local cycle = self.activeHelloCycle or {}
    local session = self.outboundSeedSession or {}
    local pause = Addon.SyncPausePolicy and Addon.SyncPausePolicy.GetDebugState and Addon.SyncPausePolicy:GetDebugState() or {}
    local transitionActive = self.IsInWorldTransition and self:IsInWorldTransition() or false
    local transitionRemaining = self.GetWorldTransitionRemaining and self:GetWorldTransitionRemaining() or 0
    local warmupActive = self.IsInWarmup and self:IsInWarmup() or false
    local warmupRemaining = self.GetWarmupRemaining and self:GetWarmupRemaining() or 0
    local worldReady = not transitionActive and not warmupActive
    local pendingReasons = sortedReasonKeys(self._pendingHelloReasons)
    local summaryActive = type(cycle) == "table" and cycle.helloId ~= nil and (cycle.selectionCompletedAt or 0) <= 0
    local inboundRows = summarizeInboundSessions(self)
    local blocksRemaining = max(0, #(session.wantedBlocks or {}) - max(0, (session.nextWantedIndex or 1) - 1))
    local lastProgressAt = tonumber(session.lastProgressAt or session.startedAt or 0) or 0
    local timeoutRemaining = lastProgressAt > 0 and max(0, (Private.constants.SESSION_TIMEOUT or 60) - (time() - lastProgressAt)) or 0
    local eligibility = self.GetPeerEligibilityBreakdown and self:GetPeerEligibilityBreakdown() or {}
    local peerRows = summarizePeerVersions(self)

    return {
        readiness = {
            syncReady = self.syncReady == true,
            savedVariablesReady = self.savedVariablesReady == true,
            playerReady = self.playerReady == true,
            worldReady = worldReady,
            worldTransitionActive = transitionActive,
            worldTransitionReason = self.worldTransitionReason,
            worldTransitionRemaining = transitionRemaining,
            warmupActive = warmupActive,
            warmupReason = self.warmupReason,
            warmupRemaining = warmupRemaining,
            rosterPreflightReady = self.rosterPreflightReady == true,
            rosterPreflightReason = self.rosterPreflightReason,
            indexReady = self.indexReady == true,
            indexStatus = self.indexStatus,
            notReadyReason = self.lastSyncNotReadyReason,
            pauseActive = pause.pauseActive == true,
            pauseReason = pause.pauseReason,
            inInstance = pause.inInstance == true,
            inRaid = pause.inRaid == true,
            inCombat = pause.inCombat == true,
            runtimeSaturated = (tel.runtimeQueuePressure or 0) >= 95,
            runtimeQueuePressure = tel.runtimeQueuePressure or 0,
            lastReadinessGateFailure = tel.lastReadinessGateFailure,
        },
        hello = {
            pending = self._helloTimer ~= nil,
            dueAt = self._helloScheduledFor or 0,
            remaining = secondsRemaining(self._helloScheduledFor),
            reason = self.lastHelloScheduleReason,
            coalescedReasons = pendingReasons,
            lastHelloId = tel.lastHelloId,
            lastHelloSentAt = tel.lastHelloSentAt or 0,
            lastHelloFingerprint = tel.lastHelloFingerprint,
            activeHelloId = cycle.helloId,
            sent = tel.helloSent or 0,
            deferredReason = tel.helloDeferredReason,
            deferredPaused = tel.helloDeferredPaused or 0,
            deferredNotReady = tel.helloDeferredNotReady or 0,
            deferredOutboundActive = tel.helloDeferredOutboundActive or 0,
        },
        summaryCollection = {
            active = summaryActive,
            helloId = cycle.helloId,
            startedAt = cycle.startedAt or 0,
            closesAt = cycle.closesAt or 0,
            remaining = summaryActive and secondsRemaining(cycle.closesAt) or 0,
            receivedCount = countKeys(cycle.summaries or {}),
            candidateCount = tel.lastSeedCandidateCount or 0,
        },
        discoveryRetry = {
            misses = self.discoveryRetryMisses or 0,
            currentDelay = tel.discoveryRetryDelay or 0,
            nextAt = tel.discoveryRetryNextAt or 0,
            remaining = secondsRemaining(tel.discoveryRetryNextAt),
            capSeconds = Private.constants.DISCOVERY_RETRY_MAX_SECONDS or 300,
            capHit = (tel.discoveryRetryDelay or 0) >= (Private.constants.DISCOVERY_RETRY_MAX_SECONDS or 300)
                or (tel.discoveryRetryCapHits or 0) > 0,
            lastReason = tel.lastDiscoveryRetryReason,
        },
        seedSelection = {
            selectedPeer = tel.lastSelectedPeer,
            selectedReason = tel.lastSelectedReason,
            candidateCount = tel.lastSeedCandidateCount or 0,
            rejectReasons = tel.lastSeedRejectReasons,
            lastNoSeedReason = tel.lastNoSeedReason,
            activeHelloId = cycle.helloId,
        },
        outboundSession = {
            active = self.HasActiveOutboundSeedSession and self:HasActiveOutboundSeedSession() or false,
            sessionId = session.sessionId,
            state = session.state or "idle",
            seedKey = session.seedKey,
            diffRequestId = session.diffRequestId,
            activeBlockKey = session.activeBlockKey,
            activeRequestId = session.activeBlockRequestId,
            wantedBlocks = #(session.wantedBlocks or {}),
            nextWantedIndex = session.nextWantedIndex or 1,
            blocksRemaining = blocksRemaining,
            successfulBlockMerges = session.successfulBlockMerges or 0,
            startedAt = session.startedAt or 0,
            lastProgressAt = lastProgressAt,
            timeoutRemaining = timeoutRemaining,
            abortReason = session.abortReason or tel.lastAbortReason,
            completedReason = session.completedReason or tel.lastSessionCompleteReason,
            lastPulledBlockKey = tel.lastBlockPullBlockKey,
            lastMergedBlockKey = tel.lastMergedBlockKey,
            lastMergedBlockFingerprint = tel.lastMergedBlockFingerprint,
            indexDirtyAllowedForActivePull = self.indexUsableForActivePull == true and (self:HasActiveOutboundSeedSession() == true),
        },
        inboundSeed = {
            activeCount = self.GetInboundSeedSessionCount and self:GetInboundSeedSessionCount() or 0,
            maxCount = Private.constants.MAX_INBOUND_SEED_SESSIONS or 4,
            perPeerMax = Private.constants.MAX_INBOUND_SEED_SESSIONS_PER_PEER or 1,
            sessionsSummary = inboundRows,
            rejectedCap = tel.inboundSeedSessionsRejectedCap or 0,
            rejectedPaused = tel.inboundSeedSessionsRejectedPaused or 0,
            rejectedNotReady = tel.inboundSeedSessionsRejectedNotReady or 0,
            rejectedUnknownRequest = tel.inboundBlockPullRejectedUnknownRequest or 0,
            rejectedNotOffered = tel.inboundBlockPullRejectedNotOffered or 0,
            clearedPause = tel.inboundSeedSessionsClearedPause or 0,
        },
        index = {
            indexReady = indexDebug.indexReady == true,
            indexStatus = indexDebug.indexStatus,
            indexUsableForActivePull = indexDebug.indexUsableForActivePull == true,
            trustedRoster = indexDebug.trustedRoster == true,
            trustedRosterReason = indexDebug.trustedRosterReason,
            activeOwnerCount = indexDebug.activeOwnerCount or 0,
            activeBlockCount = indexDebug.activeBlockCount or 0,
            activeContentCount = indexDebug.activeContentCount or 0,
            globalFingerprint = indexDebug.globalFingerprint,
            globalFingerprintDirty = indexDebug.globalFingerprintDirty == true,
            dirtyBlockCount = indexDebug.cache and indexDebug.cache.dirtyBlockCount or 0,
            lastGlobalFingerprintAt = indexDebug.lastGlobalFingerprintAt or 0,
            lastGlobalFingerprintReason = indexDebug.lastGlobalFingerprintReason,
            lastDirtyBlockKey = indexDebug.lastDirtyBlockKey,
            lastRebuiltBlockKey = indexDebug.lastRebuiltBlockKey,
            cache = {
                hits = indexDebug.cache and indexDebug.cache.stats and indexDebug.cache.stats.hits or 0,
                misses = indexDebug.cache and indexDebug.cache.stats and indexDebug.cache.stats.misses or 0,
                blockRebuilt = indexDebug.cache and indexDebug.cache.stats and indexDebug.cache.stats.blockRebuilt or 0,
                fullRebuild = indexDebug.cache and indexDebug.cache.stats and indexDebug.cache.stats.fullRebuild or 0,
                globalRecomputed = indexDebug.cache and indexDebug.cache.stats and indexDebug.cache.stats.globalRecomputed or 0,
                builtAt = indexDebug.cache and indexDebug.cache.builtAt or 0,
                lastBuildReason = indexDebug.cache and indexDebug.cache.lastBuildReason or nil,
                lastDirtyReason = indexDebug.cache and indexDebug.cache.lastDirtyReason or nil,
            },
        },
        pause = {
            active = pause.pauseActive == true,
            reason = pause.pauseReason,
            inInstance = pause.inInstance == true,
            inRaid = pause.inRaid == true,
            inCombat = pause.inCombat == true,
            worldTransitionActive = transitionActive,
            worldTransitionRemaining = transitionRemaining,
            warmupActive = warmupActive,
            warmupReason = self.warmupReason,
            warmupRemaining = warmupRemaining,
            lastPauseReason = tel.lastPauseReason,
            lastPauseEnterReason = tel.lastPauseEnterReason,
            lastPauseExitReason = tel.lastPauseExitReason,
            sessionsAbortedPause = tel.outboundSessionsAbortedPause or 0,
            inboundClearedPause = tel.inboundSeedSessionsClearedPause or 0,
        },
        compatibility = {
            peerVersionsCount = countKeys(self.peerVersions),
            eligiblePeers = eligibility.eligible or 0,
            ineligiblePeers = eligibility.ineligible or 0,
            buildChannelDrops = tel.buildChannelDrops or 0,
            skippedVersionIncompatible = tel.skippedVersionIncompatible or 0,
            skippedMissingCapability = tel.skippedMissingCapability or 0,
            newerVersionSeen = tel.newerVersionSeen or 0,
            newerProtocolSeen = tel.newerProtocolSeen or 0,
            peers = peerRows,
        },
        protocol = {
            helloSent = tel.helloSent or 0,
            summarySent = tel.summarySent or 0,
            summaryReceived = tel.summaryReceived or 0,
            indexDiffRequestSent = tel.indexDiffRequestSent or 0,
            indexDiffRequestReceived = tel.indexDiffRequestReceived or 0,
            indexDiffResponseSent = tel.indexDiffResponseSent or 0,
            indexDiffResponseReceived = tel.indexDiffResponseReceived or 0,
            lastIndexDiffRequestId = tel.lastIndexDiffRequestId,
            lastIndexDiffTarget = tel.lastIndexDiffTarget,
            lastIndexDiffLocalBlockCount = tel.lastIndexDiffLocalBlockCount or 0,
            lastIndexDiffOfferedCount = tel.lastIndexDiffOfferedCount or 0,
            lastIndexDiffNoOfferReason = tel.lastIndexDiffNoOfferReason,
            blockPullRequestSent = tel.blockPullRequestSent or 0,
            blockSnapshotReceived = tel.blockSnapshotReceived or 0,
            blockMergedImmediate = tel.blockMergedImmediate or 0,
            successfulBlockMerges = tel.successfulBlockMerges or 0,
        },
        unsupported = {
            ignored = tel.unsupportedMessagesIgnored or 0,
            lastKind = tel.lastUnsupportedMessageKind,
            lastSender = tel.lastUnsupportedMessageSender,
            lastAt = tel.lastUnsupportedMessageAt or 0,
        },
        lastBlockers = {
            noSeedReason = tel.lastNoSeedReason,
            helloDeferredReason = tel.helloDeferredReason,
            abortReason = tel.lastAbortReason,
            timeoutReason = tel.lastBlockPullTimeoutReason,
            readinessFailure = tel.lastReadinessGateFailure,
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
        warmup = runtime.readiness.warmupActive,
        transition = runtime.readiness.worldTransitionActive,
        transitionRemaining = runtime.readiness.worldTransitionRemaining,
        bootstrap = bootstrapState,
        indexReady = runtime.index.indexReady,
        indexStatus = runtime.index.indexStatus,
        trustedRoster = runtime.index.trustedRoster,
        trustedRosterReason = runtime.index.trustedRosterReason,
        localSummary = {
            syncModel = "index-diff-block-pull",
            activeOwnerCount = runtime.index.activeOwnerCount,
            activeBlockCount = runtime.index.activeBlockCount,
            activeContentCount = runtime.index.activeContentCount,
            globalFingerprint = runtime.index.globalFingerprint,
            globalFingerprintDirty = runtime.index.globalFingerprintDirty,
        },
        selectedSeedKey = runtime.seedSelection.selectedPeer,
        outboundSession = runtime.outboundSession,
        telemetry = self.telemetry,
    }
end

function Sync:GetDebugSnapshot()
    local snapshot = self:GetAlphaDebugSnapshot()
    snapshot.lifecycleDebugLog = shallowCopyArray(self.lifecycleDebugLog)
    snapshot.offlineDebugLog = shallowCopyArray(self.offlineDebugLog)
    return snapshot
end

function Sync:GetAlphaDebugSnapshot()
    local runtime = self:GetRuntimeObservabilitySnapshot()
    local info = self:GetLocalVersionInfo()
    local recent = self.GetRecentSyncEvents and self:GetRecentSyncEvents(Private.constants.RECENT_SYNC_EVENTS_LIMIT or 50) or {}
    return {
        addonVersion = info.addonVersion,
        wireVersion = info.wireVersion,
        minSupportedWireVersion = info.minSupportedWireVersion,
        buildChannel = info.buildChannel,
        buildId = info.buildId,
        commPrefix = info.commPrefix,
        readiness = runtime.readiness,
        hello = runtime.hello,
        summaryCollection = runtime.summaryCollection,
        discoveryRetry = runtime.discoveryRetry,
        seedSelection = runtime.seedSelection,
        outboundSession = runtime.outboundSession,
        inboundSeed = runtime.inboundSeed,
        index = runtime.index,
        pause = runtime.pause,
        compatibility = runtime.compatibility,
        protocol = runtime.protocol,
        unsupported = runtime.unsupported,
        lastBlockers = runtime.lastBlockers,
        recentEventLog = shallowCopyRows(recent),
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
            if self._peerSessionBackoffUntil then
                self._peerSessionBackoffUntil[key] = nil
            end
            if self._peerSessionNoProgressCount then
                self._peerSessionNoProgressCount[key] = nil
            end
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
    for key in pairs(self._peerSessionBackoffUntil or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._peerSessionBackoffUntil, key, "peerBackoff")
        end
    end
    for key in pairs(self._peerSessionNoProgressCount or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._peerSessionNoProgressCount, key, "peerBackoff")
        end
    end

    if stats.removed > 0 and not dryRun then
        Addon:RequestRefresh("clean-sync")
    end
    return stats
end

local function dumpRecentSyncLog(self, limit)
    local rows = self.GetRecentSyncEvents and self:GetRecentSyncEvents(limit or 10) or {}
    if #rows == 0 then
        Addon:Print("Sync log: none")
        return
    end
    Addon:Print(string.format("Sync log entries=%d", #rows))
    for index = 1, #rows do
        local row = rows[index]
        Addon:Print(string.format(
            "%d %s reason=%s peer=%s req=%s block=%s extra=%s",
            tonumber(row.t or 0) or 0,
            tostring(row.event or "event"),
            tostring(row.reason or "none"),
            tostring(row.peer or "none"),
            tostring(row.requestId or "none"),
            tostring(row.blockKey or "none"),
            tostring(row.extra or "none")
        ))
    end
end

function Sync:DumpStatus(mode)
    mode = tostring(mode or "summary"):lower()
    if mode == "peers" then
        self:DumpPeerVersions()
        return
    end
    if mode == "log" then
        dumpRecentSyncLog(self, 12)
        return
    end

    local runtime = self:GetRuntimeObservabilitySnapshot()
    local localVersion = self:GetLocalVersionInfo()
    local tel = self.telemetry or {}
    Addon:Print(string.format(
        "RR Sync Ready: %s reason=%s",
        boolText(runtime.readiness.syncReady),
        tostring(runtime.readiness.notReadyReason or "ready")
    ))
    Addon:Print(string.format(
        "saved=%s player=%s world=%s roster=%s index=%s paused=%s transition=%s warmup=%s",
        boolText(runtime.readiness.savedVariablesReady),
        boolText(runtime.readiness.playerReady),
        boolText(runtime.readiness.worldReady),
        boolText(runtime.readiness.rosterPreflightReady),
        boolText(runtime.readiness.indexReady),
        boolText(runtime.readiness.pauseActive),
        boolText(runtime.readiness.worldTransitionActive),
        boolText(runtime.readiness.warmupActive)
    ))
    Addon:Print(string.format(
        "HELLO sent=%d pending=%s due=%ds reason=%s retryMisses=%d retryDelay=%ds cap=%ds summaryWindow=%s closes=%ds received=%d",
        runtime.hello.sent or 0,
        boolText(runtime.hello.pending),
        math.floor(runtime.hello.remaining or 0),
        tostring(runtime.hello.reason or "none"),
        runtime.discoveryRetry.misses or 0,
        runtime.discoveryRetry.currentDelay or 0,
        runtime.discoveryRetry.capSeconds or 300,
        runtime.summaryCollection.active and "active" or "idle",
        math.floor(runtime.summaryCollection.remaining or 0),
        runtime.summaryCollection.receivedCount or 0
    ))
    Addon:Print(string.format(
        "Outbound seed=%s state=%s wanted=%d next=%d activeBlock=%s merges=%d dirty=%s dirtyAllowed=%s timeout=%ds",
        tostring(runtime.outboundSession.seedKey or "none"),
        tostring(runtime.outboundSession.state or "idle"),
        runtime.outboundSession.wantedBlocks or 0,
        runtime.outboundSession.nextWantedIndex or 1,
        tostring(runtime.outboundSession.activeBlockKey or "none"),
        runtime.outboundSession.successfulBlockMerges or 0,
        boolText(runtime.index.globalFingerprintDirty),
        boolText(runtime.outboundSession.indexDirtyAllowedForActivePull),
        math.floor(runtime.outboundSession.timeoutRemaining or 0)
    ))
    Addon:Print(string.format(
        "Inbound seed sessions=%d/%d rejectedCap=%d rejectedPaused=%d rejectedNotReady=%d clearedPause=%d",
        runtime.inboundSeed.activeCount or 0,
        runtime.inboundSeed.maxCount or 0,
        runtime.inboundSeed.rejectedCap or 0,
        runtime.inboundSeed.rejectedPaused or 0,
        runtime.inboundSeed.rejectedNotReady or 0,
        runtime.inboundSeed.clearedPause or 0
    ))
    Addon:Print(string.format(
        "Index status=%s ready=%s activePullUsable=%s owners=%d blocks=%d content=%d dirtyBlocks=%d gf=%s lastReason=%s",
        tostring(runtime.index.indexStatus or "unknown"),
        boolText(runtime.index.indexReady),
        boolText(runtime.index.indexUsableForActivePull),
        runtime.index.activeOwnerCount or 0,
        runtime.index.activeBlockCount or 0,
        runtime.index.activeContentCount or 0,
        runtime.index.dirtyBlockCount or 0,
        tostring(runtime.index.globalFingerprint or "none"),
        tostring(runtime.index.lastGlobalFingerprintReason or "none")
    ))
    Addon:Print(string.format(
        "HELLO %d / SUMMARY sent=%d recv=%d / INDEX req=%d resp=%d offered=%d / BLOCK pull=%d snapRecv=%d merged=%d",
        runtime.protocol.helloSent or 0,
        runtime.protocol.summarySent or 0,
        runtime.protocol.summaryReceived or 0,
        runtime.protocol.indexDiffRequestSent or 0,
        runtime.protocol.indexDiffResponseReceived or 0,
        runtime.protocol.lastIndexDiffOfferedCount or 0,
        runtime.protocol.blockPullRequestSent or 0,
        runtime.protocol.blockSnapshotReceived or 0,
        runtime.protocol.successfulBlockMerges or 0
    ))
    Addon:Print(string.format(
        "Last noSeed=%s defer=%s abort=%s unsupported=%d",
        tostring(runtime.lastBlockers.noSeedReason or "none"),
        tostring(runtime.lastBlockers.helloDeferredReason or "none"),
        tostring(runtime.lastBlockers.abortReason or "none"),
        runtime.unsupported.ignored or 0
    ))

    if mode == "debug" or mode == "diag" then
        Addon:Print(string.format(
            "Version addon=%s wire=%s channel=%s prefix=%s peers=%d eligible=%d ineligible=%d",
            tostring(localVersion.addonVersion or "?"),
            tostring(localVersion.wireVersion or "?"),
            tostring(localVersion.buildChannel or "release"),
            tostring(localVersion.commPrefix or Addon.ADDON_PREFIX or "?"),
            runtime.compatibility.peerVersionsCount or 0,
            runtime.compatibility.eligiblePeers or 0,
            runtime.compatibility.ineligiblePeers or 0
        ))
        Addon:Print(string.format(
            "Seed selected=%s reason=%s candidates=%d reject=%s",
            tostring(runtime.seedSelection.selectedPeer or "none"),
            tostring(runtime.seedSelection.selectedReason or "none"),
            runtime.seedSelection.candidateCount or 0,
            tostring(runtime.seedSelection.rejectReasons or "none")
        ))
        Addon:Print(string.format(
            "Last HELLO id=%s sentAt=%d fingerprint=%s pendingReasons=%s",
            tostring(runtime.hello.lastHelloId or "none"),
            runtime.hello.lastHelloSentAt or 0,
            tostring(runtime.hello.lastHelloFingerprint or "none"),
            (#(runtime.hello.coalescedReasons or {}) > 0) and concat(runtime.hello.coalescedReasons, ",") or "none"
        ))
    end

    if mode == "sessions" then
        for index = 1, #(runtime.inboundSeed.sessionsSummary or {}) do
            local row = runtime.inboundSeed.sessionsSummary[index]
            Addon:Print(string.format(
                "Inbound[%d] peer=%s req=%s offered=%d served=%d age=%ds state=%s",
                index,
                tostring(row.requesterKey or "none"),
                tostring(row.requestId or "none"),
                row.offeredBlocks or 0,
                row.servedBlocks or 0,
                math.floor(row.lastActivityAge or 0),
                tostring(row.state or "ready")
            ))
        end
    end
end
