-- Backend coverage for the Board's tamper-warning band — verifies
-- that ledger entries with non-empty tamperFlags surface in the
-- order detail panel above the usual sections, and that clean
-- ledgers produce no warning noise.

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
    Loader.Wow.SetPlayer("Bob", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    return plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    })
end

io.write("Craft Orders tamper warning band\n")

Test.it("returns empty when the order has no ledger", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    Test.eq(#plugin.Board:FormatTamperWarning(order), 0)
end)

Test.it("returns empty when all ledger entries are clean", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 1 }, observed = { [2447] = 1 },
        senderMatch = true, hashMatch = true,
        itemsMatch = true, batchMatch = true, valid = true,
        tamperFlags = {},
    })
    local updated = plugin.Store:GetOrder(order.id)
    Test.eq(#plugin.Board:FormatTamperWarning(updated), 0,
        "no flags should produce no warning lines")
end)

Test.it("renders a flagged batch with the flag list and the sender", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 2 }, observed = { [2447] = 0 },
        senderMatch = false, hashMatch = true,
        itemsMatch = false, batchMatch = true, valid = false,
        tamperFlags = { "sender-mismatch", "item-missing:2447" },
        sender = "Stranger-TestRealm",
    })
    local updated = plugin.Store:GetOrder(order.id)
    local out = plugin.Board:FormatTamperWarning(updated)
    Test.gte(#out, 3, "expects the header + at least one batch line + sender line")
    local joined = table.concat(out, "\n")
    Test.truthy(joined:find("Tamper detected", 1, true))
    Test.truthy(joined:find("batch 1", 1, true))
    Test.truthy(joined:find("sender-mismatch", 1, true))
    Test.truthy(joined:find("item-missing:2447", 1, true))
    Test.truthy(joined:find("Stranger-TestRealm", 1, true))
end)

Test.it("lists multiple dirty batches in ascending batch order", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Out-of-order insertion to verify the sort.
    plugin.Store:RecordBatchReceipt(order.id, 3, {
        expected = { [2447] = 1 }, observed = {},
        senderMatch = true, hashMatch = true, itemsMatch = false,
        batchMatch = true, valid = false,
        tamperFlags = { "item-missing:2447" },
    })
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [765] = 1 }, observed = {},
        senderMatch = true, hashMatch = true, itemsMatch = false,
        batchMatch = true, valid = false,
        tamperFlags = { "item-missing:765" },
    })
    local out = plugin.Board:FormatTamperWarning(plugin.Store:GetOrder(order.id))
    local joined = table.concat(out, "\n")
    -- batch 1 must appear before batch 3 in the rendered output.
    local pos1 = joined:find("batch 1", 1, true)
    local pos3 = joined:find("batch 3", 1, true)
    Test.truthy(pos1 and pos3 and pos1 < pos3,
        "batch 1 line must come before batch 3 line")
end)

Test.it("FormatDetailLines includes the tamper band above the body sections", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    plugin.Store:RecordBatchReceipt(order.id, 1, {
        expected = { [2447] = 1 }, observed = {},
        senderMatch = true, hashMatch = false, itemsMatch = false,
        batchMatch = true, valid = false,
        tamperFlags = { "hash-mismatch", "item-missing:2447" },
    })
    local detail = plugin.Board:FormatDetailLines(plugin.Store:GetOrder(order.id))
    local joined = table.concat(detail, "\n")

    Test.truthy(joined:find("Tamper detected", 1, true),
        "warning band must be present in the rendered detail")
    -- Tamper band sits above the Lines section; verify the order.
    local posTamper = joined:find("Tamper detected", 1, true)
    local posLines = joined:find("Lines:", 1, true)
    Test.truthy(posTamper and posLines and posTamper < posLines,
        "warning band must precede the Lines section so it's seen first")
end)
