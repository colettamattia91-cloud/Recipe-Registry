local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Codec = {}
Addon.Codec = Codec

-- Wire codec: AceSerializer + optional LibDeflate compression. Mirrors
-- the pattern in RR's Sync/SyncCodec.lua so behaviour is familiar, but
-- ships under the plugin's own namespace per docs/recipe-registry-public-api.md
-- §3.7 ("plugin owns its own thin codec, no cross-addon coupling").
--
-- Payloads below COMPRESS_MIN_SIZE bytes ship uncompressed (raw
-- AceSerializer output, which always starts with "^1"). Larger
-- payloads are deflated and then ASCII-encoded for the addon comm
-- channel; those start with COMPRESS_MARKER so the receiver picks the
-- correct decode path. Marker has no overlap with AceSerializer's
-- leading "^" character.
local COMPRESS_MARKER     = "RRO1|"
local COMPRESS_MARKER_LEN = #COMPRESS_MARKER
local COMPRESS_MIN_SIZE   = 256
local COMPRESS_LEVEL      = 6

local function getDeflate()
    return LibStub("LibDeflate", true)
end

local function getSerializer()
    return LibStub("AceSerializer-3.0")
end

-- Encodes a Lua table into the on-wire string. Returns the encoded
-- string, or nil on failure (e.g. missing serializer). In the test
-- harness's "table-fast" payload mode the serializer returns the
-- table directly; the codec passes it through so specs can compare
-- structures without round-tripping bytes.
function Codec:Encode(payload)
    local serializer = getSerializer()
    if not serializer then return nil end
    local serialized = serializer:Serialize(payload)
    if serialized == nil then return nil end
    if type(serialized) ~= "string" then return serialized end
    if serialized == "" then return nil end
    if #serialized < COMPRESS_MIN_SIZE then return serialized end

    local deflate = getDeflate()
    if not deflate then return serialized end
    local compressed = deflate:CompressDeflate(serialized, { level = COMPRESS_LEVEL })
    if type(compressed) ~= "string" or compressed == "" then return serialized end
    local encoded = deflate:EncodeForWoWAddonChannel(compressed)
    if type(encoded) ~= "string" or encoded == "" then return serialized end
    local wrapped = COMPRESS_MARKER .. encoded
    -- If compression didn't actually shrink the payload (small or noisy
    -- inputs) fall back to plain serialization to avoid framing waste.
    if #wrapped >= #serialized then return serialized end
    return wrapped
end

-- Decodes an on-wire string back into a Lua table. Returns the table
-- on success or nil on any failure (malformed input, missing libs,
-- deserialize error). Passes table inputs through unchanged for the
-- test harness's table-fast mode.
function Codec:Decode(text)
    if type(text) == "table" then return text end
    if type(text) ~= "string" or text == "" then return nil end

    local serializer = getSerializer()
    if not serializer then return nil end

    if text:sub(1, COMPRESS_MARKER_LEN) == COMPRESS_MARKER then
        local deflate = getDeflate()
        if not deflate then return nil end
        local decoded = deflate:DecodeForWoWAddonChannel(text:sub(COMPRESS_MARKER_LEN + 1))
        if type(decoded) ~= "string" or decoded == "" then return nil end
        local decompressed = deflate:DecompressDeflate(decoded)
        if type(decompressed) ~= "string" or decompressed == "" then return nil end
        local ok, payload = serializer:Deserialize(decompressed)
        if not ok then return nil end
        return payload
    end

    local ok, payload = serializer:Deserialize(text)
    if not ok then return nil end
    return payload
end

Codec.COMPRESS_MARKER   = COMPRESS_MARKER
Codec.COMPRESS_MIN_SIZE = COMPRESS_MIN_SIZE
