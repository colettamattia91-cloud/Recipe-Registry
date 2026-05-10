local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function recipeSet(...)
    local set = {}
    for i = 1, select("#", ...) do
        set[select(i, ...)] = true
    end
    return set
end

local function recipeArray(...)
    local out = {}
    for i = 1, select("#", ...) do
        out[i] = select(i, ...)
    end
    return out
end

local function count(tbl)
    local total = 0
    for _ in pairs(tbl or {}) do total = total + 1 end
    return total
end

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedMember(data, memberKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.rev = opts.rev or 1
    entry.updatedAt = opts.updatedAt or time()
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.staleAt = opts.staleAt or 0
    entry.isMock = opts.isMock == true
    entry.professions = {}

    for profession, recipeKeys in pairs(opts.professions or {}) do
        entry.professions[profession] = {
            recipes = recipeKeys,
            skillRank = opts.skillRank or 300,
            skillMaxRank = opts.skillMaxRank or 375,
            sourceType = entry.sourceType,
            guildStatus = entry.guildStatus,
            lastSeenInGuildAt = entry.lastSeenInGuildAt,
            blockRevision = entry.rev,
            lastUpdatedAt = entry.updatedAt,
        }
    end

    data:NormalizeMemberEntry(entry, memberKey)
    return entry
end

io.write("P2 backend integrity\n")

Test.it("keeps pending scan work when the opened profession is not the pending profession", function()
    local _addon, wow, data = freshAddon()

    data:MarkScanNeeded("Alchemy", "recipe-event")
    wow.SetTradeSkill("Tailoring", {
        { name = "Bolt of Netherweave", itemID = 21840 },
        { name = "Netherweave Bag", itemID = 21841 },
    })

    local result = data:ScanTradeSkill()

    Test.eq(result.profession, "Tailoring", "wrong profession scan should still report what was scanned")
    Test.truthy(result.valid, "wrong profession scan should be a valid scan of that profession")
    Test.truthy(data:HasScanPending("Alchemy"), "Alchemy pending flag should remain")
    Test.noKey(data._scanNeededByProfession, "Tailoring", "Tailoring should not become pending")
    Test.truthy(data:HasAnyScanPending(), "legacy aggregate pending flag should remain true")
end)

Test.it("keeps generic recipe-event pending after an unchanged scan", function()
    local _addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()

    seedMember(data, localKey, {
        rev = 7,
        sourceType = "owner",
        professions = {
            Tailoring = recipeSet(21840, 21841),
        },
    })

    data:MarkScanNeeded(nil, "recipe-event")
    wow.SetTradeSkill("Tailoring", {
        { name = "Bolt of Netherweave", itemID = 21840 },
        { name = "Netherweave Bag", itemID = 21841 },
    })

    local result = data:ScanTradeSkill()

    Test.eq(result.profession, "Tailoring", "scan profession")
    Test.falsy(result.changed, "unchanged scan should not be treated as owner update")
    Test.truthy(data:HasAnyScanPending(), "generic pending should remain after an unchanged scan")
    Test.truthy(data._genericScanNeeded, "generic pending marker should remain")
    Test.truthy(data._genericScanAttempts.Tailoring, "unchanged profession should be recorded as attempted")
end)

Test.it("preserves existing profession blocks and recipes when an incoming snapshot is partial", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "RemoteCrafter-TestRealm"

    seedMember(data, memberKey, {
        rev = 1,
        updatedAt = 1000,
        sourceType = "replica",
        professions = {
            Alchemy = recipeSet(1001, 1002, 1003),
            Tailoring = recipeSet(2001, 2002),
        },
    })

    data:BeginIncomingSnapshot(memberKey, 2, 2000)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 2,
        updatedAt = 2000,
        sourceType = "replica",
        profession = "Alchemy",
        skillRank = 300,
        skillMaxRank = 375,
        recipeKeys = recipeArray(1001, 1002),
    })

    local applied = data:FinalizeIncomingSnapshot(memberKey, 2, { sourceType = "replica" })
    local entry = data:GetMember(memberKey)

    Test.truthy(applied, "newer partial snapshot should apply after protections are added")
    Test.eq(entry.rev, 2, "member revision should advance")
    Test.eq(entry.professions.Alchemy.count, 3, "subset Alchemy block should keep known recipes")
    Test.hasKey(entry.professions.Alchemy.recipes, 1003, "missing Alchemy recipe should be preserved")
    Test.eq(entry.professions.Tailoring.count, 2, "missing Tailoring block should be preserved")
    Test.hasKey(entry.professions.Tailoring.recipes, 2002, "Tailoring recipe should remain")
    Test.truthy(addon.Data:GetMember(memberKey), "member should remain visible in database")
