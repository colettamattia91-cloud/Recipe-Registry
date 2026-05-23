local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon, wow, core = Loader.LoadMetadata()

Test.it("loads the metadata addon after Recipe Registry", function()
    Test.truthy(core, "core addon should load")
    Test.truthy(addon, "metadata addon should load")
    Test.eq(addon.ADDON_VERSION, "0.1.0")
    Test.truthy(addon.RecipeMetadata, "metadata table should be exposed")
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

Test.it("registers rrmeta diagnostics commands", function()
    Test.truthy(addon.__chatCommands and addon.__chatCommands.rrmeta, "rrmeta command should be registered")
    local before = #wow.GetState().prints
    addon:SlashHandler("diag")
    addon:SlashHandler("version")
    local state = wow.GetState()
    Test.gte(#state.prints, before + 2)
    Test.truthy(state.prints[before + 1]:find("recipes=14", 1, true), "diag should print generated record count")
    Test.truthy(state.prints[before + 2]:find("metadata 2026.05.23.2", 1, true), "version should print metadata version")
end)

Test.it("keeps metadata addon in the CurseForge move-folders map", function()
    local handle = assert(io.open(".pkgmeta", "r"))
    local contents = handle:read("*a")
    handle:close()

    Test.truthy(
        contents:find("RecipeRegistry/RecipeRegistry_Metadata: RecipeRegistry_Metadata", 1, true),
        "metadata move-folders entry should be present"
    )
    Test.truthy(contents:find("- tools", 1, true), "build-time tools should be ignored from the ZIP")
end)
