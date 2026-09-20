--[[
Wire v3 soak spec 5/5 — memory and table-size bounds under sustained load.

Scenario: drive a convergent multi-peer sync and verify that addon internal
tables stay bounded — no slow leaks, no unbounded growth in ring buffers,
no orphan session state.

The LRU caches for catalog views (_recipeListCache, _recipeDetailCache) are
already exercised by catalog_cache_spec.lua. This spec covers the sync-side
structures that don't show up there:
  - recentSyncEvents ring buffer (cap = RECENT_SYNC_EVENTS_LIMIT = 50)
  - outboundSeedSession terminal-state cleanup on every requester
  - inboundSeedSessions table empty on every seed after pulls finish
  - peerBackoffUntil cleared on success (no stale entries for healthy peers)
]]

local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test    = dofile("local-tests/harness/test.lua")

io.write("Soak: memory and table-size bounds under load\n")

local PEER_COUNT       = 8
local RECIPES_PER_PEER = 3
local PROFESSION       = "Alchemy"
local PEER_PREFIX      = "Memorypeer"
local MAX_TICKS        = 6000
local TICK_SECONDS     = 0.25
local EVENT_LOG_CAP    = 50

local function buildPeerNames(count)
    local names = {}
    for index = 1, count do
        names[index] = string.format("%s%02d", PEER_PREFIX, index)
    end
    return names
end

local function seedAllPeersWithUniqueContent(bus)
    for _, node in ipairs(bus.nodes) do
        bus:SeedSelfProfession(node, {
            profession  = PROFESSION,
            recipeCount = RECIPES_PER_PEER,
            baseRecipe  = 800000 + (node.index * 100),
        })
    end
end

local function allPeersHaveAllOwners(bus, expectedOwners)
    for _, viewer in ipairs(bus.nodes) do
        if viewer.online then
            local count = bus:CountVisibleOwners(viewer, PEER_PREFIX)
            if count ~= expectedOwners then
                return false
            end
        end
    end
    return true
end

local function inboundSessionCount(bus, node)
    bus:Activate(node)
    return node.addon.Sync:GetInboundSeedSessionCount() or 0
end

local function peerBackoffCount(bus, node)
    bus:Activate(node)
    local table_ = node.addon.Sync.peerBackoffUntil or {}
    local count = 0
    for _ in pairs(table_) do count = count + 1 end
    return count
end

Test.it("recentSyncEvents ring buffer respects the 50-entry cap", function()
    local bus = CommBus.New({ names = { "Logpeer" } })
    local node = bus:AddNode("Logpeer")
    bus:Activate(node)
    local sync = node.addon.Sync

    -- Reset and flood with well past the cap to prove ring trimming works.
    sync.recentSyncEvents = {}
    local floodCount = EVENT_LOG_CAP * 4
    for index = 1, floodCount do
        sync:RecordSyncEvent("soak-flood", { extra = "event-" .. index })
    end

    Test.eq(#sync.recentSyncEvents, EVENT_LOG_CAP,
        string.format("event log should hold exactly %d entries after a flood of %d",
            EVENT_LOG_CAP, floodCount))

    -- FIFO eviction: the surviving rows must be the newest, i.e. the last
    -- EVENT_LOG_CAP events recorded. Spot-check the head and tail.
    local head = sync.recentSyncEvents[1]
    local tail = sync.recentSyncEvents[#sync.recentSyncEvents]
    Test.eq(head.extra, "event-" .. (floodCount - EVENT_LOG_CAP + 1),
        "oldest surviving entry should be from the start of the retained window")
    Test.eq(tail.extra, "event-" .. floodCount,
        "newest entry should be the very last event written")

    -- GetRecentSyncEvents should respect a smaller requested limit and never
    -- exceed the underlying cap.
    local trimmed = sync:GetRecentSyncEvents(10)
    Test.eq(#trimmed, 10, "GetRecentSyncEvents should honor a smaller limit argument")
    local full = sync:GetRecentSyncEvents(1000)
    Test.eq(#full, EVENT_LOG_CAP,
        "GetRecentSyncEvents should never return more than the underlying cap")
end)

Test.it("outboundSeedSession is in a terminal state on every peer after convergence", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    seedAllPeersWithUniqueContent(bus)
    bus:EnableRuntimeTickersForAllNodes({ hello = true, autoSync = true, queue = true, prune = true })
    bus:BroadcastHello()

    local converged = bus:RunUntil(function(b)
        return allPeersHaveAllOwners(b, PEER_COUNT)
    end, { maxTicks = MAX_TICKS, tickSeconds = TICK_SECONDS })
    Test.truthy(converged,
        string.format("expected all %d peers to converge within %d ticks", PEER_COUNT, MAX_TICKS))

    -- Every peer that ever started a session must end it in a terminal
    -- state. The Sync runtime keeps the last session record assigned to
    -- self.outboundSeedSession; checking state covers both natural
    -- completion and abort paths.
    for _, node in ipairs(bus.nodes) do
        bus:Activate(node)
        local session = node.addon.Sync.outboundSeedSession
        if session then
            local state = tostring(session.state or "")
            local isTerminal = state == "completed" or state == "aborted"
            Test.truthy(isTerminal,
                string.format("peer %s's outboundSeedSession should be terminal, saw state=%s",
                    node.key, state))
        end
    end
end)

Test.it("inboundSeedSessions table empty on every peer after convergence", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    seedAllPeersWithUniqueContent(bus)
    bus:EnableRuntimeTickersForAllNodes({ hello = true, autoSync = true, queue = true, prune = true })
    bus:BroadcastHello()

    local converged = bus:RunUntil(function(b)
        return allPeersHaveAllOwners(b, PEER_COUNT)
    end, { maxTicks = MAX_TICKS, tickSeconds = TICK_SECONDS })
    Test.truthy(converged, "convergence required before checking session cleanup")

    -- With Fix B (cleanup on completion), every inbound session must be
    -- removed once its last offered block is served. No peer should
    -- carry residual session entries after the whole cohort has merged.
    for _, node in ipairs(bus.nodes) do
        local active = inboundSessionCount(bus, node)
        Test.eq(active, 0,
            string.format("peer %s should have 0 active inbound sessions, has %d",
                node.key, active))
    end
end)

Test.it("peerBackoffUntil holds no stale entries for peers that succeeded", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    seedAllPeersWithUniqueContent(bus)
    bus:EnableRuntimeTickersForAllNodes({ hello = true, autoSync = true, queue = true, prune = true })
    bus:BroadcastHello()

    local converged = bus:RunUntil(function(b)
        return allPeersHaveAllOwners(b, PEER_COUNT)
    end, { maxTicks = MAX_TICKS, tickSeconds = TICK_SECONDS })
    Test.truthy(converged, "convergence required before checking peer backoff cleanup")

    -- MarkPeerSuccess clears the backoff entry for the successful peer.
    -- After a healthy convergence, no peer should retain backoff entries
    -- for peers it successfully synced with. We allow a small bounded
    -- count to absorb in-flight failures that resolved later, but a full
    -- N-1 list would mean cleanup never fired.
    for _, node in ipairs(bus.nodes) do
        local backoffs = peerBackoffCount(bus, node)
        Test.lte(backoffs, math.max(1, math.floor(PEER_COUNT / 4)),
            string.format("peer %s should have at most %d residual backoffs, has %d",
                node.key, math.max(1, math.floor(PEER_COUNT / 4)), backoffs))
    end
end)

io.write(string.format("Soak memory bounds: %d test(s) passed\n", Test.count))
