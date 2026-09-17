--[[
Wire v3 soak spec 4/5 — discovery retry backoff under roster churn.

Scenario: A peer cycles through empty SUMMARY windows (no useful seed
discovered) and observes the backoff schedule rise from
DISCOVERY_RETRY_INITIAL_SECONDS (20) by DISCOVERY_RETRY_STEP_SECONDS (20)
per miss, capped at DISCOVERY_RETRY_MAX_SECONDS (300). A reset arrives in
the form of a useful SUMMARY (different globalFingerprint) and the
backoff returns to the initial delay.

Asserts:
  - discoveryRetryDelay rises monotonically up to 300s for peers that get
    empty SUMMARY windows.
  - discoveryRetryReset increments after a successful SUMMARY round (peer
    saw at least one differing SUMMARY).
  - discoveryRetryCapHits stays bounded (peers don't oscillate against the
    cap forever — capHits == number of retries scheduled while already at
    the cap, not exponential).
  - After reset, the next schedule uses DISCOVERY_RETRY_INITIAL_SECONDS,
    not the pre-reset value.
]]

local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test    = dofile("local-tests/harness/test.lua")

io.write("Soak: discovery retry backoff under churn\n")

local INITIAL = 20
local STEP    = 20
local MAX     = 300
-- Misses needed to first reach the cap: 15 (delay sequence 20, 40, ..., 300).
local MISSES_TO_CAP = (MAX - INITIAL) / STEP + 1  -- = 15

local function cancelHelloTimer(sync)
    if sync._helloTimer then
        sync:CancelTimer(sync._helloTimer, true)
        sync._helloTimer = nil
    end
end

local function forceScheduleRetry(sync, reason)
    cancelHelloTimer(sync)
    sync:ScheduleDiscoveryRetry(reason or "test-miss")
end

Test.it("backoff grows monotonically by STEP and caps at MAX", function()
    local bus = CommBus.New({ names = { "Lonepeer" } })
    local node = bus:AddNode("Lonepeer")
    bus:Activate(node)
    local sync = node.addon.Sync

    local delays = {}
    -- Drive past the cap by 3 extra misses to confirm cap stays sticky and
    -- discoveryRetryCapHits accumulates without going unbounded relative to
    -- the number of post-cap scheduling attempts. The reason MUST start
    -- with "discovery-" so ScheduleHello's internal shouldResetDiscoveryRetry
    -- treats it as a continuation of the same backoff run, not as a fresh
    -- HELLO trigger that would reset progress.
    local totalCalls = MISSES_TO_CAP + 3
    for index = 1, totalCalls do
        forceScheduleRetry(sync, "discovery-miss")
        delays[index] = sync.telemetry.discoveryRetryDelay or 0
    end

    -- Expected schedule: delay[k] = min(MAX, INITIAL + (k-1) * STEP)
    for index = 1, totalCalls do
        local expected = math.min(MAX, INITIAL + (index - 1) * STEP)
        Test.eq(delays[index], expected,
            string.format("miss %d should use delay %d, telemetry shows %d",
                index, expected, delays[index]))
    end

    -- Monotonic non-decreasing across the whole sequence.
    for index = 2, totalCalls do
        Test.lte(delays[index - 1], delays[index],
            string.format("delay should never decrease across misses (saw %d -> %d at miss %d)",
                delays[index - 1], delays[index], index))
    end

    -- Cap hits fire when the CURRENT delay used for scheduling is already
    -- at MAX. That happens starting with the call that first uses delay=MAX
    -- (call number MISSES_TO_CAP). With totalCalls = MISSES_TO_CAP + 3, the
    -- last 4 calls all sit at MAX → 4 cap hits.
    local expectedCapHits = totalCalls - MISSES_TO_CAP + 1
    Test.eq(sync.telemetry.discoveryRetryCapHits or 0, expectedCapHits,
        string.format("expected %d cap hits from post-cap scheduling, saw %d",
            expectedCapHits, sync.telemetry.discoveryRetryCapHits or 0))

    -- Misses telemetry should equal total scheduling calls.
    Test.eq(sync.telemetry.discoveryRetryMisses or 0, totalCalls,
        string.format("expected %d total misses tracked, saw %d",
            totalCalls, sync.telemetry.discoveryRetryMisses or 0))
end)

Test.it("useful SUMMARY resets backoff to the initial delay", function()
    local bus = CommBus.New({ names = { "Resetpeer" } })
    local node = bus:AddNode("Resetpeer")
    bus:Activate(node)
    local sync = node.addon.Sync

    -- Seed local content so BuildLocalSummary returns indexStatus="ready".
    -- The reset path inside RecordSummary requires a ready local summary
    -- before it will accept the incoming summary as "useful".
    bus:SeedSelfProfession(node, {
        profession  = "Alchemy",
        recipeCount = 2,
        baseRecipe  = 510000,
    })

    -- Drive the backoff up several steps so the reset is visible. Use the
    -- canonical "discovery-miss" reason so the scheduler treats this as
    -- continuation of the same backoff run (see Test 1 for the same point).
    local warmupMisses = 5
    for _ = 1, warmupMisses do
        forceScheduleRetry(sync, "discovery-miss")
    end
    Test.eq(sync.discoveryRetryDelay, INITIAL + warmupMisses * STEP,
        string.format("backoff should sit at %d after %d misses", INITIAL + warmupMisses * STEP, warmupMisses))
    local resetCountBefore = sync.telemetry.discoveryRetryReset or 0

    -- Open a HELLO cycle so RecordSummary has an active cycle to attach to,
    -- then feed it a SUMMARY with a fingerprint that differs from ours.
    sync:BeginHelloCycle("test-reset-cycle")
    local accepted = sync:RecordSummary("Otherpeer-TestRealm", {
        helloId            = sync.activeHelloCycle.helloId,
        activeOwnerCount   = 1,
        activeBlockCount   = 1,
        activeContentCount = 10,
        globalFingerprint  = "gf3:test-different-from-local",
    })
    Test.truthy(accepted, "RecordSummary should accept a valid foreign summary")

    Test.eq(sync.discoveryRetryDelay, INITIAL,
        string.format("backoff should reset to %d after a useful SUMMARY, saw %d",
            INITIAL, sync.discoveryRetryDelay or 0))
    Test.eq(sync.discoveryRetryMisses or 0, 0,
        "miss counter should reset to zero on useful SUMMARY")
    Test.gte(sync.telemetry.discoveryRetryReset or 0, resetCountBefore + 1,
        "discoveryRetryReset telemetry should increment on useful SUMMARY")

    -- After reset, the next schedule must use INITIAL again, not the
    -- pre-reset value — otherwise the reset wouldn't actually free the
    -- peer from a long backoff window.
    forceScheduleRetry(sync, "post-reset")
    Test.eq(sync.telemetry.discoveryRetryDelay, INITIAL,
        string.format("first schedule after reset should use initial delay %d, saw %d",
            INITIAL, sync.telemetry.discoveryRetryDelay or 0))
end)

io.write(string.format("Soak discovery backoff: %d test(s) passed\n", Test.count))
