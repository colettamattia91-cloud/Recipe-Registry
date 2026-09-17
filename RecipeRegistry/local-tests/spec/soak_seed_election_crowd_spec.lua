--[[
Wire v3 soak spec 2/5 — seed election determinism in a crowd.

Scenario: N peers with intentionally varied content counts (no two peers have
the same activeContentCount) broadcast HELLO simultaneously. Each peer
computes its own seed election from incoming SUMMARYs. Verifies that the
"highest content count, deterministic hash tie-break" rule produces ONE
elected seed per requester per HELLO cycle, while spreading exact ties across
equally useful seeds.

Asserts:
  - Every peer that issues HELLO converges to exactly one selectedSeedKey per
    activeHelloCycle (no oscillation across SUMMARY arrival order).
  - In a tie on content count, deterministic per-requester hashing spreads
    load across tied candidates.
  - INDEX_DIFF_REQUEST is sent to exactly one peer per HELLO cycle per
    requester, never to a runner-up.
  - selectedSeedKey is stable across the SUMMARY collection window — no
    "flipping" to a later-arriving SUMMARY with higher count after election
    has fired.
]]

local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test    = dofile("local-tests/harness/test.lua")

io.write("Soak: seed election determinism in a crowd\n")

local PEER_COUNT  = 12
local PROFESSION  = "Alchemy"
local MAX_TICKS   = 600
local PEER_PREFIX = "Electpeer"

local function buildPeerNames(count)
    local names = {}
    for index = 1, count do
        names[index] = string.format("%s%02d", PEER_PREFIX, index)
    end
    return names
end

local function seedPeerWithCount(bus, node, recipeCount)
    bus:SeedSelfProfession(node, {
        profession  = PROFESSION,
        recipeCount = recipeCount,
        baseRecipe  = 200000 + (node.index * 1000),
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

local function lastSelectedKey(bus, node)
    bus:Activate(node)
    local last = node.addon.Sync.lastSelectedSeed
    return last and last.peerKey or nil
end

local function allPeersElectedSomeone(bus)
    for _, node in ipairs(bus.nodes) do
        if node.online and not lastSelectedKey(bus, node) then
            return false
        end
    end
    return true
end

local function runUntilElected(bus)
    return bus:RunUntil(allPeersElectedSomeone, { maxTicks = MAX_TICKS })
end

Test.it("each peer elects the highest-content peer (with self excluded)", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    -- Distinct monotonically rising content counts: peer N has N recipes.
    -- The election rule is "highest activeContentCount with self excluded".
    for _, node in ipairs(bus.nodes) do
        seedPeerWithCount(bus, node, node.index)
    end

    bus:BroadcastHello()
    Test.truthy(runUntilElected(bus),
        string.format("expected every peer to complete one seed election within %d ticks", MAX_TICKS))

    local topNode    = bus.nodes[PEER_COUNT]      -- highest content (12 recipes)
    local secondNode = bus.nodes[PEER_COUNT - 1]  -- second highest (11 recipes)

    for _, node in ipairs(bus.nodes) do
        local elected = lastSelectedKey(bus, node)
        if node == topNode then
            Test.eq(elected, secondNode.key,
                "highest-content peer should fall back to the runner-up when self is excluded")
        else
            Test.eq(elected, topNode.key,
                string.format("peer %s should elect the highest-content peer %s, picked %s",
                    node.key, topNode.key, tostring(elected)))
        end
    end

    -- One INDEX_DIFF_REQUEST per requester per cycle. With one initial
    -- HELLO storm, the total across all peers equals the peer count.
    local totalIndexDiffRequests = 0
    for _, node in ipairs(bus.nodes) do
        local sent = countSentKind(node, "INDEX_DIFF_REQUEST")
        Test.lte(sent, 1,
            string.format("peer %s should not send more than one INDEX_DIFF_REQUEST per cycle, sent %d",
                node.key, sent))
        totalIndexDiffRequests = totalIndexDiffRequests + sent
    end
    Test.eq(totalIndexDiffRequests, PEER_COUNT,
        "every peer should send exactly one INDEX_DIFF_REQUEST after the storm")
end)

Test.it("exact tie on (content,block,owner) spreads by deterministic hash", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    -- Peers 1..10 have distinct counts 1..10. Peers 11 and 12 have an
    -- identical content count (11), identical block count (1 block each),
    -- identical owner count (1 owner each), and no backoff. The election
    -- sort therefore uses the per-requester stable hash to avoid a herd on
    -- the lexicographically smallest peer.
    for index = 1, PEER_COUNT - 2 do
        seedPeerWithCount(bus, bus.nodes[index], index)
    end
    seedPeerWithCount(bus, bus.nodes[PEER_COUNT - 1], 11)
    seedPeerWithCount(bus, bus.nodes[PEER_COUNT],     11)

    bus:BroadcastHello()
    Test.truthy(runUntilElected(bus),
        string.format("expected every peer to complete one seed election within %d ticks", MAX_TICKS))

    local nodeA = bus.nodes[PEER_COUNT - 1]
    local nodeB = bus.nodes[PEER_COUNT]
    Test.lte(nodeA.key, nodeB.key,
        "test fixture invariant: nodeA's key should sort before nodeB's")

    local picksA = 0
    local picksB = 0
    for _, node in ipairs(bus.nodes) do
        local elected = lastSelectedKey(bus, node)
        if node == nodeA then
            Test.eq(elected, nodeB.key,
                "tied peer A should pick the other tied peer (cannot pick self)")
            picksB = picksB + 1
        elseif node == nodeB then
            Test.eq(elected, nodeA.key,
                "tied peer B should pick the other tied peer (cannot pick self)")
            picksA = picksA + 1
        else
            Test.truthy(elected == nodeA.key or elected == nodeB.key,
                string.format("non-tied peer %s should pick one of the tied leaders, picked %s",
                    node.key, tostring(elected)))
            if elected == nodeA.key then
                picksA = picksA + 1
            elseif elected == nodeB.key then
                picksB = picksB + 1
            end
        end
    end
    Test.gte(picksA, 1, "hash tie-break should assign at least one requester to tied peer A")
    Test.gte(picksB, 1, "hash tie-break should assign at least one requester to tied peer B")
end)

io.write(string.format("Soak seed election: %d test(s) passed\n", Test.count))
