local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function metadata(version, channel, buildId)
    return {
        Version = version or "2.0.0",
        ["X-Build-Channel"] = channel or "release",
        ["X-Build-ID"] = buildId or ((channel or "release") .. "-build"),
    }
end

local function loadAddon(channel, version)
    local addon, wow = Loader.Load({
        addonMetadata = metadata(version, channel),
    })
    return addon, wow
end

local function countKeys(tbl)
    local total = 0
    for _ in pairs(tbl or {}) do
        total = total + 1
    end
    return total
end

local function countSentKind(node, kind)
    local total = 0
    for _, row in ipairs(node.state.sentComm or {}) do
        if type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

local function modernCaps(addon, extras)
    local caps = addon.Sync.GetLocalProtocolCaps and addon.Sync:GetLocalProtocolCaps() or {}
    for key, value in pairs(extras or {}) do
        caps[key] = value
    end
    return caps
end

local function printContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

io.write("Build channel isolation\n")

Test.it("selects the active comm prefix from the build channel", function()
    local releaseAddon = loadAddon("release")
    local devAddon = loadAddon("dev")

    Test.eq(releaseAddon.COMM_PREFIX, "RecipeRegistry", "release prefix")
    Test.eq(releaseAddon.ADDON_PREFIX, "RecipeRegistry", "release addon prefix alias")
    Test.eq(devAddon.COMM_PREFIX, "RRDEV", "dev prefix")
    Test.eq(devAddon.ADDON_PREFIX, "RRDEV", "dev addon prefix alias")
end)

Test.it("normalizes beta metadata to the release channel", function()
    local addon = loadAddon("beta")

    Test.eq(addon.BUILD_CHANNEL, "release", "beta metadata should collapse into release")
    Test.eq(addon.ADDON_PREFIX, "RecipeRegistry", "normalized beta should use the release prefix")
end)

Test.it("dev peers exchange HELLO only on the dev prefix", function()
    local bus = CommBus.New()
    local left = bus:AddNode("Devleft", {
        addonMetadata = metadata("2.0.0", "dev", "dev-left"),
    })
    local right = bus:AddNode("Devright", {
        addonMetadata = metadata("2.0.1", "dev", "dev-right"),
    })

    bus:Activate(left)
    left.addon.Sync:BroadcastHello()

    local settled = bus:RunUntil(function()
        return right.addon.Sync.peerVersions[left.key] ~= nil
            and right.addon.Sync.onlineNodes[left.key] ~= nil
    end, {
        maxTicks = 80,
    })

    Test.truthy(settled, "dev peers should complete hello observation")
    Test.eq(left.addon.ADDON_PREFIX, "RRDEV", "left dev prefix")
    Test.eq(right.addon.ADDON_PREFIX, "RRDEV", "right dev prefix")
    Test.eq(right.addon.Sync.peerVersions[left.key].compatibility, "compatible", "dev peer compatibility")
    Test.eq(right.addon.Sync.telemetry.buildChannelDrops or 0, 0, "dev peers should not drop same-channel traffic")
    Test.eq(countSentKind(right, "SUMMARY"), 0, "dev hello should not force summary when no ready delta exists")
end)

Test.it("release peers exchange HELLO only on the release prefix", function()
    local bus = CommBus.New()
    local left = bus:AddNode("Releaseleft", {
        addonMetadata = metadata("2.0.0", "release", "release-left"),
    })
    local right = bus:AddNode("Releaseright", {
        addonMetadata = metadata("2.0.1", "release", "release-right"),
    })

    bus:Activate(left)
    left.addon.Sync:BroadcastHello()

    local settled = bus:RunUntil(function()
        return right.addon.Sync.peerVersions[left.key] ~= nil
            and right.addon.Sync.onlineNodes[left.key] ~= nil
    end, {
        maxTicks = 80,
    })

    Test.truthy(settled, "release peers should complete hello observation")
    Test.eq(left.addon.ADDON_PREFIX, "RecipeRegistry", "left release prefix")
    Test.eq(right.addon.ADDON_PREFIX, "RecipeRegistry", "right release prefix")
    Test.eq(right.addon.Sync.peerVersions[left.key].compatibility, "compatible", "release peer compatibility")
    Test.eq(right.addon.Sync.telemetry.buildChannelDrops or 0, 0, "release peers should not drop same-channel traffic")
    Test.eq(countSentKind(right, "SUMMARY"), 0, "release hello should not force summary when no ready delta exists")
end)

