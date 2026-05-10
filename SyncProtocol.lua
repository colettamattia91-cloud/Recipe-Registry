local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time

local PREFIX = Constants.PREFIX

function Sync:BroadcastHello()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() then
        return
    end
    self.lastHelloAt = time()
    local summary = Addon.Data:GetLocalSummary()
    self:RecordRevisionHint(summary.memberKey, summary.rev, summary.updatedAt, summary.memberKey)
    self:SendGuildEnvelope("HELLO", {
        key = self:GetSelfKey(),
        rev = summary.rev,
        updatedAt = summary.updatedAt,
        version = Addon.DISPLAY_VERSION,
    }, "ALERT")
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
    }, "ALERT")
    self:BroadcastManifestToOnlinePeers(reason or "advertise")
end

function Sync:SendGuildEnvelope(kind, payload, priority)
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(kind) then
        return
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    payload.sentAt = time()
    local msg = LibStub("AceSerializer-3.0"):Serialize(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "GUILD", nil, priority or "NORMAL")
    end
end

function Sync:SendDirectEnvelope(kind, payload, targetKey, priority)
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(kind) then
        return
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return
    end
    local target = self:GetWhisperTarget(targetKey)
    if not target then return end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    payload.sentAt = time()
    local msg = LibStub("AceSerializer-3.0"):Serialize(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "WHISPER", target, priority or "NORMAL")
    end
end

function Sync:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= PREFIX then return end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end

    local ok, payload = LibStub("AceSerializer-3.0"):Deserialize(text)
    if not ok or type(payload) ~= "table" then return end
    if payload.sender == self:GetSelfKey() then return end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic(payload.kind) then
        return
    end

    if payload.sender then
        self:TouchNode(payload.sender, payload.version)
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
    end
end

function Sync:HandleHello(payload)
    if not self:IsValidSyncMemberKey(payload.key) then return end
    self:TouchNode(payload.key, payload.version)
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.key)
    if self:IsMockKey(payload.key) then return end
    if self:IsInWarmup() then
        self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
        Addon:Debug("Warmup deferring manifest reply", tostring(payload.key))
        self:QueueWarmupManifestPeer(payload.key, "hello")
    else
        self:SendManifestToPeer(payload.key, "hello")
    end
    if self:ShouldRequestManifestRefresh(payload.key) then
        if self:IsInWarmup() then
            Addon:Debug("Warmup deferring manifest refresh request", tostring(payload.key))
            self:QueueWarmupManifestRefresh(payload.key)
        else
            self:RequestManifestRefresh(payload.key)
        end
    end

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0

    if remoteRev > localRev then
        if self:IsCoordinator() then
            self:BroadcastIndex(payload.key, remoteRev, payload.updatedAt, payload.key, "hello")
        end
        self:QueueRequest(payload.key, payload.key, remoteRev, "hello-auto")
    end
end

function Sync:HandleAdvertise(payload)
    if not self:IsValidSyncMemberKey(payload.key) or not self:IsValidSyncMemberKey(payload.sender) then return end
    self:TouchNode(payload.sender)
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
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, ownerKey)

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0
    if remoteRev > localRev then
        self:QueueRequest(ownerKey, payload.key, remoteRev, "index")
    end
end