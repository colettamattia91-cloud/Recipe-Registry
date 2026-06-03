local Addon = _G.RecipeRegistry
local Data = Addon and Addon.Data
if not Data then
    return
end

local tonumber = tonumber
local pairs = pairs

-- Canonicalize the recipeKey to a numeric form when possible so insertion
-- and lookup agree on a single index key. Storing the same summary under
-- raw, tostring, AND tonumber forms was 3x the table footprint of the
-- index for no benefit — every caller goes through canonical().
local function canonical(recipeKey)
    return tonumber(recipeKey) or recipeKey
end

local function getOrCreateSummary(index, recipeKey)
    local key = canonical(recipeKey)
    local existing = index.byRecipeKey[key]
    if existing then
        return existing
    end
    local summary = {
        knownByCurrentPlayer = false,
        hasRemoteOwners = false,
        remoteOwnerCount = 0,
    }
    index.byRecipeKey[key] = summary
    return summary
end

function Data:InvalidateRecipeOwnershipIndex(_reason)
    self._recipeOwnershipIndex = nil
    self._recipeOwnershipIndexGeneration = (self._recipeOwnershipIndexGeneration or 0) + 1
end

function Data:BuildRecipeOwnershipIndex()
    local index = {
        byRecipeKey = {},
        generation = self._recipeOwnershipIndexGeneration or 0,
        builtAt = time and time() or 0,
    }
    local playerKey = self.GetPlayerKey and self:GetPlayerKey() or nil

    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            local isCurrentPlayer = playerKey and memberKey == playerKey
            for _, prof in pairs(entry.professions or {}) do
                for recipeKey in pairs(prof.recipes or {}) do
                    local summary = getOrCreateSummary(index, recipeKey)
                    if isCurrentPlayer then
                        summary.knownByCurrentPlayer = true
                    else
                        summary.remoteOwnerCount = (summary.remoteOwnerCount or 0) + 1
                        summary.hasRemoteOwners = true
                    end
                end
            end
        end
    end

    self._recipeOwnershipIndex = index
    return index
end

function Data:GetRecipeOwnershipIndex()
    return self._recipeOwnershipIndex or self:BuildRecipeOwnershipIndex()
end

function Data:GetRecipeOwnershipSummary(recipeKey)
    local index = self:GetRecipeOwnershipIndex()
    return index.byRecipeKey[canonical(recipeKey)] or {
        knownByCurrentPlayer = false,
        hasRemoteOwners = false,
        remoteOwnerCount = 0,
    }
end

function Data:IsRecipeKnownByCurrentPlayer(recipeKey)
    local summary = self:GetRecipeOwnershipSummary(recipeKey)
    return summary and summary.knownByCurrentPlayer == true or false
end
