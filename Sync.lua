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

local REQUEST_TIMEOUT = 12
local PROGRESS_TIMEOUT = 4
local SESSION_TIMEOUT = 35
local NODE_TIMEOUT = 95
local HELLO_INTERVAL = 30
local AUTO_SYNC_INTERVAL = 20
local OUTGOING_CHUNK_DELAY = 0.20
local MAX_RESUME_ATTEMPTS = 3
local COORDINATOR_RECOMPUTE_DELAY = 0.35
local MANIFEST_PUSH_COOLDOWN = 20

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
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
    self.inboundChunkQueue = {}
    self.inboundFinalizeQueue = {}
    self.peerPacing = {}
    self.partialManifestReceive = {}
    self._lastManifestSentAt = {}
    self.telemetry = {
        sentChunks = 0,
        receivedChunks = 0,
        appliedChunks = 0,
        skippedEquivalentMerges = 0,
        pausedSyncCycles = 0,
        busySeedRejections = 0,
    }
end

function Sync:ResetTelemetry()
    self.telemetry = {
        sentChunks = 0,
        receivedChunks = 0,
        appliedChunks = 0,
        skippedEquivalentMerges = 0,
        pausedSyncCycles = 0,
        busySeedRejections = 0,
    }
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
end

function Sync:GetSelfKey()
    return Addon.Data:GetPlayerKey()
end

function Sync:GetWhisperTarget(memberKey)
    if not memberKey then return nil end
    local name = memberKey:match("^([^%-]+)")
    return name or memberKey
end

function Sync:IsMockKey(memberKey)
    if isMockKey(memberKey) then return true end
    local row = memberKey and self.registry and self.registry[memberKey] or nil
    return row and row.isMock == true or false
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
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    payload.sentAt = time()
    local msg = LibStub("AceSerializer-3.0"):Serialize(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "GUILD", nil, priority or "NORMAL")
    end
end

function Sync:SendDirectEnvelope(kind, payload, targetKey, priority)
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
    end
end

function Sync:TouchNode(key, version)
    if not key then return end
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
        if not self:IsMockKey(key) and (Addon.Data:IsMemberOnline(key) or key == self:GetSelfKey()) then
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
    if not memberKey then return end
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
    if row and row.owner then return row.owner end
    return memberKey
end

function Sync:GetKnownRevision(memberKey)
    local row = self.registry[memberKey]
    return row and (row.rev or 0) or 0
end

function Sync:HandleHello(payload)
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
    self:TouchNode(payload.sender)
    if self:IsCoordinator() then return end
    if self.coordinatorKey and payload.sender ~= self.coordinatorKey then return end
    if self:IsMockKey(payload.key) or self:IsMockKey(payload.sender) then return end

    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.owner or payload.key)

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0
    if remoteRev > localRev then
        self:QueueRequest(payload.owner or payload.key, payload.key, remoteRev, "index")
    end
end

function Sync:QueueRequest(sourceKey, memberKey, targetRev, why, opts)
    if not sourceKey or not memberKey then return end
    local allowLocalMock = self:ShouldAllowLocalMockTraffic(sourceKey, memberKey)
    if (self:IsMockKey(sourceKey) or self:IsMockKey(memberKey)) and not allowLocalMock then return end
    opts = opts or {}

    local knownOwner = self:GetKnownOwner(memberKey)
    if not opts.allowReplicaSource and sourceKey ~= knownOwner and knownOwner then
        sourceKey = knownOwner
    end

    local q = self.pendingRequests[memberKey]
    if q and (q.rev or 0) >= (targetRev or 0) then return end

    self.pendingRequests[memberKey] = {
        source = sourceKey,
        memberKey = memberKey,
        rev = targetRev or 0,
        why = why,
        queuedAt = time(),
        attempts = q and q.attempts or 0,
        resumeAttempts = 0,
        allowReplicaSource = opts.allowReplicaSource == true,
    }
    Addon:Debug("Queued direct request", memberKey, "from", sourceKey, "rev", targetRev or 0, why or "")
    Addon:RequestRefresh("queue")
end

function Sync:ProcessRequestQueue()
    if self.inFlight then
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
        if not oldest or info.queuedAt < oldest.queuedAt then
            oldest = info
            oldestKey = memberKey
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
    }, oldest.source, "ALERT")
end

function Sync:IsRequestStillViable(request)
    if not request or not request.source then return false end
    if request.source == self:GetSelfKey() then return true end
    return self.onlineNodes[request.source] ~= nil
end

function Sync:FailInFlight(requeue)
    if self.inFlight and requeue then
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
    if not targetKey then return end
    if self:IsMockKey(targetKey) or self:IsMockKey(payload.key) then return end

    local entry = Addon.Data:GetMember(payload.key)
    if not entry then return end
    if (entry.guildStatus or "active") ~= "active" then return end
    if (entry.rev or 0) <= (payload.knownRev or 0) then return end

    local sessionId = self:BuildSessionId(payload.key, entry.rev or 0)
    local chunks = Addon.Data:BuildSnapshotChunks(payload.key)
    if #chunks == 0 then return end

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
                recipeKeys = chunk.recipeKeys,
                seq = seq,
                total = state.total,
            })
        end
    end
end

