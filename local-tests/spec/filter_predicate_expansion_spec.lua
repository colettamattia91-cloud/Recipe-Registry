local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local metadataAddon, _wow, addon = Loader.LoadMetadata({ fixture = true })
local data = addon.Data
local filters = addon.RecipeUiFilters

local function seedMember(memberKey, profession, recipeKeys)
    local entry = data:GetOrCreateMember(memberKey)
    entry.guildStatus = "active"
    entry.sourceType = entry.sourceType or "replica"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = entry.professions or {}
    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys) do
        recipes[recipeKey] = true
    end
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = #recipeKeys,
        skillRank = 375,
        skillMaxRank = 375,
        sourceType = entry.sourceType,
    })
    data:InvalidateRecipeCaches()
end

Test.it("hides Vanilla and shows TBC with default expansion visibility", function()
    -- Default flipped to TBC-only — vanilla recipes are filtered out
    -- unless the user opts back in via /rr options.
    local vanillaPasses, vanillaReason = filters:RecipePasses(-2329)
    local tbcPasses, tbcReason = filters:RecipePasses(-28596)

    Test.eq(vanillaPasses, false)
    Test.eq(vanillaReason, "hidden-expansion")
    Test.eq(tbcPasses, true)
    Test.eq(tbcReason, "visible-normal")
    Test.truthy(metadataAddon.RecipeMetadata, "metadata plugin should be present")
end)

Test.it("passes Vanilla and TBC recipes when both expansions are enabled", function()
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true

    local vanillaPasses, vanillaReason = filters:RecipePasses(-2329)
    local tbcPasses, tbcReason = filters:RecipePasses(-28596)

    Test.eq(vanillaPasses, true)
    Test.eq(vanillaReason, "visible-normal")
    Test.eq(tbcPasses, true)
    Test.eq(tbcReason, "visible-normal")
end)

Test.it("hides globally disabled Vanilla recipes without hiding TBC", function()
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true

    local vanillaPasses, vanillaReason = filters:RecipePasses(-2329)
    local tbcPasses, tbcReason = filters:RecipePasses(-28596)

    Test.eq(vanillaPasses, false)
    Test.eq(vanillaReason, "hidden-expansion")
    Test.eq(tbcPasses, true)
    Test.eq(tbcReason, "visible-normal")
end)

Test.it("uses per-profession expansion overrides ahead of global defaults", function()
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.professionExpansionOverrides.engineering = {
        inherit = false,
        vanilla = false,
        tbc = true,
    }

    local engineeringPasses, engineeringReason = filters:RecipePasses(-3918)
    local alchemyPasses, alchemyReason = filters:RecipePasses(-2329)

    Test.eq(engineeringPasses, false)
    Test.eq(engineeringReason, "hidden-expansion")
    Test.eq(alchemyPasses, true)
    Test.eq(alchemyReason, "visible-normal")
end)

Test.it("applies expansion predicate before row detail construction", function()
    addon.db.profile.recipePrefilters.professionExpansionOverrides = {}
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true
    seedMember("Remoteone-TestRealm", "Alchemy", { -2329, -28596 })

    local original = data.GetRecipeDisplayInfo
    local calls = {}
    data.GetRecipeDisplayInfo = function(self, recipeKey)
        calls[tostring(recipeKey)] = (calls[tostring(recipeKey)] or 0) + 1
        return original(self, recipeKey)
    end

    local rows = data:GetRecipeList("Alchemy", "", "alpha", "recipe", nil, {})
    data.GetRecipeDisplayInfo = original

    Test.eq(#rows, 1)
    Test.eq(rows[1].recipeKey, -28596)
    Test.eq(calls["-2329"], nil, "hidden Vanilla recipe should not build detail")
    Test.eq(calls["-28596"], 1, "visible TBC recipe should build detail")
end)

Test.it("hides ambiguous created-item keys when every candidate spell is filtered", function()
    -- Bolt of Imbued Netherweave (21840) maps to two tailoring TBC spells
    -- (26745/26746) — ambiguous even with a profession hint, exactly like
    -- the Essence of Water / Essence of Earth vanilla transmute pairs in
    -- live data. When every candidate would be hidden by the expansion
    -- prefilter, the conservative-show path must not leak the entry.
    addon.db.profile.recipePrefilters.professionExpansionOverrides = {}
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = false

    local passes, reason = filters:RecipePasses(21840)
    Test.eq(passes, false)
    Test.eq(reason, "hidden-expansion")
end)

Test.it("keeps ambiguous created-item keys visible when their expansion is enabled", function()
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true

    local passes, reason = filters:RecipePasses(21840)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unresolved-conservative")
end)

Test.it("keeps cross-profession ambiguous keys visible via the mining candidate", function()
    -- Gold Bar (3577): Smelt Gold (mining) + Transmute: Iron to Gold
    -- (alchemy), both vanilla. Mining is expansion-agnostic in the UI, so
    -- the entry stays visible even with vanilla hidden.
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    addon.db.profile.recipePrefilters.expansionDefaults.tbc = true

    local passes, reason = filters:RecipePasses(3577)
    Test.eq(passes, true)
    Test.eq(reason, "visible-unresolved-conservative")
end)
