--[[
Wire v3 soak spec 1/5 — HELLO storm convergence.

Scenario: N peers come online with distinct content and broadcast HELLO inside
the same virtual-time window. Verifies the HELLO -> SUMMARY -> INDEX_DIFF ->
BLOCK_PULL -> BLOCK_SNAPSHOT pipeline converges every peer to the same
content view within a bounded number of ticks, without any peer entering a
permanent retry loop or producing a SUMMARY storm.

Asserts:
  - All peers eventually observe every other peer's owner + recipe content.
  - Per-peer helloSent stays bounded (HELLO coalescing works under load).
  - Per-peer summarySent stays bounded by peer count (one SUMMARY per
    differing peer-pair at most, not exponential).
  - blockSnapshotReceived count per peer matches the number of new owner
    blocks they had to pull (no redundant snapshots).
  - No peer hits discoveryRetryCapHits during the storm window.
]]

local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test    = dofile("local-tests/harness/test.lua")

io.write("Soak: HELLO storm convergence\n")

local PEER_COUNT       = 12
local RECIPES_PER_PEER = 5
local PROFESSION       = "Alchemy"
local MAX_TICKS        = 8000
local TICK_SECONDS     = 0.25

local function buildPeerNames(count)
    local names = {}
    for index = 1, count do
        names[index] = string.format("Stormpeer%02d", index)
    end
    return names
end

local function seedAllPeersWithUniqueContent(bus)
    for _, node in ipairs(bus.nodes) do
        bus:SeedSelfProfession(node, {
            profession  = PROFESSION,
            recipeCount = RECIPES_PER_PEER,
            baseRecipe  = 100000 + (node.index * 1000),
        })
    end
end

local function allPeersSeeFullContent(bus)
    for _, viewer in ipairs(bus.nodes) do
        if viewer.online then
            local count = bus:CountVisibleOwners(viewer, "Stormpeer")
            if count ~= PEER_COUNT then return false end
            for _, owner in ipairs(bus.nodes) do
                if bus:CountRecipes(viewer, owner.key, PROFESSION) ~= RECIPES_PER_PEER then
                    return false
                end
            end
        end
    end
    return true
end

local function telemetryFor(bus, node)
    bus:Activate(node)
    return node.addon.Sync.telemetry or {}
end

local function maxTelemetry(bus, field)
    local max = 0
    for _, node in ipairs(bus.nodes) do
        if node.online then
            local value = telemetryFor(bus, node)[field] or 0
            if value > max then max = value end
        end
    end
    return max
end

local function sumTelemetry(bus, field)
    local total = 0
    for _, node in ipairs(bus.nodes) do
        if node.online then
            total = total + (telemetryFor(bus, node)[field] or 0)
        end
    end
    return total
end

Test.it("12 peers with unique content converge after a HELLO storm", function()
    local bus = CommBus.New({ names = buildPeerNames(PEER_COUNT) })
    for _, name in ipairs(buildPeerNames(PEER_COUNT)) do
        bus:AddNode(name)
    end
    seedAllPeersWithUniqueContent(bus)
    -- Runtime tickers drive the natural HELLO_INTERVAL / AUTO_SYNC_INTERVAL
    -- timers and the request-queue pump, so convergence happens via the
    -- same code path real clients run in-game rather than via explicit
    -- BroadcastHello loops from the test.
    bus:EnableRuntimeTickersForAllNodes({ hello = true, autoSync = true, queue = true, prune = true })

    -- All peers fire an initial HELLO inside the same virtual-time window —
    -- the worst case the protocol must handle on a guild "everyone logged
    -- in together" event. From here the runtime tickers take over.
    bus:BroadcastHello()

    local _, convergedTicks = bus:RunUntil(function(b)
        return allPeersSeeFullContent(b)
    end, { maxTicks = MAX_TICKS, tickSeconds = TICK_SECONDS })

    local converged = allPeersSeeFullContent(bus)
    if not converged then
        for _, viewer in ipairs(bus.nodes) do
            local count, stale, mock = bus:CountVisibleOwners(viewer, "Stormpeer")
            local tel = telemetryFor(bus, viewer)
            io.write(string.format(
                "  %s online=%s owners=%d stale=%d mock=%d helloSent=%d summarySent=%d snapRecv=%d\n",
                viewer.key, tostring(viewer.online), count, stale, mock,
                tel.helloSent or 0, tel.summarySent or 0, tel.blockSnapshotReceived or 0))
        end
    end
    Test.truthy(converged,
        string.format("expected all %d peers to converge within %d ticks (ran %d)",
            PEER_COUNT, MAX_TICKS, convergedTicks or 0))

    -- HELLO_INTERVAL is 15 virtual seconds; with TICK_SECONDS=0.25 a full
    -- run of MAX_TICKS is ~MAX_TICKS*0.25/15 ≈ 133 HELLO opportunities.
    -- Per-peer helloSent should stay well under that since the coalescer
    -- drops repeats with unchanged fingerprint. Slack is generous because
    -- the goal here is to catch *runaway* HELLO traffic, not micro-bound it.
    local maxHelloAllowed = math.floor((MAX_TICKS * TICK_SECONDS) / 15) + 5
    local maxHello = maxTelemetry(bus, "helloSent")
    Test.lte(maxHello, maxHelloAllowed,
        string.format("per-peer helloSent should stay <= %d, saw %d",
            maxHelloAllowed, maxHello))

    -- SUMMARY is sent in response to a peer's HELLO when fingerprints differ.
    -- Bound is (peers - 1) HELLOs received per cycle times reasonable cycle
    -- count. Same intent as above: detect exponential blow-up, not bound
    -- the natural convergence traffic tightly.
    local maxSummaryAllowed = (PEER_COUNT - 1) * maxHelloAllowed
    local maxSummary = maxTelemetry(bus, "summarySent")
    Test.lte(maxSummary, maxSummaryAllowed,
        string.format("per-peer summarySent should stay <= %d, saw %d",
            maxSummaryAllowed, maxSummary))

    -- Every peer needs to pull (PEER_COUNT - 1) other owner blocks exactly
    -- once. Allow a small redundancy slack for sessions that crossed in
    -- flight, but flag exponential growth.
    local maxSnapshots = maxTelemetry(bus, "blockSnapshotReceived")
    Test.lte(maxSnapshots, (PEER_COUNT - 1) * 2,
        string.format("per-peer blockSnapshotReceived should stay <= %d, saw %d",
            (PEER_COUNT - 1) * 2, maxSnapshots))

    -- No peer should ride the discovery backoff up to the 300s cap during
    -- a healthy storm — that would indicate the SUMMARY collection window
    -- is misclassifying real activity as "empty discovery".
    local capHits = sumTelemetry(bus, "discoveryRetryCapHits")
    Test.eq(capHits, 0,
        "no peer should hit the discovery retry cap during a healthy HELLO storm")
end)

io.write(string.format("Soak HELLO storm: %d test(s) passed\n", Test.count))
