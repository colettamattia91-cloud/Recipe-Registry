local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom",  icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf",  icon = "s", quality = 1 },
        },
    },
    [858] = {
        label = "Lesser Mana Potion",
        createdItemID = 3385,
        reagents = {
            { itemID = 785,  count = 2, name = "Mageroyal",  icon = "m", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
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

local function defaultSpec(overrides)
    local spec = {
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2 } },
    }
    if overrides then
        for key, value in pairs(overrides) do
            spec[key] = value
        end
    end
    return spec
end

io.write("Craft Orders store\n")

Test.it("rejects spec with missing requester/crafter/lines", function()
    local plugin = freshPlugin()
    local nilOrder, err1 = plugin.Store:CreateDraft({ crafter = "X", lines = { { recipeKey = 1, quantity = 1 } } })
    Test.eq(nilOrder, nil)
    Test.eq(err1, "missing-requester")

    local _, err2 = plugin.Store:CreateDraft({ requester = "X", lines = { { recipeKey = 1, quantity = 1 } } })
    Test.eq(err2, "missing-crafter")

    local _, err3 = plugin.Store:CreateDraft({ requester = "X", crafter = "Y", lines = {} })
    Test.eq(err3, "no-lines")
end)

Test.it("rejects invalid line shape", function()
    local plugin = freshPlugin()
    local _, err = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 0, quantity = 1 } },
    }))
    Test.eq(err, "invalid-line-recipekey")
    local _, err2 = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 929, quantity = 0 } },
    }))
    Test.eq(err2, "invalid-line-quantity")
end)

Test.it("creates a Draft and persists it under db.global.orders", function()
    local plugin = freshPlugin()
    local order, err = plugin.Store:CreateDraft(defaultSpec())
    Test.eq(err, nil)
    Test.truthy(order)
    Test.eq(order.status, "Draft")
    Test.eq(order.schemaVersion, 1)
    Test.eq(order.requester, "Mattia-TestRealm")
    Test.eq(order.crafter, "Bob-TestRealm")
    Test.eq(#order.lines, 1)
    Test.eq(order.lines[1].recipeKey, 929)
    Test.eq(order.lines[1].quantity, 2)
    Test.eq(plugin.Store:CountOrders(), 1)
    Test.truthy(plugin.db.global.orders[order.id])
end)

Test.it("populates materials via the planner during CreateDraft", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    Test.truthy(order.materials)
    Test.eq(order.materials[2447].required, 2, "peacebloom required for 2 crafts of recipe 929")
    Test.eq(order.materials[765].required, 2)
    Test.eq(order.materials[2447].requesterProvided, 2, "default split: requester provides all")
    Test.eq(order.materials[2447].crafterProvided, 0)
end)

Test.it("appends an OrderCreated event with line count", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local events = plugin.Store:GetRecentEvents(10)
    Test.eq(#events, 1)
    Test.eq(events[1].kind, "OrderCreated")
    Test.eq(events[1].orderId, order.id)
    Test.eq(events[1].actor, "Mattia-TestRealm")
    Test.eq(events[1].payload.lineCount, 1)
    Test.eq(events[1].seq, 1)
end)

Test.it("generates unique order IDs", function()
    -- math.random gives non-deterministic IDs; seed for determinism inside
    -- the harness isn't necessary because the assertion only checks the
    -- structural format and the absence of collision across two creates.
    local plugin = freshPlugin()
    local first = plugin.Store:CreateDraft(defaultSpec())
    local second = plugin.Store:CreateDraft(defaultSpec())
    Test.ne(first.id, second.id)
    Test.truthy(first.id:find("^rr%-ord%-"))
end)

Test.it("AddLine extends a draft and recomputes materials", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local ok = plugin.Store:AddLine(order.id, {
        recipeKey = 858, quantity = 3,
    }, "Mattia-TestRealm")
    Test.truthy(ok)
    Test.eq(#order.lines, 2)
    Test.eq(order.materials[785].required, 6, "mageroyal from second line")
    Test.eq(order.materials[765].required, 5, "silverleaf merged across lines")
end)

Test.it("AddLine rejects on non-draft orders", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    local ok, err = plugin.Store:AddLine(order.id, { recipeKey = 858, quantity = 1 })
    Test.falsy(ok)
    Test.eq(err, "not-draft")
end)

Test.it("AddLine returns unknown-order for missing id", function()
    local plugin = freshPlugin()
    local ok, err = plugin.Store:AddLine("rr-ord-bogus", { recipeKey = 1, quantity = 1 })
    Test.falsy(ok)
    Test.eq(err, "unknown-order")
end)

Test.it("RemoveLine drops a line and recomputes; protects the last line", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = {
            { recipeKey = 929, quantity = 1 },
            { recipeKey = 858, quantity = 1 },
        },
    }))
    Test.eq(#order.lines, 2)

    local ok = plugin.Store:RemoveLine(order.id, 2)
    Test.truthy(ok)
    Test.eq(#order.lines, 1)
    Test.eq(order.materials[785], nil, "mageroyal gone after removing recipe 858")

    local blocked, err = plugin.Store:RemoveLine(order.id, 1)
    Test.falsy(blocked)
    Test.eq(err, "last-line-protected")
end)

Test.it("RemoveLine validates line-index bounds", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = {
            { recipeKey = 929, quantity = 1 },
            { recipeKey = 858, quantity = 1 },
        },
    }))
    local _, err1 = plugin.Store:RemoveLine(order.id, 0)
    Test.eq(err1, "invalid-line-index")
    local _, err2 = plugin.Store:RemoveLine(order.id, 99)
    Test.eq(err2, "invalid-line-index")
