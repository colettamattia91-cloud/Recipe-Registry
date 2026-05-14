local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local type = type
local pcall = pcall
local max = math.max

local SNAP_CODEC_ENABLED = Constants.SNAP_CODEC_ENABLED
local SNAP_CODEC_MIN_BYTES = Constants.SNAP_CODEC_MIN_BYTES
local SNAP_CODEC_ID = Constants.SNAP_CODEC_ID

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

local function nowMs()
    if type(debugprofilestop) == "function" then
        return debugprofilestop()
    end
    if type(GetTime) == "function" then
        return GetTime() * 1000
    end
    return 0
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
    local summary = Addon.Data and Addon.Data.GetLocalSummary and Addon.Data:GetLocalSummary() or {}
    local protocolPaused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("REQ") or false
    return {
        wireVersion = Addon.WIRE_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = cloneCapabilities(Addon.CAPABILITIES),
        chunkWindow = Addon.CAPABILITIES and Addon.CAPABILITIES.chunkWindow == true or false,
        maniReliable = Addon.CAPABILITIES and Addon.CAPABILITIES.maniReliable == true or false,
        manifestShards = Addon.CAPABILITIES and Addon.CAPABILITIES.manifestShards == true or false,
        snapCodecCap = Addon.CAPABILITIES and Addon.CAPABILITIES.snapCodec == true or false,
        canReceiveReq = not protocolPaused,
        canSendSnap = not protocolPaused,
        snapCodec = codecId,
        snapCodecSupported = codecId ~= nil,
        snapCodecMin = 1,
        isPausedForSync = protocolPaused,
        localBlockCount = summary.professions or 0,
        localRecipeCount = summary.recipes or 0,
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
        lastSnapshotSuccessAt = caps.lastSnapshotSuccessAt,
        lastSnapshotServedAt = caps.lastSnapshotServedAt,
    }
end

function Sync:GetPeerCaps(peerKey)
    return self.peerCaps and self.peerCaps[peerKey] or nil
end

function Sync:ShouldUseSnapshotCodec(_targetKey, opts)
    opts = opts or {}
    local codec = self:GetSnapshotCodecSupport()
    if not codec then
        self.telemetry.snapCodecFallbackNoLib = (self.telemetry.snapCodecFallbackNoLib or 0) + 1
        return false, nil
    end
    if opts.acceptSnapCodec ~= codec.id then
        self.telemetry.snapCodecFallbackNoPeerCap = (self.telemetry.snapCodecFallbackNoPeerCap or 0) + 1
        return false, codec
    end
    return true, codec
end

function Sync:EncodeSnapshotBlockForWire(block, targetKey, opts)
    if type(block) ~= "table" then
        return block, "legacy"
    end

    local shouldUse, codec = self:ShouldUseSnapshotCodec(targetKey, opts)
    if not shouldUse or not codec then
        return block, "legacy"
    end

    local body = {
        sourceType = block.sourceType,
        profession = block.profession,
        skillRank = block.skillRank,
        skillMaxRank = block.skillMaxRank,
        specialization = block.specialization,
        recipeKeys = block.recipeKeys or {},
    }

    local startedAt = nowMs()
    local okSerialize, serialized = pcall(codec.serialize.Serialize, codec.serialize, body)
    if not okSerialize or type(serialized) ~= "string" then
        self.telemetry.snapCodecCompressErrors = (self.telemetry.snapCodecCompressErrors or 0) + 1
        return block, "legacy"
    end
    if #serialized < SNAP_CODEC_MIN_BYTES then
        self.telemetry.snapCodecSkippedSmall = (self.telemetry.snapCodecSkippedSmall or 0) + 1
        return block, "legacy"
    end

    local okCompress, compressed = pcall(codec.deflate.CompressDeflate, codec.deflate, serialized)
    if not okCompress or type(compressed) ~= "string" then
        self.telemetry.snapCodecCompressErrors = (self.telemetry.snapCodecCompressErrors or 0) + 1
        return block, "legacy"
    end

    local okEncode, encoded = pcall(codec.deflate.EncodeForWoWAddonChannel, codec.deflate, compressed)
    if not okEncode or type(encoded) ~= "string" then
        self.telemetry.snapCodecEncodeErrors = (self.telemetry.snapCodecEncodeErrors or 0) + 1
        return block, "legacy"
    end

    local elapsed = max(0, nowMs() - startedAt)
    self.telemetry.snapCodecEncoded = (self.telemetry.snapCodecEncoded or 0) + 1
    self.telemetry.snapCodecRawBytes = (self.telemetry.snapCodecRawBytes or 0) + #serialized
    self.telemetry.snapCodecEncodedBytes = (self.telemetry.snapCodecEncodedBytes or 0) + #encoded
    self.telemetry.snapCodecTotalEncodeMs = (self.telemetry.snapCodecTotalEncodeMs or 0) + elapsed
    if elapsed > (self.telemetry.snapCodecMaxEncodeMs or 0) then
        self.telemetry.snapCodecMaxEncodeMs = elapsed
    end

    return {
        sessionId = block.sessionId,
        key = block.key,
        rev = block.rev,
        updatedAt = block.updatedAt,
        seq = block.seq,
        total = block.total,
        codec = codec.id,
        rawBytes = #serialized,
        encodedBytes = #encoded,
        blob = encoded,
    }, codec.id
