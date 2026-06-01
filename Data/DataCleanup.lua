local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort

local cloneTableShallow = Private.cloneTableShallow
local countRecipeKeys = Private.countRecipeKeys
local isValidRecipeKey = Private.isValidRecipeKey

-- Returns true only when the recipe key resolves to a spell or item known to
-- the WoW client. Used by the auto-clean pass to drop entries left behind by
-- mock harnesses or older addon versions that no longer correspond to a real
-- in-game spell/item. GetItemInfoInstant is the synchronous local DB lookup
-- (returns nil for invalid item IDs without any server round-trip); the
-- spell-side check goes through GetSpellInfo which returns nil for unknown
-- spell IDs.
local function isRecipeKeyResolvableInClient(recipeKey)
    local numeric = tonumber(recipeKey)
    -- Non-numeric keys can't be classified against the WoW spell/item DB at
    -- all. They shouldn't appear in production (real recipe keys are
    -- positive item IDs or negative spell IDs) but a few synthetic strings
    -- exist in unit specs and pre-rewrite favourites data. Treat them as
    -- "unknown but harmless" rather than poisoning UI/sync paths with a
    -- categorical false negative.
    if not numeric then return true end
    if numeric < 0 then
        return type(GetSpellInfo) == "function" and GetSpellInfo(-numeric) ~= nil
    end
    if numeric > 0 then
        if type(GetItemInfoInstant) == "function" then
            return GetItemInfoInstant(numeric) ~= nil
        end
        return type(GetItemInfo) == "function" and GetItemInfo(numeric) ~= nil
    end
    return false
end

-- Public accessor so the UI predicate and sync producer/consumer can share
-- the same "is this key a real spell or item in the WoW client" check used
-- by the auto-clean pass.
function Data:IsRecipeKeyResolvableInClient(recipeKey)
    return isRecipeKeyResolvableInClient(recipeKey)
end

-- Stricter than IsRecipeKeyResolvableInClient: a key is "catalogued" only
-- when the metadata library actually maps it to a recipe. Catches real
-- items that aren't recipes — e.g. Worn Axe (item 2196 is a valid item
-- so GetItemInfoInstant returns non-nil, but no recipe spell maps to it).
-- Used by /rr clean and by the sync garbage gate; auto-clean stays
-- conservative because metadata may not be loaded yet at warmup.
local function isRecipeKeyCatalogued(metadata, recipeKey)
    if not metadata then return true end
    local numeric = tonumber(recipeKey)
    if not numeric then return true end  -- non-numeric: can't classify
    if numeric < 0 then
        local records = metadata._recordsBySpellId
        return records and records[-numeric] ~= nil
    end
    if numeric > 0 then
        local generated = metadata._generated
        if not generated then return true end
        if generated.recipeItemToSpellId and generated.recipeItemToSpellId[numeric] then
            return true
        end
        if generated.createdItemToSpellIds and generated.createdItemToSpellIds[numeric] then
            return true
        end
        return false
    end
    return false
end

-- Returns a set of every profession the metadata library can map the
-- given recipe key to. Positive item keys can resolve to two professions
-- when an item is both crafted by one recipe and teaches another (e.g.
-- item 10644: engineering-crafted Goblin Mortar that teaches an alchemy
-- recipe). Negative spell keys resolve to a single profession. Returns
-- nil when metadata can't classify the key at all.
local function collectRecipeKeyProfessions(metadata, recipeKey)
    if not metadata then return nil end
    local numeric = tonumber(recipeKey)
    if not numeric then return nil end
    local set
    local function addProfession(spellId)
        if not spellId then return end
        local records = metadata._recordsBySpellId
        local record = records and records[spellId]
        local profession = record and record.profession
        if profession and profession ~= "" then
            set = set or {}
            set[profession] = true
        end
    end
    if numeric < 0 then
        addProfession(-numeric)
        return set
    end
    if numeric > 0 then
        local generated = metadata._generated
        if generated then
            local viaRecipeItem = generated.recipeItemToSpellId and generated.recipeItemToSpellId[numeric]
            if viaRecipeItem then addProfession(viaRecipeItem) end
            local viaCreatedItem = generated.createdItemToSpellIds and generated.createdItemToSpellIds[numeric]
            if type(viaCreatedItem) == "table" then
                for i = 1, #viaCreatedItem do
                    addProfession(viaCreatedItem[i])
                end
            end
        end
        return set
    end
    return nil
