-- Backend coverage for the Craft Orders board's detail-panel action
-- buttons. Targets the data-side helpers (GetLocalActorForOrder,
-- ComputeActionsForOrder, ApplyOrderAction) so the spec drives the
-- whole flow without a panel frame being built. The UI strip is a
-- thin renderer around these helpers; correctness lives here.

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

-- Loads the plugin with the local player identity primed via the WoW
-- mock so Addon:GetLocalPlayerKey() returns the expected Char-Realm
-- string. Defaults to Mattia-TestRealm.
local function freshPlugin(localPlayerName)
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer(localPlayerName or "Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function specWith(requester, crafter)
    return {
        requester = requester,
        crafter   = crafter,
        lines     = {
            { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" },
        },
    }
end

-- Returns the toState labels of just the state-machine transition
-- entries; the action list also surfaces non-transition entries
-- (e.g. "compose-mail") which this spec ignores deliberately.
local function labelsOf(actions)
    local out = {}
    for index = 1, #actions do
        if actions[index].kind == "transition" or actions[index].toState then
            out[#out + 1] = actions[index].toState
        end
    end
    return out
end

local function transitionsOf(actions)
    local out = {}
    for index = 1, #actions do
        if actions[index].kind == "transition" or actions[index].toState then
            out[#out + 1] = actions[index]
        end
    end
    return out
end

local function joinSorted(list)
    local copy = {}
    for index = 1, #list do copy[index] = list[index] end
    table.sort(copy)
    return table.concat(copy, ",")
end

io.write("Craft Orders board actions\n")

Test.it("returns nothing when no order is selected", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:GetLocalActorForOrder(nil), nil)
    Test.eq(#plugin.Board:ComputeActionsForOrder(nil), 0)
end)

Test.it("returns nothing for a third-party observer", function()
    local plugin = freshPlugin("Stranger")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))
    Test.eq(plugin.Board:GetLocalActorForOrder(order), nil)
    Test.eq(#plugin.Board:ComputeActionsForOrder(order), 0)
end)

Test.it("offers the requester's transitions from Draft", function()
    local plugin = freshPlugin("Mattia")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))
    Test.eq(plugin.Board:GetLocalActorForOrder(order), "requester")

    local actions = plugin.Board:ComputeActionsForOrder(order)
    -- MaterialsPartial / MaterialsSent are now driven automatically by
    -- the mail flow (MAIL_SEND_SUCCESS -> AutoAdvanceMaterialsState),
    -- so the action strip only exposes Cancel as a manual transition
    -- the requester drives themselves.
    Test.eq(joinSorted(labelsOf(actions)), "Cancelled")

    local transitions = transitionsOf(actions)
    for index = 1, #transitions do
        Test.eq(transitions[index].actor, "requester")
        if transitions[index].toState == "Cancelled" then
            Test.eq(transitions[index].destructive, true,
                "Cancelled must render as destructive (red)")
        else
            Test.eq(transitions[index].destructive, false)
        end
    end
end)

Test.it("offers the crafter's transitions from MaterialsSent (no system-only edges)", function()
    local plugin = freshPlugin("Bob")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))
    -- Walk the order through Draft -> MaterialsSent as the requester
    -- so the crafter has something to act on.
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))

    local actions = plugin.Board:ComputeActionsForOrder(order)
    -- System-only transitions (MaterialsAssumed, Expired) must never
    -- appear on the action strip; those are driven by background
    -- timers, not user clicks.
    Test.eq(joinSorted(labelsOf(actions)),
        "MaterialsMissing,MaterialsReceived")
end)

Test.it("offers nothing in a terminal state", function()
    local plugin = freshPlugin("Mattia")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))
    Test.truthy(plugin.Store:Transition(order.id, "Cancelled", "requester"))

    Test.eq(plugin.Board:GetLocalActorForOrder(order), "requester")
    Test.eq(#plugin.Board:ComputeActionsForOrder(order), 0)
end)

Test.it("ApplyOrderAction routes through the store and updates the order", function()
    local plugin = freshPlugin("Mattia")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))

    local ok, err = plugin.Board:ApplyOrderAction(order.id, "MaterialsSent", "requester")
    Test.truthy(ok, err)
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent")
end)

Test.it("ApplyOrderAction rejects invalid transitions without mutating state", function()
    local plugin = freshPlugin("Mattia")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))

    -- "Completed" isn't reachable from Draft by anyone.
    local ok, err = plugin.Board:ApplyOrderAction(order.id, "Completed", "requester")
    Test.eq(ok, false)
    Test.truthy(err, "should surface the state-machine rejection reason")
    Test.eq(plugin.Store:GetOrder(order.id).status, "Draft",
        "rejected transitions must not advance the state")
end)

Test.it("ApplyOrderAction rejects when the actor isn't authorized for the edge", function()
    local plugin = freshPlugin("Mattia")
    local order = plugin.Store:CreateDraft(specWith("Mattia-TestRealm", "Bob-TestRealm"))
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))

    -- MaterialsSent -> MaterialsReceived is crafter-only. The requester
    -- shouldn't be able to drive it from the UI.
    local ok, err = plugin.Board:ApplyOrderAction(order.id, "MaterialsReceived", "requester")
    Test.eq(ok, false)
    Test.truthy(err)
    Test.eq(plugin.Store:GetOrder(order.id).status, "MaterialsSent")
end)
