local Loader = dofile("local-tests/harness/load-addon.lua")
local Wow = Loader.Wow

local CommBus = {}
CommBus.__index = CommBus

local unpack = unpack
local realType = type

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
        if next(manifests or {}) ~= nil then return true end
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

function CommBus.New(opts)
    opts = opts or {}
    local names = opts.names or {}
    local bus = {
        realm = opts.realm or "TestRealm",
        now = opts.now or 1700000000,
        nodes = {},
        nodeByKey = {},
        nodeByName = {},
        roster = makeRoster(names, opts.realm or "TestRealm"),
        delayed = {},
        routeHook = opts.routeHook,
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
            maxManifestChunkQueue = 0,
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
    return node.addon
end

function CommBus:AddNode(name, opts)
    opts = opts or {}
    local addon = Loader.Load({ reset = true, initialize = false })
    Wow.SetPlayer(name, self.realm)
    Wow.SetGuildRoster(self.roster)
    Loader.Initialize(addon)

    local node = {
        name = name,
        addon = addon,
        state = Wow.GetState(),
        sentCursor = 0,
        index = #self.nodes + 1,
        online = opts.online ~= false,
    }
    self:Activate(node)
    node.key = addon.Data:GetPlayerKey()
    addon.Data:RebuildOnlineCache()
    addon.Sync:RegisterComm(addon.ADDON_PREFIX)
    addon.Sync:EnsureBackgroundWorkers()

    self.nodes[#self.nodes + 1] = node
    self.nodeByKey[node.key] = node
    self.nodeByName[name] = node
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

function CommBus:DeliverToTarget(senderNode, target, row)
    if not (senderNode and senderNode.online and target and target.online) then
        local payload = row and row.message
        local kind = realType(payload) == "table" and payload.kind or "?"
        self.stats.dropped = self.stats.dropped + 1
        self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
        return false
    end
    local payload = row and row.message
    local kind = realType(payload) == "table" and payload.kind or "?"
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
    self.delayed[#self.delayed + 1] = {
        dueTick = self.stats.ticks + math.max(1, delayTicks or 1),
        sender = senderNode,
        target = target,
        row = deepcopy(row),
    }
    self.stats.delayed = self.stats.delayed + 1
end

function CommBus:RouteTarget(senderNode, target, row)
    local payload = row and row.message
    local kind = realType(payload) == "table" and payload.kind or "?"
    if self.routeHook then
        local action, delayTicks = self.routeHook(self, senderNode, target, row, payload)
        if action == "drop" then
            self.stats.dropped = self.stats.dropped + 1
            self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
            return false
        end
        if action == "delay" then
            self:QueueDelayedDelivery(senderNode, target, row, delayTicks)
            return true
        end
    end
    return self:DeliverToTarget(senderNode, target, row)
end

function CommBus:RouteMessage(senderNode, row)
    local payload = row and row.message
    local kind = realType(payload) == "table" and payload.kind or "?"
    local targets = {}

    self.stats.sentKinds[kind] = (self.stats.sentKinds[kind] or 0) + 1

    if not senderNode.online then
        self.stats.dropped = self.stats.dropped + 1
        self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
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
        self.stats.dropped = self.stats.dropped + 1
        self.stats.droppedKinds[kind] = (self.stats.droppedKinds[kind] or 0) + 1
        return false
    end

    local delivered = false
    for _, target in ipairs(targets) do
        delivered = self:RouteTarget(senderNode, target, row) or delivered
    end
    return delivered
end

function CommBus:DeliverDelayed()
    if #self.delayed == 0 then return false end
    local kept = {}
    local delivered = false

    for _, item in ipairs(self.delayed) do
        if item.dueTick <= self.stats.ticks then
            delivered = self:DeliverToTarget(item.sender, item.target, item.row) or delivered
        else
            kept[#kept + 1] = item
        end
    end

    self.delayed = kept
    return delivered
end

function CommBus:DrainComm(maxRows)
    maxRows = maxRows or 100000
    local routed = 0
    local madeProgress = false

    for _, node in ipairs(self.nodes) do
        if not node.online then
            node.sentCursor = #(node.state.sentComm or {})
        end
        if not node.online then
            -- Offline clients cannot publish queued traffic.
        else
        self:Activate(node)
        local sent = Wow.GetSentComm()
        while node.sentCursor < #sent and routed < maxRows do
            node.sentCursor = node.sentCursor + 1
            routed = routed + 1
            madeProgress = self:RouteMessage(node, sent[node.sentCursor]) or madeProgress
        end
        end
    end

    return madeProgress, routed
end

function CommBus:RecordNodeMetrics(node)
    local sync = node.addon.Sync
    local owners, blocks = outstandingCost(sync, false)
    local manifestOwners, manifestBlocks = outstandingCost(sync, true)

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
    if #(sync.manifestCatchupQueue or {}) > self.stats.maxCatchupDeferred then
        self.stats.maxCatchupDeferred = #(sync.manifestCatchupQueue or {})
    end
    if #(sync.manifestChunkQueue or {}) > self.stats.maxManifestChunkQueue then
        self.stats.maxManifestChunkQueue = #(sync.manifestChunkQueue or {})
    end
end

function CommBus:Step(opts)
    opts = opts or {}
    local perfRuns = opts.perfRuns or 1
    local inboundRuns = opts.inboundRuns or 1
    local timerRuns = opts.timerRuns or 25
    local madeProgress = false

    self.stats.ticks = self.stats.ticks + 1
    madeProgress = self:DeliverDelayed() or madeProgress

    for _, node in ipairs(self.nodes) do
        if not node.online then
            node.sentCursor = #(node.state.sentComm or {})
        end
        if not node.online then
            -- Offline clients keep their local state but do not tick.
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
    delivered, _ = self:DrainComm(opts.maxCommRows or 100000)
    madeProgress = delivered or madeProgress
    self.now = self.now + (opts.tickSeconds or 0.05)
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

function CommBus:HasWork()
    for _, node in ipairs(self.nodes) do
        if node.online and hasNodeWork(node) then
            return true
        end
    end
    if #(self.delayed or {}) > 0 then return true end
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
        if not node.online then
            -- Offline clients are not part of convergence assertions.
        else
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
        if not node.online then
            -- Offline clients are ignored for live coordinator assertions.
        else
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
    })
    for _, name in ipairs(names) do
        bus:AddNode(name)
    end
    return bus, names
end

CommBus._private = {
    countKeys = countKeys,
    outstandingCost = outstandingCost,
    deepcopy = deepcopy,
}

return CommBus
