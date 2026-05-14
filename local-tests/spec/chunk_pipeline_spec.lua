local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local PROFESSIONS = {
    "Alchemy",
    "Blacksmithing",
    "Cooking",
    "Enchanting",
    "Engineering",
    "Jewelcrafting",
    "Leatherworking",
    "Tailoring",
}

local function freshAddon(opts)
    local addon, wow = Loader.Load(opts)
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeCount, baseRecipe, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    local recipes = {}

    for offset = 1, recipeCount do
        recipes[baseRecipe + offset] = true
    end

    entry.owner = memberKey
    entry.rev = opts.rev or 100
    entry.updatedAt = opts.updatedAt or 1000
    entry.sourceType = opts.sourceType or "owner"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipes,
        count = recipeCount,
        signature = data:ComputeRecipeSignature(recipes),
        blockRevision = entry.rev,
        lastUpdatedAt = entry.updatedAt,
        sourceType = entry.sourceType,
        guildStatus = entry.guildStatus,
    })
    data:NormalizeMemberEntry(entry, memberKey)
    return entry
end

local function seedLargeOwner(data, memberKey, recipeCountPerProfession)
    for index, profession in ipairs(PROFESSIONS) do
        seedProfession(data, memberKey, profession, recipeCountPerProfession, 700000 + (index * 1000))
    end
end

local function countRecipes(data, memberKey, profession)
    local entry = data:GetMember(memberKey)
    local prof = entry and entry.professions and entry.professions[profession]
    local count = 0
    for _ in pairs(prof and prof.recipes or {}) do
        count = count + 1
    end
    return count
end

io.write("Chunk pipeline\n")

Test.it("queues snapshot chunks in bounded windows per session", function()
    local addon, wow, data = freshAddon()
    local selfKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"
    local window = addon.Sync._private.constants.SNAPSHOT_SESSION_WINDOW or 8

    seedLargeOwner(data, selfKey, 500)

    wow.DeliverComm(addon.Sync, {
        kind = "REQ",
        key = selfKey,
        knownRev = 0,
        wantRev = 100,
        requestId = "req-window",
        sender = peerKey,
        addonVersion = addon.ADDON_VERSION,
        wireVersion = addon.WIRE_VERSION,
        buildChannel = addon.BUILD_CHANNEL,
        caps = addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil,
    }, {
        sender = peerKey,
        distribution = "WHISPER",
    })

    local sessionId
    local session
    for candidateSessionId, candidate in pairs(addon.Sync.outgoingSessions or {}) do
        sessionId = candidateSessionId
        session = candidate
        break
    end

    Test.truthy(sessionId, "request should create an outgoing session")
    Test.truthy((session.total or 0) > window, "fixture should span more than one send window")
    Test.lte(#(addon.Sync.outboundChunkQueue or {}), window, "initial queued snapshot window should stay bounded")

    for _ = 1, 12 do
        wow.AdvanceTime(1)
        addon.Sync:SendNextSnapshotChunk()
        Test.lte(#(addon.Sync.outboundChunkQueue or {}), window, "queued snapshot window should remain bounded while draining")
    end
end)

Test.it("late chunk after completion is ignored instead of reopening partial state", function()
    local addon, wow, data = freshAddon()
    local ownerKey = "Ownerone-TestRealm"
    local sessionId = "session-late"

    addon.Sync:HandleSnapshotChunk({
        sessionId = sessionId,
        key = ownerKey,
        rev = 22,
        updatedAt = 2200,
        sender = ownerKey,
        profession = "Alchemy",
        recipeKeys = { 810001 },
        seq = 1,
        total = 2,
    })
    addon.Sync:HandleSnapshotChunk({
        sessionId = sessionId,
        key = ownerKey,
        rev = 22,
        updatedAt = 2200,
        sender = ownerKey,
        profession = "Alchemy",
        recipeKeys = { 810002 },
        seq = 2,
        total = 2,
    })

    for _ = 1, 4 do
        addon.Sync:ProcessInboundQueue()
    end

    local receivedBeforeLate = addon.Sync.telemetry.receivedChunks or 0
    Test.eq(addon.Sync.partialReceive[ownerKey], nil, "completed snapshot should clear partial state")
    Test.eq(countRecipes(data, ownerKey, "Alchemy"), 2, "completed snapshot should merge all recipes")

    addon.Sync:HandleSnapshotChunk({
        sessionId = sessionId,
        key = ownerKey,
        rev = 22,
        updatedAt = 2200,
        sender = ownerKey,
        profession = "Alchemy",
        recipeKeys = { 810001 },
        seq = 1,
        total = 2,
    })

    Test.eq(addon.Sync.partialReceive[ownerKey], nil, "late chunk should not reopen a completed partial state")
    Test.eq(#(addon.Sync.inboundChunkQueue or {}), 0, "late chunk should not be enqueued for decode")
    Test.eq(addon.Sync.telemetry.receivedChunks or 0, receivedBeforeLate, "late chunk should not count as new inbound work")
    Test.eq(countRecipes(data, ownerKey, "Alchemy"), 2, "late chunk should not change merged recipes")
    Test.truthy(#(wow.GetSentComm() or {}) >= 1, "completion should still emit DONE once")
end)

Test.it("resume requests queue only the explicitly missing seqs", function()
    local addon, _wow, data = freshAddon()
    local selfKey = data:GetPlayerKey()
    local peerKey = "Peerone-TestRealm"

    local entry = seedProfession(data, selfKey, "Alchemy", 500, 820000, {
        rev = 55,
        updatedAt = 5500,
    })
    local chunks = data:BuildSnapshotChunks(selfKey)
    local sessionId = "session-resume"

    addon.Sync.outgoingSessions[sessionId] = {
        sessionId = sessionId,
        memberKey = selfKey,
        targetKey = peerKey,
        rev = entry.rev,
        updatedAt = entry.updatedAt,
        total = #chunks,
        chunks = chunks,
        createdAt = time(),
        lastSentAt = 0,
        nextSeqToQueue = (#chunks + 1),
    }
    addon.Sync.outboundChunkQueue = {}

    addon.Sync:HandleResumeRequest({
        sessionId = sessionId,
        sender = peerKey,
        key = selfKey,
        rev = entry.rev,
        missing = { 2, 4 },
    })

    Test.eq(#(addon.Sync.outboundChunkQueue or {}), 2, "resume should queue only the requested seqs")
    Test.eq(addon.Sync.outboundChunkQueue[1].block.seq, 2, "first resumed seq")
    Test.eq(addon.Sync.outboundChunkQueue[2].block.seq, 4, "second resumed seq")
end)

io.write(string.format("Chunk pipeline: %d test(s) passed\n", Test.count))
