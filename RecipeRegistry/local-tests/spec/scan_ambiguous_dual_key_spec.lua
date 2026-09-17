-- Additive dual-key scan for ambiguous created items.
--
-- When a scanned recipe's crafted item is produced by more than one spell
-- (Gold Bar via Smelt Gold [mining] and Transmute: Iron to Gold [alchemy]),
-- the item key alone cannot say which recipe the crafter knows. The scan
-- now stores BOTH the item key (compat with existing peer replicas — the
-- additive merge never removes keys) and the spell key from the recipe
-- link, which resolves to exact reagents in the metadata library.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

io.write("Scan ambiguous dual-key\n")

local function freshAddon()
    local addon, wow = Loader.LoadMetadata({ fixture = true })
    return addon, wow, addon.Data
end

Test.it("stores item key plus spell key for ambiguous created items", function()
    local _addon, wow, data = freshAddon()

    -- Fixture: item 3577 (Gold Bar) is created by spells 3308 (mining) and
    -- 11479 (alchemy transmute). Item 22823 is unambiguous.
    wow.SetTradeSkill("Alchemy", {
        { name = "Transmute: Iron to Gold", itemID = 3577, spellID = 11479 },
        { name = "Unambiguous Test Potion", itemID = 22823, spellID = 28543 },
    }, { shown = false })

    local result = data:ScanTradeSkill()
    Test.truthy(result.valid, "scan should be valid")

    local entry = data:GetMember(data:GetPlayerKey())
    local recipes = entry.professions.Alchemy.recipes
    Test.hasKey(recipes, 3577, "ambiguous item key must stay (peer replica compat)")
    Test.hasKey(recipes, -11479, "spell key must be added for the ambiguous item")
    Test.hasKey(recipes, 22823, "unambiguous item stored as item key")
    Test.noKey(recipes, -28543, "unambiguous items must not get a spell key")
    Test.eq(entry.professions.Alchemy.count, 3, "count includes the additive spell key")
end)

Test.it("spell key resolves to exact reagents while the item key stays ambiguous", function()
    local _addon, wow, data = freshAddon()

    wow.SetTradeSkill("Alchemy", {
        { name = "Transmute: Iron to Gold", itemID = 3577, spellID = 11479 },
    }, { shown = false })
    data:ScanTradeSkill()
    data:BuildRecipeIndex()

    local spellDetail = data:GetRecipeDetail(-11479)
    Test.eq(spellDetail.spellID, 11479)
    Test.eq(spellDetail.reagents[1].itemID, 3575, "spell key carries the transmute reagent")

    -- The item key resolves too, but only via the ownership fallback
    -- (single profession holds it) — same behaviour as before this change.
    local itemDetail = data:GetRecipeDetail(3577, "Alchemy")
    Test.eq(itemDetail.spellID, 11479)
end)

Test.it("missing recipe link falls back to the plain item key", function()
    local _addon, wow, data = freshAddon()

    wow.SetTradeSkill("Alchemy", {
        { name = "Transmute: Iron to Gold", itemID = 3577, recipeLink = "" },
    }, { shown = false })

    local result = data:ScanTradeSkill()
    Test.truthy(result.valid, "scan should be valid")

    local entry = data:GetMember(data:GetPlayerKey())
    local recipes = entry.professions.Alchemy.recipes
    Test.hasKey(recipes, 3577, "item key stored")
    Test.noKey(recipes, -11479, "no spell key without a usable recipe link")
end)

io.write(string.format("Scan ambiguous dual-key: %d test(s) passed\n", Test.count))
