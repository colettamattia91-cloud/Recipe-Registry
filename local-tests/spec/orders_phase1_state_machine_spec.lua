local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({
        recipeRegistryStub = { Data = {} },
    })
end

io.write("Craft Orders state machine\n")

Test.it("exposes the full set of lifecycle states", function()
    local plugin = freshPlugin()
    local SM = plugin.StateMachine
    Test.eq(SM.STATES.DRAFT, "Draft")
    Test.eq(SM.STATES.MATERIALS_PARTIAL, "MaterialsPartial")
    Test.eq(SM.STATES.MATERIALS_SENT, "MaterialsSent")
    Test.eq(SM.STATES.MATERIALS_RECEIVED, "MaterialsReceived")
    Test.eq(SM.STATES.MATERIALS_ASSUMED, "MaterialsAssumed")
    Test.eq(SM.STATES.MATERIALS_MISSING, "MaterialsMissing")
    Test.eq(SM.STATES.ACCEPTED, "Accepted")
    Test.eq(SM.STATES.DELIVERY_SENT, "DeliverySent")
    Test.eq(SM.STATES.COMPLETED, "Completed")
    Test.eq(SM.STATES.RETURN_PENDING, "ReturnPending")
    Test.eq(SM.STATES.CANCELLED, "Cancelled")
    Test.eq(SM.STATES.EXPIRED, "Expired")
    Test.eq(SM.STATES.FAILED, "Failed")
end)

Test.it("marks Completed/Cancelled/Expired/Failed as terminal", function()
    local SM = freshPlugin().StateMachine
    Test.truthy(SM:IsTerminal("Completed"))
    Test.truthy(SM:IsTerminal("Cancelled"))
    Test.truthy(SM:IsTerminal("Expired"))
    Test.truthy(SM:IsTerminal("Failed"))
    Test.falsy(SM:IsTerminal("Draft"))
    Test.falsy(SM:IsTerminal("MaterialsSent"))
    Test.falsy(SM:IsTerminal("Accepted"))
end)

Test.it("validates state membership", function()
    local SM = freshPlugin().StateMachine
    Test.truthy(SM:IsValidState("Draft"))
    Test.truthy(SM:IsValidState("DeliverySent"))
    Test.falsy(SM:IsValidState("Bogus"))
    Test.falsy(SM:IsValidState(""))
    Test.falsy(SM:IsValidState(nil))
end)

Test.it("allows the requester to send materials from Draft", function()
    local SM = freshPlugin().StateMachine
    local ok, err = SM:CanTransition("Draft", "MaterialsSent", "requester")
    Test.truthy(ok, "requester should be allowed to send from Draft")
    Test.eq(err, nil)
end)

Test.it("blocks the crafter from sending materials from Draft", function()
    local SM = freshPlugin().StateMachine
    local ok, err = SM:CanTransition("Draft", "MaterialsSent", "crafter")
    Test.falsy(ok)
    Test.eq(err, "actor-not-authorized")
end)

Test.it("rejects unknown source states", function()
    local SM = freshPlugin().StateMachine
    local ok, err = SM:CanTransition("Bogus", "Draft", "requester")
    Test.falsy(ok)
    Test.eq(err, "unknown-from-state")
end)

Test.it("rejects transitions that aren't on the edge list", function()
    local SM = freshPlugin().StateMachine
    -- Draft only allows MaterialsPartial / MaterialsSent / Cancelled.
    local ok, err = SM:CanTransition("Draft", "Completed", "requester")
    Test.falsy(ok)
    Test.eq(err, "invalid-transition")
end)

Test.it("requires the crafter (not requester) to receive materials", function()
    local SM = freshPlugin().StateMachine
    local ok = SM:CanTransition("MaterialsSent", "MaterialsReceived", "crafter")
    Test.truthy(ok)
    local blocked, err = SM:CanTransition("MaterialsSent", "MaterialsReceived", "requester")
    Test.falsy(blocked)
    Test.eq(err, "actor-not-authorized")
end)

Test.it("reserves MaterialsAssumed for the system actor", function()
    local SM = freshPlugin().StateMachine
    Test.truthy(SM:CanTransition("MaterialsSent", "MaterialsAssumed", "system"))
    local blocked, err = SM:CanTransition("MaterialsSent", "MaterialsAssumed", "crafter")
    Test.falsy(blocked)
    Test.eq(err, "actor-not-authorized")
end)

Test.it("lets either party cancel from MaterialsMissing", function()
    local SM = freshPlugin().StateMachine
    Test.truthy(SM:CanTransition("MaterialsMissing", "Cancelled", "crafter"))
    Test.truthy(SM:CanTransition("MaterialsMissing", "Cancelled", "requester"))
    local blocked = SM:CanTransition("MaterialsMissing", "Cancelled", "system")
    Test.falsy(blocked)
end)

Test.it("lets requester or system mark Completed from DeliverySent", function()
    local SM = freshPlugin().StateMachine
    Test.truthy(SM:CanTransition("DeliverySent", "Completed", "requester"))
    Test.truthy(SM:CanTransition("DeliverySent", "Completed", "system"))
    local blocked, err = SM:CanTransition("DeliverySent", "Completed", "crafter")
    Test.falsy(blocked)
    Test.eq(err, "actor-not-authorized")
end)

Test.it("treats terminal states as dead-ends with no outbound edges", function()
    local SM = freshPlugin().StateMachine
    for _, terminal in ipairs({ "Completed", "Cancelled", "Expired", "Failed" }) do
        Test.eq(#SM:GetValidTransitions(terminal, nil), 0,
            "terminal " .. terminal .. " should have no outbound edges")
        local ok, err = SM:CanTransition(terminal, "Draft", "requester")
        Test.falsy(ok)
        Test.eq(err, "invalid-transition")
    end
end)

Test.it("enumerates the requester's Draft options", function()
    local SM = freshPlugin().StateMachine
    local list = SM:GetValidTransitions("Draft", "requester")
    local seen = {}
    for _, state in ipairs(list) do seen[state] = true end
    Test.truthy(seen["MaterialsPartial"])
    Test.truthy(seen["MaterialsSent"])
    Test.truthy(seen["Cancelled"])
    Test.falsy(seen["Completed"], "Completed is not a Draft target")
end)

Test.it("returns all outbound targets when actor is omitted", function()
    local SM = freshPlugin().StateMachine
    local list = SM:GetValidTransitions("MaterialsSent")
    local seen = {}
    for _, state in ipairs(list) do seen[state] = true end
    Test.truthy(seen["MaterialsReceived"])
    Test.truthy(seen["MaterialsAssumed"])
    Test.truthy(seen["MaterialsMissing"])
    Test.truthy(seen["Expired"])
end)

io.write(string.format("Craft Orders state machine: %d test(s) passed\n", Test.count))
