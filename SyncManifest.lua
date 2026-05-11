local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local random = math.random
local min = math.min
local max = math.max

local cloneFingerprintMap = Private.cloneFingerprintMap
local cloneStringRange = Private.cloneStringRange
local cloneStringSet = Private.cloneStringSet
local countArrayUnique = Private.countArrayUnique
local getManifestAnnouncementId = Private.getManifestAnnouncementId
local nowForPacing = Private.nowForPacing
local shallowCopyTable = Private.shallowCopyTable
local sliceExpectedFingerprints = Private.sliceExpectedFingerprints

local MANIFEST_CHUNK_DELAY = Constants.MANIFEST_CHUNK_DELAY
local MANIFEST_INITIAL_JITTER = Constants.MANIFEST_INITIAL_JITTER
local MANIFEST_PUSH_COOLDOWN = Constants.MANIFEST_PUSH_COOLDOWN
local MANIFEST_MERGE_ANNOUNCE_DEBOUNCE = Constants.MANIFEST_MERGE_ANNOUNCE_DEBOUNCE
local MANIFEST_MERGE_ANNOUNCE_MAX_DELAY = Constants.MANIFEST_MERGE_ANNOUNCE_MAX_DELAY
local MANIFEST_CATCHUP_DRAIN_DELAY = Constants.MANIFEST_CATCHUP_DRAIN_DELAY

function Sync:SendManifestToPeer(peerKey, why)
    if not peerKey or not Addon.TrickleSync then return end
    if not self:IsValidSyncMemberKey(peerKey) then return end
    if self:IsMockKey(peerKey) then return end
    if self:IsInWorldTransition() and why ~= "force" then
        self.telemetry.transitionDeferredManifestPeers = (self.telemetry.transitionDeferredManifestPeers or 0) + 1
        self.telemetry.transitionDeferrals = (self.telemetry.transitionDeferrals or 0) + 1
        self:QueueTransitionDrainWork({
            kind = "manifest-peer",
            peerKey = peerKey,
            why = why or "transition",
        })
        self:ScheduleTransitionDrain("manifest-peer")
        return
    end
    self.telemetry.manifestBuildRequests = (self.telemetry.manifestBuildRequests or 0) + 1
    local lastSentAt = self._lastManifestSentAt[peerKey] or 0
    if why ~= "force" and (time() - lastSentAt) < MANIFEST_PUSH_COOLDOWN then
        self.telemetry.manifestCooldownSkips = (self.telemetry.manifestCooldownSkips or 0) + 1
        return
    end

    local chunks, manifest = Addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = why or "send",
    })
    if not chunks then
        self.pendingManifestPeers = self.pendingManifestPeers or {}
        self.pendingManifestPeers[peerKey] = why or "pending"
        self.telemetry.manifestDeferredSends = (self.telemetry.manifestDeferredSends or 0) + 1
        return
    end
    local manifestId = getManifestAnnouncementId(chunks, manifest)
    if why ~= "force" and manifestId and self._lastManifestAnnouncedId[peerKey] == manifestId then
        self.telemetry.manifestUnchangedSkips = (self.telemetry.manifestUnchangedSkips or 0) + 1
        return
    end
    self:QueueManifestChunks(peerKey, chunks, why)
    self._lastManifestSentAt[peerKey] = time()
    if manifestId then
        self._lastManifestAnnouncedId[peerKey] = manifestId
    end
end

function Sync:QueueManifestChunks(peerKey, chunks, why)
    if not peerKey or not chunks then return false end
    self.manifestChunkQueue = self.manifestChunkQueue or {}
    local startAt = nowForPacing()
    if why ~= "force" and MANIFEST_INITIAL_JITTER > 0 then
        startAt = startAt + (random() * MANIFEST_INITIAL_JITTER)
    end

    for index = 1, #chunks do
        local payload = shallowCopyTable(chunks[index])
        payload.why = why
        self.manifestChunkQueue[#self.manifestChunkQueue + 1] = {
            peer = peerKey,
            payload = payload,
            queuedAt = time(),
            readyAt = startAt + ((index - 1) * MANIFEST_CHUNK_DELAY),
        }
    end
    self.telemetry.manifestChunksQueued = (self.telemetry.manifestChunksQueued or 0) + #chunks
    if #self.manifestChunkQueue > (self.telemetry.manifestQueueMaxDepth or 0) then
        self.telemetry.manifestQueueMaxDepth = #self.manifestChunkQueue
    end
    self:EnforceRuntimeQueueCaps("manifest-queue")
    return true
