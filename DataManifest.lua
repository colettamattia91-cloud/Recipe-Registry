local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local min = math.min
local max = math.max
local tostring = tostring

local MANIFEST_BUILD_BLOCKS_PER_STEP = Private.MANIFEST_BUILD_BLOCKS_PER_STEP
local buildManifestFingerprint = Private.buildManifestFingerprint
local cloneManifestForUpdate = Private.cloneManifestForUpdate
local countKeys = Private.countKeys
local countRecipeKeys = Private.countRecipeKeys
local newManifestCache = Private.newManifestCache
local newManifestTelemetry = Private.newManifestTelemetry
local nowMs = Private.nowMs

local function manifestRowFromSyncBlock(block)
    if not block then return nil end
    return {
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

function Data:BuildSyncBlockKey(ownerCharacter, professionKey)
    if not ownerCharacter or not professionKey then return nil end
    if not self:IsValidMemberKey(ownerCharacter) then return nil end
    return string.format("%s::%s", tostring(ownerCharacter), tostring(professionKey))
end

function Data:ParseSyncBlockKey(blockKey)
    if type(blockKey) ~= "string" then return nil, nil end
    local ownerCharacter, professionKey = blockKey:match("^(.-)::(.+)$")
    if not ownerCharacter or not professionKey then
        return nil, nil
    end
    return ownerCharacter, professionKey
end

function Data:IsValidSyncBlockKey(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not self:IsValidMemberKey(ownerCharacter) then return false end
    if type(professionKey) ~= "string" or professionKey == "" then return false end
    return true
end

function Data:GetSyncBlock(memberKey, professionKey)
    if not self:IsValidMemberKey(memberKey) then return nil end
    local entry = self:GetMember(memberKey)
    local profession = entry and entry.professions and entry.professions[professionKey]
    if not entry or not profession then return nil end
    local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
    if not blockKey then return nil end

    local recipeCount = profession.count
    if type(recipeCount) ~= "number" then
        recipeCount = countRecipeKeys(profession.recipes)
    end

    return {
        blockKey = blockKey,
        ownerCharacter = memberKey,
        professionKey = professionKey,
        revision = profession.blockRevision or entry.rev or 0,
        lastUpdatedAt = profession.lastUpdatedAt or entry.updatedAt or 0,
        sourceType = profession.sourceType or entry.sourceType or self:GetMemberSourceType(memberKey),
        guildStatus = profession.guildStatus or entry.guildStatus or "active",
        lastSeenInGuildAt = profession.lastSeenInGuildAt or entry.lastSeenInGuildAt or entry.updatedAt or 0,
        count = recipeCount,
        fingerprint = buildManifestFingerprint(profession),
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
    }
end

function Data:EnsureManifestCache()
    if type(self._manifestCache) ~= "table" then
        self._manifestCache = newManifestCache()
    end
    local cache = self._manifestCache
    cache.dirtyBlocks = cache.dirtyBlocks or {}
    cache.telemetry = cache.telemetry or newManifestTelemetry()
    return cache
end

function Data:GetManifestSerial()
    local cache = self:EnsureManifestCache()
    return cache.serial or 0
end

function Data:GetManifestBlockRow(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not self:IsValidMemberKey(ownerCharacter) or not professionKey then return nil end
    local entry = self:GetMember(ownerCharacter)
    if not entry or self:IsMockMember(ownerCharacter, entry) then return nil end
    if (entry.guildStatus or "active") ~= "active" then return nil end
    local block = self:GetSyncBlock(ownerCharacter, professionKey)
    if not block or (block.guildStatus or "active") ~= "active" then return nil end
    return manifestRowFromSyncBlock(block)
end

function Data:MarkManifestDirty(blockKey, reason)
    local cache = self:EnsureManifestCache()
    cache.lastReason = reason or cache.lastReason or "dirty"
    if cache.building then
        cache.dirtyDuringBuild = true
    end
    if not blockKey then
        cache.dirtyAll = true
        cache.dirtyBlocks = {}
        cache.telemetry.fullInvalidations = (cache.telemetry.fullInvalidations or 0) + 1
    elseif not cache.dirtyAll then
        if not cache.dirtyBlocks[blockKey] then
            cache.telemetry.dirtyBlocksMarked = (cache.telemetry.dirtyBlocksMarked or 0) + 1
        end
        cache.dirtyBlocks[blockKey] = true
    end
    self:ScheduleManifestBuild(reason or "dirty")
end

function Data:MarkManifestMemberDirty(memberKey, entry, reason)
    entry = entry or self:GetMember(memberKey)
    if not memberKey or not entry then
        self:MarkManifestDirty(nil, reason or "member-unknown")
        return
    end
    local marked = false
    for professionKey in pairs(entry.professions or {}) do
        self:MarkManifestDirty(self:BuildSyncBlockKey(memberKey, professionKey), reason or "member")
        marked = true
    end
    if not marked then
        self:MarkManifestDirty(nil, reason or "member-empty")
    end
end

function Data:IsManifestDirty()
    local cache = self:EnsureManifestCache()
    return cache.dirtyAll == true or next(cache.dirtyBlocks) ~= nil or cache.building == true
end

function Data:MakeManifestShell()
    local cache = self:EnsureManifestCache()
    return {
        builtAt = time(),
        memberKey = self:GetPlayerKey(),
        manifestSerial = cache.serial or 0,
        blocks = {},
        totals = {
            blocks = 0,
            recipes = 0,
        },
    }
end

function Data:GetAllSyncBlocks(includeStale)
    local blocks = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsValidMemberKey(memberKey)
            and not self:IsMockMember(memberKey, entry)
            and (includeStale or (entry.guildStatus or "active") == "active") then
            for professionKey in pairs(entry.professions or {}) do
                local block = self:GetSyncBlock(memberKey, professionKey)
                if block then
                    blocks[#blocks + 1] = block
                end
            end
        end
    end
    sort(blocks, function(a, b)
        if a.ownerCharacter ~= b.ownerCharacter then
            return a.ownerCharacter < b.ownerCharacter
        end
        return a.professionKey < b.professionKey
    end)
    return blocks
end

function Data:BuildSyncManifest(includeStale)
    local manifest = self:MakeManifestShell()

    for _, block in ipairs(self:GetAllSyncBlocks(includeStale)) do
        manifest.blocks[block.blockKey] = manifestRowFromSyncBlock(block)
        manifest.totals.blocks = manifest.totals.blocks + 1
        manifest.totals.recipes = manifest.totals.recipes + (block.count or 0)
    end

    return manifest
end

function Data:ApplyManifestDirtyBlock(manifest, blockKey)
    if not manifest or not blockKey then return end
    local previous = manifest.blocks[blockKey]
    if previous then
        manifest.totals.blocks = max(0, (manifest.totals.blocks or 0) - 1)
        manifest.totals.recipes = max(0, (manifest.totals.recipes or 0) - (previous.count or 0))
        manifest.blocks[blockKey] = nil
    end

    local row = self:GetManifestBlockRow(blockKey)
    if row then
        manifest.blocks[blockKey] = row
        manifest.totals.blocks = (manifest.totals.blocks or 0) + 1
        manifest.totals.recipes = (manifest.totals.recipes or 0) + (row.count or 0)
    end
end

function Data:CommitManifestBuild(manifest, reason, mode, processed, startMs)
    local cache = self:EnsureManifestCache()
    cache.manifest = manifest
    cache.dirtyAll = cache.dirtyDuringBuild == true
    cache.dirtyBlocks = {}
    cache.building = false
    cache.scheduled = false
    cache.dirtyDuringBuild = false
    cache.lastReason = reason or cache.lastReason
    cache.telemetry.buildsCompleted = (cache.telemetry.buildsCompleted or 0) + 1
    cache.telemetry.blocksProcessed = (cache.telemetry.blocksProcessed or 0) + (processed or 0)
    if mode == "delta" then
        cache.telemetry.deltaBuilds = (cache.telemetry.deltaBuilds or 0) + 1
    else
        cache.telemetry.fullBuilds = (cache.telemetry.fullBuilds or 0) + 1
    end
    if startMs then
        local costMs = nowMs() - startMs
        cache.telemetry.totalBuildCostMs = (cache.telemetry.totalBuildCostMs or 0) + costMs
        cache.telemetry.lastBuildCostMs = costMs
        if costMs > (cache.telemetry.maxBuildCostMs or 0) then
            cache.telemetry.maxBuildCostMs = costMs
        end
    end
    if Addon.TrickleSync and Addon.TrickleSync.InvalidateManifestChunkCache then
        Addon.TrickleSync:InvalidateManifestChunkCache(reason or "commit")
    end
    if Addon.Sync and Addon.Sync.OnManifestCacheReady then
        Addon.Sync:OnManifestCacheReady(reason or "manifest-cache")
    end
    if cache.dirtyAll then
        self:ScheduleManifestBuild("dirty-during-build")
    end
end

function Data:BuildManifestCacheNow(reason)
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        return cache.manifest
    end

    local startMs = nowMs()
    cache.serial = (cache.serial or 0) + 1
    cache.telemetry.buildsStarted = (cache.telemetry.buildsStarted or 0) + 1
    cache.telemetry.syncFallbackBuilds = (cache.telemetry.syncFallbackBuilds or 0) + (reason == "sync-fallback" and 1 or 0)

    local mode = "full"
    local manifest
    local processed = 0
    if cache.manifest and not cache.dirtyAll then
        mode = "delta"
        manifest = cloneManifestForUpdate(cache.manifest)
        manifest.builtAt = time()
        manifest.memberKey = self:GetPlayerKey()
        manifest.manifestSerial = cache.serial
        for blockKey in pairs(cache.dirtyBlocks or {}) do
            self:ApplyManifestDirtyBlock(manifest, blockKey)
            processed = processed + 1
        end
    else
        manifest = self:BuildSyncManifest(false)
        manifest.manifestSerial = cache.serial
        processed = manifest.totals.blocks or 0
    end

    self:CommitManifestBuild(manifest, reason or cache.lastReason or "sync", mode, processed, startMs)
    return manifest
end

function Data:PrepareManifestBuildState(state)
    local cache = self:EnsureManifestCache()
    state = state or {}
    state.reason = state.reason or cache.lastReason or "background"
    state.index = 1
    state.processed = 0
    state.startMs = nowMs()
    state.mode = (cache.manifest and not cache.dirtyAll) and "delta" or "full"
    cache.serial = (cache.serial or 0) + 1
    cache.telemetry.buildsStarted = (cache.telemetry.buildsStarted or 0) + 1
    cache.scheduled = false
    cache.building = true
    cache.dirtyDuringBuild = false

    if state.mode == "delta" then
        state.manifest = cloneManifestForUpdate(cache.manifest)
        state.manifest.builtAt = time()
        state.manifest.memberKey = self:GetPlayerKey()
        state.manifest.manifestSerial = cache.serial
        state.blockKeys = {}
        for blockKey in pairs(cache.dirtyBlocks or {}) do
            state.blockKeys[#state.blockKeys + 1] = blockKey
        end
        sort(state.blockKeys)
    else
        state.manifest = self:MakeManifestShell()
        state.manifest.manifestSerial = cache.serial
        state.blocks = self:GetAllSyncBlocks(false)
    end
    return state
end

function Data:RunManifestBuildStep(state)
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() and not cache.building then
        cache.scheduled = false
        return false
    end

    if not state or not state.mode then
        state = self:PrepareManifestBuildState(state)
    end

    cache.telemetry.buildSteps = (cache.telemetry.buildSteps or 0) + 1
    local processedThisStep = 0
    while processedThisStep < MANIFEST_BUILD_BLOCKS_PER_STEP do
        if state.mode == "delta" then
            local blockKey = state.blockKeys[state.index]
            if not blockKey then break end
            self:ApplyManifestDirtyBlock(state.manifest, blockKey)
        else
            local block = state.blocks[state.index]
            if not block then break end
            state.manifest.blocks[block.blockKey] = manifestRowFromSyncBlock(block)
            state.manifest.totals.blocks = state.manifest.totals.blocks + 1
            state.manifest.totals.recipes = state.manifest.totals.recipes + (block.count or 0)
        end
        state.index = state.index + 1
        state.processed = (state.processed or 0) + 1
        processedThisStep = processedThisStep + 1
    end

    local done
    if state.mode == "delta" then
        done = state.index > #(state.blockKeys or {})
    else
        done = state.index > #(state.blocks or {})
    end
    if not done then return true, state end

    self:CommitManifestBuild(state.manifest, state.reason, state.mode, state.processed or 0, state.startMs)
    return false
end

function Data:ScheduleManifestBuild(reason)
    local cache = self:EnsureManifestCache()
    if cache.scheduled or cache.building then return end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then return end
    cache.scheduled = true
    cache.lastReason = reason or cache.lastReason or "scheduled"
    cache.telemetry.schedules = (cache.telemetry.schedules or 0) + 1
    Addon.Performance:ScheduleJob("manifest-cache-build", function(state)
        return self:RunManifestBuildStep(state)
    end, {
        category = "sync-manifest",
        label = "manifest-cache-build",
        budgetMs = 2,
        state = {
            reason = reason or "scheduled",
        },
    })
end

function Data:GetPreparedSyncManifest(opts)
    opts = opts or {}
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        return cache.manifest, "ready"
    end
    if opts.allowStale and cache.manifest then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        self:ScheduleManifestBuild(opts.reason or "stale-request")
        return cache.manifest, "stale"
    end
    if opts.syncFallback then
        if Addon.Sync and Addon.Sync.ShouldDeferInlineManifestFallback and Addon.Sync:ShouldDeferInlineManifestFallback(opts.reason) then
            cache.telemetry.syncFallbackDeferrals = (cache.telemetry.syncFallbackDeferrals or 0) + 1
            cache.telemetry.deferredRequests = (cache.telemetry.deferredRequests or 0) + 1
            self:ScheduleManifestBuild(opts.reason or "request")
            return nil, "deferred"
        end
        cache.telemetry.syncFallbackBuilds = (cache.telemetry.syncFallbackBuilds or 0) + 1
        return self:BuildManifestCacheNow("sync-fallback"), "built"
    end
    cache.telemetry.deferredRequests = (cache.telemetry.deferredRequests or 0) + 1
    self:ScheduleManifestBuild(opts.reason or "request")
    return nil, "building"
end

function Data:GetManifestDebugSnapshot()
    local cache = self:EnsureManifestCache()
    local manifest = cache.manifest
    local tel = cache.telemetry or newManifestTelemetry()
    local avgCostMs = 0
    if (tel.buildsCompleted or 0) > 0 then
        avgCostMs = (tel.totalBuildCostMs or 0) / tel.buildsCompleted
    end
    return {
        ready = manifest ~= nil and not self:IsManifestDirty(),
        hasManifest = manifest ~= nil,
        dirtyAll = cache.dirtyAll == true,
        dirtyBlocks = countKeys(cache.dirtyBlocks),
        building = cache.building == true,
        scheduled = cache.scheduled == true,
        serial = cache.serial or 0,
        blocks = manifest and manifest.totals and manifest.totals.blocks or 0,
        recipes = manifest and manifest.totals and manifest.totals.recipes or 0,
        lastReason = cache.lastReason or "none",
        avgBuildCostMs = avgCostMs,
        maxBuildCostMs = tel.maxBuildCostMs or 0,
        lastBuildCostMs = tel.lastBuildCostMs or 0,
        telemetry = tel,
    }
end

function Data:DumpManifestCacheStatus()
    local snapshot = self:GetManifestDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    local chunkTelemetry = Addon.TrickleSync and Addon.TrickleSync.GetManifestChunkTelemetry
        and Addon.TrickleSync:GetManifestChunkTelemetry()
        or {}
    local syncTelemetry = Addon.Sync and Addon.Sync.telemetry or {}
    local manifestQueueDepth = Addon.Sync and Addon.Sync.manifestChunkQueue and #Addon.Sync.manifestChunkQueue or 0
    Addon:SystemPrint(string.format(
        "Manifest cache ready=%s dirtyAll=%s dirtyBlocks=%d building=%s scheduled=%s serial=%d blocks=%d recipes=%d builds=%d full=%d delta=%d steps=%d processed=%d hits=%d fallback=%d deferred=%d chunkBuilds=%d chunkHits=%d chunkInvalidations=%d maniQueued=%d maniSent=%d maniQueue=%d avgCostMs=%.2f maxCostMs=%.2f lastCostMs=%.2f last=%s",
        tostring(snapshot.ready),
        tostring(snapshot.dirtyAll),
        snapshot.dirtyBlocks or 0,
        tostring(snapshot.building),
        tostring(snapshot.scheduled),
        snapshot.serial or 0,
        snapshot.blocks or 0,
        snapshot.recipes or 0,
        telemetry.buildsCompleted or 0,
        telemetry.fullBuilds or 0,
        telemetry.deltaBuilds or 0,
        telemetry.buildSteps or 0,
        telemetry.blocksProcessed or 0,
        telemetry.cacheHits or 0,
        telemetry.syncFallbackBuilds or 0,
        telemetry.deferredRequests or 0,
        chunkTelemetry.chunkBuilds or 0,
        chunkTelemetry.chunkCacheHits or 0,
        chunkTelemetry.chunkInvalidations or 0,
        syncTelemetry.manifestChunksQueued or 0,
        syncTelemetry.manifestChunksSent or 0,
        manifestQueueDepth,
        snapshot.avgBuildCostMs or 0,
        snapshot.maxBuildCostMs or 0,
        snapshot.lastBuildCostMs or 0,
        tostring(snapshot.lastReason or "none")
    ))
end

function Data:ResetManifestTelemetry()
    local cache = self:EnsureManifestCache()
    cache.telemetry = newManifestTelemetry()
    if Addon.TrickleSync and Addon.TrickleSync.ResetManifestChunkTelemetry then
        Addon.TrickleSync:ResetManifestChunkTelemetry()
    end
end

function Data:GetDatasetCompletenessEstimate()
    local manifest = self:GetPreparedSyncManifest({ allowStale = true, syncFallback = true, reason = "completeness" })
    return manifest.totals.blocks, manifest.totals.recipes
end

function Data:IsBootstrapCandidate()
    local blockCount, recipeCount = self:GetDatasetCompletenessEstimate()
    return blockCount > 0 and recipeCount > 0
end

function Data:IsBootstrapNeeded()
    local blockCount, recipeCount = self:GetDatasetCompletenessEstimate()
    if blockCount == 0 then return true end
    return recipeCount == 0
end

function Data:DumpManifestSummary(opts)
    opts = opts or {}
    local verbose = opts.verbose == true
    local manifest = self:BuildSyncManifest(false)
    local localKey = self:GetPlayerKey()
    local totalBlocks = 0
    local totalRecipes = 0
    local ownerBlocks = 0
    local replicaBlocks = 0
    local replicaOwners = {}
    local staleMembers = 0
    local staleOwnerKeys = {}

    for memberKey, entry in pairs(self:GetMembersDB()) do
        if not self:IsMockMember(memberKey, entry) and (entry.guildStatus or "active") == "stale" then
            staleMembers = staleMembers + 1
            staleOwnerKeys[#staleOwnerKeys + 1] = memberKey
        end
    end

    for _, block in pairs(manifest.blocks or {}) do
        totalBlocks = totalBlocks + 1
        totalRecipes = totalRecipes + (block.count or 0)
        if block.ownerCharacter == localKey and (block.sourceType or "owner") == "owner" then
            ownerBlocks = ownerBlocks + 1
        else
            replicaBlocks = replicaBlocks + 1
            replicaOwners[block.ownerCharacter] = replicaOwners[block.ownerCharacter] or {
                blocks = 0,
                recipes = 0,
                sourceType = block.sourceType or "replica",
                professions = {},
            }
            replicaOwners[block.ownerCharacter].blocks = replicaOwners[block.ownerCharacter].blocks + 1
            replicaOwners[block.ownerCharacter].recipes = replicaOwners[block.ownerCharacter].recipes + (block.count or 0)
            replicaOwners[block.ownerCharacter].sourceType = block.sourceType or replicaOwners[block.ownerCharacter].sourceType
            replicaOwners[block.ownerCharacter].professions[#replicaOwners[block.ownerCharacter].professions + 1] = block.professionKey
        end
    end

    local replicaOwnerKeys = {}
    for ownerCharacter in pairs(replicaOwners) do
        replicaOwnerKeys[#replicaOwnerKeys + 1] = ownerCharacter
    end
    sort(replicaOwnerKeys)

    Addon:SystemPrint(string.format(
        "Manifest local=%s blocks=%d recipes=%d ownerBlocks=%d replicaBlocks=%d replicaOwners=%d staleMembers=%d",
        tostring(localKey),
        totalBlocks,
        totalRecipes,
        ownerBlocks,
        replicaBlocks,
        #replicaOwnerKeys,
        staleMembers
    ))

    if #replicaOwnerKeys == 0 then
        Addon:SystemPrint("Manifest replica owners: none")
    elseif not verbose then
        Addon:SystemPrint(string.format(
            "Manifest replica owners: %d (use /rr manifest verbose for details)",
            #replicaOwnerKeys
        ))
    else
        Addon:SystemPrint("Manifest replica owners:")
        local maxLines = min(#replicaOwnerKeys, 12)
        for index = 1, maxLines do
            local ownerCharacter = replicaOwnerKeys[index]
            local info = replicaOwners[ownerCharacter]
            sort(info.professions)
            Addon:SystemPrint(string.format(
                "  %s blocks=%d recipes=%d publish=replica authority=%s professions=%s",
                tostring(ownerCharacter),
                info.blocks or 0,
                info.recipes or 0,
                tostring(info.sourceType or "replica"),
                table.concat(info.professions or {}, ",")
            ))
        end
        if #replicaOwnerKeys > maxLines then
            Addon:SystemPrint(string.format("  ... and %d more", #replicaOwnerKeys - maxLines))
        end
    end
    if #staleOwnerKeys > 0 then
        sort(staleOwnerKeys)
        if not verbose then
            Addon:SystemPrint(string.format(
                "Manifest stale excluded: %d (use /rr manifest verbose for details)",
                #staleOwnerKeys
            ))
        else
            Addon:SystemPrint("Manifest stale excluded:")
            local maxStaleLines = min(#staleOwnerKeys, 8)
            for index = 1, maxStaleLines do
                local memberKey = staleOwnerKeys[index]
                local entry = self:GetMember(memberKey)
                local profCount = 0
                for _ in pairs(entry and entry.professions or {}) do
                    profCount = profCount + 1
                end
                Addon:SystemPrint(string.format("  %s professions=%d", tostring(memberKey), profCount))
            end
            if #staleOwnerKeys > maxStaleLines then
                Addon:SystemPrint(string.format("  ... and %d more", #staleOwnerKeys - maxStaleLines))
            end
        end
    end

    local snapshot = self:GetManifestDebugSnapshot()
    local syncTel = Addon.Sync and Addon.Sync.telemetry or {}
    local trickle = Addon.TrickleSync
    local residentPeers = 0
    local queuedPeers = 0
    local queuedBlocks = 0
    for _, state in pairs(trickle and trickle.peerState or {}) do
        if type(state) == "table" and type(state.manifest) == "table" then
            residentPeers = residentPeers + 1
        end
    end
    for _, queue in pairs(trickle and trickle.outboundQueue or {}) do
        local depth = #(queue or {})
        if depth > 0 then
            queuedPeers = queuedPeers + 1
            queuedBlocks = queuedBlocks + depth
        end
    end
    local partialPeers = 0
    local partialOpen = 0
    for _, manifests in pairs(Addon.Sync and Addon.Sync.partialManifestReceive or {}) do
        local perPeer = 0
        for _ in pairs(manifests or {}) do
            perPeer = perPeer + 1
            partialOpen = partialOpen + 1
        end
        if perPeer > 0 then
            partialPeers = partialPeers + 1
        end
    end
    Addon:SystemPrint(string.format(
        "Manifest builds=%d (full=%d delta=%d) avgCostMs=%.2f maxCostMs=%.2f requests=%d cooldownSkips=%d forceReplies=%d",
        snapshot.telemetry.buildsCompleted or 0,
        snapshot.telemetry.fullBuilds or 0,
        snapshot.telemetry.deltaBuilds or 0,
        snapshot.avgBuildCostMs or 0,
        snapshot.maxBuildCostMs or 0,
        syncTel.manifestBuildRequests or 0,
        syncTel.manifestCooldownSkips or 0,
        syncTel.manifestForceReplies or 0
    ))
    Addon:SystemPrint(string.format(
        "Manifest runtime residentPeers=%d queuedPeers=%d queuedBlocks=%d partialPeers=%d partialOpen=%d fallbackBuilds=%d deferred=%d",
        residentPeers,
        queuedPeers,
        queuedBlocks,
        partialPeers,
        partialOpen,
        snapshot.telemetry.syncFallbackBuilds or 0,
        snapshot.telemetry.deferredRequests or 0
    ))
end