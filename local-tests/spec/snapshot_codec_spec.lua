local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function buildRecipeSet(count)
    local recipes = {}
    for index = 1, count do
        recipes[90000 + index] = true
    end
    return recipes
end

io.write("Snapshot codec\n")

Test.it("advertises and stores negotiated snapshot codec capabilities", function()
    local addon, _wow = freshAddon()

    local caps = addon.Sync:GetLocalProtocolCaps()
    Test.eq(caps.snapCodec, "snap.lsd1", "local protocol caps should advertise snapshot codec")
    Test.eq(addon.Sync:GetLocalSnapshotCodecId(), "snap.lsd1", "local snapshot codec id")

    addon.Sync:HandleHello({
        key = "Peerone-TestRealm",
        sender = "Peerone-TestRealm",
        rev = 2,
        updatedAt = 222,
        caps = {
            snapCodec = "snap.lsd1",
            snapCodecMin = 1,
        },
    })

    local peerCaps = addon.Sync:GetPeerCaps("Peerone-TestRealm")
    Test.eq(peerCaps.snapCodec, "snap.lsd1", "peer codec capability should be tracked")
    Test.eq(peerCaps.snapCodecMin, 1, "peer codec min version should be tracked")
end)

Test.it("includes accepted snapshot codec in direct REQ envelopes", function()
    local addon, wow = freshAddon()
    local request = {
        source = "Peerone-TestRealm",
        memberKey = "Peerone-TestRealm",
        rev = 7,
        why = "manual",
        queuedAt = time(),
    }

    addon.Sync:DispatchPendingRequest(request.memberKey, request)

    local sent = wow.GetSentComm()
    local payload = sent[#sent] and sent[#sent].message or nil
    Test.truthy(payload, "REQ payload should be sent")
    Test.eq(payload.kind, "REQ", "REQ envelope kind")
    Test.eq(payload.acceptSnapCodec, "snap.lsd1", "REQ should advertise accepted snapshot codec")
end)

Test.it("encodes large snapshot blocks and decodes them back losslessly", function()
    local addon, _wow = freshAddon()
    local block = {
        sessionId = "session-42",
        key = "Peerone-TestRealm",
        rev = 8,
        updatedAt = 888,
        sourceType = "owner",
        profession = "Alchemy",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = "Potion Master",
        recipeKeys = buildRecipeSet(220),
        seq = 1,
        total = 3,
    }

    local wire = addon.Sync:EncodeSnapshotBlockForWire(block, "Peerone-TestRealm", {
        acceptSnapCodec = addon.Sync:GetLocalSnapshotCodecId(),
    })
    local decoded, ok = addon.Sync:DecodeSnapshotBlockFromWire(wire)

    Test.eq(wire.codec, "snap.lsd1", "large snapshot block should use codec")
    Test.truthy(type(wire.blob) == "string" and #wire.blob > 0, "encoded blob should be present")
    Test.truthy(ok, "encoded block should decode successfully")
    Test.eq(decoded.profession, block.profession, "profession should roundtrip")
    Test.eq(decoded.specialization, block.specialization, "specialization should roundtrip")
    Test.eq(Test.countKeys(decoded.recipeKeys), Test.countKeys(block.recipeKeys), "recipe count should roundtrip")
    Test.eq(addon.Sync.telemetry.snapCodecEncoded or 0, 1, "encode telemetry should increment")
    Test.eq(addon.Sync.telemetry.snapCodecDecoded or 0, 1, "decode telemetry should increment")
end)

Test.it("falls back to legacy SNAP payloads for small snapshot blocks", function()
    local addon, _wow = freshAddon()
    local block = {
        sessionId = "session-small",
        key = "Peerone-TestRealm",
        rev = 3,
        updatedAt = 333,
        sourceType = "owner",
        profession = "Tailoring",
        recipeKeys = { [94001] = true },
        seq = 1,
        total = 1,
    }

    local wire = addon.Sync:EncodeSnapshotBlockForWire(block, "Peerone-TestRealm", {
        acceptSnapCodec = addon.Sync:GetLocalSnapshotCodecId(),
    })

    Test.eq(wire, block, "small snapshot block should stay legacy")
    Test.eq(addon.Sync.telemetry.snapCodecSkippedSmall or 0, 1, "small payload telemetry should increment")
    Test.eq(addon.Sync.telemetry.snapCodecEncoded or 0, 0, "small payload should not increment encoded count")
end)

Test.it("drops corrupted codec payloads before appending inbound chunks", function()
    local addon, _wow = freshAddon()
    local appended = false
    local released
    local failed

    addon.Data.AppendIncomingChunk = function()
        appended = true
    end
    addon.Sync.ReleaseCompletedTransferState = function(_, memberKey, sessionId, reason)
        released = {
            memberKey = memberKey,
            sessionId = sessionId,
            reason = reason,
        }
        return 0
    end
    addon.Sync.MarkPeerFailure = function(_, peerKey, reason)
        failed = {
            peerKey = peerKey,
            reason = reason,
        }
    end

    local ok = addon.Sync:DecodeChunkStep({
        codec = "snap.lsd1",
        blob = "corrupted",
        key = "Peerone-TestRealm",
        sender = "Peerone-TestRealm",
        sessionId = "session-bad",
        rev = 5,
        updatedAt = 555,
        seq = 1,
        total = 1,
    })

    Test.falsy(ok, "corrupted payload should be rejected")
    Test.falsy(appended, "corrupted payload should not append inbound chunks")
    Test.eq(addon.Sync.telemetry.snapCodecDropped or 0, 1, "corrupted payload should increment dropped telemetry")
    Test.eq(released.memberKey, "Peerone-TestRealm", "corrupted payload should release session state")
    Test.eq(released.reason, "codec-error", "corrupted payload release reason")
    Test.eq(failed.peerKey, "Peerone-TestRealm", "corrupted payload should mark peer failure")
end)

io.write(string.format("Snapshot codec: %d test(s) passed\n", Test.count))
