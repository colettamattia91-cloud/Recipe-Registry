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
end

function TrickleSync:BuildLocalManifest()
    return Addon.Data:BuildSyncManifest(false)
end

function TrickleSync:BuildManifestChunks()
    local manifest = self:BuildLocalManifest()
    local blockKeys = {}
    for blockKey in pairs(manifest.blocks or {}) do
        blockKeys[#blockKeys + 1] = blockKey
    end
    sort(blockKeys)

    local manifestId = string.format("%s:%d:%d", manifest.memberKey or "unknown", manifest.builtAt or 0, #blockKeys)
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

    return chunks, manifest
end

function TrickleSync:StorePeerManifest(peerKey, peerManifest)
    if not peerKey or type(peerManifest) ~= "table" then return nil end
    self.peerState[peerKey] = self.peerState[peerKey] or {}
    self.peerState[peerKey].manifest = peerManifest
    self.peerState[peerKey].lastManifestAt = time()
    return self.peerState[peerKey].manifest
end

function TrickleSync:ComparePeerManifest(peerManifest)
    local localManifest = self:BuildLocalManifest()
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
            if (peerBlock.revision or 0) > (localBlock.revision or 0) then
                comparison.outdatedHere[#comparison.outdatedHere + 1] = blockKey
            elseif (peerBlock.revision or 0) < (localBlock.revision or 0) then
                comparison.outdatedThere[#comparison.outdatedThere + 1] = blockKey
            elseif (peerBlock.fingerprint or "") ~= (localBlock.fingerprint or "") then
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
