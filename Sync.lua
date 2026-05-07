local Addon = _G.RecipeRegistry
local Sync = Addon:NewModule("Sync", "AceComm-3.0", "AceEvent-3.0", "AceTimer-3.0")
Addon.Sync = Sync

local PREFIX = Addon.ADDON_PREFIX
local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local random = math.random
local tinsert = table.insert
local GetTime = GetTime

local REQUEST_TIMEOUT = 12
local PROGRESS_TIMEOUT = 4
local SESSION_TIMEOUT = 35
local NODE_TIMEOUT = 95
local HELLO_INTERVAL = 30
local AUTO_SYNC_INTERVAL = 20
local OUTGOING_CHUNK_DELAY = 0.20
local MANIFEST_CHUNK_DELAY = 0.12
local MANIFEST_INITIAL_JITTER = 0.35
local MAX_RESUME_ATTEMPTS = 3
local COORDINATOR_RECOMPUTE_DELAY = 0.35
local MANIFEST_PUSH_COOLDOWN = 20
local OFFLINE_DEBUG_LOG_LIMIT = 12

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

local function nowForPacing()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

local function shallowCopyArray(src)
    local out = {}
    for i = 1, #(src or {}) do out[i] = src[i] end
    return out
end

local function shallowCopyTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function countArrayUnique(values)
    local seen = {}
    local count = 0
    for _, value in ipairs(values or {}) do
        if value and not seen[value] then
            seen[value] = true
            count = count + 1
        end
    end
    return count
end