end

-- Public accessor for sync gates and tooltip garbage filter. Returns true
-- when metadata isn't loaded yet, so callers don't reject good data during
-- warmup before the library has populated its lookup tables. Also returns
-- true when the test harness has asked to bypass the strict check (many
-- specs seed synthetic positive recipe keys that aren't in production
-- metadata; the bypass keeps them passing without weakening the gate).
function Data:IsRecipeKeyCatalogued(recipeKey)
    if _G._RR_TEST_HARNESS_BYPASS_CATALOGUE_GATE then
        return true
    end
    local metadata = Addon and Addon.RecipeMetadata
    if not metadata or not metadata.metadataVersion then
        return true
    end
    return isRecipeKeyCatalogued(metadata, recipeKey)
end

local function newCorruptCleanStats()
    return {
        removedMembers = 0,
        removedProfessions = 0,
        removedRecipes = 0,
        invalidRecipes = 0,
        mismatchedRecipes = 0,
        repairedBlocks = 0,
        repairedCounts = 0,
        repairedSignatures = 0,
        lastRecipeKey = nil,
        lastMemberKey = nil,
        lastProfession = nil,
        lastReason = nil,
        lastActualProfession = nil,
    }
end

local function hasCorruptCleanChanges(stats)
    return (stats.removedMembers or 0) > 0
        or (stats.removedProfessions or 0) > 0
        or (stats.removedRecipes or 0) > 0
        or (stats.repairedBlocks or 0) > 0
end

local function cleanCorruptMember(data, memberKey, entry, opts, stats, dirtyBlocks)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local dirtyAll = false

    if not data:IsValidMemberKey(memberKey) or type(entry) ~= "table" then
        stats.removedMembers = stats.removedMembers + 1
        dirtyAll = true
        if not dryRun then
            data.db.global.members[memberKey] = nil
        end
        return dirtyAll
    end

    if type(entry.professions) ~= "table" then
        stats.repairedBlocks = stats.repairedBlocks + 1
        dirtyAll = true
        if not dryRun then
            entry.professions = {}
        end
    end

    for profName, prof in pairs(entry.professions or {}) do
        local removeProfession = type(profName) ~= "string"
            or profName == ""
            or profName:find(":", 1, true) ~= nil
            or type(prof) ~= "table"

        if removeProfession then
            stats.removedProfessions = stats.removedProfessions + 1
            dirtyAll = true
            if not dryRun then
                entry.professions[profName] = nil
            end
        else
            local blockDirty = false
            if type(prof.recipes) ~= "table" then
                blockDirty = true
                if not dryRun then
                    prof.recipes = {}
                end
            end

            local recipeTable = type(prof.recipes) == "table" and prof.recipes or {}
            local toRemove = {}
            for recipeKey in pairs(recipeTable) do
                local shouldRemove, reason, actualProfession = data:ShouldCleanRecipeFromProfession(profName, recipeKey, opts)
                if shouldRemove then
                    toRemove[#toRemove + 1] = {
                        key = recipeKey,
                        reason = reason,
                        actualProfession = actualProfession,
                    }
                    stats.removedRecipes = stats.removedRecipes + 1
                    if reason == "profession-mismatch" then
                        stats.mismatchedRecipes = stats.mismatchedRecipes + 1
                    else
                        stats.invalidRecipes = stats.invalidRecipes + 1
                    end
                    stats.lastRecipeKey = recipeKey
                    stats.lastMemberKey = memberKey
                    stats.lastProfession = profName
                    stats.lastReason = reason
                    stats.lastActualProfession = actualProfession
                end
            end

            for _, removal in ipairs(toRemove) do
                if not dryRun then
                    prof.recipes[removal.key] = nil
                    data:RecordInvalidRecipeKey(removal.key, "clean", memberKey, profName)
                end
                blockDirty = true
                Addon:Debug(
                    dryRun and "Would remove corrupt recipe" or "Removed corrupt recipe",
                    tostring(removal.key),
                    "from",
                    memberKey,
                    profName,
                    removal.reason or "unknown",
                    removal.actualProfession or ""
                )
            end

            local recipesForStats = type(prof.recipes) == "table" and prof.recipes or {}
            if dryRun and #toRemove > 0 then
                recipesForStats = cloneTableShallow(recipesForStats)
                for _, removal in ipairs(toRemove) do
                    recipesForStats[removal.key] = nil
                end
            end
            local actualCount = countRecipeKeys(recipesForStats)
            if prof.count ~= actualCount then
                stats.repairedCounts = stats.repairedCounts + 1
                blockDirty = true
                if not dryRun then
                    prof.count = actualCount
                end
            end

            -- `prof.signature` is a legacy field; if leftover from older
            -- saves, strip it so the entry is canonical on next write.
            if prof.signature ~= nil then
                stats.repairedSignatures = stats.repairedSignatures + 1
                blockDirty = true
                if not dryRun then
                    prof.signature = nil
                end
            end

            if blockDirty then
                stats.repairedBlocks = stats.repairedBlocks + 1
                local blockKey = data:BuildSyncBlockKey(memberKey, profName)
                if blockKey then
                    dirtyBlocks[blockKey] = true
                else
                    dirtyAll = true
                end
            end
        end
    end

    return dirtyAll
