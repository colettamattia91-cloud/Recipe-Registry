local Addon = _G.RecipeRegistry
local Addon = _G.RecipeRegistry
local BuildInfo = Addon.BuildInfo or {}

Addon.BuildInfo = BuildInfo

local function getMetadata(field)
    if type(GetAddOnMetadata) ~= "function" then
        return nil
    end
    local ok, value = pcall(GetAddOnMetadata, "RecipeRegistry", field)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function normalizeChannel(value)
    local channel = tostring(value or ""):lower()
    if channel == "dev" then
        return "dev"
    end
    -- The 2.0.0 line only supports release/dev channels. Any legacy beta tag
    -- is treated as release so it cannot drift into a half-supported channel.
    return "release"
end

local function cloneTable(src)
    local out = {}
    for key, value in pairs(src or {}) do
        if type(value) == "table" then
            local nested = {}
            for nestedKey, nestedValue in pairs(value) do
                nested[nestedKey] = nestedValue
            end
            out[key] = nested
        else
            out[key] = value
        end
    end
    return out
end

local function parseVersion(text)
    if type(text) ~= "string" then
        return nil
    end
    local parts = {}
    for piece in text:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(piece) or 0
    end
    if #parts == 0 then
        return nil
    end
    return parts
end

function BuildInfo.CompareSemver(left, right)
    local a = parseVersion(left)
    local b = parseVersion(right)
    if not a or not b then
        return nil
    end
    local maxParts = math.max(#a, #b)
    for index = 1, maxParts do
        local av = a[index] or 0
        local bv = b[index] or 0
        if av ~= bv then
            return av > bv and 1 or -1
        end
    end
    return 0
end

function BuildInfo.IsRemoteNewer(remoteVersion, localVersion)
    local cmp = BuildInfo.CompareSemver(remoteVersion, localVersion)
    return cmp ~= nil and cmp > 0 or false
end

Addon.ADDON_VERSION = tostring(Addon.ADDON_VERSION or getMetadata("Version") or Addon.DISPLAY_VERSION or "2.0.0")
Addon.DISPLAY_VERSION = Addon.ADDON_VERSION
Addon.WIRE_VERSION = tonumber(Addon.WIRE_VERSION) or 3
Addon.MIN_SUPPORTED_WIRE_VERSION = tonumber(Addon.MIN_SUPPORTED_WIRE_VERSION) or Addon.WIRE_VERSION
Addon.BUILD_CHANNEL = normalizeChannel(Addon.BUILD_CHANNEL or getMetadata("X-Build-Channel") or "release")
Addon.BUILD_ID = Addon.BUILD_ID or getMetadata("X-Build-ID")
Addon.RELEASE_COMM_PREFIX = Addon.RELEASE_COMM_PREFIX or "RecipeRegistry"
Addon.DEV_COMM_PREFIX = Addon.DEV_COMM_PREFIX or "RRDEV"
Addon.COMM_PREFIX = Addon.BUILD_CHANNEL == "dev" and Addon.DEV_COMM_PREFIX or Addon.RELEASE_COMM_PREFIX
Addon.ADDON_PREFIX = Addon.COMM_PREFIX

if Addon.ALLOW_LEGACY_RELEASE_PEERS == nil then
    Addon.ALLOW_LEGACY_RELEASE_PEERS = Addon.BUILD_CHANNEL == "release"
end

Addon.CAPABILITIES = cloneTable(Addon.CAPABILITIES or {
    chunkWindow = true,
    maniReliable = true,
    snapCodec = true,
    manifestShards = false,
})

function BuildInfo.GetLocalVersionInfo()
    return {
        addonVersion = Addon.ADDON_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        minSupportedWireVersion = Addon.MIN_SUPPORTED_WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        commPrefix = Addon.COMM_PREFIX,
        capabilities = cloneTable(Addon.CAPABILITIES),
        allowLegacyReleasePeers = Addon.ALLOW_LEGACY_RELEASE_PEERS == true,
    }
end
