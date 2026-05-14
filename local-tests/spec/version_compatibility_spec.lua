local Loader = dofile("local-tests/harness/load-addon.lua")
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

local function printContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function countPrinted(wow, needle)
    local total = 0
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            total = total + 1
        end
    end
    return total
end

local function deliverHello(addon, wow, peerKey, opts)
    opts = opts or {}
    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        sender = peerKey,
        rev = opts.rev or 5,
        updatedAt = opts.updatedAt or 200,
        addonVersion = opts.addonVersion,
        version = opts.version,
        wireVersion = opts.wireVersion,
        buildChannel = opts.buildChannel,
        buildId = opts.buildId,
        caps = opts.caps,
    }, {
        prefix = opts.prefix or addon.ADDON_PREFIX,
        distribution = opts.distribution or "GUILD",
        sender = peerKey,
    })
end

io.write("Version compatibility\n")

Test.it("compares semantic versions numerically", function()
    local addon = loadAddon("release")

    Test.eq(addon.BuildInfo.CompareSemver("1.10.0", "1.9.9"), 1, "1.10.0 should be newer than 1.9.9")
    Test.eq(addon.BuildInfo.CompareSemver("1.8.3", "1.8.2"), 1, "1.8.3 should be newer than 1.8.2")
    Test.eq(addon.BuildInfo.CompareSemver("1.8.1", "1.8.1"), 0, "same version compare")
    Test.eq(addon.BuildInfo.CompareSemver("1.8.0", "1.8.1"), -1, "older version compare")
    Test.eq(addon.BuildInfo.CompareSemver("not-a-version", "1.8.1"), nil, "invalid versions should not compare")
end)

Test.it("same addonVersion does not print update notices", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Sameversion-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.1",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.1",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    Test.falsy(printContains(wow, "newer version detected"), "same version should stay quiet")
    Test.eq(addon.Sync.telemetry.newerVersionSeen or 0, 0, "same version should not increment update telemetry")
end)

Test.it("newer same-channel addonVersion prints one update notice", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Newversion-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.2",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.2",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    Test.truthy(printContains(wow, "Recipe Registry: a newer version was detected from " .. peerKey), "newer release peer should notify")
    Test.eq(addon.Sync.telemetry.newerVersionSeen or 0, 1, "newer version telemetry")
    Test.truthy(addon.Sync.onlineNodes[peerKey], "addonVersion difference alone should not block sync")
    Test.eq(addon.Data:GetUpdateNoticeState().latestRemoteVersionSeen, "1.8.2", "latest remote version should be stored")
    Test.eq(addon.Data:GetUpdateNoticeState().lastNoticedVersion, "1.8.2", "last noticed version should be stored")
end)

Test.it("newer wireVersion is recorded for diagnostics but does not enter the sync peer pool", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Newprotocol-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.2",
        wireVersion = addon.WIRE_VERSION + 1,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION + 1,
            addonVersion = "1.8.2",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    Test.truthy(printContains(wow, "newer sync protocol detected from " .. peerKey), "newer wire should warn")
    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "remote-newer-wire", "peer compatibility should record the wire mismatch")
    Test.eq(addon.Sync.onlineNodes[peerKey], nil, "newer wire peer should not join online sync peers")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "newer wire peer should not queue requests")
end)

Test.it("older wireVersion can stay compatible when the local support window allows it", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Olderwire-TestRealm"

    addon.MIN_SUPPORTED_WIRE_VERSION = addon.WIRE_VERSION - 1
    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.0",
        wireVersion = addon.WIRE_VERSION - 1,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION - 1,
            addonVersion = "1.8.0",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "compatible", "older wire should be compatible inside the support window")
    Test.truthy(addon.Sync.onlineNodes[peerKey], "supported older wire should still be treated as online")
end)

Test.it("missing version fields are tracked as legacy unknown peers", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Legacypeer-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = nil,
        wireVersion = nil,
        buildChannel = nil,
        caps = nil,
    })

    Test.eq(addon.Sync.peerVersions[peerKey].compatibility, "legacy-unknown", "legacy compatibility state")
    Test.truthy(addon.Sync.onlineNodes[peerKey], "legacy peers should still be tracked when release policy allows it")
    Test.falsy(printContains(wow, "newer version detected"), "legacy unknown should not trigger a version notice")