Test.it("mixed dev and release peers stay isolated at the comm prefix layer", function()
    local bus = CommBus.New()
    local devNode = bus:AddNode("Devsolo", {
        addonMetadata = metadata("2.0.0", "dev", "dev-solo"),
    })
    local releaseNode = bus:AddNode("Releasesolo", {
        addonMetadata = metadata("2.0.0", "release", "release-solo"),
    })

    bus:Activate(devNode)
    devNode.addon.Sync:BroadcastHello()
    bus:Activate(releaseNode)
    releaseNode.addon.Sync:BroadcastHello()
    bus:RunUntil(function(current)
        return not current:HasWork()
    end, {
        maxTicks = 40,
    })

    Test.eq(countKeys(devNode.addon.Sync.peerVersions), 0, "dev should not learn release peers on the other prefix")
    Test.eq(countKeys(releaseNode.addon.Sync.peerVersions), 0, "release should not learn dev peers on the other prefix")
    Test.eq(countSentKind(devNode, "HELLO"), 1, "dev should still send hello on its own prefix")
    Test.eq(countSentKind(releaseNode, "HELLO"), 1, "release should still send hello on its own prefix")
    Test.eq(countKeys(devNode.addon.Sync.pendingRequests), 0, "dev should keep request queue idle")
    Test.eq(countKeys(releaseNode.addon.Sync.pendingRequests), 0, "release should keep request queue idle")
    Test.eq(devNode.addon.Sync.telemetry.buildChannelDrops or 0, 0, "prefix isolation should stop mixed traffic before payload guards")
    Test.eq(releaseNode.addon.Sync.telemetry.buildChannelDrops or 0, 0, "prefix isolation should stop mixed traffic before payload guards")
end)

Test.it("dev drops release payloads before they create sync or peer version state", function()
    local addon, wow = loadAddon("dev")
    local peerKey = "Releasepeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "2.0.1",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = modernCaps(addon, {
            addonVersion = "2.0.1",
            buildChannel = "release",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 1, "payload guard should count the drop")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropPeer, peerKey, "drop peer telemetry")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropRemote, "release", "drop remote channel telemetry")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropReason, "channel-mismatch", "drop reason telemetry")
    Test.eq(addon.Sync.peerVersions[peerKey], nil, "channel mismatch should not enter normal peerVersions")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "payload guard should stop online node creation")
    Test.eq(countKeys(addon.Sync.pendingRequests), 0, "payload guard should stop pending requests")
    Test.eq(addon.Sync:GetActiveRequestCount(), 0, "payload guard should stop active requests")
    Test.eq(addon.Sync:GetInFlightRequest(), nil, "payload guard should stop in-flight requests")
    Test.eq(countKeys(addon.Sync.peerBackoffUntil), 0, "payload guard should stop peer backoff")
end)

Test.it("release drops dev payloads without showing update notices or peer version entries", function()
    local addon, wow = loadAddon("release")
    local peerKey = "Devpeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "9.9.9",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "dev",
        caps = modernCaps(addon, {
            addonVersion = "9.9.9",
            buildChannel = "dev",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 1, "release should drop dev payloads")
    Test.eq(addon.Sync.peerVersions[peerKey], nil, "channel mismatch should not enter normal peerVersions")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "release should not create a sync peer from dev traffic")
    Test.falsy(printContains(wow, "newer version detected"), "release should ignore dev update notices")
end)

Test.it("beta payloads are normalized to release instead of becoming a third supported channel", function()
    local addon, wow = loadAddon("release")
    local peerKey = "Betapeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "2.0.0",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "beta",
        caps = modernCaps(addon, {
            addonVersion = "2.0.0",
            buildChannel = "beta",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 0, "normalized beta payload should not be dropped")
    Test.eq(addon.Sync.peerVersions[peerKey].buildChannel, "release", "beta payload should normalize into release")
    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "compatible", "normalized beta payload should use release compatibility rules")
    Test.truthy(addon.Sync.onlineNodes[peerKey], "normalized beta payload should stay on the release path")
    Test.falsy(printContains(wow, "newer version detected"), "equal beta-normalized version should not trigger notices")
end)

