local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local DIRECT_SCENARIOS = { "light", "medium", "heavy", "burst", "bootstrap" }
local TRAFFIC_SCENARIOS = { "traffic", "offline", "offlinewipe", "trafficburst" }
local ROSTER_SCENARIOS = { "roster", "rosterheavy" }

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
    return addon, wow
end

local function ceil(value)
    return math.ceil(value)
end

local function countMockMembers(addon, prefix)
    local total = 0
    for memberKey in pairs(addon.Data:GetMembersDB()) do
        if type(memberKey) == "string" and memberKey:find(prefix, 1, true) == 1 then
            total = total + 1
        end
    end
    return total
end

local function countMockRecipes(addon, prefix)
    local members = 0
    local professions = 0
    local recipes = 0
    for memberKey, entry in pairs(addon.Data:GetMembersDB()) do
        if type(memberKey) == "string" and memberKey:find(prefix, 1, true) == 1 then
            members = members + 1
            for _, prof in pairs(entry.professions or {}) do
                professions = professions + 1
                recipes = recipes + (prof.count or 0)
            end
        end
    end
    return members, professions, recipes
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function printLogDoesNotContain(wow, needle)
    return not printLogContains(wow, needle)
end

local function runUntil(addon, wow, predicate, maxTicks)
    maxTicks = maxTicks or 5000
    for _ = 1, maxTicks do
        addon.Sync:ProcessRequestQueue()
        addon.Sync:ProcessInboundQueue()
        addon.Performance:RunNextStep()
        addon.MockSync:GetDebugSnapshot()
        if predicate() then
            return true
        end
        wow.AdvanceTime(0.25)
    end
    return false
end

local function queuesIdle(addon)
    return #addon.Sync.inboundChunkQueue == 0
        and #addon.Sync.inboundFinalizeQueue == 0
        and addon.Sync.inFlight == nil
        and next(addon.Sync.pendingRequests) == nil
end

local function drainDirectScenario(addon, wow)
    return runUntil(addon, wow, function()
        local snapshot = addon.MockSync:GetDebugSnapshot()
        return snapshot.active == false
            and snapshot.pendingPayloads == 0
            and queuesIdle(addon)
    end, 10000)
end

local function drainTrafficScenario(addon, wow)
    return runUntil(addon, wow, function()
        local snapshot = addon.MockSync:GetDebugSnapshot()
        return snapshot.pendingPayloads == 0
            and queuesIdle(addon)
            and (addon.Sync.telemetry.replicaRequestsQueued or 0) == (addon.Sync.telemetry.replicaOwnersApplied or 0)
            and (addon.Sync.telemetry.replicaRequestsQueued or 0) > 0
    end, 20000)
end

local function drainRosterScenario(addon, wow)
    return runUntil(addon, wow, function()
        local snapshot = addon.MockSync:GetDebugSnapshot()
        return snapshot.active == false
            and snapshot.rosterRunning == false
            and snapshot.lastCleanup ~= nil
    end, 2000)
end

local function directExpectedPayloads(config)
    return (config.peers or 0)
        * (config.professions or 0)
        * ceil((config.recipesPerProfession or 0) / (config.chunkSize or 1))
end

local function trafficExpectedBlocks(config)
    return (config.peers or 0) * (config.ownersPerPeer or 0) * (config.professions or 0)
end

local function trafficExpectedOwners(config)
    return (config.peers or 0) * (config.ownersPerPeer or 0)
end

io.write("Mock scenarios\n")

