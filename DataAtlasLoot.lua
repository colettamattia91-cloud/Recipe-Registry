local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local tonumber = tonumber
local tostring = tostring

local cloneAtlasInfo = Private.cloneAtlasInfo
local formatReagents = Private.formatReagents
local getAtlasLootHandles = Private.getAtlasLootHandles
local getAtlasLootProfessionName = Private.getAtlasLootProfessionName
local safeGetItemName = Private.safeGetItemName
local safeGetSpellName = Private.safeGetSpellName

local function formatOutputDesc(createdItemID, createdItemName, professionID)
    if createdItemID then
        return string.format("%s(%s)", tostring(createdItemName or "?"), tostring(createdItemID))
    end
    if professionID == 10 then
        return "direct enchant/no created item"
    end
    return "no created item"
end

function Data:ResolveRecipeProfession(recipeKey)
    local n = tonumber(recipeKey)
    if not n then return nil end

    local info
    if n < 0 then
        info = self:GetAtlasLootSpellInfo(-n)
    elseif n > 0 then
        info = self:GetAtlasLootCreatedItemInfo(n) or self:GetAtlasLootRecipeInfo(n)
    end

    local professionName = info and info.professionID and getAtlasLootProfessionName(info.professionID) or nil
    if professionName then
        return self:GetCanonicalProfession(professionName), professionName
    end
    return nil
end

function Data:HasAtlasLootResolver()
    local recipe, profession = getAtlasLootHandles()
    return recipe ~= nil and profession ~= nil
end

function Data:GetAtlasLootRecipeInfo(recipeItemID)
    local cached = self._atlasRecipeInfoCache and self._atlasRecipeInfoCache[recipeItemID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not recipeItemID then return nil end
    local recipeData = recipe.GetRecipeData and recipe.GetRecipeData(recipeItemID)
    if not recipeData then return nil end
    local spellID = recipeData[3]
    local spellData = spellID and profession.GetProfessionData and profession.GetProfessionData(spellID) or nil
    local createdItemID = spellID and profession.GetCreatedItemID and profession.GetCreatedItemID(spellID) or nil
    local info = {
        recipeItemID = recipeItemID,
        professionID = recipeData[1],
        minRank = recipeData[2],
        spellID = spellID,
        spellName = safeGetSpellName(spellID),
        createdItemID = createdItemID,
        createdItemName = safeGetItemName(createdItemID),
        spellData = spellData,
    }
    self._atlasRecipeInfoCache[recipeItemID] = cloneAtlasInfo(info)
    return info
end

function Data:GetAtlasLootSpellInfo(spellID)
    local cached = self._atlasSpellInfoCache and self._atlasSpellInfoCache[spellID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not spellID then return nil end
    local spellData = profession.GetProfessionData and profession.GetProfessionData(spellID)
    if not spellData then return nil end
    local recipeItemID = recipe.GetRecipeForSpell and recipe.GetRecipeForSpell(spellID) or nil
    local info = {
        spellID = spellID,
        spellName = safeGetSpellName(spellID),
        professionID = spellData[2],
        minRank = spellData[3],
        lowRank = spellData[4],
        highRank = spellData[5],
        createdItemID = spellData[1],
        createdItemName = safeGetItemName(spellData[1]),
        recipeItemID = recipeItemID,
        recipeItemName = safeGetItemName(recipeItemID),
        reagentIDs = spellData[6] or {},
        reagentCounts = spellData[7] or {},
        numCreated = spellData[8] or 1,
    }
    self._atlasSpellInfoCache[spellID] = cloneAtlasInfo(info)
    return info
end

function Data:GetAtlasLootCreatedItemInfo(createdItemID)
    local cached = self._atlasCreatedItemInfoCache and self._atlasCreatedItemInfoCache[createdItemID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not createdItemID then return nil end
    local spellID = profession.GetCraftSpellForCreatedItem and profession.GetCraftSpellForCreatedItem(createdItemID) or nil
    if not spellID then return nil end
    local info = self:GetAtlasLootSpellInfo(spellID) or {}
    info.createdItemID = createdItemID
    info.createdItemName = safeGetItemName(createdItemID)
    self._atlasCreatedItemInfoCache[createdItemID] = cloneAtlasInfo(info)
    return info
end

function Data:DumpAtlasLootStatus()
    local recipe, profession = getAtlasLootHandles()
    Addon:SystemPrint(string.format(
        "AtlasLoot resolver: %s | Recipe=%s | Profession=%s",
        self:HasAtlasLootResolver() and "ready" or "missing",
        recipe and "yes" or "no",
        profession and "yes" or "no"
    ))
end

function Data:DebugRecipeItem(recipeItemID)
    if not recipeItemID then
        Addon:Print("Usage: /rr r <recipeItemID>")
        return
    end
    local info = self:GetAtlasLootRecipeInfo(recipeItemID)
    if not info then
        Addon:SystemPrint("No AtlasLoot recipe data for item " .. tostring(recipeItemID))
        return
    end
    local reagents = info.spellData and formatReagents(info.spellData[6], info.spellData[7]) or "none"
    Addon:SystemPrint(string.format(
        "Recipe %d -> prof=%s rank=%d spell=%s(%d) output=%s reagents=[%s]",
        recipeItemID,
        tostring(info.professionID),
        tonumber(info.minRank or 0),
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        formatOutputDesc(info.createdItemID, info.createdItemName, info.professionID),
        reagents
    ))
end

function Data:DebugSpell(spellID)
    if not spellID then
        Addon:Print("Usage: /rr s <spellID>")
        return
    end
    local info = self:GetAtlasLootSpellInfo(spellID)
    if not info then
        Addon:SystemPrint("No AtlasLoot profession data for spell " .. tostring(spellID))
        return
    end
    Addon:SystemPrint(string.format(
        "Spell %s(%d) -> prof=%s min=%d low=%d high=%d output=%s recipe=%s(%s) num=%d reagents=[%s]",
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        tostring(info.professionID),
        tonumber(info.minRank or 0),
        tonumber(info.lowRank or 0),
        tonumber(info.highRank or 0),
        formatOutputDesc(info.createdItemID, info.createdItemName, info.professionID),
        tostring(info.recipeItemName or "nil"),
        tostring(info.recipeItemID or "nil"),
        tonumber(info.numCreated or 1),
        formatReagents(info.reagentIDs, info.reagentCounts)
    ))
end

function Data:DebugCreatedItem(createdItemID)
    if not createdItemID then
        Addon:Print("Usage: /rr i <createdItemID>")
        return
    end
    local info = self:GetAtlasLootCreatedItemInfo(createdItemID)
    if not info then
        Addon:SystemPrint(
            "No AtlasLoot craft mapping for created item "
                .. tostring(createdItemID)
                .. ". In TBC many enchanting formulas are direct enchants and do not create an item; use /rr r <recipeItemID> or /rr s <spellID> for those."
        )
        return
    end
    Addon:SystemPrint(string.format(
        "Created item %s(%d) -> spell=%s(%d) recipe=%s(%s)",
        tostring(info.createdItemName or "?"),
        tonumber(createdItemID or 0),
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        tostring(info.recipeItemName or "nil"),
        tostring(info.recipeItemID or "nil")
    ))
end