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

local addon = Loader.Load({
    files = getUiFiles(),
})
local ui = addon.UI

Test.it("clears stale detail state when filters remove the selected recipe", function()
    ui.selectedRecipeKey = -2329
    ui.currentDetail = { recipeKey = -2329 }
    ui._lastDetailSignature = "stale-signature"
    ui._lastDetailRecipeKey = -2329
    ui.CloseShareMenus = function(self)
        self._closedShareMenus = true
    end

    local rejected = ui:RejectStaleRecipeSelection({
        { recipeKey = "-28596" },
    })

    Test.eq(rejected, true)
    Test.eq(ui.selectedRecipeKey, nil)
    Test.eq(ui.currentDetail, nil)
    Test.eq(ui._lastDetailSignature, nil)
    Test.eq(ui._lastDetailRecipeKey, nil)
    Test.eq(ui._closedShareMenus, true)
end)

Test.it("keeps selection when the filtered list still contains the selected recipe", function()
    ui.selectedRecipeKey = -28596
    ui.currentDetail = { recipeKey = -28596 }
    ui._lastDetailSignature = "current-signature"

    local rejected = ui:RejectStaleRecipeSelection({
        { recipeKey = "-28596" },
    })

    Test.eq(rejected, false)
    Test.eq(ui.selectedRecipeKey, -28596)
    Test.eq(ui.currentDetail.recipeKey, -28596)
    Test.eq(ui._lastDetailSignature, "current-signature")
end)
