local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local BuildInfo = {}
Addon.BuildInfo = BuildInfo

-- Reads a string field from the addon's TOC. Handles both the modern
-- C_AddOns.GetAddOnMetadata and the legacy global, since TBC Classic
-- has been moving between the two and dev clients may run either.
local function getMetadata(field)
    if type(C_AddOns) == "table" and type(C_AddOns.GetAddOnMetadata) == "function" then
        local ok, value = pcall(C_AddOns.GetAddOnMetadata, ADDON_NAME, field)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    if type(GetAddOnMetadata) == "function" then
        local ok, value = pcall(GetAddOnMetadata, ADDON_NAME, field)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function normalizeChannel(value)
    local channel = tostring(value or ""):lower()
    if channel == "dev" then return "dev" end
    return "release"
end

-- Wire protocol identity. WIRE_VERSION starts at 1 because the order
-- subsystem is its own protocol — completely independent from RR's
-- recipe sync (currently at wire v3). MIN_SUPPORTED_WIRE_VERSION is
-- the floor: any peer below this is ignored as "too old".
Addon.WIRE_VERSION              = 1
Addon.MIN_SUPPORTED_WIRE_VERSION = 1

-- Build channel + comm prefix. The dev/release split keeps two clients
-- running incompatible iterations from accidentally chatting. RR uses
-- the same pattern with "RecipeRegistry" / "RRDEV"; we use "RRORD" /
-- "RRORDDEV" so order traffic is distinguishable from recipe sync on
-- the addon comm channel even when both addons are active.
Addon.BUILD_CHANNEL       = normalizeChannel(getMetadata("X-Build-Channel"))
Addon.BUILD_ID            = getMetadata("X-Build-ID")
Addon.RELEASE_COMM_PREFIX = "RRORD"
Addon.DEV_COMM_PREFIX     = "RRORDDEV"
Addon.COMM_PREFIX         = Addon.BUILD_CHANNEL == "dev"
    and Addon.DEV_COMM_PREFIX or Addon.RELEASE_COMM_PREFIX

function BuildInfo:GetLocalVersionInfo()
    return {
        addonVersion             = Addon.ADDON_VERSION,
        wireVersion              = Addon.WIRE_VERSION,
        minSupportedWireVersion  = Addon.MIN_SUPPORTED_WIRE_VERSION,
        buildChannel             = Addon.BUILD_CHANNEL,
        buildId                  = Addon.BUILD_ID,
        commPrefix               = Addon.COMM_PREFIX,
    }
end
