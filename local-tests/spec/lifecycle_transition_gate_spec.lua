local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = entry.owner or memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
    })
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, profession), "test-seed")
    return entry
end

io.write("Lifecycle transition gate\n")

Test.it("player entering world in instance starts transition and defers hello", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 99101, { sourceType = "owner" })
    wow.SetInstance(true, "raid")

    addon:OnPlayerEnteringWorld(nil, false, false)

    Test.truthy(addon.Sync:IsInWorldTransition(), "world transition should be active")
    Test.eq(addon.Sync.worldTransitionReason, "instance-enter", "instance transition reason should be recorded")
    Test.eq(#(addon.Sync.transitionDrainQueue or {}), 1, "hello should be deferred into transition drain")
    Test.eq(addon.Sync.transitionDrainQueue[1].kind, "hello", "deferred lifecycle work should queue hello")
    Test.eq(#wow.GetSentComm(), 0, "no HELLO should be sent immediately during transition")
end)

Test.it("warmup expiry converts deferred work into progressive transition drain", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"
    seedProfession(data, localKey, "Alchemy", 99111, { sourceType = "owner" })
    data:BuildManifestCacheNow("transition-test")

    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = "1.8.1" }
    addon.Sync:EnterWarmup("test", 12)
    addon.Sync:EnterWorldTransition("test-transition", 12)
    addon.Sync:QueueWarmupManifestPeer(peerKey, "warmup")
    addon.Sync:QueueWarmupManifestRefresh(peerKey)
    addon.Sync._pendingWarmupManifestBroadcastReason = "broadcast"
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = peerKey,
            ownerCharacter = peerKey,
            revision = 2,
            blockKeys = { data:BuildSyncBlockKey(peerKey, "Alchemy") },
            expectedFingerprints = {},
        },
    }

    addon.Sync.warmupUntil = 0
    addon.Sync:HandleWarmupExpired()

    Test.gte(#(addon.Sync.transitionDrainQueue or {}), 4, "warmup work should move into transition drain queue")
    Test.eq(#(addon.Sync.manifestChunkQueue or {}), 0, "manifest fan-out should not flush inline at warmup end")
end)

io.write(string.format("Lifecycle transition gate: %d test(s) passed\n", Test.count))