Test.it("missing buildChannel is rejected on both dev and release channels", function()
    local devAddon = loadAddon("dev")
    local legacyDevPeer = "Legacydev-TestRealm"

    Loader.Wow.DeliverComm(devAddon.Sync, {
        kind = "HELLO",
        key = legacyDevPeer,
        sender = legacyDevPeer,
        wireVersion = devAddon.WIRE_VERSION,
    }, {
        prefix = devAddon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = legacyDevPeer,
    })

    Test.eq(devAddon.Sync.telemetry.buildChannelDrops or 0, 1, "dev should reject missing buildChannel")
    Test.eq(devAddon.Sync.peerVersions[legacyDevPeer], nil, "dev should not register missing-channel peers")
    Test.eq(devAddon.Sync.onlineNodes[legacyDevPeer], nil, "dev should not accept missing-channel peers")

    local releaseAddon = loadAddon("release")
    local releasePeer = "Legacyrelease-TestRealm"

    Loader.Wow.DeliverComm(releaseAddon.Sync, {
        kind = "HELLO",
        key = releasePeer,
        sender = releasePeer,
        wireVersion = releaseAddon.WIRE_VERSION,
    }, {
        prefix = releaseAddon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = releasePeer,
    })

    Test.eq(releaseAddon.Sync.telemetry.buildChannelDrops or 0, 1, "release should reject missing buildChannel")
    Test.eq(releaseAddon.Sync.peerVersions[releasePeer], nil, "release should not register missing-channel peers")
    Test.eq(releaseAddon.Sync.onlineNodes[releasePeer], nil, "release should keep missing-channel peers out of active sync state")
    Test.eq(countKeys(releaseAddon.Sync.pendingRequests), 0, "missing-channel peers should not queue requests")
    Test.eq(countKeys(releaseAddon.Sync.peerBackoffUntil), 0, "missing-channel peers should not create backoff state")
end)

Test.it("release rejects a remote newer wire and shows a protocol notice", function()
    local addon, wow = loadAddon("release")
    local peerKey = "Newerwire-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "2.0.1",
        wireVersion = (addon.WIRE_VERSION or 0) + 1,
        buildChannel = "release",
        caps = modernCaps(addon, {
            wireVersion = (addon.WIRE_VERSION or 0) + 1,
            addonVersion = "2.0.1",
            buildChannel = "release",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "remote-newer-wire", "newer wire compatibility state")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "newer wire peers should not enter active sync state")
    Test.truthy(printContains(wow, "newer sync protocol detected from " .. peerKey), "newer wire should print a protocol notice")
end)

Test.it("release rejects a remote older wire", function()
    local addon, wow = loadAddon("release")
    local peerKey = "Olderwire-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "1.0.0",
        wireVersion = math.max(1, (addon.MIN_SUPPORTED_WIRE_VERSION or addon.WIRE_VERSION) - 1),
        buildChannel = "release",
        caps = modernCaps(addon, {
            wireVersion = math.max(1, (addon.MIN_SUPPORTED_WIRE_VERSION or addon.WIRE_VERSION) - 1),
            addonVersion = "1.0.0",
            buildChannel = "release",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "remote-older-wire", "older wire compatibility state")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "older wire peers should not enter active sync state")
end)

Test.it("newer compatible addon versions still produce update notices", function()
    local addon, wow = loadAddon("release", "2.0.0")
    local peerKey = "Newerversion-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        addonVersion = "2.1.0",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = modernCaps(addon, {
            addonVersion = "2.1.0",
            buildChannel = "release",
        }),
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "compatible", "compatible newer addon should stay eligible")
    Test.truthy(printContains(wow, "a newer version was detected from " .. peerKey .. " (2.1.0)."), "newer compatible addon should print an update notice")
end)

Test.it("removed legacy capabilities do not affect compatibility decisions", function()
    local addon = loadAddon("release")
    local peerKey = "Capabilitypeer-TestRealm"

    addon.Sync:ObservePeerVersion(peerKey, {
        sender = peerKey,
        addonVersion = addon.ADDON_VERSION,
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = modernCaps(addon, {
            capabilities = {
                indexDiffSync = true,
                blockPullSync = true,
                maniReliable = false,
                manifestShards = false,
            },
        }),
    })
    addon.Sync:RecordPeerCaps(peerKey, modernCaps(addon, {
        capabilities = {
            indexDiffSync = true,
            blockPullSync = true,
            maniReliable = false,
            manifestShards = false,
        },
    }))

    local eligible, reason = addon.Sync:CanExchangeDataWithPeer(peerKey, "dispatch", {
        source = peerKey,
        memberKey = peerKey,
    })

    Test.truthy(eligible, "modern peers should stay eligible even if removed legacy flags are present")
    Test.eq(reason, "eligible", "compatibility reason should ignore removed legacy flags")
end)

io.write(string.format("Build channel isolation: %d test(s) passed\n", Test.count))