end

local function commitCorruptClean(data, stats, dirtyAll, dirtyBlocks, reason)
    if not hasCorruptCleanChanges(stats) then return false end
    if data.MarkSyncIndexDirty then
        if dirtyAll then
            data:MarkSyncIndexDirty(reason or "clean-corrupt")
        else
            for blockKey in pairs(dirtyBlocks or {}) do
                data:MarkSyncIndexDirty(reason or "clean-corrupt", blockKey)
            end
        end
    end
    data:InvalidateRecipeCaches()
    Addon:RequestRefresh(reason or "clean")
    return true
end

function Data:ShouldCleanRecipeFromProfession(profName, recipeKey, opts)
    opts = opts or {}
    if not isValidRecipeKey(recipeKey) then
        return true, "invalid-key"
    end

    -- Drop ghost recipe keys left over from old mocks or aborted scans whose
    -- IDs the WoW client doesn't know about. Skipped when no real WoW API is
    -- available (specs run under the harness which doesn't stub these), so
    -- unit tests with synthetic keys keep working.
    if opts.checkClientResolvable
        and type(GetSpellInfo) == "function"
        and (type(GetItemInfoInstant) == "function" or type(GetItemInfo) == "function")
    then
        if not isRecipeKeyResolvableInClient(recipeKey) then
            return true, "not-in-client"
        end
    end

    -- Stricter, opt-in via /rr clean: drop keys the metadata library doesn't
    -- map to any recipe. Catches real items that aren't recipes (Worn Axe
    -- and friends), which the resolvable-in-client check lets through
    -- because they're valid WoW items. Auto-clean doesn't pass this flag
    -- because metadata might not be ready 8s after login.
    if opts.checkMetadataCatalogued then
        local metadata = Addon and Addon.RecipeMetadata
        if metadata and metadata.metadataVersion
            and not isRecipeKeyCatalogued(metadata, recipeKey)
        then
            return true, "not-in-metadata"
        end
    end

    if opts.checkProfessionMismatches == false then
        return false
    end

    -- Cross-check the recipe's declared profession against where the entry
    -- actually lives in our DB. Positive item keys can legitimately tie to
    -- TWO professions: e.g. item 10644 is both the engineering-crafted
    -- Goblin Mortar AND the recipe-teaching item for the alchemy spell
    -- that uses it. Both stores are correct — collect every profession
    -- the metadata maps the key to, and only flag a mismatch when none
    -- of them match the storage profession.
    local metadata = Addon and Addon.RecipeMetadata
    local actualProfessions = collectRecipeKeyProfessions(metadata, recipeKey)
    local expectedProfession = type(profName) == "string"
        and self:GetCanonicalProfession(profName)
        or nil
    if actualProfessions and expectedProfession then
        local normalizedExpected = expectedProfession
        if type(normalizedExpected) == "string" then
            normalizedExpected = normalizedExpected:lower()
        end
        if not actualProfessions[normalizedExpected] then
            -- Pick a single representative for the diagnostic
            local representative
            for prof in pairs(actualProfessions) do
                representative = prof
                break
            end
            return true, "profession-mismatch", representative
        end
    end
    return false
