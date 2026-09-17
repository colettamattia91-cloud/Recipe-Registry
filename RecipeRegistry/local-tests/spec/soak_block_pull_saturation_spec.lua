--[[
Wire v3 soak spec 3/5 — BLOCK_PULL queue saturation against a hot seed.

Scenario: One peer (the "hot seed") holds a large, content-rich block set.
Many requesters simultaneously elect this hot seed and start pulling.
Verifies the seed-side inbound session cap (MAX_INBOUND_SEED_SESSIONS = 4)
enforces back-pressure correctly, that overflow requesters don't permanently
stall, and that the protocol never serves a block outside an offered set or
a registered session.

Asserts:
  - At-cap saturation (4 requesters): every requester completes; no inbound
    session rejection; total blockSnapshotSent equals expected (4 *
    blocks-per-session).
  - Overshoot (8 requesters with cap=4): inboundSeedSessionsRejectedCap > 0
    on the seed (cap was actually exercised), overflow requesters receive a
    busy INDEX_DIFF_RESPONSE instead of an unregistered offer, every
    requester eventually has the full content (recovery via natural HELLO
    ticker), no "block-not-offered" rejections in any path.
]]

local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test    = dofile("local-tests/harness/test.lua")

io.write("Soak: BLOCK_PULL queue saturation against a hot seed\n")

local HOT_PROFESSIONS    = { "Alchemy", "Tailoring", "Enchanting" }
local HOT_RECIPES_PER    = 5
local REQUESTER_PROFESSION = "Alchemy"
local SEED_NAME          = "Hotseed"
local REQUESTER_PREFIX   = "Hotreq"
local AT_CAP_REQUESTERS  = 4   -- matches MAX_INBOUND_SEED_SESSIONS
local OVERSHOOT_REQUESTERS = 8 -- 2x the cap to provoke rejection

