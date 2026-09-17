local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    Loader.PrimeSyncReady(addon, {
        reason = "block-snapshot-errors",
    })
    return addon, wow, addon.Data
end

local function seedSession(sync, seedKey)
    sync.outboundSeedSession = {
        state = "waiting-block",
        seedKey = seedKey,
        diffRequestId = "diff-1",
        activeBlockKey = seedKey .. "::Alchemy",
        activeBlockRequestId = "pull-1",
        wantedBlocks = {
            { blockKey = seedKey .. "::Alchemy" },
        },
        nextWantedIndex = 1,
        successfulBlockMerges = 0,
    }
    return sync.outboundSeedSession
end

local function validPayload(seedKey)
    return {
        sender = seedKey,
        requestId = "pull-1",
        blockKey = seedKey .. "::Alchemy",
        blockPayload = {
            ownerCharacter = seedKey,
            professionKey = "Alchemy",
            recipeKeys = { 91001 },
            skillRank = 300,
            skillMaxRank = 375,
        },
    }
end

io.write("Block snapshot error paths\n")

Test.it("ignores block snapshots that do not match the active outbound session", function()
    local addon = freshAddon()
    local seedKey = "Seedone-TestRealm"
    seedSession(addon.Sync, seedKey)

    Test.falsy(addon.Sync:HandleReceivedBlockSnapshot({
        sender = "Otherseed-TestRealm",
        requestId = "pull-1",
        blockKey = seedKey .. "::Alchemy",
    }), "wrong sender should be ignored")
    Test.eq(addon.Sync.outboundSeedSession.state, "waiting-block", "wrong sender should not abort")

    Test.falsy(addon.Sync:HandleReceivedBlockSnapshot({
        sender = seedKey,
        requestId = "pull-other",
        blockKey = seedKey .. "::Alchemy",
    }), "wrong request id should be ignored")
    Test.eq(addon.Sync.outboundSeedSession.state, "waiting-block", "wrong request id should not abort")

    Test.falsy(addon.Sync:HandleReceivedBlockSnapshot({
        sender = seedKey,
        requestId = "pull-1",
        blockKey = seedKey .. "::Tailoring",
    }), "wrong block should be ignored")
    Test.eq(addon.Sync.outboundSeedSession.state, "waiting-block", "wrong block should not abort")
end)

Test.it("aborts the session when the matching block snapshot cannot be merged", function()
    local addon = freshAddon()
    local seedKey = "Seedtwo-TestRealm"
    seedSession(addon.Sync, seedKey)
    local payload = validPayload(seedKey)
    payload.blockPayload = "not-a-block-payload"

    local applied = addon.Sync:HandleReceivedBlockSnapshot(payload)

    Test.falsy(applied, "invalid matching snapshot should fail")
    Test.eq(addon.Sync.outboundSeedSession.state, "aborted", "merge failure should abort the session")
    Test.eq(addon.Sync.outboundSeedSession.abortReason, "block-merge-failed", "abort reason")
    Test.eq(addon.Sync.telemetry.lastAbortReason, "block-merge-failed", "telemetry abort reason")
end)

Test.it("rejects seed-side snapshot sends for invalid or missing block data", function()
    local addon = freshAddon()

    Test.falsy(addon.Sync:SendBlockSnapshot("Peerone-TestRealm", nil), "nil request should not send")
    Test.falsy(addon.Sync:SendBlockSnapshot("Peerone-TestRealm", {
        requestId = "pull-1",
        blockKey = "Missingowner-TestRealm::Alchemy",
    }), "missing block should not send")
end)

io.write(string.format("Block snapshot error paths: %d test(s) passed\n", Test.count))
