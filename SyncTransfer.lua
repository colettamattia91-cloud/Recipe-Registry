local Addon = _G.RecipeRegistry
local Sync = Addon.Sync

local time = time

local function recordRemovedInbound(self, kind, senderKey)
    self.telemetry.legacyMessagesIgnored = (self.telemetry.legacyMessagesIgnored or 0) + 1
    self.telemetry.ignoredRemovedInbound = (self.telemetry.ignoredRemovedInbound or 0) + 1
    self.telemetry.lastLegacyMessageIgnored = tostring(kind or "unknown")
    Addon:Trace("sync", string.format(
        "removed-transfer kind=%s sender=%s",
        tostring(kind or "unknown"),
        tostring(senderKey or "unknown")
    ))
end

function Sync:SendRequestReject(_targetKey, _requestPayload, _reason, _opts)
    return false
end

function Sync:HandlePausedRequest(payload, _pauseReason)
    recordRemovedInbound(self, "REQ", payload and payload.sender)
end

function Sync:HandleRequestReject(payload)
    recordRemovedInbound(self, "RERR", payload and payload.sender)
end

function Sync:SendBlockSnapshot(targetKey, requestPayload)
    if not (type(requestPayload) == "table" and type(requestPayload.blockKey) == "string") then
        return false
    end
    local snapshot = Addon.Data and Addon.Data.BuildBlockSnapshot and Addon.Data:BuildBlockSnapshot(requestPayload.blockKey, {
        snapshotKind = "block-pull",
    }) or nil
    if type(snapshot) ~= "table" then
        return false
    end
    local sent = self:SendDirectEnvelope("BLOCK_SNAPSHOT", {
        requestId = requestPayload.requestId,
        blockKey = snapshot.blockKey,
        blockPayload = {
            ownerCharacter = snapshot.ownerCharacter,
            professionKey = snapshot.professionKey,
            recipeKeys = snapshot.recipeKeys,
            specialization = snapshot.specialization,
            skillRank = snapshot.skillRank,
            skillMaxRank = snapshot.skillMaxRank,
            metadata = snapshot.metadata,
        },
    }, targetKey, "BULK")
    if sent then
        self.telemetry.blockSnapshotSent = (self.telemetry.blockSnapshotSent or 0) + 1
        self.lastSnapshotServedAt = time()
        Addon:Trace("sync", string.format(
            "block-snapshot-sent peer=%s requestId=%s block=%s recipes=%d",
            tostring(targetKey or "unknown"),
            tostring(requestPayload.requestId or "none"),
            tostring(snapshot.blockKey or "none"),
            #(snapshot.recipeKeys or {})
        ))
    end
    return sent
end

function Sync:HandleReceivedBlockSnapshot(payload)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.state ~= "waiting-block" then
        return false
    end
    if payload.sender ~= session.seedKey then
        return false
    end
    if payload.requestId and session.activeBlockRequestId and payload.requestId ~= session.activeBlockRequestId then
        return false
    end
    if payload.blockKey ~= session.activeBlockKey then
        return false
    end

    session.lastProgressAt = time()
    self.telemetry.blockSnapshotReceived = (self.telemetry.blockSnapshotReceived or 0) + 1
    Addon:Trace("sync", string.format(
        "block-snapshot-received peer=%s requestId=%s block=%s",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        tostring(payload.blockKey or "none")
    ))

    local applied = false
    local result = nil
    local incomingPayload = payload.blockPayload or payload
    if type(incomingPayload) == "table" and incomingPayload.blockKey == nil then
        incomingPayload = {
            blockKey = payload.blockKey,
            ownerCharacter = incomingPayload.ownerCharacter,
            professionKey = incomingPayload.professionKey,
            recipeKeys = incomingPayload.recipeKeys,
            specialization = incomingPayload.specialization,
            skillRank = incomingPayload.skillRank,
            skillMaxRank = incomingPayload.skillMaxRank,
            metadata = incomingPayload.metadata,
        }
    end
    if Addon.Data and Addon.Data.ApplyIncomingBlockAdditive then
        applied, result = Addon.Data:ApplyIncomingBlockAdditive(payload.blockKey, incomingPayload, {
            sourceType = payload.sender == ((payload.blockPayload and payload.blockPayload.ownerCharacter) or payload.ownerCharacter) and "owner" or "replica",
        })
    end
    if not applied then
        if self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("block-merge-failed")
        end
        return false
    end

    local fingerprint = Addon.Data and Addon.Data.RecomputeLocalBlockFingerprint
        and Addon.Data:RecomputeLocalBlockFingerprint(payload.blockKey)
        or nil
    self.telemetry.blockMergedImmediate = (self.telemetry.blockMergedImmediate or 0) + 1
    self.telemetry.blockFingerprintRecomputed = (self.telemetry.blockFingerprintRecomputed or 0) + 1
    self.telemetry.lastMergedBlockKey = tostring(payload.blockKey)
    self.telemetry.lastMergedBlockFingerprint = fingerprint
    Addon:Trace("sync", string.format(
        "block-merge-complete block=%s fingerprint=%s",
        tostring(payload.blockKey or "none"),
        tostring(fingerprint or "none")
    ))

    session.lastMergedBlockFingerprint = fingerprint
    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    session.nextWantedIndex = (session.nextWantedIndex or 1) + 1
    self.lastSnapshotSuccessAt = time()
    self:MarkPeerSuccess(payload.sender)
    if not (session.wantedBlocks and session.wantedBlocks[session.nextWantedIndex]) then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("all-blocks-complete")
        end
        return result or true
    end
    if self.ScheduleNextWantedBlock then
        self:ScheduleNextWantedBlock()
    end
    return result or true
end

function Sync:HandleRequest(payload)
    recordRemovedInbound(self, "REQ", payload and payload.sender)
end

function Sync:HandleSnapshotChunk(payload)
    recordRemovedInbound(self, "SNAP", payload and payload.sender)
end

function Sync:HandleResumeRequest(payload)
    recordRemovedInbound(self, "RESUME", payload and payload.sender)
end

function Sync:HandleTransferDone(payload)
    recordRemovedInbound(self, "DONE", payload and payload.sender)
end

function Sync:PruneOutgoingSessions()
    return 0
end

function Sync:PrunePartialReceives()
    return 0
end

function Sync:QueueOutboundBlock(_peer, _block)
    return false
end

function Sync:CanSendToPeer(_peer, _delay)
    return false
end

function Sync:SendNextLowPriorityChunk()
    return true
end

function Sync:EnqueueReceivedChunk(_payload)
    return false
end

function Sync:DecodeChunkStep(_payload)
    return false
end

function Sync:MergeChunkStep(_item)
    return false
end

function Sync:ProcessInboundQueue()
    return true
end
