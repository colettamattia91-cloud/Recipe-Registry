local Addon = _G.RecipeRegistry
local Sync = Addon:NewModule("Sync", "AceComm-3.0", "AceEvent-3.0", "AceTimer-3.0")
Addon.Sync = Sync
local Private = Sync._private or {}
Sync._private = Private

local PREFIX = Addon.COMM_PREFIX or Addon.ADDON_PREFIX
local time = time
local pairs = pairs
local ipairs = ipairs
local min = math.min
local GetTime = GetTime

local REQUEST_TIMEOUT = 25
local SESSION_TIMEOUT = 60
local NODE_TIMEOUT = 95
local HELLO_INTERVAL = 30
-- Stretch the auto-HELLO cadence once our published fingerprint stops
-- changing AND we have established peers in onlineNodes. Two aligned
-- peers used to HELLO every 30s forever just to assert liveness; the
-- receiver then suppressed the SUMMARY for `fingerprints-match`,
-- producing pure background traffic. Stable-state HELLOs at 75s still
-- arrive within NODE_TIMEOUT (95s) so peers don't prune us, with a
-- comfortable margin for ChatThrottleLib jitter.
local HELLO_INTERVAL_STABLE = 75
local AUTO_SYNC_INTERVAL = 20
local PEER_BACKOFF_SECONDS = 45
-- Grace periods after entering the world. Sync stays paused (no HELLO
-- broadcast, no inbound serving) for this long so the addon doesn't
-- compete with WoW's load/reload/zone-change for frame time. Login and
-- reload have their own values because those events do far more work
-- (item cache priming, guild roster fetch, AtlasLoot warmup, full
-- profession scan) than a plain zone change.
local POST_LOGIN_GRACE_SECONDS = 30
local POST_RELOAD_GRACE_SECONDS = 25
local POST_WORLD_GRACE_SECONDS = 12
local POST_INSTANCE_GRACE_SECONDS = 15
local POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = 30
local POST_COMBAT_GRACE_SECONDS = 6
local ROSTER_FRESHNESS_MAX_AGE = 20
local SUMMARY_COLLECTION_WINDOW = 6
local SUMMARY_SATURATION_THRESHOLD = 80
-- Time between BLOCK_PULL_REQUESTs. Bumped from 1.0 to 2.5 to give the
-- requester's Lua VM time to GC the per-merge transients (cloned recipe
-- maps, decompression buffers, intermediate tables, trace strings)
-- before the next snapshot lands. Receivers observed memory climbing
-- to ~150 MB and visible stutter during massive pulls at the old
-- cadence. The total wall-clock for a full sync increases (e.g., 100
-- blocks: 100s -> 250s) but the per-frame budget breathes.
local BLOCK_PULL_DELAY_SECONDS = 2.5
-- Per-block response window. AceComm BULK priority is rate-limited by
-- ChatThrottleLib (~800 bytes/sec shared across all BULK queues). A
-- typical BLOCK_SNAPSHOT compressed is 1-3 KB; a seeder serving multiple
-- peers can take 10-15s to push a single snapshot out the door. 20s left
-- no headroom and produced spurious block-response-timeout aborts
-- mid-pull, forcing the requester to start over and pull everything
-- again on the next cycle. The 60s SESSION_TIMEOUT still bounds total
-- stall in case the seeder truly stops responding.
local BLOCK_PULL_RESPONSE_TIMEOUT_SECONDS = 60
local HELLO_RESCHEDULE_DELAY_SECONDS = 5
local HELLO_RESCHEDULE_JITTER_SECONDS = 10
local POST_SYNC_HELLO_COOLDOWN_SECONDS = 30
local DISCOVERY_RETRY_INITIAL_SECONDS = 20
local DISCOVERY_RETRY_STEP_SECONDS = 20
local DISCOVERY_RETRY_MAX_SECONDS = 300
local MAX_INBOUND_SEED_SESSIONS = 4
local MAX_INBOUND_SEED_SESSIONS_PER_PEER = 1
local SEED_SELECTION_TOP_BAND_RATIO = 0.95
local RECENT_SYNC_EVENTS_LIMIT = 50
local TRUSTED_ROSTER_CLEANUP_INTERVAL_SECONDS = 86400

local function countKeys(tbl)
    local total = 0
    for _ in pairs(tbl or {}) do
        total = total + 1
    end
    return total
end

local function nowForPacing()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

local function shallowCopyArray(src)
    local out = {}
    for index = 1, #(src or {}) do
        out[index] = src[index]
    end
    return out
end