end)

Test.it("release clients ignore newer dev versions for user-facing alerts", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Devnewer-TestRealm"

    deliverHello(addon, wow, peerKey, {
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
    })

    Test.falsy(printContains(wow, "newer version detected"), "dev versions must not notify release users")
    Test.eq(addon.Sync.telemetry.buildChannelDrops or 0, 1, "dev payload should be dropped")
end)

Test.it("invalid addon versions do not trigger update notices", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Invalidversion-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "not-a-version",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "not-a-version",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    Test.falsy(printContains(wow, "a newer version was detected"), "invalid versions should not notify")
    Test.eq(addon.Data:GetUpdateNoticeState().latestRemoteVersionSeen, nil, "invalid versions should not update latest remote version")
end)

Test.it("update notices are rate-limited per version but a newer version bypasses cooldown", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Ratelipeer-TestRealm"

    local firstPayload = {
        addonVersion = "1.8.2",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.2",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    }
    local secondPayload = {
        addonVersion = "1.8.3",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.3",
            buildChannel = "release",
            capabilities = {
                maniReliable = true,
            },
        },
    }
    deliverHello(addon, wow, peerKey, firstPayload)
    deliverHello(addon, wow, peerKey, firstPayload)
    deliverHello(addon, wow, peerKey, secondPayload)

    Test.eq(countPrinted(wow, "Recipe Registry: a newer version was detected from " .. peerKey), 2, "same version should stay suppressed but a newer one should bypass cooldown")
    Test.eq(addon.Sync.telemetry.newerVersionSeen or 0, 2, "newer version bypass should increment telemetry")
    Test.eq(addon.Data:GetUpdateNoticeState().latestRemoteVersionSeen, "1.8.3", "latest remote version should advance")
    Test.eq(addon.Data:GetUpdateNoticeState().lastNoticedVersion, "1.8.3", "last noticed version should advance")
end)

Test.it("manifest-large eligibility requires maniReliable support", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Manipeer-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.1",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.1",
            buildChannel = "release",
            capabilities = {
                maniReliable = false,
            },
        },
    })

    local manifestEligible, manifestReason = addon.Sync:CanExchangeDataWithPeer(peerKey, "manifest-large", {
        source = peerKey,
        memberKey = peerKey,
        why = "hello",
    })
    local requestEligible = addon.Sync:CanExchangeDataWithPeer(peerKey, "request", {
        source = peerKey,
        memberKey = peerKey,
        why = "hello",
    })

    Test.falsy(manifestEligible, "large manifest exchange should require maniReliable")
    Test.eq(manifestReason, "missing-mani-reliable", "manifest eligibility reason")
    Test.truthy(requestEligible, "snapshot request path should remain available")
end)

Test.it("slash diagnostics print local and peer version state", function()
    local addon, wow = loadAddon("release", "1.8.1")
    local peerKey = "Diagpeer-TestRealm"

    deliverHello(addon, wow, peerKey, {
        addonVersion = "1.8.2",
        wireVersion = addon.WIRE_VERSION,
        buildChannel = "release",
        buildId = "release-peer",
        caps = {
            wireVersion = addon.WIRE_VERSION,
            addonVersion = "1.8.2",
            buildChannel = "release",
            buildId = "release-peer",
            capabilities = {
                maniReliable = true,
            },
        },
    })

    addon:SlashHandler("version")
    addon:SlashHandler("versions")

    Test.truthy(printContains(wow, "Recipe Registry: version=1.8.1 wire="), "local version output")
    Test.truthy(printContains(wow, "channel=release"), "channel output")
    Test.truthy(printContains(wow, "prefix=RecipeRegistry"), "prefix output")
    Test.truthy(printContains(wow, "latestRemoteVersionSeen=1.8.2"), "latest remote version output")
    Test.truthy(printContains(wow, "- " .. peerKey .. " version=1.8.2"), "peer versions output")
end)
