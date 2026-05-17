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
local stableRecipeSignature = Private.stableRecipeSignature

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
                    "Removed corrupt recipe",
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

            local actualSignature = stableRecipeSignature(recipesForStats)
            if prof.signature ~= actualSignature then
                stats.repairedSignatures = stats.repairedSignatures + 1
                blockDirty = true
                if not dryRun then
                    prof.signature = actualSignature
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
            for _blockKey in pairs(dirtyBlocks or {}) do
                data:MarkSyncIndexDirty(reason or "clean-corrupt")
                break
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

    if opts.checkProfessionMismatches == false then
        return false
    end

    local actualProfession = self:ResolveRecipeProfession(recipeKey)
    local expectedProfession = type(profName) == "string" and self:GetCanonicalProfession(profName) or nil
    if actualProfession and expectedProfession and actualProfession ~= expectedProfession then
        return true, "profession-mismatch", actualProfession
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
    Addon:Print("Database wiped. AtlasLoot lookups stay available; sync cache is clean and a fresh guild resync was requested.")
    Addon:RequestRefresh("wipe")
end