end)

Test.it("DeleteOrder removes a draft and records a tombstone", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local ok = plugin.Store:DeleteOrder(order.id, "user-cleanup")
    Test.truthy(ok)
    Test.eq(plugin.Store:GetOrder(order.id), nil)
    local tomb = plugin.db.global.events.tombstones[order.id]
    Test.truthy(tomb)
    Test.eq(tomb.reason, "user-cleanup")
end)

Test.it("DeleteOrder appends a Pruned event", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:DeleteOrder(order.id, "user-delete")
    local events = plugin.Store:GetRecentEvents(10)
    -- Created + Pruned
    Test.eq(#events, 2)
    Test.eq(events[#events].kind, "Pruned")
    Test.eq(events[#events].actor, "system")
end)

Test.it("DeleteOrder refuses non-draft orders", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    local ok, err = plugin.Store:DeleteOrder(order.id)
    Test.falsy(ok)
    Test.eq(err, "not-draft")
end)

Test.it("SetProvider with no quantity shifts the full required amount", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 929, quantity = 5 } },
    }))
    local ok, bucket = plugin.Store:SetProvider(order.id, 2447, "crafter")
    Test.truthy(ok)
    Test.eq(bucket.crafterProvided, 5)
    Test.eq(bucket.requesterProvided, 0)
    Test.eq(bucket.required, 5, "required is invariant under provider swaps")
end)

Test.it("SetProvider clamps quantity to [0, required]", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 929, quantity = 5 } },
    }))
    local _, bucket = plugin.Store:SetProvider(order.id, 2447, "crafter", 99)
    Test.eq(bucket.crafterProvided, 5, "over-cap clamped to required")
    Test.eq(bucket.requesterProvided, 0)

    local _, bucket2 = plugin.Store:SetProvider(order.id, 2447, "crafter", -3)
    Test.eq(bucket2.crafterProvided, 0, "negative clamped to 0")
    Test.eq(bucket2.requesterProvided, 5)
end)

Test.it("SetProvider splits requester/crafter so they sum to required", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 929, quantity = 4 } },
    }))
    local _, bucket = plugin.Store:SetProvider(order.id, 2447, "crafter", 1)
    Test.eq(bucket.crafterProvided, 1)
    Test.eq(bucket.requesterProvided, 3)
    Test.eq(bucket.crafterProvided + bucket.requesterProvided, bucket.required)
end)

Test.it("SetProvider rejects bad arguments and unknown materials", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local _, err1 = plugin.Store:SetProvider(order.id, 2447, "bogus")
    Test.eq(err1, "invalid-provider")
    local _, err2 = plugin.Store:SetProvider(order.id, 99999, "crafter")
    Test.eq(err2, "unknown-material")
    local _, err3 = plugin.Store:SetProvider("rr-ord-missing", 2447, "crafter")
    Test.eq(err3, "unknown-order")
end)

Test.it("SetProvider refuses non-draft orders", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    local ok, err = plugin.Store:SetProvider(order.id, 2447, "crafter")
    Test.falsy(ok)
    Test.eq(err, "not-draft")
end)