end

function Sync:OnManifestCacheReady(reason)
    if self.pendingManifestPeers and next(self.pendingManifestPeers) ~= nil then
        local pending = self.pendingManifestPeers
        self.pendingManifestPeers = {}
        self.telemetry.manifestPendingFlushes = (self.telemetry.manifestPendingFlushes or 0) + 1
        for peerKey, why in pairs(pending) do
            self:SendManifestToPeer(peerKey, why or reason or "manifest-ready")
        end
    end
    self:FlushPendingManifestComparePeers(reason or "manifest-ready")
end

function Sync:ProcessPeerManifestComparison(senderKey, manifest)
    local _queuedBlocks, groupedRequests, compareStatus, comparison = Addon.TrickleSync:QueueMissingBlocksForPeer(senderKey, manifest)
    if compareStatus == "building" or compareStatus == "deferred" then
        self:QueuePendingManifestComparePeer(senderKey)
        return {
            changedLocalData = false,
            queuedRequests = 0,
            deferredRequests = 0,
            identicalBlocks = 0,
            metadataOnlyBlocks = 0,
            ignoredStaleBlocks = 0,
            shouldRefreshUI = false,
        }
    end

    local identicalBlocks = comparison and #(comparison.identicalBlocks or {}) or 0
    local ignoredStaleBlocks = comparison and #(comparison.ignoredStaleBlocks or {}) or 0
    if identicalBlocks > 0 then
        self.telemetry.manifestIdenticalBlockSkips = (self.telemetry.manifestIdenticalBlockSkips or 0) + identicalBlocks
        self.telemetry.manifestEquivalentPeerSkips = (self.telemetry.manifestEquivalentPeerSkips or 0) + 1
    end

    local catchupCandidates = self:BuildManifestCatchupCandidates(senderKey, groupedRequests)
    local deferReason = self:ShouldDeferManifestCatchup()
    local deferredRequests = 0
    local queuedBefore = self.telemetry.manifestCatchupQueued or 0
    if deferReason then
        self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
        Addon:Debug("Deferring manifest catch-up batch", tostring(senderKey), tostring(deferReason))
        for _, candidate in ipairs(catchupCandidates) do
            self:DeferManifestCatchupCandidate(candidate)
            deferredRequests = deferredRequests + 1
        end
        if #catchupCandidates > 0 then
            self:ScheduleManifestCatchupDrain()
        end
    else
        self:FlushManifestCatchupCandidates(catchupCandidates)
    end
    local queuedRequests = max(0, (self.telemetry.manifestCatchupQueued or 0) - queuedBefore)
    if queuedRequests == 0 and identicalBlocks > 0 then
        self.telemetry.manifestRequestsAvoided = (self.telemetry.manifestRequestsAvoided or 0) + identicalBlocks
        self.telemetry.avoidedRequests = (self.telemetry.avoidedRequests or 0) + identicalBlocks
    end
    return {
        changedLocalData = queuedRequests > 0 or deferredRequests > 0,
        queuedRequests = queuedRequests,
        deferredRequests = deferredRequests,
        identicalBlocks = identicalBlocks,
        metadataOnlyBlocks = 0,
        ignoredStaleBlocks = ignoredStaleBlocks,
        shouldRefreshUI = queuedRequests > 0 or deferredRequests > 0,
    }
end

