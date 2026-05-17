local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local max = math.max

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT

function Sync:IsRequestShapeValid(_request)
    return false
end

function Sync:IsRequestAlreadySatisfied(_request)
    return false
end

function Sync:QueueRequest(sourceKey, memberKey, _legacyVersion, why, _opts)
    self.telemetry.legacyQueueRequestsIgnored = (self.telemetry.legacyQueueRequestsIgnored or 0) + 1
    Addon:Trace("request", string.format(
        "legacy-queue-noop member=%s source=%s why=%s",
        tostring(memberKey or "unknown"),
        tostring(sourceKey or "unknown"),
        tostring(why or "")
    ))
    return false
end

function Sync:BuildWantedBlockOrder(offeredBlocks)
    local rows = {}
    for index = 1, #(offeredBlocks or {}) do
        local row = offeredBlocks[index]
        if type(row) == "table" and type(row.blockKey) == "string" and row.blockKey ~= "" then
            rows[#rows + 1] = {
                blockKey = row.blockKey,
                count = tonumber(row.count or 0) or 0,
                fingerprint = row.fingerprint,
                reason = row.reason,
            }
        end
    end
    table.sort(rows, function(left, right)
        if (left.count or 0) ~= (right.count or 0) then
            return (left.count or 0) > (right.count or 0)
        end
        return tostring(left.blockKey or "") < tostring(right.blockKey or "")
    end)
    return rows
end

function Sync:QueueWantedBlock(blockKey, reason)
    local session = self.outboundSeedSession
    if type(session) ~= "table" or type(blockKey) ~= "string" or blockKey == "" then
        return false
    end
    session.wantedBlocks = session.wantedBlocks or {}
    session.wantedBlocks[#session.wantedBlocks + 1] = {
        blockKey = blockKey,
        reason = reason,
    }
    return true
end

function Sync:ClearSeedPendingState(_seedKey, reason)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    session.offeredBlocks = {}
    session.wantedBlocks = {}
    session.nextWantedIndex = 1
    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    session.lastCleanupReason = tostring(reason or "clear")
    return true
end

function Sync:RequestIndexDiff(seedKey, opts)
    opts = opts or {}
    local session = self.outboundSeedSession
    if not (type(session) == "table" and session.seedKey == seedKey) then
        return false
    end
    if session.state == "waiting-index-diff" or session.state == "completed" or session.state == "aborted" then
        return false
    end

    local digest = Addon.Data and Addon.Data.BuildRequesterIndexDigest and Addon.Data:BuildRequesterIndexDigest({
        reason = "index-diff-request",
    }) or nil
    if type(digest) ~= "table" or digest.ready ~= true then
        return false
    end

    session.diffRequestId = string.format("IDXREQ:%s:%d", tostring(seedKey), tonumber(time() or 0) or 0)
    session.diffSentAt = time()
    session.lastProgressAt = session.diffSentAt
    session.state = "waiting-index-diff"
    session.digest = digest

    local sent = self:SendDirectEnvelope("INDEX_DIFF_REQUEST", {
        sessionId = session.sessionId,
        requestId = session.diffRequestId,
        helloId = opts.helloId or session.helloId,
        cycleId = opts.cycleId or session.cycleId,
        syncModel = digest.syncModel,
        indexStatus = digest.indexStatus,
        activeOwnerCount = digest.activeOwnerCount or 0,
        activeBlockCount = digest.activeBlockCount or 0,
        activeContentCount = digest.activeContentCount or 0,
        globalFingerprint = digest.globalFingerprint,
        rows = digest.rows,
    }, seedKey, "ALERT")
    if sent then
        self.telemetry.indexDiffRequestSent = (self.telemetry.indexDiffRequestSent or 0) + 1
        self.telemetry.lastIndexDiffSeed = tostring(seedKey)
        self.telemetry.lastIndexDiffRequestId = session.diffRequestId
        return true
    end

    if self.AbortOutboundSeedSession then
        self:AbortOutboundSeedSession("index-diff-send-failed")
    end
    return false
end

