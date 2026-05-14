local Loader = dofile("local-tests/harness/load-addon.lua")
local Wow = Loader.Wow
local TransportProfiles = dofile("local-tests/harness/transport-profiles.lua")

local CommBus = {}
CommBus.__index = CommBus

local realType = type
local mathHuge = math.huge

local PROFESSIONS = {
    "Alchemy",
    "Blacksmithing",
    "Cooking",
    "Enchanting",
    "Engineering",
    "Jewelcrafting",
    "Leatherworking",
    "Tailoring",
}

local function deepcopy(value, seen)
    if realType(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        out[deepcopy(key, seen)] = deepcopy(item, seen)
    end
    return out
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local lt, rt = realType(left), realType(right)
        if lt == rt and (lt == "number" or lt == "string") then
            return left < right
        end
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function stableDescribe(value, seen)
    local valueType = realType(value)
    if valueType == "table" then
        seen = seen or {}
        if seen[value] then
            return "<cycle>"
        end
        seen[value] = true
        local parts = {}
        for _, key in ipairs(sortedKeys(value)) do
            parts[#parts + 1] = tostring(key) .. "=" .. stableDescribe(value[key], seen)
        end
        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if valueType == "string" then
        return value
    end
    return tostring(value)
end

local function stableRecipeSignature(recipes)
    local keys = {}
    for recipeKey in pairs(recipes or {}) do
        keys[#keys + 1] = recipeKey
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for index = 1, #keys do
        parts[index] = tostring(keys[index])
    end
    return table.concat(parts, ":")
end

local function collectKnownSpellIds(knownSpells)
    local spellIDs = {}
    for spellID, known in pairs(knownSpells or {}) do
        if known then
            spellIDs[#spellIDs + 1] = spellID
        end
    end
    table.sort(spellIDs)
    return spellIDs
end

local function countPartialManifestEntries(sync)
    local total = 0
    for _, manifests in pairs(sync.partialManifestReceive or {}) do
        total = total + countKeys(manifests)
    end
    return total
end

local function snapshotNodeRuntime(node)
    local state = node and node.state or {}
    return {
        now = state.now,
        playerName = state.playerName,
        realm = state.realm,
        inGuild = state.inGuild,
        inCombat = state.inCombat,
        inRaid = state.inRaid,
        inInstance = state.inInstance,
        instanceType = state.instanceType,
        guildRoster = deepcopy(state.guildRoster or {}),
        skillLines = deepcopy(state.skillLines or {}),
        knownSpells = collectKnownSpellIds(state.knownSpells or {}),
        tradeSkill = deepcopy(state.tradeSkill or {}),
        craftSkill = deepcopy(state.craftSkill or {}),
        payloadMode = state.payloadMode or node.payloadMode or "table-fast",
    }
end

local function makeRoster(names, realm)
    local rows = {}
    for index, name in ipairs(names or {}) do
        rows[index] = {
            name = string.format("%s-%s", name, realm),
            online = true,
            rankName = "Member",
            rankIndex = 5,
            level = 70,
            classDisplayName = "Mage",
            classFileName = "MAGE",
        }
    end
    return rows
end

local function outstandingCost(sync, manifestOnly)
    local owners = 0
    local blocks = 0
    for _, request in pairs(sync.pendingRequests or {}) do
        if not manifestOnly or request.why == "manifest" then
            owners = owners + 1
            blocks = blocks + math.max(1, #(request.requestedBlocks or {}))
        end
    end
    if sync.inFlight and (not manifestOnly or sync.inFlight.why == "manifest") then
        owners = owners + 1
        blocks = blocks + math.max(1, #(sync.inFlight.requestedBlocks or {}))
    end
    return owners, blocks
end

local function hasPartialReceives(sync)
    for _ in pairs(sync.partialReceive or {}) do return true end
    for _, manifests in pairs(sync.partialManifestReceive or {}) do
        if next(manifests or {}) ~= nil then
            return true
        end
    end
    return false
end

local function hasNodeWork(node)
    local sync = node.addon.Sync
    if node.sentCursor < #(node.state.sentComm or {}) then return true end
    if countKeys(sync.pendingRequests) > 0 then return true end
    if sync.inFlight then return true end
    if countKeys(sync.outgoingSessions) > 0 then return true end
    if #(sync.outboundChunkQueue or {}) > 0 then return true end
    if #(sync.manifestChunkQueue or {}) > 0 then return true end
    if #(sync.inboundChunkQueue or {}) > 0 then return true end
    if #(sync.inboundFinalizeQueue or {}) > 0 then return true end
    if #(sync.manifestCatchupQueue or {}) > 0 then return true end
    if hasPartialReceives(sync) then return true end
    return false
end

local function describeNodeWork(node)
    local sync = node and node.addon and node.addon.Sync or nil
    if not sync then
        return {}
    end

    local reasons = {}
    if node.sentCursor < #(node.state.sentComm or {}) then
        reasons[#reasons + 1] = "sentComm=" .. tostring(#(node.state.sentComm or {}) - node.sentCursor)
    end
    if countKeys(sync.pendingRequests or {}) > 0 then
        reasons[#reasons + 1] = "pending=" .. tostring(countKeys(sync.pendingRequests or {}))
    end
    if sync.inFlight then
        reasons[#reasons + 1] = "inFlight=1"
    end
    if countKeys(sync.outgoingSessions or {}) > 0 then
        reasons[#reasons + 1] = "outgoingSessions=" .. tostring(countKeys(sync.outgoingSessions or {}))
    end
    if #(sync.outboundChunkQueue or {}) > 0 then
        reasons[#reasons + 1] = "outbound=" .. tostring(#(sync.outboundChunkQueue or {}))
    end
    if #(sync.manifestChunkQueue or {}) > 0 then
        reasons[#reasons + 1] = "manifestChunk=" .. tostring(#(sync.manifestChunkQueue or {}))
    end
    if #(sync.inboundChunkQueue or {}) > 0 then
        reasons[#reasons + 1] = "inbound=" .. tostring(#(sync.inboundChunkQueue or {}))
    end
    if #(sync.inboundFinalizeQueue or {}) > 0 then
        reasons[#reasons + 1] = "finalize=" .. tostring(#(sync.inboundFinalizeQueue or {}))
    end
    if #(sync.manifestCatchupQueue or {}) > 0 then
        reasons[#reasons + 1] = "catchup=" .. tostring(#(sync.manifestCatchupQueue or {}))
    end
    if countKeys(sync.partialReceive or {}) > 0 then
        reasons[#reasons + 1] = "partialSnap=" .. tostring(countKeys(sync.partialReceive or {}))
    end
    local partialManifests = countPartialManifestEntries(sync)
    if partialManifests > 0 then
        reasons[#reasons + 1] = "partialMani=" .. tostring(partialManifests)
    end
    return reasons
end

local function resolveTransportProfile(profile)
    if realType(profile) == "table" then
        return deepcopy(profile), "custom"
    end
    local name = profile or "instant"
    local base = TransportProfiles[name]
    if not base then
        error("unknown transport profile: " .. tostring(name), 2)
    end
    return deepcopy(base), name
end

local function payloadKind(payload)
    return realType(payload) == "table" and payload.kind or "?"
end

local function estimateLogicalSize(payload)
    return #stableDescribe(payload)
end

local function estimateWireSize(message, payload)
    if realType(message) == "string" then
        return #message
    end
    if payload ~= nil then
        return #stableDescribe(payload)
    end
    return #stableDescribe(message)
end

local function decodePayload(message)
    if realType(message) == "table" then
        return message
    end
    if realType(message) ~= "string" then
        return nil
    end
    local okStub, serializer = pcall(LibStub, "AceSerializer-3.0", true)
    if not okStub or not serializer then
        return nil
    end
    local ok, payload = serializer:Deserialize(message)
    if ok and realType(payload) == "table" then
        return payload
    end
    return nil
end

local function deterministicFraction(id)
    return ((id * 7919) % 10000) / 10000
end

local function computeProfileDelay(profile, itemId, senderNode, targetNode)
    local jitterTicks = tonumber(profile.jitterTicks or 0) or 0
    if jitterTicks <= 0 then
        return 0
    end
    local senderIndex = senderNode and senderNode.index or 0
    local targetIndex = targetNode and targetNode.index or 0
    return (itemId + senderIndex + targetIndex) % (jitterTicks + 1)
end

function CommBus.New(opts)
    opts = opts or {}
    local names = opts.names or {}
    local transportProfile, transportProfileName = resolveTransportProfile(opts.transportProfile)
    local bus = {
        realm = opts.realm or "TestRealm",
        now = opts.now or 1700000000,
        payloadMode = opts.payloadMode or "table-fast",
        nodes = {},
        nodeByKey = {},
        nodeByName = {},
        roster = makeRoster(names, opts.realm or "TestRealm"),
        routeHook = opts.routeHook,
        events = {},
        maxEvents = opts.maxEvents or 4000,
        transport = {
            profile = transportProfile,
            profileName = transportProfileName,
            queued = {},
            delivered = 0,
            deliveredBytes = 0,
            dropped = 0,
            delayed = 0,
            maxQueued = 0,
            maxBytesQueued = 0,
            maxAgeTicks = 0,
            competingTrafficBytes = 0,
            nextId = 0,
        },
        stats = {
            ticks = 0,
            delivered = 0,
            delayed = 0,
            dropped = 0,
            sentKinds = {},
            deliveredKinds = {},
            droppedKinds = {},
            maxOutstandingOwners = 0,
            maxOutstandingBlocks = 0,
            maxManifestOutstandingOwners = 0,
            maxManifestOutstandingBlocks = 0,
            maxCatchupDeferred = 0,
            maxManifestCatchupQueue = 0,
            maxManifestChunkQueue = 0,
            maxOutboundChunkQueue = 0,
            maxInboundChunkQueue = 0,
            maxInboundFinalizeQueue = 0,
            maxPendingRequests = 0,
            maxActiveRequests = 0,
            maxTransportQueue = 0,
            maxTransportBytesQueued = 0,
            maxQueueDepths = {},
        },
    }
    return setmetatable(bus, CommBus)
end

function CommBus:Activate(node)
    Wow.UseState(node.state)
    _G.RecipeRegistry = node.addon
    _G.RecipeRegistryDB = node.addon.db
    _G.RecipeRegistryCharDB = node.addon.charDB
    node.state.now = self.now
    Wow.Configure({
        payloadMode = node.payloadMode or self.payloadMode,
    })
    return node.addon
end

function CommBus:AddNode(name, opts)
    opts = opts or {}
    local addon = Loader.Load({
        reset = true,
        initialize = false,
        payloadMode = opts.payloadMode or self.payloadMode,
        addonMetadata = opts.addonMetadata,
    })
    Wow.SetPlayer(name, self.realm)
    Wow.SetGuildRoster(self.roster)
    Loader.Initialize(addon)

    local node = {
        name = name,
        addon = addon,
        state = Wow.GetState(),
        payloadMode = opts.payloadMode or self.payloadMode,
        runtimeTickers = opts.runtimeTickers,
        sentCursor = 0,
        index = #self.nodes + 1,
        online = opts.online ~= false,
        addonMetadata = deepcopy(opts.addonMetadata or {
            Version = "1.8.1",
            ["X-Build-Channel"] = "release",
            ["X-Build-ID"] = "bus-build",
        }),
    }
    self:Activate(node)
    node.key = addon.Data:GetPlayerKey()
    addon.Data:RebuildOnlineCache()
    addon.Sync:RegisterComm(addon.ADDON_PREFIX)
    addon.Sync:EnsureBackgroundWorkers()
    if opts.runtimeTickers then
        self:EnableRuntimeTickers(node, opts.runtimeTickers)
    end

    self.nodes[#self.nodes + 1] = node
    self.nodeByKey[node.key] = node
    self.nodeByName[name] = node
    return node
end

function CommBus:EnableRuntimeTickers(node, opts)
    if not node then return end
    if opts == true then
        opts = { prune = true }
    else
        opts = opts or {}
    end

    self:Activate(node)
    local sync = node.addon.Sync
    local constants = sync and sync._private and sync._private.constants or {}
    if opts.prune ~= false and not sync.pruneTicker then
        sync.pruneTicker = sync:ScheduleRepeatingTimer("PruneState", 5)
    end
    if opts.hello == true and not sync.helloTicker then
        sync.helloTicker = sync:ScheduleRepeatingTimer("BroadcastHello", constants.HELLO_INTERVAL or 15)
    end
    if opts.autoSync == true and not sync.autoSyncTicker then
        sync.autoSyncTicker = sync:ScheduleRepeatingTimer("AutoSyncTick", constants.AUTO_SYNC_INTERVAL or 30)
    end
    if opts.queue == true and not sync.queueTicker then
        sync.queueTicker = sync:ScheduleRepeatingTimer("ProcessRequestQueue", 1)
    end
end

function CommBus:EnableRuntimeTickersForAllNodes(opts)
    for _, node in ipairs(self.nodes) do
        self:EnableRuntimeTickers(node, opts)
    end
end

function CommBus:SnapshotSavedVariables(node)
    self:Activate(node)
    return {
        db = deepcopy(_G.RecipeRegistryDB or node.addon.db or {}),
        charDB = deepcopy(_G.RecipeRegistryCharDB or node.addon.charDB or {}),
    }
end

function CommBus:RestoreSavedVariables(node, saved)
    saved = saved or {}
    self:Activate(node)
    node.addon.db = deepcopy(saved.db or saved.global or {})
    node.addon.charDB = deepcopy(saved.charDB or saved.char or {})
    _G.RecipeRegistryDB = node.addon.db
    _G.RecipeRegistryCharDB = node.addon.charDB
    return node.addon.db, node.addon.charDB
end

function CommBus:ReloadNode(node, opts)
    opts = opts or {}
    self:Activate(node)
    local saved = opts.savedVariables or self:SnapshotSavedVariables(node)
    local runtime = snapshotNodeRuntime(node)
    local previousKey = node.key

    local addon = Loader.Load({
        reset = true,
        initialize = false,
        payloadMode = node.payloadMode or self.payloadMode,
        savedVariables = saved,
        addonMetadata = opts.addonMetadata or node.addonMetadata,
    })

    Wow.SetPlayer(runtime.playerName, runtime.realm)
    Wow.SetGuildRoster(runtime.guildRoster)
    Wow.SetCombat(runtime.inCombat)
    Wow.SetRaid(runtime.inRaid)
    Wow.SetInstance(runtime.inInstance, runtime.instanceType)
    Wow.SetSkillLines(runtime.skillLines)
    Wow.SetKnownSpells(runtime.knownSpells)
    if runtime.tradeSkill and runtime.tradeSkill.title then
        Wow.SetTradeSkill(runtime.tradeSkill.title, runtime.tradeSkill.entries, runtime.tradeSkill)
    end
    if runtime.craftSkill and runtime.craftSkill.title then
        Wow.SetCraftSkill(runtime.craftSkill.title, runtime.craftSkill.entries, runtime.craftSkill)
    end

    local nextState = Wow.GetState()
    nextState.now = runtime.now or nextState.now
    nextState.inGuild = runtime.inGuild ~= false
    Loader.Initialize(addon)

    node.addon = addon
    node.state = nextState
    node.sentCursor = 0
    node.addonMetadata = deepcopy(opts.addonMetadata or node.addonMetadata or {})
    self:Activate(node)
    node.key = addon.Data:GetPlayerKey()
    addon.Data:RebuildOnlineCache()
    addon.Sync:RegisterComm(addon.ADDON_PREFIX)
    addon.Sync:EnsureBackgroundWorkers()
    if node.runtimeTickers then
        self:EnableRuntimeTickers(node, node.runtimeTickers)
    end

    if previousKey and previousKey ~= node.key then
        self.nodeByKey[previousKey] = nil
    end
    self.nodeByKey[node.key] = node
    self.nodeByName[node.name] = node
    return node
end

function CommBus:SetRouteHook(fn)
    self.routeHook = fn
end

function CommBus:SetRosterOnline(name, online)
    local fullName = string.format("%s-%s", name, self.realm)
    for _, row in ipairs(self.roster or {}) do
        if row.name == fullName then
            row.online = online == true
        end
    end
end

function CommBus:RefreshRosterForNode(node)
    self:Activate(node)
    Wow.SetGuildRoster(self.roster)
    node.addon.Data:RebuildOnlineCache()
    node.addon.Sync:OnGuildRosterUpdate()
end

function CommBus:SetNodeOnline(node, online)
    node.online = online == true
    self:SetRosterOnline(node.name, node.online)
    for _, other in ipairs(self.nodes) do
        self:RefreshRosterForNode(other)
    end
end

function CommBus:SetNodeInstance(node, inInstance, instanceType)
    self:Activate(node)
    Wow.SetInstance(inInstance == true, instanceType or (inInstance and "party" or "none"))
end

function CommBus:SeedSelfProfession(node, opts)
    opts = opts or {}
    self:Activate(node)
    local data = node.addon.Data
    local memberKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(memberKey)
    local profession = opts.profession or PROFESSIONS[((node.index - 1) % #PROFESSIONS) + 1]
    local recipeCount = opts.recipeCount or 1
    local recipes = {}
    local baseRecipe = opts.baseRecipe or (120000 + (node.index * 100))

    for offset = 1, recipeCount do
        recipes[baseRecipe + offset] = true
    end

    entry.owner = memberKey
    entry.rev = opts.rev or (5000 + node.index)
    entry.updatedAt = opts.updatedAt or (7000 + node.index)
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[profession] = {
        recipes = recipes,
        count = recipeCount,
        signature = stableRecipeSignature(recipes),
        skillRank = opts.skillRank or 375,
        skillMaxRank = opts.skillMaxRank or 375,
        blockRevision = entry.rev,
        lastUpdatedAt = entry.updatedAt,
        sourceType = "owner",
        guildStatus = "active",
        lastSeenInGuildAt = entry.updatedAt,
    }
    data:NormalizeMemberEntry(entry, memberKey)
    data:MarkManifestDirty(data:BuildSyncBlockKey(memberKey, profession), "comm-bus-seed")
    data:BuildManifestCacheNow("comm-bus-seed")
    return entry
end

function CommBus:SeedAllSelfData(opts)
    for _, node in ipairs(self.nodes) do
        self:SeedSelfProfession(node, opts)
    end
end

function CommBus:SeedReplicaProfession(node, ownerKey, profession, recipeKeys, opts)
    opts = opts or {}
    self:Activate(node)
    local data = node.addon.Data
    local entry = data:GetOrCreateMember(ownerKey)
    local recipes = {}
    local recipeCount = 0

    for _, recipeKey in ipairs(recipeKeys or {}) do
        recipes[recipeKey] = true
        recipeCount = recipeCount + 1
    end

    entry.owner = ownerKey
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or entry.rev or 1
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[profession] = {
        recipes = recipes,
        count = recipeCount,
        signature = stableRecipeSignature(recipes),
        skillRank = opts.skillRank or 375,
        skillMaxRank = opts.skillMaxRank or 375,
        specialization = opts.specialization,
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or "replica",
        guildStatus = opts.guildStatus or "active",
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    }
    data:NormalizeMemberEntry(entry, ownerKey)
    data:MarkManifestDirty(data:BuildSyncBlockKey(ownerKey, profession), "comm-bus-replica")
    data:BuildManifestCacheNow("comm-bus-replica")
    return entry
end

function CommBus:ForEachNode(fn)
    for _, node in ipairs(self.nodes) do
        self:Activate(node)
        fn(node)
    end
end

function CommBus:BroadcastHelloPresence(opts)
    opts = opts or {}
    self:ForEachNode(function(node)
        if not node.online then return end
        local summary = node.addon.Data:GetLocalSummary()
        node.addon.Sync:SendGuildEnvelope("HELLO", {
            key = node.key,
            rev = opts.useSummary and summary.rev or opts.rev or 0,
            updatedAt = opts.useSummary and summary.updatedAt or opts.updatedAt or 0,
            version = opts.version or "comm-bus-test",
        }, "ALERT")
    end)
end

function CommBus:BroadcastHello()
    self:ForEachNode(function(node)
        if node.online then
            node.addon.Sync:BroadcastHello()
        end
    end)
end

function CommBus:RecordEvent(eventType, data)
    if #self.events >= self.maxEvents then
        local trimCount = math.max(1, math.floor(self.maxEvents * 0.25))
        for index = trimCount + 1, #self.events do
            self.events[index - trimCount] = self.events[index]
        end
        for index = #self.events, (#self.events - trimCount) + 1, -1 do
            self.events[index] = nil
        end
    end
    local event = deepcopy(data or {})
    event.tick = event.tick or self.stats.ticks
    event.type = eventType
    self.events[#self.events + 1] = event
    return event
end

function CommBus:FindEvents(predicate)
    local matches = {}
    if realType(predicate) ~= "function" then
        return matches
    end
    for _, event in ipairs(self.events) do
        if predicate(event) then
            matches[#matches + 1] = event
        end
    end
    return matches
end

function CommBus:CountEventsByKind(kind)
    local count = 0
    for _, event in ipairs(self.events) do
        if event.kind == kind then
            count = count + 1
        end
    end
    return count
end

function CommBus:CountEventsByType(eventType)
    local count = 0
    for _, event in ipairs(self.events) do
        if event.type == eventType then
            count = count + 1
        end
    end
    return count
end

function CommBus:DumpEvents(opts)
    opts = opts or {}
    local last = opts.last or #self.events
    local startIndex = math.max(1, (#self.events - last) + 1)
    local lines = {}

    for index = startIndex, #self.events do
        local event = self.events[index]
        lines[#lines + 1] = string.format(
            "[%d] %s kind=%s sender=%s target=%s q=%s bytes=%s seq=%s/%s req=%s session=%s",
            event.tick or 0,
            tostring(event.type or "?"),
            tostring(event.kind or "?"),
            tostring(event.sender or "?"),
            tostring(event.target or "*"),
            tostring(event.queueDepth or ""),
            tostring(event.wireSize or ""),
            tostring(event.seq or ""),
            tostring(event.total or ""),
            tostring(event.requestId or ""),
            tostring(event.sessionId or "")
        )
    end

    return table.concat(lines, "\n")
end

function CommBus:RecordQueueDepth(name, value)
    self.stats.maxQueueDepths[name] = math.max(self.stats.maxQueueDepths[name] or 0, value or 0)
end

function CommBus:MaxQueueDepth(name)
    return self.stats.maxQueueDepths[name] or 0
end

function CommBus:RefreshTransportStats()
    local queued = self.transport.queued or {}
    local bytes = 0
    local maxAge = 0

    for _, item in ipairs(queued) do
        bytes = bytes + (item.metrics and item.metrics.wireSize or 0)
        maxAge = math.max(maxAge, math.max(0, self.stats.ticks - (item.createdAtTick or self.stats.ticks)))
    end

    self.transport.maxQueued = math.max(self.transport.maxQueued or 0, #queued)
    self.transport.maxBytesQueued = math.max(self.transport.maxBytesQueued or 0, bytes)
    self.transport.maxAgeTicks = math.max(self.transport.maxAgeTicks or 0, maxAge)

    self.stats.maxTransportQueue = self.transport.maxQueued
    self.stats.maxTransportBytesQueued = self.transport.maxBytesQueued
    self:RecordQueueDepth("transport", #queued)
end

function CommBus:BuildTransportRow(rawRow, payload, target)
    local metrics = {
        kind = payloadKind(payload),
        logicalSize = estimateLogicalSize(payload),
        wireSize = estimateWireSize(rawRow.message, payload),
        requestId = payload and payload.requestId or nil,
        sessionId = payload and payload.sessionId or nil,
        seq = payload and payload.seq or nil,
        total = payload and payload.total or nil,
        createdAtTick = self.stats.ticks,
        target = target and target.key or rawRow.target,
    }

    return {
        prefix = rawRow.prefix,
        message = deepcopy(rawRow.message),
        distribution = rawRow.distribution,
        target = rawRow.target,
        priority = rawRow.priority,
        sender = rawRow.sender,
        payload = deepcopy(payload),
        metrics = metrics,
    }
end

function CommBus:BuildEventData(item, extra)
    local metrics = item and item.row and item.row.metrics or {}
    local payload = item and item.row and item.row.payload or nil
    local data = {
        sender = item and item.sender and item.sender.key or nil,
        target = item and item.target and item.target.key or nil,
        kind = payloadKind(payload),
        memberKey = payload and payload.key or nil,
        manifestId = payload and payload.manifestId or nil,
        requestId = metrics.requestId,
        sessionId = metrics.sessionId,
        seq = metrics.seq,
        total = metrics.total,
        wireSize = metrics.wireSize,
        logicalSize = metrics.logicalSize,
        queueDepth = #(self.transport.queued or {}),
    }
    for key, value in pairs(extra or {}) do
        data[key] = value
    end
    return data
end

function CommBus:RecordDrop(kind, reason)
    self.stats.dropped = self.stats.dropped + 1
    self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
    self.transport.dropped = (self.transport.dropped or 0) + 1
    self:RecordEvent("DROP", {
        kind = kind,
        reason = reason,
        queueDepth = #(self.transport.queued or {}),
    })
end

function CommBus:EnqueueTransport(senderNode, target, rawRow, payload, extraDelayTicks)
    local kind = payloadKind(payload)
    self.transport.nextId = self.transport.nextId + 1
    local itemId = self.transport.nextId

    if (self.transport.profile.dropRate or 0) > 0 and deterministicFraction(itemId) < (self.transport.profile.dropRate or 0) then
        self:RecordDrop(kind, "transport-profile-drop")
        return false
    end

    local profileDelay = computeProfileDelay(self.transport.profile, itemId, senderNode, target)
    local totalDelay = math.max(0, extraDelayTicks or 0) + profileDelay
    local row = self:BuildTransportRow(rawRow, payload, target)
    local item = {
        id = itemId,
        dueTick = self.stats.ticks + totalDelay,
        createdAtTick = self.stats.ticks,
        sender = senderNode,
        target = target,
        row = row,
    }

    self.transport.queued[#self.transport.queued + 1] = item
    if totalDelay > 0 then
        self.stats.delayed = self.stats.delayed + 1
        self.transport.delayed = self.transport.delayed + 1
    end

    self:RefreshTransportStats()
    self:RecordEvent("SEND", self:BuildEventData(item, {
        dueTick = item.dueTick,
    }))
    return true
end

function CommBus:DeliverToTarget(senderNode, target, row)
    local payload = row and row.payload or decodePayload(row and row.message)
    local kind = payloadKind(payload)

    if not (senderNode and senderNode.online and target and target.online) then
        self.stats.dropped = self.stats.dropped + 1
        self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
        self.transport.dropped = (self.transport.dropped or 0) + 1
        return false
    end

    self:Activate(target)
    target.addon.Sync:OnCommReceived(
        row.prefix,
        deepcopy(row.message),
        row.distribution,
        senderNode.key
    )
    self.stats.delivered = self.stats.delivered + 1
    self.stats.deliveredKinds[kind] = (self.stats.deliveredKinds[kind] or 0) + 1
    return true
end

function CommBus:QueueDelayedDelivery(senderNode, target, row, delayTicks)
    local payload = row and (row.payload or decodePayload(row.message)) or nil
    return self:EnqueueTransport(senderNode, target, row, payload, math.max(1, delayTicks or 1))
end

function CommBus:RouteTarget(senderNode, target, row, payload)
    if self.routeHook then
        local action, delayTicks = self.routeHook(self, senderNode, target, row, payload)
        if action == "drop" then
            self:RecordDrop(payloadKind(payload), "route-hook-drop")
            return false
        end
        if action == "delay" then
            return self:EnqueueTransport(senderNode, target, row, payload, math.max(1, delayTicks or 1))
        end
    end
    return self:EnqueueTransport(senderNode, target, row, payload, 0)
end

function CommBus:RouteMessage(senderNode, row)
    local payload = row and decodePayload(row.message) or nil
    local kind = payloadKind(payload)
    local targets = {}

    self.stats.sentKinds[kind] = (self.stats.sentKinds[kind] or 0) + 1

    if not senderNode.online then
        self:RecordDrop(kind, "sender-offline")
        return false
    end

    if row.distribution == "GUILD" then
        for _, node in ipairs(self.nodes) do
            if node ~= senderNode and node.online then
                targets[#targets + 1] = node
            end
        end
    elseif row.distribution == "WHISPER" then
        local target = self.nodeByName[row.target] or self.nodeByKey[row.target]
        if target and target.online then
            targets[1] = target
        end
    end

    if #targets == 0 then
        self:RecordDrop(kind, "no-targets")
        return false
    end

    local routed = false
    for _, target in ipairs(targets) do
        routed = self:RouteTarget(senderNode, target, row, payload) or routed
    end
    return routed
end

function CommBus:DrainComm(maxRows, flushThreshold)
    maxRows = maxRows or 100000
    flushThreshold = flushThreshold or 256
    local routed = 0
    local madeProgress = false

    for _, node in ipairs(self.nodes) do
        if not node.online then
            node.sentCursor = #(node.state.sentComm or {})
        else
            self:Activate(node)
            local sent = Wow.GetSentComm()
            while node.sentCursor < #sent and routed < maxRows do
                node.sentCursor = node.sentCursor + 1
                routed = routed + 1
                madeProgress = self:RouteMessage(node, sent[node.sentCursor]) or madeProgress
                if self.transport.profileName == "instant" or #(self.transport.queued or {}) >= flushThreshold then
                    madeProgress = self:ProcessTransportQueue() or madeProgress
                end
            end
        end
    end

    return madeProgress, routed
end

function CommBus:ProcessTransportQueue()
    if #(self.transport.queued or {}) == 0 then
        return false
    end

    table.sort(self.transport.queued, function(left, right)
        if left.dueTick ~= right.dueTick then
            return left.dueTick < right.dueTick
        end
        if self.transport.profile.reorder then
            return left.id > right.id
        end
        return left.id < right.id
    end)

    local maxMessages = self.transport.profile.maxMessagesPerTick or mathHuge
    local maxBytes = self.transport.profile.maxBytesPerTick or mathHuge
    local competingBytes = self.transport.profile.competingTrafficBytesPerTick or 0
    local remainingMessages = maxMessages
    local remainingBytes = maxBytes
    local deliveredThisTick = 0
    local madeProgress = false

    if maxBytes ~= mathHuge then
        self.transport.competingTrafficBytes = self.transport.competingTrafficBytes + competingBytes
        remainingBytes = math.max(0, maxBytes - competingBytes)
    end

    local kept = {}
    for _, item in ipairs(self.transport.queued) do
        local isDue = item.dueTick <= self.stats.ticks
        local wireSize = item.row.metrics.wireSize or 0
        local canConsumeMessageBudget = remainingMessages > 0
        local canConsumeByteBudget = (remainingBytes == mathHuge)
            or (wireSize <= remainingBytes)
            or deliveredThisTick == 0

        if isDue and canConsumeMessageBudget and canConsumeByteBudget then
            local delivered = self:DeliverToTarget(item.sender, item.target, item.row)
            deliveredThisTick = deliveredThisTick + 1
            remainingMessages = remainingMessages - 1
            if remainingBytes ~= mathHuge then
                if wireSize <= remainingBytes then
                    remainingBytes = remainingBytes - wireSize
                else
                    remainingBytes = 0
                end
            end
            if delivered then
                self.transport.delivered = self.transport.delivered + 1
                self.transport.deliveredBytes = self.transport.deliveredBytes + wireSize
                self:RecordEvent("DELIVER", self:BuildEventData(item, {
                    deliveredAtTick = self.stats.ticks,
                }))
            else
                self:RecordEvent("DROP", self:BuildEventData(item, {
                    reason = "target-offline",
                }))
            end
            madeProgress = true
        else
            kept[#kept + 1] = item
        end
    end

    self.transport.queued = kept
    self:RefreshTransportStats()
    return madeProgress
end

function CommBus:RecordNodeMetrics(node)
    local sync = node.addon.Sync
    local owners, blocks = outstandingCost(sync, false)
    local manifestOwners, manifestBlocks = outstandingCost(sync, true)
    local outboundChunkQueue = #(sync.outboundChunkQueue or {})
    local inboundChunkQueue = #(sync.inboundChunkQueue or {})
    local inboundFinalizeQueue = #(sync.inboundFinalizeQueue or {})
    local manifestCatchupQueue = #(sync.manifestCatchupQueue or {})
    local manifestChunkQueue = #(sync.manifestChunkQueue or {})
    local pendingRequests = countKeys(sync.pendingRequests or {})
    local activeRequests = sync.inFlight and 1 or 0

    if owners > self.stats.maxOutstandingOwners then
        self.stats.maxOutstandingOwners = owners
    end
    if blocks > self.stats.maxOutstandingBlocks then
        self.stats.maxOutstandingBlocks = blocks
    end
    if manifestOwners > self.stats.maxManifestOutstandingOwners then
        self.stats.maxManifestOutstandingOwners = manifestOwners
    end
    if manifestBlocks > self.stats.maxManifestOutstandingBlocks then
        self.stats.maxManifestOutstandingBlocks = manifestBlocks
    end

    self.stats.maxOutboundChunkQueue = math.max(self.stats.maxOutboundChunkQueue, outboundChunkQueue)
    self.stats.maxInboundChunkQueue = math.max(self.stats.maxInboundChunkQueue, inboundChunkQueue)
    self.stats.maxInboundFinalizeQueue = math.max(self.stats.maxInboundFinalizeQueue, inboundFinalizeQueue)
    self.stats.maxManifestCatchupQueue = math.max(self.stats.maxManifestCatchupQueue, manifestCatchupQueue)
    self.stats.maxManifestChunkQueue = math.max(self.stats.maxManifestChunkQueue, manifestChunkQueue)
    self.stats.maxPendingRequests = math.max(self.stats.maxPendingRequests, pendingRequests)
    self.stats.maxActiveRequests = math.max(self.stats.maxActiveRequests, activeRequests)
    self.stats.maxCatchupDeferred = self.stats.maxManifestCatchupQueue

    self:RecordQueueDepth("outboundChunkQueue", outboundChunkQueue)
    self:RecordQueueDepth("inboundChunkQueue", inboundChunkQueue)
    self:RecordQueueDepth("inboundFinalizeQueue", inboundFinalizeQueue)
    self:RecordQueueDepth("manifestCatchupQueue", manifestCatchupQueue)
    self:RecordQueueDepth("manifestChunkQueue", manifestChunkQueue)
    self:RecordQueueDepth("pendingRequests", pendingRequests)
    self:RecordQueueDepth("activeRequests", activeRequests)
end

function CommBus:Step(opts)
    opts = opts or {}
    local perfRuns = opts.perfRuns or 1
    local inboundRuns = opts.inboundRuns or 1
    local timerRuns = opts.timerRuns or 25
    local madeProgress = false

    self.stats.ticks = self.stats.ticks + 1

    for _, node in ipairs(self.nodes) do
        if not node.online then
            node.sentCursor = #(node.state.sentComm or {})
        else
            self:Activate(node)
            if Wow.RunDueTimers(timerRuns) > 0 then
                madeProgress = true
            end
            for _ = 1, perfRuns do
                node.addon.Performance:RunNextStep()
            end
            node.addon.Sync:ProcessRequestQueue()
            for _ = 1, inboundRuns do
                node.addon.Sync:ProcessInboundQueue()
            end
            self:RecordNodeMetrics(node)
        end
    end

    local delivered
    delivered, _ = self:DrainComm(opts.maxCommRows or 100000, opts.transportFlushThreshold or 256)
    madeProgress = delivered or madeProgress
    madeProgress = self:ProcessTransportQueue() or madeProgress

    self.now = self.now + (opts.tickSeconds or 0.05)
    self:RefreshTransportStats()
    return madeProgress
end

function CommBus:RunUntil(predicate, opts)
    opts = opts or {}
    local maxTicks = opts.maxTicks or 5000
    for _ = 1, maxTicks do
        self:Step(opts)
        if predicate(self) then
            return true, self.stats.ticks
        end
    end
    return false, self.stats.ticks
end

function CommBus:TransportIdle()
    return #(self.transport.queued or {}) == 0
end

function CommBus:NodeHasInFlightRequest(node)
    if not (node and node.online) then
        return false
    end
    self:Activate(node)
    return node.addon.Sync.inFlight ~= nil
end

function CommBus:NodeHasZombieRequests(node)
    if not node then
        return false
    end
    self:Activate(node)
    local sync = node.addon.Sync
    return sync.inFlight ~= nil
        or countKeys(sync.pendingRequests or {}) > 0
        or countKeys(sync.partialReceive or {}) > 0
        or countPartialManifestEntries(sync) > 0
        or countKeys(sync.outgoingSessions or {}) > 0
end

function CommBus:AllQueuesIdleForNode(node)
    if not node then
        return true
    end
    return not hasNodeWork(node)
end

function CommBus:DescribeNodeWork(node)
    if not node then
        return ""
    end
    local reasons = describeNodeWork(node)
    return table.concat(reasons, ", ")
end

function CommBus:NodesWithWork()
    local rows = {}
    for _, node in ipairs(self.nodes) do
        if node.online and hasNodeWork(node) then
            rows[#rows + 1] = {
                node = node,
                reasons = describeNodeWork(node),
            }
        end
    end
    table.sort(rows, function(a, b)
        return tostring(a.node and a.node.name or "") < tostring(b.node and b.node.name or "")
    end)
    return rows
end

function CommBus:DescribeWorkSummary(limit)
    local rows = self:NodesWithWork()
    if #rows == 0 then
        return "idle"
    end
    local parts = {}
    local maxRows = math.min(#rows, limit or 8)
    for index = 1, maxRows do
        local row = rows[index]
        parts[#parts + 1] = string.format(
            "%s[%s]",
            tostring(row.node and row.node.name or "?"),
            table.concat(row.reasons or {}, ",")
        )
    end
    if #rows > maxRows then
        parts[#parts + 1] = string.format("+%d more", #rows - maxRows)
    end
    return table.concat(parts, " ")
end

function CommBus:CountInFlightRequests()
    local total = 0
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            total = total + countKeys(node.addon.Sync:GetInFlightRequests())
        end
    end
    return total
end

function CommBus:CountPartialSnapshots()
    local total = 0
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            total = total + countKeys(node.addon.Sync.partialReceive or {})
        end
    end
    return total
end

function CommBus:CountPartialManifests()
    local total = 0
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            total = total + countPartialManifestEntries(node.addon.Sync)
        end
    end
    return total
end

function CommBus:CountManifestCatchupQueued()
    local total = 0
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            total = total + #(node.addon.Sync.manifestCatchupQueue or {})
        end
    end
    return total
end

function CommBus:CountOutboundChunksQueued()
    local total = 0
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            total = total + #(node.addon.Sync.outboundChunkQueue or {})
        end
    end
    return total
end

function CommBus:HasWork()
    for _, node in ipairs(self.nodes) do
        if node.online and hasNodeWork(node) then
            return true
        end
    end
    if not self:TransportIdle() then return true end
    return false
end

function CommBus:CountVisibleOwners(node, prefix)
    self:Activate(node)
    local count = 0
    local stale = 0
    local mock = 0
    for memberKey, entry in pairs(node.addon.Data:GetMembersDB()) do
        if not prefix or memberKey:find(prefix, 1, true) == 1 then
            count = count + 1
            if (entry.guildStatus or "active") ~= "active" then
                stale = stale + 1
            end
            if entry.isMock then
                mock = mock + 1
            end
        end
    end
    return count, stale, mock
end

function CommBus:AllNodesHaveOwners(expectedCount, prefix)
    for _, node in ipairs(self.nodes) do
        if node.online then
            local count, stale, mock = self:CountVisibleOwners(node, prefix)
            if count ~= expectedCount or stale ~= 0 or mock ~= 0 then
                return false
            end
        end
    end
    return true
end

function CommBus:AllOnlineNodesHaveOwnerKeys(ownerKeys)
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            local members = node.addon.Data:GetMembersDB()
            for _, ownerKey in ipairs(ownerKeys or {}) do
                if not members[ownerKey] or (members[ownerKey].guildStatus or "active") ~= "active" then
                    return false
                end
            end
        end
    end
    return true
end

function CommBus:AllQueuesIdle()
    return not self:HasWork()
end

function CommBus:CoordinatorKey()
    local keys = {}
    for _, node in ipairs(self.nodes) do
        if node.online then
            keys[#keys + 1] = node.key
        end
    end
    table.sort(keys)
    return keys[1]
end

function CommBus:AllNodesAgreeOnCoordinator()
    local expected = self:CoordinatorKey()
    if not expected then return false end
    for _, node in ipairs(self.nodes) do
        if node.online then
            self:Activate(node)
            if node.addon.Sync.coordinatorKey ~= expected then
                return false
            end
        end
    end
    return true
end

function CommBus:OnlineOwnerKeys(prefix)
    local keys = {}
    for _, node in ipairs(self.nodes) do
        if node.online and (not prefix or node.key:find(prefix, 1, true) == 1) then
            keys[#keys + 1] = node.key
        end
    end
    table.sort(keys)
    return keys
end

function CommBus:CountRecipes(node, memberKey, profession)
    self:Activate(node)
    local entry = node.addon.Data:GetMember(memberKey)
    local prof = entry and entry.professions and entry.professions[profession]
    local count = 0
    for _ in pairs(prof and prof.recipes or {}) do
        count = count + 1
    end
    return count
end

function CommBus.CreatePeers(count, opts)
    opts = opts or {}
    local names = {}
    local prefix = opts.prefix or "Buspeer"
    for index = 1, count do
        names[index] = string.format("%s%03d", prefix, index)
    end

    local bus = CommBus.New({
        names = names,
        realm = opts.realm or "TestRealm",
        now = opts.now,
        transportProfile = opts.transportProfile,
        payloadMode = opts.payloadMode,
    })
    for _, name in ipairs(names) do
        bus:AddNode(name, {
            payloadMode = opts.payloadMode,
            runtimeTickers = opts.runtimeTickers,
        })
    end
    return bus, names
end

CommBus._private = {
    countKeys = countKeys,
    outstandingCost = outstandingCost,
    deepcopy = deepcopy,
    decodePayload = decodePayload,
    estimateLogicalSize = estimateLogicalSize,
    estimateWireSize = estimateWireSize,
}

return CommBus
