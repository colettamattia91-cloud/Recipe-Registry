local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time

local PREFIX = Constants.PREFIX

local function shouldAttachProtocolCaps(kind)
    return kind == "HELLO"
        or kind == "AD"
        or kind == "MANI"
        or kind == "MREQ"
end

local function getLocalManifestFingerprint(reason)
    if Addon.Data and Addon.Data.GetPreparedManifestContentFingerprint then
        return Addon.Data:GetPreparedManifestContentFingerprint({
            reason = reason or "hello-fingerprint",
        })
    end
    return nil, "unavailable"
end

function Sync:BroadcastHello()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() then
        return
    end
    local firstHello = (self.lastHelloAt or 0) <= 0
    self.lastHelloAt = time()
    local summary = Addon.Data:GetLocalSummary()
    self:RecordRevisionHint(summary.memberKey, summary.rev, summary.updatedAt, summary.memberKey)
    local requestManifest = firstHello or self._nextHelloRequestsManifest == true
    local manifestFingerprint = getLocalManifestFingerprint("hello")
    local sent = self:SendGuildEnvelope("HELLO", {
        key = self:GetSelfKey(),
        rev = summary.rev,
        updatedAt = summary.updatedAt,
        version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = Addon.CAPABILITIES,
        caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
        manifestPushMode = "requested",
        manifestRequest = requestManifest,
        manifestFingerprint = manifestFingerprint,
    }, "ALERT")
    if sent then
        self._nextHelloRequestsManifest = false
    end
end

function Sync:AdvertiseLocalRevision(reason)
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() then
        return
    end
    local summary = Addon.Data:GetLocalSummary()
    if self.lastAdvertisedRev == summary.rev and reason ~= "startup" then return end
    self.lastAdvertisedRev = summary.rev
    self:RecordRevisionHint(summary.memberKey, summary.rev, summary.updatedAt, summary.memberKey)
    self:SendGuildEnvelope("AD", {
        key = summary.memberKey,
        rev = summary.rev,
        updatedAt = summary.updatedAt,
        professions = summary.professions,
        recipes = summary.recipes,
        why = reason,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = Addon.CAPABILITIES,
        caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
    }, "ALERT")
    self:BroadcastManifestToOnlinePeers(reason or "advertise")
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
    payload.sentAt = time()
    payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
    payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
    payload.buildId = payload.buildId or Addon.BUILD_ID
    if shouldAttachProtocolCaps(kind) then
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
    if not target then return false end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    payload.sentAt = time()
    payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
    payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
    payload.buildId = payload.buildId or Addon.BUILD_ID
    if shouldAttachProtocolCaps(kind) then
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
    if prefix ~= PREFIX then return end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end

    local ok, payload = LibStub("AceSerializer-3.0"):Deserialize(text)
    if not ok or type(payload) ~= "table" then return end
    if payload.sender == self:GetSelfKey() then return end

    local peerKey = self:IsValidSyncMemberKey(payload.sender) and payload.sender or nil
    local allowed, dropReason, remoteChannel = self:IsInboundBuildChannelAllowed(payload, sender)
    if not allowed then
        self:RegisterBuildChannelDrop(peerKey or sender, payload, dropReason, remoteChannel)
        return
    end
    if peerKey and self.ObservePeerVersion then
        self:ObservePeerVersion(peerKey, payload)
    end
    if payload.kind == "HELLO" and peerKey and self.MaybeNotifyPeerVersion then
        self:MaybeNotifyPeerVersion(peerKey)
    end
    if peerKey and self.ShouldAcceptInboundPayload and not self:ShouldAcceptInboundPayload(payload, peerKey) then
        return
    end

    local pauseReason = Addon.SyncPausePolicy and Addon.SyncPausePolicy:GetProtocolPauseReason(payload.kind) or nil
    if pauseReason then
        if payload.kind == "REQ" and self.HandlePausedRequest then
            self:HandlePausedRequest(payload, pauseReason)
        end
        return
    end

    if payload.sender then
        self:TouchNode(payload.sender, payload.addonVersion or payload.version)
    end

    if payload.kind == "HELLO" then
        self:HandleHello(payload, distribution, sender)
    elseif payload.kind == "AD" then
        self:HandleAdvertise(payload, distribution, sender)
    elseif payload.kind == "IDX" then
        self:HandleIndex(payload, distribution, sender)
    elseif payload.kind == "REQ" then
        self:HandleRequest(payload, distribution, sender)
    elseif payload.kind == "SNAP" then
        self:HandleSnapshotChunk(payload, distribution, sender)
    elseif payload.kind == "RESUME" then
        self:HandleResumeRequest(payload, distribution, sender)
    elseif payload.kind == "DONE" then
        self:HandleTransferDone(payload, distribution, sender)
    elseif payload.kind == "MANI" then
        self:HandleManifestChunk(payload, distribution, sender)
    elseif payload.kind == "MREQ" then
        self:HandleManifestRequest(payload, distribution, sender)
    elseif payload.kind == "RERR" then
        self:HandleRequestReject(payload, distribution, sender)
    end
