local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function countGuildCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if row.distribution == "GUILD" and type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function findSentCommKind(wow, kind)
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and row.message.kind == kind then
            return row
        end
    end
    return nil
end

io.write("Specialization sync\n")

Test.it("discovers a local specialization once without bumping revision on every detect", function()
    local _addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 375, skillMaxRank = 375 },
    })
    wow.SetKnownSpells({ 28675 })

    local changed = data:DetectProfessions()
    local entry = data:GetMember(data:GetPlayerKey())

    Test.truthy(changed, "first specialization discovery should count as metadata change")
    Test.eq(entry.rev, 1, "first specialization discovery should bump local rev")
    Test.eq(entry.professions.Alchemy.specialization, "Potion Master", "Alchemy specialization should be stored")
    Test.eq(entry.professions.Alchemy.blockRevision, 1, "specialization change should advance profession block revision")

    local changedAgain = data:DetectProfessions()
    entry = data:GetMember(data:GetPlayerKey())

    Test.falsy(changedAgain, "re-detecting the same specialization should be stable")
    Test.eq(entry.rev, 1, "same specialization should not bump local rev again")
    Test.eq(entry.professions.Alchemy.specialization, "Potion Master", "specialization should stay stored")
end)

Test.it("advertises a specialization-only change once when recipes are otherwise unchanged", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)

    entry.rev = 3
    entry.updatedAt = 100
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 350,
        skillMaxRank = 375,
        specialization = nil,
        blockRevision = 3,
        lastUpdatedAt = 100,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = 100,
    })

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 350, skillMaxRank = 375 },
    })
    wow.SetKnownSpells({ 28675 })

    addon:ProcessRecipeSignal()

    entry = data:GetMember(localKey)
    Test.eq(entry.rev, 4, "specialization-only detect should bump local rev once")
    Test.eq(entry.professions.Alchemy.specialization, "Potion Master", "specialization should be stored after signal")
    Test.truthy(data:HasAnyScanPending(), "recipe signal should still keep pending scan when no profession API is active")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "specialization-only change should advertise once")

    addon:ProcessRecipeSignal()

    entry = data:GetMember(localKey)
    Test.eq(entry.rev, 4, "same specialization should not keep bumping rev")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "same specialization should not keep advertising")
end)

Test.it("hydrates remote specialization onto an existing equal-revision replica without requiring a wipe", function()
    local _addon, _wow, data = freshAddon()
    local memberKey = "RemoteSpec-TestRealm"
    local entry = data:GetOrCreateMember(memberKey)

    entry.owner = memberKey
    entry.rev = 5
    entry.updatedAt = 500
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = 500
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = nil,
        blockRevision = 5,
        lastUpdatedAt = 500,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 500,
    })

    data:BeginIncomingSnapshot(memberKey, 5, 500)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 5,
        updatedAt = 500,
        sourceType = "replica",
        profession = "Alchemy",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = "Potion Master",
        recipeKeys = { 95001 },
    })

    local applied = data:FinalizeIncomingSnapshot(memberKey, 5, { sourceType = "replica" })
    entry = data:GetMember(memberKey)

    Test.truthy(applied, "incoming specialization metadata should upgrade an equal revision replica")
    Test.eq(entry.rev, 5, "metadata upgrade should not manufacture a higher remote revision")
    Test.eq(entry.professions.Alchemy.specialization, "Potion Master", "remote specialization should be stored without a local wipe")
end)

Test.it("requests a remote block again when only specialization changed in the manifest fingerprint", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "RemoteSpec-TestRealm"
    local blockKey = data:BuildSyncBlockKey(memberKey, "Alchemy")
    local entry = data:GetOrCreateMember(memberKey)

    entry.owner = memberKey
    entry.rev = 5
    entry.updatedAt = 500
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = 500
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = "Potion Master",
        blockRevision = 5,
        lastUpdatedAt = 500,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 500,
    })

    local senderManifest = data:BuildSyncManifest(false)
    local senderBlock = senderManifest.blocks[blockKey]

    entry.professions.Alchemy.specialization = nil
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", entry.professions.Alchemy)
    data:ResetManifestTelemetry()
    data:MarkManifestDirty(blockKey, "test-specialization-fingerprint")

    local blocks = addon.TrickleSync:ComputeMissingBlocks({
        blocks = {
            [blockKey] = senderBlock,
        },
    })

    Test.eq(#blocks, 1, "peer manifest should mark the block as outdated here")
    Test.eq(blocks[1], blockKey, "the specialization-only block should be requested again")
end)

