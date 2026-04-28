local Addon = _G.RecipeRegistry
local MergeEngine = Addon:NewModule("MergeEngine")
Addon.MergeEngine = MergeEngine

local pairs = pairs

local AUTHORITY_SCORE = {
    bootstrap = 1,
    replica = 2,
    owner = 3,
}

local function cloneRecipes(recipes)
    local out = {}
    for recipeKey in pairs(recipes or {}) do
        out[recipeKey] = true
    end
    return out
end

function MergeEngine:GetAuthorityScore(sourceType)
    return AUTHORITY_SCORE[sourceType or "replica"] or AUTHORITY_SCORE.replica
end

function MergeEngine:ResolveRecordAuthority(localEntry, incomingEntry)
    local localScore = self:GetAuthorityScore(localEntry and localEntry.sourceType)
    local incomingScore = self:GetAuthorityScore(incomingEntry and incomingEntry.sourceType)
    if incomingScore ~= localScore then
        return incomingScore > localScore and "incoming" or "local"
    end
    local localRev = localEntry and (localEntry.rev or 0) or 0
    local incomingRev = incomingEntry and (incomingEntry.rev or 0) or 0
    if incomingRev ~= localRev then
        return incomingRev > localRev and "incoming" or "local"
    end
    local localUpdated = localEntry and (localEntry.updatedAt or 0) or 0
    local incomingUpdated = incomingEntry and (incomingEntry.updatedAt or 0) or 0
    if incomingUpdated ~= localUpdated then
        return incomingUpdated > localUpdated and "incoming" or "local"
    end
    return "equal"
end

function MergeEngine:IgnoreEquivalent(localEntry, incomingEntry)
    if not localEntry or not incomingEntry then return false end
    if (localEntry.rev or 0) ~= (incomingEntry.rev or 0) then return false end
    if (localEntry.updatedAt or 0) ~= (incomingEntry.updatedAt or 0) then return false end
    if (localEntry.sourceType or "replica") ~= (incomingEntry.sourceType or "replica") then return false end

    local localProfs = localEntry.professions or {}
    local incomingProfs = incomingEntry.professions or {}
    for profName, localProf in pairs(localProfs) do
        local incomingProf = incomingProfs[profName]
        if not incomingProf then return false end
        if (localProf.count or 0) ~= (incomingProf.count or 0) then return false end
        if (localProf.skillRank or 0) ~= (incomingProf.skillRank or 0) then return false end
        if (localProf.skillMaxRank or 0) ~= (incomingProf.skillMaxRank or 0) then return false end
        if (localProf.signature or "") ~= (incomingProf.signature or "") then return false end
    end
    for profName in pairs(incomingProfs) do
        if not localProfs[profName] then return false end
    end
    return true
end

function MergeEngine:ShouldApplyIncoming(localEntry, incomingEntry, opts)
    opts = opts or {}
    if not incomingEntry then return false, "missing-incoming" end
    if opts.preserveOwner and localEntry and (localEntry.sourceType or "replica") == "owner"
        and (incomingEntry.sourceType or "replica") ~= "owner" then
        return false, "owner-precedence"
    end
    if self:IgnoreEquivalent(localEntry, incomingEntry) then
        return false, "equivalent"
    end

    local winner = self:ResolveRecordAuthority(localEntry, incomingEntry)
    if winner == "incoming" then
        return true, "newer"
    end
    if winner == "equal" and not localEntry then
        return true, "missing-local"
    end
    return false, winner
end

function MergeEngine:ApplyIfNewer(localEntry, incomingEntry, opts)
    local shouldApply, reason = self:ShouldApplyIncoming(localEntry, incomingEntry, opts)
    if not shouldApply then
        return false, reason, localEntry
    end

    local finalEntry = {}
    for key, value in pairs(incomingEntry) do
        if key ~= "professions" then
            finalEntry[key] = value
        end
    end
    finalEntry.professions = {}
    for profName, prof in pairs(incomingEntry.professions or {}) do
        local clone = {}
        for key, value in pairs(prof) do
            if key ~= "recipes" then
                clone[key] = value
            end
        end
        clone.recipes = cloneRecipes(prof.recipes)
        finalEntry.professions[profName] = clone
    end

    return true, reason, finalEntry
end
