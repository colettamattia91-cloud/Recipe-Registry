local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function makeOwner(prefix, index)
    return string.format("%s%03d-TestRealm", prefix, index)
end

local function makeBlock(data, ownerKey, professionKey, revision, opts)
    opts = opts or {}
    local blockKey = data:BuildSyncBlockKey(ownerKey, professionKey)
    return {
        blockKey = blockKey,
        ownerCharacter = opts.ownerCharacter or ownerKey,
        professionKey = opts.professionKey or professionKey,
        revision = revision or 1,
        lastUpdatedAt = opts.lastUpdatedAt or (1000 + (revision or 1)),
        sourceType = opts.sourceType or "replica",
        guildStatus = opts.guildStatus or "active",
        lastSeenInGuildAt = opts.lastSeenInGuildAt or 1000,
        count = opts.count or 1,
        fingerprint = opts.fingerprint or tostring(opts.recipeKey or (90000 + (revision or 1))),
    }
end

local function deliverManifest(addon, wow, senderKey, blocks, manifestId)
    local totalRecipes = 0
    for _, block in ipairs(blocks or {}) do
        totalRecipes = totalRecipes + (block.count or 0)
    end
    wow.DeliverComm(addon.Sync, {
        kind = "MANI",
        sender = senderKey,
        manifestId = manifestId or ("mani:" .. senderKey),
        builtAt = 2000,
        memberKey = senderKey,
        totals = { blocks = #(blocks or {}), recipes = totalRecipes },
        seq = 1,
        total = 1,
        blocks = blocks or {},
    }, { sender = senderKey, distribution = "WHISPER" })
end

local function runCatchupTick(addon, wow)
    wow.AdvanceTime(0.25)
    addon.Performance:RunNextStep()
end

local function runUntilPendingOrEmpty(addon, wow, ownerKey)
    for _ = 1, 8 do
        if addon.Sync.pendingRequests[ownerKey] or #(addon.Sync.manifestCatchupQueue or {}) == 0 then
            return
        end
        runCatchupTick(addon, wow)
    end
end

local function countPending(sync)
    return Test.countKeys(sync.pendingRequests)
end

io.write("Manifest catch-up cap\n")

Test.it("defers large manifest catch-up into capped batches", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Cappeer-TestRealm"
    local blocks = {}
    for index = 1, 40 do
        blocks[#blocks + 1] = makeBlock(data, makeOwner("Capowner", index), "Alchemy", index)
    end

    deliverManifest(addon, wow, senderKey, blocks, "cap:40")

    Test.eq(countPending(addon.Sync), 8, "first flush should cap owner requests")
    Test.eq(#(addon.Sync.manifestCatchupQueue or {}), 32, "remaining owners should defer")
    Test.eq(addon.Sync.telemetry.manifestCatchupDeferred, 32, "deferred telemetry")

    local batches = 1
    while #(addon.Sync.manifestCatchupQueue or {}) > 0 do
        Test.gte(8, countPending(addon.Sync), "pending request count should stay capped")
        addon.Sync.pendingRequests = {}
        runCatchupTick(addon, wow)
        batches = batches + 1
    end

    Test.gte(batches, 5, "40 owners should need multiple capped batches")
    Test.gte(6, batches, "40 owners should drain without extra repeated batches")
    Test.eq(addon.Sync.telemetry.manifestCatchupQueued, 40, "all owner requests should eventually queue")
    Test.eq(addon.Sync.telemetry.manifestCatchupDrained, 32, "deferred owners should drain")
    Test.eq(#(addon.Sync.manifestCatchupQueue or {}), 0, "deferred queue should empty")
end)

Test.it("splits a single owner with many blocks without losing block keys", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Bigpeer-TestRealm"
    local ownerKey = "Bigowner-TestRealm"
    local blocks = {}
    local expected = {}
    for index = 1, 70 do
        local profession = "Profession" .. tostring(index)
        local block = makeBlock(data, ownerKey, profession, 100 + index)
        blocks[#blocks + 1] = block
        expected[block.blockKey] = true
    end

    deliverManifest(addon, wow, senderKey, blocks, "cap:single-owner")

    local seen = {}
    while true do
        local pending = addon.Sync.pendingRequests[ownerKey]
        Test.truthy(pending, "owner request should be pending for each split")
        Test.gte(32, #(pending.requestedBlocks or {}), "block request count should stay capped")
        for _, blockKey in ipairs(pending.requestedBlocks or {}) do
            seen[blockKey] = true
        end
        addon.Sync.pendingRequests = {}
        if #(addon.Sync.manifestCatchupQueue or {}) == 0 then
            break
        end
        runUntilPendingOrEmpty(addon, wow, ownerKey)
    end

    Test.eq(Test.countKeys(seen), Test.countKeys(expected), "all block keys should be requested across splits")
    for blockKey in pairs(expected) do
        Test.truthy(seen[blockKey], "missing requested block " .. tostring(blockKey))
    end
end)

Test.it("does not let one large pending owner exhaust the global block budget", function()
    local addon, _wow, data = freshAddon()
    local senderKey = "Replicaone-TestRealm"
    local bigOwner = "Bigowner-TestRealm"
    local nextOwner = "Nextowner-TestRealm"
    local bigBlocks = {}

    for index = 1, 32 do
        bigBlocks[#bigBlocks + 1] = data:BuildSyncBlockKey(bigOwner, "Profession" .. tostring(index))
    end

    addon.Sync.pendingRequests[bigOwner] = {
        source = senderKey,
        memberKey = bigOwner,
        rev = 11,
        why = "manifest",
        queuedAt = time(),
        allowReplicaSource = true,
        requestedBlocks = bigBlocks,
        expectedFingerprints = {},
    }
    addon.Sync.manifestCatchupQueue = {
        {
            senderKey = senderKey,
            ownerCharacter = nextOwner,
            revision = 7,
            blockKeys = { data:BuildSyncBlockKey(nextOwner, "Alchemy") },
            expectedFingerprints = {},
            offlineReplica = true,
        },
    }

    addon.Sync:DrainManifestCatchupQueue()

    Test.truthy(addon.Sync.pendingRequests[nextOwner], "another owner should still queue while owner headroom remains")
    Test.eq(#(addon.Sync.pendingRequests[nextOwner].requestedBlocks or {}), 1, "new owner should keep its requested block set")
end)

Test.it("skips online replica owners, local stale owners, and malformed rows", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Skipper-TestRealm"
    local onlineOwner = "Onlineowner-TestRealm"
    local staleOwner = "Staleowner-TestRealm"
    local offlineOwner = "Offlineowner-TestRealm"

    wow.SetGuildRoster({ onlineOwner })
    data:RebuildOnlineCache()
    data:GetOrCreateMember(staleOwner).guildStatus = "stale"

    local blocks = {
        makeBlock(data, onlineOwner, "Alchemy", 10),
        makeBlock(data, staleOwner, "Alchemy", 11),
        makeBlock(data, offlineOwner, "Alchemy", 12),
        {
            blockKey = "Bad:Owner-TestRealm::Alchemy",
            ownerCharacter = "Bad:Owner-TestRealm",
            professionKey = "Alchemy",
            revision = 99,
            count = 1,
            fingerprint = "bad",
        },
    }

    deliverManifest(addon, wow, senderKey, blocks, "cap:skip")

    Test.truthy(addon.Sync.pendingRequests[offlineOwner], "offline owner should be requested from replica")
    Test.falsy(addon.Sync.pendingRequests[onlineOwner], "online owner should not be requested from replica")
    Test.falsy(addon.Sync.pendingRequests[staleOwner], "local stale owner should not be requested from replica")
    Test.eq(addon.Sync.telemetry.manifestCatchupSkippedOnlineOwners, 1, "online skip telemetry")
    Test.eq(addon.Sync.telemetry.manifestCatchupSkippedStaleOwners, 1, "stale skip telemetry")
    Test.eq(#(addon.Sync.manifestCatchupQueue or {}), 0, "malformed rows should not defer")
end)

Test.it("prioritizes sender-owned manifest blocks before offline replicas", function()
    local addon, wow, data = freshAddon()
    local senderKey = "Prioritypeer-TestRealm"
    local blocks = {
        makeBlock(data, senderKey, "Alchemy", 1, { sourceType = "owner" }),
    }
    for index = 1, 12 do
        blocks[#blocks + 1] = makeBlock(data, makeOwner("Priorityowner", index), "Alchemy", 100 + index)
    end

    deliverManifest(addon, wow, senderKey, blocks, "cap:priority")

    Test.truthy(addon.Sync.pendingRequests[senderKey], "sender-owned block should be in first capped batch")
    Test.eq(countPending(addon.Sync), 8, "first priority batch should still respect owner cap")
    Test.gte(#(addon.Sync.manifestCatchupQueue or {}), 1, "lower-priority replicas should defer")
end)

io.write(string.format("Manifest catch-up cap: %d test(s) passed\n", Test.count))
