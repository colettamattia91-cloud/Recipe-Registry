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
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("HELLO") then
        return
    end
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        return
    end

    local cycle = self.BeginHelloCycle and self:BeginHelloCycle(self._pendingHelloCycleReason or "hello") or nil
    self.lastHelloAt = time()
    if Addon.Data and Addon.Data.CommitGlobalFingerprint then
        Addon.Data:CommitGlobalFingerprint("hello-publish")
    end
    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello",
    }) or {}
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
        self.telemetry.helloSent = (self.telemetry.helloSent or 0) + 1
        self._pendingHelloCycleReason = nil
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
                if self.SelectOutboundSeed then
                    self:SelectOutboundSeed(cycle.cycleId)
                end
            end, Constants.SUMMARY_COLLECTION_WINDOW or 0.75)
        end
    end
end

function Sync:SendGuildEnvelope(kind, payload, priority)
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(kind) then
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
    local msg = LibStub("AceSerializer-3.0"):Serialize(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "GUILD", nil, priority or "NORMAL")
        return true
    end
    return false
end

function Sync:SendDirectEnvelope(kind, payload, targetKey, priority)
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(kind) then
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
    local msg = LibStub("AceSerializer-3.0"):Serialize(payload)
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

    local ok, payload = LibStub("AceSerializer-3.0"):Deserialize(text)
    if not ok or type(payload) ~= "table" then
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
    local localSummary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello-response",
    }) or nil
    if shouldSendSummaryForHello(self, payload, localSummary) then
        self:SendSummary(payload.sender or payload.key, payload.helloId)
    end
end

function Sync:SendSummary(targetKey, helloId)
    local session = self.outboundSeedSession
    if not (type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted")
        and Addon.Data and Addon.Data.CommitGlobalFingerprint
    then
        Addon.Data:CommitGlobalFingerprint("summary-publish")
    end
    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "summary-send",
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
        self:SendIndexDiffResponse(payload.sender, payload)
    end
end

function Sync:HandleIndexDiffResponse(payload)
    if self.HandleReceivedIndexDiffResponse then
        self:HandleReceivedIndexDiffResponse(payload)
    end
end

function Sync:HandleBlockPullRequest(payload)
    if self.CanServeInboundSeed then
        local allowed = self:CanServeInboundSeed(payload and payload.sender)
        if not allowed then
            return
        end
    end
    if self.SendBlockSnapshot then
        self:SendBlockSnapshot(payload and payload.sender, payload)
    end
end

function Sync:HandleBlockSnapshot(payload)
    if self.HandleReceivedBlockSnapshot then
        self:HandleReceivedBlockSnapshot(payload)
    end
end
