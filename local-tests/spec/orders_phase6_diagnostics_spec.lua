local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshPlugin()
    Loader.Wow.Reset()
    return Loader.LoadOrders({
        recipeRegistryStub = {
            Data = {},
            SyncPausePolicy = {
                ShouldPauseProtocolTraffic = function() return false end,
            },
        },
    })
end

io.write("Craft Orders diagnostics\n")

Test.it("Snapshot reports prefix, wire version, build channel from BuildInfo", function()
    local plugin = freshPlugin()
    local snap = plugin.Diagnostics:Snapshot()
    Test.eq(snap.protocol.commPrefix, plugin.COMM_PREFIX)
    Test.eq(snap.protocol.wireVersion, plugin.WIRE_VERSION)
    Test.eq(snap.protocol.buildChannel, plugin.BUILD_CHANNEL)
    Test.eq(snap.protocol.commRegistered, false, "no RegisterComm yet")
end)

Test.it("Snapshot enumerates peers sorted by highWaterSeq desc", function()
    local plugin = freshPlugin()
    plugin.db.global.peers["Alice-X"] = { highWaterSeq = 3,  lastSeenAt = 100 }
    plugin.db.global.peers["Bob-Y"]   = { highWaterSeq = 10, lastSeenAt = 200 }
    plugin.db.global.peers["Carl-Z"]  = { highWaterSeq = 7,  lastSeenAt = 150 }

    local snap = plugin.Diagnostics:Snapshot()
    Test.eq(#snap.store.peers, 3)
    Test.eq(snap.store.peers[1].key, "Bob-Y")
    Test.eq(snap.store.peers[2].key, "Carl-Z")
    Test.eq(snap.store.peers[3].key, "Alice-X")
end)

Test.it("Snapshot returns 0 across counters when nothing's happened", function()
    local plugin = freshPlugin()
    local snap = plugin.Diagnostics:Snapshot()
    Test.eq(snap.store.orders, 0)
    Test.eq(snap.store.events, 0)
    Test.eq(snap.store.tombstones, 0)
    Test.eq(snap.protocol.telemetry.helloSent or 0, 0)
    Test.eq(snap.reducer.telemetry.applied or 0, 0)
end)

Test.it("FormatSyncLines surfaces hello/events counters once they tick", function()
    local plugin = freshPlugin()
    plugin.Protocol:ResetTelemetry()
    plugin.Reducer:ResetTelemetry()
    plugin.Protocol.telemetry.helloSent = 4
    plugin.Protocol.telemetry.eventsApplied = 11
    plugin.Reducer.telemetry.applied = 9

    local lines = plugin.Diagnostics:FormatSyncLines()
    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("Hello: sent=4", 1, true))
    Test.truthy(joined:find("applied=11", 1, true))
    Test.truthy(joined:find("Reducer: applied=9", 1, true))
end)

Test.it("FormatSyncLines distinguishes registered vs not-registered comm", function()
    local plugin = freshPlugin()
    local linesBefore = table.concat(plugin.Diagnostics:FormatSyncLines(), "\n")
    Test.truthy(linesBefore:find("not-registered", 1, true))

    plugin.Protocol._commRegistered = true
    local linesAfter = table.concat(plugin.Diagnostics:FormatSyncLines(), "\n")
    Test.truthy(linesAfter:find("comm=registered", 1, true))
    Test.falsy(linesAfter:find("not-registered", 1, true))
end)

Test.it("FormatSyncLines lists peers (up to 8) with their seq + age", function()
    local plugin = freshPlugin()
    for i = 1, 10 do
        plugin.db.global.peers["Peer" .. i .. "-Realm"] = {
            highWaterSeq = i,
            lastSeenAt   = 1700000000,
        }
    end
    local lines = plugin.Diagnostics:FormatSyncLines()
    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("Peers (by highest seq):", 1, true))
    Test.truthy(joined:find("Peer10-Realm", 1, true), "highest seq peer comes first")
    Test.truthy(joined:find("(+ 2 more)", 1, true), "tail summary appears when over 8")
end)

Test.it("FormatStatusLine is a single line summarising the most relevant counters", function()
    local plugin = freshPlugin()
    plugin.Protocol.telemetry.helloSent = 2
    plugin.Protocol.telemetry.eventsApplied = 5
    plugin.Reducer.telemetry.applied = 4
    local line = plugin.Diagnostics:FormatStatusLine()
    Test.truthy(line:find("hello-sent=2", 1, true))
    Test.truthy(line:find("events-applied=5", 1, true))
    Test.truthy(line:find("reducer-applied=4", 1, true))
end)

Test.it("/rrord sync prints the formatted lines", function()
    local plugin = freshPlugin()
    Loader.Wow.GetPrints()  -- harness has a print buffer; clear by reading length cursor
    local before = #Loader.Wow.GetPrints()
    plugin:SlashHandler("sync")
    local after = #Loader.Wow.GetPrints()
    Test.gte(after - before, 5, "at least 5 lines printed (header, runtime, hello, events, reducer, store...)")
    -- Inspect the printed lines for a sentinel that only appears in
    -- the sync output.
    local found = false
    for index = before + 1, after do
        if tostring(Loader.Wow.GetPrints()[index]):find("Sync:", 1, true) then
            found = true
            break
        end
    end
    Test.truthy(found, "expected a 'Sync:' line in the slash output")
end)

io.write(string.format("Craft Orders diagnostics: %d test(s) passed\n", Test.count))
