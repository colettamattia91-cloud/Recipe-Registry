local Test = dofile("local-tests/harness/test.lua")

local ACTIVE_FILES = {
    "BuildInfo.lua",
    "Core.lua",
    "Data.lua",
    "DataIndex.lua",
    "DataScan.lua",
    "DataSnapshot.lua",
    "DataCatalog.lua",
    "MergeEngine.lua",
    "MockSync.lua",
    "Sync.lua",
    "SyncRuntime.lua",
    "SyncProtocol.lua",
    "SyncCodec.lua",
    "SyncRequests.lua",
    "SyncTransfer.lua",
    "SyncDiagnostics.lua",
    "SyncPausePolicy.lua",
    "RecipeRegistry.toc",
    "local-tests/harness/load-addon.lua",
}

local FORBIDDEN = {
    { name = "DataManifest module", pattern = "DataManifest%.lua" },
    { name = "SyncManifest module", pattern = "SyncManifest%.lua" },
    { name = "TrickleSync module", pattern = "TrickleSync%.lua" },
    { name = "maniReliable capability", pattern = "maniReliable" },
    { name = "manifestShards capability", pattern = "manifestShards" },
    { name = "QueueRequest", pattern = "%f[%w]QueueRequest%f[%W]" },
    { name = "TouchLocalRevision", pattern = "%f[%w]TouchLocalRevision%f[%W]" },
    { name = "RecordRevisionHint", pattern = "%f[%w]RecordRevisionHint%f[%W]" },
    { name = "RecomputeCoordinator", pattern = "%f[%w]RecomputeCoordinator%f[%W]" },
    { name = "IsCoordinator", pattern = "%f[%w]IsCoordinator%f[%W]" },
    { name = "coordinatorKey", pattern = "coordinatorKey" },
    { name = "SendManifestToPeer", pattern = "%f[%w]SendManifestToPeer%f[%W]" },
    { name = "RequestManifestRefresh", pattern = "%f[%w]RequestManifestRefresh%f[%W]" },
    { name = "ProcessPeerManifestComparison", pattern = "%f[%w]ProcessPeerManifestComparison%f[%W]" },
    { name = "MarkManifestDirty", pattern = "%f[%w]MarkManifestDirty%f[%W]" },
    { name = "MarkManifestMemberDirty", pattern = "%f[%w]MarkManifestMemberDirty%f[%W]" },
    { name = "BuildManifestCacheNow", pattern = "%f[%w]BuildManifestCacheNow%f[%W]" },
    { name = "GetPreparedSyncManifest", pattern = "%f[%w]GetPreparedSyncManifest%f[%W]" },
    { name = "GetManifestDebugSnapshot", pattern = "%f[%w]GetManifestDebugSnapshot%f[%W]" },
    { name = "DumpManifestCacheStatus", pattern = "%f[%w]DumpManifestCacheStatus%f[%W]" },
    { name = "ResetManifestTelemetry", pattern = "%f[%w]ResetManifestTelemetry%f[%W]" },
    { name = "DumpManifestSummary", pattern = "%f[%w]DumpManifestSummary%f[%W]" },
    { name = "AdvertiseLocalRevision", pattern = "%f[%w]AdvertiseLocalRevision%f[%W]" },
    { name = "BroadcastIndex", pattern = "%f[%w]BroadcastIndex%f[%W]" },
    { name = "HandleIndex legacy", pattern = "%f[%w]HandleIndex%f[%W]" },
    { name = "HandleAdvertise", pattern = "%f[%w]HandleAdvertise%f[%W]" },
}

local ALLOWED_LINES = {
    ["SyncProtocol.lua"] = {
        ["MANI"] = true,
        ["MREQ"] = true,
    },
}

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local function fileExists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

io.write("Sync legacy grep gate\n")

Test.it("legacy sync modules are deleted and absent from the load order", function()
    Test.falsy(fileExists("DataManifest.lua"), "DataManifest.lua should be deleted")
    Test.falsy(fileExists("SyncManifest.lua"), "SyncManifest.lua should be deleted")
    Test.falsy(fileExists("TrickleSync.lua"), "TrickleSync.lua should be deleted")
end)

Test.it("active sync code is free of removed manifest, revision, and coordinator symbols", function()
    local violations = {}

    for _, path in ipairs(ACTIVE_FILES) do
        local content = readFile(path)
        local allowed = ALLOWED_LINES[path] or {}
        local lineNumber = 0
        for line in content:gmatch("([^\n]*)\n?") do
            lineNumber = lineNumber + 1
            for _, forbidden in ipairs(FORBIDDEN) do
                if not allowed[forbidden.name] and line:find(forbidden.pattern) then
                    violations[#violations + 1] = string.format("%s:%d:%s", path, lineNumber, forbidden.name)
                end
            end
        end
    end

    Test.eq(#violations, 0, table.concat(violations, "\n"))
end)

Test.it("the removed-message quarantine stays isolated to the protocol dispatcher", function()
    local protocol = readFile("SyncProtocol.lua")
    Test.truthy(protocol:find('payload%.kind == "MANI"', 1, false) ~= nil, "protocol should still recognize removed MANI inbound payloads")
    Test.truthy(protocol:find('payload%.kind == "MREQ"', 1, false) ~= nil, "protocol should still recognize removed MREQ inbound payloads")
    Test.truthy(protocol:find("recordRemovedInbound%(self, payload%.kind, payload%.sender%)", 1, false) ~= nil, "removed payloads should be quarantined without side effects")
end)

io.write(string.format("Sync legacy grep gate: %d test(s) passed\n", Test.count))
