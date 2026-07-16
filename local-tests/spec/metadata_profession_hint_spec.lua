-- Profession-hint disambiguation for created-item recipe keys.
--
-- Some created items map to more than one crafting spell (Gold Bar via
-- Smelt Gold [mining] and Transmute: Iron to Gold [alchemy]). Scanned
-- guild data stores these as the positive created-item key, so without
-- context the metadata lookup is ambiguous and the UI cannot show
-- reagents ("no material mapping available"). The profession the block
-- was scanned under breaks the tie; same-profession pairs (the elemental
-- transmutes) must stay ambiguous.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

io.write("Metadata profession-hint disambiguation\n")

local function freshAddon()
    local addon = Loader.LoadMetadata({ fixture = true })
    return addon, addon.Data, addon.RecipeMetadata
end

local function seedMember(data, memberKey, profession, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = opts.updatedAt or 100
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipeKeys,
        count = opts.count or 0,
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 375,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    return entry
end

Test.it("GetRecipeInfo resolves cross-profession ambiguity with a hint", function()
    local _addon, _data, metadata = freshAddon()

    Test.eq(metadata:GetRecipeInfo(3577), nil, "plain lookup stays ambiguous")
    Test.eq(metadata:GetMetadataResolutionStatus(3577), "ambiguous")

    local mining = metadata:GetRecipeInfo(3577, "mining")
    Test.truthy(mining, "mining hint resolves Gold Bar to Smelt Gold")
    Test.eq(mining.spellId, 3308)
    Test.eq(mining.reagents[1].itemId, 2776)

    local alchemy = metadata:GetRecipeInfo(3577, "alchemy")
    Test.truthy(alchemy, "alchemy hint resolves Gold Bar to the transmute")
    Test.eq(alchemy.spellId, 11479)
    Test.eq(alchemy.reagents[1].itemId, 3575)
end)

Test.it("NormalizeRecipeKey honours the same hint", function()
    local _addon, _data, metadata = freshAddon()

    local hinted = metadata:NormalizeRecipeKey(3577, "mining")
    Test.eq(hinted.source, "createdItem")
    Test.eq(hinted.spellId, 3308)
    Test.eq(hinted.ambiguousSpellIds, nil, "hint removes the ambiguity flag")

    local plain = metadata:NormalizeRecipeKey(3577)
    Test.eq(plain.spellId, nil)
    Test.eq(#plain.ambiguousSpellIds, 2)
end)

Test.it("same-profession ambiguity stays ambiguous even with a hint", function()
    local _addon, _data, metadata = freshAddon()
    Test.eq(metadata:GetRecipeInfo(21840, "tailoring"), nil)
    local normalized = metadata:NormalizeRecipeKey(21840, "tailoring")
    Test.eq(#normalized.ambiguousSpellIds, 2)
end)

Test.it("wrong or non-profession hints keep the conservative nil", function()
    local _addon, _data, metadata = freshAddon()
    Test.eq(metadata:GetRecipeInfo(3577, "cooking"), nil)
    Test.eq(metadata:GetRecipeInfo(3577, "favorites"), nil)
end)

Test.it("GetRecipeDisplayInfo resolves per profession context with distinct cache entries", function()
    local _addon, data = freshAddon()

    local mining = data:GetRecipeDisplayInfo(3577, "Mining")
    Test.eq(mining.spellID, 3308)
    data:EnsureRecipeReagents(mining)
    Test.eq(mining.reagents[1].itemID, 2776, "mining context shows Gold Ore")

    local alchemy = data:GetRecipeDisplayInfo(3577, "Alchemy")
    Test.eq(alchemy.spellID, 11479)
    data:EnsureRecipeReagents(alchemy)
    Test.eq(alchemy.reagents[1].itemID, 3575, "alchemy context shows Iron Bar")

    Test.truthy(mining ~= alchemy, "contexts must not share one cached record")
end)

Test.it("ownership index disambiguates when only one profession holds the key", function()
    local _addon, data = freshAddon()
    seedMember(data, "Miner-TestRealm", "Mining", { [3577] = true }, { count = 1 })
    data:BuildRecipeIndex()

    local detail = data:GetRecipeDetail(3577)
    Test.eq(detail.spellID, 3308, "single-owner profession resolves without an explicit hint")
    Test.eq(detail.reagents[1].itemID, 2776)
end)

Test.it("list build resolves ambiguous keys against the list profession", function()
    local addon, data = freshAddon()
    -- The default prefilter hides Vanilla; both Gold Bar records are
    -- vanilla, and only Mining is expansion-agnostic. Reveal Vanilla so
    -- the Alchemy list exercises the hint too.
    local profile = addon.db and addon.db.profile
    if profile then
        profile.recipePrefilters = profile.recipePrefilters or {}
        profile.recipePrefilters.expansionDefaults = { vanilla = true, tbc = true }
    end
    seedMember(data, "Miner-TestRealm", "Mining", { [3577] = true }, { count = 1 })
    seedMember(data, "Alche-TestRealm", "Alchemy", { [3577] = true }, { count = 1 })
    data:BuildRecipeIndex()

    local miningRows = data:GetRecipeList("Mining", "", "alpha")
    Test.eq(#miningRows, 1)
    Test.eq(miningRows[1].detail.spellID, 3308)

    local alchemyRows = data:GetRecipeList("Alchemy", "", "alpha")
    Test.eq(#alchemyRows, 1)
    Test.eq(alchemyRows[1].detail.spellID, 11479)
end)

io.write(string.format("Metadata profession-hint disambiguation: %d test(s) passed\n", Test.count))
