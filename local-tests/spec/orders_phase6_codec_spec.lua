local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({ recipeRegistryStub = { Data = {} } })
end

io.write("Craft Orders codec\n")

Test.it("Encode returns table directly in table-fast harness mode", function()
    local plugin = freshPlugin()
    local payload = { kind = "HELLO_ORDERS", id = "x" }
    local encoded = plugin.Codec:Encode(payload)
    -- The harness's AceSerializer returns the table as-is in
    -- table-fast mode; the codec must pass it through unchanged.
    Test.eq(type(encoded), "table")
    Test.eq(encoded.kind, "HELLO_ORDERS")
end)

Test.it("Decode passes table inputs through unchanged", function()
    local plugin = freshPlugin()
    local input = { kind = "SUMMARY_ORDERS", peerCount = 4 }
    local decoded = plugin.Codec:Decode(input)
    Test.eq(decoded, input, "table-fast mode: same reference back out")
end)

Test.it("Decode of empty/nil/non-string non-table returns nil", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Codec:Decode(nil), nil)
    Test.eq(plugin.Codec:Decode(""), nil)
    Test.eq(plugin.Codec:Decode(false), nil)
    Test.eq(plugin.Codec:Decode(42), nil)
end)

Test.it("Encode of nil returns nil and never throws", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Codec:Encode(nil), nil)
end)

Test.it("COMPRESS_MARKER is the RRO1| prefix (distinct from RR's RR1|)", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Codec.COMPRESS_MARKER, "RRO1|")
end)

Test.it("BuildInfo exposes the dev/release prefix split", function()
    local plugin = freshPlugin()
    Test.eq(plugin.RELEASE_COMM_PREFIX, "RRORD")
    Test.eq(plugin.DEV_COMM_PREFIX,     "RRORDDEV")
    -- COMM_PREFIX defaults to release when the harness doesn't supply
    -- an X-Build-Channel via addon metadata.
    Test.truthy(plugin.COMM_PREFIX == "RRORD" or plugin.COMM_PREFIX == "RRORDDEV")
    Test.eq(plugin.WIRE_VERSION, 1)
end)

Test.it("GetLocalVersionInfo returns a self-contained summary", function()
    local plugin = freshPlugin()
    local info = plugin.BuildInfo:GetLocalVersionInfo()
    Test.eq(info.wireVersion, 1)
    Test.eq(info.minSupportedWireVersion, 1)
    Test.truthy(info.commPrefix:find("RRORD", 1, true))
end)

io.write(string.format("Craft Orders codec: %d test(s) passed\n", Test.count))
