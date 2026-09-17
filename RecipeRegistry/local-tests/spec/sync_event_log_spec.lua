local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

io.write("Sync event log\n")

Test.it("recent sync event log is bounded and drops payload-shaped fields", function()
    local addon = Loader.Load()
    local limit = addon.Sync._private.constants.RECENT_SYNC_EVENTS_LIMIT or 50

    for index = 1, limit + 10 do
        addon.Sync:RecordSyncEvent("event-" .. tostring(index), {
            reason = "bounded",
            extra = "row-" .. tostring(index),
            blockKey = "Tester-TestRealm::Alchemy",
            blockPayload = { hidden = true },
            recipeKeys = { index },
        })
    end

    local events = addon.Sync:GetRecentSyncEvents(limit + 20)
    Test.eq(#events, limit, "recent sync event log should stay bounded")
    Test.eq(events[1].event, "event-11", "oldest rows should roll off the ring buffer")
    Test.eq(events[#events].blockPayload, nil, "recent log entries should not store payloads")
    Test.eq(events[#events].recipeKeys, nil, "recent log entries should not store recipe arrays")
end)

io.write(string.format("Sync event log: %d test(s) passed\n", Test.count))
