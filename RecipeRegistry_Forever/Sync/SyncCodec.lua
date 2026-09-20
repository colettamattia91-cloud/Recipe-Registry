local Addon = _G.RecipeRegistry
local Sync = Addon.Sync

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

-- Wire codec: AceSerializer + optional LibDeflate compression.
-- Payloads below COMPRESS_MIN_SIZE bytes are sent uncompressed (raw AceSerializer
-- output, which always starts with "^1"). Larger payloads are deflated and then
-- ASCII-encoded for the addon comm channel; those start with COMPRESS_MARKER so
-- the receiver can pick the right decode path. Marker has no overlap with
-- AceSerializer's leading "^" character.
local COMPRESS_MARKER = "RR1|"
local COMPRESS_MARKER_LEN = #COMPRESS_MARKER
local COMPRESS_MIN_SIZE = 256
local COMPRESS_LEVEL = 6

local function getDeflate()
    return LibStub("LibDeflate", true)
end

local function getSerializer()
    return LibStub("AceSerializer-3.0")
end

function Sync:EncodeWirePayload(payload)
    local serializer = getSerializer()
    if not serializer then
        return nil
    end
    local serialized = serializer:Serialize(payload)
    if serialized == nil then
        return nil
    end
    -- Test harness can run in "table-fast" payload mode where Serialize returns
    -- the payload table directly. In that case there's nothing to compress —
    -- forward the raw value so the bus can dispatch it.
    if type(serialized) ~= "string" then
        return serialized
    end
    if serialized == "" then
        return nil
    end
    if #serialized < COMPRESS_MIN_SIZE then
        return serialized
    end
    local deflate = getDeflate()
    if not deflate then
        return serialized
    end
    local compressed = deflate:CompressDeflate(serialized, { level = COMPRESS_LEVEL })
    if type(compressed) ~= "string" or compressed == "" then
        return serialized
    end
    local encoded = deflate:EncodeForWoWAddonChannel(compressed)
    if type(encoded) ~= "string" or encoded == "" then
        return serialized
    end
    local wrapped = COMPRESS_MARKER .. encoded
    -- If compression didn't actually save bytes (small or noisy payloads),
    -- fall back to plain serialization to avoid useless framing overhead.
    if #wrapped >= #serialized then
        return serialized
    end
    if self.telemetry then
        self.telemetry.wireCompressedSent = (self.telemetry.wireCompressedSent or 0) + 1
        self.telemetry.wireBytesRaw = (self.telemetry.wireBytesRaw or 0) + #serialized
        self.telemetry.wireBytesOnWire = (self.telemetry.wireBytesOnWire or 0) + #wrapped
    end
    return wrapped
end

function Sync:DecodeWirePayload(text)
    -- Test harness "table-fast" mode delivers the payload table directly; pass
    -- it through so callers see the expected shape.
    if type(text) == "table" then
        return text
    end
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local serializer = getSerializer()
    if not serializer then
        return nil
    end
    if text:sub(1, COMPRESS_MARKER_LEN) == COMPRESS_MARKER then
        local deflate = getDeflate()
        if not deflate then
            return nil
        end
        local decoded = deflate:DecodeForWoWAddonChannel(text:sub(COMPRESS_MARKER_LEN + 1))
        if type(decoded) ~= "string" or decoded == "" then
            return nil
        end
        local decompressed = deflate:DecompressDeflate(decoded)
        if type(decompressed) ~= "string" or decompressed == "" then
            return nil
        end
        local ok, payload = serializer:Deserialize(decompressed)
        if not ok then
            return nil
        end
        if self.telemetry then
            self.telemetry.wireCompressedReceived = (self.telemetry.wireCompressedReceived or 0) + 1
        end
        return payload
    end
    local ok, payload = serializer:Deserialize(text)
    if not ok then
        return nil
    end
    return payload
end

function Sync:GetLocalProtocolCaps()
    local protocolPaused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_PULL_REQUEST") or false
    return {
        wireVersion = Addon.WIRE_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = cloneCapabilities(Addon.CAPABILITIES),
        indexDiffSync = Addon.CAPABILITIES and Addon.CAPABILITIES.indexDiffSync == true or false,
        blockPullSync = Addon.CAPABILITIES and Addon.CAPABILITIES.blockPullSync == true or false,
        canReceiveBlockPull = not protocolPaused,
        canSendBlockSnapshot = not protocolPaused,
        isPausedForSync = protocolPaused,
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
        indexDiffSync = caps.indexDiffSync == true,
        blockPullSync = caps.blockPullSync == true,
        canReceiveBlockPull = caps.canReceiveBlockPull ~= false,
        canSendBlockSnapshot = caps.canSendBlockSnapshot ~= false,
        isPausedForSync = caps.isPausedForSync == true,
    }
end

function Sync:GetPeerCaps(peerKey)
    return self.peerCaps and self.peerCaps[peerKey] or nil
end
