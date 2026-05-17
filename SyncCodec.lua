local Addon = _G.RecipeRegistry
local Sync = Addon.Sync

local function cloneCapabilities(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value == true
    end
    return out
end

function Sync:GetLocalProtocolCaps()
    local protocolPaused = Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_PULL_REQUEST") or false
    return {
        wireVersion = Addon.WIRE_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = cloneCapabilities(Addon.CAPABILITIES),
        chunkWindow = Addon.CAPABILITIES and Addon.CAPABILITIES.chunkWindow == true or false,
        indexDiffSync = Addon.CAPABILITIES and Addon.CAPABILITIES.indexDiffSync == true or false,
        blockPullSync = Addon.CAPABILITIES and Addon.CAPABILITIES.blockPullSync == true or false,
        canReceiveReq = not protocolPaused,
        canSendSnap = not protocolPaused,
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
        chunkWindow = caps.chunkWindow == true,
        indexDiffSync = caps.indexDiffSync == true,
        blockPullSync = caps.blockPullSync == true,
        canReceiveReq = caps.canReceiveReq ~= false,
        canSendSnap = caps.canSendSnap ~= false,
        isPausedForSync = caps.isPausedForSync == true,
    }
end

function Sync:GetPeerCaps(peerKey)
    return self.peerCaps and self.peerCaps[peerKey] or nil
end
