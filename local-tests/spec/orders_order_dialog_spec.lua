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

local function makeInfo(recipeKey, crafters)
    local info = RECIPES[recipeKey]
    return {
        recipeKey  = recipeKey,
        label      = info and info.label,
        createdItemID = info and info.createdItemID,
        crafters   = crafters,
        crafterCount = #crafters,
    }
end

io.write("Craft Orders order dialog\n")

Test.it("GetSortedCrafters strips realm suffix into a display name", function()
    local plugin = freshPlugin()
    local rows = plugin.OrderDialog:GetSortedCrafters(makeInfo(929, {
        { memberKey = "Alice-Realm", online = true, skillRank = 350 },
    }))
    Test.eq(#rows, 1)
    Test.eq(rows[1].display, "Alice", "realm suffix dropped for UI")
    Test.eq(rows[1].memberKey, "Alice-Realm", "full key preserved for storage")
end)

Test.it("GetSortedCrafters hides offline crafters by default", function()
    local plugin = freshPlugin()
    local info = makeInfo(929, {
        { memberKey = "Alice-X", online = true,  skillRank = 350 },
        { memberKey = "Bob-Y",   online = false, skillRank = 375 },
    })
    local onlyOnline = plugin.OrderDialog:GetSortedCrafters(info)
    Test.eq(#onlyOnline, 1)
    Test.eq(onlyOnline[1].memberKey, "Alice-X")

    local withOffline = plugin.OrderDialog:GetSortedCrafters(info, { includeOffline = true })
    Test.eq(#withOffline, 2)
end)

Test.it("GetSortedCrafters returns empty list when info is missing or malformed", function()
    local plugin = freshPlugin()
    Test.eq(#plugin.OrderDialog:GetSortedCrafters(nil), 0)
    Test.eq(#plugin.OrderDialog:GetSortedCrafters({}), 0)
    Test.eq(#plugin.OrderDialog:GetSortedCrafters({ crafters = {} }), 0)
end)

Test.it("ComputeInitialSelection auto-selects the only online crafter", function()
    local plugin = freshPlugin()
    local sel = plugin.OrderDialog:ComputeInitialSelection(929, makeInfo(929, {
        { memberKey = "Alice-X", online = true, skillRank = 350 },
    }))
    Test.eq(sel.crafter, "Alice-X")
    Test.eq(sel.source, "auto-select")
    Test.eq(sel.quantity, 1, "no sticky -> defaults to 1")
end)

Test.it("ComputeInitialSelection prefers a sticky choice when still available", function()
    local plugin = freshPlugin()
    plugin.OrderDialog:RememberChoice(929, 5, "Bob-Y")
    local sel = plugin.OrderDialog:ComputeInitialSelection(929, makeInfo(929, {
        { memberKey = "Alice-X", online = true, skillRank = 350 },
        { memberKey = "Bob-Y",   online = true, skillRank = 375 },
    }))
    Test.eq(sel.crafter, "Bob-Y")
    Test.eq(sel.source, "sticky")
    Test.eq(sel.quantity, 5)
end)

Test.it("ComputeInitialSelection falls back to first online when sticky crafter is offline", function()
    local plugin = freshPlugin()
    plugin.OrderDialog:RememberChoice(929, 3, "Bob-Y")
    local sel = plugin.OrderDialog:ComputeInitialSelection(929, makeInfo(929, {
        { memberKey = "Alice-X", online = true,  skillRank = 350 },
        { memberKey = "Carl-Z",  online = true,  skillRank = 340 },
        { memberKey = "Bob-Y",   online = false, skillRank = 375 },
    }))
    Test.eq(sel.crafter, "Alice-X", "first online crafter wins")
    Test.eq(sel.source, "first-online")
    Test.eq(sel.quantity, 3, "quantity sticky survives even if crafter doesn't")
end)

Test.it("ComputeInitialSelection returns nil crafter when no one is online", function()
    local plugin = freshPlugin()
    local sel = plugin.OrderDialog:ComputeInitialSelection(929, makeInfo(929, {
        { memberKey = "Alice-X", online = false, skillRank = 350 },
    }))
    Test.eq(sel.crafter, nil)
    Test.eq(sel.source, nil)
end)

Test.it("RememberChoice persists per-recipe under charDB.lastChoices", function()
    local plugin = freshPlugin()
    plugin.OrderDialog:RememberChoice(929, 4, "Alice-X")
    Test.eq(plugin.charDB.lastChoices[929].crafter, "Alice-X")
    Test.eq(plugin.charDB.lastChoices[929].quantity, 4)
end)

Test.it("ConfirmAddToCart validates quantity and crafter", function()
    local plugin = freshPlugin()
    local info = makeInfo(929, { { memberKey = "Alice-X", online = true, skillRank = 350 } })
    local _, err1 = plugin.OrderDialog:ConfirmAddToCart(929, info, 0, "Alice-X")
    Test.eq(err1, "invalid-line-quantity")
    local _, err2 = plugin.OrderDialog:ConfirmAddToCart(929, info, 1, "")
    Test.eq(err2, "missing-crafter")
end)

Test.it("ConfirmAddToCart pushes onto Cart and saves sticky", function()
    local plugin = freshPlugin()
    local info = makeInfo(929, { { memberKey = "Alice-X", online = true, skillRank = 350 } })
    local index, outcome = plugin.OrderDialog:ConfirmAddToCart(929, info, 3, "Alice-X")
    Test.eq(index, 1)
    Test.eq(outcome, "added")
    Test.eq(plugin.Cart:CountLines(), 1)
    Test.eq(plugin.Cart:GetLines()[1].quantity, 3)
    Test.eq(plugin.Cart:GetLines()[1].recipeLabel, "Major Healing Potion")

    -- Sticky check.
    local sticky = plugin.OrderDialog:GetLastChoice(929)
    Test.eq(sticky.crafter, "Alice-X")
    Test.eq(sticky.quantity, 3)
end)

Test.it("ConfirmAddToCart twice for same recipe+crafter merges quantities", function()
    local plugin = freshPlugin()
    local info = makeInfo(929, { { memberKey = "Alice-X", online = true, skillRank = 350 } })
    plugin.OrderDialog:ConfirmAddToCart(929, info, 2, "Alice-X")
    local index, outcome = plugin.OrderDialog:ConfirmAddToCart(929, info, 3, "Alice-X")
    Test.eq(index, 1)
    Test.eq(outcome, "merged")
    Test.eq(plugin.Cart:GetLines()[1].quantity, 5)
end)

Test.it("ShouldDefaultToOffline is false when at least one crafter is online", function()
    local plugin = freshPlugin()
    local doDefault = plugin.OrderDialog:ShouldDefaultToOffline(makeInfo(929, {
        { memberKey = "Alice-X", online = true,  skillRank = 350 },
        { memberKey = "Bob-Y",   online = false, skillRank = 375 },
    }))
    Test.falsy(doDefault)
end)

Test.it("ShouldDefaultToOffline is true when nobody is online but offline crafters exist", function()
    local plugin = freshPlugin()
    local doDefault = plugin.OrderDialog:ShouldDefaultToOffline(makeInfo(929, {
        { memberKey = "Alice-X", online = false, skillRank = 350 },
        { memberKey = "Bob-Y",   online = false, skillRank = 375 },
    }))
    Test.truthy(doDefault)
end)

Test.it("ShouldDefaultToOffline is false when there are no crafters at all", function()
    local plugin = freshPlugin()
    Test.falsy(plugin.OrderDialog:ShouldDefaultToOffline(makeInfo(929, {})))
    Test.falsy(plugin.OrderDialog:ShouldDefaultToOffline(nil))
end)

io.write(string.format("Craft Orders order dialog: %d test(s) passed\n", Test.count))