function Sync:FlushPendingManifestComparePeers(_reason)
    if not (self._pendingManifestComparePeers and next(self._pendingManifestComparePeers) ~= nil) then
        return
    end

    local pending = self._pendingManifestComparePeers
    self._pendingManifestComparePeers = {}
    for peerKey in pairs(pending) do
        local peerState = Addon.TrickleSync and Addon.TrickleSync.peerState and Addon.TrickleSync.peerState[peerKey] or nil
        local manifest = peerState and peerState.manifest or nil
        if manifest then
            self:ProcessPeerManifestComparison(peerKey, manifest)
        end
    end
end

function Sync:RequestManifestRefresh(peerKey, opts)
    opts = opts or {}
    if peerKey and peerKey ~= "" then
        if self:IsMockKey(peerKey) then return end
        if self:IsInWorldTransition() and not opts.force then
            self.telemetry.transitionDeferredManifestPeers = (self.telemetry.transitionDeferredManifestPeers or 0) + 1
            self.telemetry.transitionDeferrals = (self.telemetry.transitionDeferrals or 0) + 1
            self:QueueTransitionDrainWork({
                kind = "manifest-refresh",
                peerKey = peerKey,
                reason = opts.reason or "transition",
            })
            self:ScheduleTransitionDrain("manifest-refresh")
            return
        end
        if not self:ShouldRequestManifestRefresh(peerKey, opts) then return end
        if opts.clearBackoff then
            self:ClearPeerBackoff(peerKey)
        end
        self:RecordManifestRefreshRequest(peerKey)
        self:SendDirectEnvelope("MREQ", {
            key = self:GetSelfKey(),
            why = opts.reason or "manual",
        }, peerKey, "NORMAL")
        return
    end

    self:SendGuildEnvelope("MREQ", {
        key = self:GetSelfKey(),
        why = "manual-all",
    }, "NORMAL")
end

function Sync:HandleManifestRequest(payload)
    if not self:IsValidSyncMemberKey(payload.sender) or payload.sender == self:GetSelfKey() then return end
    if self:IsMockKey(payload.sender) then return end
    self.telemetry.manifestForceReplies = (self.telemetry.manifestForceReplies or 0) + 1
    self:SendManifestToPeer(payload.sender, "force")
end

function Sync:ScheduleCoalescedManifestAnnounce(reason)
    local now = time()
    if self._coalescedManifestTimer then
        if (now - (self._coalescedManifestFirstAt or now)) >= MANIFEST_MERGE_ANNOUNCE_MAX_DELAY then
            self:CancelTimer(self._coalescedManifestTimer, true)
            self._coalescedManifestTimer = nil
        else
            return
        end
    end
    self._coalescedManifestReason = reason or "coalesced-merge"
    self._coalescedManifestFirstAt = now
    self.telemetry.coalescedManifestSchedules = (self.telemetry.coalescedManifestSchedules or 0) + 1
    Addon:Debug("Coalesced manifest announce scheduled", tostring(reason or "coalesced-merge"))
    self._coalescedManifestTimer = self:ScheduleTimer(function()
        self._coalescedManifestTimer = nil
        local why = self._coalescedManifestReason or "coalesced-merge"
        self._coalescedManifestReason = nil
        if self:IsInWarmup() then
            self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
            self._pendingWarmupManifestBroadcastReason = why
            return
        end
        self.telemetry.coalescedManifestFlushes = (self.telemetry.coalescedManifestFlushes or 0) + 1
        self:BroadcastManifestToOnlinePeers(why, { ignoreWarmup = true })
    end, MANIFEST_MERGE_ANNOUNCE_DEBOUNCE)
end