local function nameRoster(seedName, requesterCount)
    local names = { seedName }
    for index = 1, requesterCount do
        names[#names + 1] = string.format("%s%02d", REQUESTER_PREFIX, index)
    end
    return names
end

local function seedHotPeer(bus, seedNode)
    bus:Activate(seedNode)
    local data = seedNode.addon.Data
    local memberKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.updatedAt = 8000
    entry.lastSeenInGuildAt = entry.updatedAt
    for index, profession in ipairs(HOT_PROFESSIONS) do
        local recipes = {}
        for offset = 1, HOT_RECIPES_PER do
            recipes[400000 + (index * 1000) + offset] = true
        end
        entry.professions[profession] = {
            recipes        = recipes,
            count          = HOT_RECIPES_PER,
            skillRank      = 375,
            skillMaxRank   = 375,
            sourceType     = "owner",
            guildStatus    = "active",
            lastUpdatedAt  = entry.updatedAt,
            lastSeenInGuildAt = entry.updatedAt,
        }
    end
    data:NormalizeMemberEntry(entry, memberKey)
    if data.MarkSyncIndexDirty then data:MarkSyncIndexDirty("hot-seed-init") end
    if data.PrepareSyncIndexNow then data:PrepareSyncIndexNow("hot-seed-init") end
    if seedNode.addon.Sync.RefreshSyncReadyState then
        seedNode.addon.Sync:RefreshSyncReadyState("hot-seed-init")
    end
end

local function seedRequester(bus, node)
    bus:SeedSelfProfession(node, {
        profession  = REQUESTER_PROFESSION,
        recipeCount = 1,
        baseRecipe  = 700000 + (node.index * 100),
    })
end

local function countSentKind(node, kind)
    local total = 0
    for _, row in ipairs(node.state.sentComm or {}) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function telemetry(bus, node)
    bus:Activate(node)
    return node.addon.Sync.telemetry or {}
end

local function requesterHasFullSeedContent(bus, requester, seedKey)
    bus:Activate(requester)
    local entry = requester.addon.Data:GetMember(seedKey)
    if not entry then return false end
    for _, profession in ipairs(HOT_PROFESSIONS) do
        local prof = entry.professions and entry.professions[profession]
        if not prof or (prof.count or 0) ~= HOT_RECIPES_PER then
            return false
        end
    end
    return true
end

local function allRequestersConverged(bus, seedKey)
    for _, node in ipairs(bus.nodes) do
        if node.online and node.key ~= seedKey then
            if not requesterHasFullSeedContent(bus, node, seedKey) then
                return false
            end
        end
    end
    return true
end

Test.it("4 requesters at the inbound session cap all complete cleanly", function()
    local bus = CommBus.New({ names = nameRoster(SEED_NAME, AT_CAP_REQUESTERS) })
    local seed = bus:AddNode(SEED_NAME)
    local requesters = {}
    for index = 1, AT_CAP_REQUESTERS do
        requesters[index] = bus:AddNode(string.format("%s%02d", REQUESTER_PREFIX, index))
    end
    seedHotPeer(bus, seed)
    for _, requester in ipairs(requesters) do
        seedRequester(bus, requester)
    end

    -- Without runtime tickers: one HELLO storm. Each requester elects the
    -- hot seed (most content), opens a session within the cap, and pulls.
    bus:BroadcastHello()
    local converged = bus:RunUntil(function(b)
        return allRequestersConverged(b, seed.key)
    end, { maxTicks = 800 })

    Test.truthy(converged,
        string.format("expected all %d requesters to merge the hot seed's blocks at cap", AT_CAP_REQUESTERS))

    local seedTel = telemetry(bus, seed)
    Test.eq(seedTel.inboundSeedSessionsRejectedCap or 0, 0,
        "at the cap exactly, no session should be rejected")
    Test.eq(seedTel.inboundBlockPullRejectedUnknownRequest or 0, 0,
        "no BLOCK_PULL_REQUEST should arrive without a registered session")
    Test.eq(seedTel.inboundBlockPullRejectedNotOffered or 0, 0,
        "no BLOCK_PULL_REQUEST should ask for a block outside its offered set")

    -- Each requester pulls all HOT_PROFESSIONS blocks (3) from the seed.
    local expectedSnapshots = AT_CAP_REQUESTERS * #HOT_PROFESSIONS
    Test.eq(countSentKind(seed, "BLOCK_SNAPSHOT"), expectedSnapshots,
        string.format("seed should serve exactly %d snapshots (requesters * blocks)", expectedSnapshots))

    -- Fix B: every session must be marked completed on the seed side once
    -- its last offered block has been served — slots free instantly instead
    -- of waiting for the 60s inactivity prune.
    Test.eq(seedTel.inboundSeedSessionsCompleted or 0, AT_CAP_REQUESTERS,
        string.format("seed should complete exactly %d inbound sessions", AT_CAP_REQUESTERS))
    Test.eq(seedTel.inboundSeedSessionsActive or 0, 0,
        "all inbound session slots should be free after completion")
end)

Test.it("8 requesters overshoot the cap and recover via natural retries", function()
    local bus = CommBus.New({ names = nameRoster(SEED_NAME, OVERSHOOT_REQUESTERS) })
    local seed = bus:AddNode(SEED_NAME)
    local requesters = {}
    for index = 1, OVERSHOOT_REQUESTERS do
        requesters[index] = bus:AddNode(string.format("%s%02d", REQUESTER_PREFIX, index))
    end
    seedHotPeer(bus, seed)
    for _, requester in ipairs(requesters) do
        seedRequester(bus, requester)
    end

    -- Runtime tickers enable natural HELLO_INTERVAL re-firing so requesters
    -- whose initial session was capped get another chance on the next cycle.
    bus:EnableRuntimeTickersForAllNodes({ hello = true, autoSync = true, queue = true, prune = true })

    bus:BroadcastHello()
    local converged = bus:RunUntil(function(b)
        return allRequestersConverged(b, seed.key)
    end, { maxTicks = 10000, tickSeconds = 0.25 })

    if not converged then
        for _, requester in ipairs(requesters) do
            local entry = requester.addon.Data:GetMember(seed.key)
            local counts = {}
            for _, profession in ipairs(HOT_PROFESSIONS) do
                counts[#counts + 1] = string.format("%s=%d", profession,
                    (entry and entry.professions and entry.professions[profession]
                        and entry.professions[profession].count) or 0)
            end
            local tel = telemetry(bus, requester)
            io.write(string.format("  %s seedBlocks=%s helloSent=%d snapRecv=%d\n",
                requester.key, table.concat(counts, ","),
                tel.helloSent or 0, tel.blockSnapshotReceived or 0))
        end
        local seedTel = telemetry(bus, seed)
        io.write(string.format("  SEED rejectedCap=%d unknown=%d notOffered=%d snapSent=%d\n",
            seedTel.inboundSeedSessionsRejectedCap or 0,
            seedTel.inboundBlockPullRejectedUnknownRequest or 0,
            seedTel.inboundBlockPullRejectedNotOffered or 0,
            countSentKind(seed, "BLOCK_SNAPSHOT")))
    end
    Test.truthy(converged,
        string.format("expected all %d requesters to converge despite cap rejections", OVERSHOOT_REQUESTERS))

    local seedTel = telemetry(bus, seed)
    Test.gte(seedTel.inboundSeedSessionsRejectedCap or 0, 1,
        "the initial storm should produce at least one cap rejection before retries kick in")
    Test.gte(seedTel.indexDiffBusySent or 0, 1,
        "overflow requesters should receive a busy INDEX_DIFF_RESPONSE when the seed cap is full")
    Test.eq(seedTel.inboundBlockPullRejectedUnknownRequest or 0, 0,
        "busy responses should prevent BLOCK_PULL_REQUESTs without a registered session")
    Test.eq(seedTel.inboundBlockPullRejectedNotOffered or 0, 0,
        "no BLOCK_PULL_REQUEST should ever ask for a block outside its offered set")
    -- Fix B: the hot seed services exactly the first wave of cap-fitting
    -- requesters (AT_CAP_REQUESTERS = 4). The overshoot requesters then
    -- converge via the first wave's winners — once a winner has merged the
    -- seed's blocks, its activeContentCount surpasses the seed's, so
    -- retrying requesters elect a winner instead. The hot seed therefore
    -- only ever completes AT_CAP_REQUESTERS sessions, and additive merge
    -- propagation does the rest. This distributed-relay outcome is a
    -- desirable side effect of the protocol shape.
    Test.gte(seedTel.inboundSeedSessionsCompleted or 0, AT_CAP_REQUESTERS,
        string.format("hot seed should complete at least %d inbound sessions (its cap)", AT_CAP_REQUESTERS))
    local drained = bus:RunUntil(function()
        return seed.addon.Sync:GetInboundSeedSessionCount() == 0
    end, { maxTicks = 400, tickSeconds = 0.25 })
    Test.truthy(drained,
        "seed inbound sessions should drain after any extra relay blocks offered during retries are served")
    Test.eq(seedTel.inboundSeedSessionsActive or 0, 0,
        "no inbound session should remain occupied on the seed once all requesters have merged")
end)

io.write(string.format("Soak block pull saturation: %d test(s) passed\n", Test.count))
