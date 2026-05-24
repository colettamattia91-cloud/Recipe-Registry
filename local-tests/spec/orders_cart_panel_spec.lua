local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label = "Major Healing Potion",
        createdItemID = 22829,
        createdItemIcon = "Interface\\Icons\\INV_Potion_054",
        createdItemQuality = 2,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
        },
    },
    [858] = {
        label = "Lesser Mana Potion",
        createdItemID = 3385,
        createdItemIcon = "Interface\\Icons\\INV_Potion_076",
        createdItemQuality = 1,
        reagents = {
            { itemID = 785, count = 2, name = "Mageroyal", icon = "m", quality = 1 },
        },
    },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function lineFor(recipeKey, quantity, crafter)
    local info = RECIPES[recipeKey]
    return {
        recipeKey    = recipeKey,
        quantity     = quantity,
        crafter      = crafter,
        recipeLabel  = info and info.label,
        outputItemID = info and info.createdItemID,
    }
end

io.write("Craft Orders cart panel\n")

Test.it("BuildView on empty cart returns empty groups", function()
    local plugin = freshPlugin()
    local view = plugin.CartPanel:BuildView()
    Test.eq(#view.groups, 0)
    Test.eq(view.totalLines, 0)
    Test.eq(view.totalCrafters, 0)
end)

Test.it("BuildView groups lines by crafter and sorts alphabetically", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Bob-Y"))
    plugin.Cart:AddLine(lineFor(929, 3, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Alice-X"))

    local view = plugin.CartPanel:BuildView()
    Test.eq(view.totalLines, 3)
    Test.eq(view.totalCrafters, 2)
    Test.eq(view.groups[1].crafter, "Alice-X", "alphabetical: Alice before Bob")
    Test.eq(view.groups[2].crafter, "Bob-Y")
    Test.eq(#view.groups[1].lines, 2)
    Test.eq(#view.groups[2].lines, 1)
end)

Test.it("BuildView populates display name + recipe label + quantity", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 5, "Alice-Realm"))
    local view = plugin.CartPanel:BuildView()
    Test.eq(view.groups[1].displayName, "Alice", "realm suffix stripped for display")
    Test.eq(view.groups[1].lines[1].recipeLabel, "Major Healing Potion")
    Test.eq(view.groups[1].lines[1].quantity, 5)
    Test.eq(view.groups[1].lines[1].quality, 2, "RR's createdItemQuality propagated")
    Test.eq(view.groups[1].lines[1].lineIndex, 1, "cart index preserved for mutation handlers")
end)

Test.it("OnIncrement bumps the cart line quantity", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    Test.truthy(plugin.CartPanel:OnIncrement(1))
    Test.eq(plugin.Cart:GetLines()[1].quantity, 3)
end)

Test.it("OnDecrement above 1 reduces, at 1 removes the line", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 3, "Alice-X"))
    Test.truthy(plugin.CartPanel:OnDecrement(1))
    Test.eq(plugin.Cart:GetLines()[1].quantity, 2)
    plugin.CartPanel:OnDecrement(1)  -- 2 -> 1
    plugin.CartPanel:OnDecrement(1)  -- 1 -> remove
    Test.eq(plugin.Cart:CountLines(), 0)
end)

Test.it("OnRemove drops the targeted line", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Bob-Y"))
    plugin.CartPanel:OnRemove(1)
    Test.eq(plugin.Cart:CountLines(), 1)
    Test.eq(plugin.Cart:GetLines()[1].recipeKey, 858)
end)

Test.it("OnClear empties the cart", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Bob-Y"))
    plugin.CartPanel:OnClear()
    Test.truthy(plugin.Cart:IsEmpty())
end)

Test.it("OnCheckout creates one order per crafter and clears the cart", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Bob-Y"))
    local result = plugin.CartPanel:OnCheckout()
    Test.eq(#result.created, 2)
    Test.eq(#result.errors, 0)
    Test.truthy(plugin.Cart:IsEmpty())
end)

Test.it("FormatCheckoutSummary handles success + partial-failure shapes", function()
    local plugin = freshPlugin()
    local successLines = plugin.CartPanel:FormatCheckoutSummary({
        created = { "rr-ord-1", "rr-ord-2" }, errors = {},
    })
    Test.eq(#successLines, 1)
    Test.truthy(successLines[1]:find("Created 2 order", 1, true))
    Test.truthy(successLines[1]:find("rr-ord-1", 1, true))

    local mixedLines = plugin.CartPanel:FormatCheckoutSummary({
        created = { "rr-ord-3" },
        errors  = { { crafter = "Alice-X", reason = "synthetic" } },
    })
    Test.eq(#mixedLines, 2)
    Test.truthy(mixedLines[2]:find("Error for Alice-X", 1, true))
    Test.truthy(mixedLines[2]:find("synthetic", 1, true))

    local emptyLines = plugin.CartPanel:FormatCheckoutSummary({
        created = {}, errors = {},
    })
    Test.eq(emptyLines[1], "Nothing to check out.")

    local nilLines = plugin.CartPanel:FormatCheckoutSummary(nil)
    Test.eq(nilLines[1], "Cart checkout failed.")
end)

io.write(string.format("Craft Orders cart panel: %d test(s) passed\n", Test.count))
