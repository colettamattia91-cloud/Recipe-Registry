local Addon = _G.RecipeRegistry
local Data = Addon and Addon.Data
if not Data then
    return
end

local tostring = tostring
local tonumber = tonumber
local pairs = pairs

local function storeSummary(index, recipeKey, summary)
    index.byRecipeKey[recipeKey] = summary
    index.byRecipeKey[tostring(recipeKey)] = summary
    local numeric = tonumber(recipeKey)
    if numeric then
        index.byRecipeKey[numeric] = summary
    end
end

local function getOrCreateSummary(index, recipeKey)
    local existing = index.byRecipeKey[recipeKey] or index.byRecipeKey[tostring(recipeKey)]
    if existing then
        return existing
    end
    local summary = {
        knownByCurrentPlayer = false,
        hasRemoteOwners = false,
        remoteOwnerCount = 0,
    }
    storeSummary(index, recipeKey, summary)
    return summary
end

function Data:InvalidateRecipeOwnershipIndex(reason)
    self._recipeOwnershipIndex = nil
    self._recipeOwnershipIndexGeneration = (self._recipeOwnershipIndexGeneration or 0) + 1
    self._recipeOwnershipIndexInvalidatedReason = reason
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
    return index.byRecipeKey[recipeKey] or index.byRecipeKey[tostring(recipeKey)] or {
        knownByCurrentPlayer = false,
        hasRemoteOwners = false,
        remoteOwnerCount = 0,
    }
end

function Data:IsRecipeKnownByCurrentPlayer(recipeKey)
    local summary = self:GetRecipeOwnershipSummary(recipeKey)
    return summary and summary.knownByCurrentPlayer == true or false
end
