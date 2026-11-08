local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time
local max = math.max

local SESSION_TIMEOUT = Constants.SESSION_TIMEOUT
-- Quanto si aspetta la risposta a un index diff prima di passare al candidato
-- dopo. Prima l'unico limite era SESSION_TIMEOUT, 60 s, e poi si aspettava il
-- prossimo HELLO: un seed muto costava un giro intero. 30 s coprono il caso
-- peggiore misurato il 06/11 -- un digest di 600 blocchi pesa ~6,8 KB, cioe'
-- ~8,5 s per uscire a 800 B/s, piu' una coda di SUMMARY sul seed di ~11 s con
-- 40 compagni online -- e i seed nuovi, quando non possono, rispondono busy.
local INDEX_DIFF_RESPONSE_TIMEOUT_SECONDS = 30

-- Un seed che non risponde, o che non consegna il blocco chiesto, passa in
-- fondo ai candidati per un po'. L'08/11 il canary chiedeva ad Alarnos a ogni
-- HELLO, 8 volte in 14 minuti e sempre a vuoto; e nella gilda simulata, con i
-- sussurri a raffica scartati dal server, un client 0.1.6 chiedeva 34 volte
-- in 20 minuti un blocco a uno 0.1.5 la cui risposta non arrivava mai. Resta
-- candidato -- se e' l'unico che ha il blocco lo si richiede -- ma non passa
-- piu' davanti a chi risponde. Lo stesso registro delle sessioni senza
-- progressi: una sessione che porta qualcosa lo cancella.
local function backOffSilentSeed(self, session, reason, now)
    if not self:IsValidSyncMemberKey(session.seedKey) then
        return
    end
    local cooldown = Constants.SILENT_SEED_BACKOFF_SECONDS or 120
    self._peerSessionBackoffUntil = self._peerSessionBackoffUntil or {}
    self._peerSessionBackoffUntil[session.seedKey] = now + cooldown
    self.telemetry.silentSeedBackoffs = (self.telemetry.silentSeedBackoffs or 0) + 1
    Addon:Tracef("sync",
        "peer-backoff-set peer=%s reason=%s cooldownSeconds=%d",
        tostring(session.seedKey), tostring(reason), cooldown
    )
end
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

