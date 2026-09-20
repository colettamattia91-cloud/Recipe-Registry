local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load({ enable = true })
    return addon, wow, addon.Data
end

io.write("AceBucket integration\n")

Test.it("coalesces repeated guild roster updates into one bucket flush", function()
    local addon, wow = freshAddon()
    local flushReasons = {}

    addon.Sync.ShouldDeferHeavyLifecycleWork = function()
        return false
    end
    addon.ProcessCoalescedGuildRosterUpdate = function(_, reason)
        flushReasons[#flushReasons + 1] = reason
    end

    wow.DeliverEvent(addon, "GUILD_ROSTER_UPDATE")
    wow.DeliverEvent(addon, "GUILD_ROSTER_UPDATE")
    wow.DeliverEvent(addon, "GUILD_ROSTER_UPDATE")

    wow.AdvanceTime(1.4)
    wow.RunDueTimers()
    Test.eq(#flushReasons, 0, "bucket should not flush before interval")

    wow.AdvanceTime(0.2)
    wow.RunDueTimers()

    local bucket = addon:GetBucketTelemetrySnapshot()
    Test.eq(#flushReasons, 1, "bucket should flush once")
    Test.eq(flushReasons[1], "bucket", "bucket flush reason")
    Test.eq(bucket.rosterBuckets, 1, "roster bucket count")
    Test.eq(bucket.rosterEventsAbsorbed, 3, "roster events absorbed")
    Test.eq(addon.Sync.telemetry.rosterEventsSeen or 0, 3, "sync telemetry seen count")
    Test.eq(addon.Sync.telemetry.rosterEventsCoalesced or 0, 2, "sync telemetry coalesced count")
end)

Test.it("coalesces item info updates and keeps list invalidation narrow", function()
    local addon, wow = freshAddon()
    local invalidations = {}
    local refreshes = {}

    addon.Data.InvalidateRecipeCaches = function(_, scope)
        invalidations[#invalidations + 1] = scope
    end
    addon.RequestRefresh = function(_, reason)
        refreshes[#refreshes + 1] = reason
    end

    wow.DeliverEvent(addon, "GET_ITEM_INFO_RECEIVED", 19019)
    wow.DeliverEvent(addon, "GET_ITEM_INFO_RECEIVED", 19019)
    wow.DeliverEvent(addon, "GET_ITEM_INFO_RECEIVED", 19020)

    wow.AdvanceTime(0.8)
    wow.RunDueTimers()

    local bucket = addon:GetBucketTelemetrySnapshot()
    Test.eq(bucket.itemBuckets, 1, "item bucket count")
    Test.eq(bucket.itemEventsAbsorbed, 3, "item events absorbed")
    Test.eq(#invalidations, 1, "item info should invalidate once")
    Test.eq(invalidations[1], "list", "item info should only invalidate list cache")
    Test.eq(#refreshes, 1, "item info should refresh once")
    Test.eq(refreshes[1], "item-cache", "item info refresh reason")
end)

io.write(string.format("AceBucket integration: %d test(s) passed\n", Test.count))
