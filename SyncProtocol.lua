local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time

local PREFIX = Constants.PREFIX

local function shouldAttachProtocolCaps(kind)
    return kind == "HELLO"
end

local function recordUnsupportedMessage(self, kind, senderKey)
    self.telemetry.unsupportedMessagesIgnored = (self.telemetry.unsupportedMessagesIgnored or 0) + 1
    self.telemetry.lastUnsupportedMessageKind = tostring(kind or "unknown")
    self.telemetry.lastUnsupportedMessageSender = tostring(senderKey or "unknown")
    self.telemetry.lastUnsupportedMessageAt = time()
    if self.RecordSyncEvent then
        self:RecordSyncEvent("unsupportedMessageIgnored", {
            reason = tostring(kind or "unknown"),
            peer = senderKey,
        })
    end
    Addon:Trace("sync", string.format(
        "unsupported-message kind=%s sender=%s",
        tostring(kind or "unknown"),
        tostring(senderKey or "unknown")
    ))
end

local function shouldSendSummaryForHello(self, helloPayload, localSummary)
    if type(localSummary) ~= "table" then
        return false
    end
    if tostring(localSummary.indexStatus or "") ~= "ready" then
        return false
    end
    if tostring(helloPayload and helloPayload.indexStatus or "") ~= "ready" then
        return false
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("SUMMARY") then
        return false
    end
    if self.IsSummarySaturated and self:IsSummarySaturated() then
        return false
    end
    return tostring(localSummary.globalFingerprint or "") ~= tostring(helloPayload and helloPayload.globalFingerprint or "")
end

function Sync:BroadcastHello()
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("HELLO")
    end
    if not allowed then
        return false
    end
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        return false
    end

    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello",
        allowDeferred = true,
    }) or {}
    -- If the index is merely dirty (cache populated, fingerprint not yet
    -- recomputed) try a synchronous prepare before giving up. This avoids the
    -- failure mode where the prepare timer was cancelled or never scheduled,
    -- which would otherwise leave HELLO permanently deferred.
    if tostring(summary.indexStatus or "") ~= "ready"
        and Addon.Data
        and Addon.Data.IsSyncIndexDirty
        and Addon.Data:IsSyncIndexDirty()
        and Addon.Data.PrepareSyncIndexNow
    then
        Addon.Data:PrepareSyncIndexNow("hello-sync-prepare")
        summary = Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
            reason = "hello-after-prepare",
            allowDeferred = false,
        }) or summary
    end
    if tostring(summary.indexStatus or "") ~= "ready" then
        if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
            Addon.Data:ScheduleSyncIndexPrepare("hello-not-ready", 0.5)
        end
        if self.RefreshSyncReadyState then
            self:RefreshSyncReadyState("hello-not-ready")
        end
        if self.ScheduleHello then
            self:ScheduleHello("deferred:hello-not-ready")
        end
        return false
    end
    local cycle = self.BeginHelloCycle and self:BeginHelloCycle(self._pendingHelloCycleReason or "hello") or nil
    local sent = self:SendGuildEnvelope("HELLO", {
        key = self:GetSelfKey(),
        helloId = cycle and cycle.helloId or nil,
        version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = Addon.CAPABILITIES,
        caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
        syncModel = summary.syncModel,
        indexStatus = summary.indexStatus,
        activeOwnerCount = summary.activeOwnerCount or 0,
        activeBlockCount = summary.activeBlockCount or 0,
        activeContentCount = summary.activeContentCount or 0,
        globalFingerprint = summary.globalFingerprint,
    }, "ALERT")
    if sent then
        self.lastHelloAt = time()
        self.telemetry.helloSent = (self.telemetry.helloSent or 0) + 1
        self.telemetry.lastHelloSentAt = self.lastHelloAt
        self.telemetry.lastHelloId = cycle and cycle.helloId or nil
        self.telemetry.lastHelloFingerprint = summary.globalFingerprint
        self._pendingHelloCycleReason = nil
        if self.RecordSyncEvent then
            self:RecordSyncEvent("helloSent", {
                reason = cycle and cycle.reason or "hello",
                requestId = cycle and cycle.helloId or nil,
                extra = tostring(summary.globalFingerprint or "none"),
            })
        end
        Addon:Trace("sync", string.format(
            "hello-sent helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
            tostring(cycle and cycle.helloId or "none"),
            tonumber(summary.activeOwnerCount or 0) or 0,
            tonumber(summary.activeBlockCount or 0) or 0,
            tonumber(summary.activeContentCount or 0) or 0,
            tostring(summary.globalFingerprint or "none")
        ))
        if self._helloCycleTimer then
            self:CancelTimer(self._helloCycleTimer, true)
            self._helloCycleTimer = nil
        end
        if cycle then
            self._helloCycleTimer = self:ScheduleTimer(function()
                self._helloCycleTimer = nil
                self.telemetry.summaryCollectionTimeouts = (self.telemetry.summaryCollectionTimeouts or 0) + 1
                if self.SelectOutboundSeed then
                    self:SelectOutboundSeed(cycle.cycleId)
                end
            end, Constants.SUMMARY_COLLECTION_WINDOW or 6)
        end
        return true
    end
    return false