function Sync:BroadcastManifestToOnlinePeers(why, opts)
    opts = opts or {}
    if self:IsInWarmup() and not opts.ignoreWarmup then
        self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
        self._pendingWarmupManifestBroadcastReason = why or self._pendingWarmupManifestBroadcastReason or "broadcast"
        Addon:Debug("Warmup deferring manifest fan-out", tostring(why or "broadcast"))
        return
    end
    if self:IsInWorldTransition() and not opts.ignoreTransition then
        self.telemetry.transitionDeferrals = (self.telemetry.transitionDeferrals or 0) + 1
        self:QueueTransitionDrainWork({
            kind = "broadcast-manifest",
            why = why or "broadcast",
        })
        self:ScheduleTransitionDrain("manifest-broadcast")
        return
    end
    for peerKey in pairs(self.onlineNodes or {}) do
        if peerKey ~= self:GetSelfKey() and self:IsValidSyncMemberKey(peerKey) and not self:IsMockKey(peerKey) then
            self:SendManifestToPeer(peerKey, why or "broadcast")
        end
    end
end

function Sync:IsManifestCatchupOwnerBusy(ownerCharacter)
    if not ownerCharacter then return true end
    if self.pendingRequests and self.pendingRequests[ownerCharacter] then return true end
    if self:GetInFlightRequest(ownerCharacter) then return true end
    return false
end

function Sync:SortManifestCatchupCandidates(candidates)
    sort(candidates, function(a, b)
        if a.directOwner ~= b.directOwner then return a.directOwner end
        if a.offlineReplica ~= b.offlineReplica then return a.offlineReplica end
        if (a.revision or 0) ~= (b.revision or 0) then return (a.revision or 0) > (b.revision or 0) end
        if #(a.blockKeys or {}) ~= #(b.blockKeys or {}) then return #(a.blockKeys or {}) > #(b.blockKeys or {}) end
        return tostring(a.ownerCharacter or "") < tostring(b.ownerCharacter or "")
    end)
end

function Sync:BuildManifestCatchupCandidates(senderKey, groupedRequests)
    local candidates = {}
    local seenCandidates = 0
    local rosterFresh = self:IsRosterFresh()
    if not rosterFresh then
        self:EnsureFreshRoster("manifest-catchup")
    end
    for ownerCharacter, request in pairs(groupedRequests or {}) do
        local blockKeys = cloneStringSet(request and request.blockKeys)
        if self:IsValidSyncMemberKey(ownerCharacter) and #blockKeys > 0 then
            seenCandidates = seenCandidates + 1
            local ownerIsOnline = rosterFresh and Addon.Data:IsMemberOnline(ownerCharacter) or false
            local directOwner = ownerCharacter == senderKey
            if not directOwner and ownerIsOnline then
                self.telemetry.manifestCatchupSkippedOnlineOwners = (self.telemetry.manifestCatchupSkippedOnlineOwners or 0) + 1
            elseif not directOwner and self:IsLocallyStaleOwner(ownerCharacter) then
                self.telemetry.manifestCatchupSkippedStaleOwners = (self.telemetry.manifestCatchupSkippedStaleOwners or 0) + 1
            else
                candidates[#candidates + 1] = {
                    senderKey = senderKey,
                    ownerCharacter = ownerCharacter,
                    revision = request and request.revision or 0,
                    blockKeys = blockKeys,
                    expectedFingerprints = cloneFingerprintMap(request and request.fingerprints),
                    directOwner = directOwner,
                    offlineReplica = not directOwner and not ownerIsOnline,
                    sourceType = request and request.sourceType,
                    wasDeferred = request and request.wasDeferred == true or false,
                }
            end
        end
    end
    self.telemetry.manifestCatchupCandidates = (self.telemetry.manifestCatchupCandidates or 0) + seenCandidates
    self:SortManifestCatchupCandidates(candidates)
    return candidates
end

