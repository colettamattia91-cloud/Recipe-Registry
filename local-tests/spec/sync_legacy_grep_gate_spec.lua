local Test = dofile("local-tests/harness/test.lua")

local ACTIVE_RUNTIME_FILES = {
    "BuildInfo.lua",
    "Core.lua",
    "Data.lua",
    "DataCatalog.lua",
    "DataIndex.lua",
    "DataScan.lua",
    "DataSnapshot.lua",
    "MergeEngine.lua",
    "MockSync.lua",
    "Sync.lua",
    "SyncCodec.lua",
    "SyncDiagnostics.lua",
    "SyncPausePolicy.lua",
    "SyncProtocol.lua",
    "SyncRequests.lua",
    "SyncRuntime.lua",
    "SyncTransfer.lua",
    "UI/MainFrame.lua",
}

local FORBIDDEN = {
    { name = "legacy kind AD", pattern = '%f[%w]"AD"%f[%W]' },
    { name = "legacy kind IDX", pattern = '%f[%w]"IDX"%f[%W]' },
    { name = "legacy kind MANI", pattern = '%f[%w]"MANI"%f[%W]' },
    { name = "legacy kind MREQ", pattern = '%f[%w]"MREQ"%f[%W]' },
    { name = "legacy kind REQ", pattern = '%f[%w]"REQ"%f[%W]' },
    { name = "legacy kind SNAP", pattern = '%f[%w]"SNAP"%f[%W]' },
    { name = "legacy kind RESUME", pattern = '%f[%w]"RESUME"%f[%W]' },
    { name = "legacy kind DONE", pattern = '%f[%w]"DONE"%f[%W]' },
    { name = "legacy kind RERR", pattern = '%f[%w]"RERR"%f[%W]' },
    { name = "manifest token", pattern = "%f[%a]manifest%f[%A]" },
    { name = "coordinator token", pattern = "%f[%a]coordinator%f[%A]" },
    { name = "revision token", pattern = "%f[%a]revision%f[%A]" },
    { name = "rev token", pattern = "%f[%a]rev%f[%A]" },
    { name = "blockRevision token", pattern = "blockRevision" },
    { name = "knownRev token", pattern = "knownRev" },
    { name = "wantRev token", pattern = "wantRev" },
    { name = "remoteRev token", pattern = "remoteRev" },
    { name = "localRev token", pattern = "localRev" },
    { name = "ownerRevision token", pattern = "ownerRevision" },
    { name = "legacyMessagesIgnored telemetry", pattern = "legacyMessagesIgnored" },
    { name = "ignoredRemovedInbound telemetry", pattern = "ignoredRemovedInbound" },
    { name = "lastLegacyMessageIgnored telemetry", pattern = "lastLegacyMessageIgnored" },
    { name = "recordRemovedInbound helper", pattern = "recordRemovedInbound" },
    { name = "DataManifest module", pattern = "DataManifest" },
    { name = "SyncManifest module", pattern = "SyncManifest" },
    { name = "TrickleSync module", pattern = "TrickleSync" },
    { name = "AdvertiseLocalRevision", pattern = "%f[%w]AdvertiseLocalRevision%f[%W]" },
    { name = "BroadcastIndex", pattern = "%f[%w]BroadcastIndex%f[%W]" },
    { name = "HandleIndex", pattern = "%f[%w]HandleIndex%f[%W]" },
    { name = "HandleAdvertise", pattern = "%f[%w]HandleAdvertise%f[%W]" },
    { name = "RecordRevisionHint", pattern = "%f[%w]RecordRevisionHint%f[%W]" },
    { name = "GetKnownRevision", pattern = "%f[%w]GetKnownRevision%f[%W]" },
    { name = "QueueRequest", pattern = "%f[%w]QueueRequest%f[%W]" },
    { name = "RequestGuildCatchup", pattern = "%f[%w]RequestGuildCatchup%f[%W]" },
    { name = "RecomputeCoordinator", pattern = "%f[%w]RecomputeCoordinator%f[%W]" },
    { name = "IsCoordinator", pattern = "%f[%w]IsCoordinator%f[%W]" },
    { name = "SendManifestToPeer", pattern = "%f[%w]SendManifestToPeer%f[%W]" },
    { name = "RequestManifestRefresh", pattern = "%f[%w]RequestManifestRefresh%f[%W]" },
    { name = "ProcessPeerManifestComparison", pattern = "%f[%w]ProcessPeerManifestComparison%f[%W]" },
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

Test.it("legacy sync modules are deleted and absent from the repository", function()
    Test.falsy(fileExists("DataManifest.lua"), "DataManifest.lua should be deleted")
    Test.falsy(fileExists("SyncManifest.lua"), "SyncManifest.lua should be deleted")
    Test.falsy(fileExists("TrickleSync.lua"), "TrickleSync.lua should be deleted")
end)

Test.it("active runtime Lua files are free of explicit legacy sync protocol symbols", function()
    local violations = {}

    for _, path in ipairs(ACTIVE_RUNTIME_FILES) do
        local content = readFile(path)
        local lineNumber = 0
        for line in content:gmatch("([^\n]*)\n?") do
            lineNumber = lineNumber + 1
            for _, forbidden in ipairs(FORBIDDEN) do
                if line:find(forbidden.pattern) then
                    violations[#violations + 1] = string.format("%s:%d:%s", path, lineNumber, forbidden.name)
                end
            end
        end
    end

    Test.eq(#violations, 0, table.concat(violations, "\n"))
end)

Test.it("protocol dispatch exposes only the supported modern message kinds", function()
    local protocol = readFile("SyncProtocol.lua")

    Test.truthy(protocol:find('payload%.kind == "HELLO"', 1, false) ~= nil, "HELLO dispatch should remain")
    Test.truthy(protocol:find('payload%.kind == "SUMMARY"', 1, false) ~= nil, "SUMMARY dispatch should remain")
    Test.truthy(protocol:find('payload%.kind == "INDEX_DIFF_REQUEST"', 1, false) ~= nil, "INDEX_DIFF_REQUEST dispatch should remain")
    Test.truthy(protocol:find('payload%.kind == "INDEX_DIFF_RESPONSE"', 1, false) ~= nil, "INDEX_DIFF_RESPONSE dispatch should remain")
    Test.truthy(protocol:find('payload%.kind == "BLOCK_PULL_REQUEST"', 1, false) ~= nil, "BLOCK_PULL_REQUEST dispatch should remain")
    Test.truthy(protocol:find('payload%.kind == "BLOCK_SNAPSHOT"', 1, false) ~= nil, "BLOCK_SNAPSHOT dispatch should remain")
    Test.truthy(protocol:find("recordUnsupportedMessage%(self, payload%.kind, payload%.sender%)", 1, false) ~= nil, "unsupported messages should be ignored generically")
end)

io.write(string.format("Sync legacy grep gate: %d test(s) passed\n", Test.count))