end

function Sync:SendGuildEnvelope(kind, payload, priority)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol(kind)
    end
    if not allowed then
        return false
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return false
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    if shouldAttachProtocolCaps(kind) then
        payload.sentAt = time()
        payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
        payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
        payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
        payload.buildId = payload.buildId or Addon.BUILD_ID
        payload.capabilities = payload.capabilities or Addon.CAPABILITIES
        payload.caps = payload.caps or (self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
    end
    local msg = self:EncodeWirePayload(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "GUILD", nil, priority or "NORMAL")
        return true
    end
    return false
end

function Sync:SendDirectEnvelope(kind, payload, targetKey, priority)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol(kind)
    end
    if not allowed then
        return false
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return false
    end
    local target = self:GetWhisperTarget(targetKey)
    if not target then
        return false
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    if shouldAttachProtocolCaps(kind) then
        payload.sentAt = time()
        payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
        payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
        payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
        payload.buildId = payload.buildId or Addon.BUILD_ID
        payload.capabilities = payload.capabilities or Addon.CAPABILITIES
        payload.caps = payload.caps or (self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
    end
    local msg = self:EncodeWirePayload(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "WHISPER", target, priority or "NORMAL")
        return true
    end
    return false
end

function Sync:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= PREFIX then
        return
    end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then
        return
    end

    local payload = self:DecodeWirePayload(text)
    if type(payload) ~= "table" then
        return
    end
    if payload.sender == self:GetSelfKey() then
        return
    end

    local peerKey = self:IsValidSyncMemberKey(payload.sender) and payload.sender or nil
    if payload.kind == "HELLO" then
        local allowed, dropReason, remoteChannel = self:IsInboundBuildChannelAllowed(payload, sender)
        if not allowed then
            self:RegisterBuildChannelDrop(peerKey or sender, payload, dropReason, remoteChannel)
            return
        end
        if peerKey and self.ObservePeerVersion then
            self:ObservePeerVersion(peerKey, payload)
        end
        if peerKey and self.MaybeNotifyPeerVersion then
            self:MaybeNotifyPeerVersion(peerKey)
        end
        if peerKey and self.ShouldAcceptInboundPayload and not self:ShouldAcceptInboundPayload(payload, peerKey) then
            return
        end
    else
        if peerKey and self.ShouldAcceptInboundPayload and not self:ShouldAcceptInboundPayload(payload, peerKey) then
            return
        end
    end

    local pauseReason = Addon.SyncPausePolicy and Addon.SyncPausePolicy:GetProtocolPauseReason(payload.kind) or nil
    if pauseReason then
        return
    end

    if payload.kind == "HELLO" and payload.sender then
        self:TouchNode(payload.sender, payload.addonVersion or payload.version)
    end

    if payload.kind == "HELLO" then
        self:HandleHello(payload, distribution, sender)
    elseif payload.kind == "SUMMARY" then
        self:HandleSummary(payload, distribution, sender)
    elseif payload.kind == "INDEX_DIFF_REQUEST" then
        self:HandleIndexDiffRequest(payload, distribution, sender)
    elseif payload.kind == "INDEX_DIFF_RESPONSE" then
        self:HandleIndexDiffResponse(payload, distribution, sender)
    elseif payload.kind == "BLOCK_PULL_REQUEST" then
        self:HandleBlockPullRequest(payload, distribution, sender)
    elseif payload.kind == "BLOCK_SNAPSHOT" then
        self:HandleBlockSnapshot(payload, distribution, sender)
    else
        recordUnsupportedMessage(self, payload.kind, payload.sender)
    end
end

function Sync:HandleHello(payload)
    if not self:IsValidSyncMemberKey(payload.key) then
        return
    end
    self._lastHelloSeenAt = self._lastHelloSeenAt or {}
    self._lastHelloSeenAt[payload.key] = time()
    if self.RecordPeerCaps then
        self:RecordPeerCaps(payload.sender or payload.key, payload.caps)
    end
    Addon:Trace("sync", string.format(
        "hello-received peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
        tostring(payload.sender or payload.key or "unknown"),
        tostring(payload.helloId or "none"),
        tonumber(payload.activeOwnerCount or 0) or 0,
        tonumber(payload.activeBlockCount or 0) or 0,
        tonumber(payload.activeContentCount or 0) or 0,
        tostring(payload.globalFingerprint or "none")
    ))
    local ready, readyReason = true, "ready"
    if self.CanRunSyncProtocol then
        ready, readyReason = self:CanRunSyncProtocol("SUMMARY")
    end
    if not ready then
        Addon:Trace("sync", string.format(
            "summary-suppressed peer=%s reason=%s",
            tostring(payload.sender or payload.key or "unknown"),
            tostring(readyReason or "not-ready")
        ))
        return
    end
    local localSummary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello-response",
        allowDeferred = true,
    }) or nil
    if shouldSendSummaryForHello(self, payload, localSummary) then
        self:SendSummary(payload.sender or payload.key, payload.helloId)
    else
        local suppressReason = "unknown"
        if type(localSummary) ~= "table" then
            suppressReason = "local-summary-unavailable"
        elseif tostring(localSummary.indexStatus or "") ~= "ready" then
            suppressReason = "local-index-not-ready:" .. tostring(localSummary.indexStatus or "unknown")
        elseif tostring(payload.indexStatus or "") ~= "ready" then
            suppressReason = "remote-index-not-ready:" .. tostring(payload.indexStatus or "unknown")
        elseif Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("SUMMARY") then
            suppressReason = "paused"
        elseif self.IsSummarySaturated and self:IsSummarySaturated() then
            suppressReason = "saturated"
        elseif tostring(localSummary.globalFingerprint or "") == tostring(payload.globalFingerprint or "") then
            suppressReason = "fingerprints-match"
        end
        Addon:Trace("sync", string.format(
            "summary-suppressed peer=%s reason=%s localFp=%s remoteFp=%s",
            tostring(payload.sender or payload.key or "unknown"),
            suppressReason,
            tostring(localSummary and localSummary.globalFingerprint or "nil"),
            tostring(payload.globalFingerprint or "nil")
        ))
    end
