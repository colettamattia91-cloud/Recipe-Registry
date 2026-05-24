local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local PAUSE_STATE = { paused = false }

local function makeStubWithPausePolicy()
    return {
        Data = {},
        SyncPausePolicy = {
            ShouldPauseProtocolTraffic = function(_, _)
                return PAUSE_STATE.paused == true
            end,
        },
    }
end

local function freshPlugin(opts)
    opts = opts or {}
    PAUSE_STATE.paused = false
    Loader.Wow.Reset()
    return Loader.LoadOrders({
        recipeRegistryStub = opts.stub or makeStubWithPausePolicy(),
    })
end

local function countHelloSent()
    local total = 0
    for _, row in ipairs(Loader.Wow.GetSentComm()) do
        if type(row.message) == "table" and row.message.kind == "HELLO_ORDERS" then
            total = total + 1
        end
    end
    return total
end

io.write("Craft Orders runtime\n")

Test.it("ScheduleHello sets a timer and bumps the scheduled counter", function()
    local plugin = freshPlugin()
    plugin.Runtime:ResetTelemetry()
    plugin.Runtime:ScheduleHello("local-change")
    Test.truthy(plugin.Runtime._helloTimer, "timer registered")
    Test.eq(plugin.Runtime.telemetry.helloScheduled, 1)
end)

Test.it("a sooner reason replaces an existing slower timer", function()
    local plugin = freshPlugin()
    plugin.Runtime:ScheduleHello("login")  -- 30s
    local longerDue = plugin.Runtime._helloTimerDelay
    plugin.Runtime:ScheduleHello("local-change")  -- 10s
    Test.lte(plugin.Runtime._helloTimerDelay, longerDue,
        "the shorter delay should win on coalesce")
end)

Test.it("a slower reason keeps the existing sooner timer", function()
    local plugin = freshPlugin()
    plugin.Runtime:ScheduleHello("local-change")  -- 10s
    local sooner = plugin.Runtime._helloTimerDelay
    plugin.Runtime:ScheduleHello("login")  -- 30s, should NOT replace
    Test.eq(plugin.Runtime._helloTimerDelay, sooner)
    Test.eq(plugin.Runtime.telemetry.helloCoalesced, 1)
end)

Test.it("running the timer to completion fires a HELLO broadcast", function()
    local plugin = freshPlugin()
    plugin.Runtime:ResetTelemetry()
    plugin.Runtime:ScheduleHello("local-change")  -- 10s
    Loader.Wow.AdvanceTime(plugin.Runtime.delays.CHANGE_HELLO_DELAY + 1)
    Loader.Wow.RunDueTimers()

    Test.eq(plugin.Runtime.telemetry.helloFired, 1)
    Test.eq(plugin.Runtime.telemetry.helloSent, 1)
    Test.eq(countHelloSent(), 1, "exactly one HELLO went on the wire")
end)

Test.it("FireHello skips and reschedules when pause policy says no", function()
    local plugin = freshPlugin()
    plugin.Runtime:ResetTelemetry()
    PAUSE_STATE.paused = true

    plugin.Runtime:FireHello()
    Test.eq(plugin.Runtime.telemetry.pausedDeferred, 1)
    Test.eq(plugin.Runtime.telemetry.skippedReasons["paused"], 1)
    Test.eq(countHelloSent(), 0, "paused: nothing on the wire")
    Test.truthy(plugin.Runtime._helloTimer, "rescheduled for pause-resume")

    -- Releasing the pause and running the timer should now send.
    PAUSE_STATE.paused = false
    Loader.Wow.AdvanceTime(plugin.Runtime.delays.PAUSE_RESCHEDULE_DELAY + 1)
    Loader.Wow.RunDueTimers()
    Test.eq(countHelloSent(), 1)
end)

Test.it("FireHello skips when local player key is missing", function()
    local plugin = freshPlugin()
    plugin.Runtime:ResetTelemetry()
    local original = plugin.GetLocalPlayerKey
    plugin.GetLocalPlayerKey = function() return nil end
    plugin.Runtime:FireHello()
    Test.eq(plugin.Runtime.telemetry.readinessFailed, 1)
    Test.eq(plugin.Runtime.telemetry.skippedReasons["player-key-missing"], 1)
    Test.eq(countHelloSent(), 0)
    plugin.GetLocalPlayerKey = original
end)