Test.it("requests an owner block with richer specialization even when the local replica revision is higher", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "RemoteSpec-TestRealm"
    local blockKey = data:BuildSyncBlockKey(memberKey, "Blacksmithing")
    local entry = data:GetOrCreateMember(memberKey)

    entry.owner = memberKey
    entry.rev = 3
    entry.updatedAt = 700
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = 700
    entry.professions.Blacksmithing = data:NormalizeProfessionBlock(entry, "Blacksmithing", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = nil,
        blockRevision = 3,
        lastUpdatedAt = 700,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 700,
    })

    local blocks = addon.TrickleSync:ComputeMissingBlocks({
        blocks = {
            [blockKey] = {
                blockKey = blockKey,
                ownerCharacter = memberKey,
                professionKey = "Blacksmithing",
                revision = 2,
                lastUpdatedAt = 600,
                sourceType = "owner",
                guildStatus = "active",
                lastSeenInGuildAt = 600,
                count = 1,
                fingerprint = "95001|spec:Armorsmith",
            },
        },
    })

    Test.eq(#blocks, 1, "owner block with richer specialization should still be requested")
    Test.eq(blocks[1], blockKey, "the owner block should win over a higher-revision replica cache")
end)

Test.it("applies a lower-revision owner snapshot over a higher-revision replica when it carries specialization", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "RemoteSpec-TestRealm"
    local entry = data:GetOrCreateMember(memberKey)

    entry.owner = memberKey
    entry.rev = 3
    entry.updatedAt = 700
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = 700
    entry.professions.Blacksmithing = data:NormalizeProfessionBlock(entry, "Blacksmithing", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = nil,
        blockRevision = 3,
        lastUpdatedAt = 700,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 700,
    })

    data:BeginIncomingSnapshot(memberKey, 2, 600)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 2,
        updatedAt = 600,
        sourceType = "owner",
        profession = "Blacksmithing",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = "Armorsmith",
        recipeKeys = { 95001 },
    })

    local applied = addon.Sync:MergeChunkStep({
        memberKey = memberKey,
        rev = 2,
        sender = memberKey,
    })
    entry = data:GetMember(memberKey)

    Test.truthy(applied, "actual owner snapshot should apply over a higher-revision replica cache")
    Test.eq(entry.rev, 2, "stored remote owner revision should match the owner snapshot")
    Test.eq(entry.sourceType, "owner", "stored authority should reflect the owner snapshot")
    Test.eq(entry.professions.Blacksmithing.specialization, "Armorsmith", "owner specialization should repair the stale replica")
end)

Test.it("repairs a missing remote specialization after forcing a manifest refresh on first hello", function()
    local addon, wow, data = freshAddon()
    local memberKey = "RemoteSpec-TestRealm"
    local blockKey = data:BuildSyncBlockKey(memberKey, "Alchemy")
    local entry = data:GetOrCreateMember(memberKey)

    entry.owner = memberKey
    entry.rev = 5
    entry.updatedAt = 500
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = 500
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = {
            [95001] = true,
        },
        count = 1,
        signature = "95001",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = nil,
        blockRevision = 5,
        lastUpdatedAt = 500,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = 500,
    })

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = memberKey,
        rev = 5,
        updatedAt = 500,
        sender = memberKey,
        version = "1.8.1",
    }, {
        sender = memberKey,
        distribution = "GUILD",
    })

    local manifestRefresh = findSentCommKind(wow, "MREQ")
    Test.truthy(manifestRefresh, "first hello should trigger a targeted manifest refresh request")

    wow.DeliverComm(addon.Sync, {
        kind = "MANI",
        manifestId = "spec-refresh",
        builtAt = 510,
        memberKey = memberKey,
        sender = memberKey,
        totals = {
            blocks = 1,
            recipes = 1,
        },
        seq = 1,
        total = 1,
        blocks = {
            {
                blockKey = blockKey,
                ownerCharacter = memberKey,
                professionKey = "Alchemy",
                revision = 5,
                lastUpdatedAt = 500,
                sourceType = "owner",
                guildStatus = "active",
                lastSeenInGuildAt = 500,
                count = 1,
                fingerprint = "95001|spec:Potion Master",
            },
        },
    }, {
        sender = memberKey,
        distribution = "WHISPER",
    })

    addon.Sync:ProcessRequestQueue()
    local request = findSentCommKind(wow, "REQ")
    Test.truthy(request, "manifest refresh should lead to a direct block request")
    Test.eq(request.message.requestedBlocks[1], blockKey, "the specialization block should be requested")

    wow.DeliverComm(addon.Sync, {
        kind = "SNAP",
        sessionId = "spec-refresh-session",
        key = memberKey,
        sender = memberKey,
        rev = 5,
        updatedAt = 500,
        sourceType = "owner",
        profession = "Alchemy",
        skillRank = 375,
        skillMaxRank = 375,
        specialization = "Potion Master",
        recipeKeys = { 95001 },
        seq = 1,
        total = 1,
    }, {
        sender = memberKey,
        distribution = "WHISPER",
    })

    addon.Sync:ProcessInboundQueue()
    addon.Sync:ProcessInboundQueue()

    entry = data:GetMember(memberKey)
    Test.eq(entry.professions.Alchemy.specialization, "Potion Master", "forced manifest refresh should repair the missing specialization")
end)

io.write(string.format("Specialization sync: %d test(s) passed\n", Test.count))
