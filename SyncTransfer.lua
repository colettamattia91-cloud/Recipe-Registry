local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local max = math.max

local nowForPacing = Private.nowForPacing
local shallowCopyArray = Private.shallowCopyArray
local shallowCopyTable = Private.shallowCopyTable

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
local OUTGOING_CHUNK_DELAY = Constants.OUTGOING_CHUNK_DELAY
local MANIFEST_CHUNK_DELAY = Constants.MANIFEST_CHUNK_DELAY
local SNAPSHOT_SESSION_WINDOW = Constants.SNAPSHOT_SESSION_WINDOW or 8

local function countQueuedChunksForSession(queue, sessionId)
    local count = 0
    for _, queued in ipairs(queue or {}) do
        if queued and queued.block and queued.block.sessionId == sessionId then
            count = count + 1
        end
    end
    return count
end

local function isRetryableRejectReason(reason)
    return reason == "PAUSED_INSTANCE"
        or reason == "LOADING_TRANSITION"
        or reason == "BUSY"
        or reason == "RATE_LIMITED"
        or reason == "TARGET_UNAVAILABLE"
end

function Sync:SendRequestReject(targetKey, requestPayload, reason, opts)
    if not self:IsValidSyncMemberKey(targetKey) then
        return false
    end
    opts = opts or {}
    return self:SendDirectEnvelope("RERR", {
        key = requestPayload and requestPayload.key or nil,
        requestId = requestPayload and requestPayload.requestId or nil,
        reason = tostring(reason or "INVALID_REQUEST"),
        retryable = opts.retryable == true,
        retryAfter = opts.retryAfter,
        requestedBlocks = type(requestPayload and requestPayload.requestedBlocks) == "table" and #(requestPayload.requestedBlocks or {}) or 0,
        knownRev = requestPayload and requestPayload.knownRev or 0,
        wantedRev = requestPayload and (requestPayload.wantRev or requestPayload.wantedRev) or 0,
    }, targetKey, "ALERT")
end

function Sync:HandlePausedRequest(payload, pauseReason)
    if not (payload and self:IsValidSyncMemberKey(payload.sender)) then
        return
    end
    self:SendRequestReject(payload.sender, payload, pauseReason or "PAUSED_INSTANCE", {
        retryable = true,
        retryAfter = 15,
    })
end

function Sync:HandleRequestReject(payload)
    if not (payload and self:IsValidSyncMemberKey(payload.sender) and self:IsValidSyncMemberKey(payload.key)) then
        return
    end
    local request = self:GetInFlightRequest(payload.key)
    if not request then
        return
    end
    if request.source ~= payload.sender then
        return
    end
    if payload.requestId and request.requestId and payload.requestId ~= request.requestId then
        return
    end

    local retryable = payload.retryable == true
    local reason = tostring(payload.reason or "REJECT")
    Addon:Trace("request", string.format(
        "reject peer=%s member=%s reqId=%s reason=%s retryable=%s",
        tostring(payload.sender or "?"),
        tostring(payload.key or "?"),
        tostring(payload.requestId or "none"),
        reason,
        tostring(retryable)
    ))
    self.telemetry.rejectsTotal = (self.telemetry.rejectsTotal or 0) + 1
    self.telemetry.lastRejectPeer = tostring(payload.sender)
    self.telemetry.lastRejectReason = reason
    if retryable then
        self.telemetry.rejectsRetryable = (self.telemetry.rejectsRetryable or 0) + 1
    else
        self.telemetry.rejectsPermanent = (self.telemetry.rejectsPermanent or 0) + 1
        self:RememberPeerReject(payload.sender, request, reason, false, payload.retryAfter)
    end

    if retryable then
        self:MarkPeerFailure(payload.sender, "reject:" .. reason, request)
        if self:IsRequestShapeValid(request) and not self:IsRequestAlreadySatisfied(request) then
            self.pendingRequests[request.memberKey] = {
                source = request.source,
                memberKey = request.memberKey,
                rev = request.rev,
                why = request.why,
                queuedAt = time(),
                readyAt = time() + max(1, tonumber(payload.retryAfter) or 5),
                attempts = request.attempts or 1,
                resumeAttempts = 0,
                allowReplicaSource = request.allowReplicaSource == true,
                requestedBlocks = Private.cloneStringSet(request.requestedBlocks),
                expectedFingerprints = Private.cloneFingerprintMap(request.expectedFingerprints),
            }
        end
    else
        local health = self.peerHealth and self.peerHealth[payload.sender] or nil
        if health then
            health.snapshotBackoffUntil = max(health.snapshotBackoffUntil or 0, time() + 120)
        end
    end

    self.partialReceive[payload.key] = nil
    self:ClearInFlightRequest(payload.key)
    self.telemetry.requestIdActive = nil
    Addon:RequestRefresh("queue")
    self:ScheduleQueuePump()
