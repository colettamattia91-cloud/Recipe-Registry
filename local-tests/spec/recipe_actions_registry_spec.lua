local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshUI()
    local addon = Loader.Load({ files = Loader.BackendFilesWithUI })
    return addon, addon.UI
end

io.write("RecipeRegistry.UI recipe action registry\n")

Test.it("starts with no recipe actions registered", function()
    local _, UI = freshUI()
    Test.eq(#UI:ListRecipeActions(), 0)
    Test.falsy(UI:HasRecipeAction("order"))
    Test.eq(UI:GetRecipeActionSpec("order"), nil)
end)

Test.it("RegisterRecipeAction validates required fields", function()
    local _, UI = freshUI()
    Test.eq(select(2, UI:RegisterRecipeAction(nil)),               "invalid-spec")
    Test.eq(select(2, UI:RegisterRecipeAction({})),                "missing-id")
    Test.eq(select(2, UI:RegisterRecipeAction({ id = "" })),       "missing-id")
    Test.eq(select(2, UI:RegisterRecipeAction({ id = "x" })),      "missing-label")
    Test.eq(select(2, UI:RegisterRecipeAction({
        id = "x", label = "X", icon = 42,
    })), "invalid-icon")
    Test.eq(select(2, UI:RegisterRecipeAction({
        id = "x", label = "X", onClick = "nope",
    })), "invalid-onclick")
    Test.eq(select(2, UI:RegisterRecipeAction({
        id = "x", label = "X", isVisible = "nope",
    })), "invalid-isvisible")
    Test.eq(select(2, UI:RegisterRecipeAction({
        id = "x", label = "X", isEnabled = 1,
    })), "invalid-isenabled")
end)

Test.it("registers a spec and surfaces it via the lookup helpers", function()
    local _, UI = freshUI()
    Test.truthy(UI:RegisterRecipeAction({
        id    = "order",
        label = "Add to order cart",
        icon  = "Interface\\Icons\\INV_Misc_Bag_08",
        onClick = function() end,
    }))
    Test.truthy(UI:HasRecipeAction("order"))
    local spec = UI:GetRecipeActionSpec("order")
    Test.eq(spec.id, "order")
    Test.eq(spec.label, "Add to order cart")
    Test.eq(spec.icon, "Interface\\Icons\\INV_Misc_Bag_08")
    Test.eq(#UI:ListRecipeActions(), 1)
    Test.eq(UI:ListRecipeActions()[1], "order")
end)

Test.it("preserves registration order across multiple actions", function()
    local _, UI = freshUI()
    UI:RegisterRecipeAction({ id = "order", label = "A" })
    UI:RegisterRecipeAction({ id = "share", label = "B" })
    UI:RegisterRecipeAction({ id = "later", label = "C" })
    local list = UI:ListRecipeActions()
    Test.eq(list[1], "order")
    Test.eq(list[2], "share")
    Test.eq(list[3], "later")
end)

Test.it("re-registering the same id replaces the spec without re-ordering", function()
    local _, UI = freshUI()
    UI:RegisterRecipeAction({ id = "order", label = "first" })
    UI:RegisterRecipeAction({ id = "share", label = "B" })
    UI:RegisterRecipeAction({ id = "order", label = "updated" })
    Test.eq(UI:GetRecipeActionSpec("order").label, "updated")
    -- order list unchanged
    local list = UI:ListRecipeActions()
    Test.eq(list[1], "order")
    Test.eq(list[2], "share")
end)

Test.it("UnregisterRecipeAction drops the spec and order entry", function()
    local _, UI = freshUI()
    UI:RegisterRecipeAction({ id = "order", label = "A" })
    UI:RegisterRecipeAction({ id = "share", label = "B" })
    Test.truthy(UI:UnregisterRecipeAction("order"))
    Test.falsy(UI:HasRecipeAction("order"))
    Test.eq(#UI:ListRecipeActions(), 1)
    Test.eq(UI:ListRecipeActions()[1], "share")

    -- Unregistering an unknown id is a no-op and returns falsy.
    Test.falsy(UI:UnregisterRecipeAction("ghost"))
end)

Test.it("RealizeRecipeActions is safe to call without a frame", function()
    local _, UI = freshUI()
    UI:RegisterRecipeAction({ id = "order", label = "A" })
    -- No frame in tests (UI:CreateMainFrame uses CreateFrame which the
    -- harness doesn't stub). The realize helper must early-return
    -- rather than throw.
    local ok = pcall(UI.RealizeRecipeActions, UI, nil, nil)
    Test.truthy(ok)
end)

io.write(string.format("RecipeRegistry.UI recipe action registry: %d test(s) passed\n",
    Test.count))