local function shallowCopyTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function cloneStringSet(src)
    local out = {}
    for index = 1, #(src or {}) do
        if src[index] then
            out[#out + 1] = src[index]
        end
    end
    return out
end

local function isHelloAutoReason(why)
    return tostring(why or ""):find("^hello%-auto") ~= nil
end

local function isManualReason(why)
    local text = tostring(why or "")
    return text == "manual" or text == "manual-all"
end

local function addRetrySuffix(why)
    local text = tostring(why or "retry")
    if text == "" then
        return "retry"
    end
    if text:find(":retry", 1, true) then
        return text
    end
    return text .. ":retry"
end

local function isMockKey(memberKey)
    return type(memberKey) == "string"
        and (memberKey:find("__RRMockPeer", 1, true) == 1 or memberKey:find("__RRMockOwner", 1, true) == 1)
end

local function newSyncTelemetry()
    return {
        helloSent = 0,
        summarySent = 0,
        summaryReceived = 0,
        seedSelected = 0,
        indexDiffRequestSent = 0,
        indexDiffRequestReceived = 0,
        indexDiffResponseSent = 0,
        indexDiffResponseReceived = 0,
        indexDiffBusySent = 0,
        indexDiffBusyReceived = 0,
        blocksOffered = 0,
        blockPullRequestSent = 0,
        blockPullStarted = 0,
        blockPullDelayed = 0,
        blockSnapshotSent = 0,
        blockSnapshotReceived = 0,
        blockMergedImmediate = 0,
        blockFingerprintRecomputed = 0,
        outboundSessionCompleted = 0,
        outboundSessionAborted = 0,
        unsupportedMessagesIgnored = 0,
        lastUnsupportedMessageKind = nil,
        lastUnsupportedMessageSender = nil,
        lastUnsupportedMessageAt = 0,
        globalFingerprintDirty = 0,
        pausedSyncCycles = 0,
        skippedEquivalentMerges = 0,
        syncIndexCacheHit = 0,
        syncIndexCacheMiss = 0,
        syncIndexBlockRebuilt = 0,
        syncIndexFullRebuild = 0,
        syncIndexGlobalRecomputed = 0,
        syncIndexDirtyBlockCount = 0,
        buildChannelDrops = 0,
        ignoredBuildChannelPeers = 0,
        lastBuildChannelDropPeer = nil,
        lastBuildChannelDropRemote = nil,
        lastBuildChannelDropReason = nil,
        versionIneligiblePeers = 0,
        skippedVersionIncompatible = 0,
        skippedMissingCapability = 0,
        assumedModernCapabilities = 0,
        assumedModernCapabilityPeer = nil,
        assumedModernCapabilityPurpose = nil,
        lastVersionNoticePeer = nil,
        lastVersionNoticeRemote = nil,
        latestRemoteVersionSeen = nil,
        newerVersionSeen = 0,
        newerProtocolSeen = 0,
        activeCommPrefix = PREFIX,
        lastSelectedPeer = nil,
        lastSelectedReason = nil,
        lastSeedSelectionHash = nil,
        lastSeedSelectionBand = nil,
        seedSelectionHashed = 0,
        seedFallbackSelected = 0,
        seedBusyReceived = 0,
        seedBusyNoFallback = 0,
        lastAbortReason = nil,
        lastSummaryPeer = nil,
        lastIndexDiffSeed = nil,
        lastIndexDiffRequestId = nil,
        lastIndexDiffTarget = nil,
        lastIndexDiffLocalBlockCount = 0,
        lastIndexDiffOfferedCount = 0,
        lastIndexDiffNoOfferReason = nil,
        lastIndexDiffBusyPeer = nil,
        lastIndexDiffBusyReason = nil,
        lastBlockPullBlockKey = nil,
        lastBlockPullRequestId = nil,
        lastBlockPullSentAt = 0,
        lastBlockSnapshotReceivedAt = 0,
        lastBlockPullTimeoutAt = 0,
        lastBlockPullTimeoutReason = nil,
        lastMergedBlockKey = nil,
        lastMergedBlockFingerprint = nil,
        lastBlockOfferReasons = nil,
        lastSessionCompleteReason = nil,
        syncReadyTransitions = 0,
        lastSyncReady = false,
        lastSyncReadyReason = nil,
        lastSyncNotReadyReason = nil,
        savedVariablesReadyAt = 0,
        playerReadyAt = 0,
        rosterPreflightReadyAt = 0,
        indexReadyAt = 0,
        lastReadinessGateFailure = nil,
        helloScheduled = 0,
        helloScheduleCoalesced = 0,
        helloDeferredNotReady = 0,
        helloDeferredPaused = 0,
        helloDeferredOutboundActive = 0,
        helloDeferredReason = nil,
        lastHelloScheduledReason = nil,
        lastHelloScheduledDelay = 0,
        lastHelloDueAt = 0,
        lastHelloSentAt = 0,
        lastHelloId = nil,
        lastHelloFingerprint = nil,
        summaryWindowOpened = 0,
        summaryWindowClosed = 0,
        lastSummaryWindowCloseAt = 0,
        lastSummaryCount = 0,
        summaryCollectionTimeouts = 0,
        discoveryRetryMisses = 0,
        discoveryRetryDelay = 0,
        discoveryRetryNextAt = 0,
        discoveryRetryCapHits = 0,
        discoveryRetryReset = 0,
        lastDiscoveryRetryReason = nil,
        lastNoSeedReason = nil,
        seedCandidatesSeen = 0,
        seedCandidatesRejected = 0,
        lastSeedCandidateCount = 0,
        lastSeedRejectReasons = nil,
        successfulBlockMerges = 0,
        inboundSeedSessionsMax = MAX_INBOUND_SEED_SESSIONS,
        inboundSeedSessionsRejectedCap = 0,
        inboundSeedSessionsRejectedPaused = 0,
        inboundSeedSessionsRejectedNotReady = 0,
        inboundSeedSessionsClearedPause = 0,
        inboundSeedSessionsCompleted = 0,
        inboundBlockPullRejectedUnknownRequest = 0,
        inboundBlockPullRejectedNotOffered = 0,
        summarySuppressedAtCap = 0,
        lastInboundRequester = nil,
        lastInboundRequestId = nil,
        lastInboundServedBlockKey = nil,
        lastDirtyBlockKey = nil,
        lastRebuiltBlockKey = nil,
        lastGlobalFingerprintAt = 0,
        lastGlobalFingerprintReason = nil,
        lastPauseReason = nil,
        lastPauseEnterReason = nil,
        lastPauseExitReason = nil,
        outboundSessionsAbortedPause = 0,
        lastNoSummaryAt = 0,
        rosterSyncRelevantUpdates = 0,
        rosterSyncNoopUpdates = 0,
        rosterUpdateIgnoredForSync = 0,
        rosterIndexDirtySkipped = 0,
        rosterKnownOwnersChecked = 0,
        rosterUnknownMembersIgnored = 0,
        rosterCleanupRuns = 0,
        rosterCleanupSkippedThrottle = 0,
        rosterCleanupChangedOwners = 0,
        lastRosterSyncSignature = nil,
        lastRosterSyncRelevantReason = nil,
    }
end

Private.constants = {
    PREFIX = PREFIX,
    REQUEST_TIMEOUT = REQUEST_TIMEOUT,
    SESSION_TIMEOUT = SESSION_TIMEOUT,
    NODE_TIMEOUT = NODE_TIMEOUT,
    HELLO_INTERVAL = HELLO_INTERVAL,
    HELLO_INTERVAL_STABLE = HELLO_INTERVAL_STABLE,
    AUTO_SYNC_INTERVAL = AUTO_SYNC_INTERVAL,
    PEER_BACKOFF_SECONDS = PEER_BACKOFF_SECONDS,
    POST_LOGIN_GRACE_SECONDS = POST_LOGIN_GRACE_SECONDS,
    POST_RELOAD_GRACE_SECONDS = POST_RELOAD_GRACE_SECONDS,
    POST_WORLD_GRACE_SECONDS = POST_WORLD_GRACE_SECONDS,
    POST_INSTANCE_GRACE_SECONDS = POST_INSTANCE_GRACE_SECONDS,
    POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = POST_RELOAD_IN_INSTANCE_GRACE_SECONDS,
    POST_COMBAT_GRACE_SECONDS = POST_COMBAT_GRACE_SECONDS,
    ROSTER_FRESHNESS_MAX_AGE = ROSTER_FRESHNESS_MAX_AGE,
    SUMMARY_COLLECTION_WINDOW = SUMMARY_COLLECTION_WINDOW,
    SUMMARY_SATURATION_THRESHOLD = SUMMARY_SATURATION_THRESHOLD,
    BLOCK_PULL_DELAY_SECONDS = BLOCK_PULL_DELAY_SECONDS,
    BLOCK_PULL_RESPONSE_TIMEOUT_SECONDS = BLOCK_PULL_RESPONSE_TIMEOUT_SECONDS,
    HELLO_RESCHEDULE_DELAY_SECONDS = HELLO_RESCHEDULE_DELAY_SECONDS,
    HELLO_RESCHEDULE_JITTER_SECONDS = HELLO_RESCHEDULE_JITTER_SECONDS,
    POST_SYNC_HELLO_COOLDOWN_SECONDS = POST_SYNC_HELLO_COOLDOWN_SECONDS,
    DISCOVERY_RETRY_INITIAL_SECONDS = DISCOVERY_RETRY_INITIAL_SECONDS,
    DISCOVERY_RETRY_STEP_SECONDS = DISCOVERY_RETRY_STEP_SECONDS,
    DISCOVERY_RETRY_MAX_SECONDS = DISCOVERY_RETRY_MAX_SECONDS,
    MAX_INBOUND_SEED_SESSIONS = MAX_INBOUND_SEED_SESSIONS,
    MAX_INBOUND_SEED_SESSIONS_PER_PEER = MAX_INBOUND_SEED_SESSIONS_PER_PEER,
    SEED_SELECTION_TOP_BAND_RATIO = SEED_SELECTION_TOP_BAND_RATIO,
    RECENT_SYNC_EVENTS_LIMIT = RECENT_SYNC_EVENTS_LIMIT,
    TRUSTED_ROSTER_CLEANUP_INTERVAL_SECONDS = TRUSTED_ROSTER_CLEANUP_INTERVAL_SECONDS,
    MAX_CONCURRENT_REQUESTS = 1,
}
Private.countKeys = countKeys
Private.nowForPacing = nowForPacing
Private.shallowCopyArray = shallowCopyArray
Private.shallowCopyTable = shallowCopyTable
Private.cloneStringSet = cloneStringSet
Private.isHelloAutoReason = isHelloAutoReason
Private.isManualReason = isManualReason
Private.addRetrySuffix = addRetrySuffix
Private.newSyncTelemetry = newSyncTelemetry
Private.isMockKey = isMockKey

-- User-tunable sync knobs resolve through these helpers so a bogus
-- SavedVariables value (or a missing profile during early init) can never
-- push the sync engine outside the safe operating range. The clamps also
-- shield us from a future refactor that bumps the constants without
-- updating the slider min/max in Options.lua.
local function readTuning(field, fallback, minValue, maxValue)
    local profile = Addon.db and Addon.db.profile or nil
    local value = profile and profile.tuning and tonumber(profile.tuning[field])
    if value == nil then return fallback end
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

function Sync:GetBlockPullDelay()
    return readTuning("blockPullDelaySeconds", BLOCK_PULL_DELAY_SECONDS, 1.0, 5.0)
end

function Sync:GetMaxInboundSeedSessions()
    local value = readTuning("maxInboundSeedSessions", MAX_INBOUND_SEED_SESSIONS, 1, 4)
    return math.floor(value + 0.5)
end

function Sync:GetBlockPullResponseTimeout()
    return readTuning("blockPullResponseTimeoutSeconds", BLOCK_PULL_RESPONSE_TIMEOUT_SECONDS, 30, 120)
end

function Sync:Startup()
    if self._startupInitialized then
        return true
    end
    self._startupInitialized = true
    self:RegisterComm(PREFIX)
    self.queueTicker = self.queueTicker or self:ScheduleRepeatingTimer("ProcessRequestQueue", 1)
    self.pruneTicker = self.pruneTicker or self:ScheduleRepeatingTimer("PruneState", 5)
    self.autoSyncTicker = self.autoSyncTicker or self:ScheduleRepeatingTimer("AutoSyncTick", AUTO_SYNC_INTERVAL)
    self:ScheduleTimer("AutoSyncTick", 6)
    self:EnsureBackgroundWorkers()
    return true
end

function Sync:GetSelfKey()
    return Addon.Data:GetPlayerKey()
end

function Sync:GetWhisperTarget(memberKey)
    if not memberKey then
        return nil
    end
    local name = memberKey:match("^([^%-]+)")
    return name or memberKey
end

function Sync:IsRealTrafficSuppressed()
    return Addon.MockSync
        and Addon.MockSync.IsHardIsolationEnabled
        and Addon.MockSync:IsHardIsolationEnabled()
        or false
end

function Sync:IsMockKey(memberKey)
    if isMockKey(memberKey) then
        return true
    end
    local row = memberKey and self.onlineNodes and self.onlineNodes[memberKey] or nil
    return row and row.isMock == true or false
end

function Sync:IsValidSyncMemberKey(memberKey)
    return type(memberKey) == "string"
        and memberKey ~= ""
        and not memberKey:find(":", 1, true)
        and memberKey:find("-", 1, true) ~= nil
end

function Sync:IsLocallyStaleOwner(ownerCharacter)
    local entry = Addon.Data and Addon.Data.GetMember and Addon.Data:GetMember(ownerCharacter) or nil
    return entry and (entry.guildStatus or "active") ~= "active" or false
end
