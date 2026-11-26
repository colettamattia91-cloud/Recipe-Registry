local Addon = _G.RecipeRegistry
if not Addon then
    return
end

local generated = _G.RecipeRegistryRecipeMetadata or {}
local overrides = _G.RecipeRegistryRecipeMetadataOverrides or {}

local RecipeMetadata = {
    metadataVersion = generated.metadataVersion,
    schemaVersion = generated.schemaVersion,
    flavor = generated.flavor,
    _generated = generated,
    _overrides = overrides,
    _recordsBySpellId = {},
    _recipeItemToSpellId = {},
    _createdItemToSpellIds = {},
}

local function countTable(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function countOverrideEntries()
    local count = 0
    for _, bucket in pairs(overrides or {}) do
        count = count + countTable(bucket)
    end
    return count
end

local function cloneReagents(reagents)
    if type(reagents) ~= "table" then
        return nil
    end
    local out = {}
    for index, reagent in ipairs(reagents) do
        out[index] = {
            itemId = reagent.itemId,
            count = reagent.count,
        }
    end
    return out
end

-- I record sono quelli del file generato, non copie. Fino al 14/11 _Rebuild
-- li copiava tutti: 5 MB in piu' sui 3,6 del file (sandbox Lua 5.1), perche'
-- il costruttore della copia nominava 27 campi e Lua 5.1 riserva lo spazio
-- per tutti anche quando valgono nil. La copia veniva da quando i metadati
-- erano un addon a parte; il dato e' statico, e nessun consumatore modifica un
-- record. Una ricetta con una correzione a mano riceve invece una copia sua
-- (vedi hasOverride), cosi' il file generato resta com'e' anche quando
-- _Rebuild gira di nuovo con correzioni diverse.
--
-- I campi di un record, come li scrive il generatore; un campo assente vale
-- il suo caso comune:
--   spellId           aggiunto qui, dalla chiave
--   profession        il mestiere primario
--   professions       l'elenco completo quando sono piu' d'uno: la 461692,
--                     Synthetic Gordok Ogre Suit, sta in Leatherworking e in
--                     Tailoring
--   expansion, recipeItemId, createdItemId, createdCount, createdCountMax,
--   specialization, category, sortOrder, requiredSkill
--   classMask         le classi a cui un trainer la insegna; assente = tutte
--   phase             la fase in cui arriva; assente = contenuto base
--   trainerTitle, trainerContinents
--                     il titolo di ogni trainer che la insegna e i continenti
--   selfOnlyOutputless, bopOutput
--   faction           assente = entrambe, che e' il caso comune
--   sourceKind, worldDrop, bossDrop
--   sourcePlaces      un posto per NPC, { name, zone, x, y, faction }: la zona
--                     e' un id, GetSource la risolve; posizione e fazione
--                     sono del singolo NPC, non della ricetta
--   alsoSources       le provenienze oltre la principale, in ordine:
--                     { kind, places, worldDrop, bossDrop, trainerTitle }
--   skillLevels       le quattro soglie di colore della ricetta
--   removed           nei dati del client ma non nel gioco
--   reagents          { itemId, count } per slot
--
-- I booleani mancano quando sono falsi: chi li legge confronta con true o
-- ne prende la verita', mai con false.
local function shallowCopy(record)
    local out = {}
    for key, value in pairs(record) do
        out[key] = value
    end
    return out
end

local function cloneSpellIdList(list)
    local out = {}
    for index, spellId in ipairs(list or {}) do
        out[index] = spellId
    end
    return out
end

local function cloneCategoryList(list)
    local out = {}
    for index, category in ipairs(list or {}) do
        out[index] = {
            key = category.key,
            label = category.label,
            order = category.order,
        }
    end
    return out
end

local function sortedRecordIds(records)
    local ids = {}
    for spellId in pairs(records or {}) do
        ids[#ids + 1] = spellId
    end
    table.sort(ids, function(left, right)
        return tonumber(left) < tonumber(right)
    end)
    return ids
end

local function applyOverrides(record)
    if type(record) ~= "table" then
        return
    end
    local spellId = record.spellId

    local createdItemId = overrides.createdItemBySpellId and overrides.createdItemBySpellId[spellId]
    if createdItemId ~= nil then
        record.createdItemId = createdItemId
    end

    local recipeItemId = overrides.recipeItemBySpellId and overrides.recipeItemBySpellId[spellId]
    if recipeItemId ~= nil then
        record.recipeItemId = recipeItemId
    end

    local category = overrides.categoryBySpellId and overrides.categoryBySpellId[spellId]
    if type(category) == "table" then
        if category.category ~= nil then
            record.category = category.category
        end
        if category.sortOrder ~= nil then
            record.sortOrder = category.sortOrder
        end
    end

    local selfOnly = overrides.selfOnlyOutputlessBySpellId and overrides.selfOnlyOutputlessBySpellId[spellId]
    if selfOnly ~= nil then
        record.selfOnlyOutputless = selfOnly == true
    end

    local bopOutput = overrides.bopOutputBySpellId and overrides.bopOutputBySpellId[spellId]
    if bopOutput ~= nil then
        record.bopOutput = bopOutput == true
    elseif record.createdItemId and overrides.bindTypeByCreatedItemId then
        local bindType = overrides.bindTypeByCreatedItemId[record.createdItemId]
        if bindType ~= nil then
            record.bopOutput = tonumber(bindType) == 1
        end
    end
end

-- Se una correzione a mano tocca questa ricetta. Su Forever i secchi delle
-- correzioni sono tutti vuoti, quindi nessuna ricetta viene copiata.
local function hasOverride(spellId, record)
    local function has(bucket, key)
        return type(bucket) == "table" and key ~= nil and bucket[key] ~= nil
    end
    return has(overrides.createdItemBySpellId, spellId)
        or has(overrides.recipeItemBySpellId, spellId)
        or has(overrides.categoryBySpellId, spellId)
        or has(overrides.selfOnlyOutputlessBySpellId, spellId)
        or has(overrides.bopOutputBySpellId, spellId)
        or has(overrides.bindTypeByCreatedItemId, record.createdItemId)
end

local function addCreatedItemIndex(index, createdItemId, spellId)
    if not createdItemId then
        return
    end
    local bucket = index[createdItemId]
    if not bucket then
        bucket = {}
        index[createdItemId] = bucket
    end
    bucket[#bucket + 1] = spellId
end

local function buildNavTreeFromRecords(recordsBySpellId)
    -- Mirror the structure the generator emits: a nested map
    -- profession -> category keyed by recipe IDs. One level of categories,
    -- because that is all the Forever client has.
    -- Each non-leaf node carries an `_all` array that unions every recipe
    -- under it so the runtime can answer "all recipes for this profession"
    -- or "all recipes in this category" with a single table get.
    local tree = {}
    for spellId, record in pairs(recordsBySpellId) do
        local profession = record.profession
        if profession then
            local profNode = tree[profession]
            if not profNode then
                profNode = { _all = {} }
                tree[profession] = profNode
            end
            profNode._all[#profNode._all + 1] = spellId

            local categoryKey = record.category or "misc"
            local catNode = profNode[categoryKey]
            if not catNode then
                catNode = { _all = {} }
                profNode[categoryKey] = catNode
            end
            catNode._all[#catNode._all + 1] = spellId
        end
    end
    for _, profNode in pairs(tree) do
        table.sort(profNode._all)
        for categoryKey, catNode in pairs(profNode) do
            if categoryKey ~= "_all" then
                table.sort(catNode._all)
            end
        end
    end
    return tree
end

local function overridesAffectClassification(overrideTable)
    if type(overrideTable) ~= "table" then return false end
    -- Only category overrides change the navTree's shape; other override
    -- buckets (createdItem, recipeItem, bopOutput, etc.) leave the nav
    -- classification unchanged.
    if type(overrideTable.categoryBySpellId) == "table"
        and next(overrideTable.categoryBySpellId) ~= nil then
        return true
    end
    return false
end

function RecipeMetadata:_Rebuild()
    generated = _G.RecipeRegistryRecipeMetadata or generated or {}
    overrides = _G.RecipeRegistryRecipeMetadataOverrides or overrides or {}
    self._generated = generated
    self._overrides = overrides
    self.metadataVersion = generated.metadataVersion
    self.schemaVersion = generated.schemaVersion
    self.flavor = generated.flavor
    self._recordsBySpellId = {}
    self._recipeItemToSpellId = {}
    self._createdItemToSpellIds = {}
    self._reagentItemIds = nil
    -- Drop the resolution-status memo so the next predicate call rebuilds
    -- it against the fresh record set.
    self._unresolvedSpellIdSet = nil

    -- Gli indici per oggetto il generatore li scrive gia', identici a quelli
    -- che si costruirebbero qui (verificato il 14/11: 2001 e 2330 voci, zero
    -- differenze). Si rifanno solo se mancano, come nei dati finti degli spec,
    -- o se una correzione cambia l'oggetto di una ricetta.
    local itemOverrides = next(overrides.createdItemBySpellId or {}) ~= nil
        or next(overrides.recipeItemBySpellId or {}) ~= nil
    local reuseIndexes = not itemOverrides
        and type(generated.recipeItemToSpellId) == "table"
        and type(generated.createdItemToSpellIds) == "table"

    local records = generated.recipesBySpellId or {}
    for _, key in ipairs(sortedRecordIds(records)) do
        local source = records[key]
        if type(source) == "table" then
            local spellId = tonumber(key)
            source.spellId = spellId
            local record = source
            if hasOverride(spellId, source) then
                record = shallowCopy(source)
                applyOverrides(record)
            end
            self._recordsBySpellId[spellId] = record
            if not reuseIndexes then
                if record.recipeItemId then
                    self._recipeItemToSpellId[record.recipeItemId] = spellId
                end
                addCreatedItemIndex(self._createdItemToSpellIds, record.createdItemId, spellId)
            end
        end
    end

    if reuseIndexes then
        self._recipeItemToSpellId = generated.recipeItemToSpellId
        self._createdItemToSpellIds = generated.createdItemToSpellIds
    else
        for _, spellIds in pairs(self._createdItemToSpellIds) do
            table.sort(spellIds)
        end
    end

    -- Prefer the static nav-tree baked into Generated.lua (fast, no Lua
    -- iteration at load) but fall back to a runtime build when it is absent
    -- (sample fixture) or when runtime overrides change classification.
    if generated.navTree and not overridesAffectClassification(overrides) then
        self._navTree = generated.navTree
    else
        self._navTree = buildNavTreeFromRecords(self._recordsBySpellId)
    end

    return self
end

local function normalizeNumericRecipeKey(recipeKey)
    local numeric = tonumber(recipeKey)
    if not numeric then
        return nil
    end
    return math.floor(numeric)
end

-- Ambiguous created-item keys (same item produced by more than one spell,
-- e.g. Gold Bar via Smelt Gold and Transmute: Iron to Gold) can be broken
-- when the caller knows which profession the recipe was scanned under.
-- `professionHint` is a normalized profession key ("mining", "alchemy").
-- Returns the single matching record, or nil when the hint is absent or
-- still matches zero / more than one candidate (e.g. the two-alchemy
-- elemental transmute pairs stay ambiguous by design).
local function resolveAmbiguousByProfession(self, spellIds, professionHint)
    if not professionHint then
        return nil
    end
    local match
    for _, spellId in ipairs(spellIds) do
        local record = self._recordsBySpellId[spellId]
        if record and record.profession == professionHint then
            if match then
                return nil
            end
            match = record
        end
    end
    return match
end

function RecipeMetadata:NormalizeRecipeKey(recipeKey, professionHint)
    local normalized = {
        recipeKey = recipeKey,
        source = "unknown",
    }

    local numeric = normalizeNumericRecipeKey(recipeKey)
    if not numeric then
        return normalized
    end

    if numeric < 0 then
        local spellId = -numeric
        local record = self._recordsBySpellId[spellId]
        normalized.spellId = spellId
        normalized.source = "spell"
        if record then
            normalized.recipeItemId = record.recipeItemId
            normalized.createdItemId = record.createdItemId
        end
        return normalized
    end

    if numeric == 0 then
        normalized.source = "invalidItem"
        return normalized
    end

    local recipeSpellId = self._recipeItemToSpellId[numeric]
    if recipeSpellId then
        local record = self._recordsBySpellId[recipeSpellId]
        normalized.spellId = recipeSpellId
        normalized.recipeItemId = numeric
        normalized.createdItemId = record and record.createdItemId or nil
        normalized.source = "recipeItem"
        return normalized
    end

    local createdSpellIds = self._createdItemToSpellIds[numeric]
    if createdSpellIds then
        normalized.createdItemId = numeric
        normalized.source = "createdItem"
        if #createdSpellIds == 1 then
            local spellId = createdSpellIds[1]
            local record = self._recordsBySpellId[spellId]
            normalized.spellId = spellId
            normalized.recipeItemId = record and record.recipeItemId or nil
        else
            local hinted = resolveAmbiguousByProfession(self, createdSpellIds, professionHint)
            if hinted then
                normalized.spellId = hinted.spellId
                normalized.recipeItemId = hinted.recipeItemId
            else
                normalized.ambiguousSpellIds = cloneSpellIdList(createdSpellIds)
            end
        end
        return normalized
    end

    normalized.source = "unknown"
    return normalized
end

function RecipeMetadata:GetRecipeInfo(recipeKey, professionHint)
    -- Hot path: skip the table allocation that NormalizeRecipeKey does when
    -- we just want the record. Called once per candidate inside the list
    -- build predicate cascade, so 300+ allocations per profession refresh
    -- otherwise pile up against the Lua GC.
    local numeric = tonumber(recipeKey)
    if not numeric then return nil end
    local floored = math.floor(numeric)
    if floored == 0 then return nil end
    if floored < 0 then
        return self._recordsBySpellId[-floored]
    end
    local recipeSpellId = self._recipeItemToSpellId[floored]
    if recipeSpellId then
        return self._recordsBySpellId[recipeSpellId]
    end
    local createdSpellIds = self._createdItemToSpellIds[floored]
    if type(createdSpellIds) == "table" then
        if #createdSpellIds == 1 then
            return self._recordsBySpellId[createdSpellIds[1]]
        end
        local hinted = resolveAmbiguousByProfession(self, createdSpellIds, professionHint)
        if hinted then
            return hinted
        end
    end
    -- Ambiguous or unknown: fall back to the full normalize so the
    -- caller still gets the ambiguity flag in GetMetadataResolutionStatus.
    return nil
end

local function getInfo(self, recipeKey, info)
    if type(info) == "table" then
        return info
    end
    return self:GetRecipeInfo(recipeKey)
end

function RecipeMetadata:GetProfession(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.profession or nil
end

function RecipeMetadata:GetCategory(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info or not info.category then
        return nil
    end
    return {
        category = info.category,
        sortOrder = info.sortOrder,
    }
end

-- Hash set of catalogued spell IDs for the given profession, optionally
-- narrowed to one category. The list builder consults this hash so
-- the only remaining runtime work is the BoP/ownership filter on a much
-- smaller set. Returns nil if the nav-tree is unavailable (callers fall back
-- to the per-recipe predicate).
function RecipeMetadata:BuildProfessionSpellIdHash(professionKey, categoryKey)
    local tree = self._navTree
    if not tree or not professionKey then return nil end
    local hash = {}
    local profNode = tree[professionKey]
    if not profNode then return hash end

    local function consumeArray(arr)
        if type(arr) ~= "table" then return end
        for i = 1, #arr do hash[arr[i]] = true end
    end

    if categoryKey then
        local catNode = profNode[categoryKey]
        if catNode then consumeArray(catNode._all) end
    else
        consumeArray(profNode._all)
    end
    return hash
end

function RecipeMetadata:GetCategoriesForProfession(professionKey)
    local generatedCategories = self._generated and self._generated.categoriesByProfession
    return cloneCategoryList(generatedCategories and generatedCategories[professionKey] or nil)
end

function RecipeMetadata:GetCreatedItemId(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.createdItemId or nil
end

-- Spell ID of the profession specialization required to learn this recipe,
-- or nil when any practitioner can learn it. The IDs match the ones
-- Data.lua PROFESSION_SPECIALIZATIONS detects on the local character, so a
-- caller can compare this directly against a scanned profession's
-- specialization. Note this means "required to learn" — specializations that
-- only improve yield (the TBC cloth cooldowns) are deliberately not flagged.
function RecipeMetadata:GetSpecialization(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.specialization or nil
end

-- Which classes a trainer will teach the recipe to, as the client's own class
-- bitmask, or nil when every class can learn it. The gate is on the RECIPE,
-- not on what it makes: a warrior can learn to craft a druid-only helm, but no
-- trainer will teach a warrior the Deathblow X11 Goggles. Twenty-two recipes
-- carry one and all of them are engineering goggles.
function RecipeMetadata:GetClassMask(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.classMask or nil
end

-- The content phase a recipe first becomes obtainable in, or nil for anything
-- available from the start -- which is the whole of Vanilla and most of
-- Burning Crusade. Absent means base content, never "unknown".
function RecipeMetadata:GetPhase(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.phase or nil
end

--- True for a recipe that is in the client data but not in the game: never
--- implemented, or taken out and never returned. There is nowhere to go and
--- learn one, so listing it among what a character could still learn is a
--- wild goose chase. Absent data reads as false, not as unknown.
function RecipeMetadata:IsRemoved(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info ~= nil and info.removed == true
end

-- Units produced per craft. The generated data omits the field for the
-- common single-output case, so absence means 1 rather than "unknown".
-- Returns min, max; the two differ only for the handful of recipes with a
-- random yield.
function RecipeMetadata:GetCreatedCount(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info then
        return nil
    end
    local minimum = tonumber(info.createdCount) or 1
    return minimum, tonumber(info.createdCountMax) or minimum
end

-- Every item that appears as a reagent of some recipe, as a set. Consumers
-- use it to bound their own per-item stores to things the addon will ever
-- actually price. Memoized and dropped on rebuild; the returned table is
-- freshly built, so callers may keep it.
function RecipeMetadata:GetReagentItemIds()
    if self._reagentItemIds then return self._reagentItemIds end
    local ids = {}
    for _, record in pairs(self._recordsBySpellId or {}) do
        for _, reagent in ipairs(record.reagents or {}) do
            if reagent.itemId then
                ids[reagent.itemId] = true
            end
        end
    end
    self._reagentItemIds = ids
    return ids
end

-- Where a recipe is obtained, for the ones taught by an item. Returns nil
-- when nothing is known -- a trainer-taught recipe has no recipe item and so
-- no entry, which is itself the answer.
--
-- `faction` is nil when both factions can get it, which is the common case;
-- callers must not read nil as "unknown". Zone IDs are resolved to names
-- here, from the table the generator emits once at the top level rather than
-- repeating a popular vendor city on hundreds of records.
function RecipeMetadata:GetSource(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info then return nil end
    if not (info.faction or info.sourceKind or info.worldDrop or info.bossDrop) then
        return nil
    end

    -- Places come back as { name, zone } pairs with the zone resolved. Either
    -- half can be missing: a quest names a zone and nobody, and a recipe every
    -- trainer teaches names neither.
    local zoneNames = self._generated and self._generated.zoneNamesById or nil
    local function resolvePlaces(list)
        local places
        for _, place in ipairs(list or {}) do
            local zone = place.zone and zoneNames and zoneNames[place.zone] or nil
            if place.name or zone then
                places = places or {}
                places[#places + 1] = {
                    name = place.name,
                    zone = zone,
                    x = place.x,
                    y = place.y,
                    faction = place.faction,
                }
            end
        end
        return places
    end

    -- The other ways to get it, after the main one and in the generator's
    -- order. On Forever a recipe can drop AND be a quest reward -- Pattern:
    -- Blue Suede Armor does both -- and the main source alone hid the other.
    local also
    for _, extra in ipairs(info.alsoSources or {}) do
        if extra.kind then
            also = also or {}
            also[#also + 1] = {
                kind = extra.kind,
                worldDrop = extra.worldDrop == true,
                bossDrop = extra.bossDrop == true,
                places = resolvePlaces(extra.places),
                trainerTitle = extra.trainerTitle,
            }
        end
    end

    return {
        faction = info.faction,
        kind = info.sourceKind,
        worldDrop = info.worldDrop == true,
        bossDrop = info.bossDrop == true,
        places = resolvePlaces(info.sourcePlaces),
        -- Trainer-taught recipes have no places -- no source names the NPCs --
        -- so the answer they do have is the title every one of their trainers
        -- carries, which is the line the player reads under the NPC in game.
        trainerTitle = info.trainerTitle,
        trainerContinents = info.trainerContinents,
        also = also,
    }
end

-- The four difficulty thresholds, when the source stated a usable ladder.
-- 2490 of the 2520 records carry one, built by the generator from the
-- client's three (learn, yellow, grey); the rest have to be approximated from
-- the skill requirement, which is the caller's problem and not this one's.
function RecipeMetadata:GetSkillLevels(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    local levels = info and info.skillLevels or nil
    if type(levels) ~= "table" or #levels ~= 4 then return nil end
    return levels
end

function RecipeMetadata:GetRecipeItemId(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.recipeItemId or nil
end

function RecipeMetadata:GetReagents(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and cloneReagents(info.reagents) or nil
end

function RecipeMetadata:IsOutputlessSelfOnly(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.selfOnlyOutputless == true or false
end

function RecipeMetadata:IsBopOutput(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info then
        return nil
    end
    return info.bopOutput
end

local function addUnresolved(out, spellId, field, severity, message)
    out[#out + 1] = {
        spellId = spellId,
        field = field,
        severity = severity,
        message = message,
    }
end

function RecipeMetadata:_CollectUnresolvedRecords()
    local out = {}
    for _, spellId in ipairs(sortedRecordIds(self._recordsBySpellId)) do
        local record = self._recordsBySpellId[spellId]
        if not record.profession or record.profession == "" then
            addUnresolved(out, spellId, "profession", "release-blocking", "missing profession")
        end
        if not record.category or record.category == "" then
            addUnresolved(out, spellId, "category", "release-blocking", "missing category")
        end
        if record.sortOrder == nil then
            addUnresolved(out, spellId, "sortOrder", "release-blocking", "missing sort order")
        end
        -- Niente controllo "manca l'oggetto prodotto". Su Forever ogni record
        -- viene dal client, e un createdItemId assente e' la risposta del
        -- client, non un buco: incantamenti e Tinker non producono un oggetto.
        if not record.selfOnlyOutputless and (type(record.reagents) ~= "table" or #record.reagents == 0) then
            addUnresolved(out, spellId, "reagents", "warning", "missing reagents")
        end
    end
    return out
end

-- Build a set { [spellId] = true } of records that have at least one
-- unresolved field. The full _CollectUnresolvedRecords walk is O(N)
-- over every catalogued record (~2150 in the current dataset); doing
-- it inside RecipePasses meant 300+ × 2150 ops per profession list
-- build, which produced visible CPU spikes when opening a profession.
-- The set is built once per metadata rebuild and lookup is O(1).
local function ensureUnresolvedSpellIdSet(self)
    if self._unresolvedSpellIdSet ~= nil then
        return self._unresolvedSpellIdSet
    end
    local set = {}
    for _, unresolved in ipairs(self:_CollectUnresolvedRecords()) do
        local spellId = unresolved and unresolved.spellId
        if spellId then
            set[spellId] = true
        end
    end
    self._unresolvedSpellIdSet = set
    return set
end

function RecipeMetadata:GetMetadataResolutionStatus(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if info then
        -- Resolved record. ambiguousSpellIds can only flag NULL info, so
        -- skip the full NormalizeRecipeKey call (which allocates a fresh
        -- table) when we already have a record.
        return ensureUnresolvedSpellIdSet(self)[info.spellId]
            and "unresolved" or "resolved"
    end
    -- info is nil: either ambiguous mapping or genuinely unknown.
    local normalized = self:NormalizeRecipeKey(recipeKey)
    if normalized.ambiguousSpellIds then
        return "ambiguous"
    end
    return "unresolved"
end

function RecipeMetadata:GetUnresolvedRecords(severity)
    local out = {}
    for _, unresolved in ipairs(self:_CollectUnresolvedRecords()) do
        if severity == nil or unresolved.severity == severity then
            out[#out + 1] = unresolved
        end
    end
    return out
end

function RecipeMetadata:GetRecordCounts()
    local counts = {
        recipes = 0,
        unresolved = 0,
        ambiguousCreatedItems = 0,
        recipeItems = countTable(self._recipeItemToSpellId),
        createdItems = countTable(self._createdItemToSpellIds),
        overrides = countOverrideEntries(),
    }

    for _, record in pairs(self._recordsBySpellId or {}) do
        counts.recipes = counts.recipes + 1
    end

    for _, spellIds in pairs(self._createdItemToSpellIds or {}) do
        if #spellIds > 1 then
            counts.ambiguousCreatedItems = counts.ambiguousCreatedItems + 1
        end
    end

    counts.unresolved = #self:GetUnresolvedRecords()
    return counts
end

RecipeMetadata:_Rebuild()
Addon.RecipeMetadata = RecipeMetadata
