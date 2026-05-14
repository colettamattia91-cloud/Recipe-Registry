local Loader = dofile("local-tests/harness/load-addon.lua")
local CommBus = dofile("local-tests/harness/comm-bus.lua")
local Test = dofile("local-tests/harness/test.lua")

local function metadata(version, channel, buildId)
    return {
        Version = version or "1.8.1",
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

Test.it("dev peers exchange HELLO and MANI only on the dev prefix", function()
    local bus = CommBus.New()
    local left = bus:AddNode("Devleft", {
        addonMetadata = metadata("1.8.1", "dev", "dev-left"),
    })
    local right = bus:AddNode("Devright", {
        addonMetadata = metadata("1.8.2", "dev", "dev-right"),
    })

    bus:Activate(left)
    left.addon.Sync:BroadcastHello()

    local settled = bus:RunUntil(function()
        return right.addon.Sync.peerVersions[left.key] ~= nil
            and right.addon.Sync.onlineNodes[left.key] ~= nil
            and countSentKind(right, "MANI") >= 1
    end, {
        maxTicks = 80,
    })

    Test.truthy(settled, "dev peers should complete hello/manifest exchange")
    Test.eq(left.addon.ADDON_PREFIX, "RRDEV", "left dev prefix")
    Test.eq(right.addon.ADDON_PREFIX, "RRDEV", "right dev prefix")
    Test.eq(right.addon.Sync.peerVersions[left.key].compatibility, "compatible", "dev peer compatibility")
    Test.eq(right.addon.Sync.telemetry.buildChannelDrops or 0, 0, "dev peers should not drop same-channel traffic")
end)

Test.it("release peers exchange HELLO and MANI only on the release prefix", function()
    local bus = CommBus.New()
    local left = bus:AddNode("Releaseleft", {
        addonMetadata = metadata("1.8.1", "release", "release-left"),
    })
    local right = bus:AddNode("Releaseright", {
        addonMetadata = metadata("1.8.2", "release", "release-right"),
    })

    bus:Activate(left)
    left.addon.Sync:BroadcastHello()

    local settled = bus:RunUntil(function()
        return right.addon.Sync.peerVersions[left.key] ~= nil
            and right.addon.Sync.onlineNodes[left.key] ~= nil
            and countSentKind(right, "MANI") >= 1
    end, {
        maxTicks = 80,
    })

    Test.truthy(settled, "release peers should complete hello/manifest exchange")
    Test.eq(left.addon.ADDON_PREFIX, "RecipeRegistry", "left release prefix")
    Test.eq(right.addon.ADDON_PREFIX, "RecipeRegistry", "right release prefix")
    Test.eq(right.addon.Sync.peerVersions[left.key].compatibility, "compatible", "release peer compatibility")
    Test.eq(right.addon.Sync.telemetry.buildChannelDrops or 0, 0, "release peers should not drop same-channel traffic")
end)

Test.it("mixed dev and release peers stay isolated at the comm prefix layer", function()
    local bus = CommBus.New()
    local devNode = bus:AddNode("Devsolo", {
        addonMetadata = metadata("1.8.1", "dev", "dev-solo"),
    })
    local releaseNode = bus:AddNode("Releasesolo", {
        addonMetadata = metadata("1.8.1", "release", "release-solo"),
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

    Test.eq(countKeys(devNode.addon.Sync.peerVersions), 0, "dev should not learn release peer versions on the other prefix")
    Test.eq(countKeys(releaseNode.addon.Sync.peerVersions), 0, "release should not learn dev peer versions on the other prefix")
    Test.eq(countSentKind(devNode, "MANI"), 0, "dev should not send manifest traffic to release")
    Test.eq(countSentKind(releaseNode, "MANI"), 0, "release should not send manifest traffic to dev")
    Test.eq(countKeys(devNode.addon.Sync.pendingRequests), 0, "dev should keep request queue idle")
    Test.eq(countKeys(releaseNode.addon.Sync.pendingRequests), 0, "release should keep request queue idle")
    Test.eq(devNode.addon.Sync.telemetry.buildChannelDrops or 0, 0, "prefix isolation should stop mixed traffic before payload guards")
    Test.eq(releaseNode.addon.Sync.telemetry.buildChannelDrops or 0, 0, "prefix isolation should stop mixed traffic before payload guards")
end)

Test.it("dev drops release payloads that arrive on the active prefix before they create sync state", function()
    local addon, wow = loadAddon("dev")
    local peerKey = "Releasepeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        rev = 4,
        updatedAt = 100,
        addonVersion = "1.8.9",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.9",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 1, "payload guard should count the drop")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropPeer, peerKey, "drop peer telemetry")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropRemote, "release", "drop remote channel telemetry")
    Test.eq(addon.Sync.telemetry.lastBuildChannelDropReason, "channel-mismatch", "drop reason telemetry")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "payload guard should stop online node creation")
    Test.eq(countKeys(addon.Sync.pendingRequests), 0, "payload guard should stop pending requests")
    Test.eq(addon.Sync:GetActiveRequestCount(), 0, "payload guard should stop active requests")
    Test.eq(addon.Sync:GetInFlightRequest(), nil, "payload guard should stop in-flight requests")
    Test.eq(countKeys(addon.Sync.peerBackoffUntil), 0, "payload guard should stop peer backoff")
end)

Test.it("release drops dev payloads on the active prefix without showing update notices", function()
    local addon, wow = loadAddon("release")
    local peerKey = "Devpeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        rev = 6,
        updatedAt = 100,
        addonVersion = "9.9.9",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "dev",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "9.9.9",
            buildChannel = "dev",
            capabilities = {
                maniReliable = true,
            },
        },
    }, {
        prefix = addon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = peerKey,
    })

    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 1, "release should drop dev payloads")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "release should not create a sync peer from dev traffic")
    Test.falsy(printContains(wow, "newer version detected"), "release should ignore dev update notices")
