local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local type = type
local tostring = tostring

local countRecipeKeys = Private.countRecipeKeys
local isValidRecipeKey = Private.isValidRecipeKey
local lowerSafe = Private.lowerSafe

local DEFAULT_ROSTER_FRESHNESS_MAX_AGE = 20
local SYNC_MODEL = "index-diff-block-pull"

local function cloneArray(values)
    local out = {}
    for index = 1, #(values or {}) do
        out[index] = values[index]
    end
    return out
end

local function cloneTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        if type(value) == "table" then
            out[key] = cloneTable(value)
        else
            out[key] = value
        end
    end
    return out
end

local function sortStrings(values)
    sort(values, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return values
end

local function countKeys(tbl)
    local total = 0
    for _ in pairs(tbl or {}) do
        total = total + 1
    end
    return total
end

local function bumpSyncTelemetry(counter, amount)
    local sync = Addon.Sync
    if not (sync and sync.telemetry) then
        return
    end
    sync.telemetry[counter] = (sync.telemetry[counter] or 0) + (amount or 1)
end

local function setSyncTelemetry(counter, value)
    local sync = Addon.Sync
    if not (sync and sync.telemetry) then
        return
    end
    sync.telemetry[counter] = value
end

local function buildSpecializationContentKey(specialization)
    if specialization == nil then
        return nil
    end
    local normalized = lowerSafe(specialization)
    if normalized == "" then
        return nil
    end
    return "spec:" .. normalized
end

local function normalizeContentKey(recipeKey)
    local numeric = tonumber(recipeKey)
    if numeric ~= nil then
        return tostring(numeric)
    end
    return tostring(recipeKey)
end

local function hashString(text)
    local hash = 5381
    for index = 1, #text do
        hash = ((hash * 33) + string.byte(text, index)) % 4294967296
    end
    return string.format("%08x", hash)
end

-- `bf3`/`gf3` denote the current internal fingerprint schema revision.
-- They are local convergence identifiers, not compatibility markers for the
-- removed manifest/revision protocol.
local function buildFingerprint(prefix, content)
    return string.format("%s:%s", prefix, hashString(content))
end

local function getRosterFreshnessMaxAge()
    local constants = Addon.Sync and Addon.Sync._private and Addon.Sync._private.constants or nil
    return constants and constants.ROSTER_FRESHNESS_MAX_AGE or DEFAULT_ROSTER_FRESHNESS_MAX_AGE
end

local function getSyncWarmupReason()
    local sync = Addon.Sync
    if not sync then
        return nil
    end
    if sync.IsInWarmup and sync:IsInWarmup() then
        return "warmup"
    end
    if sync.IsInWorldTransition and sync:IsInWorldTransition() then
        return "world-transition"
    end
    return nil
end

local function buildRosterState(self, reason)
    local snapshot = nil
    local snapshotCount = 0
    local knownActive = 0
    local trusted = false
    local rosterReason = "unavailable"

    local transitionReason = getSyncWarmupReason()
    if transitionReason then
        rosterReason = transitionReason
    elseif type(IsInGuild) == "function" and not IsInGuild() then
        trusted = true
        rosterReason = "not-in-guild"
    elseif self.NeedsGuildRosterRefresh and self:NeedsGuildRosterRefresh(getRosterFreshnessMaxAge()) then
        rosterReason = "roster-stale"
        if self.RequestGuildRosterRefresh then
            self:RequestGuildRosterRefresh(reason or "sync-index", {
                cooldown = getRosterFreshnessMaxAge(),
            })
        end
    else
        local lifecycle = Addon.GuildLifecycleMaintenance
        if lifecycle and lifecycle.BuildGuildRosterSnapshot and lifecycle.ValidateRosterSnapshot then
            snapshot, snapshotCount = lifecycle:BuildGuildRosterSnapshot()
            local memberKeys = self:GetSortedMemberKeys(true)
            local valid, validateReason, finalSnapshotCount, finalKnownActive =
                lifecycle:ValidateRosterSnapshot(snapshot, snapshotCount, memberKeys, {})
            snapshotCount = finalSnapshotCount or snapshotCount or 0
            knownActive = finalKnownActive or 0
            if valid then
                trusted = true
                rosterReason = "trusted"
            else
                rosterReason = validateReason or "roster-untrusted"
            end
        else
            trusted = true
            rosterReason = "trusted-no-lifecycle"
        end
    end

    return {
        trusted = trusted,
        reason = rosterReason,
        snapshot = snapshot,
        snapshotCount = snapshotCount or 0,
        knownActive = knownActive or 0,
        evaluatedAt = time(),
    }
end

local function rosterSignature(rosterState)
    if type(rosterState) ~= "table" then
        return "missing"
    end
    local parts = {
        tostring(rosterState.trusted == true),
        tostring(rosterState.reason or "unknown"),
    }
    local snapshotKeys = {}
    for memberKey in pairs(rosterState.snapshot or {}) do
        snapshotKeys[#snapshotKeys + 1] = memberKey
    end
    sortStrings(snapshotKeys)
    parts[#parts + 1] = table.concat(snapshotKeys, "|")
    return table.concat(parts, "::")
end

local function shouldPublishOwner(self, rosterState, memberKey, entry, selfKey)
    if not memberKey or not entry then
        return false
    end
    if self:IsMockMember(memberKey, entry) then
        return false
    end
    if memberKey == selfKey then
        return true
    end
    if (entry.guildStatus or "active") ~= "active" then
        return false
    end
    if rosterState and rosterState.trusted ~= true then
        return false
    end
    if rosterState and type(rosterState.snapshot) == "table" and not rosterState.snapshot[memberKey] then
        return false
    end
    return true
end

local function buildContentKeysForProfession(profession)
    local contentKeys = {}
    for recipeKey in pairs(profession and profession.recipes or {}) do
        if isValidRecipeKey(recipeKey) then
            contentKeys[#contentKeys + 1] = normalizeContentKey(recipeKey)
        end
    end
    local specializationKey = buildSpecializationContentKey(profession and profession.specialization or nil)
    if specializationKey then
        contentKeys[#contentKeys + 1] = specializationKey
    end
    return sortStrings(contentKeys)
end

local function buildBlockRecord(self, memberKey, professionKey, profession)
    local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
    if not blockKey then
        return nil
    end
    local contentKeys = buildContentKeysForProfession(profession)
    local joined = table.concat(contentKeys, "|")
    return {
        blockKey = blockKey,
        ownerCharacter = memberKey,
        professionKey = professionKey,
        sortedContentKeys = contentKeys,
        contentCount = #contentKeys,
        blockFingerprint = string.format("bf3:%d:%s", #contentKeys, buildFingerprint("bf3", joined)),
        builtAt = time(),
    }
end

local function ensureSyncIndexState(self)
    self._syncIndexState = self._syncIndexState or {
        committedSummary = nil,
        committedGlobalFingerprint = nil,
        lastCommittedAt = 0,
        lastCommittedReason = nil,
        lastSummary = nil,
        lastDirtyReason = nil,
        lastDirtyAt = 0,
        lastClearedReason = nil,
        lastClearedAt = 0,
    }
    self._syncIndexCache = self._syncIndexCache or {
        dirtyAll = true,
        dirtyBlocks = {},
        dirtyBlockCount = 0,
        blocks = {},
        blockKeys = {},
        activeOwnerCount = 0,
        activeBlockCount = 0,
        activeContentCount = 0,
        globalFingerprint = nil,
        trustedRosterState = nil,
        indexStatus = "missing",
        ready = false,
        globalDirty = true,
        rosterSignature = nil,
        builtAt = 0,
        lastBuildReason = nil,
        lastDirtyReason = nil,
        lastDirtyAt = 0,
        lastFullBuildAt = 0,
        stats = {
            hits = 0,
            misses = 0,
            blockRebuilt = 0,
            fullRebuild = 0,
            globalRecomputed = 0,
        },
    }
    return self._syncIndexState, self._syncIndexCache
end

local function isOutboundSessionActive()
    local sync = Addon.Sync
    local session = sync and sync.outboundSeedSession or nil
    if type(session) ~= "table" then
        return false
    end
    local state = tostring(session.state or "")
    return state ~= "" and state ~= "completed" and state ~= "aborted" and state ~= "idle"
end

local function syncTelemetryStats(cache)
    local stats = cache and cache.stats or {}
    setSyncTelemetry("syncIndexCacheHit", stats.hits or 0)
    setSyncTelemetry("syncIndexCacheMiss", stats.misses or 0)
    setSyncTelemetry("syncIndexBlockRebuilt", stats.blockRebuilt or 0)
    setSyncTelemetry("syncIndexFullRebuild", stats.fullRebuild or 0)
    setSyncTelemetry("syncIndexGlobalRecomputed", stats.globalRecomputed or 0)
    setSyncTelemetry("syncIndexDirtyBlockCount", cache and cache.dirtyBlockCount or 0)
end

local function recalcAggregateState(cache)
    local blockKeys = {}
    local owners = {}
    local contentCount = 0
    for blockKey, block in pairs(cache.blocks or {}) do
        if type(block) == "table" then
            blockKeys[#blockKeys + 1] = blockKey
            owners[block.ownerCharacter] = true
            contentCount = contentCount + (tonumber(block.contentCount or 0) or 0)
        end
    end
    sortStrings(blockKeys)
    cache.blockKeys = blockKeys
    cache.activeOwnerCount = countKeys(owners)
    cache.activeBlockCount = #blockKeys
    cache.activeContentCount = contentCount
end

local function rebuildGlobalFingerprint(cache)
    local parts = {}
    for _, blockKey in ipairs(cache.blockKeys or {}) do
        local block = cache.blocks and cache.blocks[blockKey] or nil
        parts[#parts + 1] = string.format("%s=%s", tostring(blockKey), tostring(block and block.blockFingerprint or ""))
    end
    local payload = table.concat(parts, "|")
    cache.globalFingerprint = string.format(
        "gf3:%d:%d:%d:%s",
        tonumber(cache.activeOwnerCount or 0) or 0,
        tonumber(cache.activeBlockCount or 0) or 0,
        tonumber(cache.activeContentCount or 0) or 0,
        buildFingerprint("gf3", payload)
    )
    cache.globalDirty = false
    cache.stats.globalRecomputed = (cache.stats.globalRecomputed or 0) + 1
    bumpSyncTelemetry("syncIndexGlobalRecomputed")
    Addon:Trace("sync", string.format(
        "global-fingerprint-recomputed owners=%d blocks=%d content=%d fingerprint=%s",
        cache.activeOwnerCount or 0,
        cache.activeBlockCount or 0,
        cache.activeContentCount or 0,
        tostring(cache.globalFingerprint or "none")
    ))
end

local function rebuildAllBlocks(self, cache, rosterState, reason)
    local memberKeys = self:GetSortedMemberKeys(true)
    local selfKey = self:GetPlayerKey()
    local blocks = {}

    for _, memberKey in ipairs(memberKeys) do
        local entry = self:GetMember(memberKey)
        if shouldPublishOwner(self, rosterState, memberKey, entry, selfKey) then
            local professionKeys = {}
            for professionKey in pairs(entry.professions or {}) do
                professionKeys[#professionKeys + 1] = professionKey
            end
            sortStrings(professionKeys)
            for _, professionKey in ipairs(professionKeys) do
                local profession = entry.professions and entry.professions[professionKey] or nil
                local block = buildBlockRecord(self, memberKey, professionKey, profession)
                if block and block.contentCount > 0 then
                    blocks[block.blockKey] = block
                end
            end
        end
    end

    cache.blocks = blocks
    cache.trustedRosterState = cloneTable(rosterState)
    cache.indexStatus = rosterState.trusted == true and "ready" or tostring(rosterState.reason or "not-ready")
    cache.ready = rosterState.trusted == true
    cache.lastBuildReason = tostring(reason or "full-rebuild")
    cache.lastFullBuildAt = time()
    cache.dirtyAll = false
    cache.dirtyBlocks = {}
    cache.dirtyBlockCount = 0
    recalcAggregateState(cache)
    cache.globalDirty = true
    cache.stats.fullRebuild = (cache.stats.fullRebuild or 0) + 1
    bumpSyncTelemetry("syncIndexFullRebuild")
    Addon:Trace("sync", string.format(
        "sync-index-full-rebuild reason=%s ready=%s roster=%s",
        tostring(reason or "full-rebuild"),
        tostring(cache.ready == true),
        tostring(cache.indexStatus or "unknown")
    ))
end

local function rebuildDirtyBlocks(self, cache, rosterState, reason)
    if cache.dirtyAll then
        rebuildAllBlocks(self, cache, rosterState, reason)
        return
    end
    if cache.rosterSignature ~= rosterSignature(rosterState) then
        rebuildAllBlocks(self, cache, rosterState, reason or "roster-changed")
        return
    end

    local rebuilt = 0
    for blockKey in pairs(cache.dirtyBlocks or {}) do
        local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
        local entry = ownerCharacter and self:GetMember(ownerCharacter) or nil
        local publish = ownerCharacter and entry and shouldPublishOwner(self, rosterState, ownerCharacter, entry, self:GetPlayerKey()) or false
        local profession = publish and entry.professions and entry.professions[professionKey] or nil
        local block = profession and buildBlockRecord(self, ownerCharacter, professionKey, profession) or nil
        if block and block.contentCount > 0 then
            cache.blocks[blockKey] = block
        else
            cache.blocks[blockKey] = nil
        end
        rebuilt = rebuilt + 1
        cache.stats.blockRebuilt = (cache.stats.blockRebuilt or 0) + 1
        bumpSyncTelemetry("syncIndexBlockRebuilt")
        Addon:Trace("sync", string.format(
            "sync-index-block-rebuilt reason=%s block=%s",
            tostring(reason or "dirty-block"),
            tostring(blockKey)
        ))
    end
    cache.dirtyBlocks = {}
    cache.dirtyBlockCount = 0
    recalcAggregateState(cache)
    cache.trustedRosterState = cloneTable(rosterState)
    cache.indexStatus = rosterState.trusted == true and "ready" or tostring(rosterState.reason or "not-ready")
    cache.ready = rosterState.trusted == true
    cache.lastBuildReason = tostring(reason or "dirty-block")
    cache.globalDirty = cache.globalDirty or rebuilt > 0
end

local function ensureLiveIndex(self, reason)
    local state, cache = ensureSyncIndexState(self)
    local rosterState = buildRosterState(self, reason or "sync-index")
    local nextRosterSignature = rosterSignature(rosterState)

    local hasCache = cache.builtAt > 0 and next(cache.blocks or {}) ~= nil or cache.ready == false and cache.rosterSignature ~= nil
    if not hasCache then
        cache.stats.misses = (cache.stats.misses or 0) + 1
        bumpSyncTelemetry("syncIndexCacheMiss")
        rebuildAllBlocks(self, cache, rosterState, reason or "cache-miss")
    elseif cache.dirtyAll or cache.rosterSignature ~= nextRosterSignature then
        cache.stats.misses = (cache.stats.misses or 0) + 1
        bumpSyncTelemetry("syncIndexCacheMiss")
        if cache.rosterSignature ~= nextRosterSignature and not cache.dirtyAll then
            rebuildAllBlocks(self, cache, rosterState, reason or "roster-changed")
        else
            rebuildDirtyBlocks(self, cache, rosterState, reason or "dirty")
        end
    elseif cache.dirtyBlockCount > 0 or cache.globalDirty then
        cache.stats.misses = (cache.stats.misses or 0) + 1
        bumpSyncTelemetry("syncIndexCacheMiss")
        rebuildDirtyBlocks(self, cache, rosterState, reason or "dirty")
    else
        cache.stats.hits = (cache.stats.hits or 0) + 1
        bumpSyncTelemetry("syncIndexCacheHit")
    end

    cache.rosterSignature = nextRosterSignature
    cache.builtAt = time()
    if cache.globalDirty then
        rebuildGlobalFingerprint(cache)
    end
    syncTelemetryStats(cache)

    local summary = {
        syncModel = SYNC_MODEL,
        ready = cache.ready == true,
        indexStatus = cache.indexStatus,
        trustedRoster = rosterState.trusted == true,
        trustedRosterReason = rosterState.reason,
        activeOwnerCount = cache.activeOwnerCount or 0,
        activeBlockCount = cache.activeBlockCount or 0,
        activeContentCount = cache.activeContentCount or 0,
        globalFingerprint = cache.globalFingerprint,
        blocks = cache.blocks,
        blockKeys = cache.blockKeys,
        rosterState = rosterState,
        builtAt = cache.builtAt,
    }
    state.lastSummary = cloneTable(summary)
    return state, cache, summary
end

function Data:BuildSyncBlockKey(ownerCharacter, professionKey)
    if not ownerCharacter or not professionKey then
        return nil
    end
    if not self:IsValidMemberKey(ownerCharacter) then
        return nil
    end
    return string.format("%s::%s", tostring(ownerCharacter), tostring(professionKey))
end

function Data:ParseSyncBlockKey(blockKey)
    if type(blockKey) ~= "string" then
        return nil, nil
    end
    local ownerCharacter, professionKey = blockKey:match("^(.-)::(.+)$")
    if not ownerCharacter or not professionKey then
        return nil, nil
    end
    return ownerCharacter, professionKey
end

function Data:IsValidSyncBlockKey(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not self:IsValidMemberKey(ownerCharacter) then
        return false
    end
    return type(professionKey) == "string" and professionKey ~= ""
end

function Data:GetSyncBlock(memberKey, professionKey)
    local entry = self:GetMember(memberKey)
    local profession = entry and entry.professions and entry.professions[professionKey] or nil
    local block = profession and buildBlockRecord(self, memberKey, professionKey, profession) or nil
    if not block then
        return nil
    end
    return {
        blockKey = block.blockKey,
        ownerCharacter = block.ownerCharacter,
        professionKey = block.professionKey,
        contentKeys = cloneArray(block.sortedContentKeys),
        count = block.contentCount,
        fingerprint = block.blockFingerprint,
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
        specialization = profession.specialization,
        sourceType = profession.sourceType or entry.sourceType or self:GetMemberSourceType(memberKey),
        guildStatus = profession.guildStatus or entry.guildStatus or "active",
        lastSeenInGuildAt = profession.lastSeenInGuildAt or entry.lastSeenInGuildAt or 0,
    }
end

function Data:MarkSyncIndexDirty(reason, blockKey, opts)
    local state, cache = ensureSyncIndexState(self)
    opts = type(opts) == "table" and opts or {}
    cache.lastDirtyReason = tostring(reason or "unspecified")
    cache.lastDirtyAt = time()
    state.lastDirtyReason = cache.lastDirtyReason
    state.lastDirtyAt = cache.lastDirtyAt

    if opts.full == true or not blockKey then
        cache.dirtyAll = true
        cache.dirtyBlocks = {}
        cache.dirtyBlockCount = 0
    else
        cache.dirtyBlocks = cache.dirtyBlocks or {}
        if not cache.dirtyBlocks[blockKey] then
            cache.dirtyBlocks[blockKey] = true
            cache.dirtyBlockCount = cache.dirtyBlockCount + 1
        end
    end

    cache.globalDirty = true
    syncTelemetryStats(cache)
    bumpSyncTelemetry("globalFingerprintDirty")
    Addon:Trace("sync", string.format(
        "global-fingerprint-dirty reason=%s block=%s full=%s dirtyBlocks=%d",
        tostring(reason or "unspecified"),
        tostring(blockKey or "none"),
        tostring(cache.dirtyAll == true),
        cache.dirtyBlockCount or 0
    ))
    return true
end

function Data:IsSyncIndexDirty()
    local _, cache = ensureSyncIndexState(self)
    return cache.dirtyAll == true or (cache.dirtyBlockCount or 0) > 0 or cache.globalDirty == true
end

function Data:ClearSyncIndexDirty(reason)
    local state, cache = ensureSyncIndexState(self)
    cache.dirtyAll = false
    cache.dirtyBlocks = {}
    cache.dirtyBlockCount = 0
    cache.globalDirty = false
    state.lastClearedReason = tostring(reason or "unspecified")
    state.lastClearedAt = time()
    syncTelemetryStats(cache)
    return true
end

function Data:GetRosterTrustState()
    local _, _, summary = ensureLiveIndex(self, "sync-index-debug")
    return cloneTable(summary.rosterState)
end

function Data:EnsureTrustedRosterForSync(reason)
    local _, _, summary = ensureLiveIndex(self, reason or "sync-index")
    return cloneTable(summary.rosterState)
end

function Data:BuildSyntheticContentKeys(profession)
    return buildContentKeysForProfession(profession)
end

function Data:BuildBlockContentKeys(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not ownerCharacter or not professionKey then
        return {}
    end
    local entry = self:GetMember(ownerCharacter)
    local profession = entry and entry.professions and entry.professions[professionKey] or nil
    return buildContentKeysForProfession(profession)
end

function Data:BuildBlockFingerprint(blockKey)
    local contentKeys = self:BuildBlockContentKeys(blockKey)
    return string.format("bf3:%d:%s", #contentKeys, buildFingerprint("bf3", table.concat(contentKeys, "|")))
end

function Data:BuildGlobalFingerprint(index)
    local blockKeys = cloneArray(index and index.blockKeys or {})
    local blocks = index and index.blocks or {}
    sortStrings(blockKeys)
    local parts = {}
    for _, blockKey in ipairs(blockKeys) do
        local block = blocks[blockKey]
        parts[#parts + 1] = string.format("%s=%s", tostring(blockKey), tostring(block and block.blockFingerprint or ""))
    end
    return string.format(
        "gf3:%d:%d:%d:%s",
        tonumber(index and index.activeOwnerCount or 0) or 0,
        #blockKeys,
        tonumber(index and index.activeContentCount or 0) or 0,
        buildFingerprint("gf3", table.concat(parts, "|"))
    )
end

function Data:BuildLocalSummary(opts)
    opts = opts or {}
    local state, _, summary = ensureLiveIndex(self, opts.reason or "summary")

    if summary.ready and not state.committedGlobalFingerprint then
        state.committedGlobalFingerprint = summary.globalFingerprint
        state.committedSummary = cloneTable(summary)
        state.lastCommittedAt = time()
        state.lastCommittedReason = "initial-summary"
    end

    local out = {
        syncModel = summary.syncModel,
        ready = summary.ready,
        indexStatus = summary.indexStatus,
        trustedRoster = summary.trustedRoster,
        trustedRosterReason = summary.trustedRosterReason,
        activeOwnerCount = summary.activeOwnerCount or 0,
        activeBlockCount = summary.activeBlockCount or 0,
        activeContentCount = summary.activeContentCount or 0,
        globalFingerprint = summary.globalFingerprint,
        globalFingerprintCommitted = state.committedGlobalFingerprint,
        globalFingerprintDirty = self:IsSyncIndexDirty(),
        professions = summary.activeBlockCount or 0,
        recipes = summary.activeContentCount or 0,
        memberKey = self:GetPlayerKey(),
        builtAt = summary.builtAt,
    }
    state.lastSummary = cloneTable(out)
    return out
end

function Data:CommitGlobalFingerprint(reason)
    local state, cache, summary = ensureLiveIndex(self, reason or "manual-commit")
    if summary.ready then
        state.committedGlobalFingerprint = summary.globalFingerprint
        state.committedSummary = cloneTable(summary)
        state.lastCommittedAt = time()
        state.lastCommittedReason = tostring(reason or "manual-commit")
        cache.dirtyAll = false
        cache.dirtyBlocks = {}
        cache.dirtyBlockCount = 0
        cache.globalDirty = false
        syncTelemetryStats(cache)
        bumpSyncTelemetry("globalFingerprintCommitted")
    end
    return state.committedGlobalFingerprint
end

function Data:GetLocalSummary()
    return self:BuildLocalSummary({
        reason = "local-summary",
    })
end

function Data:GetLiveSyncIndex(opts)
    local _, _, summary = ensureLiveIndex(self, opts and opts.reason or "live-index")
    return {
        syncModel = summary.syncModel,
        ready = summary.ready,
        indexStatus = summary.indexStatus,
        trustedRoster = summary.trustedRoster,
        trustedRosterReason = summary.trustedRosterReason,
        activeOwnerCount = summary.activeOwnerCount,
        activeBlockCount = summary.activeBlockCount,
        activeContentCount = summary.activeContentCount,
        globalFingerprint = summary.globalFingerprint,
        blocks = cloneTable(summary.blocks),
        blockKeys = cloneArray(summary.blockKeys),
        builtAt = summary.builtAt,
    }
end

function Data:BuildRequesterIndexDigest(opts)
    local _, _, index = ensureLiveIndex(self, opts and opts.reason or "requester-digest")
    local blocks = {}
    for _, blockKey in ipairs(index.blockKeys or {}) do
        local block = index.blocks and index.blocks[blockKey] or nil
        blocks[blockKey] = {
            count = tonumber(block and block.contentCount or 0) or 0,
            fingerprint = block and block.blockFingerprint or nil,
        }
    end
    return {
        syncModel = index.syncModel,
        indexStatus = index.indexStatus,
        ready = index.ready == true,
        activeOwnerCount = index.activeOwnerCount or 0,
        activeBlockCount = index.activeBlockCount or 0,
        activeContentCount = index.activeContentCount or 0,
        globalFingerprint = index.globalFingerprint,
        blocks = blocks,
    }
end

function Data:BuildIndexDiffResponse(requesterDigest, opts)
    local _, _, liveIndex = ensureLiveIndex(self, opts and opts.reason or "index-diff")
    local requesterBlocks = type(requesterDigest) == "table" and requesterDigest.blocks or {}
    local offered = {}

    for _, blockKey in ipairs(liveIndex.blockKeys or {}) do
        local localBlock = liveIndex.blocks and liveIndex.blocks[blockKey] or nil
        if localBlock then
            local remoteRow = requesterBlocks and requesterBlocks[blockKey] or nil
            local localCount = tonumber(localBlock.contentCount or 0) or 0
            local localFingerprint = localBlock.blockFingerprint
            local shouldOffer = false
            local reason = nil

            if not remoteRow then
                shouldOffer = true
                reason = "missing"
            else
                local remoteCount = tonumber(remoteRow.count or 0) or 0
                local remoteFingerprint = remoteRow.fingerprint
                if tostring(remoteFingerprint or "") ~= tostring(localFingerprint or "") then
                    if remoteCount <= localCount then
                        shouldOffer = true
                        reason = remoteCount == localCount and "count-match-fingerprint-mismatch"
                            or "requester-lower-count-fingerprint-mismatch"
                    else
                        reason = "requester-higher-count-fingerprint-mismatch"
                    end
                end
            end

            if shouldOffer then
                offered[#offered + 1] = {
                    blockKey = blockKey,
                    count = localCount,
                    fingerprint = localFingerprint,
                    reason = reason,
                }
            end
        end
    end

    sort(offered, function(left, right)
        if (left.count or 0) ~= (right.count or 0) then
            return (left.count or 0) > (right.count or 0)
        end
        return tostring(left.blockKey or "") < tostring(right.blockKey or "")
    end)

    return {
        syncModel = liveIndex.syncModel,
        indexStatus = liveIndex.indexStatus,
        ready = liveIndex.ready == true,
        offeredBlocks = offered,
    }
end

function Data:BuildBlockSnapshot(blockKey, opts)
    opts = opts or {}
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not ownerCharacter or not professionKey then
        return nil
    end
    local entry = self:GetMember(ownerCharacter)
    local profession = entry and entry.professions and entry.professions[professionKey] or nil
    if not entry or not profession then
        return nil
    end

    local recipeKeys = {}
    for recipeKey in pairs(profession.recipes or {}) do
        if isValidRecipeKey(recipeKey) then
            recipeKeys[#recipeKeys + 1] = tonumber(recipeKey) or recipeKey
        end
    end
    sort(recipeKeys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    return {
        blockKey = blockKey,
        ownerCharacter = ownerCharacter,
        professionKey = professionKey,
        recipeKeys = recipeKeys,
        specialization = profession.specialization,
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
        metadata = {
            ownerSourceType = entry.sourceType,
            professionSourceType = profession.sourceType,
            ownerUpdatedAt = entry.updatedAt,
            professionUpdatedAt = profession.lastUpdatedAt,
        },
        builtAt = time(),
        snapshotKind = opts.snapshotKind or "live-block",
    }
end

function Data:GetSyncIndexDebugState()
    local state, cache, summary = ensureLiveIndex(self, "sync-index-debug")
    return {
        dirty = self:IsSyncIndexDirty(),
        lastDirtyReason = state.lastDirtyReason,
        lastDirtyAt = state.lastDirtyAt or 0,
        lastClearedReason = state.lastClearedReason,
        lastClearedAt = state.lastClearedAt or 0,
        lastBuiltAt = summary and summary.builtAt or 0,
        lastBuildReason = cache.lastBuildReason,
        lastCommittedAt = state.lastCommittedAt or 0,
        lastCommittedReason = state.lastCommittedReason,
        trustedRoster = summary and summary.trustedRoster == true or false,
        trustedRosterReason = summary and summary.trustedRosterReason or "unknown",
        snapshotCount = summary and summary.rosterState and summary.rosterState.snapshotCount or 0,
        knownActive = summary and summary.rosterState and summary.rosterState.knownActive or 0,
        indexReady = summary and summary.ready == true or false,
        indexStatus = summary and summary.indexStatus or "unknown",
        activeOwnerCount = summary and summary.activeOwnerCount or 0,
        activeBlockCount = summary and summary.activeBlockCount or 0,
        activeContentCount = summary and summary.activeContentCount or 0,
        globalFingerprint = summary and summary.globalFingerprint or nil,
        committedGlobalFingerprint = state.committedGlobalFingerprint,
        globalFingerprintDirty = self:IsSyncIndexDirty(),
        syncModel = summary and summary.syncModel or SYNC_MODEL,
        memberCount = countKeys(self:GetMembersDB()),
        cache = {
            dirtyAll = cache.dirtyAll == true,
            dirtyBlockCount = cache.dirtyBlockCount or 0,
            builtAt = cache.builtAt or 0,
            lastBuildReason = cache.lastBuildReason,
            lastDirtyReason = cache.lastDirtyReason,
            lastDirtyAt = cache.lastDirtyAt or 0,
            stats = cloneTable(cache.stats or {}),
        },
    }
end

function Data:DumpSyncIndexStatus()
    local snapshot = self:GetSyncIndexDebugState()
    Addon:Print(string.format(
        "Sync index ready=%s status=%s owners=%d blocks=%d content=%d dirty=%s committed=%s hits=%d misses=%d blockRebuilt=%d fullRebuild=%d globalRecomputed=%d",
        tostring(snapshot.indexReady == true),
        tostring(snapshot.indexStatus or "unknown"),
        tonumber(snapshot.activeOwnerCount or 0) or 0,
        tonumber(snapshot.activeBlockCount or 0) or 0,
        tonumber(snapshot.activeContentCount or 0) or 0,
        tostring(snapshot.globalFingerprintDirty == true),
        tostring(snapshot.committedGlobalFingerprint or "none"),
        snapshot.cache.stats.hits or 0,
        snapshot.cache.stats.misses or 0,
        snapshot.cache.stats.blockRebuilt or 0,
        snapshot.cache.stats.fullRebuild or 0,
        snapshot.cache.stats.globalRecomputed or 0
    ))
end