end

function Sync:HandleHello(payload)
    if not self:IsValidSyncMemberKey(payload.key) then return end
    local sawHelloBefore = (self._lastHelloSeenAt and self._lastHelloSeenAt[payload.key] or 0) > 0
    self._lastHelloSeenAt = self._lastHelloSeenAt or {}
    self._lastHelloSeenAt[payload.key] = time()
    self:TouchNode(payload.key, payload.addonVersion or payload.version)
    if self.MarkManifestPeerSuccess then
        self:MarkManifestPeerSuccess(payload.sender or payload.key)
    end
    if self.RecordPeerCaps then
        self:RecordPeerCaps(payload.sender or payload.key, payload.caps)
    end
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.key)
    if self:IsMockKey(payload.key) then return end
    local localManifestFingerprint = getLocalManifestFingerprint("hello-compare")
    local remoteManifestFingerprint = type(payload.manifestFingerprint) == "string" and payload.manifestFingerprint or nil
    local manifestFingerprintsMatch = localManifestFingerprint
        and remoteManifestFingerprint
        and localManifestFingerprint == remoteManifestFingerprint
    if manifestFingerprintsMatch then
        self:RecordManifestReceived(payload.key)
        if self.RecordManifestFingerprintReceived then
            self:RecordManifestFingerprintReceived(payload.key, remoteManifestFingerprint)
        end
    end

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0
    local directOwnerRefreshPending = remoteRev > localRev

    local shouldSendManifest = not manifestFingerprintsMatch
    if self:IsInWarmup() and shouldSendManifest then
        self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
        Addon:Debug("Warmup deferring manifest reply", tostring(payload.key))
        self:QueueWarmupManifestPeer(payload.key, "hello")
    elseif shouldSendManifest then
        self:SendManifestToPeer(payload.key, "hello")
    else
        Addon:Trace("manifest", string.format(
            "send-skip peer=%s reason=%s why=hello",
            tostring(payload.key),
            manifestFingerprintsMatch and "hello-fingerprint-match" or "hello-not-requested"
        ))
    end
    local manifestFingerprintAlreadyHandled = remoteManifestFingerprint
        and ((self._lastManifestFingerprintReceived and self._lastManifestFingerprintReceived[payload.key] == remoteManifestFingerprint)
            or (self.HasRecentlyRequestedManifestFingerprint and self:HasRecentlyRequestedManifestFingerprint(payload.key, remoteManifestFingerprint)))
    local manifestFingerprintMismatch = localManifestFingerprint
        and remoteManifestFingerprint
        and localManifestFingerprint ~= remoteManifestFingerprint
        and not manifestFingerprintAlreadyHandled
    local manifestRefreshOpts = {
        reason = "hello-auto",
        manifestFingerprintMismatch = manifestFingerprintMismatch == true,
        remoteManifestFingerprint = remoteManifestFingerprint,
    }
    local canRequestFingerprintMismatch = not manifestFingerprintMismatch
        or self:IsCoordinator()
        or (self.coordinatorKey and payload.key == self.coordinatorKey)
    if sawHelloBefore
        and not manifestFingerprintsMatch
        and not manifestFingerprintAlreadyHandled
        and not (manifestFingerprintMismatch and directOwnerRefreshPending)
        and canRequestFingerprintMismatch
        and self:ShouldRequestManifestRefresh(payload.key, manifestRefreshOpts) then
        if self:IsInWarmup() then
            Addon:Debug("Warmup deferring manifest refresh request", tostring(payload.key))
            self:QueueWarmupManifestRefresh(payload.key)
        else
            self:RequestManifestRefresh(payload.key, manifestRefreshOpts)
        end
    end

    if remoteRev > localRev then
        if self:IsCoordinator() then
            self:BroadcastIndex(payload.key, remoteRev, payload.updatedAt, payload.key, "hello")
        end
        self:QueueRequest(payload.key, payload.key, remoteRev, "hello-auto")
    end
