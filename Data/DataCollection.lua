-- Collection projection: this character's own profession recipe book.
--
-- This is a different question from the rest of the addon. Everywhere else
-- Recipe Registry answers "who in the guild can craft this"; here it answers
-- "how much of my profession do I have, and where is the rest". The two
-- never mix in one list, so this lives behind its own tab.
--
-- Every catalogued recipe of the character's professions gets a row, learned
-- or not, because a collection you can only see the holes in is not a
-- collection. `known` is what separates the two halves; the view decides how
-- much of it to draw.
--
-- Everything is computed from data already on disk: the metadata library
-- knows every catalogued recipe per profession, the local scan knows what
-- this character learned, and the profession block carries the skill rank
-- and the specialization. No network, no scan, and no new saved state
-- beyond the per-profession opt-out and the view filter.
local Addon = _G.RecipeRegistry
local Data = Addon.Data

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local tostring = tostring
local tonumber = tonumber

local function metadata()
    return Addon.RecipeMetadata
end

local function specializationsFor(professionName)
    local specs = Data.PROFESSION_SPECIALIZATIONS
    return specs and specs[professionName] or nil
end

-- prof.specialization holds the display name ("Armorsmith"); the metadata
-- library reports the requirement as the spell ID. Bridge the two through
-- the table Data already keeps.
function Data:GetSpecializationSpellId(professionName, specializationName)
    if not professionName or not specializationName then return nil end
    for _, spec in ipairs(specializationsFor(professionName) or {}) do
        if spec.name == specializationName then
            return spec.spellID
        end
    end
    return nil
end

function Data:GetSpecializationName(professionName, specializationSpellId)
    if not professionName or not specializationSpellId then return nil end
    for _, spec in ipairs(specializationsFor(professionName) or {}) do
        if spec.spellID == specializationSpellId then
            return spec.name
        end
    end
    return nil
end

-- The professions of the character actually being played, with the rank and
-- specialization the last scan recorded. Alts are deliberately out: "what is
-- in my book" is a question about the character at the keyboard, and an alt
-- row would be indistinguishable from a real one in the same list.
function Data:GetLocalProfessionBlocks()
    local out = {}
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMembersDB()[playerKey]
    if not entry or type(entry.professions) ~= "table" then
        return out
    end
    for professionName, prof in pairs(entry.professions) do
        if type(prof) == "table" then
            out[professionName] = prof
        end
    end
    return out
end

function Data:IsCollectionEnabledForProfession(professionName)
    local profile = Addon.db and Addon.db.profile
    local disabled = profile and profile.collectionDisabledProfessions
    if type(disabled) ~= "table" then return true end
    return disabled[professionName] ~= true
end

function Data:SetCollectionEnabledForProfession(professionName, enabled)
    local profile = Addon.db and Addon.db.profile
    if not profile or not professionName then return end
    if type(profile.collectionDisabledProfessions) ~= "table" then
        profile.collectionDisabledProfessions = {}
    end
    profile.collectionDisabledProfessions[professionName] = (enabled == false) or nil
end

-- The view's one control, and deliberately one rather than two switches: the
-- three states are a strict narrowing, so a single button that cycles through
-- them says everything two checkboxes would, without asking the reader to
-- work out what their four combinations mean.
--
--   all       the whole book, learned recipes ticked
--   unlearned only the holes
--   ready     only the holes you can fill today
--
-- "all" is the default because the collection is the point of the tab.
local COLLECTION_FILTERS = {
    all = true,
    unlearned = true,
    ready = true,
}
local COLLECTION_FILTER_ORDER = { "all", "unlearned", "ready" }

Data.COLLECTION_FILTER_ORDER = COLLECTION_FILTER_ORDER

function Data:GetCollectionFilter()
    local profile = Addon.db and Addon.db.profile
    local filter = profile and profile.collectionFilter
    return COLLECTION_FILTERS[filter] and filter or "all"
end

function Data:SetCollectionFilter(filter)
    local profile = Addon.db and Addon.db.profile
    if not profile then return end
    -- The default is stored as absence, the same way the per-profession
    -- opt-out is: a profile that never touched the filter and one set back to
    -- "all" are the same profile.
    if filter == "all" or not COLLECTION_FILTERS[filter] then
        profile.collectionFilter = nil
        return
    end
    profile.collectionFilter = filter
end