end

function Sync:SendSummary(targetKey, helloId)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("SUMMARY")
    end
    if not allowed then
        return false
    end
    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "summary-send",
        allowDeferred = true,
    }) or nil
    if type(summary) ~= "table" or tostring(summary.indexStatus or "") ~= "ready" then
        return false
    end
    local sent = self:SendDirectEnvelope("SUMMARY", {
        helloId = helloId,
        activeOwnerCount = summary.activeOwnerCount or 0,
        activeBlockCount = summary.activeBlockCount or 0,
        activeContentCount = summary.activeContentCount or 0,
        globalFingerprint = summary.globalFingerprint,
    }, targetKey, "ALERT")
    if sent then
        self.telemetry.summarySent = (self.telemetry.summarySent or 0) + 1
        self.telemetry.lastSummaryPeer = tostring(targetKey or "unknown")
        if self.RecordSyncEvent then
            self:RecordSyncEvent("summarySent", {
                peer = targetKey,
                requestId = helloId,
                extra = tostring(summary.globalFingerprint or "none"),
            })
        end
        Addon:Trace("sync", string.format(
            "summary-sent peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
            tostring(targetKey or "unknown"),
            tostring(helloId or "none"),
            tonumber(summary.activeOwnerCount or 0) or 0,
            tonumber(summary.activeBlockCount or 0) or 0,
            tonumber(summary.activeContentCount or 0) or 0,
            tostring(summary.globalFingerprint or "none")
        ))
    end
    return sent
end