function Sync:SendIndexDiffResponse(targetKey, requestPayload)
    if not self:IsValidSyncMemberKey(targetKey) then
        return false
    end
    local response = Addon.Data and Addon.Data.BuildIndexDiffResponse and Addon.Data:BuildIndexDiffResponse(requestPayload, {
        reason = "index-diff-response",
    }) or nil
    if type(response) ~= "table" or response.ready ~= true then
        return false
    end
    local sent = self:SendDirectEnvelope("INDEX_DIFF_RESPONSE", {
        sessionId = requestPayload and requestPayload.sessionId or nil,
        requestId = requestPayload and requestPayload.requestId or nil,
        helloId = requestPayload and requestPayload.helloId or nil,
        cycleId = requestPayload and requestPayload.cycleId or nil,
        syncModel = response.syncModel,
        indexStatus = response.indexStatus,
        activeOwnerCount = response.activeOwnerCount or 0,
        activeBlockCount = response.activeBlockCount or 0,
        activeContentCount = response.activeContentCount or 0,
        globalFingerprint = response.globalFingerprint,
        offeredBlocks = response.offeredBlocks,
    }, targetKey, "ALERT")
    if sent then
        self.telemetry.indexDiffResponseSent = (self.telemetry.indexDiffResponseSent or 0) + 1
        self.telemetry.blocksOffered = (self.telemetry.blocksOffered or 0) + #(response.offeredBlocks or {})
    end
    return sent
end

function Sync:HandleReceivedIndexDiffResponse(payload)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.state ~= "waiting-index-diff" then
        return false
    end
    if payload.sender ~= session.seedKey then
        return false
    end
    if payload.requestId and session.diffRequestId and payload.requestId ~= session.diffRequestId then
        return false
    end

    session.lastProgressAt = time()
    session.state = "index-diff-ready"
    session.offeredBlocks = self:BuildWantedBlockOrder(payload.offeredBlocks or {})
    session.wantedBlocks = self:BuildWantedBlockOrder(payload.offeredBlocks or {})
    session.nextWantedIndex = 1
    self.telemetry.indexDiffResponseReceived = (self.telemetry.indexDiffResponseReceived or 0) + 1
    self.telemetry.blocksOffered = (self.telemetry.blocksOffered or 0) + #(session.offeredBlocks or {})
    self.telemetry.wantedBlocksBuilt = (self.telemetry.wantedBlocksBuilt or 0) + #(session.wantedBlocks or {})

    if #(session.wantedBlocks or {}) == 0 then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("index-diff-empty")
        end
        return true
    end

    if self.RequestNextWantedBlock then
        self:RequestNextWantedBlock()
    end
    return true
end

function Sync:RequestNextWantedBlock()
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.state == "completed" or session.state == "aborted" then
        return false
    end
    if session.activeBlockKey or session.activeBlockRequestId then
        return false
    end
    local row = session.wantedBlocks and session.wantedBlocks[session.nextWantedIndex] or nil
    if not row then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("all-blocks-complete")
        end
        return false
    end

    local requestId = string.format("BLKREQ:%s:%s:%d", tostring(session.seedKey), tostring(row.blockKey), tonumber(time() or 0) or 0)
    session.activeBlockKey = row.blockKey
    session.activeBlockRequestId = requestId
    session.state = "waiting-block"
    session.blockRequestedAt = time()
    session.lastProgressAt = session.blockRequestedAt

    local sent = self:SendDirectEnvelope("BLOCK_PULL_REQUEST", {
        sessionId = session.sessionId,
        requestId = requestId,
        helloId = session.helloId,
        cycleId = session.cycleId,
        blockKey = row.blockKey,
    }, session.seedKey, "ALERT")
    if sent then
        self.telemetry.blockPullRequestSent = (self.telemetry.blockPullRequestSent or 0) + 1
        return true
    end

    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    if self.AbortOutboundSeedSession then
        self:AbortOutboundSeedSession("block-pull-send-failed")
    end
    return false
end

function Sync:ProcessRequestQueue()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() then
        return
    end

    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return
    end
    if session.state == "completed" or session.state == "aborted" then
        return
    end

    local now = time()
    local age = max(0, now - (session.lastProgressAt or session.startedAt or now))
    if age > SESSION_TIMEOUT then
        self.telemetry.requestTimeoutSession = (self.telemetry.requestTimeoutSession or 0) + 1
        if self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("session-timeout")
        end
        return
    end

    if session.state == "seed-selected" then
        self:RequestIndexDiff(session.seedKey, {
            cycleId = session.cycleId,
            helloId = session.helloId,
            sessionId = session.sessionId,
        })
        return
    end

    if session.state == "index-diff-ready" or session.state == "request-next-block" then
        self:RequestNextWantedBlock()
    end
end

function Sync:FailInFlight(_memberKey, _requeue, _reason)
    return false
end

function Sync:RequestGuildCatchup(memberKey, silent)
    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull")
    end
    if self.ScheduleHelloCycle then
        self:ScheduleHelloCycle(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull", 0.5)
    end
    if not silent then
        Addon:Print("Scheduled a hello cycle for index-diff sync.")
    end
end

function Sync:GetOldestPendingRequest()
    return nil
end
