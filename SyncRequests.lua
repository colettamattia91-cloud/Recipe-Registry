local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local max = math.max

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
-- BLOCK_PULL_DELAY_SECONDS and BLOCK_PULL_RESPONSE_TIMEOUT_SECONDS now
-- resolve via Sync:GetBlockPullDelay() / :GetBlockPullResponseTimeout()
-- so the user-tunable values from the options panel take effect without
-- needing a /reload.

-- Summarize an offered-blocks list into compact, human-readable strings for
-- traces. Repeating "missing,missing,missing..." 164 times across the offered
-- count carries no signal. Grouping by profession and by reason is much more
-- diagnosable — you can tell at a glance whether a profession (e.g. Mining) is
-- present in the offered set without grepping through hundreds of keys.
-- Returns (reasonsSummary, byProfessionSummary, blockKeysCompact).
local function summarizeOfferedBlocks(offeredBlocks)
    local reasonCounts = {}
    local profCounts = {}
    local blockKeys = {}
    for index = 1, #(offeredBlocks or {}) do
        local row = offeredBlocks[index]
        if type(row) == "table" then
            if row.reason then
                local key = tostring(row.reason)
                reasonCounts[key] = (reasonCounts[key] or 0) + 1
            end
            if type(row.blockKey) == "string" and row.blockKey ~= "" then
                blockKeys[#blockKeys + 1] = row.blockKey
                local prof = row.blockKey:match("^.-::(.+)$")
                if prof and prof ~= "" then
                    profCounts[prof] = (profCounts[prof] or 0) + 1
                end
            end
        end
    end
    local function flattenSorted(map)
        local parts = {}
        for k, v in pairs(map) do
            parts[#parts + 1] = string.format("%s:%d", tostring(k), tonumber(v) or 0)
        end
        table.sort(parts)
        return table.concat(parts, ",")
    end
    return flattenSorted(reasonCounts), flattenSorted(profCounts), table.concat(blockKeys, ",")
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
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("INDEX_DIFF_REQUEST")
    end
    if not allowed then
        return false
    end
    local session = self.outboundSeedSession
    if not (type(session) == "table" and session.seedKey == seedKey) then
        return false
    end
    if session.state == "waiting-index-diff" or session.state == "completed" or session.state == "aborted" then
        return false
    end

    local digest = Addon.Data and Addon.Data.BuildRequesterIndexDigest and Addon.Data:BuildRequesterIndexDigest({
        reason = "index-diff-request",
        allowDeferred = true,
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
        self.telemetry.lastIndexDiffTarget = tostring(seedKey)
        self.telemetry.lastIndexDiffLocalBlockCount = tonumber(digest.activeBlockCount or 0) or 0
        if self.RecordSyncEvent then
            self:RecordSyncEvent("indexDiffRequestSent", {
                peer = seedKey,
                requestId = session.diffRequestId,
                extra = string.format("blocks=%d", self.telemetry.lastIndexDiffLocalBlockCount or 0),
            })
        end
        Addon:Tracef("sync",
            "index-diff-request-sent peer=%s requestId=%s blocks=%d",
            tostring(seedKey),
            tostring(session.diffRequestId),
            tonumber(digest.activeBlockCount or 0) or 0
        )
        return true
    end

    if self.AbortOutboundSeedSession then
        self:AbortOutboundSeedSession("index-diff-send-failed")
    end
    return false
end

function Sync:BuildIndexDiffResponseForRequest(requestPayload)
    return Addon.Data and Addon.Data.BuildIndexDiffResponse and Addon.Data:BuildIndexDiffResponse(requestPayload, {
        reason = "index-diff-response",
        allowDeferred = true,
    }) or nil
end

function Sync:SendPreparedIndexDiffResponse(targetKey, requestPayload, response)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("INDEX_DIFF_RESPONSE")
    end
    if not allowed then
        return false, nil
    end
    if not self:IsValidSyncMemberKey(targetKey) then
        return false, nil
    end
    if type(response) ~= "table" or response.ready ~= true then
        return false, response
    end
    local sent = self:SendDirectEnvelope("INDEX_DIFF_RESPONSE", {
        requestId = requestPayload and requestPayload.requestId or nil,
        offeredBlocks = response.offeredBlocks,
    }, targetKey, "ALERT")
    if sent then
        local reasonsSummary, profsSummary, blockKeysCompact = summarizeOfferedBlocks(response.offeredBlocks)
        self.telemetry.indexDiffResponseSent = (self.telemetry.indexDiffResponseSent or 0) + 1
        self.telemetry.blocksOffered = (self.telemetry.blocksOffered or 0) + #(response.offeredBlocks or {})
        self.telemetry.lastIndexDiffOfferedCount = #(response.offeredBlocks or {})
        self.telemetry.lastIndexDiffNoOfferReason = (#(response.offeredBlocks or {}) == 0) and "no-diff" or nil
        self.telemetry.lastBlockOfferReasons = reasonsSummary
        self.telemetry.lastBlockOfferProfessions = profsSummary
        self.telemetry.lastBlockOfferKeys = blockKeysCompact
        if self.RecordSyncEvent then
            self:RecordSyncEvent("indexDiffResponseSent", {
                peer = targetKey,
                requestId = requestPayload and requestPayload.requestId or nil,
                extra = string.format("offered=%d", self.telemetry.lastIndexDiffOfferedCount or 0),
            })
        end
        Addon:Tracef("sync",
            "index-diff-response-sent peer=%s requestId=%s offered=%d byProfession=[%s] reasons=[%s] blocks=[%s]",
            tostring(targetKey),
            tostring(requestPayload and requestPayload.requestId or "none"),
            #(response.offeredBlocks or {}),
            profsSummary ~= "" and profsSummary or "none",
            reasonsSummary ~= "" and reasonsSummary or "none",
            blockKeysCompact ~= "" and blockKeysCompact or "none"
        )
    end
    return sent, response
end

function Sync:SendIndexDiffResponse(targetKey, requestPayload)
    local response = self:BuildIndexDiffResponseForRequest(requestPayload)
    return self:SendPreparedIndexDiffResponse(targetKey, requestPayload, response)
end

function Sync:SendIndexDiffBusy(targetKey, requestPayload, reason)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("INDEX_DIFF_RESPONSE")
    end
    if not allowed or not self:IsValidSyncMemberKey(targetKey) then
        return false
    end

    local busyReason = tostring(reason or "busy")
    local sent = self:SendDirectEnvelope("INDEX_DIFF_RESPONSE", {
        requestId = requestPayload and requestPayload.requestId or nil,
        busy = true,
        reason = busyReason,
    }, targetKey, "ALERT")
    if sent then
        self.telemetry.indexDiffBusySent = (self.telemetry.indexDiffBusySent or 0) + 1
        self.telemetry.lastIndexDiffBusyPeer = targetKey
        self.telemetry.lastIndexDiffBusyReason = busyReason
        self.telemetry.lastIndexDiffNoOfferReason = busyReason
        if self.RecordSyncEvent then
            self:RecordSyncEvent("indexDiffBusySent", {
                peer = targetKey,
                requestId = requestPayload and requestPayload.requestId or nil,
                reason = busyReason,
            })
        end
        Addon:Tracef("sync",
            "index-diff-busy-sent peer=%s requestId=%s reason=%s",
            tostring(targetKey),
            tostring(requestPayload and requestPayload.requestId or "none"),
            busyReason
        )
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

    if payload.busy == true then
        local busyReason = tostring(payload.reason or "seed-busy")
        session.lastProgressAt = time()
        self.telemetry.indexDiffBusyReceived = (self.telemetry.indexDiffBusyReceived or 0) + 1
        self.telemetry.seedBusyReceived = (self.telemetry.seedBusyReceived or 0) + 1
        self.telemetry.lastIndexDiffBusyPeer = payload.sender
        self.telemetry.lastIndexDiffBusyReason = busyReason
        self.telemetry.lastIndexDiffNoOfferReason = busyReason
        if self.RecordSyncEvent then
            self:RecordSyncEvent("indexDiffBusyReceived", {
                peer = payload.sender,
                requestId = payload.requestId,
                reason = busyReason,
            })
        end
        Addon:Tracef("sync",
            "index-diff-busy-received peer=%s requestId=%s reason=%s",
            tostring(payload.sender or "unknown"),
            tostring(payload.requestId or "none"),
            busyReason
        )
        if self.HandleSeedBusy then
            self:HandleSeedBusy(payload.sender, busyReason)
        end
        return true
    end

    session.lastProgressAt = time()
    session.state = "index-diff-ready"
    session.offeredBlocks = self:BuildWantedBlockOrder(payload.offeredBlocks or {})
    session.wantedBlocks = self:BuildWantedBlockOrder(payload.offeredBlocks or {})
    session.nextWantedIndex = 1
    self.telemetry.indexDiffResponseReceived = (self.telemetry.indexDiffResponseReceived or 0) + 1
    self.telemetry.blocksOffered = (self.telemetry.blocksOffered or 0) + #(session.offeredBlocks or {})
    self.telemetry.lastIndexDiffOfferedCount = #(session.offeredBlocks or {})
    self.telemetry.lastIndexDiffNoOfferReason = (#(session.offeredBlocks or {}) == 0) and "no-diff" or nil

    local reasonsSummary, profsSummary, blockKeysCompact = summarizeOfferedBlocks(session.offeredBlocks)
    self.telemetry.lastBlockOfferReasons = reasonsSummary
    self.telemetry.lastBlockOfferProfessions = profsSummary
    self.telemetry.lastBlockOfferKeys = blockKeysCompact
    if self.RecordSyncEvent then
        self:RecordSyncEvent("indexDiffResponseReceived", {
            peer = payload.sender,
            requestId = payload.requestId,
            extra = string.format("offered=%d", self.telemetry.lastIndexDiffOfferedCount or 0),
        })
    end
    Addon:Tracef("sync",
        "index-diff-response-received peer=%s requestId=%s offered=%d byProfession=[%s] reasons=[%s] blocks=[%s]",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        #(session.offeredBlocks or {}),
        profsSummary ~= "" and profsSummary or "none",
        reasonsSummary ~= "" and reasonsSummary or "none",
        blockKeysCompact ~= "" and blockKeysCompact or "none"
    )

    if #(session.wantedBlocks or {}) == 0 then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("index-diff-empty")
        end
        return true
    end

    return self:RequestNextWantedBlock()
end

function Sync:RequestNextWantedBlock()
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("BLOCK_PULL_REQUEST")
    end
    if not allowed then
        return false
    end
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
        self.telemetry.lastBlockPullRequestId = requestId
        self.telemetry.lastBlockPullSentAt = session.blockRequestedAt
        if self.RecordSyncEvent then
            self:RecordSyncEvent("blockPullRequestSent", {
                peer = session.seedKey,
                requestId = requestId,
                blockKey = row.blockKey,
                reason = row.reason,
            })
        end
        Addon:Tracef("sync",
            "block-pull-start peer=%s requestId=%s block=%s reason=%s",
            tostring(session.seedKey),
            tostring(requestId),
            tostring(row.blockKey),
            tostring(row.reason or "unknown")
        )
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
    local pullDelay = self:GetBlockPullDelay()
    session.state = "waiting-next-block-delay"
    session.nextBlockReadyAt = time() + pullDelay
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
    end, pullDelay)
    Addon:Tracef("sync",
        "block-pull-delay peer=%s nextDelay=%.1f",
        tostring(session.seedKey or "unknown"),
        pullDelay
    )
    return true
end

function Sync:ProcessRequestQueue()
    self:RefreshSyncReadyState("request-queue")
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

    local allowActivePullAdvance = self.CanAdvanceOutboundPullSession and self:CanAdvanceOutboundPullSession() or false
    if self.syncReady ~= true and not allowActivePullAdvance then
        return
    end

    local now = time()
    local age = max(0, now - (session.lastProgressAt or session.startedAt or now))
    if age > SESSION_TIMEOUT then
        self.telemetry.lastBlockPullTimeoutAt = now
        self.telemetry.lastBlockPullTimeoutReason = "session-timeout"
        if self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("session-timeout")
        end
        return
    end

    if session.state == "waiting-block" and session.blockRequestedAt then
        local blockAge = max(0, now - session.blockRequestedAt)
        if blockAge > self:GetBlockPullResponseTimeout() then
            self.telemetry.lastBlockPullTimeoutAt = now
            self.telemetry.lastBlockPullTimeoutReason = "block-response-timeout"
            if self.AbortOutboundSeedSession then
                self:AbortOutboundSeedSession("block-response-timeout")
            end
            return
        end
    end

    if session.state == "seed-selected" then
        if self.syncReady ~= true then
            return
        end
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
    if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
        Addon.Data:ScheduleSyncIndexPrepare(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull", 0.2)
    end
    if self.ResetDiscoveryRetry then
        self:ResetDiscoveryRetry(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull")
    end
    if self.RefreshSyncReadyState then
        self:RefreshSyncReadyState(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull")
    end
    if self.ScheduleHello then
        self:ScheduleHello(memberKey and memberKey ~= "" and "manual-pull-targeted" or "manual-pull", 0.5)
    end
    if not silent then
        Addon:Print("Scheduled a hello cycle for index-diff sync.")
    end
end
