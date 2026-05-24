local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
        },
    },
    [858] = {
        label = "Lesser Mana Potion",
        createdItemID = 3385,
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

io.write("Craft Orders cart\n")

Test.it("starts empty", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Cart:CountLines(), 0)
    Test.truthy(plugin.Cart:IsEmpty())
end)

Test.it("AddLine rejects missing fields", function()
    local plugin = freshPlugin()
    local _, err1 = plugin.Cart:AddLine({ quantity = 1, crafter = "A-Realm" })
    Test.eq(err1, "invalid-line-recipekey")

    local _, err2 = plugin.Cart:AddLine({ recipeKey = 929, crafter = "A-Realm" })
    Test.eq(err2, "invalid-line-quantity")

    local _, err3 = plugin.Cart:AddLine({ recipeKey = 929, quantity = 1 })
    Test.eq(err3, "missing-crafter")

    local _, err4 = plugin.Cart:AddLine({ recipeKey = 929, quantity = 0, crafter = "A" })
    Test.eq(err4, "invalid-line-quantity")
end)

Test.it("AddLine appends a new line and reports its index", function()
    local plugin = freshPlugin()
    local index, merged = plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    Test.eq(index, 1)
    Test.falsy(merged)
    Test.eq(plugin.Cart:CountLines(), 1)
    Test.eq(plugin.Cart:GetLines()[1].recipeLabel, "Major Healing Potion")
end)

Test.it("AddLine merges quantity when (recipeKey, crafter) is the same", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    local index, merged = plugin.Cart:AddLine(lineFor(929, 3, "Alice-X"))
    Test.eq(index, 1)
    Test.truthy(merged)
    Test.eq(plugin.Cart:CountLines(), 1, "still one line, just bigger quantity")
    Test.eq(plugin.Cart:GetLines()[1].quantity, 5)
end)

Test.it("AddLine keeps separate lines for different crafters of the same recipe", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(929, 3, "Bob-Y"))
    Test.eq(plugin.Cart:CountLines(), 2)
end)

Test.it("RemoveLineAt drops the line and tolerates out-of-range index", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Bob-Y"))
    Test.truthy(plugin.Cart:RemoveLineAt(1))
    Test.eq(plugin.Cart:CountLines(), 1)
    Test.eq(plugin.Cart:GetLines()[1].recipeKey, 858)

    local ok, err = plugin.Cart:RemoveLineAt(99)
    Test.falsy(ok)
    Test.eq(err, "invalid-index")
end)

Test.it("UpdateLineAt changes quantity in place", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    local index, merged = plugin.Cart:UpdateLineAt(1, { quantity = 5 })
    Test.eq(index, 1)
    Test.falsy(merged)
    Test.eq(plugin.Cart:GetLines()[1].quantity, 5)
end)

Test.it("UpdateLineAt rejects non-positive quantity", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    local _, err = plugin.Cart:UpdateLineAt(1, { quantity = 0 })
    Test.eq(err, "invalid-line-quantity")
end)

Test.it("UpdateLineAt changing crafter to another line's crafter merges", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))  -- index 1
    plugin.Cart:AddLine(lineFor(929, 1, "Bob-Y"))    -- index 2

    local index, merged = plugin.Cart:UpdateLineAt(2, { crafter = "Alice-X" })
    Test.truthy(merged)
    Test.eq(plugin.Cart:CountLines(), 1, "two recipes for Alice merged into one")
    Test.eq(plugin.Cart:GetLines()[1].quantity, 3, "quantities summed (2 + 1)")
    Test.eq(index, 1, "merged into Alice's existing line")
end)

Test.it("Clear empties the cart", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Bob-Y"))
    plugin.Cart:Clear()
    Test.truthy(plugin.Cart:IsEmpty())
end)

Test.it("GroupByCrafter buckets lines by target", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Alice-X"))
    plugin.Cart:AddLine(lineFor(929, 4, "Bob-Y"))
    local groups = plugin.Cart:GroupByCrafter()
    Test.eq(#groups["Alice-X"].lines, 2)
    Test.eq(#groups["Bob-Y"].lines, 1)
    Test.eq(groups["Bob-Y"].lines[1].quantity, 4)
end)

Test.it("Checkout with empty cart returns empty-cart error", function()
    local plugin = freshPlugin()
    local result, err = plugin.Cart:Checkout({ requester = "Mattia-Realm" })
    Test.eq(result, nil)
    Test.eq(err, "empty-cart")
end)

Test.it("Checkout creates one order per crafter and clears the cart", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(858, 1, "Alice-X"))
    plugin.Cart:AddLine(lineFor(929, 4, "Bob-Y"))

    local result = plugin.Cart:Checkout({ requester = "Mattia-TestRealm" })
    Test.eq(#result.created, 2, "one order for Alice, one for Bob")
    Test.eq(#result.errors, 0)
    Test.truthy(plugin.Cart:IsEmpty(), "cart cleared on full success")

    -- Verify the orders landed in the store with the right shape.
    local aliceOrder = plugin.Store:GetOrder(result.created[1])
    local bobOrder   = plugin.Store:GetOrder(result.created[2])
    -- created order is alphabetical by crafter due to sorted key iteration.
    Test.eq(aliceOrder.crafter, "Alice-X")
    Test.eq(#aliceOrder.lines, 2)
    Test.eq(bobOrder.crafter, "Bob-Y")
    Test.eq(#bobOrder.lines, 1)
end)

Test.it("Checkout uses Addon:GetLocalPlayerKey when no requester is passed", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 1, "Alice-X"))
    -- The harness's UnitFullName returns "Tester"/"TestRealm" by default.
    local result = plugin.Cart:Checkout()
    Test.eq(#result.created, 1)
    Test.eq(plugin.Store:GetOrder(result.created[1]).requester, "Tester-TestRealm")
end)

Test.it("Checkout preserves cart when a crafter group fails", function()
    local plugin = freshPlugin()
    plugin.Cart:AddLine(lineFor(929, 2, "Alice-X"))
    plugin.Cart:AddLine(lineFor(929, 3, "Bob-Y"))

    -- Force a failure for the second CreateDraft by monkey-patching
    -- after the first call.
    local original = plugin.Store.CreateDraft
    local calls = 0
    plugin.Store.CreateDraft = function(self, spec)
        calls = calls + 1
        if calls == 2 then return nil, "synthetic-failure" end
        return original(self, spec)
    end

    local result = plugin.Cart:Checkout({ requester = "Mattia-TestRealm" })
    plugin.Store.CreateDraft = original
    Test.eq(#result.created, 1)
    Test.eq(#result.errors, 1)
    Test.eq(result.errors[1].reason, "synthetic-failure")
    Test.eq(plugin.Cart:CountLines(), 2, "cart preserved on partial failure")
end)

io.write(string.format("Craft Orders cart: %d test(s) passed\n", Test.count))