function Sync:HandleSnapshotChunk(payload)
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
    if self:IsMockKey(peerKey) then return end
    local lastSentAt = self._lastManifestSentAt[peerKey] or 0
    if why ~= "force" and (time() - lastSentAt) < MANIFEST_PUSH_COOLDOWN then
        return
    end

    local chunks = Addon.TrickleSync:BuildManifestChunks()
    for index = 1, #chunks do
        local payload = shallowCopyTable(chunks[index])
        payload.why = why
        self:SendDirectEnvelope("MANI", payload, peerKey, "NORMAL")
    end
    self._lastManifestSentAt[peerKey] = time()
end

function Sync:BroadcastManifestToOnlinePeers(why)
    for peerKey in pairs(self.onlineNodes or {}) do
        if peerKey ~= self:GetSelfKey() and not self:IsMockKey(peerKey) then
            self:SendManifestToPeer(peerKey, why or "broadcast")
        end
    end
end

function Sync:HandleManifestChunk(payload)
    if not payload.sender or payload.sender == self:GetSelfKey() then return end
    if self:IsMockKey(payload.sender) and not self:ShouldAllowLocalMockTraffic(payload.sender, nil) then return end

    local senderKey = payload.sender
    self.partialManifestReceive[senderKey] = self.partialManifestReceive[senderKey] or {}
    local state = self.partialManifestReceive[senderKey][payload.manifestId]
    if not state then
        state = {
            manifestId = payload.manifestId,
            builtAt = payload.builtAt or time(),
            memberKey = payload.memberKey or senderKey,
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
        state.blocks[block.blockKey] = block
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
    for ownerCharacter, request in pairs(groupedRequests or {}) do
        self:QueueRequest(senderKey, ownerCharacter, request.revision or 0, "manifest", {
            allowReplicaSource = true,
        })
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

function Sync:CanSendToPeer(peer)
    if not peer then return false end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseOutbound() then
        return false
    end
    local pacing = self.peerPacing[peer]
    if pacing and (time() - (pacing.lastSentAt or 0)) < OUTGOING_CHUNK_DELAY then
        return false
    end
    return true
end

function Sync:SendNextLowPriorityChunk()
    if #self.outboundChunkQueue == 0 then
        return true
    end

    local candidateIndex
    for index = 1, #self.outboundChunkQueue do
        if self:CanSendToPeer(self.outboundChunkQueue[index].peer) then
            candidateIndex = index
            break
        end
    end
    if not candidateIndex then
        return true
    end

    local queued = table.remove(self.outboundChunkQueue, candidateIndex)
    local block = queued.block
    self:SendDirectEnvelope("SNAP", block, queued.peer, "BULK")
    self.peerPacing[queued.peer] = self.peerPacing[queued.peer] or {}
    self.peerPacing[queued.peer].lastSentAt = time()
    self.telemetry.sentChunks = self.telemetry.sentChunks + 1

    local session = self.outgoingSessions[block.sessionId]
    if session then
        session.lastSentAt = time()
    end
    return true
end

function Sync:EnqueueReceivedChunk(payload)
    self.inboundChunkQueue[#self.inboundChunkQueue + 1] = shallowCopyTable(payload)
    self.telemetry.receivedChunks = self.telemetry.receivedChunks + 1
end

function Sync:DecodeChunkStep(payload)
    if not payload then return false end
    Addon.Data:AppendIncomingChunk({
        memberKey = payload.key,
        rev = payload.rev,
        updatedAt = payload.updatedAt,
        sourceType = payload.sourceType or "replica",
        profession = payload.profession,
        skillRank = payload.skillRank,
        skillMaxRank = payload.skillMaxRank,
        recipeKeys = payload.recipeKeys,
    })
    return true
end

function Sync:MergeChunkStep(item)
    if not item then return false end
    local merged = Addon.Data:FinalizeIncomingSnapshot(item.memberKey, item.rev, {
        sourceType = "replica",
        isMock = self:IsMockKey(item.memberKey) or self:IsMockKey(item.sender),
    })
    if merged then
        self.telemetry.appliedChunks = self.telemetry.appliedChunks + 1
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
    if not silent then
        Addon:Print("Queued direct catch-up requests from data owners.")
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
        inboundChunks = #self.inboundChunkQueue,
        inboundFinalize = #self.inboundFinalizeQueue,
        inFlight = self.inFlight and self.inFlight.memberKey or nil,
        paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false,
        telemetry = self.telemetry,
    }
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

function Sync:DumpStatus()
    local role = self:IsCoordinator() and "Coordinator" or "Client"
    Addon:Print(string.format(
        "Role=%s coordinator=%s onlineNodes=%d registry=%d queued=%d inFlight=%s outgoing=%d outboundChunks=%d inboundChunks=%d paused=%s",
        role,
        tostring(self.coordinatorKey),
        countKeys(self.onlineNodes),
        countKeys(self.registry),
        countKeys(self.pendingRequests),
        self.inFlight and self.inFlight.memberKey or "none",
        countKeys(self.outgoingSessions),
        #self.outboundChunkQueue,
        #self.inboundChunkQueue,
        tostring(Addon.SyncPausePolicy and Addon.SyncPausePolicy:IsSensitiveSyncContext() or false)
    ))
end
