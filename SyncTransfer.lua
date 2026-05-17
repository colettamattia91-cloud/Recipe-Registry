local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private

local time = time

local function recordLegacyTransferNoop(self, kind, detail)
    self.telemetry.legacyMessagesIgnored = (self.telemetry.legacyMessagesIgnored or 0) + 1
    self.telemetry.lastLegacyMessageIgnored = tostring(kind or "legacy")
    Addon:Trace("transfer", string.format(
        "legacy-transfer-noop kind=%s detail=%s",
        tostring(kind or "legacy"),
        tostring(detail or "none")
    ))
end

function Sync:SendRequestReject(_targetKey, _requestPayload, _reason, _opts)
    return false
end

function Sync:HandlePausedRequest(payload, _pauseReason)
    recordLegacyTransferNoop(self, "REQ", payload and payload.sender)
end

function Sync:HandleRequestReject(payload)
    recordLegacyTransferNoop(self, "RERR", payload and payload.sender)
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
        sessionId = requestPayload.sessionId,
        requestId = requestPayload.requestId,
        helloId = requestPayload.helloId,
        cycleId = requestPayload.cycleId,
        blockKey = snapshot.blockKey,
        ownerCharacter = snapshot.ownerCharacter,
        professionKey = snapshot.professionKey,
        recipeKeys = snapshot.recipeKeys,
        specialization = snapshot.specialization,
        skillRank = snapshot.skillRank,
        skillMaxRank = snapshot.skillMaxRank,
        metadata = snapshot.metadata,
        contentCount = snapshot.contentCount,
        fingerprint = snapshot.fingerprint,
    }, targetKey, "BULK")
    if sent then
        self.telemetry.blockSnapshotSent = (self.telemetry.blockSnapshotSent or 0) + 1
        self.lastSnapshotServedAt = time()
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

    local applied = false
    local result = nil
    if Addon.Data and Addon.Data.ApplyIncomingBlockAdditive then
        applied, result = Addon.Data:ApplyIncomingBlockAdditive(payload.blockKey, payload, {
            sourceType = payload.sender == payload.ownerCharacter and "owner" or "replica",
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
    session.lastMergedBlockFingerprint = fingerprint
    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    session.nextWantedIndex = (session.nextWantedIndex or 1) + 1
    session.state = "request-next-block"
    self.lastSnapshotSuccessAt = time()
    self:MarkPeerSuccess(payload.sender)

    if self.RequestNextWantedBlock then
        self:RequestNextWantedBlock()
    end
    return result or true
end

function Sync:HandleRequest(payload)
    recordLegacyTransferNoop(self, "REQ", payload and payload.sender)
end

function Sync:HandleSnapshotChunk(payload)
    recordLegacyTransferNoop(self, "SNAP", payload and payload.sender)
end

function Sync:HandleResumeRequest(payload)
    recordLegacyTransferNoop(self, "RESUME", payload and payload.sender)
end

function Sync:HandleTransferDone(payload)
    recordLegacyTransferNoop(self, "DONE", payload and payload.sender)
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
