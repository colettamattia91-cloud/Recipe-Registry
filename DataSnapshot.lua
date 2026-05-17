local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local sort = table.sort
local tostring = tostring

local countRecipeKeys = Private.countRecipeKeys
local stableRecipeSignature = Private.stableRecipeSignature
local isValidRecipeKey = Private.isValidRecipeKey

local function sortedRecipeKeys(recipes)
    local keys = {}
    for recipeKey in pairs(recipes or {}) do
        if isValidRecipeKey(recipeKey) then
            keys[#keys + 1] = tonumber(recipeKey) or recipeKey
        end
    end
    sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return keys
end

function Data:GetLocalSummary()
    if self.BuildLocalSummary then
        return self:BuildLocalSummary({
            reason = "local-summary",
        })
    end
    return {
        memberKey = self:GetPlayerKey(),
        professions = 0,
        recipes = 0,
    }
end

function Data:BuildSnapshotChunks(memberKey, opts)
    opts = opts or {}
    local requestedBlocks = {}
    for _, blockKey in ipairs(opts.requestedBlocks or {}) do
        requestedBlocks[#requestedBlocks + 1] = blockKey
    end
    sort(requestedBlocks)

    if #requestedBlocks == 0 then
        local entry = self:GetMember(memberKey)
        for professionKey in pairs(entry and entry.professions or {}) do
            local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
            if blockKey then
                requestedBlocks[#requestedBlocks + 1] = blockKey
            end
        end
        sort(requestedBlocks)
    end

    local chunks = {}
    for index = 1, #requestedBlocks do
        local snapshot = self.BuildBlockSnapshot and self:BuildBlockSnapshot(requestedBlocks[index], {
            snapshotKind = "legacy-compat",
        }) or nil
        if snapshot then
            chunks[#chunks + 1] = snapshot
        end
    end
    return chunks
end

function Data:BeginIncomingSnapshot(_memberKey, _legacyVersion, _updatedAt)
    return true
end

function Data:AppendIncomingChunk(_chunk)
    return true
end

function Data:FinalizeIncomingSnapshot(_memberKey, _legacyVersion, _opts)
    return false
end

function Data:ApplyIncomingBlockAdditive(blockKey, snapshot, opts)
    opts = opts or {}
    local normalized = Addon.MergeEngine and Addon.MergeEngine.NormalizeIncomingBlockPayload
        and Addon.MergeEngine:NormalizeIncomingBlockPayload(snapshot)
        or nil
    if not normalized or normalized.blockKey ~= blockKey then
        return false, "invalid-block-snapshot"
    end

    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not ownerCharacter or not professionKey then
        return false, "invalid-block-key"
    end

    local entry = self:GetOrCreateMember(ownerCharacter)
    local currentProf = entry.professions and entry.professions[professionKey] or nil
    local localBlock = {
        recipes = currentProf and currentProf.recipes or {},
        specialization = currentProf and currentProf.specialization or nil,
        metadata = {
            skillRank = currentProf and currentProf.skillRank or 0,
            skillMaxRank = currentProf and currentProf.skillMaxRank or 0,
            ownerSourceType = entry.sourceType,
            professionSourceType = currentProf and currentProf.sourceType or nil,
            ownerUpdatedAt = entry.updatedAt,
            professionUpdatedAt = currentProf and currentProf.lastUpdatedAt or nil,
        },
    }

    local merged = Addon.MergeEngine and Addon.MergeEngine.MergeBlockAdditive
        and Addon.MergeEngine:MergeBlockAdditive(localBlock, normalized)
        or nil
    if not merged then
        return false, "merge-failed"
    end

    local profession = currentProf or {}
    profession.recipes = merged.recipes or {}
    profession.specialization = merged.specialization
    profession.skillRank = merged.skillRank or profession.skillRank or 0
    profession.skillMaxRank = merged.skillMaxRank or profession.skillMaxRank or 0
    profession.sourceType = profession.sourceType or entry.sourceType or opts.sourceType or "replica"
    profession.guildStatus = "active"
    profession.lastSeenInGuildAt = time()
    profession.lastUpdatedAt = time()
    profession.count = countRecipeKeys(profession.recipes)
    profession.signature = stableRecipeSignature(profession.recipes)

    entry.owner = ownerCharacter
    entry.sourceType = entry.sourceType or opts.sourceType or self:GetMemberSourceType(ownerCharacter)
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = profession.lastSeenInGuildAt
    entry.professions = entry.professions or {}
    entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, profession)
    self.db.global.members[ownerCharacter] = self:NormalizeMemberEntry(entry, ownerCharacter)

    if self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty("block-merge:" .. tostring(blockKey))
    end
    self:InvalidateRecipeCaches("metadata")
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex("block-merge")
    end

    local fingerprint = self.BuildBlockFingerprint and self:BuildBlockFingerprint(blockKey) or nil
    return true, {
        blockKey = blockKey,
        ownerCharacter = ownerCharacter,
        professionKey = professionKey,
        changed = merged.changed == true,
        addedRecipes = merged.addedRecipes or 0,
        specializationChanged = merged.specializationChanged == true,
        blockFingerprint = fingerprint,
    }
end

function Data:RecomputeLocalBlockFingerprint(blockKey)
    if not blockKey or not self.BuildBlockFingerprint then
        return nil
    end
    return self:BuildBlockFingerprint(blockKey)
end

function Data:DumpLocalSyncStatus(professionFilter)
    local memberKey = self:GetPlayerKey()
    local entry = self:GetOrCreateMember(memberKey)
    local professionKeys = {}
    local totalRecipes = 0

    for profName, prof in pairs(entry.professions or {}) do
        professionKeys[#professionKeys + 1] = profName
        totalRecipes = totalRecipes + (prof.count or countRecipeKeys(prof.recipes))
    end
    sort(professionKeys)

    Addon:SystemPrint(string.format(
        "Local sync owner=%s professions=%d recipes=%d",
        tostring(memberKey),
        #professionKeys,
        totalRecipes
    ))

    local requestedProfession = tostring(professionFilter or ""):match("^%s*(.-)%s*$") or ""
    if requestedProfession ~= "" then
        local canonical = self:GetCanonicalProfession(requestedProfession)
        local resolved = entry.professions[canonical] and canonical or nil
        if not resolved then
            for _, profName in ipairs(professionKeys) do
                if tostring(profName):lower() == tostring(canonical):lower() then
                    resolved = profName
                    break
                end
            end
        end
        if not resolved then
            Addon:SystemPrint("Local sync profession not found: " .. tostring(requestedProfession) .. ".")
            return
        end
        professionKeys = { resolved }
    end

    for _, profName in ipairs(professionKeys) do
        local prof = entry.professions[profName]
        Addon:SystemPrint(string.format(
            "  %s count=%d skill=%d/%d spec=%s recipes=%s",
            tostring(profName),
            prof and (prof.count or countRecipeKeys(prof.recipes)) or 0,
            prof and (prof.skillRank or 0) or 0,
            prof and (prof.skillMaxRank or 0) or 0,
            tostring(prof and prof.specialization or "none"),
            table.concat(sortedRecipeKeys(prof and prof.recipes or {}), ",")
        ))
    end
end
