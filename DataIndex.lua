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

local function cloneSummary(summary)
    if type(summary) ~= "table" then
        return nil
    end
    local out = {}
    for key, value in pairs(summary) do
        if type(value) == "table" then
            local nested = {}
            for nestedKey, nestedValue in pairs(value) do
                nested[nestedKey] = nestedValue
            end
            out[key] = nested
        else
            out[key] = value
        end
    end
    return out
end

local function countKeys(tbl)
    local total = 0
    for _ in pairs(tbl or {}) do
        total = total + 1
    end
    return total
end

local function sortStrings(values)
    sort(values, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return values
end

local function ensureSyncIndexState(self)
    self._syncIndexState = self._syncIndexState or {
        dirty = false,
        lastDirtyReason = nil,
        lastDirtyAt = 0,
        lastClearedReason = nil,
        lastClearedAt = 0,
        lastBuiltAt = 0,
        lastBuildReason = nil,
        lastRosterState = nil,
        lastSummary = nil,
        committedSummary = nil,
        committedGlobalFingerprint = nil,
        lastCommittedAt = 0,
        lastCommittedReason = nil,
        lastDiffDigest = nil,
        lastDiffDigestAt = 0,
        lastLiveIndex = nil,
    }
    return self._syncIndexState
end

local function bumpSyncTelemetry(counter)
    local sync = Addon.Sync
    if not (sync and sync.telemetry) then
        return
    end
    sync.telemetry[counter] = (sync.telemetry[counter] or 0) + 1
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

local function buildFingerprint(prefix, contentKeys)
    local keys = cloneArray(contentKeys)
    sortStrings(keys)
    return string.format("%s:%d:%s", prefix, #keys, table.concat(keys, "|"))
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

local function isOutboundSessionActive()
    local sync = Addon.Sync
    local session = sync and sync.outboundSeedSession or nil
    if type(session) ~= "table" then
        return false
    end
    local state = tostring(session.state or "")
    return state ~= "" and state ~= "completed" and state ~= "aborted" and state ~= "idle"
end

local function buildLiveIndex(self, opts)
    opts = opts or {}
    local rosterState = buildRosterState(self, opts.reason or "sync-index")
    local memberKeys = self:GetSortedMemberKeys(true)
    local selfKey = self:GetPlayerKey()
    local blocks = {}
    local blockKeys = {}
    local activeOwnerCount = 0
    local activeContentCount = 0

    for _, memberKey in ipairs(memberKeys) do
        local entry = self:GetMember(memberKey)
        if shouldPublishOwner(self, rosterState, memberKey, entry, selfKey) then
            local ownerBlockCount = 0
            local professionKeys = {}
            for professionKey in pairs(entry.professions or {}) do
                professionKeys[#professionKeys + 1] = professionKey
            end
            sortStrings(professionKeys)

            for _, professionKey in ipairs(professionKeys) do
                local profession = entry.professions and entry.professions[professionKey] or nil
                local contentKeys = buildContentKeysForProfession(profession)
                if #contentKeys > 0 then
                    local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
                    if blockKey then
                        local blockFingerprint = buildFingerprint("bf1", contentKeys)
                        blocks[blockKey] = {
                            blockKey = blockKey,
                            ownerCharacter = memberKey,
                            professionKey = professionKey,
                            contentKeys = contentKeys,
                            blockFingerprint = blockFingerprint,
                            contentCount = #contentKeys,
                        }
                        blockKeys[#blockKeys + 1] = blockKey
                        activeContentCount = activeContentCount + #contentKeys
                        ownerBlockCount = ownerBlockCount + 1
                    end
                end
            end

            if ownerBlockCount > 0 then
                activeOwnerCount = activeOwnerCount + 1
            end
        end
    end

    sortStrings(blockKeys)

    local globalParts = {}
    for _, blockKey in ipairs(blockKeys) do
        local block = blocks[blockKey]
        globalParts[#globalParts + 1] = string.format("%s=%s", tostring(blockKey), tostring(block and block.blockFingerprint or ""))
    end

    return {
        syncModel = SYNC_MODEL,
        ready = rosterState.trusted == true,
        indexStatus = rosterState.trusted == true and "ready" or tostring(rosterState.reason or "not-ready"),
        trustedRoster = rosterState.trusted == true,
        trustedRosterReason = rosterState.reason,
        activeOwnerCount = activeOwnerCount,
        activeBlockCount = #blockKeys,
        activeContentCount = activeContentCount,
        globalFingerprint = string.format(
            "gf1:%d:%d:%d:%s",
            activeOwnerCount,
            #blockKeys,
            activeContentCount,
            table.concat(globalParts, "|")
        ),
        blocks = blocks,
        blockKeys = blockKeys,
        rosterState = rosterState,
        builtAt = time(),
    }
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
    local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
    if not blockKey then
        return nil
    end
    local entry = self:GetMember(memberKey)
    local profession = entry and entry.professions and entry.professions[professionKey] or nil
    if not entry or not profession then
        return nil
    end
    local contentKeys = buildContentKeysForProfession(profession)
    return {
        blockKey = blockKey,
        ownerCharacter = memberKey,
        professionKey = professionKey,
        contentKeys = contentKeys,
        count = #contentKeys,
        fingerprint = buildFingerprint("bf1", contentKeys),
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
        specialization = profession.specialization,
        sourceType = profession.sourceType or entry.sourceType or self:GetMemberSourceType(memberKey),
        guildStatus = profession.guildStatus or entry.guildStatus or "active",
        lastSeenInGuildAt = profession.lastSeenInGuildAt or entry.lastSeenInGuildAt or 0,
    }
end

local function buildDigestRows(index)
    local rows = {}
    for _, blockKey in ipairs(index and index.blockKeys or {}) do
        local block = index and index.blocks and index.blocks[blockKey] or nil
        rows[#rows + 1] = {
            blockKey = blockKey,
            count = tonumber(block and block.contentCount or 0) or 0,
            fingerprint = block and block.blockFingerprint or nil,
        }
    end
    return rows
end

local function cloneDigestRows(rows)
    local out = {}
    for index = 1, #(rows or {}) do
        local row = rows[index]
        out[index] = {
            blockKey = row and row.blockKey or nil,
            count = tonumber(row and row.count or 0) or 0,
            fingerprint = row and row.fingerprint or nil,
        }
    end
    return out
end

function Data:MarkSyncIndexDirty(reason)
    local state = ensureSyncIndexState(self)
    local wasDirty = state.dirty == true
    state.dirty = true
    state.lastDirtyReason = tostring(reason or "unspecified")
    state.lastDirtyAt = time()
    if not wasDirty then
        bumpSyncTelemetry("globalFingerprintDirty")
    end
    return true
end

function Data:IsSyncIndexDirty()
    local state = ensureSyncIndexState(self)
    return state.dirty == true
end

function Data:ClearSyncIndexDirty(reason)
    local state = ensureSyncIndexState(self)
    state.dirty = false
    state.lastClearedReason = tostring(reason or "unspecified")
    state.lastClearedAt = time()
    return true
end

function Data:GetRosterTrustState()
    local state = ensureSyncIndexState(self)
    if type(state.lastRosterState) ~= "table" then
        state.lastRosterState = buildRosterState(self, "sync-index-debug")
    end
    return cloneSummary(state.lastRosterState)
end

function Data:EnsureTrustedRosterForSync(reason)
    local state = ensureSyncIndexState(self)
    state.lastRosterState = buildRosterState(self, reason or "sync-index")
    return cloneSummary(state.lastRosterState)
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
    return buildFingerprint("bf1", contentKeys)
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
        "gf1:%d:%d:%d:%s",
        tonumber(index and index.activeOwnerCount or 0) or 0,
        #blockKeys,
        tonumber(index and index.activeContentCount or 0) or 0,
        table.concat(parts, "|")
    )
end

function Data:BuildLocalSummary(opts)
    opts = opts or {}
    local state = ensureSyncIndexState(self)
    local summary = buildLiveIndex(self, opts)

    summary.globalFingerprint = self:BuildGlobalFingerprint(summary)
    state.lastBuiltAt = summary.builtAt or time()
    state.lastBuildReason = tostring(opts.reason or "summary")
    state.lastRosterState = cloneSummary(summary.rosterState)
    state.lastSummary = cloneSummary(summary)
    state.lastLiveIndex = cloneSummary(summary)

    if summary.ready then
        local changed = state.dirty == true
            or state.committedGlobalFingerprint ~= summary.globalFingerprint
            or type(state.committedSummary) ~= "table"
        if changed and not isOutboundSessionActive() then
            state.committedGlobalFingerprint = summary.globalFingerprint
            state.committedSummary = cloneSummary(summary)
            state.lastCommittedAt = time()
            state.lastCommittedReason = tostring(opts.reason or "summary")
            self:ClearSyncIndexDirty("commit:" .. tostring(opts.reason or "summary"))
            bumpSyncTelemetry("globalFingerprintCommitted")
        end
    end

    summary.globalFingerprintCommitted = state.committedGlobalFingerprint
    summary.globalFingerprintDirty = state.dirty == true
    summary.professions = summary.activeBlockCount
    summary.recipes = summary.activeContentCount
    summary.memberKey = self:GetPlayerKey()
    summary.blocks = nil
    summary.blockKeys = nil
    summary.rosterState = nil
    return summary
end

function Data:CommitGlobalFingerprint(reason)
    local state = ensureSyncIndexState(self)
    local summary = buildLiveIndex(self, {
        reason = reason or "manual-commit",
    })
    summary.globalFingerprint = self:BuildGlobalFingerprint(summary)
    state.lastBuiltAt = summary.builtAt or time()
    state.lastBuildReason = tostring(reason or "manual-commit")
    state.lastRosterState = cloneSummary(summary.rosterState)
    state.lastSummary = cloneSummary(summary)
    state.lastLiveIndex = cloneSummary(summary)
    if summary.ready then
        state.committedGlobalFingerprint = summary.globalFingerprint
        state.committedSummary = cloneSummary(summary)
        state.lastCommittedAt = time()
        state.lastCommittedReason = tostring(reason or "manual-commit")
        self:ClearSyncIndexDirty("commit:" .. tostring(reason or "manual-commit"))
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
    local state = ensureSyncIndexState(self)
    local index = buildLiveIndex(self, opts or {})
    index.globalFingerprint = self:BuildGlobalFingerprint(index)
    state.lastLiveIndex = cloneSummary(index)
    return index
end

function Data:BuildRequesterIndexDigest(opts)
    local state = ensureSyncIndexState(self)
    local index = self:GetLiveSyncIndex(opts or {})
    local digest = {
        syncModel = index.syncModel,
        indexStatus = index.indexStatus,
        ready = index.ready == true,
        activeOwnerCount = index.activeOwnerCount or 0,
        activeBlockCount = index.activeBlockCount or 0,
        activeContentCount = index.activeContentCount or 0,
        globalFingerprint = index.globalFingerprint,
        rows = buildDigestRows(index),
    }
    state.lastDiffDigest = {
        syncModel = digest.syncModel,
        indexStatus = digest.indexStatus,
        ready = digest.ready,
        activeOwnerCount = digest.activeOwnerCount,
        activeBlockCount = digest.activeBlockCount,
        activeContentCount = digest.activeContentCount,
        globalFingerprint = digest.globalFingerprint,
        rows = cloneDigestRows(digest.rows),
    }
    state.lastDiffDigestAt = time()
    return digest
end

function Data:BuildIndexDiffResponse(requesterDigest, opts)
    opts = opts or {}
    local liveIndex = self:GetLiveSyncIndex({
        reason = opts.reason or "index-diff",
    })
    local requesterRows = {}
    for _, row in ipairs(type(requesterDigest) == "table" and requesterDigest.rows or {}) do
        if type(row) == "table" and type(row.blockKey) == "string" and row.blockKey ~= "" then
            requesterRows[row.blockKey] = {
                count = tonumber(row.count or 0) or 0,
                fingerprint = row.fingerprint,
            }
        end
    end

    local offered = {}
    for _, blockKey in ipairs(liveIndex.blockKeys or {}) do
        local localBlock = liveIndex.blocks and liveIndex.blocks[blockKey] or nil
        if localBlock then
            local remoteRow = requesterRows[blockKey]
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
        activeOwnerCount = liveIndex.activeOwnerCount or 0,
        activeBlockCount = liveIndex.activeBlockCount or 0,
        activeContentCount = liveIndex.activeContentCount or 0,
        globalFingerprint = liveIndex.globalFingerprint,
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
        contentCount = #self:BuildBlockContentKeys(blockKey),
        fingerprint = self:BuildBlockFingerprint(blockKey),
        builtAt = time(),
        snapshotKind = opts.snapshotKind or "live-block",
    }
end

function Data:GetSyncIndexDebugState()
    local state = ensureSyncIndexState(self)
    local summary = state.lastSummary or self:BuildLocalSummary({
        reason = "sync-index-debug",
    })
    local rosterState = state.lastRosterState or {}
    return {
        dirty = state.dirty == true,
        lastDirtyReason = state.lastDirtyReason,
        lastDirtyAt = state.lastDirtyAt or 0,
        lastClearedReason = state.lastClearedReason,
        lastClearedAt = state.lastClearedAt or 0,
        lastBuiltAt = state.lastBuiltAt or 0,
        lastBuildReason = state.lastBuildReason,
        lastCommittedAt = state.lastCommittedAt or 0,
        lastCommittedReason = state.lastCommittedReason,
        trustedRoster = rosterState.trusted == true,
        trustedRosterReason = rosterState.reason,
        snapshotCount = tonumber(rosterState.snapshotCount or 0) or 0,
        knownActive = tonumber(rosterState.knownActive or 0) or 0,
        indexReady = summary and summary.ready == true or false,
        indexStatus = summary and summary.indexStatus or "unknown",
        activeOwnerCount = summary and summary.activeOwnerCount or 0,
        activeBlockCount = summary and summary.activeBlockCount or 0,
        activeContentCount = summary and summary.activeContentCount or 0,
        globalFingerprint = summary and summary.globalFingerprint or nil,
        committedGlobalFingerprint = state.committedGlobalFingerprint,
        globalFingerprintDirty = state.dirty == true,
        syncModel = summary and summary.syncModel or SYNC_MODEL,
        memberCount = countKeys(self:GetMembersDB()),
    }
end

function Data:MarkManifestDirty(_blockKey, reason)
    return self:MarkSyncIndexDirty(reason or "legacy-manifest-dirty")
end

function Data:MarkManifestMemberDirty(_memberKey, _entry, reason)
    return self:MarkSyncIndexDirty(reason or "legacy-manifest-member-dirty")
end

function Data:BuildManifestCacheNow(reason)
    self:BuildLocalSummary({
        reason = reason or "legacy-manifest-build",
    })
    return {
        memberKey = self:GetPlayerKey(),
        builtAt = time(),
        totals = {
            blocks = 0,
            recipes = 0,
        },
        blocks = {},
    }
end

function Data:GetPreparedSyncManifest(_opts)
    return self:BuildManifestCacheNow("legacy-manifest-prepared"), "deprecated-noop"
end

function Data:GetManifestDebugSnapshot()
    local debugState = self:GetSyncIndexDebugState()
    return {
        ready = debugState.indexReady == true,
        hasManifest = false,
        dirtyAll = debugState.globalFingerprintDirty == true,
        dirtyBlocks = 0,
        building = false,
        scheduled = false,
        serial = 0,
        blocks = debugState.activeBlockCount or 0,
        recipes = debugState.activeContentCount or 0,
        telemetry = {
            syncFallbackBuilds = 0,
            syncFallbackDeferrals = 0,
            deferredRequests = 0,
        },
    }
end

function Data:DumpManifestCacheStatus()
    Addon:Print("Manifest cache was removed. Use /rr sync for index-diff diagnostics.")
end

function Data:ResetManifestTelemetry()
    return true
end

function Data:DumpManifestSummary(_opts)
    local summary = self:BuildLocalSummary({
        reason = "legacy-manifest-summary",
    })
    Addon:Print(string.format(
        "Local summary ready=%s owners=%d blocks=%d content=%d fingerprint=%s",
        tostring(summary.ready == true),
        tonumber(summary.activeOwnerCount or 0) or 0,
        tonumber(summary.activeBlockCount or 0) or 0,
        tonumber(summary.activeContentCount or 0) or 0,
        tostring(summary.globalFingerprint or "none")
    ))
end
