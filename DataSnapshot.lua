local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local tostring = tostring
local max = math.max

local cloneTableShallow = Private.cloneTableShallow
local countRecipeKeys = Private.countRecipeKeys
local isSubsetOf = Private.isSubsetOf
local isValidRecipeKey = Private.isValidRecipeKey
local lowerSafe = Private.lowerSafe
local stableRecipeSignature = Private.stableRecipeSignature

function Data:GetLocalSummary()
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local profCount, recipeCount = 0, 0
    for _, prof in pairs(entry.professions or {}) do
        profCount = profCount + 1
        recipeCount = recipeCount + (prof.count or 0)
    end
    return {
        memberKey = self:GetPlayerKey(),
        rev = entry.rev or 0,
        updatedAt = entry.updatedAt or 0,
        professions = profCount,
        recipes = recipeCount,
    }
end

function Data:BuildSnapshotChunks(memberKey, opts)
    local entry = self:GetMember(memberKey)
    if not entry then return {} end
    opts = opts or {}

    local requestedProfessions = nil
    if type(opts.requestedBlocks) == "table" and #opts.requestedBlocks > 0 then
        requestedProfessions = {}
        for _, blockKey in ipairs(opts.requestedBlocks) do
            local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
            if ownerCharacter == memberKey and professionKey then
                requestedProfessions[professionKey] = true
            end
        end
    end

    local chunks = {}
    local chunkSize = 120
    local profNames = {}
    for profName in pairs(entry.professions or {}) do
        if not requestedProfessions or requestedProfessions[profName] then
            profNames[#profNames + 1] = profName
        end
    end
    sort(profNames)

    for _, profName in ipairs(profNames) do
        local prof = entry.professions[profName]
        local pending = {}
        local count = 0
        local recipeKeys = {}
        for recipeKey in pairs(prof.recipes or {}) do
            if isValidRecipeKey(recipeKey) then
                recipeKeys[#recipeKeys + 1] = recipeKey
            else
                self:RecordInvalidRecipeKey(recipeKey, "snapshot", memberKey, profName)
            end
        end
        sort(recipeKeys, function(a, b) return tostring(a) < tostring(b) end)

        for _, recipeKey in ipairs(recipeKeys) do
            pending[#pending + 1] = recipeKey
            count = count + 1
            if count >= chunkSize then
                chunks[#chunks + 1] = {
                    memberKey = memberKey,
                    rev = entry.rev or 0,
                    updatedAt = entry.updatedAt or 0,
                    sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
                    profession = profName,
                    skillRank = prof.skillRank or 0,
                    skillMaxRank = prof.skillMaxRank or 0,
                    specialization = prof.specialization or nil,
                    recipeKeys = pending,
                    partial = true,
                }
                pending = {}
                count = 0
            end
        end

        chunks[#chunks + 1] = {
            memberKey = memberKey,
            rev = entry.rev or 0,
            updatedAt = entry.updatedAt or 0,
            sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
            profession = profName,
            skillRank = prof.skillRank or 0,
            skillMaxRank = prof.skillMaxRank or 0,
            specialization = prof.specialization or nil,
            recipeKeys = pending,
            partial = false,
        }
    end

    if #chunks == 0 and not requestedProfessions then
        chunks[1] = {
            memberKey = memberKey,
            rev = entry.rev or 0,
            updatedAt = entry.updatedAt or 0,
            sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
            profession = nil,
            recipeKeys = {},
            partial = false,
        }
    end

    return chunks
end

function Data:BeginIncomingSnapshot(memberKey, rev, updatedAt)
    self._incoming = self._incoming or {}
    self._incoming[memberKey] = {
        memberKey = memberKey,
        rev = rev,
        updatedAt = updatedAt,
        professions = {},
    }
end

function Data:AppendIncomingChunk(chunk)
    if not chunk or not chunk.memberKey then return end
    self._incoming = self._incoming or {}
    local state = self._incoming[chunk.memberKey]
    if not state or state.rev ~= chunk.rev then
        self:BeginIncomingSnapshot(chunk.memberKey, chunk.rev, chunk.updatedAt)
        state = self._incoming[chunk.memberKey]
    end

    if chunk.profession then
        local prof = state.professions[chunk.profession] or {
            skillRank = chunk.skillRank or 0,
            skillMaxRank = chunk.skillMaxRank or 0,
            specialization = chunk.specialization or nil,
            recipes = {},
            sourceType = chunk.sourceType or "replica",
        }
        for _, recipeKey in ipairs(chunk.recipeKeys or {}) do
            if isValidRecipeKey(recipeKey) then
                prof.recipes[recipeKey] = true
            else
                self:RecordInvalidRecipeKey(recipeKey, "inbound", chunk.memberKey, chunk.profession)
                Addon:Debug("Blocked invalid recipe from sync:", recipeKey, "profession:", chunk.profession, "from:", chunk.memberKey)
            end
        end
        prof.skillRank = chunk.skillRank or prof.skillRank or 0
        prof.skillMaxRank = chunk.skillMaxRank or prof.skillMaxRank or 0
        if chunk.specialization ~= nil then
            prof.specialization = chunk.specialization
        end
        prof.lastUpdatedAt = chunk.updatedAt or state.updatedAt or time()
        prof.sourceType = chunk.sourceType or prof.sourceType or "replica"
        state.professions[chunk.profession] = prof
    end
end

function Data:FinalizeIncomingSnapshot(memberKey, rev, opts)
    if not self._incoming or not self._incoming[memberKey] then return false end
    local state = self._incoming[memberKey]
    if state.rev ~= rev then return false end
    opts = opts or {}

    local current = self:GetMember(memberKey)

    local finalEntry = {
        owner = memberKey,
        rev = rev,
        updatedAt = state.updatedAt or time(),
        sourceType = opts.sourceType or state.sourceType or "replica",
        guildStatus = "active",
        lastSeenInGuildAt = time(),
        isMock = opts.isMock == true,
        professions = {},
    }

    for profName, prof in pairs(state.professions or {}) do
        local incomingRecipes = prof.recipes or {}
        local count = 0
        for _ in pairs(incomingRecipes) do count = count + 1 end

        local currentProf = current and current.professions and current.professions[profName] or nil
        local currentCount = currentProf and (currentProf.count or countRecipeKeys(currentProf.recipes)) or 0
        local protectedPartial = false
        if currentProf and currentProf.recipes and currentCount > count then
            local incomingRank = prof.skillRank or 0
            local currentRank = currentProf.skillRank or 0
            if incomingRank >= currentRank and isSubsetOf(incomingRecipes, currentProf.recipes) then
                local incomingCount = count
                local merged = {}
                for recipeKey in pairs(currentProf.recipes) do merged[recipeKey] = true end
                for recipeKey in pairs(incomingRecipes) do merged[recipeKey] = true end
                incomingRecipes = merged
                count = 0
                for _ in pairs(incomingRecipes) do count = count + 1 end
                protectedPartial = true
                Addon:SystemPrint(string.format(
                    "Protected %s %s from a partial remote overwrite (%d -> %d kept, source=%s).",
                    memberKey,
                    profName,
                    incomingCount,
                    currentCount,
                    tostring(prof.sourceType or finalEntry.sourceType or "replica")
                ))
            end
        end

        local skillRank = prof.skillRank or 0
        local skillMaxRank = prof.skillMaxRank or 0
        local specialization = prof.specialization or nil
        local blockRevision = rev
        local lastUpdatedAt = state.updatedAt or time()
        local sourceType = prof.sourceType or finalEntry.sourceType
        if protectedPartial and currentProf then
            skillRank = max(currentProf.skillRank or 0, skillRank)
            skillMaxRank = max(currentProf.skillMaxRank or 0, skillMaxRank)
            specialization = specialization or currentProf.specialization
            blockRevision = currentProf.blockRevision or blockRevision
            lastUpdatedAt = currentProf.lastUpdatedAt or lastUpdatedAt
            sourceType = currentProf.sourceType or sourceType
        end

        finalEntry.professions[profName] = {
            skillRank = skillRank,
            skillMaxRank = skillMaxRank,
            specialization = specialization,
            recipes = incomingRecipes,
            count = count,
            signature = stableRecipeSignature(incomingRecipes),
            lastScan = state.updatedAt or time(),
            blockRevision = blockRevision,
            lastUpdatedAt = lastUpdatedAt,
            sourceType = sourceType,
            guildStatus = "active",
            lastSeenInGuildAt = finalEntry.lastSeenInGuildAt,
        }
    end

    if current and finalEntry.sourceType ~= "owner" then
        local preserved = 0
        for profName, currentProf in pairs(current.professions or {}) do
            if not finalEntry.professions[profName] then
                local clone = cloneTableShallow(currentProf)
                clone.recipes = {}
                for recipeKey in pairs(currentProf.recipes or {}) do
                    clone.recipes[recipeKey] = true
                end
                finalEntry.professions[profName] = clone
                preserved = preserved + 1
            end
        end
        if preserved > 0 then
            Addon:Debug("Preserved", preserved, "profession block(s) missing from incoming snapshot for", memberKey)
        end
    end

    local applied, reason, resolved = Addon.MergeEngine:ApplyIfNewer(current, finalEntry, {
        preserveOwner = memberKey == self:GetPlayerKey(),
    })
    self._incoming[memberKey] = nil

    if not applied then
        if Addon.Sync and Addon.Sync.RecordMergeSkip then
            Addon.Sync:RecordMergeSkip(reason)
        end
        return false
    end

    self.db.global.members[memberKey] = self:NormalizeMemberEntry(resolved, memberKey)
    self:MarkManifestMemberDirty(memberKey, self.db.global.members[memberKey], "snapshot-merge")
    self:InvalidateRecipeCaches()
    Addon:RequestRefresh("snapshot-merge")
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex()
    end
    return true
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
        "Local sync owner=%s rev=%d updated=%d professions=%d recipes=%d",
        tostring(memberKey),
        entry.rev or 0,
        entry.updatedAt or 0,
        #professionKeys,
        totalRecipes
    ))

    if #professionKeys == 0 then
        Addon:SystemPrint("Local sync professions: none")
        return
    end

    local requestedProfession = tostring(professionFilter or ""):match("^%s*(.-)%s*$") or ""
    if requestedProfession ~= "" then
        local canonical = self:GetCanonicalProfession(requestedProfession)
        local resolved = entry.professions[canonical] and canonical or nil
        if not resolved then
            for _, profName in ipairs(professionKeys) do
                if lowerSafe(profName) == lowerSafe(canonical) or lowerSafe(profName) == lowerSafe(requestedProfession) then
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
            "  %s count=%d skill=%d/%d spec=%s blockRev=%d source=%s updated=%d",
            tostring(profName),
            prof and (prof.count or countRecipeKeys(prof.recipes)) or 0,
            prof and (prof.skillRank or 0) or 0,
            prof and (prof.skillMaxRank or 0) or 0,
            tostring(prof and prof.specialization or "none"),
            prof and (prof.blockRevision or 0) or 0,
            tostring(prof and prof.sourceType or "owner"),
            prof and (prof.lastUpdatedAt or 0) or 0
        ))
    end
end