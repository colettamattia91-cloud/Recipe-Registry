local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = entry.owner or memberKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or data:GetMemberSourceType(memberKey)
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt or entry.updatedAt

    local recipes = {}
    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
    end

    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = opts.count or #recipeKeys,
        signature = opts.signature or table.concat(recipeKeys, ","),
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 375,
        specialization = opts.specialization,
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.lastUpdatedAt or opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })

    return entry, entry.professions[profession]
end

local function buildActiveManifestFingerprint(data)
    return data:BuildManifestContentFingerprint(data:BuildSyncManifest(false))
end

io.write("Manifest content fingerprint\n")

Test.it("ignores revision and volatile metadata for identical active recipe content", function()
    local _addonA, _wowA, dataA = freshAddon()
    local _addonB, _wowB, dataB = freshAddon()
    local ownerKey = "Ownerone-TestRealm"

    seedProfession(dataA, ownerKey, "Alchemy", { 91001, 91002 }, {
        rev = 3,
        updatedAt = 100,
        lastUpdatedAt = 100,
        blockRevision = 3,
        skillRank = 300,
        skillMaxRank = 375,
        sourceType = "owner",
        specialization = "Potion Master",
        lastSeenInGuildAt = 100,
    })
    local _entryB, profB = seedProfession(dataB, ownerKey, "Alchemy", { 91002, 91001 }, {
        rev = 17,
        updatedAt = 900,
        lastUpdatedAt = 950,
        blockRevision = 21,
        skillRank = 1,
        skillMaxRank = 75,
        sourceType = "replica",
        specialization = "Potion Master",
        lastSeenInGuildAt = 999,
    })

    profB.count = 99
    profB.signature = "stale-signature"

    local manifestA = dataA:BuildSyncManifest(false)
    local manifestB = dataB:BuildSyncManifest(false)
    local blockKey = dataA:BuildSyncBlockKey(ownerKey, "Alchemy")

    Test.eq(manifestA.blocks[blockKey].count, 2, "active manifest should derive recipe count from recipe keys")
    Test.eq(manifestB.blocks[blockKey].count, 2, "stale cached counts should not leak into manifest rows")
    Test.eq(manifestA.blocks[blockKey].fingerprint, manifestB.blocks[blockKey].fingerprint, "block fingerprint should ignore revision and volatile metadata")

    local fingerprintA = dataA:BuildManifestContentFingerprint(manifestA)
    local fingerprintB = dataB:BuildManifestContentFingerprint(manifestB)

    Test.eq(fingerprintA, fingerprintB, "global fingerprint should depend only on active recipe content")
    Test.truthy(fingerprintA:match("^mf2:1:2:%d+$") ~= nil, "global fingerprint should use the mf2 content-only format")
end)

Test.it("excludes stale owners from the active HELLO fingerprint", function()
    local _addonA, _wowA, dataA = freshAddon()
    local _addonB, _wowB, dataB = freshAddon()
    local activeOwner = "Activeone-TestRealm"
    local staleOwner = "Staleone-TestRealm"

    seedProfession(dataA, activeOwner, "Alchemy", { 92001, 92002 }, { sourceType = "owner", rev = 5 })
    seedProfession(dataA, staleOwner, "Tailoring", { 93001 }, {
        sourceType = "replica",
        rev = 9,
        guildStatus = "stale",
        lastSeenInGuildAt = 50,
    })
    seedProfession(dataB, activeOwner, "Alchemy", { 92001, 92002 }, { sourceType = "owner", rev = 1 })

    local manifestA = dataA:BuildSyncManifest(false)
    local manifestB = dataB:BuildSyncManifest(false)

    Test.falsy(manifestA.blocks[dataA:BuildSyncBlockKey(staleOwner, "Tailoring")], "stale owners should not appear in the active manifest")
    Test.eq(buildActiveManifestFingerprint(dataA), buildActiveManifestFingerprint(dataB), "stale-only differences should not perturb the active HELLO fingerprint")
end)

Test.it("changes block and global fingerprints when recipe or owner-profession content changes", function()
    local _addonA, _wowA, dataA = freshAddon()
    local _addonB, _wowB, dataB = freshAddon()
    local ownerKey = "Ownertwo-TestRealm"

    seedProfession(dataA, ownerKey, "Alchemy", { 94001, 94002 }, { sourceType = "owner" })
    seedProfession(dataB, ownerKey, "Alchemy", { 94001 }, { sourceType = "owner" })
    seedProfession(dataB, ownerKey, "Blacksmithing", { 95001 }, { sourceType = "owner" })

    local manifestA = dataA:BuildSyncManifest(false)
    local manifestB = dataB:BuildSyncManifest(false)
    local alchemyKey = dataA:BuildSyncBlockKey(ownerKey, "Alchemy")

    Test.truthy(manifestA.blocks[alchemyKey].fingerprint ~= manifestB.blocks[alchemyKey].fingerprint, "missing a recipe should change the block content fingerprint")
    Test.truthy(dataA:BuildManifestContentFingerprint(manifestA) ~= dataB:BuildManifestContentFingerprint(manifestB), "owner-profession content differences should change the global fingerprint")
end)

io.write(string.format("Manifest content fingerprint: %d test(s) passed\n", Test.count))