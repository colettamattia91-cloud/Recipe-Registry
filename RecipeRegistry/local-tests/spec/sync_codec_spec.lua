local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon(payloadMode)
    local addon, wow = Loader.Load({
        payloadMode = payloadMode,
    })
    return addon, wow
end

local function largePayload()
    local values = {}
    for index = 1, 120 do
        values[index] = "recipe-" .. tostring(index)
    end
    return {
        kind = "BLOCK_SNAPSHOT",
        blockKey = "Codecpeer-TestRealm::Alchemy",
        blockPayload = {
            ownerCharacter = "Codecpeer-TestRealm",
            professionKey = "Alchemy",
            recipeKeys = values,
        },
    }
end

io.write("Sync codec\n")

Test.it("passes table-fast payloads through without serialization", function()
    local addon = freshAddon("table-fast")
    local payload = { kind = "HELLO", key = "Codecpeer-TestRealm" }

    local encoded = addon.Sync:EncodeWirePayload(payload)
    local decoded = addon.Sync:DecodeWirePayload(encoded)

    Test.eq(encoded, payload, "table-fast encode should return the table payload")
    Test.eq(decoded, payload, "table-fast decode should return the same table payload")
end)

Test.it("roundtrips realistic string payloads and uses compression for large envelopes", function()
    local addon = freshAddon("realistic-string")
    local payload = largePayload()

    local encoded = addon.Sync:EncodeWirePayload(payload)
    local decoded = addon.Sync:DecodeWirePayload(encoded)

    Test.eq(type(encoded), "string", "realistic payload should encode to string")
    Test.truthy(encoded:find("^RR1|") ~= nil, "large payload should use the compressed wire marker")
    Test.eq(decoded.kind, payload.kind, "decoded kind")
    Test.eq(decoded.blockKey, payload.blockKey, "decoded block key")
    Test.eq(#decoded.blockPayload.recipeKeys, #payload.blockPayload.recipeKeys, "decoded recipe count")
    Test.eq(addon.Sync.telemetry.wireCompressedSent or 0, 1, "compression send telemetry")
    Test.eq(addon.Sync.telemetry.wireCompressedReceived or 0, 1, "compression receive telemetry")
end)

Test.it("rejects malformed compressed and serialized payloads without throwing", function()
    local addon = freshAddon("realistic-string")

    Test.eq(addon.Sync:DecodeWirePayload("RR1|not-valid"), nil, "bad compressed payload should decode to nil")
    Test.eq(addon.Sync:DecodeWirePayload("not-a-serialized-payload"), nil, "bad serializer payload should decode to nil")
    Test.eq(addon.Sync:DecodeWirePayload(""), nil, "empty payload should decode to nil")
end)

io.write(string.format("Sync codec: %d test(s) passed\n", Test.count))
