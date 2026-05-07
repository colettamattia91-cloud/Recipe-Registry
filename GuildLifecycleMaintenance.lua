local Addon = _G.RecipeRegistry
local GuildLifecycleMaintenance = Addon:NewModule("GuildLifecycleMaintenance")
Addon.GuildLifecycleMaintenance = GuildLifecycleMaintenance

local pairs = pairs
local ipairs = ipairs
local floor = math.floor

local WEEK_SECONDS = 7 * 24 * 60 * 60
local STALE_RETENTION_SECONDS = 28 * 24 * 60 * 60
local CLEANUP_CHUNK_SIZE = 25
local ROSTER_MIN_KNOWN_FOR_RATIO = 6
local ROSTER_MIN_SNAPSHOT_RATIO = 0.5

function GuildLifecycleMaintenance:OnInitialize()
    self._running = false
    self._lastRunInfo = nil
end

function GuildLifecycleMaintenance:ShouldRunWeeklyCleanup()
    if not Addon.Data then return false end
    local meta = Addon.Data:GetGlobalMeta()
    local lastRun = meta and meta.lastWeeklyCleanupAt or 0
    return (time() - lastRun) >= WEEK_SECONDS
end

function GuildLifecycleMaintenance:BuildGuildRosterSnapshot()
    local snapshot = {}
    local count = 0
    local total = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, total do
        local fullName = GetGuildRosterInfo and GetGuildRosterInfo(i)
        if fullName then
            local name, realm = fullName:match("^([^%-]+)%-(.+)$")
            if not name then
                name = fullName
                realm = GetRealmName() or "UnknownRealm"
            end
            realm = (realm or "UnknownRealm"):gsub("[%s%-]", "")
            local memberKey = name .. "-" .. realm
            if not snapshot[memberKey] then
                snapshot[memberKey] = true
                count = count + 1
            end
        end
    end
    return snapshot, count
end

function GuildLifecycleMaintenance:CountSnapshotMembers(snapshot)
    local count = 0
    for _ in pairs(snapshot or {}) do
        count = count + 1
    end
    return count
end

function GuildLifecycleMaintenance:CountKnownActiveMembers(memberKeys)
    local count = 0
    for _, memberKey in ipairs(memberKeys or {}) do
        local entry = Addon.Data and Addon.Data:GetMember(memberKey) or nil
        if entry and (entry.guildStatus or "active") == "active" then
            count = count + 1
        end
    end
    return count
end

function GuildLifecycleMaintenance:ValidateRosterSnapshot(snapshot, snapshotCount, memberKeys, opts)
    opts = opts or {}
    if opts.mock or opts.skipRosterValidation then
        return true, nil, snapshotCount or self:CountSnapshotMembers(snapshot), 0
    end

    local knownActive = self:CountKnownActiveMembers(memberKeys)
    snapshotCount = snapshotCount or self:CountSnapshotMembers(snapshot)
    if knownActive <= 0 then
        return true, nil, snapshotCount, knownActive
    end
    if snapshotCount <= 0 then
        return false, "roster-empty", snapshotCount, knownActive
    end
    if knownActive >= ROSTER_MIN_KNOWN_FOR_RATIO
        and snapshotCount < floor(knownActive * ROSTER_MIN_SNAPSHOT_RATIO) then
        return false, "roster-too-small", snapshotCount, knownActive
    end
    return true, nil, snapshotCount, knownActive
end

function GuildLifecycleMaintenance:MarkStaleMembers(memberKey, now)
    if not memberKey then return false end
    return Addon.Data:MarkMemberStale(memberKey, now)
end

function GuildLifecycleMaintenance:PruneExpiredStaleRecords(memberKey, now)
    if not memberKey then return false end
    local entry = Addon.Data:GetMember(memberKey)
    if not entry or (entry.guildStatus or "active") ~= "stale" then
        return false
    end
    if (entry.staleAt or 0) <= 0 then
        return false
    end
    if (now - (entry.staleAt or now)) < STALE_RETENTION_SECONDS then
        return false
    end
    Addon.Data:DeleteMember(memberKey)
    return true
end