function Data:CycleCollectionFilter()
    local current = self:GetCollectionFilter()
    for index, filter in ipairs(COLLECTION_FILTER_ORDER) do
        if filter == current then
            local nextFilter = COLLECTION_FILTER_ORDER[index + 1] or COLLECTION_FILTER_ORDER[1]
            self:SetCollectionFilter(nextFilter)
            return nextFilter
        end
    end
    self:SetCollectionFilter(COLLECTION_FILTER_ORDER[1])
    return COLLECTION_FILTER_ORDER[1]
end

-- Whether a row survives the current filter. Lives here rather than in the
-- view so the rule is testable, but it is applied at draw time: the rows the
-- filter hides still have to be counted, or a profession header could not say
-- 185 of 385.
function Data:CollectionRowPasses(row, filter)
    local collection = row and row.collection
    if not collection then return false end
    filter = filter or self:GetCollectionFilter()
    if filter == "unlearned" then
        return not collection.known
    end
    if filter == "ready" then
        return not collection.known
            and collection.skillMet == true
            and collection.specializationMet == true
    end
    return true
end

-- How the recipe reaches the player lives in Data:DescribeRecipeSource, next
-- to the recipe display data rather than here: the detail panel asks the same
-- question about recipes that are not in this view at all, and the two must
-- not drift into two vocabularies.

-- Names, icons and item quality come from Data:GetRecipeDisplayInfo, which
-- costs two GetItemInfo calls per recipe and takes a slot in a 256-entry
-- cache. A blacksmith alone has ~385 catalogued recipes and a second
-- profession pushes the total past 600, so resolving every candidate would
-- blow that cache on every rebuild -- evicting entries the recipe browser
-- needs -- and would do it synchronously on every list refresh while the
-- tab is open.
--
-- So rows are built cheap and stay unresolved. The row renderer resolves
-- the handful it actually paints, exactly as the ordinary recipe list does
-- through RefreshRecipeRowAssets.
function Data:ResolveCollectionRow(row)
    if not row or row._collectionResolved then return row end
    local professionName = row.collection and row.collection.professionName or nil
    local detail = self.GetRecipeDisplayInfo
        and self:GetRecipeDisplayInfo(row.recipeKey, professionName) or nil
    row.detail = detail
    row.label = (detail and detail.label)
        or (self.ResolveRecipeLabel and self:ResolveRecipeLabel(row.recipeKey))
        or tostring(row.recipeKey)
    row._collectionResolved = true
    return row
end