end)

Test.it("missing buildChannel is rejected by dev but allowed as legacy release traffic when wire metadata is present", function()
    local devAddon = loadAddon("dev")
    local legacyDevPeer = "Legacydev-TestRealm"

    Loader.Wow.DeliverComm(devAddon.Sync, {
        kind = "HELLO",
        key = legacyDevPeer,
        sender = legacyDevPeer,
        rev = 2,
        updatedAt = 100,
        wireVersion = devAddon.WIRE_VERSION,
        caps = {
            wireVersion = devAddon.WIRE_VERSION,
            capabilities = {
                maniReliable = true,
            },
        },
    }, {
        prefix = devAddon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = legacyDevPeer,
    })

    Test.eq(devAddon.Sync.telemetry.buildChannelDrops or 0, 1, "dev should reject missing buildChannel")
    Test.eq(devAddon.Sync.onlineNodes[legacyDevPeer], nil, "dev should not accept legacy peers")

    local releaseAddon = loadAddon("release")
    local releasePeer = "Legacyrelease-TestRealm"

    Loader.Wow.DeliverComm(releaseAddon.Sync, {
        kind = "HELLO",
        key = releasePeer,
        sender = releasePeer,
        rev = 2,
        updatedAt = 100,
        wireVersion = releaseAddon.WIRE_VERSION,
        caps = {
            wireVersion = releaseAddon.WIRE_VERSION,
            capabilities = {
                maniReliable = true,
            },
        },
    }, {
        prefix = releaseAddon.ADDON_PREFIX,
        distribution = "GUILD",
        sender = releasePeer,
    })

    Test.eq(releaseAddon.Sync.telemetry.buildChannelDrops or 0, 0, "release should allow explicit legacy policy")
    Test.truthy(releaseAddon.Sync.onlineNodes[releasePeer], "release should still accept legacy traffic")
    Test.eq(releaseAddon.Sync.peerVersions[releasePeer].compatibility, "legacy-unknown", "release legacy compatibility state")
end)
