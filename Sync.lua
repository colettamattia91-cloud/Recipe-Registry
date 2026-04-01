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
local OUTGOING_CHUNK_DELAY = 0.08
local MAX_RESUME_ATTEMPTS = 3
local COORDINATOR_RECOMPUTE_DELAY = 0.35

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
end

function Sync:GetSelfKey()
    return Addon.Data:GetPlayerKey()
end

function Sync:GetWhisperTarget(memberKey)
    if not memberKey then return nil end
    local name = memberKey:match("^([^%-]+)")
    return name or memberKey
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
        if Addon.Data:IsMemberOnline(key) or key == self:GetSelfKey() then
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

function Sync:RecordRevisionHint(memberKey, rev, updatedAt, owner)
    if not memberKey then return end
    local row = self.registry[memberKey] or { owner = owner or memberKey, rev = 0, updatedAt = 0 }
    if owner then row.owner = owner end
    if (rev or 0) >= (row.rev or 0) then
        row.rev = rev or row.rev or 0
        row.updatedAt = updatedAt or row.updatedAt or 0
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

    self:RecordRevisionHint(payload.key, payload.rev, payload.updatedAt, payload.owner or payload.key)

    local localEntry = Addon.Data:GetMember(payload.key)
    local localRev = localEntry and localEntry.rev or 0
    local remoteRev = payload.rev or 0
    if remoteRev > localRev then
        self:QueueRequest(payload.owner or payload.key, payload.key, remoteRev, "index")
    end
end

function Sync:QueueRequest(sourceKey, memberKey, targetRev, why)
    if not sourceKey or not memberKey then return end

    local knownOwner = self:GetKnownOwner(memberKey)
    if sourceKey ~= knownOwner and knownOwner then
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
    }

    local localEntry = Addon.Data:GetMember(oldest.memberKey)
    local knownRev = localEntry and localEntry.rev or 0
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

    local entry = Addon.Data:GetMember(payload.key)
    if not entry then return end
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
            self:SendDirectEnvelope("SNAP", {
                sessionId = sessionId,
                key = state.memberKey,
                rev = chunk.rev,
                updatedAt = chunk.updatedAt,
                profession = chunk.profession,
                skillRank = chunk.skillRank,
                skillMaxRank = chunk.skillMaxRank,
                recipeKeys = chunk.recipeKeys,
                seq = seq,
                total = state.total,
            }, state.targetKey, "BULK")
            state.lastSentAt = time()
        end
    end
end

function Sync:HandleSnapshotChunk(payload)
    if payload.key == self:GetSelfKey() and payload.sender == self:GetSelfKey() then return end

    Addon.Data:AppendIncomingChunk({
        memberKey = payload.key,
        rev = payload.rev,
        updatedAt = payload.updatedAt,
        profession = payload.profession,
        skillRank = payload.skillRank,
        skillMaxRank = payload.skillMaxRank,
        recipeKeys = payload.recipeKeys,
    })

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

    local complete = true
    for i = 1, payload.total do
        if not state.seen[i] then
            complete = false
            break
        end
    end

    if complete then
        self.partialReceive[payload.key] = nil
        local merged = Addon.Data:FinalizeIncomingSnapshot(payload.key, payload.rev)
        self:SendDirectEnvelope("DONE", {
            sessionId = payload.sessionId,
            key = payload.key,
            rev = payload.rev,
        }, payload.sender, "ALERT")

        if self.inFlight and self.inFlight.memberKey == payload.key then
            self.inFlight = nil
        end

        if merged and self:IsCoordinator() then
            self:BroadcastIndex(payload.key, payload.rev, payload.updatedAt, payload.key, "snapshot-merged")
        end
        Addon:RequestRefresh("snapshot-complete")
    end
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
    if session.targetKey ~= payload.sender then return end
    if session.memberKey ~= payload.key or session.rev ~= payload.rev then return end

    local missing = shallowCopyArray(payload.missing or {})
    if #missing == 0 then return end
    self:SendOutgoingSession(payload.sessionId, missing)
end

function Sync:HandleTransferDone(payload)
    local session = self.outgoingSessions[payload.sessionId]
    if not session then return end
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

    if countKeys(self.onlineNodes) == 0 then
        if (time() - (self.lastHelloAt or 0)) > 10 then
            self:BroadcastHello()
        end
        return
    end

    if not self.inFlight then
        for key, hint in pairs(self.registry) do
            local localEntry = Addon.Data:GetMember(key)
            local localRev = localEntry and localEntry.rev or 0
            if (hint.rev or 0) > localRev then
                self:QueueRequest(hint.owner or key, key, hint.rev or 0, "auto-tick")
            end
        end
    end

    if (time() - (self.lastHelloAt or 0)) > HELLO_INTERVAL then
        self:BroadcastHello()
    end
end

function Sync:RequestGuildCatchup(memberKey, silent)
    if memberKey and memberKey ~= "" then
        local remoteRev = self:GetKnownRevision(memberKey)
        if remoteRev == 0 then
            local localEntry = Addon.Data:GetMember(memberKey)
            remoteRev = (localEntry and localEntry.rev or 0) + 1
        end
        self:QueueRequest(self:GetKnownOwner(memberKey), memberKey, remoteRev, "manual")
        return
    end

    for key, hint in pairs(self.registry) do
        local localEntry = Addon.Data:GetMember(key)
        local localRev = localEntry and localEntry.rev or 0
        if (hint.rev or 0) > localRev then
            self:QueueRequest(hint.owner or key, key, hint.rev or 0, "manual-all")
        end
    end
    if not silent then
        Addon:Print("Queued direct catch-up requests from data owners.")
    end
end

function Sync:GetUiState()
    return {
        role = self:IsCoordinator() and "Coordinator" or "Client",
        coordinatorKey = self.coordinatorKey,
        onlineNodes = countKeys(self.onlineNodes),
        registry = countKeys(self.registry),
        queued = countKeys(self.pendingRequests),
        inFlight = self.inFlight and self.inFlight.memberKey or nil,
        outgoing = countKeys(self.outgoingSessions),
        autoSync = true,
    }
end

function Sync:DumpStatus()
    local role = self:IsCoordinator() and "Coordinator" or "Client"
    Addon:Print(string.format(
        "Role=%s coordinator=%s onlineNodes=%d registry=%d queued=%d inFlight=%s outgoing=%d",
        role,
        tostring(self.coordinatorKey),
        countKeys(self.onlineNodes),
        countKeys(self.registry),
        countKeys(self.pendingRequests),
        self.inFlight and self.inFlight.memberKey or "none",
        countKeys(self.outgoingSessions)
    ))
end