Test.it("declares every expected scenario and rejects unknown scenarios", function()
    local addon = freshAddon()
    local names = {
        "light", "medium", "heavy", "burst", "bootstrap",
        "traffic", "offline", "offlinewipe", "trafficburst",
        "roster", "rosterheavy", "rosterbad", "integrity",
    }

    for _, name in ipairs(names) do
        Test.truthy(addon.MockSync:GetScenarioConfig(name), name .. " should be declared")
    end

    local ok, reason = addon.MockSync:StartScenario("does-not-exist")
    Test.falsy(ok, "unknown mock scenario should not start")
    Test.eq(reason, "unknown-scenario", "unknown scenario reason")
    Test.eq(addon.MockSync:GetDebugSnapshot().scenarioCount, #names, "scenario count should match test matrix")
end)

Test.it("covers the /rr mock command surface", function()
    local addon, wow = freshAddon()

    addon:SlashHandler("mock start integrity")
    Test.truthy(printLogContains(wow, "Mock sync completed: integrity (ok)"), "slash start integrity output")

    addon:SlashHandler("mock status")
    Test.truthy(printLogDoesNotContain(wow, "Mock active=false scenario=integrity"), "slash status should be hidden without debug")

    addon.debugMode = true
    addon:SlashHandler("mock status")
    Test.truthy(printLogContains(wow, "Mock active=false scenario=integrity"), "slash status output")
    addon.debugMode = false

    addon:SlashHandler("mock reset")
    Test.truthy(printLogContains(wow, "Mock sync counters reset."), "slash reset output")
    Test.eq(addon.MockSync.telemetry.scenariosStarted, 0, "reset should clear counters")

    addon:SlashHandler("mock start does-not-exist")
    Test.truthy(printLogContains(wow, "Mock sync start failed: unknown-scenario"), "slash unknown start output")

    addon:SlashHandler("mock stop")
    Test.truthy(printLogContains(wow, "Mock sync stopped."), "slash stop output")

    addon:SlashHandler("mock cleanup")
    Test.truthy(printLogContains(wow, "Mock cleanup complete."), "slash cleanup output")
end)

for _, scenarioName in ipairs(DIRECT_SCENARIOS) do
    Test.it("runs direct mock scenario " .. scenarioName .. " to merged snapshots", function()
        local addon, wow = freshAddon()
        local config = addon.MockSync:GetScenarioConfig(scenarioName)
        local expectedPayloads = directExpectedPayloads(config)
        local expectedMembers = config.peers
        local expectedProfessions = config.peers * config.professions
        local expectedRecipes = config.peers * config.professions * config.recipesPerProfession

        local ok, reason = addon.MockSync:StartScenario(scenarioName)
        Test.truthy(ok, "scenario should start: " .. tostring(reason))
        Test.truthy(addon.MockSync:IsHardIsolationEnabled(), "scenario should isolate real traffic")
        Test.eq(addon.MockSync:GetDebugSnapshot().pendingPayloads, expectedPayloads, "queued payload count")

        Test.truthy(drainDirectScenario(addon, wow), "scenario should drain")

        local snapshot = addon.MockSync:GetDebugSnapshot()
        local telemetry = snapshot.telemetry or {}
        local members, professions, recipes = countMockRecipes(addon, "__RRMockPeer")

        Test.eq(telemetry.payloadsQueued, expectedPayloads, "payloads queued")
        Test.eq(telemetry.payloadsDelivered, expectedPayloads, "payloads delivered")
        Test.eq(telemetry.scenariosStarted, 1, "scenario started telemetry")
        Test.eq(telemetry.scenariosCompleted, 1, "scenario completed telemetry")
        Test.eq(addon.Sync.telemetry.receivedChunks, expectedPayloads, "sync received chunks")
        Test.eq(addon.Sync.telemetry.appliedChunks, expectedMembers, "merged member snapshots")
        Test.eq(members, expectedMembers, "mock member count")
        Test.eq(professions, expectedProfessions, "mock profession count")
        Test.eq(recipes, expectedRecipes, "mock recipe count")

        if scenarioName == "bootstrap" then
            local first
            for memberKey, entry in pairs(addon.Data:GetMembersDB()) do
                if memberKey:find("__RRMockPeer", 1, true) == 1 then
                    first = entry
                    break
                end
            end
            Test.truthy(first, "bootstrap should create a mock member")
            local sawBootstrapBlock = false
            for _, prof in pairs(first.professions or {}) do
                if prof.sourceType == "bootstrap" then
                    sawBootstrapBlock = true
                    break
                end
            end
            Test.truthy(sawBootstrapBlock, "bootstrap mock should preserve bootstrap block source")
        end
    end)
end

for _, scenarioName in ipairs(TRAFFIC_SCENARIOS) do
    Test.it("runs traffic mock scenario " .. scenarioName .. " through manifest replica catch-up", function()
        local addon, wow = freshAddon()
        local config = addon.MockSync:GetScenarioConfig(scenarioName)
        local expectedOwners = trafficExpectedOwners(config)
        local expectedBlocks = trafficExpectedBlocks(config)
        local expectedRecipes = expectedBlocks * config.recipesPerProfession

        local ok, reason = addon.MockSync:StartScenario(scenarioName)
        Test.truthy(ok, "traffic scenario should start: " .. tostring(reason))
        Test.truthy(addon.MockSync:IsHardIsolationEnabled(), "traffic scenario should isolate real traffic")
        Test.eq(addon.MockSync:GetDebugSnapshot().datasets, config.peers, "mock peer datasets")

        Test.truthy(drainTrafficScenario(addon, wow), "traffic scenario should drain")

        local snapshot = addon.MockSync:GetDebugSnapshot()
        local mockTelemetry = snapshot.telemetry or {}
        local syncTelemetry = addon.Sync.telemetry or {}
        local members, professions, recipes = countMockRecipes(addon, "__RRMockOwner")

        Test.eq(snapshot.pendingPayloads, 0, "pending payloads should drain")
        Test.eq(mockTelemetry.scenariosStarted, 1, "scenario started telemetry")
        Test.eq(mockTelemetry.peersSimulated, config.peers, "peers simulated")
        Test.gte(mockTelemetry.trafficAnnouncements, config.peers, "hello/manifest announcements")
        Test.eq(mockTelemetry.trafficRequests, expectedOwners, "local mock requests")
        Test.gte(mockTelemetry.trafficSnapshots, expectedOwners, "snapshot payloads delivered")
        Test.eq(syncTelemetry.replicaManifestBlocksSeen, expectedBlocks, "manifest blocks seen")
        Test.eq(syncTelemetry.replicaManifestOwnersSeen, expectedOwners, "manifest owners seen")
        Test.eq(syncTelemetry.replicaRequestsQueued, expectedOwners, "replica requests queued")
        Test.eq(syncTelemetry.replicaOwnersApplied, expectedOwners, "replica owners applied")
        Test.eq(syncTelemetry.replicaNewOwnersApplied, expectedOwners, "new replica owners applied")
        Test.eq(addon.Sync:GetDebugSnapshot().pendingRequests, 0, "sync pending requests")
        Test.eq(members, expectedOwners, "offline owner member count")
        Test.eq(professions, expectedBlocks, "offline owner profession blocks")
        Test.eq(recipes, expectedRecipes, "offline owner recipe count")
    end)
end

for _, scenarioName in ipairs(ROSTER_SCENARIOS) do
    Test.it("runs roster mock scenario " .. scenarioName .. " with expected stale/prune results", function()
        local addon, wow = freshAddon()
        local config = addon.MockSync:GetScenarioConfig(scenarioName)
        local expectedProcessed = (config.activeMembers or 0) + (config.missingMembers or 0) + (config.prunableMembers or 0)

        local ok, reason = addon.MockSync:StartScenario(scenarioName)
        Test.truthy(ok, "roster scenario should start: " .. tostring(reason))
        Test.truthy(drainRosterScenario(addon, wow), "roster scenario should drain")

        local snapshot = addon.MockSync:GetDebugSnapshot()
        local telemetry = snapshot.telemetry or {}
        local lastCleanup = snapshot.lastCleanup or {}

        Test.eq(telemetry.rosterRunsStarted, 1, "roster started telemetry")
        Test.eq(telemetry.rosterRunsCompleted, 1, "roster completed telemetry")
        Test.eq(lastCleanup.aborted, false, "cleanup should not abort")
        Test.eq(lastCleanup.processed, expectedProcessed, "processed members")
        Test.eq(lastCleanup.keptActive, config.activeMembers, "kept active members")
        Test.eq(lastCleanup.markedStale, config.missingMembers, "marked stale members")
        Test.eq(lastCleanup.pruned, config.prunableMembers, "pruned members")
        Test.eq(countMockMembers(addon, "__RRMockOwnerRoster"), expectedProcessed - config.prunableMembers, "remaining roster mock members")
    end)
end

Test.it("runs rosterbad mock scenario as an aborted incomplete-roster guardrail", function()
    local addon = freshAddon()

    local ok, reason = addon.MockSync:StartScenario("rosterbad")
    Test.truthy(ok, "rosterbad should complete as a successful guardrail scenario")
    Test.eq(reason, "roster-empty", "rosterbad should report the abort reason")

    local snapshot = addon.MockSync:GetDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    local lastCleanup = snapshot.lastCleanup or {}

    Test.falsy(snapshot.active, "rosterbad should not stay active")
    Test.eq(telemetry.rosterRunsStarted, 1, "rosterbad started telemetry")
    Test.eq(telemetry.rosterRunsCompleted, 1, "rosterbad completed telemetry")
    Test.truthy(lastCleanup.aborted, "cleanup should be marked aborted")
    Test.eq(lastCleanup.abortReason, "roster-empty", "abort reason")
    Test.eq(lastCleanup.markedStale, 0, "guardrail should not mark stale")
end)

Test.it("runs integrity mock scenario and records the protected merge result", function()
    local addon = freshAddon()

    local ok, reason = addon.MockSync:StartScenario("integrity")
    Test.truthy(ok, "integrity scenario should pass: " .. tostring(reason))

    local snapshot = addon.MockSync:GetDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    local integrity = snapshot.integrityScenario or {}

    Test.falsy(snapshot.active, "integrity scenario should finish immediately")
    Test.eq(telemetry.integrityRunsStarted, 1, "integrity started telemetry")
    Test.eq(telemetry.integrityRunsCompleted, 1, "integrity completed telemetry")
    Test.eq(telemetry.integrityRunsFailed, 0, "integrity failure telemetry")
    Test.truthy(integrity.passed, "integrity result")
    Test.eq(integrity.reason, "ok", "integrity reason")
    Test.truthy(integrity.secondaryExists, "missing profession block should be preserved")
    Test.gte(integrity.primaryCount, integrity.expectedPrimaryCount, "primary profession should not shrink")
end)

Test.it("cleans mock members and sync state after a scenario", function()
    local addon, wow = freshAddon()

    Test.truthy(addon.MockSync:StartScenario("traffic"), "traffic scenario should start")
    Test.truthy(drainTrafficScenario(addon, wow), "traffic scenario should drain before cleanup")
    Test.gte(countMockMembers(addon, "__RRMockOwner"), 1, "mock owners should exist before cleanup")
    Test.gte(addon.Sync:GetDebugSnapshot().registry, 1, "mock registry entries should exist before cleanup")

    local removedMembers, removedRegistry, removedOnlineNodes = addon.MockSync:Cleanup()

    Test.gte(removedMembers, 1, "cleanup should remove mock members")
    Test.gte(removedRegistry, 1, "cleanup should remove registry rows")
    Test.gte(removedOnlineNodes, 1, "cleanup should remove online mock nodes")
    Test.eq(countMockMembers(addon, "__RRMockOwner"), 0, "mock owners after cleanup")
    Test.eq(countMockMembers(addon, "__RRMockPeer"), 0, "mock peers after cleanup")
    Test.eq(addon.Sync:GetDebugSnapshot().pendingRequests, 0, "pending requests after cleanup")
end)

io.write(string.format("Mock scenarios: %d test(s) passed\n", Test.count))
