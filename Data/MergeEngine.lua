local Addon = _G.RecipeRegistry
local MergeEngine = Addon:NewModule("MergeEngine")
Addon.MergeEngine = MergeEngine

local pairs = pairs
local tostring = tostring
local max = math.max

local function cloneRecipes(recipes)
    local out = {}
    for recipeKey in pairs(recipes or {}) do
        out[recipeKey] = true
    end
    return out
end

function MergeEngine:MergeTransportMetadataNonAuthoritative(localBlock, incomingBlock)
    localBlock = localBlock or {}
    incomingBlock = incomingBlock or {}
    return {
        skillRank = max(tonumber(localBlock.skillRank or 0) or 0, tonumber(incomingBlock.skillRank or 0) or 0),
        skillMaxRank = max(tonumber(localBlock.skillMaxRank or 0) or 0, tonumber(incomingBlock.skillMaxRank or 0) or 0),
        ownerSourceType = incomingBlock.ownerSourceType or localBlock.ownerSourceType,
        professionSourceType = incomingBlock.professionSourceType or localBlock.professionSourceType,
        ownerUpdatedAt = incomingBlock.ownerUpdatedAt or localBlock.ownerUpdatedAt,
        professionUpdatedAt = incomingBlock.professionUpdatedAt or localBlock.professionUpdatedAt,
    }
end

function MergeEngine:NormalizeIncomingBlockPayload(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local recipeSet = {}
    for _, recipeKey in ipairs(payload.recipeKeys or {}) do
        if recipeKey ~= nil then
            recipeSet[recipeKey] = true
        end
    end
    return {
        blockKey = payload.blockKey,
        ownerCharacter = payload.ownerCharacter,
        professionKey = payload.professionKey,
        recipes = recipeSet,
        specialization = payload.specialization,
        skillRank = payload.skillRank or 0,
        skillMaxRank = payload.skillMaxRank or 0,
        metadata = type(payload.metadata) == "table" and payload.metadata or {},
    }
end

function MergeEngine:MergeBlockAdditive(localBlock, incomingBlock)
    local mergedRecipes = cloneRecipes(localBlock and localBlock.recipes or {})
    local addedRecipes = 0
    for recipeKey in pairs(incomingBlock and incomingBlock.recipes or {}) do
        if not mergedRecipes[recipeKey] then
            mergedRecipes[recipeKey] = true
            addedRecipes = addedRecipes + 1
        end
    end

    local specializationChanged = false
    local finalSpecialization = localBlock and localBlock.specialization or nil
    if incomingBlock and incomingBlock.specialization ~= nil
        and tostring(incomingBlock.specialization) ~= tostring(finalSpecialization)
    then
        finalSpecialization = incomingBlock.specialization
        specializationChanged = true
    end

    local mergedMetadata = self:MergeTransportMetadataNonAuthoritative(
        localBlock and localBlock.metadata or {},
        incomingBlock and incomingBlock.metadata or {}
    )

    return {
        recipes = mergedRecipes,
        specialization = finalSpecialization,
        skillRank = mergedMetadata.skillRank,
        skillMaxRank = mergedMetadata.skillMaxRank,
        metadata = mergedMetadata,
        changed = addedRecipes > 0 or specializationChanged,
        addedRecipes = addedRecipes,
        specializationChanged = specializationChanged,
    }
end
