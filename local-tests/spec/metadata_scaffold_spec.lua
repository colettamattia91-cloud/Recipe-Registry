local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon, wow = Loader.LoadMetadata({ fixture = true })

Test.it("loads metadata as part of the RR addon (no separate plugin)", function()
    Test.truthy(addon, "RR addon should load")
    Test.truthy(addon.RecipeMetadata, "addon.RecipeMetadata should be exposed")
    Test.truthy(addon.RecipeMetadataDiagnostics, "addon.RecipeMetadataDiagnostics module should be registered")
    Test.eq(_G.RecipeRegistry_Metadata, nil, "no separate _G.RecipeRegistry_Metadata addon should exist")
end)

Test.it("exposes generated record counts for diagnostics", function()
    local counts = addon.RecipeMetadata:GetRecordCounts()
    Test.eq(counts.recipes, 14)
    Test.eq(counts.vanilla, 5)
    Test.eq(counts.tbc, 9)
    Test.eq(counts.unresolved, 0)
    Test.gte(counts.recipeItems, 5)
    Test.gte(counts.createdItems, 12)
end)

Test.it("routes /rr meta diag and /rr meta version through the RR slash handler", function()
    local before = #wow.GetState().prints
    addon:SlashHandler("meta diag")
    addon:SlashHandler("meta version")
    local state = wow.GetState()
    Test.gte(#state.prints, before + 2)
    Test.truthy(state.prints[before + 1]:find("recipes=14", 1, true), "diag should print generated record count")
    Test.truthy(state.prints[before + 2]:find("2026.05.23.2", 1, true), "version should print metadata version")
end)

Test.it("packaging no longer carries a separate metadata move-folders entry", function()
    local handle = assert(io.open(".pkgmeta", "r"))
    local contents = handle:read("*a")
    handle:close()

    Test.falsy(
        contents:find("RecipeRegistry_Metadata", 1, true),
        ".pkgmeta should not mention RecipeRegistry_Metadata after fold-in"
    )
    Test.truthy(contents:find("- tools", 1, true), "build-time tools should still be ignored from the ZIP")
end)