-- Skip blocks offered with a fingerprint we've already failed to converge
-- on. In a convergence sync the question isn't WHO is sending — it's WHAT
-- they're sending. If peer A advertised block B with fingerprint F and we
-- pulled it with zero progress, peer C later advertising B with the same
-- F won't help us either; they share the same divergent state. Skip
-- straight away. The same key (B, F) also expires after a cooldown so a
-- peer that legitimately re-broadcasts the same fingerprint after a brief
-- network blip eventually gets another chance.
--
-- When peer A updates and now advertises B with a NEW fingerprint F', the
-- (B, F') pair is fresh and we try it — convergence-aware: we trust the
-- DATA's identity, not the peer's.
local BLOCK_SATURATION_NO_PROGRESS_THRESHOLD = 2
local BLOCK_SATURATION_COOLDOWN_SECONDS = 300

local function normalizeFingerprint(fingerprint)
    if fingerprint == nil then return "" end
    return tostring(fingerprint)
end

-- Saturation lives in SavedVariables so the cooldown survives /reload.
-- Cross-version sync loops typically arise immediately after login (the
-- offending peer is back online) so resetting the state at reload would
-- mean re-paying the discovery cost every session.
local function getSaturationStore(create)
    local db = Addon and Addon.Data and Addon.Data.db and Addon.Data.db.global or nil
    if not db then return nil end
    if type(db.syncSaturation) ~= "table" then
        if not create then return nil end
        db.syncSaturation = {}
    end
    if type(db.syncSaturation.blockFingerprints) ~= "table" then
        if not create then return nil end
        db.syncSaturation.blockFingerprints = {}
    end
    return db.syncSaturation.blockFingerprints
end

local function getSaturationEntry(blockKey, fingerprint, create)
    if type(blockKey) ~= "string" or blockKey == "" then return nil end
    local store = getSaturationStore(create)
    if not store then return nil end
    local fp = normalizeFingerprint(fingerprint)
    local blockTable = store[blockKey]
    if not blockTable then
        if not create then return nil end
        blockTable = {}
        store[blockKey] = blockTable
    end
    local entry = blockTable[fp]
    if not entry and create then
        entry = { noProgressCount = 0, saturatedUntil = 0 }
        blockTable[fp] = entry
    end
    return entry
end

function Sync:IsBlockFingerprintSaturated(blockKey, fingerprint)
    local entry = getSaturationEntry(blockKey, fingerprint, false)
    if not entry then return false end
    local saturatedUntil = entry.saturatedUntil or 0
    if saturatedUntil <= 0 then
        -- Counter is incrementing but threshold not yet reached: NOT
        -- saturated, but also don't reset — we need the count to survive
        -- between sessions so the threshold can actually be crossed.
        return false
    end
    if saturatedUntil <= time() then
        -- Cooldown expired: clear so the next pull gets a fresh chance.
        entry.saturatedUntil = 0
        entry.noProgressCount = 0
        return false
    end
    return true
end

function Sync:RecordBlockFingerprintNoProgress(blockKey, fingerprint)
    local entry = getSaturationEntry(blockKey, fingerprint, true)
    if not entry then return end
    entry.noProgressCount = (entry.noProgressCount or 0) + 1
    if entry.noProgressCount >= BLOCK_SATURATION_NO_PROGRESS_THRESHOLD then
        entry.saturatedUntil = time() + BLOCK_SATURATION_COOLDOWN_SECONDS
        Addon:Tracef("sync",
            "block-fingerprint-saturation-set block=%s fingerprint=%s noProgressCount=%d cooldownSeconds=%d",
            tostring(blockKey),
            tostring(normalizeFingerprint(fingerprint)),
            entry.noProgressCount,
            BLOCK_SATURATION_COOLDOWN_SECONDS
        )
    end
end

function Sync:ResetBlockFingerprintSaturation(blockKey, fingerprint)
    local entry = getSaturationEntry(blockKey, fingerprint, false)
    if entry then
        entry.noProgressCount = 0
        entry.saturatedUntil = 0
    end
end

function Sync:BuildWantedBlockOrder(offeredBlocks, peerKey)
    local rows = {}
    local skipped = 0
    local dropped = 0
    -- Un blocco che il proprietario ha detto di non avere piu' non si chiede:
    -- chi lo offre non ha ancora sentito la dichiarazione. Se il seed e' il
    -- proprietario stesso, lo offre perche' l'ha ripreso, e lo si prende.
    local data = Addon.Data
    local canCheckDropped = data and data.IsSyncBlockDroppedByOwner and data.ParseSyncBlockKey
    for index = 1, #(offeredBlocks or {}) do
        local row = offeredBlocks[index]
        if type(row) == "table" and type(row.blockKey) == "string" and row.blockKey ~= "" then
            if canCheckDropped
                and data:ParseSyncBlockKey(row.blockKey) ~= peerKey
                and data:IsSyncBlockDroppedByOwner(row.blockKey)
            then
                dropped = dropped + 1
            elseif self:IsBlockFingerprintSaturated(row.blockKey, row.fingerprint) then
                skipped = skipped + 1
            else
                rows[#rows + 1] = {
                    blockKey = row.blockKey,
                    count = tonumber(row.count or 0) or 0,
                    fingerprint = row.fingerprint,
                    reason = row.reason,
                }
            end
        end
    end
    if skipped > 0 then
        Addon:Tracef("sync",
            "block-fingerprint-saturation-skip peer=%s skipped=%d kept=%d",
            tostring(peerKey or "unknown"),
            skipped,
            #rows
        )
    end
    if dropped > 0 then
        Addon:Tracef("sync",
            "block-owner-dropped-skip peer=%s skipped=%d kept=%d",
            tostring(peerKey or "unknown"),
            dropped,
            #rows
        )
    end
    table.sort(rows, function(left, right)
        if (left.count or 0) ~= (right.count or 0) then
            return (left.count or 0) > (right.count or 0)
        end
        return tostring(left.blockKey or "") < tostring(right.blockKey or "")
    end)
    -- Il secondo valore dice perche' un blocco offerto non si chiede. Conta per
    -- le coppie sterili: un blocco segnato resta rifiutato finche' le
    -- impronte non cambiano, uno saturo torna dopo il suo cooldown, e quindi
    -- un "niente da chiedere" dovuto alla saturazione non e' sterile.
    return rows, { ownerDropped = dropped, saturated = skipped }
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
    -- l'impronta che descrive il digest appena costruito; nil se l'indice non e'
    -- in ordine, e allora la coppia non si registra
    session.localFingerprint = self.GetSettledLocalFingerprint
        and self:GetSettledLocalFingerprint("index-diff-request") or nil
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

-- Il "no" del seed. Prima passava da CanRunSyncProtocol, e quindi taceva
-- proprio quando serviva: un seed in warmup, o con l'indice da ricostruire,
-- non poteva dire di non poter rispondere, e chi chiedeva aspettava 60 s. Un
-- rifiuto e' un sussurro di poche decine di byte: parte sempre, con il motivo,
-- e chi lo riceve passa al candidato dopo (HandleSeedBusy). Lo capiscono anche
-- i client vecchi: e' l'INDEX_DIFF_RESPONSE con busy che conoscono gia'.
function Sync:SendIndexDiffBusy(targetKey, requestPayload, reason)
    if not self:IsValidSyncMemberKey(targetKey) then
        return false
    end

    local busyReason = tostring(reason or "busy")
    local sent = self:SendRefusalEnvelope("INDEX_DIFF_RESPONSE", {
        requestId = requestPayload and requestPayload.requestId or nil,
        busy = true,
        reason = busyReason,
    }, targetKey)
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
    -- offeredBlocks is read-only (telemetry / logging); wantedBlocks is
    -- iterated by nextWantedIndex. Same source so share the list — two
    -- BuildWantedBlockOrder calls were doing two table sorts and two
    -- saturation-store walks for the same answer.
    local orderedBlocks, orderStats = self:BuildWantedBlockOrder(payload.offeredBlocks or {}, payload.sender)
    session.offeredBlocks = orderedBlocks
    session.wantedBlocks = orderedBlocks
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
        -- niente da prendere, e non per un cooldown che scade da solo: con
        -- queste due impronte non verra' mai niente, vedi le coppie sterili
        if (orderStats and orderStats.saturated or 0) == 0 and self.RecordSterilePair then
            local offeredCount = #(payload.offeredBlocks or {})
            self:RecordSterilePair("pull", payload.sender, session.seedFingerprint, session.localFingerprint,
                offeredCount == 0 and "no-offer" or "owner-dropped")
        end
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
    -- Capture the fingerprint the peer advertised at INDEX_DIFF time. After
    -- the pull merges we use it as the saturation key so the block-vs-data
    -- backoff tracks WHAT we tried to pull, not WHO offered it.
    session.activeBlockOfferedFingerprint = row.fingerprint
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
    session.activeBlockOfferedFingerprint = nil
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

    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return
    end
    if session.state == "completed" or session.state == "aborted" then
        return
    end

    -- I timeout prima di tutto. Erano dopo i due return qui sotto, e quindi
    -- una sessione aperta un attimo prima di un'istanza, o con l'indice da
    -- ricostruire, non scadeva mai: in istanza ProcessRequestQueue usciva
    -- subito, e a indice non pronto anche -- mentre il rebuild completo
    -- dell'indice aspetta, per scelta, che non ci siano sessioni aperte.
    -- Trovato dalla gilda simulata il 06/11 (sync_sim_spec, caos).
    local now = time()
    local paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic() or false
    if session.state == "waiting-index-diff" and session.diffSentAt
        and (now - session.diffSentAt) > INDEX_DIFF_RESPONSE_TIMEOUT_SECONDS
    then
        self.telemetry.indexDiffResponseTimeouts = (self.telemetry.indexDiffResponseTimeouts or 0) + 1
        Addon:Tracef("sync",
            "index-diff-timeout peer=%s requestId=%s waited=%d",
            tostring(session.seedKey or "unknown"),
            tostring(session.diffRequestId or "none"),
            now - session.diffSentAt
        )
        backOffSilentSeed(self, session, "index-diff-timeout", now)
        if self.FallBackFromSeed then
            self:FallBackFromSeed(session, "index-diff-timeout")
        elseif self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("index-diff-timeout")
        end
        return
    end
    local age = max(0, now - (session.lastProgressAt or session.startedAt or now))
    if age > SESSION_TIMEOUT then
        self.telemetry.lastBlockPullTimeoutAt = now
        self.telemetry.lastBlockPullTimeoutReason = "session-timeout"
        backOffSilentSeed(self, session, "session-timeout", now)
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
            backOffSilentSeed(self, session, "block-response-timeout", now)
            if self.AbortOutboundSeedSession then
                self:AbortOutboundSeedSession("block-response-timeout")
            end
            return
        end
    end

    if paused then
        return
    end
    local allowActivePullAdvance = self.CanAdvanceOutboundPullSession and self:CanAdvanceOutboundPullSession() or false
    if self.syncReady ~= true and not allowActivePullAdvance then
        return
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
