-- Missing-recipe projection: what the CURRENT character could still learn.
--
-- This is a different question from the rest of the addon. Everywhere else
-- Recipe Registry answers "who in the guild can craft this"; here it answers
-- "what does my profession still have that I have not learned". The two
-- never mix in one list, so this lives behind its own tab.
--
-- Everything is computed from data already on disk: the metadata library
-- knows every catalogued recipe per profession, the local scan knows what
-- this character learned, and the profession block carries the skill rank
-- and the specialization. No network, no scan, and no new saved state
-- beyond the per-profession opt-out.
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
-- specialization the last scan recorded. Alts are deliberately out: "what am
-- I missing" is a question about the character at the keyboard, and an alt
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

function Data:IsMissingRecipesEnabledForProfession(professionName)
    local profile = Addon.db and Addon.db.profile
    local disabled = profile and profile.missingRecipesDisabledProfessions
    if type(disabled) ~= "table" then return true end
    return disabled[professionName] ~= true
end

-- The one filter this view has. With three hundred candidates on a maxed
-- profession, "what can I go and learn right now" is a different question
-- from "what does this profession have left", and the sort alone does not
-- answer it once the ready recipes run past the bottom of the window.
-- Off by default: the full list is the honest answer.
function Data:IsMissingRecipesLearnableOnly()
    local profile = Addon.db and Addon.db.profile
    return (profile and profile.missingRecipesLearnableOnly) == true
end

function Data:SetMissingRecipesLearnableOnly(enabled)
    local profile = Addon.db and Addon.db.profile
    if not profile then return end
    profile.missingRecipesLearnableOnly = (enabled == true) or nil
end

function Data:SetMissingRecipesEnabledForProfession(professionName, enabled)
    local profile = Addon.db and Addon.db.profile
    if not profile or not professionName then return end
    if type(profile.missingRecipesDisabledProfessions) ~= "table" then
        profile.missingRecipesDisabledProfessions = {}
    end
    profile.missingRecipesDisabledProfessions[professionName] = (enabled == false) or nil
end

-- How the recipe reaches the player lives in Data:DescribeRecipeSource, next
-- to the recipe display data rather than here: the detail panel asks the same
-- question about recipes that are not missing at all, and the two views must
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
function Data:ResolveMissingRow(row)
    if not row or row._missingResolved then return row end
    local professionName = row.missing and row.missing.professionName or nil
    local detail = self.GetRecipeDisplayInfo
        and self:GetRecipeDisplayInfo(row.recipeKey, professionName) or nil
    row.detail = detail
    row.label = (detail and detail.label)
        or (self.ResolveRecipeLabel and self:ResolveRecipeLabel(row.recipeKey))
        or tostring(row.recipeKey)
    row._missingResolved = true
    return row
end

-- One row per catalogued recipe of this profession that the character has
-- not learned. Rows carry the same shape the recipe list uses so they go
-- through the ordinary row renderer, plus a `missing` block the renderer
-- reads for the skill / source / specialization line.
function Data:BuildMissingRecipeRowsForProfession(professionName, prof)
    local meta = metadata()
    if not meta or not professionName or not prof then return {} end

    local filters = Addon.RecipeUiFilters
    local professionKey = filters and filters.NormalizeProfessionKey
        and filters:NormalizeProfessionKey(professionName) or nil
    if not professionKey then return {} end

    -- Reuse the expansion visibility the rest of the UI is filtered by, so a
    -- player who hides Vanilla is not told they are missing 1248 vanilla
    -- recipes.
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
        local recipeKey = -spellId
        if not self:IsRecipeKnownByCurrentPlayer(recipeKey) then
            local info = meta:GetRecipeInfo(recipeKey, professionKey)
            -- Deliberately NOT run through RecipePasses. The expansion
            -- prefilter is already applied above, via the candidate hash,
            -- and every candidate is catalogued by construction. What is
            -- left in that predicate is the ownership-driven filtering --
            -- remote BoP, self-only outputless -- which exists because
            -- another player's soulbound craft is useless to you. A
            -- soulbound craft YOU could learn is the opposite: exactly what
            -- this view is for. The profit filter has no business here
            -- either; you cannot craft what you have not learned.
            --
            -- Recipes that are in the client data but not in the game are the
            -- one exclusion this view does make. There is nowhere to go and
            -- learn them, so listing them is not an opportunity, it is a
            -- player walking Azeroth looking for a trainer who does not exist.
            if not (meta.IsRemoved and meta:IsRemoved(recipeKey, info)) then
                local requiredSkill = tonumber(info and info.requiredSkill) or nil
                local specializationId = meta.GetSpecialization
                    and meta:GetSpecialization(recipeKey, info) or nil
                local source = self:DescribeRecipeSource(recipeKey, professionKey, info)
                rows[#rows + 1] = {
                    recipeKey = recipeKey,
                    -- detail and label are filled in by ResolveMissingRow,
                    -- for visible rows only.
                    crafterCount = 0,
                    onlineCount = 0,
                    professionList = { professionName },
                    missing = {
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
    end

    return rows
end

-- Every enabled profession of the current character, in one list. Sorted so
-- the recipes the character can go and learn right now come first: skill met
-- and specialization met, then by required skill, then by profession.
--
-- Note the sort never reads a name: names are unresolved at this point by
-- design, and resolving 600 of them to break ties would cost exactly what
-- the lazy build is here to avoid. The recipe key is the final tiebreak, so
-- the order is still stable between rebuilds.
function Data:BuildMissingRecipeRows()
    local rows = {}
    local learnableOnly = self:IsMissingRecipesLearnableOnly()
    for professionName, prof in pairs(self:GetLocalProfessionBlocks()) do
        if self:IsMissingRecipesEnabledForProfession(professionName) then
            local professionRows = self:BuildMissingRecipeRowsForProfession(professionName, prof)
            for _, row in ipairs(professionRows) do
                if not learnableOnly or (row.missing.skillMet and row.missing.specializationMet) then
                    rows[#rows + 1] = row
                end
            end
        end
    end

    sort(rows, function(a, b)
        local am, bm = a.missing, b.missing
        local aReady = (am.skillMet and am.specializationMet) and 1 or 0
        local bReady = (bm.skillMet and bm.specializationMet) and 1 or 0
        if aReady ~= bReady then return aReady > bReady end
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
