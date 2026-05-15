local Addon = _G.RecipeRegistry
local TrickleSync = Addon:NewModule("TrickleSync")
Addon.TrickleSync = TrickleSync

local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local time = time

local MANIFEST_BLOCKS_PER_CHUNK = 24
local TRICKLE_OUTBOUND_QUEUE_PER_PEER_CAP = 96
local TRICKLE_OUTBOUND_QUEUE_GLOBAL_CAP = 384

local function getValidManifestBlockParts(blockKey, block)
    if not Addon.Data or not Addon.Data.ParseSyncBlockKey then return nil, nil end
    local ownerCharacter, professionKey = Addon.Data:ParseSyncBlockKey(blockKey)
    if not Addon.Data:IsValidMemberKey(ownerCharacter) then return nil, nil end
    if type(professionKey) ~= "string" or professionKey == "" then return nil, nil end
    if block and block.ownerCharacter and block.ownerCharacter ~= ownerCharacter then return nil, nil end
    if block and block.professionKey and block.professionKey ~= professionKey then return nil, nil end
    return ownerCharacter, professionKey
end

function TrickleSync:OnInitialize()
    self.peerState = {}
    self.outboundQueue = {}
    self._manifestChunkCache = nil
    self.telemetry = {
        chunkBuilds = 0,
        chunkCacheHits = 0,
        chunkInvalidations = 0,
        queueCapHits = 0,
        queueCapDrops = 0,
        lastInvalidationReason = "none",
    }
end

function TrickleSync:BuildLocalManifest(opts)
    if Addon.Data and Addon.Data.GetPreparedSyncManifest then
        return Addon.Data:GetPreparedSyncManifest(opts or { allowStale = true, syncFallback = true, reason = "trickle" })
    end
    return Addon.Data:BuildSyncManifest(false), "built"
end

function TrickleSync:InvalidateManifestChunkCache(reason)
    self._manifestChunkCache = nil
    self.telemetry = self.telemetry or {}
    self.telemetry.chunkInvalidations = (self.telemetry.chunkInvalidations or 0) + 1
    self.telemetry.lastInvalidationReason = reason or "unknown"
end

function TrickleSync:GetManifestChunkTelemetry()
    self.telemetry = self.telemetry or {}
    return self.telemetry
end

function TrickleSync:ResetManifestChunkTelemetry()
    self.telemetry = {
        chunkBuilds = 0,
        chunkCacheHits = 0,
        chunkInvalidations = 0,
        queueCapHits = 0,
        queueCapDrops = 0,
        lastInvalidationReason = "none",
    }
end

