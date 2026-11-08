local Addon = _G.RecipeRegistry
local Sync = Addon.Sync

local time = time

-- Un BLOCK_PULL_REQUEST che il seed non puo' servire. Fino alla 0.1.5 il seed
-- lo scriveva nel suo log e non diceva niente a chi chiedeva, che aspettava
-- 60 s (block-response-timeout) prima di arrendersi -- e una sessione chiusa
-- a meta' dal seed, per un warmup o un cambio di zona, voleva dire 60 s di
-- attesa per ogni compagno che stava tirando da lui. Ora risponde.
--
-- Un tipo di messaggio nuovo e non un BLOCK_SNAPSHOT vuoto: un client vecchio
-- lo prenderebbe per "il seed non ha piu' quel blocco" e creerebbe un mestiere
-- vuoto. Un tipo che non conosce lo scarta e basta, e resta col timeout di
-- prima.
--
-- Due famiglie di motivi. Quelli del blocco -- non e' fra quelli offerti, o
-- non c'e' piu' -- dicono di saltare quel blocco e andare avanti col
-- prossimo. Tutti gli altri dicono che il seed adesso non puo', e chi chiede
-- passa a un altro candidato.
local BLOCK_LEVEL_REFUSALS = {
    ["block-not-offered"] = true,
    ["snapshot-unavailable"] = true,
}

function Sync:SendBlockPullRefused(targetKey, requestPayload, reason)
    if not self:IsValidSyncMemberKey(targetKey) then
        return false
    end
    local refusal = tostring(reason or "refused")
    local sent = self:SendRefusalEnvelope("BLOCK_PULL_REFUSED", {
        requestId = requestPayload and requestPayload.requestId or nil,
        blockKey = requestPayload and requestPayload.blockKey or nil,
        reason = refusal,
    }, targetKey)
    if sent then
        self.telemetry.blockPullRefusedSent = (self.telemetry.blockPullRefusedSent or 0) + 1
        Addon:Tracef("sync",
            "block-pull-refused-sent peer=%s block=%s requestId=%s reason=%s",
            tostring(targetKey),
            tostring(requestPayload and requestPayload.blockKey or "none"),
            tostring(requestPayload and requestPayload.requestId or "none"),
            refusal
        )
    end
    return sent
end

-- Lasciare un seed che non risponde, o che dice di non potere. Se da lui si e'
-- gia' preso qualcosa la sessione si chiude come sempre, perche' l'impronta va
-- ricalcolata e il prossimo HELLO deve dirlo; altrimenti si prova subito il
-- candidato dopo dello stesso giro, invece di aspettare il prossimo HELLO.
function Sync:FallBackFromSeed(session, reason)
    if type(session) ~= "table" then
        return false
    end
    -- a protocollo fermo o a sync non pronto non si apre una sessione nuova:
    -- resterebbe li' senza poter partire, si chiude e basta
    local paused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("INDEX_DIFF_REQUEST") or false
    if (session.successfulBlockMerges or 0) == 0
        and not paused
        and self.syncReady == true
        and type(self.activeHelloCycle) == "table"
        and self.HandleSeedBusy
    then
        return self:HandleSeedBusy(session.seedKey, reason)
    end
    if self.AbortOutboundSeedSession then
        return self:AbortOutboundSeedSession(reason)
    end
    return false
end

function Sync:HandleReceivedBlockPullRefused(payload)
    local session = self.outboundSeedSession
    if type(session) ~= "table" or session.state ~= "waiting-block" then
        return false
    end
    if payload.sender ~= session.seedKey then
        return false
    end
    if payload.requestId and session.activeBlockRequestId and payload.requestId ~= session.activeBlockRequestId then
        return false
    end
    if payload.blockKey and session.activeBlockKey and payload.blockKey ~= session.activeBlockKey then
        return false
    end

    local reason = tostring(payload.reason or "refused")
    self.telemetry.blockPullRefusedReceived = (self.telemetry.blockPullRefusedReceived or 0) + 1
    Addon:Tracef("sync",
        "block-pull-refused-received peer=%s block=%s requestId=%s reason=%s",
        tostring(payload.sender),
        tostring(session.activeBlockKey or "none"),
        tostring(payload.requestId or "none"),
        reason
    )
    session.lastProgressAt = time()
    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    session.activeBlockOfferedFingerprint = nil

    if not BLOCK_LEVEL_REFUSALS[reason] then
        return self:FallBackFromSeed(session, "seed-refused:" .. reason)
    end

    session.nextWantedIndex = (session.nextWantedIndex or 1) + 1
    if not (session.wantedBlocks and session.wantedBlocks[session.nextWantedIndex]) then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("all-blocks-complete")
        end
        return true
    end
    if self.ScheduleNextWantedBlock then
        self:ScheduleNextWantedBlock()
    end
    return true
