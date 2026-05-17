local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function countCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function countLegacyOutbound(wow)
    return countCommKind(wow, "AD")
        + countCommKind(wow, "IDX")
        + countCommKind(wow, "MANI")
        + countCommKind(wow, "MREQ")
end

local function withModernVersion(addon, payload)
    payload = payload or {}
    payload.addonVersion = payload.addonVersion or addon.ADDON_VERSION
    payload.wireVersion = payload.wireVersion or addon.WIRE_VERSION
    payload.buildChannel = payload.buildChannel or addon.BUILD_CHANNEL
    payload.caps = payload.caps or (addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or nil)
    return payload
end

io.write("Sync phase 1 legacy noop\n")

Test.it("ignores inbound AD IDX MANI and MREQ without creating sync work", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerone-TestRealm"
    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        helloId = "legacy-prime",
        syncModel = "index-diff-block-pull",
        indexStatus = "ready",
        activeOwnerCount = 1,
        activeBlockCount = 1,
        activeContentCount = 1,
        globalFingerprint = "gf3:1:1:1:prime",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })
    local messages = {
        {
            kind = "AD",
            key = peerKey,
            sender = peerKey,
        },
        {
            kind = "IDX",
            key = peerKey,
            owner = peerKey,
            sender = peerKey,
        },
        {
            kind = "MANI",
            memberKey = peerKey,
            manifestId = "legacy-mani",
            seq = 1,
            total = 1,
            blocks = {},
            sender = peerKey,
        },
        {
            kind = "MREQ",
            reason = "manual",
            sender = peerKey,
        },
    }

    for _, payload in ipairs(messages) do
        wow.DeliverComm(addon.Sync, withModernVersion(addon, payload), {
            sender = peerKey,
            distribution = "WHISPER",
        })
    end

    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "legacy inbound messages should not queue requests")
    Test.falsy(addon.Sync.inFlight, "legacy inbound messages should not create in-flight work")
    Test.eq(countCommKind(wow, "REQ"), 0, "legacy inbound messages should not emit REQ traffic")
    Test.eq(countLegacyOutbound(wow), 0, "legacy inbound messages should not emit legacy replies")
    Test.eq(addon.Sync.telemetry.legacyMessagesIgnored or 0, 4, "legacy ignore telemetry should count all legacy inbound kinds")
end)

Test.it("HELLO keeps peer observation but does not trigger legacy or request traffic", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Peerhello-TestRealm"

    wow.DeliverComm(addon.Sync, withModernVersion(addon, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        helloId = "peer-hello",
        syncModel = "index-diff-block-pull",
        indexStatus = "ready",
        activeOwnerCount = 2,
        activeBlockCount = 2,
        activeContentCount = 7,
        globalFingerprint = "gf3:2:2:7:test",
    }), {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.truthy(addon.Sync.peerVersions[peerKey], "hello should still record peer version state")
    Test.truthy(addon.Sync.onlineNodes[peerKey], "hello should still record online peer state")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "hello should not queue requests in phase 1")
    Test.falsy(addon.Sync.inFlight, "hello should not create in-flight work in phase 1")
    Test.eq(countCommKind(wow, "REQ"), 0, "hello should not emit REQ traffic in phase 1")
    Test.eq(countLegacyOutbound(wow), 0, "hello should not emit legacy follow-up traffic in phase 1")
end)

Test.it("startup sends HELLO without emitting AD", function()
    local addon, wow, _data = freshAddon()

    addon.Sync:Startup()
    wow.RunTimers(10)

    Test.eq(countCommKind(wow, "AD"), 0, "startup should no longer advertise local revision")
    Test.eq(countLegacyOutbound(wow), 0, "startup should not emit legacy outbound traffic")
    Test.eq(countCommKind(wow, "HELLO"), 1, "startup should still schedule one hello")
end)

Test.it("auto tick keeps the runtime idle until a real summary/diff session exists", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Registrypeer-TestRealm"

    addon.Sync.lastHelloAt = time()
    addon.Sync.onlineNodes[peerKey] = { lastSeen = time(), version = addon.ADDON_VERSION }

    addon.Sync:AutoSyncTick()

    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "auto tick should not queue work from discovery-only state")
    Test.falsy(addon.Sync.inFlight, "auto tick should not create in-flight requests")
    Test.eq(countCommKind(wow, "REQ"), 0, "auto tick should not emit removed request traffic")
end)

io.write(string.format("Sync phase 1 legacy noop: %d test(s) passed\n", Test.count))
