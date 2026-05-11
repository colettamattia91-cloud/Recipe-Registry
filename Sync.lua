local Addon = _G.RecipeRegistry
local Sync = Addon:NewModule("Sync", "AceComm-3.0", "AceEvent-3.0", "AceTimer-3.0")
Addon.Sync = Sync
local Private = Sync._private or {}
Sync._private = Private

local PREFIX = Addon.ADDON_PREFIX
local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local random = math.random
local tinsert = table.insert
local tremove = table.remove
local min = math.min
local max = math.max
local GetTime = GetTime

local REQUEST_TIMEOUT = 25
local PROGRESS_TIMEOUT = 8
local SESSION_TIMEOUT = 60
local NODE_TIMEOUT = 95
local HELLO_INTERVAL = 30
local AUTO_SYNC_INTERVAL = 20
local OUTGOING_CHUNK_DELAY = 0.20
local MANIFEST_CHUNK_DELAY = 0.12
local MANIFEST_INITIAL_JITTER = 0.35
local MAX_RESUME_ATTEMPTS = 3
local COORDINATOR_RECOMPUTE_DELAY = 0.35
local MANIFEST_PUSH_COOLDOWN = 20
local MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH = 8
local MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH = 32
local MANIFEST_CATCHUP_DRAIN_DELAY = 0.20
local MAX_REQUEST_RETRIES = 3
local MAX_HELLO_AUTO_RETRIES = 1
local MAX_CONCURRENT_REQUESTS = 2
local ROSTER_FRESHNESS_MAX_AGE = 20
local ROSTER_REFRESH_REQUEST_COOLDOWN = 8
local PEER_BACKOFF_SECONDS = 45
local HELLO_AUTO_BACKOFF_SECONDS = 20
local PEER_BACKOFF_FAILURE_THRESHOLD = 2
local MANIFEST_REFRESH_REQUEST_COOLDOWN = 30
local POST_WORLD_GRACE_SECONDS = 12
local POST_INSTANCE_GRACE_SECONDS = 15
local POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = 30
local POST_COMBAT_GRACE_SECONDS = 6
local MANIFEST_MERGE_ANNOUNCE_DEBOUNCE = 8
local MANIFEST_MERGE_ANNOUNCE_MAX_DELAY = 25
local OFFLINE_DEBUG_LOG_LIMIT = 12
local MAX_OUTBOUND_CHUNKS = 320
local MAX_MANIFEST_CHUNKS = 256
local MAX_INBOUND_CHUNKS = 320
local MAX_INBOUND_FINALIZE_QUEUE = 96
local MAX_PARTIAL_RECEIVES = 24
local MAX_PARTIAL_MANIFESTS_TOTAL = 64
local MAX_PARTIAL_MANIFESTS_PER_PEER = 8
local MAX_MANIFEST_CATCHUP_QUEUE = 256
local MAX_PENDING_REQUESTS = 64
local SNAP_CODEC_ENABLED = true
local SNAP_CODEC_MIN_BYTES = 768
local SNAP_CODEC_ID = "snap.lsd1"

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

local function nowForPacing()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return time()
end

local function shallowCopyArray(src)
    local out = {}
    for i = 1, #(src or {}) do out[i] = src[i] end
    return out
end

local function shallowCopyTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function getManifestAnnouncementId(chunks, manifest)
    if type(chunks) == "table" and chunks[1] and chunks[1].manifestId then
        return tostring(chunks[1].manifestId)
    end
    if type(manifest) ~= "table" then return nil end
    local totals = manifest.totals or {}
    return string.format(
        "%s:%d:%d:%d",
        tostring(manifest.memberKey or "unknown"),
        tonumber(manifest.builtAt or 0) or 0,
        tonumber(manifest.manifestSerial or 0) or 0,
        tonumber(totals.blocks or 0) or 0
    )
end

local function countArrayUnique(values)
    local seen = {}
    local count = 0
    for _, value in ipairs(values or {}) do
        if value and not seen[value] then
            seen[value] = true
            count = count + 1
        end
    end
    return count
end

