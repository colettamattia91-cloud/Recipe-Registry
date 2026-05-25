local Addon = _G.RecipeRegistry
if not Addon then
    return
end

local RecipeUiFilters = Addon:NewModule("RecipeUiFilters")
Addon.RecipeUiFilters = RecipeUiFilters

local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local sort = table.sort

local PROFESSION_KEY_BY_DISPLAY = {
    Alchemy = "alchemy",
    Blacksmithing = "blacksmithing",
    Cooking = "cooking",
    Enchanting = "enchanting",
    Engineering = "engineering",
    Jewelcrafting = "jewelcrafting",
    Leatherworking = "leatherworking",
    Tailoring = "tailoring",
}

local FAVORITES_VIEW = "Favorites"

local function normalizeProfessionKey(professionKey)
    if not professionKey then
        return nil
    end
    if PROFESSION_KEY_BY_DISPLAY[professionKey] then
        return PROFESSION_KEY_BY_DISPLAY[professionKey]
    end
    local text = tostring(professionKey):lower()
    text = text:gsub("%s+", "_")
    return text
end

local function getProfilePrefilters()
    local profile = Addon.db and Addon.db.profile or {}
    local filters = profile.recipePrefilters
    if type(filters) ~= "table" then
        filters = {}
        profile.recipePrefilters = filters
    end
    if type(filters.expansionDefaults) ~= "table" then
        filters.expansionDefaults = {}
    end
    if filters.expansionDefaults.vanilla == nil then
        filters.expansionDefaults.vanilla = true
    end
    if filters.expansionDefaults.tbc == nil then
        filters.expansionDefaults.tbc = true
    end
    if type(filters.professionExpansionOverrides) ~= "table" then
        filters.professionExpansionOverrides = {}
    end
    if filters.showRemoteBopOutputRecipes == nil then
        filters.showRemoteBopOutputRecipes = false
    end
    return filters
end

local function getMetadata()
    return Addon.RecipeMetadata
end

local function boolToken(value)
    return value and "1" or "0"
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function RecipeUiFilters:GetMetadata()
    return getMetadata()
end

function RecipeUiFilters:NormalizeProfessionKey(professionKey)
    return normalizeProfessionKey(professionKey)
end

function RecipeUiFilters:GetEffectiveExpansionVisibility(professionKey)
    local filters = getProfilePrefilters()
    local normalizedProfession = normalizeProfessionKey(professionKey)
    local defaults = filters.expansionDefaults or {}
    local out = {
        professionKey = normalizedProfession,
        vanilla = defaults.vanilla ~= false,
        tbc = defaults.tbc ~= false,
        inherited = true,
    }

    local override = normalizedProfession and filters.professionExpansionOverrides[normalizedProfession] or nil
    if type(override) == "table" and override.inherit == false then
        out.inherited = false
        if override.vanilla ~= nil then
            out.vanilla = override.vanilla == true
        end
        if override.tbc ~= nil then
            out.tbc = override.tbc == true
        end
    end
    return out
end

function RecipeUiFilters:RecipePasses(recipeKey, recipeInfo, filterContext)
    local metadata = getMetadata()
    if not metadata then
        return true, "visible-no-plugin"
    end

    local info = recipeInfo or metadata:GetRecipeInfo(recipeKey)
    local resolution = metadata:GetMetadataResolutionStatus(recipeKey, info)
    if not info then
        if resolution == "ambiguous" then
            Addon:Trace("filters", "metadata ambiguous for recipe", recipeKey)
        else
            Addon:Trace("filters", "metadata unresolved for recipe", recipeKey)
        end
        return true, "visible-unresolved-conservative"
    end

    local professionKey = metadata:GetProfession(recipeKey, info)
    if not professionKey then
        Addon:Trace("filters", "metadata missing profession for recipe", recipeKey)
        return true, "visible-unresolved-conservative"
    end

    local expansion = metadata:GetRecipeExpansion(recipeKey, info)
    local visibility = self:GetEffectiveExpansionVisibility(professionKey)
    if expansion == "vanilla" and visibility.vanilla == false then
        return false, "hidden-expansion"
    end
    if expansion == "tbc" and visibility.tbc == false then
        return false, "hidden-expansion"
    end

    local ctx = filterContext or {}
    local ownership = ctx.ownership
    if not ownership and Addon.Data and Addon.Data.GetRecipeOwnershipSummary then
        ownership = Addon.Data:GetRecipeOwnershipSummary(recipeKey)
    end
    ownership = ownership or {}

    local selfOnly = metadata:IsOutputlessSelfOnly(recipeKey, info)
    local bopOutput = metadata:IsBopOutput(recipeKey, info)
    if bopOutput == nil and Addon.Data and Addon.Data.ResolveRecipeBopOutput then
        bopOutput = Addon.Data:ResolveRecipeBopOutput(recipeKey, info)
    end
    local restricted = selfOnly == true or bopOutput == true
    if restricted and ownership.knownByCurrentPlayer == true then
        return true, "visible-current-player"
    end

    local filters = getProfilePrefilters()
    if selfOnly == true and filters.showRemoteBopOutputRecipes ~= true then
        return false, "hidden-outputless-self-only"
    end
    if bopOutput == true and filters.showRemoteBopOutputRecipes ~= true then
        return false, "hidden-remote-bop"
    end

    if resolution ~= "resolved" then
        Addon:Trace("filters", "metadata unresolved for recipe", recipeKey)
        return true, "visible-unresolved-conservative"
    end

    return true, "visible-normal"
