-- Verifies that the Reducer broadcasts CraftOrders:Changed after a
-- successful batch apply, so the Board and Cart pick up remote-driven
-- mutations without waiting for the next local edit. Without this
-- signal, a peer's order update lands in the store silently and the
-- UI shows stale state until the user touches something.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = { label = "Major Healing Potion", createdItemID = 22829, reagents = {} },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

-- Patches Addon:SendMessage to capture broadcast tuples into a list.
-- Returns the list (live reference) so the spec can inspect it after
-- driving the reducer.
local function captureSendMessages(addon)
    local captured = {}
    addon.SendMessage = function(_self, message, ...)
        captured[#captured + 1] = { message = message, args = { ... } }
    end
    return captured
end

local function freshPlugin()
    Loader.Wow.Reset()
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub() })
    return plugin, captureSendMessages(plugin)
end

local FOREIGN = "Bob-OtherRealm"

local function makeCreateEvent(orderId, seq, requester, crafter)
    return {
        kind     = "OrderCreated",
        orderId  = orderId,
        producer = FOREIGN,
        seq      = seq,
        actor    = requester,
        at       = 1700000000 + seq,
        payload  = {
            requester    = requester,
            crafter      = crafter,
            deliveryMode = "mail",
            notes        = "",
            lines        = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
            lineCount    = 1,
            createdAt    = 1700000000 + seq,
        },
    }
end

local function countBroadcasts(captured, message)
    local count = 0
    for index = 1, #captured do
        if captured[index].message == message then count = count + 1 end
    end
    return count
end

io.write("Craft Orders reducer change broadcast\n")

Test.it("broadcasts CraftOrders:Changed once after a successful batch apply", function()
    local plugin, captured = freshPlugin()
    local batch = {
        makeCreateEvent("rr-ord-a", 1, "Alice-Realm", "Bob-OtherRealm"),
        makeCreateEvent("rr-ord-b", 2, "Carl-Realm",  "Bob-OtherRealm"),
    }
    local summary = plugin.Reducer:ApplyEvents(batch)
    Test.eq(summary.applied, 2)
    Test.eq(countBroadcasts(captured, "CraftOrders:Changed"), 1,
        "exactly one coalesced broadcast for the whole batch")
end)

Test.it("does not broadcast when nothing was applied", function()
    local plugin, captured = freshPlugin()
    -- Empty batch.
    plugin.Reducer:ApplyEvents({})
    -- Batch of all duplicates (apply once, then again).
    plugin.Reducer:ApplyEvents({ makeCreateEvent("rr-ord-a", 1, "Alice-Realm", "Bob-OtherRealm") })
    -- Reset the capture window after the legitimate apply.
    for key in pairs(captured) do captured[key] = nil end
    plugin.Reducer:ApplyEvents({ makeCreateEvent("rr-ord-a", 1, "Alice-Realm", "Bob-OtherRealm") })
    Test.eq(countBroadcasts(captured, "CraftOrders:Changed"), 0,
        "a duplicate-only batch must not fire a stale broadcast")
end)

Test.it("first arg carries a reason tag so subscribers can distinguish sync from local edits", function()
    local plugin, captured = freshPlugin()
    plugin.Reducer:ApplyEvents({ makeCreateEvent("rr-ord-a", 1, "Alice-Realm", "Bob-OtherRealm") })
    local match
    for index = 1, #captured do
        if captured[index].message == "CraftOrders:Changed" then match = captured[index] end
    end
    Test.truthy(match, "should have a captured broadcast")
    Test.eq(match.args[1], "sync-applied",
        "Subscribers expecting 'sync-applied' as the reason should see exactly that string")
end)
