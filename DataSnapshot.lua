local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local tostring = tostring

local countRecipeKeys = Private.countRecipeKeys

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

    -- Membership classification (`guildStatus`) is owned by the trusted-roster
    -- preflight, not by the inbound sync merge. Receiving recipe data for an
    -- owner says nothing about whether that owner is still in our guild — only
    -- the roster snapshot can decide that. Consult the current roster state to
    -- decide whether to refresh `active`, preserve an existing classification,
    -- or leave a fresh entry pending until the next preflight runs.
    local rosterState = self.GetRosterPreflightState and self:GetRosterPreflightState() or nil
    local rosterTrusted = type(rosterState) == "table" and rosterState.trusted == true
    local rosterSnapshot
    if rosterTrusted and type(rosterState) == "table" and type(rosterState.snapshot) == "table" then
        rosterSnapshot = rosterState.snapshot
    end
    local rosterHasOwnerEvidence = rosterSnapshot ~= nil
    local ownerInTrustedGuild = rosterSnapshot and rosterSnapshot[ownerCharacter] == true or false

    local existingEntry = self:GetMember(ownerCharacter)
    local entry = self:GetOrCreateMember(ownerCharacter)
    local entryIsNew = existingEntry == nil
    local previousGuildStatus = entry.guildStatus or "active"
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
    profession.lastUpdatedAt = time()
    profession.count = countRecipeKeys(profession.recipes)
    profession.signature = nil  -- legacy field; drop on merge so SavedVariables sheds it

    entry.owner = ownerCharacter
    entry.sourceType = entry.sourceType or opts.sourceType or self:GetMemberSourceType(ownerCharacter)

    if rosterHasOwnerEvidence and ownerInTrustedGuild then
        -- Trusted snapshot confirms this owner is in our guild: refresh active.
        profession.guildStatus = "active"
        profession.lastSeenInGuildAt = time()
        entry.guildStatus = "active"
        entry.lastSeenInGuildAt = profession.lastSeenInGuildAt
        entry.staleAt = 0
    elseif rosterHasOwnerEvidence and not ownerInTrustedGuild then
        -- Trusted snapshot is positive evidence the owner is NOT in our guild:
        -- preserve persisted data but don't reactivate. New entries default to
        -- stale; pre-existing classification is left alone so a previous
        -- preflight verdict survives the merge.
        if entryIsNew then
            entry.guildStatus = "stale"
            entry.staleAt = entry.staleAt or time()
        end
        if not profession.guildStatus then
            profession.guildStatus = entry.guildStatus or "active"
        end
    else
        -- No roster evidence (untrusted state, fallback mode, or warming up):
        -- do not classify. Preserve existing status; let the next preflight
        -- decide. Default new entries to active so they remain visible until
        -- the roster proves otherwise, matching the conservative "no
        -- destructive purge in uncertain roster states" rule.
        if entryIsNew and not entry.guildStatus then
            entry.guildStatus = "active"
        end
        if not profession.guildStatus then
            profession.guildStatus = entry.guildStatus or "active"
        end
    end

    entry.professions = entry.professions or {}
    entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, profession)
    self.db.global.members[ownerCharacter] = self:NormalizeMemberEntry(entry, ownerCharacter)

    -- If the merge flipped the owner from stale to active, the entry's
    -- OTHER professions were previously excluded from the sync index by
    -- shouldPublishOwner and need to be re-added. Marking only the
    -- merged block dirty would leave those other professions invisible
    -- until the next full rebuild. Touch them all so rebuildDirtyBlocks
    -- picks them up incrementally.
    local statusFlippedToActive = previousGuildStatus ~= "active" and (entry.guildStatus or "active") == "active"
    if statusFlippedToActive and self.MarkOwnerSyncBlocksDirty then
        self:MarkOwnerSyncBlocksDirty(ownerCharacter, "block-merge:stale-to-active")
    elseif self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty("block-merge:" .. tostring(blockKey), blockKey)
    end
    self:InvalidateRecipeCaches("metadata")
    -- The "metadata" scope intentionally preserves _recipeListCache so that
    -- skill-rank/spec-only refreshes don't blow away precomputed list rows.
    -- A block merge that ADDS recipes, introduces a new owner, or flips an
    -- owner back to active changes which rows appear in those cached lists
    -- (and their crafterCount / professionList), so drop the list cache too.
    -- Pure metadata-only merges (addedRecipes == 0, no new owner, no status
    -- flip) still keep the list cache hot.
    local contentChanged = (merged.addedRecipes or 0) > 0 or entryIsNew or statusFlippedToActive
    if contentChanged then
        self:InvalidateRecipeCaches("list")
    end
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex("block-merge")
    end

    -- The block fingerprint recompute walks the roster and rebuilds the
    -- dirty blocks of the sync index — for an owner with many recipes that
    -- is the heaviest part of the post-merge work, and doing it inline at
    -- the end of every block pull produced a visible per-merge stutter. The
    -- block is already marked dirty above (MarkSyncIndexDirty or
    -- MarkOwnerSyncBlocksDirty), so any consumer that needs the fingerprint
    -- right now (e.g. a SUMMARY build) will trigger the rebuild lazily. For
    -- the routine "merge then move on" path we defer the rebuild via an
    -- AceBucket message so consecutive merges coalesce into a single
    -- rebuild instead of paying the cost N times.
    if Addon.SendMessage then
        Addon:SendMessage("RR_BLOCK_MERGE_POST", blockKey)
    end
    return true, {
        blockKey = blockKey,
        ownerCharacter = ownerCharacter,
        professionKey = professionKey,
        changed = merged.changed == true,
        addedRecipes = merged.addedRecipes or 0,
        specializationChanged = merged.specializationChanged == true,
        blockFingerprint = nil,
    }
end

function Data:RecomputeLocalBlockFingerprint(blockKey, opts)
    opts = opts or {}
    if self.RefreshSyncBlockRecord then
        return self:RefreshSyncBlockRecord(blockKey, opts.reason or "block-fingerprint")
    end
    return self.BuildBlockFingerprint and self:BuildBlockFingerprint(blockKey) or nil
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
    table.sort(professionKeys)

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
        local recipeList = {}
        for recipeKey in pairs(prof and prof.recipes or {}) do
            recipeList[#recipeList + 1] = tonumber(recipeKey) or recipeKey
        end
        table.sort(recipeList, function(left, right)
            return tostring(left) < tostring(right)
        end)
        Addon:SystemPrint(string.format(
            "  %s count=%d skill=%d/%d spec=%s recipes=%s",
            tostring(profName),
            prof and (prof.count or countRecipeKeys(prof.recipes)) or 0,
            prof and (prof.skillRank or 0) or 0,
            prof and (prof.skillMaxRank or 0) or 0,
            tostring(prof and prof.specialization or "none"),
            table.concat(recipeList, ",")
        ))
    end
end
