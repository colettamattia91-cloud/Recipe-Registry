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

io.write("Manifest identical skip\n")

Test.it("equivalent peer manifest block avoids catch-up requests and UI refresh", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"
    seedProfession(data, localKey, "Alchemy", 99201, { sourceType = "owner", rev = 3, updatedAt = 300 })
    local manifest = data:BuildManifestCacheNow("identical")
    local blockKey = data:BuildSyncBlockKey(localKey, "Alchemy")
    local localBlock = manifest.blocks[blockKey]

    local result = addon.Sync:ProcessPeerManifestComparison(peerKey, {
        memberKey = peerKey,
        builtAt = time(),
        totals = { blocks = 1, recipes = 1 },
        blocks = {
            [blockKey] = {
                blockKey = blockKey,
                ownerCharacter = localBlock.ownerCharacter,
                professionKey = localBlock.professionKey,
                revision = localBlock.revision,
                lastUpdatedAt = localBlock.lastUpdatedAt,
                sourceType = localBlock.sourceType,
                guildStatus = localBlock.guildStatus,
                count = localBlock.count,
                fingerprint = localBlock.fingerprint,
            },
        },
    })

    Test.eq(result.queuedRequests, 0, "identical manifest should not queue REQ")
    Test.eq(result.deferredRequests, 0, "identical manifest should not defer catch-up")
    Test.eq(result.identicalBlocks, 1, "identical block count should be reported")
    Test.falsy(result.shouldRefreshUI, "identical manifest should not demand a UI refresh")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "no pending request should be created")
    Test.eq(addon.Sync.telemetry.manifestIdenticalBlockSkips or 0, 1, "identical skip telemetry should increment")
end)

io.write(string.format("Manifest identical skip: %d test(s) passed\n", Test.count))