end)

Test.it("builds snapshot chunks only for requested manifest blocks", function()
    local _addon, _wow, data = freshAddon()
    local memberKey = "RemoteCrafter-TestRealm"

    seedMember(data, memberKey, {
        rev = 2,
        sourceType = "replica",
        professions = {
            Alchemy = recipeSet(1101),
            Enchanting = recipeSet(),
        },
    })

    local chunks = data:BuildSnapshotChunks(memberKey, {
        requestedBlocks = {
            data:BuildSyncBlockKey(memberKey, "Alchemy"),
        },
    })

    Test.eq(#chunks, 1, "requested block snapshot should only include one profession")
    Test.eq(chunks[1].profession, "Alchemy", "requested block profession")
    Test.eq(#chunks[1].recipeKeys, 1, "requested block recipe count")

    local missingChunks = data:BuildSnapshotChunks(memberKey, {
        requestedBlocks = {
            data:BuildSyncBlockKey(memberKey, "Tailoring"),
        },
    })
    Test.eq(#missingChunks, 0, "unknown requested block should not send unrelated professions")
end)

Test.it("does not request a smaller replica manifest block over richer local data", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "RemoteCrafter-TestRealm"
    local blockKey = data:BuildSyncBlockKey(memberKey, "Enchanting")

    seedMember(data, memberKey, {
        rev = 3,
        sourceType = "replica",
        professions = {
            Enchanting = recipeSet(1201, 1202),
        },
    })

    local blocks = addon.TrickleSync:ComputeMissingBlocks({
        blocks = {
            [blockKey] = {
                blockKey = blockKey,
                ownerCharacter = memberKey,
                professionKey = "Enchanting",
                revision = 4,
                lastUpdatedAt = 4000,
                sourceType = "replica",
                guildStatus = "active",
                count = 0,
                fingerprint = "|spec:",
            },
        },
    })

    Test.eq(#blocks, 0, "smaller replica block should not be requested over richer local data")
end)

Test.it("supports local-only manifest comparison for catch-up without building peer-side diffs", function()
    local addon, _wow, data = freshAddon()
    local localOwner = data:GetPlayerKey()
    local remoteOwner = "RemoteCrafter-TestRealm"
    local localBlockKey = data:BuildSyncBlockKey(localOwner, "Alchemy")
    local remoteBlockKey = data:BuildSyncBlockKey(remoteOwner, "Enchanting")

    seedMember(data, localOwner, {
        rev = 2,
        sourceType = "owner",
        professions = {
            Alchemy = recipeSet(1401),
        },
    })

    local comparison = addon.TrickleSync:ComparePeerManifest({
        blocks = {
            [remoteBlockKey] = {
                blockKey = remoteBlockKey,
                ownerCharacter = remoteOwner,
                professionKey = "Enchanting",
                revision = 5,
                lastUpdatedAt = 5000,
                sourceType = "owner",
                guildStatus = "active",
                count = 1,
                fingerprint = "2401",
            },
        },
    }, {
        includeRemoteDiffs = false,
    })

    Test.eq(#comparison.missingHere, 1, "remote block should still be missing locally")
    Test.eq(comparison.missingHere[1], remoteBlockKey, "local-only compare should keep catch-up target")
    Test.eq(#comparison.missingThere, 0, "peer-side missing diff should be skipped")
    Test.eq(#comparison.outdatedThere, 0, "peer-side outdated diff should be skipped")
    Test.eq(comparison.localManifest.blocks[localBlockKey].ownerCharacter, localOwner, "local manifest should still be available to callers")
end)

Test.it("keeps full manifest diff behavior when peer-side diffs are requested", function()
    local addon, _wow, data = freshAddon()
    local localOwner = "ReplicaOwner-TestRealm"
    local blockKey = data:BuildSyncBlockKey(localOwner, "Alchemy")

    seedMember(data, localOwner, {
        rev = 4,
        sourceType = "replica",
        professions = {
            Alchemy = recipeSet(1501, 1502),
        },
    })

    local comparison = addon.TrickleSync:ComparePeerManifest({
        blocks = {
            [blockKey] = {
                blockKey = blockKey,
                ownerCharacter = localOwner,
                professionKey = "Alchemy",
                revision = 3,
                lastUpdatedAt = 3000,
                sourceType = "replica",
                guildStatus = "active",
                count = 1,
                fingerprint = "1501",
            },
        },
    })

    Test.eq(#comparison.missingThere, 0, "peer has the same block key, so it should not be missing there")
    Test.eq(#comparison.outdatedThere, 1, "full compare should still detect a peer-side stale replica")
    Test.eq(comparison.outdatedThere[1], blockKey, "peer-side stale block should be reported")
end)

Test.it("ignores malformed manifest owner keys before queueing block requests", function()
    local addon, _wow, data = freshAddon()
    local badOwner = "Beaudacio3:-13695:-13700:-13702:us-Thunderstrike"
    local badBlockKey = badOwner .. "::Enchanting"

    Test.falsy(data:IsValidMemberKey(badOwner), "colon-delimited owner should not be a valid member key")

    local blocks = addon.TrickleSync:ComputeMissingBlocks({
        blocks = {
            [badBlockKey] = {
                blockKey = badBlockKey,
                ownerCharacter = badOwner,
                professionKey = "Enchanting",
                revision = 8,
                lastUpdatedAt = 8000,
                sourceType = "replica",
                guildStatus = "active",
                count = 168,
                fingerprint = "-13695:-13700|spec:",
            },
        },
    })
    Test.eq(#blocks, 0, "malformed owner block should not be requested")

    local grouped = addon.TrickleSync:GroupBlockRequestsByOwner({
        blocks = {
            [badBlockKey] = {
                blockKey = badBlockKey,
                ownerCharacter = badOwner,
                professionKey = "Enchanting",
                revision = 8,
            },
        },
    }, { badBlockKey })
    Test.eq(Test.countKeys(grouped), 0, "malformed owner block should not be grouped")
end)

Test.it("drops malformed direct sync requests instead of retrying timeouts", function()
    local addon, _wow, _data = freshAddon()
    local badOwner = "Beaudacio3:-13695:-13700:-13702:us-Thunderstrike"

    addon.Sync:QueueRequest("Peerone-TestRealm", badOwner, 8, "test")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "malformed request should not be queued")

    addon.Sync.pendingRequests[badOwner] = {
        source = "Peerone-TestRealm",
        memberKey = badOwner,
        rev = 8,
        queuedAt = 1,
    }
    addon.Sync:ProcessRequestQueue()
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "pre-existing malformed pending request should be pruned")
    Test.falsy(addon.Sync.inFlight, "malformed request should not become in-flight")
end)

Test.it("filters malformed manifest chunks before storing peer manifests", function()
    local addon, _wow, _data = freshAddon()
    local senderKey = "Peerone-TestRealm"
    local badOwner = "Beaudacio3:-13695:-13700:-13702:us-Thunderstrike"
    local badBlockKey = badOwner .. "::Enchanting"

    addon.Sync:HandleManifestChunk({
        sender = senderKey,
        manifestId = "bad-manifest",
        builtAt = 9000,
        memberKey = senderKey,
        seq = 1,
        total = 1,
        totals = { blocks = 1, recipes = 168 },
        blocks = {
            {
                blockKey = badBlockKey,
                ownerCharacter = badOwner,
                professionKey = "Enchanting",
                revision = 9,
                sourceType = "replica",
                guildStatus = "active",
                count = 168,
            },
        },
    })

    local stored = addon.TrickleSync.peerState[senderKey] and addon.TrickleSync.peerState[senderKey].manifest
    Test.truthy(stored, "peer manifest should still complete")
    Test.eq(Test.countKeys(stored.blocks), 0, "malformed block should be dropped from stored manifest")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "malformed manifest should not queue requests")
end)

Test.it("cleans corrupt member keys, invalid recipes, and AtlasLoot profession mismatches", function()
    local addon, _wow, data = freshAddon()
    local previousAtlas = _G.AtlasLoot
    _G.AtlasLoot = {
        Data = {
            Recipe = {},
            Profession = {
                GetCraftSpellForCreatedItem = function(itemID)
                    return ({ [1111] = 5001, [2222] = 5002 })[itemID]
                end,
                GetProfessionData = function(spellID)
                    return ({
                        [5001] = { 1111, 3 },
                        [5002] = { 2222, 10 },
                    })[spellID]
                end,
                GetProfessionName = function(professionID)
                    return ({ [3] = "Cooking", [10] = "Enchanting" })[professionID]
                end,
            },
        },
    }

    local memberKey = "Auldyin-TestRealm"
    seedMember(data, memberKey, {
        rev = 7,
        sourceType = "replica",
        professions = {
            Cooking = recipeSet(1111, 2222, "bad-recipe-key", 2107276023613),
        },
    })
    local entry = data:GetMember(memberKey)
    entry.professions.Cooking.count = 99
    entry.professions.Cooking.signature = "stale"

    local corruptMemberKey = "Beaudacio3:-13695:-13700:us-Thunderstrike"
    data.db.global.members[corruptMemberKey] = {
        owner = corruptMemberKey,
        rev = 1,
        professions = {
            Cooking = { recipes = recipeSet(3333), count = 1 },
        },
    }
    addon.Sync.pendingRequests[corruptMemberKey] = {
        source = "Peerone-TestRealm",
        memberKey = corruptMemberKey,
        rev = 1,
        queuedAt = 1,
    }

    local dryRun = data:CleanCorruptData({ dryRun = true })
    Test.eq(dryRun.removedMembers, 1, "dry run corrupt member count")
    Test.eq(dryRun.removedRecipes, 3, "dry run corrupt recipe count")
    Test.eq(dryRun.mismatchedRecipes, 1, "dry run profession mismatch count")
    Test.truthy(data:GetMember(corruptMemberKey), "dry run should not remove corrupt member")
    Test.hasKey(entry.professions.Cooking.recipes, 2222, "dry run should not remove mismatched recipe")

    local stats = data:CleanCorruptData()
    local syncStats = addon.Sync:CleanCorruptState()
    entry = data:GetMember(memberKey)

    Test.eq(stats.removedMembers, 1, "corrupt member count")
    Test.eq(stats.removedRecipes, 3, "corrupt recipe count")
    Test.eq(stats.invalidRecipes, 2, "invalid recipe count")
    Test.eq(stats.mismatchedRecipes, 1, "profession mismatch count")
    Test.falsy(data:GetMember(corruptMemberKey), "corrupt member should be removed")
    Test.hasKey(entry.professions.Cooking.recipes, 1111, "valid Cooking recipe should remain")
    Test.noKey(entry.professions.Cooking.recipes, 2222, "Enchanting recipe should be removed from Cooking")
    Test.noKey(entry.professions.Cooking.recipes, "bad-recipe-key", "invalid recipe key should be removed")
    Test.noKey(entry.professions.Cooking.recipes, 2107276023613, "absurd item id should be removed")
    Test.eq(entry.professions.Cooking.count, 1, "recipe count should be repaired")
    Test.eq(syncStats.pendingRequests, 1, "corrupt pending request should be removed")

    _G.AtlasLoot = previousAtlas
end)

Test.it("runs safe corrupt data cleanup in background without profession mismatch checks", function()
    local addon, _wow, data = freshAddon()
    local memberKey = "AutoClean-TestRealm"
    local badOwner = "Broken:Owner-TestRealm"

    seedMember(data, memberKey, {
        rev = 2,
        sourceType = "replica",
        professions = {
            Cooking = recipeSet(21072, 2107276023613),
        },
    })
    local entry = data:GetMember(memberKey)
    entry.professions.Cooking.count = 2
    entry.professions.Cooking.signature = "stale"
    data.db.global.members[badOwner] = {
        owner = badOwner,
        professions = {},
    }
    addon.Sync.pendingRequests[badOwner] = {
        source = "Peerone-TestRealm",
        memberKey = badOwner,
        rev = 1,
        queuedAt = 1,
    }

    Test.truthy(data:ScheduleSafeAutoClean({ maxMembersPerStep = 1 }), "auto-clean should schedule")
    for _ = 1, 20 do
        addon.Performance:RunNextStep()
        if not addon.Performance:HasPendingJobs("maintenance") then break end
    end

    entry = data:GetMember(memberKey)
    Test.falsy(data:GetMember(badOwner), "auto-clean should remove malformed member")
    Test.hasKey(entry.professions.Cooking.recipes, 21072, "valid recipe should remain")
    Test.noKey(entry.professions.Cooking.recipes, 2107276023613, "impossible recipe should be removed")
    Test.eq(entry.professions.Cooking.count, 1, "auto-clean repaired recipe count")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "auto-clean should remove corrupt sync pending state")
    Test.truthy(data._safeAutoCleanCompleted, "auto-clean completion marker")
end)

Test.it("preserves local profession metadata while protecting from partial remote overwrite", function()
    local _addon, _wow, data = freshAddon()
    local memberKey = "RemoteCrafter-TestRealm"

    seedMember(data, memberKey, {
        rev = 5,
        updatedAt = 5000,
        sourceType = "replica",
        professions = {
            Engineering = recipeSet(1301, 1302),
        },
    })
    local entry = data:GetMember(memberKey)
    entry.professions.Engineering.specialization = "Gnomish Engineering"
    entry.professions.Engineering.blockRevision = 5
    entry.professions.Engineering.lastUpdatedAt = 5000
    entry.professions.Engineering.sourceType = "replica"

    data:BeginIncomingSnapshot(memberKey, 6, 6000)
    data:AppendIncomingChunk({
        memberKey = memberKey,
        rev = 6,
        updatedAt = 6000,
        sourceType = "replica",
        profession = "Engineering",
        skillRank = 375,
        skillMaxRank = 375,
        recipeKeys = {},
    })

    local applied = data:FinalizeIncomingSnapshot(memberKey, 6, { sourceType = "replica" })
    entry = data:GetMember(memberKey)

    Test.truthy(applied, "newer partial snapshot may apply after protection")
    Test.eq(entry.professions.Engineering.count, 2, "protected recipe count")
    Test.eq(entry.professions.Engineering.specialization, "Gnomish Engineering", "protected specialization metadata")
    Test.eq(entry.professions.Engineering.blockRevision, 5, "protected block revision metadata")
    Test.eq(entry.professions.Engineering.sourceType, "replica", "protected source metadata")
end)

Test.it("aborts roster cleanup when the roster snapshot is implausibly small", function()
    local addon, _wow, data = freshAddon()
    local memberKeys = {}

    for i = 1, 8 do
        local memberKey = string.format("Roster%02d-TestRealm", i)
        memberKeys[#memberKeys + 1] = memberKey
        seedMember(data, memberKey, {
            rev = 1,
            sourceType = "replica",
            professions = {
                Alchemy = recipeSet(3000 + i),
            },
        })
    end

    local snapshot = {
        ["Roster01-TestRealm"] = true,
        ["Roster02-TestRealm"] = true,
    }

    local started, reason = addon.GuildLifecycleMaintenance:StartCleanup({
        force = true,
        label = "test-roster-too-small",
        snapshot = snapshot,
        memberKeys = memberKeys,
        updateLastRunAt = false,
    })

    local info = addon.GuildLifecycleMaintenance:GetLastRunInfo()

    Test.falsy(started, "cleanup should not start")
    Test.eq(reason, "roster-too-small", "abort reason")
    Test.truthy(info and info.aborted, "last run should be marked aborted")
    Test.eq(info.snapshotCount, 2, "snapshot count should be recorded")
    Test.eq(info.knownActive, 8, "known active count should be recorded")
    Test.eq(info.markedStale, 0, "no member should be marked stale during abort")
    Test.falsy(addon.GuildLifecycleMaintenance:IsCleanupRunning(), "cleanup should not remain running")

    for _, memberKey in ipairs(memberKeys) do
        Test.eq(data:GetMember(memberKey).guildStatus, "active", memberKey .. " should remain active")
    end
end)

io.write(string.format("P2 backend integrity: %d test(s) passed\n", Test.count))
