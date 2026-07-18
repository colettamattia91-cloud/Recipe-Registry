-- Detail panel re-render after async item-info resolution.
--
-- On a cold WoW item cache the first render of a recipe detail shows
-- "item:1234" placeholders for reagents (GetItemInfo returns nil until the
-- server answers). The GET_ITEM_INFO_RECEIVED bucket then triggers an
-- "item-cache" UI refresh whose plan includes the detail panel — but the
-- panel's visibility signature used to ignore reagent names, so the
-- refresh was swallowed by the signature short-circuit and the
-- placeholders stayed until the user re-selected the recipe.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

io.write("Detail panel item-cache re-render\n")

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
    metadataFixture = true,
})
Loader.LoadMetadata({
    reset = false,
    loadCore = false,
    fixture = true,
})

local ui = addon.UI

local function stubRegion()
    return {
        SetText = function(self, value) self.text = value end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetPoint = function() end,
        SetTexture = function(self, value) self.texture = value end,
        SetTexCoord = function() end,
        SetVertexColor = function() end,
        Enable = function() end,
        Disable = function() end,
        SetAlpha = function() end,
    }
end

local favoriteButton = stubRegion()
favoriteButton.icon = stubRegion()

ui.frame = {
    detailFavoriteButton = favoriteButton,
    detailShareButton = stubRegion(),
    detailTitle = stubRegion(),
    detailSub = stubRegion(),
    detailScroll = stubRegion(),
    recipeRows = {},
    detailLines = {},
}

local renderCalls = {}
ui.RenderDetailLines = function(_, lines)
    renderCalls[#renderCalls + 1] = table.concat(lines, "\n")
end

Test.it("re-renders the detail panel once reagent item info resolves", function()
    -- Cold cache: every GetItemInfo lookup misses, like a fresh client
    -- that has not seen the reagent items yet.
    local realGetItemInfo = _G.GetItemInfo
    _G.GetItemInfo = function() return nil end

    ui.selectedProfession = "Alchemy"
    ui.selectedRecipeKey = -2329
    ui:RefreshDetailPanel()

    Test.eq(#renderCalls, 1, "first selection renders the detail panel")
    Test.truthy(renderCalls[1]:find("item:765", 1, true),
        "cold cache should render the reagent placeholder item:765")

    -- Item info arrives (GET_ITEM_INFO_RECEIVED -> item-cache refresh plan
    -- re-runs RefreshDetailPanel). The signature must not swallow it.
    _G.GetItemInfo = realGetItemInfo
    ui:RefreshDetailPanel()

    Test.eq(#renderCalls, 2, "item-cache refresh re-renders the panel")
    Test.truthy(renderCalls[2]:find("Item 765", 1, true),
        "resolved reagent name should replace the placeholder")
end)

Test.it("skips the rebuild when nothing visible changed", function()
    local before = #renderCalls
    ui:RefreshDetailPanel()
    Test.eq(#renderCalls, before, "identical signature still short-circuits")
end)

io.write(string.format("Detail panel item-cache re-render: %d test(s) passed\n", Test.count))
