local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local pairs = pairs
local ipairs = ipairs
local random = math.random
local max = math.max

local addRetrySuffix = Private.addRetrySuffix
local cloneFingerprintMap = Private.cloneFingerprintMap
local cloneStringSet = Private.cloneStringSet
local isHelloAutoReason = Private.isHelloAutoReason
local isManualReason = Private.isManualReason
local mergeExpectedFingerprints = Private.mergeExpectedFingerprints
local mergeRequestedBlocks = Private.mergeRequestedBlocks

local REQUEST_TIMEOUT = Constants.REQUEST_TIMEOUT
local PROGRESS_TIMEOUT = Constants.PROGRESS_TIMEOUT
local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
local MAX_RESUME_ATTEMPTS = Constants.MAX_RESUME_ATTEMPTS
local MAX_REQUEST_RETRIES = Constants.MAX_REQUEST_RETRIES
local MAX_HELLO_AUTO_RETRIES = Constants.MAX_HELLO_AUTO_RETRIES
local MAX_CONCURRENT_REQUESTS = Constants.MAX_CONCURRENT_REQUESTS

local function requestBlocksCovered(existing, expected)
    if type(expected) ~= "table" or #expected == 0 then
        return true
    end
    local seen = {}
    for _, blockKey in ipairs(existing or {}) do
        if blockKey then
            seen[blockKey] = true
        end
    end
    for _, blockKey in ipairs(expected) do
        if blockKey and not seen[blockKey] then
            return false
        end
    end
    return true
end

local function expectedFingerprintsCovered(existing, expected)
    for blockKey, fingerprint in pairs(expected or {}) do
        if (existing and existing[blockKey] or nil) ~= fingerprint then
            return false
        end
    end
    return true
end

function Sync:IsRequestShapeValid(request)
    return request
        and self:IsValidSyncMemberKey(request.memberKey)
        and self:IsValidSyncMemberKey(request.source)
end

function Sync:IsRequestAlreadySatisfied(request)
    if not request or not self:IsValidSyncMemberKey(request.memberKey) then return false end
    local entry = Addon.Data:GetMember(request.memberKey)
    if not entry then return false end

    local targetRev = request.rev or 0
    if (entry.rev or 0) < targetRev then
        return false
    end

    local requestedBlocks = request.requestedBlocks or {}
    local expectedFingerprints = request.expectedFingerprints or {}
    if type(requestedBlocks) ~= "table" or #requestedBlocks == 0 then
        return true
    end

    for _, blockKey in ipairs(requestedBlocks) do
        local ownerCharacter, professionKey = Addon.Data:ParseSyncBlockKey(blockKey)
        if ownerCharacter ~= request.memberKey or not professionKey then
            return false
        end
        local prof = entry.professions and entry.professions[professionKey]
        if not prof or (prof.guildStatus or entry.guildStatus or "active") ~= "active" then
            return false
        end
        local expectedFingerprint = expectedFingerprints[blockKey]
        if expectedFingerprint ~= nil then
            local localBlock = Addon.Data:GetSyncBlock(request.memberKey, professionKey)
            local localFingerprint = localBlock and localBlock.fingerprint or nil
            if localFingerprint ~= expectedFingerprint then
                return false
            end
        end
    end
    return true
end

function Sync:GetRequestMaxAttempts(request)
    if isHelloAutoReason(request and request.why) then
        return MAX_HELLO_AUTO_RETRIES
    end
    return MAX_REQUEST_RETRIES
end

function Sync:DoesRequestCover(request, targetRev, requestedBlocks, expectedFingerprints)
    if not request then return false end
    if (request.rev or 0) < (targetRev or 0) then return false end
    return requestBlocksCovered(request.requestedBlocks, requestedBlocks)
        and expectedFingerprintsCovered(request.expectedFingerprints, expectedFingerprints)
end

function Sync:GetRequestPriorityBucket(request)
    local why = tostring(request and request.why or "")
    if why == "manual" or why == "manual-all" then return 0 end
    if why == "manifest" then return 1 end
    if why == "index" then return 2 end
    if why == "advertise-auto" or why == "auto-tick" then return 3 end
    if isHelloAutoReason(why) then return 4 end
    return 2
end