end

function Sync:DecodeSnapshotBlockFromWire(payload)
    if type(payload) ~= "table" or not payload.codec then
        return payload, true
    end
    if payload.codec ~= SNAP_CODEC_ID then
        self.telemetry.snapCodecDecodeErrors = (self.telemetry.snapCodecDecodeErrors or 0) + 1
        return nil, false, "unsupported-codec"
    end

    local codec = self:GetSnapshotCodecSupport()
    if not codec then
        self.telemetry.snapCodecDecodeNoLib = (self.telemetry.snapCodecDecodeNoLib or 0) + 1
        return nil, false, "missing-codec-lib"
    end
    if type(payload.blob) ~= "string" then
        self.telemetry.snapCodecDecodeErrors = (self.telemetry.snapCodecDecodeErrors or 0) + 1
        return nil, false, "missing-blob"
    end

    local startedAt = nowMs()
    local okDecode, compressed = pcall(codec.deflate.DecodeForWoWAddonChannel, codec.deflate, payload.blob)
    if not okDecode or type(compressed) ~= "string" then
        self.telemetry.snapCodecDecodeErrors = (self.telemetry.snapCodecDecodeErrors or 0) + 1
        return nil, false, "addon-channel-decode-failed"
    end

    local okDecompress, serialized = pcall(codec.deflate.DecompressDeflate, codec.deflate, compressed)
    if not okDecompress or type(serialized) ~= "string" then
        self.telemetry.snapCodecDecompressErrors = (self.telemetry.snapCodecDecompressErrors or 0) + 1
        return nil, false, "decompress-failed"
    end

    local okDeserialize, success, body = pcall(codec.serialize.Deserialize, codec.serialize, serialized)
    if not okDeserialize or not success or type(body) ~= "table" then
        self.telemetry.snapCodecDeserializeErrors = (self.telemetry.snapCodecDeserializeErrors or 0) + 1
        return nil, false, "deserialize-failed"
    end
    if body.recipeKeys ~= nil and type(body.recipeKeys) ~= "table" then
        self.telemetry.snapCodecDeserializeErrors = (self.telemetry.snapCodecDeserializeErrors or 0) + 1
        return nil, false, "invalid-recipe-keys"
    end

    local elapsed = max(0, nowMs() - startedAt)
    self.telemetry.snapCodecDecoded = (self.telemetry.snapCodecDecoded or 0) + 1
    self.telemetry.snapCodecTotalDecodeMs = (self.telemetry.snapCodecTotalDecodeMs or 0) + elapsed
    if elapsed > (self.telemetry.snapCodecMaxDecodeMs or 0) then
        self.telemetry.snapCodecMaxDecodeMs = elapsed
    end

    return {
        sessionId = payload.sessionId,
        key = payload.key,
        rev = payload.rev,
        updatedAt = payload.updatedAt,
        sourceType = body.sourceType,
        profession = body.profession,
        skillRank = body.skillRank,
        skillMaxRank = body.skillMaxRank,
        specialization = body.specialization,
        recipeKeys = body.recipeKeys or {},
        seq = payload.seq,
        total = payload.total,
        sender = payload.sender,
        sentAt = payload.sentAt,
    }, true
end