Test.it("OnEnable schedules an initial login HELLO and wires the roster event", function()
    local plugin = freshPlugin()
    plugin.Runtime:OnEnable()
    Test.truthy(plugin.Runtime._helloTimer, "login-delay timer set")
    Test.eq(plugin.Runtime._helloTimerDelay, plugin.Runtime.delays.LOGIN_HELLO_DELAY)
    Test.truthy(plugin.__events and plugin.__events["GUILD_ROSTER_UPDATE"],
        "GUILD_ROSTER_UPDATE handler registered on the addon")
end)

Test.it("OnEnable is idempotent — calling twice doesn't double-schedule", function()
    local plugin = freshPlugin()
    plugin.Runtime:OnEnable()
    local firstTimer = plugin.Runtime._helloTimer
    plugin.Runtime:OnEnable()
    Test.eq(plugin.Runtime._helloTimer, firstTimer, "same timer reused")
end)

Test.it("MIN_BROADCAST_INTERVAL gates back-to-back schedules", function()
    local plugin = freshPlugin()
    -- Trigger one broadcast.
    plugin.Runtime:ScheduleHello("local-change")
    Loader.Wow.AdvanceTime(plugin.Runtime.delays.CHANGE_HELLO_DELAY + 1)
    Loader.Wow.RunDueTimers()
    local sentAfterFirst = countHelloSent()
    Test.eq(sentAfterFirst, 1)

    -- A new schedule immediately afterwards must respect the
    -- min-interval floor. The chosen delay should be >=
    -- MIN_BROADCAST_INTERVAL even though local-change's normal delay
    -- is larger; the assertion verifies the floor isn't undercut.
    plugin.Runtime:ScheduleHello("local-change")
    Test.gte(plugin.Runtime._helloTimerDelay,
        plugin.Runtime.delays.MIN_BROADCAST_INTERVAL - 1)  -- -1 cushion for the time elapsed during RunDueTimers
end)

Test.it("CancelPendingHello clears the timer and pending reasons", function()
    local plugin = freshPlugin()
    plugin.Runtime:ScheduleHello("local-change")
    Test.truthy(plugin.Runtime._helloTimer)
    plugin.Runtime:CancelPendingHello()
    Test.eq(plugin.Runtime._helloTimer, nil)
    Test.eq(plugin.Runtime._pendingReasons, nil)
end)

Test.it("DescribeState reflects schedule + telemetry shape", function()
    local plugin = freshPlugin()
    plugin.Runtime:OnEnable()
    plugin.Runtime:ScheduleHello("local-change")  -- replaces with sooner

    local state = plugin.Runtime:DescribeState()
    Test.truthy(state.enabled)
    Test.truthy(state.hasPendingTimer)
    -- pendingReasons table is alphabetized.
    Test.eq(state.pendingReasons[1], "local-change")
    Test.eq(state.pendingReasons[2], "login")
    Test.eq(type(state.telemetry), "table")
end)

Test.it("GUILD_ROSTER_UPDATE handler routes through to ScheduleHello", function()
    local plugin = freshPlugin()
    plugin.Runtime:OnEnable()
    plugin.Runtime:CancelPendingHello()  -- start clean after the login schedule

    Test.eq(plugin.Runtime._helloTimer, nil)
    -- Invoke the registered handler directly (harness doesn't fire WoW events automatically).
    local handler = plugin.__events["GUILD_ROSTER_UPDATE"]
    Test.eq(type(handler), "function")
    handler("GUILD_ROSTER_UPDATE")
    Test.truthy(plugin.Runtime._helloTimer, "roster trigger scheduled a HELLO")
    Test.eq(plugin.Runtime._helloTimerDelay, plugin.Runtime.delays.ROSTER_HELLO_DELAY)
end)

io.write(string.format("Craft Orders runtime: %d test(s) passed\n", Test.count))
