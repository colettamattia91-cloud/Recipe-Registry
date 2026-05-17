local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local max = math.max

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
local BLOCK_PULL_DELAY_SECONDS = Constants.BLOCK_PULL_DELAY_SECONDS or 1.0

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

function Sync:RequestIndexDiff(seedKey)
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

    session.diffRequestId = string.format("DIFFREQ:%s:%d", tostring(seedKey), tonumber(time() or 0) or 0)
    session.diffSentAt = time()
    session.lastProgressAt = session.diffSentAt
    session.state = "waiting-index-diff"

    local sent = self:SendDirectEnvelope("INDEX_DIFF_REQUEST", {
        requestId = session.diffRequestId,
        blocks = digest.blocks,
    }, seedKey, "ALERT")
    if sent then
        self.telemetry.indexDiffRequestSent = (self.telemetry.indexDiffRequestSent or 0) + 1
        self.telemetry.lastIndexDiffSeed = tostring(seedKey)
        self.telemetry.lastIndexDiffRequestId = session.diffRequestId
        Addon:Trace("sync", string.format(
            "index-diff-request-sent peer=%s requestId=%s blocks=%d",
            tostring(seedKey),
            tostring(session.diffRequestId),
            tonumber(digest.activeBlockCount or 0) or 0
        ))
        return true
    end

    if self.AbortOutboundSeedSession then
        self:AbortOutboundSeedSession("index-diff-send-failed")
    end
    return false
end

function Sync:SendIndexDiffResponse(targetKey, requestPayload)
    if not self:IsValidSyncMemberKey(targetKey) then
        return false, nil
    end
    local response = Addon.Data and Addon.Data.BuildIndexDiffResponse and Addon.Data:BuildIndexDiffResponse(requestPayload, {
        reason = "index-diff-response",
    }) or nil
    if type(response) ~= "table" or response.ready ~= true then
        return false, response
    end
    local sent = self:SendDirectEnvelope("INDEX_DIFF_RESPONSE", {
        requestId = requestPayload and requestPayload.requestId or nil,
        offeredBlocks = response.offeredBlocks,
    }, targetKey, "ALERT")
    if sent then
        local reasons = {}
        for index = 1, #(response.offeredBlocks or {}) do
            local row = response.offeredBlocks[index]
            if row and row.reason then
                reasons[#reasons + 1] = tostring(row.reason)
            end
        end
        self.telemetry.indexDiffResponseSent = (self.telemetry.indexDiffResponseSent or 0) + 1
        self.telemetry.blocksOffered = (self.telemetry.blocksOffered or 0) + #(response.offeredBlocks or {})
        self.telemetry.lastBlockOfferReasons = table.concat(reasons, ",")
        Addon:Trace("sync", string.format(
            "index-diff-response-sent peer=%s requestId=%s offered=%d reasons=%s",
            tostring(targetKey),
            tostring(requestPayload and requestPayload.requestId or "none"),
            #(response.offeredBlocks or {}),
            self.telemetry.lastBlockOfferReasons ~= "" and self.telemetry.lastBlockOfferReasons or "none"
        ))
    end
    return sent, response
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

    local reasons = {}
    for index = 1, #(session.offeredBlocks or {}) do
        local row = session.offeredBlocks[index]
        if row and row.reason then
            reasons[#reasons + 1] = tostring(row.reason)
        end
    end
    self.telemetry.lastBlockOfferReasons = table.concat(reasons, ",")
    Addon:Trace("sync", string.format(
        "index-diff-response-received peer=%s requestId=%s offered=%d reasons=%s",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        #(session.offeredBlocks or {}),
        self.telemetry.lastBlockOfferReasons ~= "" and self.telemetry.lastBlockOfferReasons or "none"
    ))

    if #(session.wantedBlocks or {}) == 0 then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("index-diff-empty")
        end
        return true
    end

    return self:RequestNextWantedBlock()
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

    local requestId = string.format("BLOCKREQ:%s:%s:%d", tostring(session.seedKey), tostring(row.blockKey), tonumber(time() or 0) or 0)
    session.activeBlockKey = row.blockKey
    session.activeBlockRequestId = requestId
    session.state = "waiting-block"
    session.blockRequestedAt = time()
    session.lastProgressAt = session.blockRequestedAt

    local sent = self:SendDirectEnvelope("BLOCK_PULL_REQUEST", {
        requestId = requestId,
        blockKey = row.blockKey,
    }, session.seedKey, "ALERT")
    if sent then
        self.telemetry.blockPullRequestSent = (self.telemetry.blockPullRequestSent or 0) + 1
        self.telemetry.blockPullStarted = (self.telemetry.blockPullStarted or 0) + 1
        self.telemetry.lastBlockPullBlockKey = tostring(row.blockKey)
        Addon:Trace("sync", string.format(
            "block-pull-start peer=%s requestId=%s block=%s reason=%s",
            tostring(session.seedKey),
            tostring(requestId),
            tostring(row.blockKey),
            tostring(row.reason or "unknown")
        ))
        return true
    end

    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    if self.AbortOutboundSeedSession then
        self:AbortOutboundSeedSession("block-pull-send-failed")
    end
    return false
end

function Sync:ScheduleNextWantedBlock()
    local session = self.outboundSeedSession
    if type(session) ~= "table" or session.state == "completed" or session.state == "aborted" then
        return false
    end
    if session.nextBlockTimer then
        self:CancelTimer(session.nextBlockTimer, true)
        session.nextBlockTimer = nil
    end
    session.state = "waiting-next-block-delay"
    session.nextBlockReadyAt = time() + BLOCK_PULL_DELAY_SECONDS
    self.telemetry.blockPullDelayed = (self.telemetry.blockPullDelayed or 0) + 1
    session.nextBlockTimer = self:ScheduleTimer(function()
        if session.nextBlockTimer then
            self:CancelTimer(session.nextBlockTimer, true)
        end
        session.nextBlockTimer = nil
        if session.state == "waiting-next-block-delay" then
            session.state = "request-next-block"
            self:RequestNextWantedBlock()
        end
    end, BLOCK_PULL_DELAY_SECONDS)
    Addon:Trace("sync", string.format(
        "block-pull-delay peer=%s nextDelay=%.1f",
        tostring(session.seedKey or "unknown"),
        BLOCK_PULL_DELAY_SECONDS
    ))
    return true
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
        if self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("session-timeout")
        end
        return
    end

    if session.state == "seed-selected" then
        self:RequestIndexDiff(session.seedKey)
        return
    end

    if session.state == "request-next-block" then
        self:RequestNextWantedBlock()
    end
end

function Sync:StartManualSyncPull(memberKey, silent)
    if Addon.Data and Addon.Data.MarkSyncIndexDirty then
        Addon.Data:MarkSyncIndexDirty(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull", nil, {
            full = true,
        })
    end
    if self.ScheduleHello then
        self:ScheduleHello(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull", 0.5)
    end
    if not silent then
        Addon:Print("Scheduled a hello cycle for index-diff sync.")
    end
end
