local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function primeSyncReady(addon, wow, data, reason)
    local ownerKey = data:GetPlayerKey()
    wow.SetGuildRoster({
        { name = ownerKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    Loader.PrimeSyncReady(addon, {
        reason = reason or "discovery-debug-prime",
        runTimers = false,
    })
end

io.write("Discovery debug\n")

Test.it("discovery retry diagnostics update on empty summary windows and cap at 300 seconds", function()
    local addon, wow, data = freshAddon()
    primeSyncReady(addon, wow, data, "discovery-debug")

    addon.Sync:BroadcastHello()
    wow.AdvanceTime(6)
    wow.RunTimers(20)

    local snapshot = addon.Sync:GetRuntimeObservabilitySnapshot()
    Test.eq(snapshot.discoveryRetry.misses, 1, "empty summary window should count as one retry miss")
    Test.eq(snapshot.discoveryRetry.currentDelay, 20, "first discovery retry should start at 20 seconds")
    Test.truthy(snapshot.discoveryRetry.nextAt > 0, "retry snapshot should include the next due time")
    Test.eq(snapshot.discoveryRetry.capSeconds, 300, "retry cap should be 300 seconds")

    for _ = 1, 20 do
        if addon.Sync._helloTimer then
            addon.Sync:CancelTimer(addon.Sync._helloTimer, true)
            addon.Sync._helloTimer = nil
        end
        addon.Sync._helloScheduledFor = nil
        addon.Sync:ScheduleDiscoveryRetry("discovery-debug-loop")
    end

    local capped = addon.Sync:GetRuntimeObservabilitySnapshot()
    Test.eq(capped.discoveryRetry.currentDelay, 300, "retry delay should cap at 300 seconds")
    Test.truthy(capped.discoveryRetry.capHit, "snapshot should report capped retry state")
end)

io.write(string.format("Discovery debug: %d test(s) passed\n", Test.count))