function TrickleSync:BuildManifestChunks(opts)
    opts = opts or {}
    local manifest, status = self:BuildLocalManifest({
        allowStale = opts.allowStale == true,
        syncFallback = opts.syncFallback == true,
        reason = opts.reason or "manifest-chunks",
    })
    if not manifest then return nil, nil, status or "building" end

    local blockKeys = {}
    for blockKey in pairs(manifest.blocks or {}) do
        blockKeys[#blockKeys + 1] = blockKey
    end
    sort(blockKeys)

    local manifestId = string.format(
        "%s:%d:%d:%d",
        manifest.memberKey or "unknown",
        manifest.builtAt or 0,
        manifest.manifestSerial or 0,
        #blockKeys
    )
    if self._manifestChunkCache
        and self._manifestChunkCache.manifestId == manifestId
        and self._manifestChunkCache.chunks then
        self.telemetry = self.telemetry or {}
        self.telemetry.chunkCacheHits = (self.telemetry.chunkCacheHits or 0) + 1
        return self._manifestChunkCache.chunks, manifest, status or "cached"
    end

    local chunks = {}
    for startIndex = 1, #blockKeys, MANIFEST_BLOCKS_PER_CHUNK do
        local rows = {}
        for offset = 0, (MANIFEST_BLOCKS_PER_CHUNK - 1) do
            local blockKey = blockKeys[startIndex + offset]
            if not blockKey then break end
            local block = manifest.blocks[blockKey]
            rows[#rows + 1] = {
                blockKey = blockKey,
                ownerCharacter = block.ownerCharacter,
                professionKey = block.professionKey,
                revision = block.revision,
                lastUpdatedAt = block.lastUpdatedAt,
                sourceType = block.sourceType,
                guildStatus = block.guildStatus,
                lastSeenInGuildAt = block.lastSeenInGuildAt,
                count = block.count,
                fingerprint = block.fingerprint,
            }
        end
        chunks[#chunks + 1] = {
            manifestId = manifestId,
            builtAt = manifest.builtAt,
            memberKey = manifest.memberKey,
            totals = manifest.totals,
            seq = #chunks + 1,
            total = math.max(1, math.ceil(#blockKeys / MANIFEST_BLOCKS_PER_CHUNK)),
            blocks = rows,
        }
    end

    if #chunks == 0 then
        chunks[1] = {
            manifestId = manifestId,
            builtAt = manifest.builtAt,
            memberKey = manifest.memberKey,
            totals = manifest.totals,
            seq = 1,
            total = 1,
            blocks = {},
        }
    end

    self.telemetry = self.telemetry or {}
    self.telemetry.chunkBuilds = (self.telemetry.chunkBuilds or 0) + 1
    self._manifestChunkCache = {
        manifestId = manifestId,
        chunks = chunks,
    }
    return chunks, manifest, status or "built"
end

function TrickleSync:StorePeerManifest(peerKey, peerManifest)
    if not peerKey or type(peerManifest) ~= "table" then return nil end
    self.peerState[peerKey] = self.peerState[peerKey] or {}
    self.peerState[peerKey].manifest = peerManifest
    self.peerState[peerKey].lastManifestAt = time()
    return self.peerState[peerKey].manifest
end

function TrickleSync:IsPeerBlockEquivalentToLocal(peerBlock, localBlock)
    if type(peerBlock) ~= "table" or type(localBlock) ~= "table" then
        return false
    end
    if (peerBlock.guildStatus or "active") ~= "active" or (localBlock.guildStatus or "active") ~= "active" then
        return false
    end
    if peerBlock.ownerCharacter ~= localBlock.ownerCharacter then
        return false
    end
    if peerBlock.professionKey ~= localBlock.professionKey then
        return false
    end
    if (peerBlock.count or 0) ~= (localBlock.count or 0) then
        return false
    end
    if (peerBlock.fingerprint or "") ~= (localBlock.fingerprint or "") then
        return false
    end

    return true
end

function TrickleSync:ComparePeerManifest(peerManifest, opts)
    opts = opts or {}
    local includeRemoteDiffs = opts.includeRemoteDiffs ~= false
    local localManifest, status = self:BuildLocalManifest({
        allowStale = true,
        syncFallback = true,
        reason = opts.reason or "compare",
    })
    if not localManifest then
        return {
            localManifest = nil,
            peerManifest = peerManifest or { blocks = {} },
            missingHere = {},
            missingThere = {},
            outdatedHere = {},
            outdatedThere = {},
            identicalBlocks = {},
            ignoredStaleBlocks = {},
            status = status or "building",
        }, status or "building"
    end
    local comparison = {
        localManifest = localManifest,
        peerManifest = peerManifest or { blocks = {} },
        missingHere = {},
        missingThere = {},
        outdatedHere = {},
        outdatedThere = {},
        identicalBlocks = {},
        ignoredStaleBlocks = {},
        status = status or "ready",
    }

    local peerBlocks = comparison.peerManifest.blocks or {}
    for blockKey, peerBlock in pairs(peerBlocks) do
        local ownerCharacter = getValidManifestBlockParts(blockKey, peerBlock)
        if not ownerCharacter then
            -- Ignore malformed manifest rows instead of turning them into REQ keys.
        elseif (peerBlock.guildStatus or "active") ~= "active" then
            -- Stale records should not drive normal convergence.
            comparison.ignoredStaleBlocks[#comparison.ignoredStaleBlocks + 1] = blockKey
        else
            local localBlock = localManifest.blocks[blockKey]
            if not localBlock then
                comparison.missingHere[#comparison.missingHere + 1] = blockKey
            elseif self:IsPeerBlockEquivalentToLocal(peerBlock, localBlock) then
                comparison.identicalBlocks[#comparison.identicalBlocks + 1] = blockKey
            else
                local peerFingerprint = peerBlock.fingerprint or ""
                local localFingerprint = localBlock.fingerprint or ""
                local peerSource = peerBlock.sourceType or "replica"
                local localCount = localBlock.count or 0
                local peerCount = peerBlock.count or 0

                if peerSource ~= "owner" and localCount > peerCount then
                    if includeRemoteDiffs then
                        comparison.outdatedThere[#comparison.outdatedThere + 1] = blockKey
                    end
                elseif peerFingerprint ~= localFingerprint or peerCount ~= localCount then
                    comparison.outdatedHere[#comparison.outdatedHere + 1] = blockKey
                elseif includeRemoteDiffs then
                    comparison.outdatedThere[#comparison.outdatedThere + 1] = blockKey
                end
            end
        end
    end

    if includeRemoteDiffs then
        for blockKey in pairs(localManifest.blocks or {}) do
            if not peerBlocks[blockKey] then
                comparison.missingThere[#comparison.missingThere + 1] = blockKey
            end
        end
    end

    return comparison, status or "ready"
end

function TrickleSync:ComputeMissingBlocks(peerManifest)
    local comparison, status = self:ComparePeerManifest(peerManifest, {
        includeRemoteDiffs = false,
        reason = "compare-local-missing",
    })
    if not comparison or not comparison.localManifest then
        return nil, comparison, status or "building"
    end
    local blocks = {}

    for _, blockKey in ipairs(comparison.missingHere) do
        blocks[#blocks + 1] = blockKey
    end
    for _, blockKey in ipairs(comparison.outdatedHere) do
        blocks[#blocks + 1] = blockKey
    end

    sort(blocks)
    return blocks, comparison, status or "ready"
end

function TrickleSync:GroupBlockRequestsByOwner(peerManifest, blockKeys)
    local grouped = {}
    for _, blockKey in ipairs(blockKeys or {}) do
        local block = peerManifest and peerManifest.blocks and peerManifest.blocks[blockKey]
        local ownerCharacter = getValidManifestBlockParts(blockKey, block)
        if ownerCharacter then
            local row = grouped[ownerCharacter] or {
                revision = 0,
                blockKeys = {},
                fingerprints = {},
                sourceType = block.sourceType or "replica",
            }
            row.blockKeys[#row.blockKeys + 1] = blockKey
            row.fingerprints[blockKey] = block and block.fingerprint or nil
            if (block.revision or 0) > (row.revision or 0) then
                row.revision = block.revision or 0
            end
            row.sourceType = block.sourceType or row.sourceType
            grouped[ownerCharacter] = row
        end
    end
    return grouped
end

function TrickleSync:QueueMissingBlocksForPeer(peerKey, peerManifest)
    if not peerKey then return 0, {}, "missing-peer", nil end
    local missingBlocks, comparison, status = self:ComputeMissingBlocks(peerManifest)
    if not missingBlocks then
        self.outboundQueue[peerKey] = nil
        self.peerState[peerKey] = self.peerState[peerKey] or {}
        self.peerState[peerKey].lastManifestAt = time()
        self.peerState[peerKey].queuedBlocks = 0
        return 0, {}, status or "building", comparison
    end

    local otherQueued = 0
    for otherPeer, queue in pairs(self.outboundQueue or {}) do
        if otherPeer ~= peerKey then
            otherQueued = otherQueued + #(queue or {})
        end
    end

    local queue = {}
    local dropped = 0
    for _, blockKey in ipairs(missingBlocks) do
        if #queue >= TRICKLE_OUTBOUND_QUEUE_PER_PEER_CAP then
            dropped = dropped + 1
        elseif (otherQueued + #queue) >= TRICKLE_OUTBOUND_QUEUE_GLOBAL_CAP then
            dropped = dropped + 1
        else
            queue[#queue + 1] = blockKey
        end
    end

    self.telemetry = self.telemetry or {}
    if dropped > 0 then
        self.telemetry.queueCapHits = (self.telemetry.queueCapHits or 0) + 1
        self.telemetry.queueCapDrops = (self.telemetry.queueCapDrops or 0) + dropped
    end

    self.outboundQueue[peerKey] = queue
    self.peerState[peerKey] = self.peerState[peerKey] or {}
    self.peerState[peerKey].lastManifestAt = time()
    self.peerState[peerKey].queuedBlocks = #queue
    return #queue, self:GroupBlockRequestsByOwner(peerManifest, missingBlocks), status or "ready", comparison
end

function TrickleSync:GetQueuedBlocks(peerKey)
    return self.outboundQueue[peerKey] or {}
end
