local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

io.write("Runtime queue caps\n")

Test.it("enforces outbound queue caps and drops duplicate chunk state", function()
    local addon, _wow, _data = freshAddon()
    local cap = addon.Sync._private.constants.MAX_OUTBOUND_CHUNKS

    for index = 1, cap + 12 do
        addon.Sync:QueueOutboundBlock("Peerone-TestRealm", {
            sessionId = "session-1",
            seq = index <= 6 and 1 or index,
            key = "Peerone-TestRealm",
        })
    end

    addon.Sync:EnforceRuntimeQueueCaps("test")

    Test.gte(cap, #addon.Sync.outboundChunkQueue, "outbound queue should stay within cap")
    Test.gte(addon.Sync.telemetry.queueCapPrunes or 0, 1, "queue cap prunes should be recorded")
end)

Test.it("releases session chunks immediately on transfer done", function()
    local addon, _wow, _data = freshAddon()
    addon.Sync.outgoingSessions["session-9"] = {
        sessionId = "session-9",
        memberKey = "Peerone-TestRealm",
        targetKey = "Peerone-TestRealm",
        createdAt = time(),
    }
    addon.Sync.outboundChunkQueue = {
        {
            peer = "Peerone-TestRealm",
            block = {
                sessionId = "session-9",
                seq = 1,
                key = "Peerone-TestRealm",
            },
        },
    }

    addon.Sync:HandleTransferDone({
        sessionId = "session-9",
        sender = "Peerone-TestRealm",
    })

    Test.eq(addon.Sync.outgoingSessions["session-9"], nil, "outgoing session should be released immediately")
    Test.eq(#addon.Sync.outboundChunkQueue, 0, "queued chunk state for completed session should be released")
end)

io.write(string.format("Runtime queue caps: %d test(s) passed\n", Test.count))
