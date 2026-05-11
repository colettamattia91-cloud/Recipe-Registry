local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    addon.Sync:EnsureBackgroundWorkers()
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

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
end

io.write("Version sync\n")

Test.it("manual version audit blacklists peers that do not answer", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Silentpeer-TestRealm"

    addon.Sync:TouchNode(peerKey, "1.8.1")
    addon:SlashHandler("version")
    Test.eq(countCommKind(wow, "VREQ"), 1, "version audit should send VREQ")

    wow.AdvanceTime(9)
    wow.RunDueTimers(10)

    Test.truthy(addon.Sync:IsPeerVersionBlacklisted(peerKey), "silent peer should be blacklisted after timeout")
end)

Test.it("compatible version response clears a timeout blacklist", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Recoverpeer-TestRealm"

    addon.Sync:TouchNode(peerKey, "1.8.1")
    addon:SlashHandler("version")
    wow.AdvanceTime(9)
    wow.RunDueTimers(10)
    Test.truthy(addon.Sync:IsPeerVersionBlacklisted(peerKey), "peer should be blacklisted before response")

    wow.DeliverComm(addon.Sync, {
        kind = "VACK",
        sender = peerKey,
        version = "1.8.1",
        wireVersion = addon.WIRE_VERSION,
    }, {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.falsy(addon.Sync:IsPeerVersionBlacklisted(peerKey), "matching VACK should clear blacklist")
end)

Test.it("newer peer version locks local sync and preserves read-only consult mode", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Newerpeer-TestRealm"

    wow.DeliverComm(addon.Sync, {
        kind = "HELLO",
        key = peerKey,
        rev = 9,
        updatedAt = 2000,
        sender = peerKey,
        version = "1.9.0",
        caps = {
            addonVersion = "1.9.0",
            wireVersion = addon.WIRE_VERSION,
        },
    }, {
        sender = peerKey,
        distribution = "GUILD",
    })

    Test.truthy(addon.Sync:IsVersionSyncBlocked(), "newer peer should lock local sync")
    Test.truthy(printLogContains(wow, "Recipe Registry sync locked:"), "local obsolete warning should be printed")

    addon.Sync:QueueRequest(peerKey, peerKey, 9, "manual")
    Test.eq(Test.countKeys(addon.Sync.pendingRequests), 0, "locked local version should refuse new sync requests")
end)

Test.it("older peer version is blacklisted and excluded from sync exchange", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Olderpeer-TestRealm"

    addon.Sync:TouchNode(peerKey, "1.7.9")
    wow.DeliverComm(addon.Sync, {
        kind = "VACK",
        sender = peerKey,
        version = "1.7.9",
        wireVersion = addon.WIRE_VERSION,
    }, {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.truthy(addon.Sync:IsPeerVersionBlacklisted(peerKey), "older peer should be blacklisted")
    local eligible, reason = addon.Sync:CanExchangeDataWithPeer(peerKey, "dispatch", {
        source = peerKey,
        memberKey = peerKey,
        why = "index",
    })
    Test.falsy(eligible, "blacklisted peer should be ineligible")
    Test.truthy(tostring(reason):find("peer_version_blacklist", 1, true) ~= nil, "blacklist reason should surface")
    Test.falsy(addon.Sync:SendDirectEnvelope("REQ", {
        key = peerKey,
        knownRev = 0,
        wantRev = 1,
    }, peerKey, "ALERT"), "REQ should not be sent to blacklisted peer")
end)

Test.it("same version peer keeps sync behavior unchanged", function()
    local addon, wow, _data = freshAddon()
    local peerKey = "Equalpeer-TestRealm"

    addon.Sync:TouchNode(peerKey, "1.8.1")
    wow.DeliverComm(addon.Sync, {
        kind = "VACK",
        sender = peerKey,
        version = "1.8.1",
        wireVersion = addon.WIRE_VERSION,
    }, {
        sender = peerKey,
        distribution = "WHISPER",
    })

    Test.falsy(addon.Sync:IsVersionSyncBlocked(), "equal version should not lock local sync")
    Test.falsy(addon.Sync:IsPeerVersionBlacklisted(peerKey), "equal version should not blacklist peer")
    addon.Sync:QueueRequest(peerKey, peerKey, 4, "manual")
    Test.truthy(addon.Sync.pendingRequests[peerKey], "equal version peer should remain queueable")
end)

io.write(string.format("Version sync: %d test(s) passed\n", Test.count))
