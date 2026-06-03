-- Backend coverage for the "Compose mail" action button. Verifies
-- that ComputeActionsForOrder surfaces it under the right conditions,
-- that DispatchAction routes it to the MailAssistant, and that the
-- WoW SendMail UI globals end up populated with the composed mail.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
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
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

local function hasComposeAction(actions)
    for index = 1, #actions do
        if actions[index].kind == "compose-mail" then return true end
    end
    return false
end

io.write("Craft Orders mail compose action\n")

Test.it("requester sees Compose mail when the order has shippable materials", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    local actions = plugin.Board:ComputeActionsForOrder(order)
    Test.truthy(hasComposeAction(actions),
        "Draft + requester + materials should surface Compose mail")
end)

Test.it("crafter does not see Compose mail (sending materials is the requester's job)", function()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Bob", "TestRealm")  -- local player is the crafter now
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    local order = draftOrder(plugin)
    local actions = plugin.Board:ComputeActionsForOrder(order)
    Test.falsy(hasComposeAction(actions))
end)

Test.it("Compose mail disappears once the order has moved past MaterialsSent", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    -- Crafter then marks received (state machine requires it to be done by the crafter).
    Loader.Wow.SetPlayer("Bob", "TestRealm")
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsReceived", "crafter"))
    -- Switch back to the requester and verify Compose is gone for them.
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    local actions = plugin.Board:ComputeActionsForOrder(plugin.Store:GetOrder(order.id))
    Test.falsy(hasComposeAction(actions),
        "Compose mail must not be offered past MaterialsSent")
end)

Test.it("DispatchAction(compose-mail) fails cleanly when the mailbox is closed", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(false)
    local ok, err = plugin.Board:DispatchAction(order.id, { kind = "compose-mail" })
    Test.eq(ok, false)
    Test.eq(err, "mailbox-closed")
end)

Test.it("DispatchAction(compose-mail) populates the SendMail UI globals", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.MailAssistant:SetMailboxOpen(true)

    local ok = plugin.Board:DispatchAction(order.id, { kind = "compose-mail" })
    Test.truthy(ok)
    -- The harness's stubs forward SetText into mailbox.outgoing, so
    -- reading them back is the testable substitute for inspecting the
    -- actual SendMail UI.
    local outgoing = Loader.Wow.GetSendMailOutgoing()
    Test.eq(outgoing.recipient, "Bob-TestRealm")
    Test.truthy((outgoing.subject or ""):find("Order", 1, true))
    Test.truthy((outgoing.body or ""):find("--RR-ORDER--", 1, true))
end)

Test.it("DispatchAction(transition) still drives state changes through Store:Transition", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    local ok = plugin.Board:DispatchAction(order.id, {
        kind    = "transition",
        toState = "MaterialsSent",
        actor   = "requester",
    })
    Test.truthy(ok)
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent")
end)