function Sync:IsBetterPendingRequest(candidate, best)
    if not best then return true end
    local candidatePriority = self:GetRequestPriorityBucket(candidate)
    local bestPriority = self:GetRequestPriorityBucket(best)
    if candidatePriority ~= bestPriority then
        return candidatePriority < bestPriority
    end

    local candidateScore = self:GetPeerHealthScore(candidate.source)
    local bestScore = self:GetPeerHealthScore(best.source)
    if candidateScore ~= bestScore then
        return candidateScore > bestScore
    end

    if (candidate.rev or 0) ~= (best.rev or 0) then
        return (candidate.rev or 0) > (best.rev or 0)
    end

    return (candidate.queuedAt or 0) < (best.queuedAt or 0)
end

function Sync:ShouldAllowLocalMockTraffic(sourceKey, memberKey)
    if not (Addon.MockSync and Addon.MockSync.IsLocalTrafficEnabled) then
        return false
    end
    return Addon.MockSync:IsLocalTrafficEnabled(sourceKey, memberKey)
end

function Sync:ShouldDeferRequestDispatch(request)
    if isManualReason(request and request.why) then
        return false
    end
    if self:IsInWarmup() then
        return true
    end
    if self.IsInWorldTransition and self:IsInWorldTransition() then
        return true
    end
    return false
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

    if self:IsRequestAlreadySatisfied({
        memberKey = memberKey,
        rev = targetRev or 0,
        requestedBlocks = opts.requestedBlocks,
        expectedFingerprints = opts.expectedFingerprints,
    }) then
        Addon:Debug("Skipped satisfied sync request", memberKey, "from", sourceKey, "rev", targetRev or 0, why or "")
        return
    end

    local active = self:GetInFlightRequest(memberKey)
    if self:DoesRequestCover(active, targetRev or 0, opts.requestedBlocks, opts.expectedFingerprints) then
        Addon:Debug("Skipped covered sync request", memberKey, "from", sourceKey, "rev", targetRev or 0, why or "")
        return
    end

    local q = self.pendingRequests[memberKey]
    if q and (q.rev or 0) >= (targetRev or 0) then
        if opts.requestedBlocks and #opts.requestedBlocks > 0 then
            q.requestedBlocks = mergeRequestedBlocks(q.requestedBlocks, opts.requestedBlocks)
            q.expectedFingerprints = mergeExpectedFingerprints(q.expectedFingerprints, opts.expectedFingerprints)
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
        expectedFingerprints = cloneFingerprintMap(opts.expectedFingerprints),
    }
    if self.EnforceRuntimeQueueCaps then
        self:EnforceRuntimeQueueCaps("queue-request")
    end
    Addon:Debug("Queued direct request", memberKey, "from", sourceKey, "rev", targetRev or 0, why or "")
    Addon:RequestRefresh("queue")
end

function Sync:SelectNextPendingRequest(skipMembers)
    local bestKey, best
    local sawWarmupDeferred = false

    for memberKey, info in pairs(self.pendingRequests) do
        if skipMembers and skipMembers[memberKey] then
            -- Keep same-pass retries queued so another owner can use the freed slot first.
        elseif not self:IsRequestShapeValid(info) then
            self.pendingRequests[memberKey] = nil
        elseif self:GetInFlightRequest(memberKey) then
            if self:DoesRequestCover(self:GetInFlightRequest(memberKey), info.rev or 0, info.requestedBlocks, info.expectedFingerprints) then
                self.pendingRequests[memberKey] = nil
            end
        elseif self:IsRequestAlreadySatisfied(info) then
            self.pendingRequests[memberKey] = nil
        else
            local allowLocalMock = self:ShouldAllowLocalMockTraffic(info and info.source, memberKey)
            if not self:IsRealTrafficSuppressed() or allowLocalMock then
                if self:IsPeerBackoffActive(info.source) and not isManualReason(info.why) then
                    self.telemetry.peerBackoffSkips = (self.telemetry.peerBackoffSkips or 0) + 1
                elseif self:ShouldDeferRequestDispatch(info) then
                    sawWarmupDeferred = true
                elseif not best or self:IsBetterPendingRequest(info, best) then
                    best = info
                    bestKey = memberKey
                end
            end
        end
    end

    return bestKey, best, sawWarmupDeferred
