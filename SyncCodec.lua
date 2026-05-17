local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local type = type
local pcall = pcall

local SNAP_CODEC_ENABLED = Constants.SNAP_CODEC_ENABLED
local SNAP_CODEC_ID = Constants.SNAP_CODEC_ID

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

local function getLibrary(name)
    local ok, lib = pcall(LibStub, name, true)
    if ok and lib then
        return lib
    end
    ok, lib = pcall(LibStub, name)
    if ok then
        return lib
    end
    return nil
end

function Sync:IsSnapshotCodecEnabled()
    if SNAP_CODEC_ENABLED ~= true then
        return false
    end
    return self.snapCodecEnabled ~= false
end

function Sync:GetSnapshotCodecSupport()
    if not self:IsSnapshotCodecEnabled() then
        return nil
    end

    local serialize = getLibrary("LibSerialize")
    local deflate = getLibrary("LibDeflate")
    if not serialize or not deflate then
        return nil
    end

    return {
        id = SNAP_CODEC_ID,
        serialize = serialize,
        deflate = deflate,
    }
end

function Sync:GetLocalSnapshotCodecId()
    local codec = self:GetSnapshotCodecSupport()
    return codec and codec.id or nil
end

function Sync:GetLocalProtocolCaps()
    local codecId = self:GetLocalSnapshotCodecId()
    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "protocol-caps",
    }) or {}
    local protocolPaused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_PULL_REQUEST") or false
    return {
        wireVersion = Addon.WIRE_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = cloneCapabilities(Addon.CAPABILITIES),
        chunkWindow = Addon.CAPABILITIES and Addon.CAPABILITIES.chunkWindow == true or false,
        maniReliable = Addon.CAPABILITIES and Addon.CAPABILITIES.maniReliable == true or false,
        indexDiffSync = Addon.CAPABILITIES and Addon.CAPABILITIES.indexDiffSync == true or false,
        blockPullSync = Addon.CAPABILITIES and Addon.CAPABILITIES.blockPullSync == true or false,
        manifestShards = Addon.CAPABILITIES and Addon.CAPABILITIES.manifestShards == true or false,
        snapCodecCap = Addon.CAPABILITIES and Addon.CAPABILITIES.snapCodec == true or false,
        canReceiveReq = not protocolPaused,
        canSendSnap = not protocolPaused,
        snapCodec = codecId,
        snapCodecSupported = codecId ~= nil,
        snapCodecMin = 1,
        isPausedForSync = protocolPaused,
        localBlockCount = summary.activeBlockCount or summary.professions or 0,
        localRecipeCount = summary.activeContentCount or summary.recipes or 0,
        localOwnerCount = summary.activeOwnerCount or 0,
        globalFingerprint = summary.globalFingerprint,
        indexStatus = summary.indexStatus,
        syncModel = summary.syncModel,
        lastSnapshotSuccessAt = self.lastSnapshotSuccessAt or 0,
        lastSnapshotServedAt = self.lastSnapshotServedAt or 0,
    }
end

function Sync:RecordPeerCaps(peerKey, caps)
    if not self:IsValidSyncMemberKey(peerKey) then
        return
    end
    self.peerCaps = self.peerCaps or {}
    if type(caps) ~= "table" then
        self.peerCaps[peerKey] = nil
        return
    end
    self.peerCaps[peerKey] = {
        wireVersion = caps.wireVersion,
        addonVersion = caps.addonVersion,
        buildChannel = caps.buildChannel,
        buildId = caps.buildId,
        capabilities = cloneCapabilities(caps.capabilities),
        chunkWindow = caps.chunkWindow,
        maniReliable = caps.maniReliable,
        indexDiffSync = caps.indexDiffSync,
        blockPullSync = caps.blockPullSync,
        manifestShards = caps.manifestShards,
        snapCodecCap = caps.snapCodecCap,
        canReceiveReq = caps.canReceiveReq,
        canSendSnap = caps.canSendSnap,
        snapCodec = caps.snapCodec,
        snapCodecSupported = caps.snapCodecSupported,
        snapCodecMin = caps.snapCodecMin,
        isPausedForSync = caps.isPausedForSync,
        localBlockCount = caps.localBlockCount,
        localRecipeCount = caps.localRecipeCount,
        localOwnerCount = caps.localOwnerCount,
        globalFingerprint = caps.globalFingerprint,
        indexStatus = caps.indexStatus,
        syncModel = caps.syncModel,
        lastSnapshotSuccessAt = caps.lastSnapshotSuccessAt,
        lastSnapshotServedAt = caps.lastSnapshotServedAt,
    }
end

function Sync:GetPeerCaps(peerKey)
    return self.peerCaps and self.peerCaps[peerKey] or nil
end
