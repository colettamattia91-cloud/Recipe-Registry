local Addon = _G.RecipeRegistry
local TrickleSync = Addon:NewModule("TrickleSync")
Addon.TrickleSync = TrickleSync

local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local time = time

local MANIFEST_BLOCKS_PER_CHUNK = 24

function TrickleSync:OnInitialize()
    self.peerState = {}
    self.outboundQueue = {}
    self._manifestChunkCache = nil
    self.telemetry = {
        chunkBuilds = 0,
        chunkCacheHits = 0,
        chunkInvalidations = 0,
    }
end

function TrickleSync:BuildLocalManifest(opts)
    if Addon.Data and Addon.Data.GetPreparedSyncManifest then
        return Addon.Data:GetPreparedSyncManifest(opts or { allowStale = true, syncFallback = true, reason = "trickle" })
    end
    return Addon.Data:BuildSyncManifest(false), "built"
end

function TrickleSync:InvalidateManifestChunkCache()
    self._manifestChunkCache = nil
    self.telemetry = self.telemetry or {}
    self.telemetry.chunkInvalidations = (self.telemetry.chunkInvalidations or 0) + 1
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

function TrickleSync:ComparePeerManifest(peerManifest)
    local localManifest = self:BuildLocalManifest({ allowStale = true, syncFallback = true, reason = "compare" })
    local comparison = {
        localManifest = localManifest,
        peerManifest = peerManifest or { blocks = {} },
        missingHere = {},
        missingThere = {},
        outdatedHere = {},
        outdatedThere = {},
    }

    local peerBlocks = comparison.peerManifest.blocks or {}
    for blockKey, peerBlock in pairs(peerBlocks) do
        if (peerBlock.guildStatus or "active") ~= "active" then
            -- Stale records should not drive normal convergence.
        else
        local localBlock = localManifest.blocks[blockKey]
        if not localBlock then
            comparison.missingHere[#comparison.missingHere + 1] = blockKey
        else
            local peerRevision = peerBlock.revision or 0
            local localRevision = localBlock.revision or 0
            local peerFingerprint = peerBlock.fingerprint or ""
            local localFingerprint = localBlock.fingerprint or ""
            local peerSource = peerBlock.sourceType or "replica"
            local localSource = localBlock.sourceType or "replica"

            if peerSource == "owner" and localSource ~= "owner" and peerFingerprint ~= localFingerprint then
                comparison.outdatedHere[#comparison.outdatedHere + 1] = blockKey
            elseif peerRevision > localRevision then
                comparison.outdatedHere[#comparison.outdatedHere + 1] = blockKey
            elseif peerRevision < localRevision then
                comparison.outdatedThere[#comparison.outdatedThere + 1] = blockKey
            elseif peerFingerprint ~= localFingerprint then
                comparison.outdatedHere[#comparison.outdatedHere + 1] = blockKey
            end
        end
        end
    end

    for blockKey in pairs(localManifest.blocks or {}) do
        if not peerBlocks[blockKey] then
            comparison.missingThere[#comparison.missingThere + 1] = blockKey
        end
    end

    return comparison
end

function TrickleSync:ComputeMissingBlocks(peerManifest)
    local comparison = self:ComparePeerManifest(peerManifest)
    local blocks = {}

    for _, blockKey in ipairs(comparison.missingHere) do
        blocks[#blocks + 1] = blockKey
    end
    for _, blockKey in ipairs(comparison.outdatedHere) do
        blocks[#blocks + 1] = blockKey
    end

    sort(blocks)
    return blocks, comparison
end

function TrickleSync:GroupBlockRequestsByOwner(peerManifest, blockKeys)
    local grouped = {}
    for _, blockKey in ipairs(blockKeys or {}) do
        local block = peerManifest and peerManifest.blocks and peerManifest.blocks[blockKey]
        local ownerCharacter = block and block.ownerCharacter
        if ownerCharacter then
            local row = grouped[ownerCharacter] or {
                revision = 0,
                blockKeys = {},
                sourceType = block.sourceType or "replica",
            }
            row.blockKeys[#row.blockKeys + 1] = blockKey
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
    if not peerKey then return 0, {} end
    local missingBlocks = self:ComputeMissingBlocks(peerManifest)
    local queue = self.outboundQueue[peerKey] or {}

    for _, blockKey in ipairs(missingBlocks) do
        queue[#queue + 1] = blockKey
    end

    self.outboundQueue[peerKey] = queue
    self.peerState[peerKey] = self.peerState[peerKey] or {}
    self.peerState[peerKey].lastManifestAt = time()
    self.peerState[peerKey].queuedBlocks = #queue
    return #queue, self:GroupBlockRequestsByOwner(peerManifest, missingBlocks)
end

function TrickleSync:GetQueuedBlocks(peerKey)
    return self.outboundQueue[peerKey] or {}
end
