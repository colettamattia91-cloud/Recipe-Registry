local Test = dofile("local-tests/harness/test.lua")

local ACTIVE_FILES = {
    "BuildInfo.lua",
    "DataIndex.lua",
    "DataSnapshot.lua",
    "MergeEngine.lua",
    "Sync.lua",
    "SyncRuntime.lua",
    "SyncProtocol.lua",
    "SyncCodec.lua",
    "SyncRequests.lua",
    "SyncTransfer.lua",
    "SyncDiagnostics.lua",
    "Core.lua",
}

local FORBIDDEN = {
    { name = "rev", pattern = "%f[%w]rev%f[%W]" },
    { name = "revision", pattern = "%f[%w]revision%f[%W]" },
    { name = "blockRevision", pattern = "blockRevision" },
    { name = "knownRev", pattern = "knownRev" },
    { name = "wantRev", pattern = "wantRev" },
    { name = "remoteRev", pattern = "remoteRev" },
    { name = "localRev", pattern = "localRev" },
    { name = "ownerRevision", pattern = "ownerRevision" },
    { name = "RecordRevisionHint", pattern = "%f[%w]RecordRevisionHint%f[%W]" },
    { name = "GetKnownRevision", pattern = "%f[%w]GetKnownRevision%f[%W]" },
    { name = "QueueRequest", pattern = "%f[%w]QueueRequest%f[%W]" },
    { name = "AdvertiseLocalRevision", pattern = "%f[%w]AdvertiseLocalRevision%f[%W]" },
    { name = "BroadcastIndex", pattern = "%f[%w]BroadcastIndex%f[%W]" },
    { name = "HandleIndex", pattern = "%f[%w]HandleIndex%f[%W]" },
    { name = "HandleAdvertise", pattern = "%f[%w]HandleAdvertise%f[%W]" },
    { name = "SendManifestToPeer", pattern = "%f[%w]SendManifestToPeer%f[%W]" },
    { name = "RequestManifestRefresh", pattern = "%f[%w]RequestManifestRefresh%f[%W]" },
    { name = "ProcessPeerManifestComparison", pattern = "%f[%w]ProcessPeerManifestComparison%f[%W]" },
}

local ALLOWED = {
    ["SyncProtocol.lua"] = {
        ["HandleIndex"] = true,
        ["HandleAdvertise"] = true,
    },
    ["SyncRequests.lua"] = {
        ["QueueRequest"] = true,
    },
}

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local content = handle:read("*a")
    handle:close()
    return content
end

io.write("Sync legacy grep gate\n")

Test.it("active sync code is free of behavior-driving revision and manifest terms", function()
    local violations = {}

    for _, path in ipairs(ACTIVE_FILES) do
        local content = readFile(path)
        local allowedForFile = ALLOWED[path] or {}
        for _, forbidden in ipairs(FORBIDDEN) do
            if not allowedForFile[forbidden.name] then
                local lineNumber = 0
                for line in content:gmatch("([^\n]*)\n?") do
                    lineNumber = lineNumber + 1
                    if line:find(forbidden.pattern) then
                        violations[#violations + 1] = string.format("%s:%d:%s", path, lineNumber, forbidden.name)
                    end
                end
            end
        end
    end

    Test.eq(#violations, 0, table.concat(violations, "\n"))
end)

io.write(string.format("Sync legacy grep gate: %d test(s) passed\n", Test.count))
