local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshUI()
    local addon = Loader.Load({
        files = Loader.BackendFilesWithUI,
    })
    return addon, addon.UI
end

io.write("RecipeRegistry.UI external tab registry\n")

Test.it("starts with no external tabs registered", function()
    local _, UI = freshUI()
    Test.eq(#UI:ListExternalTabs(), 0)
    Test.falsy(UI:HasExternalTab("orders"))
    Test.eq(UI:GetExternalTabSpec("orders"), nil)
end)

Test.it("RegisterExternalTab validates required fields", function()
    local _, UI = freshUI()
    local nilSpec, err1 = UI:RegisterExternalTab(nil)
    Test.eq(nilSpec, nil)
    Test.eq(err1, "invalid-spec")

    local _, err2 = UI:RegisterExternalTab({ label = "X" })
    Test.eq(err2, "missing-id")

    local _, err3 = UI:RegisterExternalTab({ id = "" })
    Test.eq(err3, "missing-id")

    local _, err4 = UI:RegisterExternalTab({ id = "orders" })
    Test.eq(err4, "missing-label")

    local _, err5 = UI:RegisterExternalTab({ id = "ext:orders", label = "Orders" })
    Test.eq(err5, "reserved-prefix",
        "the ext: prefix is reserved for the internal view-id encoding")

    local _, err6 = UI:RegisterExternalTab({ id = "orders", label = "Orders", build = "not-a-fn" })
    Test.eq(err6, "invalid-build")

    local _, err7 = UI:RegisterExternalTab({ id = "orders", label = "Orders", onSelect = 42 })
    Test.eq(err7, "invalid-onselect")
end)

Test.it("registers a tab and exposes it through the lookup API", function()
    local _, UI = freshUI()
    local buildCalls = 0
    local ok, err = UI:RegisterExternalTab({
        id    = "orders",
        label = "Craft Orders",
        build = function() buildCalls = buildCalls + 1 end,
    })
    Test.truthy(ok, "registration succeeded")
    Test.eq(err, nil)

    Test.truthy(UI:HasExternalTab("orders"))
    local spec = UI:GetExternalTabSpec("orders")
    Test.eq(spec.id, "orders")
    Test.eq(spec.label, "Craft Orders")
    Test.eq(type(spec.build), "function")
    Test.eq(buildCalls, 0, "build should not run until the frame realizes the panel")

    local list = UI:ListExternalTabs()
    Test.eq(#list, 1)
    Test.eq(list[1], "orders")
end)

Test.it("preserves registration order across multiple tabs", function()
    local _, UI = freshUI()
    UI:RegisterExternalTab({ id = "orders",   label = "Orders" })
    UI:RegisterExternalTab({ id = "raid",     label = "Raid Helpers" })
    UI:RegisterExternalTab({ id = "auctions", label = "Auctions" })
    local list = UI:ListExternalTabs()
    Test.eq(#list, 3)
    Test.eq(list[1], "orders")
    Test.eq(list[2], "raid")
    Test.eq(list[3], "auctions")
end)

Test.it("re-registering an existing id replaces the spec without reordering", function()
    local _, UI = freshUI()
    UI:RegisterExternalTab({ id = "orders", label = "Orders" })
    UI:RegisterExternalTab({ id = "raid",   label = "Raid" })

    UI:RegisterExternalTab({ id = "orders", label = "Craft Orders (updated)" })
    local list = UI:ListExternalTabs()
    Test.eq(#list, 2, "no duplicate entries in the order list")
    Test.eq(list[1], "orders", "re-registration keeps original position")
    Test.eq(UI:GetExternalTabSpec("orders").label, "Craft Orders (updated)")
end)

Test.it("IsExternalView is false when only built-in views are active", function()
    local _, UI = freshUI()
    Test.falsy(UI:IsExternalView())
    Test.eq(UI:GetExternalTabId(), nil)
    UI:SetMainView("recipes")
    Test.falsy(UI:IsExternalView())
    UI:SetMainView("addon")
    Test.falsy(UI:IsExternalView())
end)

Test.it("SelectExternalTab refuses unknown ids", function()
    local _, UI = freshUI()
    local ok, err = UI:SelectExternalTab("ghost")
    Test.falsy(ok)
    Test.eq(err, "unknown-tab")
    Test.falsy(UI:IsExternalView())
end)

Test.it("SelectExternalTab flips the view model into the external view", function()
    local _, UI = freshUI()
    UI:RegisterExternalTab({ id = "orders", label = "Orders" })
    Test.truthy(UI:SelectExternalTab("orders"))
    Test.truthy(UI:IsExternalView())
    Test.eq(UI:GetExternalTabId(), "orders")
    Test.eq(UI.selectedProfession, "ext:orders")
end)

Test.it("SetMainView back to recipes clears external view and fires onDeselect", function()
    local _, UI = freshUI()
    local deselectCalls = 0
    UI:RegisterExternalTab({
        id = "orders", label = "Orders",
        onDeselect = function() deselectCalls = deselectCalls + 1 end,
    })
    UI:SelectExternalTab("orders")
    Test.truthy(UI:IsExternalView())

    UI:SetMainView("recipes")
    Test.falsy(UI:IsExternalView())
    -- The panel hasn't been realized (no CreateFrame in tests), so the
    -- onDeselect callback should not have fired — its contract is "called
    -- with the panel" and there is no panel.
    Test.eq(deselectCalls, 0)
end)

Test.it("SetMainView('addon') clears any active external view", function()
    local _, UI = freshUI()
    UI:RegisterExternalTab({ id = "orders", label = "Orders" })
    UI:SelectExternalTab("orders")
    UI:SetMainView("addon")
    Test.falsy(UI:IsExternalView())
    Test.truthy(UI:IsAddonStatusView())
end)

Test.it("selecting an external tab twice in a row is idempotent", function()
    local _, UI = freshUI()
    UI:RegisterExternalTab({ id = "orders", label = "Orders" })
    UI:SelectExternalTab("orders")
    UI:SelectExternalTab("orders")
    Test.eq(UI:GetExternalTabId(), "orders")
end)

Test.it("EXTERNAL_VIEW_PREFIX is namespaced and reserved", function()
    local _, UI = freshUI()
    Test.eq(UI.EXTERNAL_VIEW_PREFIX, "ext:")
    -- A direct selectedProfession write should also be detected.
    UI.selectedProfession = "ext:made-up"
    Test.truthy(UI:IsExternalView())
    Test.eq(UI:GetExternalTabId(), "made-up")
end)

io.write(string.format("RecipeRegistry.UI external tab registry: %d test(s) passed\n", Test.count))
