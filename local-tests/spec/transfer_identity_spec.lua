local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

io.write("Transfer identity\n")

Test.it("creates distinct outgoing sessions for same-owner requests in the same second", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)

    entry.rev = 5
    entry.updatedAt = 1234
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = { [91001] = true },
        count = 1,
        signature = "91001",
        skillRank = 350,
        skillMaxRank = 375,
        blockRevision = 5,
        lastUpdatedAt = 1234,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = 1234,
    })

    addon.Sync:HandleRequest({
        sender = "Peerone-TestRealm",
        key = localKey,
        knownRev = 0,
    })
    addon.Sync:HandleRequest({
        sender = "Peertwo-TestRealm",
        key = localKey,
        knownRev = 0,
    })

    local sessionIds = {}
    local targets = {}
    for sessionId, state in pairs(addon.Sync.outgoingSessions) do
        sessionIds[#sessionIds + 1] = sessionId
        targets[state.targetKey] = true
    end

    Test.eq(#sessionIds, 2, "same-second requests for the same owner should keep distinct outgoing sessions")
    Test.truthy(targets["Peerone-TestRealm"], "first peer should keep its own outgoing session")
    Test.truthy(targets["Peertwo-TestRealm"], "second peer should keep its own outgoing session")
end)

io.write(string.format("Transfer identity: %d test(s) passed\n", Test.count))