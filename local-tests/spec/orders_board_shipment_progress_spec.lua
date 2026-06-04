-- Backend coverage for the Board's "Shipments: N of M batches sent"
-- progress line in the order detail panel. The line replaces the
-- removed manual "Mark materials sent" button — users now read
-- progress and let the mail flow drive the state transition.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
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
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

io.write("Craft Orders board shipment progress line\n")

Test.it("returns nil when nothing has shipped yet", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    Test.eq(plugin.Board:FormatShipmentProgressLine(order), nil,
        "fresh Draft orders should not render a Shipments: line")
end)

Test.it("renders 'N of M' once at least one batch has sentAt", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchSent(order.id, 1,
        { recipient = "Bob-TestRealm", items = { [2447] = 1, [765] = 1 } })

    local line = plugin.Board:FormatShipmentProgressLine(plugin.Store:GetOrder(order.id))
    Test.truthy(line)
    Test.truthy(line:find("Shipments:", 1, true))
    Test.truthy(line:find("1 of 1", 1, true),
        "single-batch order should report 1 of 1 after sending")
end)

Test.it("FormatDetailLines includes the progress line below Delivery and above Lines", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchSent(order.id, 1, { recipient = "Bob-TestRealm", items = {} })

    local detail = plugin.Board:FormatDetailLines(plugin.Store:GetOrder(order.id))
    local joined = table.concat(detail, "\n")

    local posDelivery = joined:find("Delivery:", 1, true)
    local posShipment = joined:find("Shipments:", 1, true)
    local posLines    = joined:find("Lines:", 1, true)
    Test.truthy(posDelivery and posShipment and posLines,
        "all three section markers should be present in the detail body")
    Test.truthy(posDelivery < posShipment, "Shipments must follow Delivery")
    Test.truthy(posShipment < posLines, "Shipments must precede the Lines block")
end)

Test.it("counts every batches[*] entry that carries a sentAt stamp", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Three out-of-order RecordBatchSent calls simulate a user
    -- composing batches 2 and 3 then doubling back to batch 1.
    plugin.Store:RecordBatchSent(order.id, 2, { recipient = "Bob-TestRealm", items = {} })
    plugin.Store:RecordBatchSent(order.id, 3, { recipient = "Bob-TestRealm", items = {} })
    plugin.Store:RecordBatchSent(order.id, 1, { recipient = "Bob-TestRealm", items = {} })

    local line = plugin.Board:FormatShipmentProgressLine(plugin.Store:GetOrder(order.id))
    Test.truthy(line)
    Test.truthy(line:find("3 of", 1, true),
        "should count three sentAt-stamped slots regardless of insertion order")
end)
