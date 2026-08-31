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

function Data:SetMissingRecipesEnabledForProfession(professionName, enabled)
    local profile = Addon.db and Addon.db.profile
    if not profile or not professionName then return end
    if type(profile.missingRecipesDisabledProfessions) ~= "table" then
        profile.missingRecipesDisabledProfessions = {}
    end
    profile.missingRecipesDisabledProfessions[professionName] = (enabled == false) or nil
end

-- How the recipe reaches the player. The metadata carries no learn-source
-- field -- alternate teaching sources are explicitly out of scope for the
-- generator -- but recipeItemId is a usable proxy: a recipe with a teaching
-- item is a pattern, plans or recipe you find, buy or loot, and one without
-- is taught directly by a trainer.
local function describeSource(info)
    if info and info.recipeItemId then
        return "item", "From a recipe item"
    end
    return "trainer", "From a trainer"
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
            do
                local detail = self.GetRecipeDisplayInfo
                    and self:GetRecipeDisplayInfo(recipeKey, professionName) or nil
                local requiredSkill = tonumber(info and info.requiredSkill) or nil
                local specializationId = meta.GetSpecialization
                    and meta:GetSpecialization(recipeKey, info) or nil
                local sourceKind, sourceLabel = describeSource(info)
                rows[#rows + 1] = {
                    recipeKey = recipeKey,
                    detail = detail,
                    label = (detail and detail.label)
                        or (self.ResolveRecipeLabel and self:ResolveRecipeLabel(recipeKey))
                        or tostring(recipeKey),
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
                        sourceKind = sourceKind,
                        sourceLabel = sourceLabel,
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
-- and specialization met, then by required skill, then by profession, then
-- by name.
function Data:BuildMissingRecipeRows()
    local rows = {}
    for professionName, prof in pairs(self:GetLocalProfessionBlocks()) do
        if self:IsMissingRecipesEnabledForProfession(professionName) then
            local professionRows = self:BuildMissingRecipeRowsForProfession(professionName, prof)
            for _, row in ipairs(professionRows) do
                rows[#rows + 1] = row
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
        local al = tostring(a.label):lower()
        local bl = tostring(b.label):lower()
        if al ~= bl then return al < bl end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)

    return rows
end