end

function Sync:DispatchPendingRequest(memberKey, request)
    if not (memberKey and request) then return false end

    self.pendingRequests[memberKey] = nil
    self._requestDispatchCounter = (self._requestDispatchCounter or 0) + 1
    local active = {
        memberKey = request.memberKey,
        source = request.source,
        rev = request.rev,
        why = request.why,
        dispatchOrder = self._requestDispatchCounter,
        startedAt = time(),
        lastProgressAt = time(),
        attempts = (request.attempts or 0) + 1,
        resumeAttempts = 0,
        allowReplicaSource = request.allowReplicaSource == true,
        requestedBlocks = cloneStringSet(request.requestedBlocks),
        expectedFingerprints = cloneFingerprintMap(request.expectedFingerprints),
    }
    self:SetInFlightRequest(active)
    self.telemetry.requestDispatches = (self.telemetry.requestDispatches or 0) + 1
    if self:GetActiveRequestCount() > (self.telemetry.requestConcurrencyMax or 0) then
        self.telemetry.requestConcurrencyMax = self:GetActiveRequestCount()
    end

    local localEntry = Addon.Data:GetMember(request.memberKey)
    local knownRev = localEntry and localEntry.rev or 0
    if self:ShouldAllowLocalMockTraffic(request.source, request.memberKey) then
        if not (Addon.MockSync and Addon.MockSync.HandleLocalRequest) then
            self:FailInFlight(request.memberKey, false, "mock-unavailable")
            return false
        end
        local accepted = Addon.MockSync:HandleLocalRequest({
            source = request.source,
            memberKey = request.memberKey,
            knownRev = knownRev,
            wantRev = request.rev or 0,
            allowReplicaSource = request.allowReplicaSource == true,
            requestedBlocks = cloneStringSet(request.requestedBlocks),
        })
        if not accepted then
            self:FailInFlight(request.memberKey, false, "mock-rejected")
            return false
        end
        return true
    end

    self:SendDirectEnvelope("REQ", {
        key = request.memberKey,
        knownRev = knownRev,
        wantRev = request.rev or 0,
        requestedBlocks = cloneStringSet(request.requestedBlocks),
    }, request.source, "ALERT")
    return true
end