Test.it("SetProvider emits OrderUpdated with before/after split", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = { { recipeKey = 929, quantity = 3 } },
    }))
    plugin.Store:SetProvider(order.id, 2447, "crafter", 2, "Mattia-TestRealm")
    local events = plugin.Store:GetRecentEvents(10)
    local last = events[#events]
    Test.eq(last.kind, "OrderUpdated")
    Test.eq(last.payload.change, "provider-set")
    Test.eq(last.payload.itemID, 2447)
    Test.eq(last.payload.provider, "crafter")
    Test.eq(last.payload.quantity, 2)
    Test.eq(last.payload.previousRequester, 3)
    Test.eq(last.payload.previousCrafter, 0)
    Test.eq(last.payload.newCrafter, 2)
    Test.eq(last.payload.newRequester, 1)
end)

Test.it("Transition enforces state-machine rules and records the change", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local ok = plugin.Store:Transition(order.id, "MaterialsSent", "requester")
    Test.truthy(ok)
    Test.eq(order.status, "MaterialsSent")

    local blocked, err = plugin.Store:Transition(order.id, "Completed", "requester")
    Test.falsy(blocked)
    Test.eq(err, "invalid-transition")
end)

Test.it("Transition rejects unauthorised actors", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local ok, err = plugin.Store:Transition(order.id, "MaterialsSent", "crafter")
    Test.falsy(ok)
    Test.eq(err, "actor-not-authorized")
end)

Test.it("Transition appends OrderUpdated with from/to and actor", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(order.id, "MaterialsSent", "requester", { reason = "spec" })
    local events = plugin.Store:GetRecentEvents(10)
    local last = events[#events]
    Test.eq(last.kind, "OrderUpdated")
    Test.eq(last.actor, "requester")
    Test.eq(last.payload.fromState, "Draft")
    Test.eq(last.payload.toState, "MaterialsSent")
    Test.eq(last.payload.details.reason, "spec")
end)

Test.it("ListOrders sorts newest first and honors status filter", function()
    local plugin = freshPlugin()
    -- Bump the wow clock between creates so createdAt differs by 1s, so the
    -- sort is unambiguous.
    local wowState = Loader.Wow.GetState()
    local first = plugin.Store:CreateDraft(defaultSpec())
    wowState.now = wowState.now + 1
    plugin.Store:CreateDraft(defaultSpec())
    wowState.now = wowState.now + 1
    local third = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(third.id, "MaterialsSent", "requester")

    local all = plugin.Store:ListOrders()
    Test.eq(#all, 3)
    Test.eq(all[1].id, third.id, "newest first")
    Test.eq(all[3].id, first.id)

    local drafts = plugin.Store:ListOrders({ status = "Draft" })
    Test.eq(#drafts, 2)
    for _, order in ipairs(drafts) do
        Test.eq(order.status, "Draft")
    end
end)

Test.it("ListOrders filters by requester and crafter", function()
    local plugin = freshPlugin()
    plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:CreateDraft(defaultSpec({ crafter = "Alice-TestRealm" }))
    local forBob   = plugin.Store:ListOrders({ crafter = "Bob-TestRealm" })
    local forAlice = plugin.Store:ListOrders({ crafter = "Alice-TestRealm" })
    Test.eq(#forBob, 1)
    Test.eq(#forAlice, 1)
end)

Test.it("AppendEvent increments seq and validates kind", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    Test.eq(plugin.db.global.events.seq, 1, "Created event consumed seq=1")
    plugin.Store:AddLine(order.id, { recipeKey = 858, quantity = 1 })
    Test.eq(plugin.db.global.events.seq, 2)

    local nilEntry, err = plugin.Store:AppendEvent({})
    Test.eq(nilEntry, nil)
    Test.eq(err, "invalid-event")
end)

Test.it("GetRecentEvents returns at most the last N entries", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    for index = 1, 6 do
        plugin.Store:AppendEvent({ kind = "Tick", orderId = order.id, actor = "system", payload = { i = index } })
    end
    local tail = plugin.Store:GetRecentEvents(3)
    Test.eq(#tail, 3)
    Test.eq(tail[#tail].payload.i, 6, "last entry is the most recent")
    Test.eq(tail[1].payload.i, 4)
end)

io.write(string.format("Craft Orders store: %d test(s) passed\n", Test.count))