local function cloneStringSet(src)
    local out = {}
    for _, value in ipairs(src or {}) do
        if value then
            out[#out + 1] = value
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

local function newSyncTelemetry()
    return {
        sentChunks = 0,
        receivedChunks = 0,
        appliedChunks = 0,
        skippedEquivalentMerges = 0,
        pausedSyncCycles = 0,
        busySeedRejections = 0,
        replicaManifestOwnersSeen = 0,
        replicaManifestBlocksSeen = 0,
        replicaRequestsQueued = 0,
        replicaRequestsServed = 0,
        replicaOwnersApplied = 0,
        replicaNewOwnersApplied = 0,
        manifestChunksSent = 0,
        manifestChunksQueued = 0,
        manifestChunksDelivered = 0,
        manifestChunksReceived = 0,
        manifestCooldownSkips = 0,
        manifestUnchangedSkips = 0,
        manifestDeferredSends = 0,
        manifestPendingFlushes = 0,
        manifestQueueMaxDepth = 0,
        manifestBuildRequests = 0,
        manifestForceReplies = 0,
        manifestCatchupCandidates = 0,
        manifestCatchupQueued = 0,
        manifestCatchupDeferred = 0,
        manifestCatchupDrained = 0,
        manifestCatchupSkippedOnlineOwners = 0,
        manifestCatchupSkippedStaleOwners = 0,
        manifestCatchupMaxDeferred = 0,
        peerBackoffSkips = 0,
        peerBackoffApplied = 0,
        requestRetries = 0,
        requestDrops = 0,
        requestDispatches = 0,
        requestConcurrencyMax = 0,
        requestTimeoutInitial = 0,
        requestTimeoutProgress = 0,
        requestTimeoutSession = 0,
        rejectsTotal = 0,
        rejectsRetryable = 0,
        rejectsPermanent = 0,
        lastRejectPeer = nil,
        lastRejectReason = nil,
        skippedNotDataEligible = 0,
        queuedBackoff = 0,
        purgedBackoffRequests = 0,
        deferredBackoffRequests = 0,
        requestIdActive = nil,
        lastSelectedPeer = nil,
        lastSelectedReason = nil,
        rosterRefreshRequests = 0,
        manifestCompareDeferred = 0,
        warmupDeferrals = 0,
        transitionDeferrals = 0,
        transitionDrainSteps = 0,
        transitionSkippedHello = 0,
        transitionSkippedRosterRefresh = 0,
        transitionDeferredUI = 0,
        transitionDeferredTooltip = 0,
        transitionDeferredManifestPeers = 0,
        transitionDeferredCatchup = 0,
        coalescedManifestSchedules = 0,
        coalescedManifestFlushes = 0,
        catchupDrainDeferrals = 0,
        rosterEventsSeen = 0,
        rosterEventsCoalesced = 0,
        rosterPresenceOnlyUpdates = 0,
        rosterHeavyUpdates = 0,
        manifestIdenticalBlockSkips = 0,
        manifestEquivalentPeerSkips = 0,
        manifestRequestsAvoided = 0,
        snapshotIdenticalSkips = 0,
        snapshotMetadataOnlyApplies = 0,
        snapshotHeavyApplies = 0,
        cacheInvalidationsAvoided = 0,
        avoidedRequests = 0,
        avoidedCacheInvalidations = 0,
        releasedIncomingStates = 0,
        queueCapPrunes = 0,
        outboundChunkQueueMax = 0,
        manifestChunkQueueMax = 0,
        inboundChunkQueueMax = 0,
        inboundFinalizeQueueMax = 0,
        partialReceiveMax = 0,
        partialManifestReceiveMax = 0,
        pendingRequestMax = 0,
        runtimeQueuePressure = 0,
        prunedOutgoingSessions = 0,
        prunedPartialReceives = 0,
        prunedPartialManifestReceives = 0,
        partialManifestPruned = 0,
        prunedTricklePeerState = 0,
        prunedTrickleOutboundQueues = 0,
        duplicateCrafterRowsDetected = 0,
        duplicateCrafterRowsCollapsed = 0,
        lastDuplicateRecipeKey = nil,
        lastDuplicateMemberKey = nil,
        snapCodecEncoded = 0,
        snapCodecDecoded = 0,
        snapCodecSkippedSmall = 0,
        snapCodecFallbackNoLib = 0,
        snapCodecFallbackNoPeerCap = 0,
        snapCodecCompressErrors = 0,
        snapCodecEncodeErrors = 0,
        snapCodecDecodeNoLib = 0,
        snapCodecDecodeErrors = 0,
        snapCodecDecompressErrors = 0,
        snapCodecDeserializeErrors = 0,
        snapCodecDropped = 0,
        snapCodecRawBytes = 0,
        snapCodecEncodedBytes = 0,
        snapCodecMaxEncodeMs = 0,
        snapCodecMaxDecodeMs = 0,
        snapCodecTotalEncodeMs = 0,
        snapCodecTotalDecodeMs = 0,
    }
end

local function mergeRequestedBlocks(existing, incoming)
    if type(existing) ~= "table" or #existing == 0 then
        return cloneStringSet(incoming)
    end
    if type(incoming) ~= "table" or #incoming == 0 then
        return cloneStringSet(existing)
    end

    local seen = {}
    local merged = {}
    for _, blockKey in ipairs(existing) do
        if blockKey and not seen[blockKey] then
            seen[blockKey] = true
            merged[#merged + 1] = blockKey
        end
    end
    for _, blockKey in ipairs(incoming) do
        if blockKey and not seen[blockKey] then
            seen[blockKey] = true
            merged[#merged + 1] = blockKey
        end
    end
    sort(merged)
    return merged
end

local function cloneFingerprintMap(src)
    local out = {}
    for blockKey, fingerprint in pairs(src or {}) do
        if blockKey and fingerprint ~= nil then
            out[blockKey] = fingerprint
        end
    end
    return out
end

local function mergeExpectedFingerprints(existing, incoming)
    local merged = cloneFingerprintMap(existing)
    for blockKey, fingerprint in pairs(incoming or {}) do
        if blockKey and fingerprint ~= nil then
            merged[blockKey] = fingerprint
        end
    end
    return merged
end

local function sliceExpectedFingerprints(src, blockKeys)
    local out = {}
    for _, blockKey in ipairs(blockKeys or {}) do
        local fingerprint = src and src[blockKey] or nil
        if fingerprint ~= nil then
            out[blockKey] = fingerprint
        end
    end
    return out
end

local function cloneStringRange(src, firstIndex, lastIndex)
    local out = {}
    local finalIndex = min(lastIndex or #(src or {}), #(src or {}))
    for index = firstIndex or 1, finalIndex do
        if src[index] then
            out[#out + 1] = src[index]
        end
    end
    return out
end

local function isMockKey(memberKey)
    return type(memberKey) == "string"
        and (memberKey:find("__RRMockPeer", 1, true) == 1 or memberKey:find("__RRMockOwner", 1, true) == 1)
end

Private.constants = {
    PREFIX = PREFIX,
    REQUEST_TIMEOUT = REQUEST_TIMEOUT,
    PROGRESS_TIMEOUT = PROGRESS_TIMEOUT,
    SESSION_TIMEOUT = SESSION_TIMEOUT,
    NODE_TIMEOUT = NODE_TIMEOUT,
    HELLO_INTERVAL = HELLO_INTERVAL,
    AUTO_SYNC_INTERVAL = AUTO_SYNC_INTERVAL,
    OUTGOING_CHUNK_DELAY = OUTGOING_CHUNK_DELAY,
    MANIFEST_CHUNK_DELAY = MANIFEST_CHUNK_DELAY,
    MANIFEST_INITIAL_JITTER = MANIFEST_INITIAL_JITTER,
    MAX_RESUME_ATTEMPTS = MAX_RESUME_ATTEMPTS,
    COORDINATOR_RECOMPUTE_DELAY = COORDINATOR_RECOMPUTE_DELAY,
    MANIFEST_PUSH_COOLDOWN = MANIFEST_PUSH_COOLDOWN,
    MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH = MANIFEST_CATCHUP_OWNER_CAP_PER_FLUSH,
    MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH = MANIFEST_CATCHUP_BLOCK_CAP_PER_FLUSH,
    MANIFEST_CATCHUP_DRAIN_DELAY = MANIFEST_CATCHUP_DRAIN_DELAY,
    MAX_REQUEST_RETRIES = MAX_REQUEST_RETRIES,
    MAX_HELLO_AUTO_RETRIES = MAX_HELLO_AUTO_RETRIES,
    MAX_CONCURRENT_REQUESTS = MAX_CONCURRENT_REQUESTS,
    ROSTER_FRESHNESS_MAX_AGE = ROSTER_FRESHNESS_MAX_AGE,
    ROSTER_REFRESH_REQUEST_COOLDOWN = ROSTER_REFRESH_REQUEST_COOLDOWN,
    PEER_BACKOFF_SECONDS = PEER_BACKOFF_SECONDS,
    HELLO_AUTO_BACKOFF_SECONDS = HELLO_AUTO_BACKOFF_SECONDS,
    PEER_BACKOFF_FAILURE_THRESHOLD = PEER_BACKOFF_FAILURE_THRESHOLD,
    MANIFEST_REFRESH_REQUEST_COOLDOWN = MANIFEST_REFRESH_REQUEST_COOLDOWN,
    POST_WORLD_GRACE_SECONDS = POST_WORLD_GRACE_SECONDS,
    POST_INSTANCE_GRACE_SECONDS = POST_INSTANCE_GRACE_SECONDS,
    POST_RELOAD_IN_INSTANCE_GRACE_SECONDS = POST_RELOAD_IN_INSTANCE_GRACE_SECONDS,
    POST_COMBAT_GRACE_SECONDS = POST_COMBAT_GRACE_SECONDS,
    MANIFEST_MERGE_ANNOUNCE_DEBOUNCE = MANIFEST_MERGE_ANNOUNCE_DEBOUNCE,
    MANIFEST_MERGE_ANNOUNCE_MAX_DELAY = MANIFEST_MERGE_ANNOUNCE_MAX_DELAY,
    OFFLINE_DEBUG_LOG_LIMIT = OFFLINE_DEBUG_LOG_LIMIT,
    MAX_OUTBOUND_CHUNKS = MAX_OUTBOUND_CHUNKS,
    MAX_MANIFEST_CHUNKS = MAX_MANIFEST_CHUNKS,
    MAX_INBOUND_CHUNKS = MAX_INBOUND_CHUNKS,
    MAX_INBOUND_FINALIZE_QUEUE = MAX_INBOUND_FINALIZE_QUEUE,
    MAX_PARTIAL_RECEIVES = MAX_PARTIAL_RECEIVES,
    MAX_PARTIAL_MANIFESTS_TOTAL = MAX_PARTIAL_MANIFESTS_TOTAL,
    MAX_PARTIAL_MANIFESTS_PER_PEER = MAX_PARTIAL_MANIFESTS_PER_PEER,
    MAX_MANIFEST_CATCHUP_QUEUE = MAX_MANIFEST_CATCHUP_QUEUE,
    MAX_PENDING_REQUESTS = MAX_PENDING_REQUESTS,
    SNAP_CODEC_ENABLED = SNAP_CODEC_ENABLED,
    SNAP_CODEC_MIN_BYTES = SNAP_CODEC_MIN_BYTES,
    SNAP_CODEC_ID = SNAP_CODEC_ID,
}
Private.countKeys = countKeys
Private.nowForPacing = nowForPacing
Private.shallowCopyArray = shallowCopyArray
Private.shallowCopyTable = shallowCopyTable
Private.getManifestAnnouncementId = getManifestAnnouncementId
Private.countArrayUnique = countArrayUnique
Private.cloneStringSet = cloneStringSet
Private.isHelloAutoReason = isHelloAutoReason
Private.isManualReason = isManualReason
Private.addRetrySuffix = addRetrySuffix
Private.newSyncTelemetry = newSyncTelemetry
Private.mergeRequestedBlocks = mergeRequestedBlocks
Private.cloneFingerprintMap = cloneFingerprintMap
Private.mergeExpectedFingerprints = mergeExpectedFingerprints
Private.sliceExpectedFingerprints = sliceExpectedFingerprints
Private.cloneStringRange = cloneStringRange
Private.isMockKey = isMockKey

function Sync:Startup()
    self:RegisterComm(PREFIX)
    self:EnterWarmup("startup", POST_WORLD_GRACE_SECONDS)
    self:ScheduleHello(1)
    self.helloTicker = self:ScheduleRepeatingTimer("BroadcastHello", HELLO_INTERVAL)
    self.queueTicker = self:ScheduleRepeatingTimer("ProcessRequestQueue", 1)
    self.pruneTicker = self:ScheduleRepeatingTimer("PruneState", 5)
    self.autoSyncTicker = self:ScheduleRepeatingTimer("AutoSyncTick", AUTO_SYNC_INTERVAL)
    self:ScheduleTimer("AutoSyncTick", 6)
    self:AdvertiseLocalRevision("startup")
    self:EnsureBackgroundWorkers()
    if Addon.Data and Addon.Data.ScheduleManifestBuild then
        Addon.Data:ScheduleManifestBuild("startup")
    end
end

function Sync:GetSelfKey()
    return Addon.Data:GetPlayerKey()
end

function Sync:GetWhisperTarget(memberKey)
    if not memberKey then return nil end
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
    if isMockKey(memberKey) then return true end
    local row = memberKey and self.registry and self.registry[memberKey] or nil
    return row and row.isMock == true or false
end

function Sync:IsValidSyncMemberKey(memberKey)
    if Addon.Data and Addon.Data.IsValidMemberKey then
        return Addon.Data:IsValidMemberKey(memberKey)
    end
    return type(memberKey) == "string"
        and memberKey ~= ""
        and not memberKey:find(":", 1, true)
        and memberKey:find("-", 1, true) ~= nil
end

function Sync:IsLocallyStaleOwner(ownerCharacter)
    local entry = Addon.Data and Addon.Data.GetMember and Addon.Data:GetMember(ownerCharacter) or nil
    return entry and (entry.guildStatus or "active") ~= "active" or false
end