end

local function appendOverride(parts, professionKey, override)
    if type(override) ~= "table" then
        return
    end
    parts[#parts + 1] = table.concat({
        "override",
        normalizeProfessionKey(professionKey) or tostring(professionKey),
        boolToken(override.inherit ~= false),
        boolToken(override.vanilla == true),
        boolToken(override.tbc == true),
    }, ":")
end

local function shouldUseBroadFilterKey(ctx)
    if not ctx then
        return true
    end
    if ctx.globalSearch == true or ctx.selectedProfession == FAVORITES_VIEW then
        return true
    end
    return normalizeProfessionKey(ctx.effectiveProfession or ctx.selectedProfession) == nil
end

function RecipeUiFilters:BuildFilterCacheKey(ctx)
    ctx = ctx or {}
    local metadata = getMetadata()
    if not metadata then
        return "plugin=absent"
    end

    local filters = getProfilePrefilters()
    local data = Addon.Data or {}
    local parts = {
        "plugin=present",
        "metadata=" .. tostring(metadata.metadataVersion or ""),
        "schema=" .. tostring(metadata.schemaVersion or ""),
        "flavor=" .. tostring(metadata.flavor or ""),
        "remoteBop=" .. boolToken(filters.showRemoteBopOutputRecipes == true),
        "ownership=" .. tostring(data._recipeOwnershipIndexGeneration or 0),
    }

    local overrides = filters.professionExpansionOverrides or {}
    if shouldUseBroadFilterKey(ctx) then
        parts[#parts + 1] = "scope=broad"
        parts[#parts + 1] = "defaultVanilla=" .. boolToken(filters.expansionDefaults and filters.expansionDefaults.vanilla ~= false)
        parts[#parts + 1] = "defaultTbc=" .. boolToken(filters.expansionDefaults and filters.expansionDefaults.tbc ~= false)
        parts[#parts + 1] = "filterGen=" .. tostring(data._recipeFilterGenerationAll or 0)
        for _, professionKey in ipairs(sortedKeys(overrides)) do
            appendOverride(parts, professionKey, overrides[professionKey])
        end
    else
        local professionKey = normalizeProfessionKey(ctx.effectiveProfession or ctx.selectedProfession)
        local visibility = self:GetEffectiveExpansionVisibility(professionKey)
        local professionGenerations = data._recipeFilterGenerationByProfession or {}
        parts[#parts + 1] = "scope=profession:" .. tostring(professionKey)
        parts[#parts + 1] = "vanilla=" .. boolToken(visibility.vanilla ~= false)
        parts[#parts + 1] = "tbc=" .. boolToken(visibility.tbc ~= false)
        parts[#parts + 1] = "inherited=" .. boolToken(visibility.inherited == true)
        parts[#parts + 1] = "filterGen=" .. tostring(professionGenerations[professionKey] or 0)
    end

    return table.concat(parts, "|")
end

function RecipeUiFilters:Explain(recipeKey, ctx)
    local passed, reason = self:RecipePasses(recipeKey, nil, ctx)
    local metadata = getMetadata()
    local normalized = metadata and metadata:NormalizeRecipeKey(recipeKey) or nil
    return {
        recipeKey = recipeKey,
        passed = passed,
        reason = reason,
        plugin = metadata and "present" or "absent",
        metadataVersion = metadata and metadata.metadataVersion or nil,
        spellId = normalized and normalized.spellId or nil,
        source = normalized and normalized.source or nil,
    }
end

function RecipeUiFilters:InvalidateProfessionProjection(professionKey, reason)
    local normalizedProfession = normalizeProfessionKey(professionKey)
    if Addon.Data and Addon.Data.InvalidateRecipeListCacheForFilter then
        Addon.Data:InvalidateRecipeListCacheForFilter(normalizedProfession, reason)
    elseif Addon.Data and Addon.Data.InvalidateRecipeCaches then
        Addon.Data:InvalidateRecipeCaches("list")
    end
    if Addon.RequestRefresh then
        Addon:RequestRefresh(reason or ("filters:" .. tostring(normalizedProfession or "all")))
    end
end
