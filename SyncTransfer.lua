local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort

local nowForPacing = Private.nowForPacing
local shallowCopyArray = Private.shallowCopyArray
local shallowCopyTable = Private.shallowCopyTable

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
local OUTGOING_CHUNK_DELAY = Constants.OUTGOING_CHUNK_DELAY
local MANIFEST_CHUNK_DELAY = Constants.MANIFEST_CHUNK_DELAY

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
    if not self:IsValidSyncMemberKey(targetKey) or not self:IsValidSyncMemberKey(payload.key) then return end
    if self:IsMockKey(targetKey) or self:IsMockKey(payload.key) then return end

    local entry = Addon.Data:GetMember(payload.key)
    if not entry then return end
    if (entry.guildStatus or "active") ~= "active" then return end

    local requestedBlocks = payload.requestedBlocks or {}
    local hasSpecificBlockRequest = type(requestedBlocks) == "table" and #requestedBlocks > 0
    if (entry.rev or 0) <= (payload.knownRev or 0) then
        if not hasSpecificBlockRequest then
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
            return
        end
    end

    local sessionId = self:BuildSessionId(payload.key, entry.rev or 0, targetKey)
    local chunks = Addon.Data:BuildSnapshotChunks(payload.key, {
        requestedBlocks = hasSpecificBlockRequest and requestedBlocks or nil,
    })
    if #chunks == 0 then return end

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
    }

    self:SendOutgoingSession(sessionId)
end

function Sync:SendOutgoingSession(sessionId, onlySeqs)
    local state = self.outgoingSessions[sessionId]
    if not state then return end

    local seqs = {}
    if onlySeqs and #onlySeqs > 0 then
        for _, seq in ipairs(onlySeqs) do seqs[#seqs + 1] = seq end
        sort(seqs)
    else
        for seq = 1, state.total do seqs[#seqs + 1] = seq end
    end

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
end

function Sync:HandleSnapshotChunk(payload)
    if not self:IsValidSyncMemberKey(payload.key) or not self:IsValidSyncMemberKey(payload.sender) then return end
    if payload.key == self:GetSelfKey() and payload.sender == self:GetSelfKey() then return end

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
        request.sessionId = payload.sessionId
        request.lastProgressAt = time()
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
    self:SendDirectEnvelope("SNAP", wireBlock, queued.peer, "BULK")
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = nowForPacing()
    self.telemetry.sentChunks = self.telemetry.sentChunks + 1

    if session then
        session.lastSentAt = time()
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