function GuildLifecycleMaintenance:RunCleanupStep(state)
    local now = time()
    local processed = 0
    while processed < CLEANUP_CHUNK_SIZE and state.index <= #state.memberKeys do
        local memberKey = state.memberKeys[state.index]
        state.index = state.index + 1
        processed = processed + 1
        state.processed = (state.processed or 0) + 1

        if state.snapshot[memberKey] then
            if Addon.Data:MarkMemberActive(memberKey, now) then
                state.keptActive = (state.keptActive or 0) + 1
            end
        else
            if self:MarkStaleMembers(memberKey, now) then
                state.markedStale = (state.markedStale or 0) + 1
            end
            if self:PruneExpiredStaleRecords(memberKey, now) then
                state.pruned = (state.pruned or 0) + 1
            end
        end
    end

    if state.index > #state.memberKeys then
        self._running = false
        self._lastRunInfo = {
            label = state.label or "guild-cleanup",
            startedAt = state.startedAt or now,
            finishedAt = now,
            processed = state.processed or 0,
            keptActive = state.keptActive or 0,
            markedStale = state.markedStale or 0,
            pruned = state.pruned or 0,
            aborted = false,
            snapshotCount = state.snapshotCount or 0,
            knownActive = state.knownActive or 0,
            mock = state.mock == true,
        }
        if state.updateLastRunAt ~= false then
            Addon.Data:SetLastWeeklyCleanupAt(now)
        end
        Addon:RequestRefresh("guild-cleanup")
        return false, state
    end
    return true, state
end

function GuildLifecycleMaintenance:StartCleanup(opts)
    opts = opts or {}
    if self._running then
        return false, "already-running"
    end
    if not opts.force and not self:ShouldRunWeeklyCleanup() then
        return false, "not-due"
    end
    if not Addon.Performance then return false end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end

    local snapshot, snapshotCount
    if opts.snapshot then
        snapshot = opts.snapshot
        snapshotCount = self:CountSnapshotMembers(snapshot)
    else
        snapshot, snapshotCount = self:BuildGuildRosterSnapshot()
    end
    local memberKeys = opts.memberKeys or Addon.Data:GetSortedMemberKeys(true)
    local validRoster, rosterReason, finalSnapshotCount, knownActive = self:ValidateRosterSnapshot(snapshot, snapshotCount, memberKeys, opts)
    if not validRoster then
        local now = time()
        self._lastRunInfo = {
            label = opts.label or (opts.force and "guild-manual-cleanup" or "guild-weekly-cleanup"),
            startedAt = now,
            finishedAt = now,
            processed = 0,
            keptActive = 0,
            markedStale = 0,
            pruned = 0,
            aborted = true,
            abortReason = rosterReason,
            snapshotCount = finalSnapshotCount or 0,
            knownActive = knownActive or 0,
            mock = opts.mock == true,
        }
        Addon:Debug("Guild roster cleanup aborted:", rosterReason, "snapshot", finalSnapshotCount or 0, "knownActive", knownActive or 0)
        return false, rosterReason
    end

    self._running = true
    Addon.Performance:ScheduleJob("guild-cleanup", function(state)
        return self:RunCleanupStep(state)
    end, {
        category = "maintenance",
        label = opts.label or (opts.force and "guild-manual-cleanup" or "guild-weekly-cleanup"),
        budgetMs = 2,
        state = {
            snapshot = snapshot,
            memberKeys = memberKeys,
            index = 1,
            startedAt = time(),
            processed = 0,
            keptActive = 0,
            markedStale = 0,
            pruned = 0,
            snapshotCount = finalSnapshotCount or snapshotCount or 0,
            knownActive = knownActive or 0,
            updateLastRunAt = opts.updateLastRunAt ~= false,
            label = opts.label or (opts.force and "guild-manual-cleanup" or "guild-weekly-cleanup"),
            mock = opts.mock == true,
        },
    })
    return true
end

function GuildLifecycleMaintenance:StartWeeklyCleanup()
    return self:StartCleanup({ force = false })
end

function GuildLifecycleMaintenance:StartManualCleanup()
    return self:StartCleanup({ force = true })
end

function GuildLifecycleMaintenance:IsCleanupRunning()
    return self._running == true
end

function GuildLifecycleMaintenance:GetLastRunInfo()
    return self._lastRunInfo
end
