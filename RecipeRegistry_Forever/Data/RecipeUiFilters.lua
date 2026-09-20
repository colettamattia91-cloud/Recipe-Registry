local Addon = _G.RecipeRegistry
if not Addon then
    return
end

local RecipeUiFilters = Addon:NewModule("RecipeUiFilters")
Addon.RecipeUiFilters = RecipeUiFilters

local tostring = tostring
local tonumber = tonumber
local pairs = pairs

local PROFESSION_KEY_BY_DISPLAY = {
    Alchemy = "alchemy",
    Blacksmithing = "blacksmithing",
    Cooking = "cooking",
    Enchanting = "enchanting",
    Engineering = "engineering",
    -- "first_aid" con l'underscore: e' la chiave che il bundle di datamining
    -- emette gia' oggi (out/bundle/forever-local-*/recipes.json), e le due
    -- devono combaciare o il dataset non si aggancera' mai a questo mestiere
    ["First Aid"] = "first_aid",
    Fishing = "fishing",
    Herbalism = "herbalism",
    Leatherworking = "leatherworking",
    Mining = "mining",
    Skinning = "skinning",
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
    if filters.showRemoteBopOutputRecipes == nil then
        filters.showRemoteBopOutputRecipes = false
    end
    if filters.hideUncataloguedRecipes == nil then
        filters.hideUncataloguedRecipes = true
    end
    if filters.showOnlyProfitableRecipes == nil then
        filters.showOnlyProfitableRecipes = false
    end
    return filters
end

local function getMetadata()
    return Addon.RecipeMetadata
end

local function boolToken(value)
    return value and "1" or "0"
end

function RecipeUiFilters:NormalizeProfessionKey(professionKey)
    return normalizeProfessionKey(professionKey)
end

-- The v1 metadata library only catalogues the eight crafting professions
-- declared in PROFESSION_KEY_BY_DISPLAY. Gathering/auxiliary professions
-- (Mining, First Aid, Fishing, Herbalism, Skinning) are out of scope, so
-- the hide-uncatalogued gate must not apply to their recipes — there is no
-- metadata to compare against and dropping their rows hides legitimate
-- scan data.
function RecipeUiFilters:IsSupportedProfession(professionKey)
    if not professionKey then return false end
    if PROFESSION_KEY_BY_DISPLAY[professionKey] then return true end
    for _, canonical in pairs(PROFESSION_KEY_BY_DISPLAY) do
        if canonical == professionKey then return true end
    end
    return false
end

-- The profit filter is a setting, not options-panel state. The collection
-- strip and the recipe header drive the same switch the options panel does, so
-- both the reading and the writing live here, next to the code that consumes
-- them: one setter, one invalidation path, rather than one of each per surface.
function RecipeUiFilters:IsProfitableOnly()
    return getProfilePrefilters().showOnlyProfitableRecipes == true
end

function RecipeUiFilters:SetProfitableOnly(enabled)
    getProfilePrefilters().showOnlyProfitableRecipes = enabled == true
    self:InvalidateProfessionProjection(nil, "filters:profitable-only")
end

-- Profit gate for the "only profitable recipes" toggle. Deliberately the
-- last thing RecipePasses does, and only when the toggle is on: it is the
-- one predicate that costs price lookups, so the default path never pays
-- for it.
--
-- Only a craft that prices out at a loss is dropped. One that cannot be
-- priced at all stays visible and is marked in the list instead: reagents
-- with no auctions (vials, thread, spices) are common enough that hiding
-- the unpriceable would quietly empty whole professions -- every flask
-- needs a vial -- and the filter would be hiding recipes out of ignorance
-- rather than out of a verdict.
-- Four answers, not three. A craft whose best case already loses money is
-- unprofitable whatever the missing reagent costs, so a partial estimate is
-- still grounds to hide it; a partial estimate in the black is not, because
-- the missing reagent could take it back under.
local function profitVerdict(recipeKey, info)
    local market = Addon.Market
    if not (market and market.EstimateRecipeProfit) then
        return "unpriceable"
    end
    local profit, quality = market:EstimateRecipeProfit(recipeKey, info)
    if type(profit) ~= "number" then
        return "unpriceable"
    end
    if profit <= 0 then
        return "unprofitable"
    end
    return quality == "partial" and "partial" or "profitable"
end

function RecipeUiFilters:RecipePasses(recipeKey, recipeInfo, filterContext)
    local passes, reason = self:EvaluateVisibility(recipeKey, recipeInfo, filterContext)
    if passes ~= true then
        return passes, reason
    end
    if getProfilePrefilters().showOnlyProfitableRecipes ~= true then
        return true, reason
    end
    local metadata = getMetadata()
    local info = recipeInfo or (metadata and metadata:GetRecipeInfo(recipeKey)) or nil
    local verdict = profitVerdict(recipeKey, info)
    if verdict == "unprofitable" then
        Addon:Trace("filters", "recipe hidden by profit filter", recipeKey)
        return false, "hidden-not-profitable"
    end
    if verdict == "partial" then
        return true, "visible-partial-price"
    end
    if verdict == "unpriceable" then
        return true, "visible-unpriced"
    end
    return true, reason
end

-- Everything except the profit gate: ownership, BoP/outputless
-- and the uncatalogued cleanup. Split out so the expensive gate can run
-- once, last, on the survivors.
function RecipeUiFilters:EvaluateVisibility(recipeKey, recipeInfo, filterContext)
    local metadata = getMetadata()
    if not metadata then
        return true, "visible-no-plugin"
    end

    local profileFilters = getProfilePrefilters()
    local info = recipeInfo or metadata:GetRecipeInfo(recipeKey)
    local resolution = metadata:GetMetadataResolutionStatus(recipeKey, info)
    if not info then
        if resolution == "ambiguous" then
            -- Real recipe with mapping ambiguity (e.g. same created item from
            -- multiple spells): keep visible per roadmap §9 conservative show —
            -- the mapping is a remediation task, the recipe itself is legit.
            Addon:Trace("filters", "metadata ambiguous for recipe", recipeKey)
            return true, "visible-unresolved-conservative"
        end
        -- Last-gate cleanup (profile-gated, default on): drop only the entries
        -- that look like spurious garbage — positive item-IDs imported as
        -- recipe keys without a metadata match. Negative spell keys are
        -- always legit (scanned from a real TradeSkill window) even if the
        -- profession sits outside the v1 metadata scope (Mining smelting,
        -- First Aid, Fishing), so they stay visible per roadmap §9 even
        -- with the flag on.
        local numericKey = tonumber(recipeKey)
        -- Out-of-scope professions (Mining, First Aid, Fishing, ...) opt out
        -- of the hide-uncatalogued gate via filterContext, because there is
        -- no metadata to compare against — every recipe in those professions
        -- is "uncatalogued" by definition and dropping them hides real scan
        -- data, not garbage.
        -- Un dataset che non conosce nessuna ricetta non ha titolo per
        -- nascondere qualcosa. Su Forever e' il segnaposto vuoto, e senza questa
        -- riga il cancello nascondeva OGNI ricetta scansionata -- sono tutte
        -- chiavi-oggetto positive -- lasciando l'addon con la lista vuota mentre
        -- i dati erano regolarmente in SavedVariables. Visto in gioco il
        -- 2026-09-18. Vedi Data:MetadataKnowsAnyRecipe.
        local metadataHasOpinion = not (Addon.Data and Addon.Data.MetadataKnowsAnyRecipe)
            or Addon.Data:MetadataKnowsAnyRecipe()
        local skipUncataloguedGate = (filterContext and filterContext.allowUncataloguedRecipes == true)
            or not metadataHasOpinion
        if not skipUncataloguedGate
            and profileFilters.hideUncataloguedRecipes ~= false
            and numericKey and numericKey > 0
        then
            Addon:Trace("filters", "metadata uncatalogued item-key recipe", recipeKey)
            return false, "hidden-uncatalogued"
        end
        -- Last-resort sanity check: if neither the metadata library nor the
        -- WoW client knows about this recipe key, it's a ghost (old mock /
        -- corrupted scan) and pretending it's a real recipe just keeps the
        -- garbage propagating between peers. Hide it. The same predicate
        -- guards the sync producer/consumer, so peers also stop echoing it.
        if Addon.Data and Addon.Data.IsRecipeKeyResolvableInClient
            and not Addon.Data:IsRecipeKeyResolvableInClient(recipeKey)
        then
            Addon:Trace("filters", "recipe key not resolvable in client", recipeKey)
            return false, "hidden-not-in-client"
        end
        Addon:Trace("filters", "metadata unresolved for recipe", recipeKey)
        return true, "visible-unresolved-conservative"
    end

    local professionKey = info.profession
    if not professionKey then
        Addon:Trace("filters", "metadata missing profession for recipe", recipeKey)
        return true, "visible-unresolved-conservative"
    end

    local ctx = filterContext or {}
    local ownership = ctx.ownership
    if not ownership and Addon.Data and Addon.Data.GetRecipeOwnershipSummary then
        ownership = Addon.Data:GetRecipeOwnershipSummary(recipeKey)
    end
    ownership = ownership or {}

    -- Read straight off the record. IsOutputlessSelfOnly / IsBopOutput
    -- are wrappers around the same field access; calling them per
    -- candidate adds two method dispatches each that pile up on large
    -- profession lists. Static bopOutput is emitted for every catalogued
    -- recipe, so the dynamic fallback only fires for unresolved records.
    local selfOnly = info.selfOnlyOutputless == true
    local bopOutput = info.bopOutput
    if bopOutput == nil and Addon.Data and Addon.Data.ResolveRecipeBopOutput then
        bopOutput = Addon.Data:ResolveRecipeBopOutput(recipeKey, info)
    end
    local restricted = selfOnly == true or bopOutput == true
    if restricted and ownership.knownByCurrentPlayer == true then
        return true, "visible-current-player"
    end

    if selfOnly == true and profileFilters.showRemoteBopOutputRecipes ~= true then
        return false, "hidden-outputless-self-only"
    end
    if bopOutput == true and profileFilters.showRemoteBopOutputRecipes ~= true then
        return false, "hidden-remote-bop"
    end

    if resolution ~= "resolved" then
        Addon:Trace("filters", "metadata unresolved for recipe", recipeKey)
        return true, "visible-unresolved-conservative"
    end

    return true, "visible-normal"
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
        "hideUncat=" .. boolToken(filters.hideUncataloguedRecipes ~= false),
        -- Price data itself is not in the key: Market:InvalidatePriceCache
        -- drops the recipe list caches wholesale when the auction house
        -- closes, which is the only moment the underlying prices move.
        "profitOnly=" .. boolToken(filters.showOnlyProfitableRecipes == true),
        "ownership=" .. tostring(data._recipeOwnershipIndexGeneration or 0),
    }

    if shouldUseBroadFilterKey(ctx) then
        parts[#parts + 1] = "scope=broad"
        parts[#parts + 1] = "filterGen=" .. tostring(data._recipeFilterGenerationAll or 0)
    else
        local professionKey = normalizeProfessionKey(ctx.effectiveProfession or ctx.selectedProfession)
        local professionGenerations = data._recipeFilterGenerationByProfession or {}
        parts[#parts + 1] = "scope=profession:" .. tostring(professionKey)
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