-- One row per catalogued recipe of this profession, learned or not. Rows
-- carry the same shape the recipe list uses so they go through the ordinary
-- row renderer, plus a `collection` block the renderer reads for the status /
-- source / specialization line.
function Data:BuildCollectionRowsForProfession(professionName, prof)
    local meta = metadata()
    if not meta or not professionName or not prof then return {} end

    local filters = Addon.RecipeUiFilters
    local professionKey = filters and filters.NormalizeProfessionKey
        and filters:NormalizeProfessionKey(professionName) or nil
    if not professionKey then return {} end

    -- Reuse the expansion visibility the rest of the UI is filtered by, so a
    -- player who hides Vanilla is not shown a 1248-recipe vanilla book they
    -- asked not to see.
    local visibility = filters and filters.GetEffectiveExpansionVisibility
        and filters:GetEffectiveExpansionVisibility(professionKey)
        or { vanilla = true, tbc = true }
    local candidates = meta.BuildVisibleSpellIdHash
        and meta:BuildVisibleSpellIdHash(professionKey, visibility) or nil
    if not candidates then return {} end

    local skillRank = tonumber(prof.skillRank) or 0
    local ownedSpecializationId = self:GetSpecializationSpellId(professionName, prof.specialization)

    local rows = {}
    for spellId in pairs(candidates) do
        -- Two key shapes, and they are not interchangeable.
        --
        -- The catalogue is indexed by spell id. A profession SCAN is not: it
        -- keys a recipe by the item it creates, and falls back to the negative
        -- spell id only for a craft that makes no item. Enchanting is the one
        -- profession where the two agree, which is why it alone looked right
        -- while every other profession reported nothing learned.
        --
        -- The row keeps the catalogue key, because that is the one that always
        -- resolves: a created item shared by more than one recipe is dropped
        -- from the by-item index, so an alchemy discovery looked up by its
        -- item comes back empty and loses its name, icon and source. Only the
        -- ownership question is asked in the scan's shape -- both shapes, in
        -- fact, since for an ambiguous created item the scanner writes the
        -- item key and the spell key.
        local recipeKey = -spellId
        local info = meta:GetRecipeInfo(recipeKey, professionKey)
        local createdItemId = meta:GetCreatedItemId(recipeKey, info)
        local known = self:IsRecipeKnownByCurrentPlayer(recipeKey)
            or (createdItemId ~= nil and self:IsRecipeKnownByCurrentPlayer(createdItemId))
            or false
        -- Deliberately NOT run through RecipePasses. The expansion prefilter
        -- is already applied above, via the candidate hash, and every
        -- candidate is catalogued by construction. What is left in that
        -- predicate is the ownership-driven filtering -- remote BoP,
        -- self-only outputless -- which exists because another player's
        -- soulbound craft is useless to you. A soulbound craft in your own
        -- book is the opposite: exactly what this view is for. The profit
        -- filter has no business here either; this list is not a shopping
        -- list.
        --
        -- Recipes that are in the client data but not in the game are the one
        -- exclusion this view makes, and only among the ones you do not have:
        -- there is nowhere to go and learn them, so listing them is not an
        -- opportunity, it is a player walking Azeroth looking for a trainer
        -- who does not exist. One you somehow DO know stays, because it is
        -- genuinely in your book.
        if known or not (meta.IsRemoved and meta:IsRemoved(recipeKey, info)) then
            local requiredSkill = tonumber(info and info.requiredSkill) or nil
            local specializationId = meta.GetSpecialization
                and meta:GetSpecialization(recipeKey, info) or nil
            local source = self:DescribeRecipeSource(recipeKey, professionKey, info)
            rows[#rows + 1] = {
                recipeKey = recipeKey,
                -- detail and label are filled in by ResolveCollectionRow,
                -- for visible rows only.
                crafterCount = 0,
                onlineCount = 0,
                professionList = { professionName },
                collection = {
                    known = known,
                    professionName = professionName,
                    requiredSkill = requiredSkill,
                    skillRank = skillRank,
                    -- Learnable now, or does the character have to level
                    -- the profession further first?
                    skillMet = requiredSkill == nil or skillRank >= requiredSkill,
                    sourceKind = source.kind,
                    sourceLabel = source.label,
                    -- One line per place, for the row tooltip: the table
                    -- column clips, and a recipe sold in four cities is
                    -- exactly the case where the clipped half matters.
                    sourceLines = source.lines,
                    -- nil means both factions, which is the common case:
                    -- the generator omits the field rather than repeating
                    -- it on most of the dataset.
                    faction = source.faction,
                    sourcePlaces = source.places,
                    specializationSpellId = specializationId,
                    specializationName = specializationId
                        and self:GetSpecializationName(professionName, specializationId) or nil,
                    specializationMet = specializationId == nil
                        or specializationId == ownedSpecializationId,
                },
            }
        end
    end

    return rows
end

-- Every enabled profession of the current character, in one list, unfiltered:
-- the view filter runs at draw time so the profession headers can still count
-- the rows it hides.
--
-- Sorted so the recipes the character can go and get right now come first,
-- then the ones still out of reach, then the ones already in the book. Within
-- each of the three, by required skill, which is the order a profession is
-- actually levelled in.
--
-- Note the sort never reads a name: names are unresolved at this point by
-- design, and resolving 800 of them to break ties would cost exactly what
-- the lazy build is here to avoid. The recipe key is the final tiebreak, so
-- the order is still stable between rebuilds.
function Data:BuildCollectionRows()
    local rows = {}
    for professionName, prof in pairs(self:GetLocalProfessionBlocks()) do
        if self:IsCollectionEnabledForProfession(professionName) then
            local professionRows = self:BuildCollectionRowsForProfession(professionName, prof)
            for _, row in ipairs(professionRows) do
                rows[#rows + 1] = row
            end
        end
    end

    local function rank(collection)
        if collection.known then return 2 end
        if collection.skillMet and collection.specializationMet then return 0 end
        return 1
    end

    sort(rows, function(a, b)
        local am, bm = a.collection, b.collection
        local aRank, bRank = rank(am), rank(bm)
        if aRank ~= bRank then return aRank < bRank end
        local ask = am.requiredSkill or 0
        local bsk = bm.requiredSkill or 0
        if ask ~= bsk then return ask < bsk end
        if am.professionName ~= bm.professionName then
            return am.professionName < bm.professionName
        end
        return (tonumber(a.recipeKey) or 0) > (tonumber(b.recipeKey) or 0)
    end)

    return rows
end