end

function Sync:BuildSessionId(memberKey, rev, targetKey)
    self._sessionIdCounter = (self._sessionIdCounter or 0) + 1
    return string.format(
        "%s:%d:%d:%s:%d",
        memberKey or "unknown",
        rev or 0,
        time(),
        targetKey or "unknown",
        self._sessionIdCounter
    )
end

function Sync:HandleRequest(payload)
    local targetKey = payload.sender
    if not self:IsValidSyncMemberKey(targetKey) then return end
    if not self:IsValidSyncMemberKey(payload.key) then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=INVALID_REQUEST", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "INVALID_REQUEST", { retryable = false })
        return
    end
    if self:IsMockKey(targetKey) or self:IsMockKey(payload.key) then return end

    local pauseReason = Addon.SyncPausePolicy and Addon.SyncPausePolicy:GetProtocolPauseReason("REQ") or nil
    if pauseReason then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=%s", tostring(targetKey), tostring(payload.key), tostring(pauseReason)))
        self:SendRequestReject(targetKey, payload, pauseReason, {
            retryable = true,
            retryAfter = 15,
        })
        return
    end
    if self:EstimateRuntimeQueuePressure() >= 90 then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=BUSY", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "BUSY", {
            retryable = true,
            retryAfter = 10,
        })
        return
    end

    local entry = Addon.Data:GetMember(payload.key)
    if not entry then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=NO_ENTRY", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "NO_ENTRY", { retryable = false })
        return
    end
    if (entry.guildStatus or "active") ~= "active" then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=INACTIVE_ENTRY", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "INACTIVE_ENTRY", { retryable = false })
        return
    end

    local requestedBlocks = payload.requestedBlocks or {}
    local hasSpecificBlockRequest = type(requestedBlocks) == "table" and #requestedBlocks > 0
    if (entry.rev or 0) <= (payload.knownRev or 0) then
        if not hasSpecificBlockRequest then
            self:SendRequestReject(targetKey, payload, "ALREADY_KNOWN", { retryable = false })
            return
        end

        local hasRequestedBlock = false
        for _, blockKey in ipairs(requestedBlocks) do
            local ownerCharacter, professionKey = Addon.Data:ParseSyncBlockKey(blockKey)
            if ownerCharacter == payload.key and professionKey then
                local prof = entry.professions and entry.professions[professionKey]
                if prof and (prof.guildStatus or entry.guildStatus or "active") == "active" then
                    hasRequestedBlock = true
                    break
                end
            end
        end
        if not hasRequestedBlock then
            Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=NO_REQUESTED_BLOCK", tostring(targetKey), tostring(payload.key)))
            self:SendRequestReject(targetKey, payload, "NO_REQUESTED_BLOCK", { retryable = false })
            return
        end
    end

    if payload.key ~= self:GetSelfKey()
        and payload.key ~= targetKey
        and Addon.Data:IsMemberOnline(payload.key) then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=NOT_SERVEABLE_REPLICA", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "NOT_SERVEABLE_REPLICA", { retryable = false })
        return
    end

    local sessionId = self:BuildSessionId(payload.key, entry.rev or 0, targetKey)
    local chunks = Addon.Data:BuildSnapshotChunks(payload.key, {
        requestedBlocks = hasSpecificBlockRequest and requestedBlocks or nil,
    })
    if #chunks == 0 then
        Addon:Trace("transfer", string.format("reject-send target=%s member=%s reason=EMPTY_SNAPSHOT", tostring(targetKey), tostring(payload.key)))
        self:SendRequestReject(targetKey, payload, "EMPTY_SNAPSHOT", { retryable = false })
        return
    end

    Addon:Trace("transfer", string.format(
        "serve target=%s member=%s session=%s chunks=%d requestedBlocks=%d replica=%s",
        tostring(targetKey),
        tostring(payload.key),
        tostring(sessionId),
        #chunks,
        #(requestedBlocks or {}),
        tostring(payload.key ~= self:GetSelfKey() and payload.key ~= targetKey)
    ))

    if payload.requestedBlocks and #payload.requestedBlocks > 0
        and payload.key ~= self:GetSelfKey()
        and payload.key ~= targetKey
        and not Addon.Data:IsMemberOnline(payload.key) then
        self.telemetry.replicaRequestsServed = self.telemetry.replicaRequestsServed + 1
        self:PushOfflineDebugEvent("served", string.format("%s to %s blocks=%d", tostring(payload.key), tostring(targetKey), #payload.requestedBlocks))
    end

    self.outgoingSessions[sessionId] = {
        sessionId = sessionId,
        memberKey = payload.key,
        targetKey = targetKey,
        rev = entry.rev or 0,
        updatedAt = entry.updatedAt or 0,
        total = #chunks,
        chunks = chunks,
        acceptSnapCodec = payload.acceptSnapCodec,
        createdAt = time(),
        lastSentAt = 0,
        nextSeqToQueue = 1,
    }

    self.lastSnapshotServedAt = time()

    self:SendOutgoingSession(sessionId)
end

function Sync:SendOutgoingSession(sessionId, onlySeqs)
    local state = self.outgoingSessions[sessionId]
    if not state then return end

    if onlySeqs and #onlySeqs > 0 then
        local seqs = {}
        for _, seq in ipairs(onlySeqs) do seqs[#seqs + 1] = seq end
        sort(seqs)
        for _, seq in ipairs(seqs) do
            local chunk = state.chunks[seq]
            if chunk then
                self:QueueOutboundBlock(state.targetKey, {
                    sessionId = sessionId,
                    key = state.memberKey,
                    rev = chunk.rev,
                    updatedAt = chunk.updatedAt,
                    sourceType = chunk.sourceType,
                    profession = chunk.profession,
                    skillRank = chunk.skillRank,
                    skillMaxRank = chunk.skillMaxRank,
                    specialization = chunk.specialization,
                    recipeKeys = chunk.recipeKeys,
                    seq = seq,
                    total = state.total,
                })
            end
        end
        return
    end

    state.nextSeqToQueue = state.nextSeqToQueue or 1
    while state.nextSeqToQueue <= state.total
        and countQueuedChunksForSession(self.outboundChunkQueue, sessionId) < SNAPSHOT_SESSION_WINDOW do
        local seq = state.nextSeqToQueue
        local chunk = state.chunks[seq]
        state.nextSeqToQueue = state.nextSeqToQueue + 1
        if chunk then
            self:QueueOutboundBlock(state.targetKey, {
                sessionId = sessionId,
                key = state.memberKey,
                rev = chunk.rev,
                updatedAt = chunk.updatedAt,
                sourceType = chunk.sourceType,
                profession = chunk.profession,
                skillRank = chunk.skillRank,
                skillMaxRank = chunk.skillMaxRank,
                specialization = chunk.specialization,
                recipeKeys = chunk.recipeKeys,
                seq = seq,
                total = state.total,
            })
        end
    end
end

function Sync:HandleSnapshotChunk(payload)
    if not self:IsValidSyncMemberKey(payload.key) or not self:IsValidSyncMemberKey(payload.sender) then return end
    if payload.key == self:GetSelfKey() and payload.sender == self:GetSelfKey() then return end
    local completed = self.completedIncomingSessions and self.completedIncomingSessions[payload.key] or nil
    if completed
        and completed.sessionId == payload.sessionId
        and completed.rev == payload.rev
        and completed.sender == payload.sender then
        return
    end

    local state = self.partialReceive[payload.key]
    if not state or state.sessionId ~= payload.sessionId or state.rev ~= payload.rev then
        state = {
            sessionId = payload.sessionId,
            memberKey = payload.key,
            source = payload.sender,
            rev = payload.rev,
            updatedAt = payload.updatedAt,
            total = payload.total,
            seen = {},
            startedAt = time(),
            lastProgressAt = time(),
        }
        self.partialReceive[payload.key] = state
    end

    state.seen[payload.seq] = true
    state.total = payload.total
    state.lastProgressAt = time()

    local request = self:GetInFlightRequest(payload.key)
    if request then
        local now = time()
        if request.sessionId ~= payload.sessionId then
            request.sessionStartedAt = now
        end
        request.sessionId = payload.sessionId
        request.lastProgressAt = now
        request.source = payload.sender or request.source
        self:RefreshPrimaryInFlight()
    end

    self:EnqueueReceivedChunk(payload)

    local complete = true
    for i = 1, payload.total do
        if not state.seen[i] then
            complete = false
            break
        end
    end

    if complete then
        Addon:Trace("transfer", string.format(
            "snapshot-complete sender=%s member=%s session=%s rev=%d total=%d",
            tostring(payload.sender),
            tostring(payload.key),
            tostring(payload.sessionId or "none"),
            payload.rev or 0,
            payload.total or 0
        ))
        self.completedIncomingSessions[payload.key] = {
            sessionId = payload.sessionId,
            rev = payload.rev,
            sender = payload.sender,
            completedAt = time(),
        }
        self:ReleaseCompletedTransferState(payload.key, payload.sessionId, "snapshot-complete")
        self.inboundFinalizeQueue[#self.inboundFinalizeQueue + 1] = {
            memberKey = payload.key,
            rev = payload.rev,
            updatedAt = payload.updatedAt,
            sender = payload.sender,
            sessionId = payload.sessionId,
        }
        self:EnforceRuntimeQueueCaps("snapshot-complete")
        if not self:IsMockKey(payload.sender) then
            self:SendDirectEnvelope("DONE", {
                sessionId = payload.sessionId,
                key = payload.key,
                rev = payload.rev,
            }, payload.sender, "ALERT")
        end

        self:MarkPeerSuccess(payload.sender)

        self:ClearInFlightRequest(payload.key)

        Addon:RequestRefresh("snapshot-complete")
        self:ScheduleQueuePump()
    end
end

function Sync:GetMissingSeqs(state)
    local missing = {}
    if not state then return missing end
    for i = 1, (state.total or 0) do
        if not state.seen[i] then
            missing[#missing + 1] = i
        end
    end
    return missing
end

function Sync:SendResumeForInFlight(memberKey)
    local request = memberKey and self:GetInFlightRequest(memberKey) or self:GetInFlightRequest()
    if not request then return end
    if self:IsMockKey(request.source) then return end
    local partial = self.partialReceive[request.memberKey]
    if not partial or partial.sessionId ~= request.sessionId then
        self:FailInFlight(request.memberKey, true, "resume-mismatch")
        return
    end

    local missing = self:GetMissingSeqs(partial)
    if #missing == 0 then return end

    Addon:Trace("request", string.format(
        "resume-request member=%s source=%s session=%s missing=%s",
        tostring(partial.memberKey),
        tostring(request.source),
        tostring(partial.sessionId or "none"),
        table.concat(missing, ",")
    ))
    self:SendDirectEnvelope("RESUME", {
        sessionId = partial.sessionId,
        key = partial.memberKey,
        rev = partial.rev,
        missing = missing,
    }, request.source, "ALERT")
end

function Sync:HandleResumeRequest(payload)
    local session = self.outgoingSessions[payload.sessionId]
    if not session then return end
    if not self:IsValidSyncMemberKey(payload.sender) or not self:IsValidSyncMemberKey(payload.key) then return end
    if self:IsMockKey(payload.sender) or self:IsMockKey(payload.key) then return end
    if session.targetKey ~= payload.sender then return end
    if session.memberKey ~= payload.key or session.rev ~= payload.rev then return end

    local missing = shallowCopyArray(payload.missing or {})
    if #missing == 0 then return end
    Addon:Trace("transfer", string.format(
        "resume-serve target=%s member=%s session=%s missing=%s",
        tostring(payload.sender),
        tostring(payload.key),
        tostring(payload.sessionId or "none"),
        table.concat(missing, ",")
    ))
    self:SendOutgoingSession(payload.sessionId, missing)
end

function Sync:HandleTransferDone(payload)
    local session = self.outgoingSessions[payload.sessionId]
    if not session then return end
    if not self:IsValidSyncMemberKey(payload.sender) then return end
    if self:IsMockKey(payload.sender) then return end
    if session.targetKey ~= payload.sender then return end
    self:ReleaseCompletedTransferState(session.memberKey, payload.sessionId, "done")
end

function Sync:PruneOutgoingSessions()
    local now = time()
    local removed = 0
    for sessionId, state in pairs(self.outgoingSessions) do
        if (now - (state.createdAt or now)) > SESSION_TIMEOUT then
            removed = removed + self:ReleaseCompletedTransferState(state.memberKey, sessionId, "outgoing-timeout")
        end
    end
    if removed > 0 then
        self.telemetry.prunedOutgoingSessions = (self.telemetry.prunedOutgoingSessions or 0) + removed
    end
end

function Sync:PrunePartialReceives()
    local now = time()
    local removed = 0
    for memberKey, state in pairs(self.partialReceive) do
        if (now - (state.lastProgressAt or now)) > SESSION_TIMEOUT then
            removed = removed + self:ReleaseCompletedTransferState(memberKey, state and state.sessionId, "partial-timeout")
            if self:GetInFlightRequest(memberKey) then
                self:FailInFlight(memberKey, true, "partial-timeout")
            end
        end
    end
    if removed > 0 then
        self.telemetry.prunedPartialReceives = (self.telemetry.prunedPartialReceives or 0) + removed
    end
end

function Sync:QueueOutboundBlock(peer, block)
    if not peer or not block then return false end
    self.outboundChunkQueue[#self.outboundChunkQueue + 1] = {
        peer = peer,
        block = block,
        queuedAt = time(),
    }
    self:EnforceRuntimeQueueCaps("outbound")
    return true
end

function Sync:CanSendToPeer(peer, delay)
    if not peer then return false end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseOutbound() then
        return false
    end
    local pacing = self.peerPacing[peer]
    if pacing and (nowForPacing() - (pacing.lastSentAt or 0)) < (delay or OUTGOING_CHUNK_DELAY) then
        return false
    end
    return true
end

function Sync:SendNextSnapshotChunk()
    local candidateIndex
    for index = 1, #self.outboundChunkQueue do
        if self:CanSendToPeer(self.outboundChunkQueue[index].peer, OUTGOING_CHUNK_DELAY) then
            candidateIndex = index
            break
        end
    end
    if not candidateIndex then
        return false
    end

    local queued = table.remove(self.outboundChunkQueue, candidateIndex)
    local block = queued.block
    local session = self.outgoingSessions[block.sessionId]
    local wireBlock = block
    if self.EncodeSnapshotBlockForWire then
        wireBlock = self:EncodeSnapshotBlockForWire(block, queued.peer, {
            acceptSnapCodec = session and session.acceptSnapCodec or nil,
            reason = "snapshot-send",
        }) or block
    end
    local sent = self:SendDirectEnvelope("SNAP", wireBlock, queued.peer, "BULK")
    if not sent then
        Addon:Trace("transfer", string.format(
            "snap-send-fail target=%s member=%s session=%s seq=%d/%d",
            tostring(queued.peer),
            tostring(block.key),
            tostring(block.sessionId or "none"),
            block.seq or 0,
            block.total or 0
        ))
        self:MarkPeerFailure(queued.peer, "target-unavailable")
        return false
    end
    Addon:Trace(block.key ~= queued.peer and block.key ~= Addon.Data:GetPlayerKey() and "offline" or "transfer", string.format(
        "snap-send target=%s member=%s session=%s seq=%d/%d codec=%s",
        tostring(queued.peer),
        tostring(block.key),
        tostring(block.sessionId or "none"),
        block.seq or 0,
        block.total or 0,
        tostring(wireBlock and wireBlock.codec or "legacy")
    ))
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = nowForPacing()
    self.telemetry.sentChunks = self.telemetry.sentChunks + 1

    if session then
        session.lastSentAt = time()
        self:SendOutgoingSession(block.sessionId)
    end
    return true
end

function Sync:SendNextLowPriorityChunk()
    if #self.outboundChunkQueue > 0 and self:SendNextSnapshotChunk() then
        return true
    end
    if self:SendNextManifestChunk() then
        return true
    end
    return true
end

function Sync:EnqueueReceivedChunk(payload)
    self.inboundChunkQueue[#self.inboundChunkQueue + 1] = shallowCopyTable(payload)
    self.telemetry.receivedChunks = self.telemetry.receivedChunks + 1
    self:EnforceRuntimeQueueCaps("inbound")
end

function Sync:DecodeChunkStep(payload)
    if not payload then return false end
    if payload.codec and self.DecodeSnapshotBlockFromWire then
        local decoded, ok, reason = self:DecodeSnapshotBlockFromWire(payload)
        if not ok then
            Addon:Trace("transfer", string.format(
                "decode-drop member=%s sender=%s session=%s reason=%s",
                tostring(payload.key or "?"),
                tostring(payload.sender or "?"),
                tostring(payload.sessionId or "none"),
                tostring(reason or "codec-error")
            ))
            self.telemetry.snapCodecDropped = (self.telemetry.snapCodecDropped or 0) + 1
            if payload.key and payload.sessionId and self.ReleaseCompletedTransferState then
                self:ReleaseCompletedTransferState(payload.key, payload.sessionId, "codec-error")
            end
            if payload.sender and self.MarkPeerFailure then
                self:MarkPeerFailure(payload.sender, reason or "codec-error")
            end
            return false
        end
        payload = decoded
    end
    if not self:IsValidSyncMemberKey(payload.key) then return false end
    Addon:Trace(payload.sender and payload.sender ~= payload.key and "offline" or "transfer", string.format(
        "decode member=%s sender=%s session=%s seq=%d/%d sourceType=%s",
        tostring(payload.key),
        tostring(payload.sender or payload.key),
        tostring(payload.sessionId or "none"),
        payload.seq or 0,
        payload.total or 0,
        tostring(payload.sourceType or "replica")
    ))
    Addon.Data:AppendIncomingChunk({
        memberKey = payload.key,
        rev = payload.rev,
        updatedAt = payload.updatedAt,
        sourceType = payload.sourceType or "replica",
        profession = payload.profession,
        skillRank = payload.skillRank,
        skillMaxRank = payload.skillMaxRank,
        specialization = payload.specialization,
        recipeKeys = payload.recipeKeys,
    })
    return true
end

function Sync:MergeChunkStep(item)
    if not item then return false end
    if not self:IsValidSyncMemberKey(item.memberKey) then return false end
    local hadLocalEntry = Addon.Data:GetMember(item.memberKey) ~= nil
    local localEntry = Addon.Data:GetMember(item.memberKey)
    if item.sender and item.sender ~= item.memberKey
        and localEntry
        and (localEntry.guildStatus or "active") ~= "active" then
        Addon:Trace("offline", string.format(
            "apply-skip member=%s sender=%s reason=local-stale",
            tostring(item.memberKey),
            tostring(item.sender)
        ))
        if Addon.Data._incoming then
            Addon.Data._incoming[item.memberKey] = nil
        end
        self:PushOfflineDebugEvent("stale-skip", string.format("%s via %s", tostring(item.memberKey), tostring(item.sender)))
        return false
    end
    local sourceType = (item.sender and item.sender == item.memberKey) and "owner" or "replica"
    local merged = Addon.Data:FinalizeIncomingSnapshot(item.memberKey, item.rev, {
        sourceType = sourceType,
        isMock = self:IsMockKey(item.memberKey) or self:IsMockKey(item.sender),
    })
    if merged then
        Addon:Trace(item.sender and item.sender ~= item.memberKey and "offline" or "transfer", string.format(
            "applied member=%s sender=%s rev=%d sourceType=%s",
            tostring(item.memberKey),
            tostring(item.sender or item.memberKey),
            item.rev or 0,
            tostring(sourceType)
        ))
        self.telemetry.appliedChunks = self.telemetry.appliedChunks + 1
        if item.sender and item.sender ~= item.memberKey and not Addon.Data:IsMemberOnline(item.memberKey) then
            self.telemetry.replicaOwnersApplied = self.telemetry.replicaOwnersApplied + 1
            if not hadLocalEntry then
                self.telemetry.replicaNewOwnersApplied = self.telemetry.replicaNewOwnersApplied + 1
            end
            self:PushOfflineDebugEvent("applied", string.format("%s via %s new=%s", tostring(item.memberKey), tostring(item.sender), tostring(not hadLocalEntry)))
        end
        if self:IsCoordinator() then
            self:BroadcastIndex(item.memberKey, item.rev, item.updatedAt, item.memberKey, "snapshot-merged")
        end
    else
        Addon:Trace(item.sender and item.sender ~= item.memberKey and "offline" or "transfer", string.format(
            "apply-skip member=%s sender=%s rev=%d reason=not-newer-or-equivalent",
            tostring(item.memberKey),
            tostring(item.sender or item.memberKey),
            item.rev or 0
        ))
    end
    return merged
end

function Sync:ProcessInboundQueue()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseInboundApply() then
        return true
    end

    if #self.inboundChunkQueue > 0 then
        local payload = table.remove(self.inboundChunkQueue, 1)
        self:DecodeChunkStep(payload)
        return true
    end

    if #self.inboundFinalizeQueue > 0 then
        local item = table.remove(self.inboundFinalizeQueue, 1)
        self:MergeChunkStep(item)
    end

    return true
end