end

function Data:CleanCorruptData(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local stats = newCorruptCleanStats()
    local dirtyAll = false
    local dirtyBlocks = {}

    for memberKey, entry in pairs(self:GetMembersDB()) do
        dirtyAll = cleanCorruptMember(self, memberKey, entry, opts, stats, dirtyBlocks) or dirtyAll
    end

    if not dryRun then
        commitCorruptClean(self, stats, dirtyAll, dirtyBlocks, "clean-corrupt")
    end

    return stats
end

function Data:ScheduleSafeAutoClean(opts)
    if self._safeAutoCleanScheduled or self._safeAutoCleanCompleted then
        return false
    end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        return false
    end

    opts = opts or {}
    self._safeAutoCleanScheduled = true
    local memberKeys = {}
    for memberKey in pairs(self:GetMembersDB()) do
        memberKeys[#memberKeys + 1] = memberKey
    end
    sort(memberKeys)

    Addon.Performance:ScheduleJob("safe-auto-clean", function(state)
        state.index = state.index or 1
        state.memberKeys = state.memberKeys or memberKeys
        state.stats = state.stats or newCorruptCleanStats()
        state.dirtyBlocks = state.dirtyBlocks or {}
        state.dirtyAll = state.dirtyAll == true

        local processed = 0
        local maxMembersPerStep = opts.maxMembersPerStep or 8
        while processed < maxMembersPerStep do
            local memberKey = state.memberKeys[state.index]
            if not memberKey then
                self._safeAutoCleanCompleted = true
                self._safeAutoCleanScheduled = false
                local syncStats = Addon.Sync and Addon.Sync.CleanCorruptState
                    and Addon.Sync:CleanCorruptState({ dryRun = false })
                    or nil
                state.syncRemoved = syncStats and syncStats.removed or 0
                commitCorruptClean(self, state.stats, state.dirtyAll, state.dirtyBlocks, "auto-clean")
                if hasCorruptCleanChanges(state.stats) or (state.syncRemoved or 0) > 0 then
                    Addon:SystemPrint(string.format(
                        "Auto-clean repaired saved data: members=%d professions=%d recipes=%d repaired=%d sync=%d.",
                        state.stats.removedMembers or 0,
                        state.stats.removedProfessions or 0,
                        state.stats.removedRecipes or 0,
                        (state.stats.repairedBlocks or 0) + (state.stats.repairedCounts or 0) + (state.stats.repairedSignatures or 0),
                        state.syncRemoved or 0
                    ))
                end
                return false, state
            end

            state.dirtyAll = cleanCorruptMember(self, memberKey, self:GetMember(memberKey), {
                checkProfessionMismatches = false,
                checkClientResolvable = true,
            }, state.stats, state.dirtyBlocks) or state.dirtyAll
            state.index = state.index + 1
            processed = processed + 1
        end
        return true, state
    end, {
        category = "maintenance",
        label = "safe-auto-clean",
        budgetMs = 1,
        maxStepsPerRun = 1,
        state = {
            memberKeys = memberKeys,
            index = 1,
            stats = newCorruptCleanStats(),
            dirtyBlocks = {},
            dirtyAll = false,
        },
    })

    return true
end

function Data:CleanInvalidRecipes()
    local stats = self:CleanCorruptData({ checkProfessionMismatches = false })
    return stats.removedRecipes or 0
end

function Data:WipeDatabase()
    local members = self:GetMembersDB()
    for key in pairs(members) do
        members[key] = nil
    end
    self._incoming = {}
    self._currentProfs = {}
    self:GetGlobalMeta().bootstrapCompletedAt = 0
    if self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty("wipe")
    end

    if Addon.Sync then
        Addon.Sync:ResetRuntimeStateForDatabaseWipe()
    end

    self:InvalidateRecipeCaches()
    self:DetectProfessions()
    if Addon.Sync then
        Addon.Sync:KickoffDatabaseResync()
    end
    Addon:Print("Database wiped. Metadata lookups stay available; sync cache is clean and a fresh guild resync was requested.")
    Addon:RequestRefresh("wipe")
end