end

function Sync:HandleAdvertise(payload)
    if not self:IsValidSyncMemberKey(payload.key) or not self:IsValidSyncMemberKey(payload.sender) then return end
    self:TouchNode(payload.sender, payload.addonVersion or payload.version)
    if self.MarkManifestPeerSuccess then
        self:MarkManifestPeerSuccess(payload.sender)
    end
    if self.RecordPeerCaps then
        self:RecordPeerCaps(payload.sender, payload.caps)
    end
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.key)
    if self:IsMockKey(payload.key) or self:IsMockKey(payload.sender) then return end

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0

    if remoteRev > localRev then
        if self:IsCoordinator() then
            self:BroadcastIndex(payload.key, remoteRev, payload.updatedAt, payload.key, "advertise")
        end
        self:QueueRequest(payload.key, payload.key, remoteRev, "advertise-auto")
    end
end

function Sync:BroadcastIndex(memberKey, rev, updatedAt, owner, why)
    if not self:IsValidSyncMemberKey(memberKey) then return end
    if owner and not self:IsValidSyncMemberKey(owner) then owner = memberKey end
    if self:IsMockKey(memberKey) or self:IsMockKey(owner) then return end
    self:RecordRevisionHint(memberKey, rev, updatedAt, owner)
    self:SendGuildEnvelope("IDX", {
        key = memberKey,
        rev = rev,
        updatedAt = updatedAt,
        owner = owner or memberKey,
        why = why,
    }, "ALERT")
end

function Sync:HandleIndex(payload)
    if not self:IsValidSyncMemberKey(payload.key) or not self:IsValidSyncMemberKey(payload.sender) then return end
    self:TouchNode(payload.sender)
    if self:IsCoordinator() then return end
    if self.coordinatorKey and payload.sender ~= self.coordinatorKey then return end
    if self:IsMockKey(payload.key) or self:IsMockKey(payload.sender) then return end

    local ownerKey = self:IsValidSyncMemberKey(payload.owner) and payload.owner or payload.key
    local selfKey = self:GetSelfKey()
    if ownerKey == selfKey then
        self.telemetry.indexSkippedLocalOwners = (self.telemetry.indexSkippedLocalOwners or 0) + 1
        return
    end
    if ownerKey ~= payload.sender then
        local rosterFresh = self:IsRosterFresh()
        if not rosterFresh then
            self:EnsureFreshRoster("index-owner")
            rosterFresh = self:IsRosterFresh()
        end
        local ownerOnline = rosterFresh and Addon.Data:IsMemberOnline(ownerKey) or false
        -- Coordinator IDX hints can safely fan out direct owner requests, but offline-owner
        -- replica paths must stay in manifest catch-up so they do not seed impossible REQs.
        if not ownerOnline then
            self.telemetry.indexSkippedImpossibleOwners = (self.telemetry.indexSkippedImpossibleOwners or 0) + 1
            return
        end
    end
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, ownerKey)
    if payload.key == selfKey then
        return
    end

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0
    if remoteRev > localRev then
        self:QueueRequest(ownerKey, payload.key, remoteRev, "index")
    end
end