end

function Sync:SendBlockSnapshot(targetKey, requestPayload)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("BLOCK_SNAPSHOT")
    end
    -- il secondo valore e' il motivo, per il BLOCK_PULL_REFUSED che ne segue
    if not allowed then
        return false, "not-ready"
    end
    if not (type(requestPayload) == "table" and type(requestPayload.blockKey) == "string") then
        return false, "bad-request"
    end
    local snapshot = Addon.Data and Addon.Data.BuildBlockSnapshot and Addon.Data:BuildBlockSnapshot(requestPayload.blockKey, {
        snapshotKind = "block-pull",
    }) or nil
    if type(snapshot) ~= "table" then
        -- offerto e poi sparito: il proprietario l'ha dichiarato abbandonato,
        -- o una pulizia l'ha tolto, fra l'index diff e questa richiesta
        return false, "snapshot-unavailable"
    end
    local sent = self:SendDirectEnvelope("BLOCK_SNAPSHOT", {
        requestId = requestPayload.requestId,
        blockKey = snapshot.blockKey,
        blockPayload = {
            ownerCharacter = snapshot.ownerCharacter,
            professionKey = snapshot.professionKey,
            recipeKeys = snapshot.recipeKeys,
            specialization = snapshot.specialization,
            skillRank = snapshot.skillRank,
            skillMaxRank = snapshot.skillMaxRank,
            metadata = snapshot.metadata,
        },
    }, targetKey, "BULK")
    if sent then
        self.telemetry.blockSnapshotSent = (self.telemetry.blockSnapshotSent or 0) + 1
        self.lastSnapshotServedAt = time()
        if self.RecordSyncEvent then
            self:RecordSyncEvent("blockSnapshotSent", {
                peer = targetKey,
                requestId = requestPayload.requestId,
                blockKey = snapshot.blockKey,
                extra = string.format("recipes=%d", #(snapshot.recipeKeys or {})),
            })
        end
        Addon:Tracef("sync",
            "block-snapshot-sent peer=%s requestId=%s block=%s recipes=%d",
            tostring(targetKey or "unknown"),
            tostring(requestPayload.requestId or "none"),
            tostring(snapshot.blockKey or "none"),
            #(snapshot.recipeKeys or {})
        )
    end
    if not sent then
        return false, "send-failed"
    end
    return true
end

function Sync:HandleReceivedBlockSnapshot(payload)
    local session = self.outboundSeedSession
    if type(session) ~= "table" then
        return false
    end
    if session.state ~= "waiting-block" then
        return false
    end
    if payload.sender ~= session.seedKey then
        return false
    end
    if payload.requestId and session.activeBlockRequestId and payload.requestId ~= session.activeBlockRequestId then
        return false
    end
    if payload.blockKey ~= session.activeBlockKey then
        return false
    end

    session.lastProgressAt = time()
    self.telemetry.blockSnapshotReceived = (self.telemetry.blockSnapshotReceived or 0) + 1
    self.telemetry.lastBlockSnapshotReceivedAt = session.lastProgressAt
    if self.RecordSyncEvent then
        self:RecordSyncEvent("blockSnapshotReceived", {
            peer = payload.sender,
            requestId = payload.requestId,
            blockKey = payload.blockKey,
        })
    end
    Addon:Tracef("sync",
        "block-snapshot-received peer=%s requestId=%s block=%s",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        tostring(payload.blockKey or "none")
    )

    local incomingPayload = payload.blockPayload or payload
    if type(incomingPayload) == "table" and incomingPayload.blockKey == nil then
        incomingPayload = {
            blockKey = payload.blockKey,
            ownerCharacter = incomingPayload.ownerCharacter,
            professionKey = incomingPayload.professionKey,
            recipeKeys = incomingPayload.recipeKeys,
            specialization = incomingPayload.specialization,
            skillRank = incomingPayload.skillRank,
            skillMaxRank = incomingPayload.skillMaxRank,
            metadata = incomingPayload.metadata,
        }
    end

    local applied = false
    local result = nil
    if Addon.Data and Addon.Data.ApplyIncomingBlockAdditive then
        local blockOwner = Addon.Data.ParseSyncBlockKey and Addon.Data:ParseSyncBlockKey(payload.blockKey) or nil
        applied, result = Addon.Data:ApplyIncomingBlockAdditive(payload.blockKey, incomingPayload, {
            sourceType = payload.sender == ((payload.blockPayload and payload.blockPayload.ownerCharacter) or payload.ownerCharacter) and "owner" or "replica",
            fromOwner = blockOwner ~= nil and payload.sender == blockOwner,
        })
    end
    if not applied then
        if self.AbortOutboundSeedSession then
            self:AbortOutboundSeedSession("block-merge-failed")
        end
        return false
    end

    -- The fingerprint recompute has been deferred to the RR_BLOCK_MERGE_POST
    -- bucket handler in Core. The merge result no longer carries it, and we
    -- deliberately do NOT recompute it synchronously here: that would defeat
    -- the deferral and re-introduce the per-merge stutter we were trying to
    -- avoid. Per-block fingerprint telemetry is intentionally cleared here:
    -- the deferred bucket drains all dirty blocks at once and the authoritative
    -- sync state is finalized by the global fingerprint refresh when the pull
    -- session completes.
    self.telemetry.blockMergedImmediate = (self.telemetry.blockMergedImmediate or 0) + 1
    self.telemetry.lastMergedBlockKey = tostring(payload.blockKey)
    self.telemetry.lastMergedBlockFingerprint = nil
    self.telemetry.successfulBlockMerges = (session.successfulBlockMerges or 0) + 1
    if self.RecordSyncEvent then
        self:RecordSyncEvent("blockMerged", {
            peer = payload.sender,
            requestId = payload.requestId,
            blockKey = payload.blockKey,
        })
    end
    local addedRecipes = type(result) == "table" and tonumber(result.addedRecipes or 0) or 0
    local specChanged = type(result) == "table" and result.specializationChanged == true
    local incomingRecipeCount = type(incomingPayload) == "table" and incomingPayload.recipeKeys
        and #incomingPayload.recipeKeys or 0
    Addon:Tracef("sync",
        "block-merge-complete block=%s peer=%s incomingRecipes=%d addedRecipes=%d specChanged=%s fingerprint=deferred",
        tostring(payload.blockKey or "none"),
        tostring(payload.sender or "unknown"),
        incomingRecipeCount,
        addedRecipes,
        tostring(specChanged)
    )

    -- Saturation tracking by (block, fingerprint): the offered fingerprint
    -- identifies the data shape the peer advertised. If pulling against
    -- this fingerprint added zero recipes, that DATA won't converge with
    -- ours — and the same fingerprint coming from a different peer next
    -- session won't help either. Index on the fingerprint, not the peer,
    -- so the backoff is convergence-aware: a peer who later advertises a
    -- NEW fingerprint for the same block (e.g. they cleaned their DB)
    -- gets a fresh attempt naturally. Any pull that DOES make progress
    -- (added recipes, spec change, or empty incoming meaning the peer
    -- dropped the block) resets the counter on that fingerprint.
    local progressMerge = addedRecipes > 0 or specChanged or incomingRecipeCount == 0
    local offeredFingerprint = session.activeBlockOfferedFingerprint
    if payload.blockKey then
        if not progressMerge then
            if self.RecordBlockFingerprintNoProgress then
                self:RecordBlockFingerprintNoProgress(payload.blockKey, offeredFingerprint)
            end
        else
            if self.ResetBlockFingerprintSaturation then
                self:ResetBlockFingerprintSaturation(payload.blockKey, offeredFingerprint)
            end
        end
    end
    -- Session-level progress tracking so CompleteOutboundSeedSession can
    -- tell "we pulled blocks but converged on nothing" apart from "we
    -- pulled and made progress". Drives the peer-level backoff that the
    -- seed-selection sort already honors via IsPeerBackoffActive.
    if progressMerge then
        session.progressBlockMerges = (session.progressBlockMerges or 0) + 1
    end

    session.successfulBlockMerges = (session.successfulBlockMerges or 0) + 1
    session.lastMergedBlockFingerprint = nil
    session.activeBlockKey = nil
    session.activeBlockRequestId = nil
    session.activeBlockOfferedFingerprint = nil
    session.nextWantedIndex = (session.nextWantedIndex or 1) + 1
    if self.RefreshSyncReadyState then
        self:RefreshSyncReadyState("block-merge")
    end
    self.lastSnapshotSuccessAt = time()
    self:MarkPeerSuccess(payload.sender)
    if not (session.wantedBlocks and session.wantedBlocks[session.nextWantedIndex]) then
        if self.CompleteOutboundSeedSession then
            self:CompleteOutboundSeedSession("all-blocks-complete")
        end
        return result or true
    end
    if self.ScheduleNextWantedBlock then
        self:ScheduleNextWantedBlock()
    end
    return result or true
end