function Sync:DeferManifestCatchupCandidate(candidate)
    if not (candidate and self:IsValidSyncMemberKey(candidate.ownerCharacter)) then return end
    candidate.blockKeys = cloneStringSet(candidate.blockKeys)
    candidate.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, candidate.blockKeys)
    if #candidate.blockKeys == 0 then return end
    self.manifestCatchupQueue = self.manifestCatchupQueue or {}
    if not candidate.wasDeferred then
        self.telemetry.manifestCatchupDeferred = (self.telemetry.manifestCatchupDeferred or 0) + 1
    end
    candidate.wasDeferred = true
    self.manifestCatchupQueue[#self.manifestCatchupQueue + 1] = candidate
    if #self.manifestCatchupQueue > (self.telemetry.manifestCatchupMaxDeferred or 0) then
        self.telemetry.manifestCatchupMaxDeferred = #self.manifestCatchupQueue
    end
end

function Sync:QueueManifestCatchupRequest(candidate)
    if not (candidate and self:IsValidSyncMemberKey(candidate.ownerCharacter) and self:IsValidSyncMemberKey(candidate.senderKey)) then
        return false, false
    end
    if self:IsRequestAlreadySatisfied({
        memberKey = candidate.ownerCharacter,
        rev = candidate.revision or 0,
        requestedBlocks = candidate.blockKeys,
        expectedFingerprints = candidate.expectedFingerprints,
    }) then
        if candidate.wasDeferred then
            self.telemetry.manifestCatchupDrained = (self.telemetry.manifestCatchupDrained or 0) + 1
        end
        return true, false
    end
    if self:IsManifestCatchupOwnerBusy(candidate.ownerCharacter) then
        return false, false
    end
    self:QueueRequest(candidate.senderKey, candidate.ownerCharacter, candidate.revision or 0, "manifest", {
        allowReplicaSource = true,
        requestedBlocks = candidate.blockKeys,
        expectedFingerprints = candidate.expectedFingerprints,
    })
    self.telemetry.manifestCatchupQueued = (self.telemetry.manifestCatchupQueued or 0) + 1
    if candidate.wasDeferred then
        self.telemetry.manifestCatchupDrained = (self.telemetry.manifestCatchupDrained or 0) + 1
    end
    if candidate.offlineReplica then
        self.telemetry.replicaRequestsQueued = (self.telemetry.replicaRequestsQueued or 0) + 1
        self:PushOfflineDebugEvent("queued", string.format(
            "%s from %s blocks=%d rev=%d",
            tostring(candidate.ownerCharacter),
            tostring(candidate.senderKey),
            #(candidate.blockKeys or {}),
            candidate.revision or 0
        ))
    end
    return true, true
end

function Sync:FlushManifestCatchupCandidates(candidates)
    local ownersQueued = self:GetManifestCatchupOutstandingCost()
    local blocksQueued = 0
    local ownersAdded = 0
    local blocksAdded = 0
    local deferred = {}

    for _, candidate in ipairs(candidates or {}) do
        local blockKeys = cloneStringSet(candidate.blockKeys)
        local index = 1
        while index <= #blockKeys do
            if ownersQueued >= Constants.MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH or blocksQueued >= Constants.MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH then
                local rest = shallowCopyTable(candidate)
                rest.blockKeys = cloneStringRange(blockKeys, index, #blockKeys)
                rest.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, rest.blockKeys)
                deferred[#deferred + 1] = rest
                break
            end
            if self:IsManifestCatchupOwnerBusy(candidate.ownerCharacter) then
                local rest = shallowCopyTable(candidate)
                rest.blockKeys = cloneStringRange(blockKeys, index, #blockKeys)
                rest.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, rest.blockKeys)
                deferred[#deferred + 1] = rest
                break
            end

            local availableBlocks = Constants.MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH - blocksQueued
            local takeCount = min(#blockKeys - index + 1, availableBlocks)
            if takeCount <= 0 then
                local rest = shallowCopyTable(candidate)
                rest.blockKeys = cloneStringRange(blockKeys, index, #blockKeys)
                rest.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, rest.blockKeys)
                deferred[#deferred + 1] = rest
                break
            end

            local chunk = shallowCopyTable(candidate)
            chunk.blockKeys = cloneStringRange(blockKeys, index, index + takeCount - 1)
            chunk.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, chunk.blockKeys)
            local consumed, queued = self:QueueManifestCatchupRequest(chunk)
            if consumed then
                if queued then
                    ownersQueued = ownersQueued + 1
                    blocksQueued = blocksQueued + #chunk.blockKeys
                    ownersAdded = ownersAdded + 1
                    blocksAdded = blocksAdded + #chunk.blockKeys
                end
                index = index + takeCount
            else
                local rest = shallowCopyTable(candidate)
                rest.blockKeys = cloneStringRange(blockKeys, index, #blockKeys)
                rest.expectedFingerprints = sliceExpectedFingerprints(candidate.expectedFingerprints, rest.blockKeys)
                deferred[#deferred + 1] = rest
                break
            end
        end
    end

    for _, candidate in ipairs(deferred) do
        self:DeferManifestCatchupCandidate(candidate)
    end
    if #deferred > 0 then
        self:ScheduleManifestCatchupDrain()
    end
    return ownersAdded, blocksAdded, #deferred
end

function Sync:DrainManifestCatchupQueue()
    if #(self.manifestCatchupQueue or {}) == 0 then return false end
    local deferReason = self:ShouldDeferManifestCatchup()
    if deferReason then
        self.telemetry.catchupDrainDeferrals = (self.telemetry.catchupDrainDeferrals or 0) + 1
        Addon:Debug("Deferring catch-up drain", tostring(deferReason))
        return true
    end
    local pending = self.manifestCatchupQueue
    self.manifestCatchupQueue = {}
    self:SortManifestCatchupCandidates(pending)
    self:FlushManifestCatchupCandidates(pending)
    return #(self.manifestCatchupQueue or {}) > 0
end

function Sync:ScheduleManifestCatchupDrain()
    if self._manifestCatchupJobActive then return end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        self._manifestCatchupJobActive = true
        self:ScheduleTimer(function()
            self._manifestCatchupJobActive = false
            self:DrainManifestCatchupQueue()
        end, MANIFEST_CATCHUP_DRAIN_DELAY)
        return
    end
    self._manifestCatchupJobActive = true
    Addon.Performance:ScheduleJob("manifest-catchup-drain", function(state)
        state = state or {}
        state.nextRunAt = state.nextRunAt or (nowForPacing() + MANIFEST_CATCHUP_DRAIN_DELAY)
        if nowForPacing() < state.nextRunAt then
            return true, state
        end
        local deferReason, nextDelay = self:ShouldDeferManifestCatchup()
        if deferReason then
            self.telemetry.catchupDrainDeferrals = (self.telemetry.catchupDrainDeferrals or 0) + 1
            Addon:Debug("Warmup/busy deferring catch-up drain", tostring(deferReason))
            state.nextRunAt = nowForPacing() + max(MANIFEST_CATCHUP_DRAIN_DELAY, nextDelay or MANIFEST_CATCHUP_DRAIN_DELAY)
            return true, state
        end
        local keepGoing = self:DrainManifestCatchupQueue()
        if keepGoing then
            state.nextRunAt = nowForPacing() + MANIFEST_CATCHUP_DRAIN_DELAY
            return true, state
        end
        self._manifestCatchupJobActive = false
        return false, state
    end, {
        category = "sync-manifest-catchup",
        label = "manifest-catchup-drain",
        budgetMs = 1,
    })
end

function Sync:HandleManifestChunk(payload)
    if not self:IsValidSyncMemberKey(payload.sender) or payload.sender == self:GetSelfKey() then return end
    if not payload.manifestId then return end
    if self:IsMockKey(payload.sender) and not self:ShouldAllowLocalMockTraffic(payload.sender, nil) then return end
    self.telemetry.manifestChunksReceived = (self.telemetry.manifestChunksReceived or 0) + 1

    local senderKey = payload.sender
    local manifestMemberKey = self:IsValidSyncMemberKey(payload.memberKey) and payload.memberKey or senderKey
    self.partialManifestReceive[senderKey] = self.partialManifestReceive[senderKey] or {}
    local state = self.partialManifestReceive[senderKey][payload.manifestId]
    if not state then
        state = {
            manifestId = payload.manifestId,
            builtAt = payload.builtAt or time(),
            memberKey = manifestMemberKey,
            totals = payload.totals or {},
            total = payload.total or 1,
            seen = {},
            blocks = {},
        }
        self.partialManifestReceive[senderKey][payload.manifestId] = state
    end

    state.seen[payload.seq or 1] = true
    state.total = payload.total or state.total or 1
    for _, block in ipairs(payload.blocks or {}) do
        local blockKey = block and block.blockKey
        local ownerCharacter, professionKey = Addon.Data:ParseSyncBlockKey(blockKey)
        if Addon.Data:IsValidMemberKey(ownerCharacter)
            and type(professionKey) == "string"
            and professionKey ~= ""
            and (not block.ownerCharacter or block.ownerCharacter == ownerCharacter)
            and (not block.professionKey or block.professionKey == professionKey) then
            block.ownerCharacter = ownerCharacter
            block.professionKey = professionKey
            state.blocks[blockKey] = block
        else
            Addon:Debug("Ignored malformed manifest block", tostring(blockKey), "from", tostring(senderKey))
        end
    end

    local complete = true
    for seq = 1, (state.total or 1) do
        if not state.seen[seq] then
            complete = false
            break
        end
    end
    if not complete then return end

    local manifest = {
        builtAt = state.builtAt,
        memberKey = state.memberKey,
        totals = state.totals,
        blocks = state.blocks,
    }

    self.partialManifestReceive[senderKey][payload.manifestId] = nil
    if next(self.partialManifestReceive[senderKey]) == nil then
        self.partialManifestReceive[senderKey] = nil
    end
    self:RecordManifestReceived(senderKey)
    if self.MarkManifestPeerSuccess then
        self:MarkManifestPeerSuccess(senderKey)
    end

    Addon.TrickleSync:StorePeerManifest(senderKey, manifest)
    local replicaOwners = {}
    local replicaBlocks = 0
    for _, block in pairs(manifest.blocks or {}) do
        if block and Addon.Data:IsValidMemberKey(block.ownerCharacter) and block.ownerCharacter ~= senderKey and not Addon.Data:IsMemberOnline(block.ownerCharacter) then
            replicaBlocks = replicaBlocks + 1
            replicaOwners[#replicaOwners + 1] = block.ownerCharacter
        elseif block and block.sourceType == "replica" and Addon.Data:IsValidMemberKey(block.ownerCharacter) and not Addon.Data:IsMemberOnline(block.ownerCharacter) then
            replicaBlocks = replicaBlocks + 1
            replicaOwners[#replicaOwners + 1] = block.ownerCharacter
        end
    end
    if replicaBlocks > 0 then
        local uniqueReplicaOwners = countArrayUnique(replicaOwners)
        self.telemetry.replicaManifestBlocksSeen = self.telemetry.replicaManifestBlocksSeen + replicaBlocks
        self.telemetry.replicaManifestOwnersSeen = self.telemetry.replicaManifestOwnersSeen + uniqueReplicaOwners
        self:PushOfflineDebugEvent("manifest", string.format("peer=%s owners=%d blocks=%d", tostring(senderKey), uniqueReplicaOwners, replicaBlocks))
    end
    local comparisonResult = self:ProcessPeerManifestComparison(senderKey, manifest)
    if comparisonResult and comparisonResult.shouldRefreshUI then
        Addon:RequestRefresh("manifest")
    end
end

function Sync:SendNextManifestChunk()
    if #(self.manifestChunkQueue or {}) == 0 then
        return false
    end

    local now = nowForPacing()
    local candidateIndex
    for index = 1, #self.manifestChunkQueue do
        local queued = self.manifestChunkQueue[index]
        if (queued.readyAt or 0) <= now and self:CanSendToPeer(queued.peer, MANIFEST_CHUNK_DELAY) then
            candidateIndex = index
            break
        end
    end
    if not candidateIndex then
        return false
    end

    local queued = table.remove(self.manifestChunkQueue, candidateIndex)
    self:SendDirectEnvelope("MANI", queued.payload, queued.peer, "NORMAL")
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = now
    self.telemetry.manifestChunksSent = (self.telemetry.manifestChunksSent or 0) + 1
    return true
end
