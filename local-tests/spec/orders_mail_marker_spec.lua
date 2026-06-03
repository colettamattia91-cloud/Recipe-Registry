-- Backend coverage for the Craft Orders mail marker codec — the
-- machine-readable block at the end of the mail body used by the
-- scanner to identify, verify, and route incoming material mails.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({})
end

io.write("Craft Orders mail marker\n")

Test.it("CanonicalItems sorts by itemID for stable hashing", function()
    local plugin = freshPlugin()
    Test.eq(plugin.MailMarker:CanonicalItems({ [765] = 3, [2447] = 1 }),
        "765=3,2447=1",
        "should sort by itemID ascending")
    Test.eq(plugin.MailMarker:CanonicalItems({ [2447] = 1, [765] = 3 }),
        "765=3,2447=1",
        "insertion order must not affect output")
end)

Test.it("CanonicalHash is identical for equivalent item sets", function()
    local plugin = freshPlugin()
    local a = plugin.MailMarker:CanonicalHash({ [765] = 3, [2447] = 1 })
    local b = plugin.MailMarker:CanonicalHash({ [2447] = 1, [765] = 3 })
    Test.eq(a, b, "same items, different insertion order => same hash")
    Test.eq(#a, 8, "hash should be 8 hex chars")
end)

Test.it("CanonicalHash changes when a count changes", function()
    local plugin = freshPlugin()
    local a = plugin.MailMarker:CanonicalHash({ [765] = 3 })
    local b = plugin.MailMarker:CanonicalHash({ [765] = 4 })
    Test.ne(a, b)
end)

Test.it("CanonicalHash changes when an item is added", function()
    local plugin = freshPlugin()
    local a = plugin.MailMarker:CanonicalHash({ [765] = 3 })
    local b = plugin.MailMarker:CanonicalHash({ [765] = 3, [2447] = 1 })
    Test.ne(a, b)
end)

Test.it("Encode rejects missing required fields", function()
    local plugin = freshPlugin()
    local _, err1 = plugin.MailMarker:Encode(nil)
    Test.eq(err1, "invalid-spec")
    local _, err2 = plugin.MailMarker:Encode({ orderId = "" })
    Test.eq(err2, "missing-orderId")
    local _, err3 = plugin.MailMarker:Encode({ orderId = "x" })
    Test.eq(err3, "missing-requester")
    local _, err4 = plugin.MailMarker:Encode({ orderId = "x", requester = "A-R", crafter = "B-R", items = nil })
    Test.eq(err4, "missing-items")
    local _, err5 = plugin.MailMarker:Encode({
        orderId = "x", requester = "A-R", crafter = "B-R",
        batchNumber = 4, totalBatches = 2,
        items = {},
    })
    Test.eq(err5, "invalid-batch")
end)

Test.it("Encode produces a fenced block with sorted items and a hash", function()
    local plugin = freshPlugin()
    local encoded = plugin.MailMarker:Encode({
        orderId      = "rr-ord-abc123",
        requester    = "Mattia-TestRealm",
        crafter      = "Bob-TestRealm",
        batchNumber  = 1,
        totalBatches = 1,
        items        = { [2447] = 1, [765] = 3 },
    })
    Test.truthy(encoded, "should produce an encoded string")
    Test.truthy(encoded:find("--RR-ORDER--", 1, true))
    Test.truthy(encoded:find("--RR-END--", 1, true))
    Test.truthy(encoded:find('id="rr-ord-abc123"', 1, true))
    Test.truthy(encoded:find('req="Mattia-TestRealm"', 1, true))
    Test.truthy(encoded:find('cra="Bob-TestRealm"', 1, true))
    Test.truthy(encoded:find("b=1", 1, true))
    Test.truthy(encoded:find("bt=1", 1, true))
    -- Items rendered in itemID-ascending order: 765 < 2447.
    Test.truthy(encoded:find("[765]=3", 1, true) < encoded:find("[2447]=1", 1, true),
        "items must be sorted by itemID")
end)

Test.it("Decode round-trips an Encode", function()
    local plugin = freshPlugin()
    local input = {
        orderId      = "rr-ord-abc123",
        requester    = "Mattia-TestRealm",
        crafter      = "Bob-TestRealm",
        batchNumber  = 2,
        totalBatches = 3,
        items        = { [765] = 3, [2447] = 1 },
    }
    local encoded = plugin.MailMarker:Encode(input)
    local body = "Hi! Materials for your order.\n\n" .. encoded .. "\nThanks!"
    local decoded, err = plugin.MailMarker:Decode(body)
    Test.truthy(decoded, err)
    Test.eq(decoded.orderId,      input.orderId)
    Test.eq(decoded.requester,    input.requester)
    Test.eq(decoded.crafter,      input.crafter)
    Test.eq(decoded.batchNumber,  2)
    Test.eq(decoded.totalBatches, 3)
    Test.eq(decoded.schemaVersion, plugin.MailMarker.SCHEMA_VERSION)
    Test.eq(decoded.items[765],   3)
    Test.eq(decoded.items[2447],  1)
    Test.eq(decoded.hash,         plugin.MailMarker:CanonicalHash(input.items))
end)

Test.it("Decode rejects bodies without a marker", function()
    local plugin = freshPlugin()
    local _, err1 = plugin.MailMarker:Decode("plain mail body, no marker here")
    Test.eq(err1, "no-marker")
    local _, err2 = plugin.MailMarker:Decode("--RR-ORDER--\n{partial}")
    Test.eq(err2, "no-end-fence")
end)

Test.it("Decode of a hand-edited marker still works (humans can read/modify body text)", function()
    local plugin = freshPlugin()
    local body =
        "Hello Bob,\n" ..
        "  - Peacebloom x1\n" ..
        "  - Silverleaf x3\n" ..
        "--RR-ORDER--\n" ..
        '{id="rr-ord-zzz",req="A-Realm",cra="B-Realm",b=1,bt=1,sv=1,h="00000000",items={[765]=3,[2447]=1}}\n' ..
        "--RR-END--\n" ..
        "Cheers"
    local decoded, err = plugin.MailMarker:Decode(body)
    Test.truthy(decoded, err)
    Test.eq(decoded.orderId, "rr-ord-zzz")
    Test.eq(decoded.items[765], 3)
end)
