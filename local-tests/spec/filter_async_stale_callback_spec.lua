local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function getUiFiles()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "UI/MainFrame.lua"
    return files
end

local addon = Loader.Load({ files = getUiFiles() })
Loader.LoadMetadata({ reset = false, loadCore = false })
local ui = addon.UI

Test.it("ignores recipe-list callbacks from older UI generations", function()
    ui.frame = {}
    ui._recipeListGeneration = 2
    ui.currentRecipeRows = { { recipeKey = "old" } }

    ui:_FinalizeRecipeList({ { recipeKey = "new" } }, { selectedProfession = "Alchemy" }, 1)

    Test.eq(#ui.currentRecipeRows, 1)
    Test.eq(ui.currentRecipeRows[1].recipeKey, "old")
end)

Test.it("ignores callbacks whose filter cache key no longer matches", function()
    ui.frame = {}
    ui._recipeListGeneration = 3
    ui.currentRecipeRows = { { recipeKey = "old" } }
    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = true
    local context = { selectedProfession = "Alchemy", filterContext = {} }
    context.filterCacheKey = addon.RecipeUiFilters:BuildFilterCacheKey(context.filterContext)

    addon.db.profile.recipePrefilters.expansionDefaults.vanilla = false
    ui:_FinalizeRecipeList({ { recipeKey = "new" } }, context, 3)

    Test.eq(#ui.currentRecipeRows, 1)
    Test.eq(ui.currentRecipeRows[1].recipeKey, "old")
end)