function Sync:HandleSummary(payload)
    local peerKey = self:IsValidSyncMemberKey(payload.sender) and payload.sender or nil
    if not peerKey then
        return
    end
    if not self:GetPeerVersionInfo(peerKey) and self.ObservePeerVersion then
        -- SUMMARY is allowed to arrive as a direct reply to our active HELLO before
        -- that peer has emitted its own HELLO. Prime provisional peer metadata from
        -- the local build so the current handshake can continue without widening
        -- the wire payload.
        self:ObservePeerVersion(peerKey, {
            sender = peerKey,
            addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
            wireVersion = Addon.WIRE_VERSION,
            buildChannel = Addon.BUILD_CHANNEL,
            buildId = Addon.BUILD_ID,
            caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
        })
        if self.RecordPeerCaps then
            self:RecordPeerCaps(peerKey, self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
        end
    end
    if self.RecordSummary then
        self:RecordSummary(peerKey, payload)
    end
end

function Sync:HandleIndexDiffRequest(payload)
    if not (payload and self:IsValidSyncMemberKey(payload.sender)) then
        return
    end
    self.telemetry.indexDiffRequestReceived = (self.telemetry.indexDiffRequestReceived or 0) + 1
    if self.RecordSyncEvent then
        self:RecordSyncEvent("indexDiffRequestReceived", {
            peer = payload.sender,
            requestId = payload.requestId,
            extra = string.format("blocks=%d", type(payload.blocks) == "table" and Private.countKeys(payload.blocks) or 0),
        })
    end
    Addon:Trace("sync", string.format(
        "index-diff-request-received peer=%s requestId=%s blocks=%d",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        type(payload.blocks) == "table" and Private.countKeys(payload.blocks) or 0
    ))
    if self.CanServeInboundSeed then
        local allowed = self:CanServeInboundSeed(payload.sender)
        if not allowed then
            return
        end
    end
    if self.SendIndexDiffResponse then
        local sent, response = self:SendIndexDiffResponse(payload.sender, payload)
        if sent and self.RegisterInboundSeedSession then
            self:RegisterInboundSeedSession(payload.sender, payload.requestId, response and response.offeredBlocks or nil)
        end
    end
end

function Sync:HandleIndexDiffResponse(payload)
    if self.HandleReceivedIndexDiffResponse then
        self:HandleReceivedIndexDiffResponse(payload)
    end
end

function Sync:HandleBlockPullRequest(payload)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("BLOCK_SNAPSHOT")
    end
    if not allowed then
        return
    end
    if self.CanServeInboundSeed then
        local allowed = self:CanServeInboundSeed(payload and payload.sender)
        if not allowed then
            return
        end
    end
    local inboundSession = self.GetInboundSeedSession and self:GetInboundSeedSession(payload and payload.sender) or nil
    if not inboundSession then
        self.telemetry.inboundBlockPullRejectedUnknownRequest = (self.telemetry.inboundBlockPullRejectedUnknownRequest or 0) + 1
        if self.RecordSyncEvent then
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = payload and payload.sender,
                requestId = payload and payload.requestId,
                reason = "unknown-request",
                blockKey = payload and payload.blockKey,
            })
        end
        return
    end
    if type(inboundSession.offeredBlocks) == "table" and inboundSession.offeredBlocks[payload and payload.blockKey] ~= true then
        self.telemetry.inboundBlockPullRejectedNotOffered = (self.telemetry.inboundBlockPullRejectedNotOffered or 0) + 1
        if self.RecordSyncEvent then
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = payload and payload.sender,
                requestId = payload and payload.requestId,
                reason = "block-not-offered",
                blockKey = payload and payload.blockKey,
            })
        end
        return
    end
    inboundSession.lastActivity = time()
    inboundSession.servedBlocks = tonumber(inboundSession.servedBlocks or 0) or 0
    if self.SendBlockSnapshot then
        local sent = self:SendBlockSnapshot(payload and payload.sender, payload)
        if sent then
            inboundSession.servedBlocks = inboundSession.servedBlocks + 1
            inboundSession.lastActivity = time()
            inboundSession.state = "serving"
            self.telemetry.lastInboundRequester = payload and payload.sender or self.telemetry.lastInboundRequester
            self.telemetry.lastInboundRequestId = payload and payload.requestId or self.telemetry.lastInboundRequestId
            self.telemetry.lastInboundServedBlockKey = payload and payload.blockKey or self.telemetry.lastInboundServedBlockKey
        end
    end
end

function Sync:HandleBlockSnapshot(payload)
    if self.HandleReceivedBlockSnapshot then
        self:HandleReceivedBlockSnapshot(payload)
    end
end