function Sync:ProcessRequestQueue()
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() then
        return
    end
    local now = time()
    local skipPendingMembers = {}
    local activeKeys = {}
    for memberKey in pairs(self:GetInFlightRequests()) do
        activeKeys[#activeKeys + 1] = memberKey
    end

    for _, memberKey in ipairs(activeKeys) do
        local request = self:GetInFlightRequest(memberKey)
        if request then
            if not self:IsRequestShapeValid(request) then
                Addon:Debug("Dropping malformed in-flight request", tostring(request.memberKey), "from", tostring(request.source))
                self:FailInFlight(memberKey, false, "malformed")
                skipPendingMembers[memberKey] = true
            elseif self:IsRequestAlreadySatisfied(request) then
                Addon:Debug("Dropping satisfied in-flight request", request.memberKey)
                self.partialReceive[request.memberKey] = nil
                self:ClearInFlightRequest(request.memberKey)
                skipPendingMembers[memberKey] = true
                Addon:RequestRefresh("queue")
                self:ScheduleQueuePump()
            elseif not self:IsRequestStillViable(request) then
                Addon:Debug("Dropping in-flight request; source unavailable", request.memberKey)
                self:FailInFlight(memberKey, true, "source-unavailable")
                skipPendingMembers[memberKey] = true
            elseif (now - (request.startedAt or now)) > SESSION_TIMEOUT then
                Addon:Debug("Request session timeout", request.memberKey)
                self:FailInFlight(memberKey, true, "session-timeout")
                skipPendingMembers[memberKey] = true
            elseif not request.sessionId then
                if (now - (request.startedAt or now)) > REQUEST_TIMEOUT then
                    Addon:Debug("Initial request timeout", request.memberKey)
                    self:FailInFlight(memberKey, true, "initial-timeout")
                    skipPendingMembers[memberKey] = true
                end
            elseif (now - (request.lastProgressAt or now)) > PROGRESS_TIMEOUT then
                if (request.resumeAttempts or 0) < MAX_RESUME_ATTEMPTS then
                    request.resumeAttempts = (request.resumeAttempts or 0) + 1
                    request.lastProgressAt = now
                    self:SendResumeForInFlight(memberKey)
                else
                    Addon:Debug("Resume exhausted", request.memberKey)
                    self:FailInFlight(memberKey, true, "resume-exhausted")
                end
            end
        end
    end

    while self:GetActiveRequestCount() < MAX_CONCURRENT_REQUESTS do
        local nextKey, nextRequest, sawWarmupDeferred = self:SelectNextPendingRequest(skipPendingMembers)
        if not nextRequest then
            if sawWarmupDeferred then
                self.telemetry.warmupDeferrals = (self.telemetry.warmupDeferrals or 0) + 1
            end
            return
        end

        if self:IsRequestAlreadySatisfied(nextRequest) then
            self.pendingRequests[nextKey] = nil
        elseif not self:IsRequestStillViable(nextRequest) then
            self.pendingRequests[nextKey] = nil
        else
            self:DispatchPendingRequest(nextKey, nextRequest)
        end
    end
end

function Sync:IsRequestStillViable(request)
    if not self:IsRequestShapeValid(request) then return false end
    if request.source == self:GetSelfKey() then return true end
    local rosterFresh = self:IsRosterFresh()
    if not rosterFresh then
        self:EnsureFreshRoster("request-viability")
    end
    if rosterFresh and Addon.Data and Addon.Data.GetGuildMemberMeta then
        local meta = Addon.Data:GetGuildMemberMeta(request.source)
        if meta and meta.online == false then
            return false
        end
    end
    return self.onlineNodes[request.source] ~= nil
end

function Sync:FailInFlight(memberKey, requeue, reason)
    if type(memberKey) == "boolean" or memberKey == nil then
        reason = requeue
        requeue = memberKey
        memberKey = self.inFlight and self.inFlight.memberKey or nil
    end

    local req = memberKey and self:GetInFlightRequest(memberKey) or self:GetInFlightRequest()
    if req and requeue and self:IsRequestShapeValid(req) and not self:IsRequestAlreadySatisfied(req) then
        local attempts = req.attempts or 1
        local maxAttempts = self:GetRequestMaxAttempts(req)
        self:MarkPeerFailure(req.source, reason or "retry", req)
        if attempts >= maxAttempts then
            self.telemetry.requestDrops = (self.telemetry.requestDrops or 0) + 1
            Addon:Debug(
                "Dropping failed request after retries",
                tostring(req.memberKey),
                "from",
                tostring(req.source),
                tostring(req.why or ""),
                "attempts",
                tostring(attempts)
            )
        else
            self.pendingRequests[req.memberKey] = {
                source = req.source,
                memberKey = req.memberKey,
                rev = req.rev,
                why = addRetrySuffix(req.why),
                queuedAt = time() + random(),
                attempts = attempts,
                resumeAttempts = req.resumeAttempts or 0,
                allowReplicaSource = req.allowReplicaSource == true,
                requestedBlocks = cloneStringSet(req.requestedBlocks),
                expectedFingerprints = cloneFingerprintMap(req.expectedFingerprints),
            }
            if self.EnforceRuntimeQueueCaps then
                self:EnforceRuntimeQueueCaps("retry-request")
            end
            self.telemetry.requestRetries = (self.telemetry.requestRetries or 0) + 1
        end
        if self:IsValidSyncMemberKey(req.source) and not self:IsMockKey(req.source) and not self:IsInWarmup() then
            self:RequestManifestRefresh(req.source, {
                force = true,
                reason = "request-repair",
            })
        end
    end
    if req and req.memberKey then
        self.partialReceive[req.memberKey] = nil
    end
    self:ClearInFlightRequest(req and req.memberKey or memberKey)
    Addon:RequestRefresh("queue")
    self:ScheduleQueuePump()
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

function Sync:GetOldestPendingRequest()
    local oldest
    for _, request in pairs(self.pendingRequests or {}) do
        if self:IsRequestShapeValid(request) and (not oldest or (request.queuedAt or 0) < (oldest.queuedAt or 0)) then
            oldest = request
        end
    end
    return oldest
end