local function cloneStringSet(src)
    local out = {}
    for _, value in ipairs(src or {}) do
        if value then
            out[#out + 1] = value
        end
    end
    return out
end

local function mergeRequestedBlocks(existing, incoming)
    if type(existing) ~= "table" or #existing == 0 then
        return cloneStringSet(incoming)
    end
    if type(incoming) ~= "table" or #incoming == 0 then
        return cloneStringSet(existing)
    end

    local seen = {}
    local merged = {}
    for _, blockKey in ipairs(existing) do
        if blockKey and not seen[blockKey] then
            seen[blockKey] = true
            merged[#merged + 1] = blockKey
        end
    end
    for _, blockKey in ipairs(incoming) do
        if blockKey and not seen[blockKey] then
            seen[blockKey] = true
            merged[#merged + 1] = blockKey
        end
    end
    sort(merged)
    return merged
end

local function isMockKey(memberKey)
    return type(memberKey) == "string"
        and (memberKey:find("__RRMockPeer", 1, true) == 1 or memberKey:find("__RRMockOwner", 1, true) == 1)
end

function Sync:OnInitialize()
    self.onlineNodes = {}
    self.registry = {}
    self.pendingRequests = {}
    self.partialReceive = {}
    self.outgoingSessions = {}
    self.coordinatorKey = nil
    self.inFlight = nil
    self.lastAdvertisedRev = nil
    self._lastCoordinatorChangeAt = 0
    self.lastHelloAt = 0
    self.outboundChunkQueue = {}
    self.manifestChunkQueue = {}
    self.inboundChunkQueue = {}
    self.inboundFinalizeQueue = {}
    self.peerPacing = {}
    self.partialManifestReceive = {}
    self._lastManifestSentAt = {}
    self.pendingManifestPeers = {}
    self.telemetry = {
        sentChunks = 0,
        receivedChunks = 0,
        appliedChunks = 0,
        skippedEquivalentMerges = 0,
        pausedSyncCycles = 0,
        busySeedRejections = 0,
        replicaManifestOwnersSeen = 0,
        replicaManifestBlocksSeen = 0,
        replicaRequestsQueued = 0,
        replicaRequestsServed = 0,
        replicaOwnersApplied = 0,
        replicaNewOwnersApplied = 0,
        manifestChunksSent = 0,
        manifestChunksQueued = 0,
        manifestChunksDelivered = 0,
        manifestCooldownSkips = 0,
        manifestDeferredSends = 0,
        manifestPendingFlushes = 0,
        manifestQueueMaxDepth = 0,
    }
    self.offlineDebugLog = {}
end

function Sync:ResetTelemetry()
    self.telemetry = {
        sentChunks = 0,
        receivedChunks = 0,
        appliedChunks = 0,
        skippedEquivalentMerges = 0,
        pausedSyncCycles = 0,
        busySeedRejections = 0,
        replicaManifestOwnersSeen = 0,
        replicaManifestBlocksSeen = 0,
        replicaRequestsQueued = 0,
        replicaRequestsServed = 0,
        replicaOwnersApplied = 0,
        replicaNewOwnersApplied = 0,
        manifestChunksSent = 0,
        manifestChunksQueued = 0,
        manifestChunksDelivered = 0,
        manifestCooldownSkips = 0,
        manifestDeferredSends = 0,
        manifestPendingFlushes = 0,
        manifestQueueMaxDepth = 0,
    }
    self.offlineDebugLog = {}
end

function Sync:PushOfflineDebugEvent(kind, detail)
    local stamp = date and date("%H:%M:%S") or tostring(time())
    local line = string.format("%s %s %s", tostring(stamp), tostring(kind or "event"), tostring(detail or ""))
    self.offlineDebugLog[#self.offlineDebugLog + 1] = line
    while #self.offlineDebugLog > OFFLINE_DEBUG_LOG_LIMIT do
        table.remove(self.offlineDebugLog, 1)
    end
end

function Sync:Startup()
    self:RegisterComm(PREFIX)
    self:ScheduleHello(1)
    self.helloTicker = self:ScheduleRepeatingTimer("BroadcastHello", HELLO_INTERVAL)
    self.queueTicker = self:ScheduleRepeatingTimer("ProcessRequestQueue", 1)
    self.pruneTicker = self:ScheduleRepeatingTimer("PruneState", 5)
    self.autoSyncTicker = self:ScheduleRepeatingTimer("AutoSyncTick", AUTO_SYNC_INTERVAL)
    self:ScheduleTimer("AutoSyncTick", 6)
    self:AdvertiseLocalRevision("startup")
    self:EnsureBackgroundWorkers()
    if Addon.Data and Addon.Data.ScheduleManifestBuild then
        Addon.Data:ScheduleManifestBuild("startup")
    end
end

function Sync:GetSelfKey()
    return Addon.Data:GetPlayerKey()
end

function Sync:GetWhisperTarget(memberKey)
    if not memberKey then return nil end
    local name = memberKey:match("^([^%-]+)")
    return name or memberKey
end

function Sync:IsRealTrafficSuppressed()
    return Addon.MockSync
        and Addon.MockSync.IsHardIsolationEnabled
        and Addon.MockSync:IsHardIsolationEnabled()
        or false
end

function Sync:IsMockKey(memberKey)
    if isMockKey(memberKey) then return true end
    local row = memberKey and self.registry and self.registry[memberKey] or nil
    return row and row.isMock == true or false
end

function Sync:IsValidSyncMemberKey(memberKey)
    if Addon.Data and Addon.Data.IsValidMemberKey then
        return Addon.Data:IsValidMemberKey(memberKey)
    end
    return type(memberKey) == "string"
        and memberKey ~= ""
        and not memberKey:find(":", 1, true)
        and memberKey:find("-", 1, true) ~= nil
end

function Sync:IsRequestShapeValid(request)
    return request
        and self:IsValidSyncMemberKey(request.memberKey)
        and self:IsValidSyncMemberKey(request.source)
end

function Sync:ShouldAllowLocalMockTraffic(sourceKey, memberKey)
    if not (Addon.MockSync and Addon.MockSync.IsLocalTrafficEnabled) then
        return false
    end
    return Addon.MockSync:IsLocalTrafficEnabled(sourceKey, memberKey)
end

function Sync:OnGuildRosterUpdate()
    self:PruneOnlineNodes()
    self:RecomputeCoordinator()
end

function Sync:ScheduleHello(delay)
    self:ScheduleTimer("BroadcastHello", delay or 0.5)
end

function Sync:BroadcastHello()
    self.lastHelloAt = time()
    local summary = Addon.Data:GetLocalSummary()
    self:RecordRevisionHint(summary.memberKey, summary.rev, summary.updatedAt, summary.memberKey)
    self:SendGuildEnvelope("HELLO", {
        key = self:GetSelfKey(),
        rev = summary.rev,
        updatedAt = summary.updatedAt,
        version = Addon.DISPLAY_VERSION,
    }, "ALERT")
    self:BroadcastManifestToOnlinePeers("hello-broadcast")
end

function Sync:AdvertiseLocalRevision(reason)
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

function Sync:TouchNode(key, version)
    if not self:IsValidSyncMemberKey(key) then return end
    self.onlineNodes[key] = self.onlineNodes[key] or {}
    self.onlineNodes[key].lastSeen = time()
    self.onlineNodes[key].version = version or self.onlineNodes[key].version

    local selfKey = self:GetSelfKey()
    self.onlineNodes[selfKey] = self.onlineNodes[selfKey] or { version = Addon.DISPLAY_VERSION }
    self.onlineNodes[selfKey].lastSeen = time()

    if self._recomputeTimer then return end
    self._recomputeTimer = self:ScheduleTimer(function()
        self._recomputeTimer = nil
        self:RecomputeCoordinator()
    end, COORDINATOR_RECOMPUTE_DELAY)
end

function Sync:PruneOnlineNodes()
    local now = time()
    for key, info in pairs(self.onlineNodes) do
        if info.lastSeen and (now - info.lastSeen) > NODE_TIMEOUT then
            self.onlineNodes[key] = nil
        end
    end
end

function Sync:PruneState()
    self:PruneOnlineNodes()
    self:PruneOutgoingSessions()
    self:PrunePartialReceives()
    self:RecomputeCoordinator()
end

function Sync:RecomputeCoordinator()
    local keys = {}
    for key in pairs(self.onlineNodes) do
        if self:IsValidSyncMemberKey(key)
            and not self:IsMockKey(key)
            and (Addon.Data:IsMemberOnline(key) or key == self:GetSelfKey()) then
            keys[#keys + 1] = key
        end
    end
    if #keys == 0 then
        keys[1] = self:GetSelfKey()
    end
    sort(keys)
    local nextCoordinator = keys[1]
    if nextCoordinator ~= self.coordinatorKey then
        self.coordinatorKey = nextCoordinator
        self._lastCoordinatorChangeAt = time()
        Addon:Debug("Coordinator changed to", tostring(nextCoordinator))
        Addon:RequestRefresh("coordinator")
    end
end

function Sync:IsCoordinator()
    return self.coordinatorKey == self:GetSelfKey()
end

function Sync:RecordRevisionHint(memberKey, rev, updatedAt, owner, meta)
    if not self:IsValidSyncMemberKey(memberKey) then return end
    if owner and not self:IsValidSyncMemberKey(owner) then owner = memberKey end
    meta = meta or {}
    local row = self.registry[memberKey] or { owner = owner or memberKey, rev = 0, updatedAt = 0 }
    if owner then row.owner = owner end
    if (rev or 0) >= (row.rev or 0) then
        row.rev = rev or row.rev or 0
        row.updatedAt = updatedAt or row.updatedAt or 0
    end
    if meta.isMock ~= nil then
        row.isMock = meta.isMock and true or false
    elseif row.isMock == nil and isMockKey(memberKey) then
        row.isMock = true
    end
    row.lastSeen = time()
    self.registry[memberKey] = row
end

function Sync:GetKnownOwner(memberKey)
    local row = self.registry[memberKey]
    if row and self:IsValidSyncMemberKey(row.owner) then return row.owner end
    return memberKey
end

function Sync:GetKnownRevision(memberKey)
    local row = self.registry[memberKey]
    return row and (row.rev or 0) or 0
end

function Sync:HandleHello(payload)
    if not self:IsValidSyncMemberKey(payload.key) then return end
    self:TouchNode(payload.key, payload.version)
    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.key)
    if self:IsMockKey(payload.key) then return end
    self:SendManifestToPeer(payload.key, "hello")

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

function Sync:QueueRequest(sourceKey, memberKey, targetRev, why, opts)
    if not sourceKey or not memberKey then return end
    if not self:IsValidSyncMemberKey(memberKey) then
        Addon:Debug("Skipped malformed sync request", tostring(memberKey), "from", tostring(sourceKey), why or "")
        return
    end
    if not self:IsValidSyncMemberKey(sourceKey) then
        sourceKey = self:GetKnownOwner(memberKey)
    end
    if not self:IsValidSyncMemberKey(sourceKey) then
        Addon:Debug("Skipped sync request with malformed source", tostring(memberKey), "from", tostring(sourceKey), why or "")
        return
    end
    local allowLocalMock = self:ShouldAllowLocalMockTraffic(sourceKey, memberKey)
    if (self:IsMockKey(sourceKey) or self:IsMockKey(memberKey)) and not allowLocalMock then return end
    opts = opts or {}

    local knownOwner = self:GetKnownOwner(memberKey)
    if not opts.allowReplicaSource and sourceKey ~= knownOwner and knownOwner then
        sourceKey = knownOwner
    end

    local q = self.pendingRequests[memberKey]
    if q and (q.rev or 0) >= (targetRev or 0) then
        if opts.requestedBlocks and #opts.requestedBlocks > 0 then
            q.requestedBlocks = mergeRequestedBlocks(q.requestedBlocks, opts.requestedBlocks)
            q.allowReplicaSource = q.allowReplicaSource or opts.allowReplicaSource == true
            q.source = opts.allowReplicaSource and sourceKey or q.source
        end
        return
    end

    self.pendingRequests[memberKey] = {
        source = sourceKey,
        memberKey = memberKey,
        rev = targetRev or 0,
        why = why,
        queuedAt = time(),
        attempts = q and q.attempts or 0,
        resumeAttempts = 0,
        allowReplicaSource = opts.allowReplicaSource == true,
        requestedBlocks = cloneStringSet(opts.requestedBlocks),
    }
    Addon:Debug("Queued direct request", memberKey, "from", sourceKey, "rev", targetRev or 0, why or "")
    Addon:RequestRefresh("queue")
end

function Sync:ProcessRequestQueue()
    if self.inFlight then
        if not self:IsRequestShapeValid(self.inFlight) then
            Addon:Debug("Dropping malformed in-flight request", tostring(self.inFlight.memberKey), "from", tostring(self.inFlight.source))
            self:FailInFlight(false)
            return
        end
        if not self:IsRequestStillViable(self.inFlight) then
            Addon:Debug("Dropping in-flight request; source unavailable", self.inFlight.memberKey)
            self:FailInFlight(true)
            return
        end

        local now = time()
        if (now - (self.inFlight.startedAt or now)) > SESSION_TIMEOUT then
            Addon:Debug("Request session timeout", self.inFlight.memberKey)
            self:FailInFlight(true)
            return
        end

        if not self.inFlight.sessionId then
            if (now - (self.inFlight.startedAt or now)) > REQUEST_TIMEOUT then
                Addon:Debug("Initial request timeout", self.inFlight.memberKey)
                self:FailInFlight(true)
            end
            return
        end

        if (now - (self.inFlight.lastProgressAt or now)) > PROGRESS_TIMEOUT then
            if (self.inFlight.resumeAttempts or 0) < MAX_RESUME_ATTEMPTS then
                self.inFlight.resumeAttempts = (self.inFlight.resumeAttempts or 0) + 1
                self.inFlight.lastProgressAt = now
                self:SendResumeForInFlight()
            else
                Addon:Debug("Resume exhausted", self.inFlight.memberKey)
                self:FailInFlight(true)
            end
        end
        return
    end

    local oldestKey, oldest
    for memberKey, info in pairs(self.pendingRequests) do
        if not self:IsRequestShapeValid(info) then
            self.pendingRequests[memberKey] = nil
        else
            local allowLocalMock = self:ShouldAllowLocalMockTraffic(info and info.source, memberKey)
            if not self:IsRealTrafficSuppressed() or allowLocalMock then
                if not oldest or info.queuedAt < oldest.queuedAt then
                    oldest = info
                    oldestKey = memberKey
                end
            end
        end
    end
    if not oldest then return end

    if not self:IsRequestStillViable(oldest) then
        self.pendingRequests[oldestKey] = nil
        return
    end

    self.pendingRequests[oldestKey] = nil
    self.inFlight = {
        memberKey = oldest.memberKey,
        source = oldest.source,
        rev = oldest.rev,
        why = oldest.why,
        startedAt = time(),
        lastProgressAt = time(),
        attempts = (oldest.attempts or 0) + 1,
        resumeAttempts = 0,
        allowReplicaSource = oldest.allowReplicaSource == true,
        requestedBlocks = cloneStringSet(oldest.requestedBlocks),
    }

    local localEntry = Addon.Data:GetMember(oldest.memberKey)
    local knownRev = localEntry and localEntry.rev or 0
    if self:ShouldAllowLocalMockTraffic(oldest.source, oldest.memberKey) then
        if not (Addon.MockSync and Addon.MockSync.HandleLocalRequest) then
            self:FailInFlight(false)
            return
        end
        local accepted = Addon.MockSync:HandleLocalRequest({
            source = oldest.source,
            memberKey = oldest.memberKey,
            knownRev = knownRev,
            wantRev = oldest.rev or 0,
            allowReplicaSource = oldest.allowReplicaSource == true,
            requestedBlocks = cloneStringSet(oldest.requestedBlocks),
        })
        if not accepted then
            self:FailInFlight(false)
        end
        return
    end
    self:SendDirectEnvelope("REQ", {
        key = oldest.memberKey,
        knownRev = knownRev,
        wantRev = oldest.rev or 0,
        requestedBlocks = cloneStringSet(oldest.requestedBlocks),
    }, oldest.source, "ALERT")
end

function Sync:IsRequestStillViable(request)
    if not self:IsRequestShapeValid(request) then return false end
    if request.source == self:GetSelfKey() then return true end
    return self.onlineNodes[request.source] ~= nil
end

function Sync:FailInFlight(requeue)
    if self.inFlight and requeue and self:IsRequestShapeValid(self.inFlight) then
        local req = self.inFlight
        self.pendingRequests[req.memberKey] = {
            source = req.source,
            memberKey = req.memberKey,
            rev = req.rev,
            why = (req.why or "") .. ":retry",
            queuedAt = time() + random(),
            attempts = req.attempts or 1,
            resumeAttempts = req.resumeAttempts or 0,
            allowReplicaSource = req.allowReplicaSource == true,
            requestedBlocks = cloneStringSet(req.requestedBlocks),
        }
    end
    if self.inFlight then
        self.partialReceive[self.inFlight.memberKey] = nil
    end
    self.inFlight = nil
    Addon:RequestRefresh("queue")
end

function Sync:BuildSessionId(memberKey, rev)
    return string.format("%s:%d:%d", memberKey or "unknown", rev or 0, time())
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

    local sessionId = self:BuildSessionId(payload.key, entry.rev or 0)
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

    if self.inFlight and self.inFlight.memberKey == payload.key then
        self.inFlight.sessionId = payload.sessionId
        self.inFlight.lastProgressAt = time()
        self.inFlight.source = payload.sender or self.inFlight.source
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
        self.partialReceive[payload.key] = nil
        self.inboundFinalizeQueue[#self.inboundFinalizeQueue + 1] = {
            memberKey = payload.key,
            rev = payload.rev,
            updatedAt = payload.updatedAt,
            sender = payload.sender,
            sessionId = payload.sessionId,
        }
        if not self:IsMockKey(payload.sender) then
            self:SendDirectEnvelope("DONE", {
                sessionId = payload.sessionId,
                key = payload.key,
                rev = payload.rev,
            }, payload.sender, "ALERT")
        end

        if self.inFlight and self.inFlight.memberKey == payload.key then
            self.inFlight = nil
        end

        Addon:RequestRefresh("snapshot-complete")
    end
end

function Sync:SendManifestToPeer(peerKey, why)
    if not peerKey or not Addon.TrickleSync then return end
    if not self:IsValidSyncMemberKey(peerKey) then return end
    if self:IsMockKey(peerKey) then return end
    local lastSentAt = self._lastManifestSentAt[peerKey] or 0
    if why ~= "force" and (time() - lastSentAt) < MANIFEST_PUSH_COOLDOWN then
        self.telemetry.manifestCooldownSkips = (self.telemetry.manifestCooldownSkips or 0) + 1
        return
    end

    local chunks = Addon.TrickleSync:BuildManifestChunks({
        allowStale = false,
        syncFallback = false,
        reason = why or "send",
    })
    if not chunks then
        self.pendingManifestPeers = self.pendingManifestPeers or {}
        self.pendingManifestPeers[peerKey] = why or "pending"
        self.telemetry.manifestDeferredSends = (self.telemetry.manifestDeferredSends or 0) + 1
        return
    end
    self:QueueManifestChunks(peerKey, chunks, why)
    self._lastManifestSentAt[peerKey] = time()
end

function Sync:QueueManifestChunks(peerKey, chunks, why)
    if not peerKey or not chunks then return false end
    self.manifestChunkQueue = self.manifestChunkQueue or {}
    local startAt = nowForPacing()
    if why ~= "force" and MANIFEST_INITIAL_JITTER > 0 then
        startAt = startAt + (random() * MANIFEST_INITIAL_JITTER)
    end

    for index = 1, #chunks do
        local payload = shallowCopyTable(chunks[index])
        payload.why = why
        self.manifestChunkQueue[#self.manifestChunkQueue + 1] = {
            peer = peerKey,
            payload = payload,
            queuedAt = time(),
            readyAt = startAt + ((index - 1) * MANIFEST_CHUNK_DELAY),
        }
    end
    self.telemetry.manifestChunksQueued = (self.telemetry.manifestChunksQueued or 0) + #chunks
    if #self.manifestChunkQueue > (self.telemetry.manifestQueueMaxDepth or 0) then
        self.telemetry.manifestQueueMaxDepth = #self.manifestChunkQueue
    end
    return true
end

function Sync:OnManifestCacheReady(reason)
    if not self.pendingManifestPeers or next(self.pendingManifestPeers) == nil then return end
    local pending = self.pendingManifestPeers
    self.pendingManifestPeers = {}
    self.telemetry.manifestPendingFlushes = (self.telemetry.manifestPendingFlushes or 0) + 1
    for peerKey, why in pairs(pending) do
        self:SendManifestToPeer(peerKey, why or reason or "manifest-ready")
    end
end

function Sync:RequestManifestRefresh(peerKey)
    if peerKey and peerKey ~= "" then
        if self:IsMockKey(peerKey) then return end
        self:SendDirectEnvelope("MREQ", {
            key = self:GetSelfKey(),
            why = "manual",
        }, peerKey, "NORMAL")
        return
    end

    self:SendGuildEnvelope("MREQ", {
        key = self:GetSelfKey(),
        why = "manual-all",
    }, "NORMAL")
end

function Sync:HandleManifestRequest(payload)
    if not self:IsValidSyncMemberKey(payload.sender) or payload.sender == self:GetSelfKey() then return end
    if self:IsMockKey(payload.sender) then return end
    self:SendManifestToPeer(payload.sender, "force")
end

function Sync:BroadcastManifestToOnlinePeers(why)
    for peerKey in pairs(self.onlineNodes or {}) do
        if peerKey ~= self:GetSelfKey() and self:IsValidSyncMemberKey(peerKey) and not self:IsMockKey(peerKey) then
            self:SendManifestToPeer(peerKey, why or "broadcast")
        end
    end
end

function Sync:HandleManifestChunk(payload)
    if not self:IsValidSyncMemberKey(payload.sender) or payload.sender == self:GetSelfKey() then return end
    if not payload.manifestId then return end
    if self:IsMockKey(payload.sender) and not self:ShouldAllowLocalMockTraffic(payload.sender, nil) then return end

    local senderKey = payload.sender
    local manifestMemberKey = self:IsValidSyncMemberKey(payload.memberKey) and payload.memberKey or senderKey
    self.partialManifestReceive[senderKey] = self.partialManifestReceive[senderKey] or {}
    local state = self.partialManifestReceive[senderKey][payload.manifestId]
    if not state then
        state = {
            manifestId = payload.manifestId,
            builtAt = payload.builtAt or time(),
            memberKey = manifestMemberKey,
            totals = payload.totals or {},
            total = payload.total or 1,
            seen = {},
            blocks = {},
        }
        self.partialManifestReceive[senderKey][payload.manifestId] = state
    end

    state.seen[payload.seq or 1] = true
    state.total = payload.total or state.total or 1
    for _, block in ipairs(payload.blocks or {}) do
        local blockKey = block and block.blockKey
        local ownerCharacter, professionKey = Addon.Data:ParseSyncBlockKey(blockKey)
        if Addon.Data:IsValidMemberKey(ownerCharacter)
            and type(professionKey) == "string"
            and professionKey ~= ""
            and (not block.ownerCharacter or block.ownerCharacter == ownerCharacter)
            and (not block.professionKey or block.professionKey == professionKey) then
            block.ownerCharacter = ownerCharacter
            block.professionKey = professionKey
            state.blocks[blockKey] = block
        else
            Addon:Debug("Ignored malformed manifest block", tostring(blockKey), "from", tostring(senderKey))
        end
    end

    local complete = true
    for seq = 1, (state.total or 1) do
        if not state.seen[seq] then
            complete = false
            break
        end
    end
    if not complete then return end

    local manifest = {
        builtAt = state.builtAt,
        memberKey = state.memberKey,
        totals = state.totals,
        blocks = state.blocks,
    }

    self.partialManifestReceive[senderKey][payload.manifestId] = nil
    if next(self.partialManifestReceive[senderKey]) == nil then
        self.partialManifestReceive[senderKey] = nil
    end

    Addon.TrickleSync:StorePeerManifest(senderKey, manifest)
    local _, groupedRequests = Addon.TrickleSync:QueueMissingBlocksForPeer(senderKey, manifest)
    local replicaOwners = {}
    local replicaBlocks = 0
    for blockKey, block in pairs(manifest.blocks or {}) do
        if block and Addon.Data:IsValidMemberKey(block.ownerCharacter) and block.ownerCharacter ~= senderKey and not Addon.Data:IsMemberOnline(block.ownerCharacter) then
            replicaBlocks = replicaBlocks + 1
            replicaOwners[#replicaOwners + 1] = block.ownerCharacter
        elseif block and block.sourceType == "replica" and Addon.Data:IsValidMemberKey(block.ownerCharacter) and not Addon.Data:IsMemberOnline(block.ownerCharacter) then
            replicaBlocks = replicaBlocks + 1
            replicaOwners[#replicaOwners + 1] = block.ownerCharacter
        end
    end
    if replicaBlocks > 0 then
        local uniqueReplicaOwners = countArrayUnique(replicaOwners)
        self.telemetry.replicaManifestBlocksSeen = self.telemetry.replicaManifestBlocksSeen + replicaBlocks
        self.telemetry.replicaManifestOwnersSeen = self.telemetry.replicaManifestOwnersSeen + uniqueReplicaOwners
        self:PushOfflineDebugEvent("manifest", string.format("peer=%s owners=%d blocks=%d", tostring(senderKey), uniqueReplicaOwners, replicaBlocks))
    end
    for ownerCharacter, request in pairs(groupedRequests or {}) do
        local ownerIsOnline = Addon.Data:IsMemberOnline(ownerCharacter)
        local shouldRequestReplica = ownerCharacter == senderKey or not ownerIsOnline
        if ownerCharacter ~= senderKey and not ownerIsOnline then
            self.telemetry.replicaRequestsQueued = self.telemetry.replicaRequestsQueued + 1
            self:PushOfflineDebugEvent("queued", string.format("%s from %s blocks=%d rev=%d", tostring(ownerCharacter), tostring(senderKey), #(request.blockKeys or {}), request.revision or 0))
        end
        if shouldRequestReplica then
            self:QueueRequest(senderKey, ownerCharacter, request.revision or 0, "manifest", {
                allowReplicaSource = true,
                requestedBlocks = request.blockKeys,
            })
        end
    end
    Addon:RequestRefresh("manifest")
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

function Sync:SendResumeForInFlight()
    if not self.inFlight then return end
    if self:IsMockKey(self.inFlight.source) then return end
    local partial = self.partialReceive[self.inFlight.memberKey]
    if not partial or partial.sessionId ~= self.inFlight.sessionId then
        self:FailInFlight(true)
        return
    end

    local missing = self:GetMissingSeqs(partial)
    if #missing == 0 then return end

    self:SendDirectEnvelope("RESUME", {
        sessionId = partial.sessionId,
        key = partial.memberKey,
        rev = partial.rev,
        missing = missing,
    }, self.inFlight.source, "ALERT")
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
    self.outgoingSessions[payload.sessionId] = nil
end

function Sync:PruneOutgoingSessions()
    local now = time()
    for sessionId, state in pairs(self.outgoingSessions) do
        if (now - (state.createdAt or now)) > SESSION_TIMEOUT then
            self.outgoingSessions[sessionId] = nil
        end
    end
end

function Sync:PrunePartialReceives()
    local now = time()
    for memberKey, state in pairs(self.partialReceive) do
        if (now - (state.lastProgressAt or now)) > SESSION_TIMEOUT then
            self.partialReceive[memberKey] = nil
            if self.inFlight and self.inFlight.memberKey == memberKey then
                self:FailInFlight(true)
            end
        end
    end
end

function Sync:AutoSyncTick()
    if not IsInGuild() then return end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() then
        self.telemetry.pausedSyncCycles = self.telemetry.pausedSyncCycles + 1
        return
    end

    if countKeys(self.onlineNodes) == 0 then
        if (time() - (self.lastHelloAt or 0)) > 10 then
            self:BroadcastHello()
        end
        return
    end

    if not self.inFlight then
        for key, hint in pairs(self.registry) do
            if not self:IsMockKey(key) and not self:IsMockKey(hint.owner) then
                local localEntry = Addon.Data:GetMember(key)
                local localRev = localEntry and localEntry.rev or 0
                if (hint.rev or 0) > localRev then
                    self:QueueRequest(hint.owner or key, key, hint.rev or 0, "auto-tick")
                end
            end
        end
        self:BroadcastManifestToOnlinePeers("auto-tick")
    end

    if (time() - (self.lastHelloAt or 0)) > HELLO_INTERVAL then
        self:BroadcastHello()
    end
end

function Sync:EnsureBackgroundWorkers()
    if self._workersReady or not Addon.Performance then return end
    self._workersReady = true
    Addon.Performance:ScheduleJob("sync-outbound-loop", function()
        return self:SendNextLowPriorityChunk()
    end, {
        category = "sync-outbound",
        label = "sync-outbound-loop",
        budgetMs = 2,
    })
    Addon.Performance:ScheduleJob("sync-inbound-loop", function()
        return self:ProcessInboundQueue()
    end, {
        category = "sync-inbound",
        label = "sync-inbound-loop",
        budgetMs = 2,
    })
end

function Sync:QueueOutboundBlock(peer, block)
    if not peer or not block then return false end
    self.outboundChunkQueue[#self.outboundChunkQueue + 1] = {
        peer = peer,
        block = block,
        queuedAt = time(),
    }
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
    self:SendDirectEnvelope("SNAP", block, queued.peer, "BULK")
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = nowForPacing()
    self.telemetry.sentChunks = self.telemetry.sentChunks + 1

    local session = self.outgoingSessions[block.sessionId]
    if session then
        session.lastSentAt = time()
    end
    return true
end

function Sync:SendNextManifestChunk()
    if #(self.manifestChunkQueue or {}) == 0 then
        return false
    end

    local now = nowForPacing()
    local candidateIndex
    for index = 1, #self.manifestChunkQueue do
        local queued = self.manifestChunkQueue[index]
        if (queued.readyAt or 0) <= now and self:CanSendToPeer(queued.peer, MANIFEST_CHUNK_DELAY) then
            candidateIndex = index
            break
        end
    end
    if not candidateIndex then
        return false
    end

    local queued = table.remove(self.manifestChunkQueue, candidateIndex)
    self:SendDirectEnvelope("MANI", queued.payload, queued.peer, "NORMAL")
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = now
    self.telemetry.manifestChunksSent = (self.telemetry.manifestChunksSent or 0) + 1
    self.telemetry.manifestChunksDelivered = (self.telemetry.manifestChunksDelivered or 0) + 1
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
end

function Sync:DecodeChunkStep(payload)
    if not payload then return false end
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

function Sync:RecordPauseCycle(paused)
    if paused then
        self.telemetry.pausedSyncCycles = self.telemetry.pausedSyncCycles + 1
    end
end

function Sync:RecordMergeSkip(reason)
    if reason == "equivalent" then
        self.telemetry.skippedEquivalentMerges = self.telemetry.skippedEquivalentMerges + 1
    end
end

function Sync:RequestGuildCatchup(memberKey, silent)
    if memberKey and memberKey ~= "" then
        if self:IsMockKey(memberKey) then return end
        local remoteRev = self:GetKnownRevision(memberKey)
        if remoteRev == 0 then
            local localEntry = Addon.Data:GetMember(memberKey)
            remoteRev = (localEntry and localEntry.rev or 0) + 1
        end
        self:QueueRequest(self:GetKnownOwner(memberKey), memberKey, remoteRev, "manual")
        return
    end

    for key, hint in pairs(self.registry) do
        if not self:IsMockKey(key) and not self:IsMockKey(hint.owner) then
            local localEntry = Addon.Data:GetMember(key)
            local localRev = localEntry and localEntry.rev or 0
            if (hint.rev or 0) > localRev then
                self:QueueRequest(hint.owner or key, key, hint.rev or 0, "manual-all")
            end
        end
    end
    self:RequestManifestRefresh()
    if not silent then
        Addon:Print("Queued direct catch-up requests and requested fresh manifests from online peers.")
    end
end

function Sync:GetUiState()
    local pauseState = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false
    local bootstrapState = Addon.BootstrapSync and Addon.BootstrapSync:GetUiState() or nil
    return {
        role = self:IsCoordinator() and "Coordinator" or "Client",
        coordinatorKey = self.coordinatorKey,
        onlineNodes = countKeys(self.onlineNodes),
        registry = countKeys(self.registry),
        queued = countKeys(self.pendingRequests),
        inFlight = self.inFlight and self.inFlight.memberKey or nil,
        outgoing = countKeys(self.outgoingSessions),
        outboundChunks = #self.outboundChunkQueue,
        manifestChunks = #(self.manifestChunkQueue or {}),
        inboundChunks = #self.inboundChunkQueue,
        autoSync = true,
        paused = pauseState,
        bootstrap = bootstrapState,
        telemetry = self.telemetry,
    }
end

function Sync:GetDebugSnapshot()
    return {
        onlineNodes = countKeys(self.onlineNodes),
        registry = countKeys(self.registry),
        pendingRequests = countKeys(self.pendingRequests),
        outgoingSessions = countKeys(self.outgoingSessions),
        outboundChunks = #self.outboundChunkQueue,
        manifestChunks = #(self.manifestChunkQueue or {}),
        inboundChunks = #self.inboundChunkQueue,
        inboundFinalize = #self.inboundFinalizeQueue,
        inFlight = self.inFlight and self.inFlight.memberKey or nil,
        paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false,
        isolated = self:IsRealTrafficSuppressed(),
        telemetry = self.telemetry,
        offlineDebugLog = shallowCopyArray(self.offlineDebugLog),
    }
end

function Sync:DumpOfflineSyncStatus()
    local t = self.telemetry or {}
    Addon:Print(string.format(
        "Offline sync manifests owners=%d blocks=%d queued=%d served=%d applied=%d newOwners=%d",
        t.replicaManifestOwnersSeen or 0,
        t.replicaManifestBlocksSeen or 0,
        t.replicaRequestsQueued or 0,
        t.replicaRequestsServed or 0,
        t.replicaOwnersApplied or 0,
        t.replicaNewOwnersApplied or 0
    ))
    if #(self.offlineDebugLog or {}) == 0 then
        Addon:Print("Offline sync recent: none")
        return
    end
    Addon:Print("Offline sync recent:")
    for index = 1, #self.offlineDebugLog do
        Addon:Print("  " .. tostring(self.offlineDebugLog[index]))
    end
end

function Sync:CleanupMockState()
    local removedRegistry = 0
    local removedOnlineNodes = 0
    local removedPendingRequests = 0

    for key, row in pairs(self.registry or {}) do
        if self:IsMockKey(key) or (row and row.isMock) then
            self.registry[key] = nil
            removedRegistry = removedRegistry + 1
        end
    end

    for key in pairs(self.onlineNodes or {}) do
        if self:IsMockKey(key) then
            self.onlineNodes[key] = nil
            removedOnlineNodes = removedOnlineNodes + 1
        end
    end

    for memberKey, info in pairs(self.pendingRequests or {}) do
        if self:IsMockKey(memberKey) or self:IsMockKey(info and info.source) then
            self.pendingRequests[memberKey] = nil
            removedPendingRequests = removedPendingRequests + 1
        end
    end

    for memberKey, info in pairs(self.partialReceive or {}) do
        if self:IsMockKey(memberKey) or self:IsMockKey(info and info.source) then
            self.partialReceive[memberKey] = nil
        end
    end

    for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
        if self:IsMockKey(peerKey) then
            self.partialManifestReceive[peerKey] = nil
        elseif type(manifests) == "table" then
            for manifestId, state in pairs(manifests) do
                if self:IsMockKey(state and state.memberKey) then
                    manifests[manifestId] = nil
                end
            end
            if next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    for peerKey in pairs(self._lastManifestSentAt or {}) do
        if self:IsMockKey(peerKey) then
            self._lastManifestSentAt[peerKey] = nil
        end
    end

    for sessionId, state in pairs(self.outgoingSessions or {}) do
        if self:IsMockKey(state and state.memberKey) or self:IsMockKey(state and state.targetKey) then
            self.outgoingSessions[sessionId] = nil
        end
    end

    local keptOutbound = {}
    for index = 1, #(self.outboundChunkQueue or {}) do
        local item = self.outboundChunkQueue[index]
        if not self:IsMockKey(item and item.peer) and not self:IsMockKey(item and item.block and item.block.key) then
            keptOutbound[#keptOutbound + 1] = item
        end
    end
    self.outboundChunkQueue = keptOutbound

    local keptManifest = {}
    for index = 1, #(self.manifestChunkQueue or {}) do
        local item = self.manifestChunkQueue[index]
        if not self:IsMockKey(item and item.peer) and not self:IsMockKey(item and item.payload and item.payload.memberKey) then
            keptManifest[#keptManifest + 1] = item
        end
    end
    self.manifestChunkQueue = keptManifest

    local keptInbound = {}
    for index = 1, #(self.inboundChunkQueue or {}) do
        local item = self.inboundChunkQueue[index]
        if not self:IsMockKey(item and item.key) and not self:IsMockKey(item and item.sender) then
            keptInbound[#keptInbound + 1] = item
        end
    end
    self.inboundChunkQueue = keptInbound

    local keptFinalize = {}
    for index = 1, #(self.inboundFinalizeQueue or {}) do
        local item = self.inboundFinalizeQueue[index]
        if not self:IsMockKey(item and item.memberKey) and not self:IsMockKey(item and item.sender) then
            keptFinalize[#keptFinalize + 1] = item
        end
    end
    self.inboundFinalizeQueue = keptFinalize

    if self.inFlight and (self:IsMockKey(self.inFlight.memberKey) or self:IsMockKey(self.inFlight.source)) then
        self.inFlight = nil
    end

    self:RecomputeCoordinator()
    Addon:RequestRefresh("mock-cleanup")
    return removedRegistry, removedOnlineNodes, removedPendingRequests
end

function Sync:CleanCorruptState(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local stats = {
        removed = 0,
        registry = 0,
        onlineNodes = 0,
        pendingRequests = 0,
        partialReceives = 0,
        outgoingSessions = 0,
        queues = 0,
        inFlight = 0,
    }

    local function drop(tbl, key, field)
        stats.removed = stats.removed + 1
        stats[field] = (stats[field] or 0) + 1
        if not dryRun then
            tbl[key] = nil
        end
    end

    for key, row in pairs(self.registry or {}) do
        if not self:IsValidSyncMemberKey(key) or (row and row.owner and not self:IsValidSyncMemberKey(row.owner)) then
            drop(self.registry, key, "registry")
        end
    end

    for key in pairs(self.onlineNodes or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.onlineNodes, key, "onlineNodes")
        end
    end

    for memberKey, info in pairs(self.pendingRequests or {}) do
        if not self:IsRequestShapeValid(info) then
            drop(self.pendingRequests, memberKey, "pendingRequests")
        end
    end

    for memberKey, info in pairs(self.partialReceive or {}) do
        if not self:IsValidSyncMemberKey(memberKey)
            or (info and info.source and not self:IsValidSyncMemberKey(info.source)) then
            drop(self.partialReceive, memberKey, "partialReceives")
        end
    end

    for peerKey, manifests in pairs(self.partialManifestReceive or {}) do
        if not self:IsValidSyncMemberKey(peerKey) then
            drop(self.partialManifestReceive, peerKey, "partialReceives")
        elseif type(manifests) == "table" then
            for manifestId, state in pairs(manifests) do
                if state and state.memberKey and not self:IsValidSyncMemberKey(state.memberKey) then
                    stats.removed = stats.removed + 1
                    stats.partialReceives = stats.partialReceives + 1
                    if not dryRun then
                        manifests[manifestId] = nil
                    end
                end
            end
            if not dryRun and next(manifests) == nil then
                self.partialManifestReceive[peerKey] = nil
            end
        end
    end

    for key in pairs(self._lastManifestSentAt or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self._lastManifestSentAt, key, "queues")
        end
    end
    for key in pairs(self.pendingManifestPeers or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.pendingManifestPeers, key, "queues")
        end
    end
    for key in pairs(self.peerPacing or {}) do
        if not self:IsValidSyncMemberKey(key) then
            drop(self.peerPacing, key, "queues")
        end
    end

    for sessionId, state in pairs(self.outgoingSessions or {}) do
        if not self:IsValidSyncMemberKey(state and state.memberKey)
            or not self:IsValidSyncMemberKey(state and state.targetKey) then
            drop(self.outgoingSessions, sessionId, "outgoingSessions")
        end
    end

    local function keepQueue(src, validFn)
        local kept = {}
        for index = 1, #(src or {}) do
            local item = src[index]
            if validFn(item) then
                kept[#kept + 1] = item
            else
                stats.removed = stats.removed + 1
                stats.queues = stats.queues + 1
            end
        end
        return kept
    end

    if not dryRun then
        self.outboundChunkQueue = keepQueue(self.outboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.block and item.block.key)
        end)
        self.manifestChunkQueue = keepQueue(self.manifestChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.payload and item.payload.memberKey)
        end)
        self.inboundChunkQueue = keepQueue(self.inboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.key)
                and self:IsValidSyncMemberKey(item and item.sender)
        end)
        self.inboundFinalizeQueue = keepQueue(self.inboundFinalizeQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.memberKey)
                and (not item.sender or self:IsValidSyncMemberKey(item.sender))
        end)
    else
        keepQueue(self.outboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.block and item.block.key)
        end)
        keepQueue(self.manifestChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.peer)
                and self:IsValidSyncMemberKey(item and item.payload and item.payload.memberKey)
        end)
        keepQueue(self.inboundChunkQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.key)
                and self:IsValidSyncMemberKey(item and item.sender)
        end)
        keepQueue(self.inboundFinalizeQueue, function(item)
            return self:IsValidSyncMemberKey(item and item.memberKey)
                and (not item.sender or self:IsValidSyncMemberKey(item.sender))
        end)
    end

    if self.inFlight and not self:IsRequestShapeValid(self.inFlight) then
        stats.removed = stats.removed + 1
        stats.inFlight = 1
        if not dryRun then
            self.inFlight = nil
        end
    end

    if stats.removed > 0 and not dryRun then
        self:RecomputeCoordinator()
        Addon:RequestRefresh("clean-sync")
    end
    return stats
end

function Sync:DumpStatus()
    local role = self:IsCoordinator() and "Coordinator" or "Client"
    Addon:Print(string.format(
        "Role=%s coordinator=%s onlineNodes=%d registry=%d queued=%d inFlight=%s outgoing=%d outboundChunks=%d manifestChunks=%d inboundChunks=%d manifestPending=%d paused=%s isolated=%s",
        role,
        tostring(self.coordinatorKey),
        countKeys(self.onlineNodes),
        countKeys(self.registry),
        countKeys(self.pendingRequests),
        self.inFlight and self.inFlight.memberKey or "none",
        countKeys(self.outgoingSessions),
        #self.outboundChunkQueue,
        #(self.manifestChunkQueue or {}),
        #self.inboundChunkQueue,
        countKeys(self.pendingManifestPeers),
        tostring(Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false),
        tostring(self:IsRealTrafficSuppressed())
    ))
end
