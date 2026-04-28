local Addon = _G.RecipeRegistry
local Performance = Addon:NewModule("Performance", "AceTimer-3.0")
Addon.Performance = Performance

local pairs = pairs
local type = type
local tremove = table.remove
local min = math.min

local TICK_INTERVAL = 0.05
local DEFAULT_BUDGET_MS = 3
local DEFAULT_MAX_STEPS = 6

local function nowMs()
    if type(debugprofilestop) == "function" then
        return debugprofilestop()
    end
    return GetTime() * 1000
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function safeCall(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555Recipe Registry error:|r " .. tostring(a))
        return nil, nil, nil
    end
    return a, b, c
end

function Performance:OnInitialize()
    self.jobQueues = {}
    self.jobOrder = {}
    self.pausedCategories = {}
    self.pendingUIRefreshScopes = {}
    self.telemetry = {
        jobsScheduled = 0,
        jobsCompleted = 0,
        jobSteps = 0,
        jobYields = 0,
        pausedSkips = 0,
        deferredUIRefreshCount = 0,
        uiRefreshFlushes = 0,
        uiRefreshMarks = 0,
        averageStepCostMs = 0,
        maxStepCostMs = 0,
        overBudgetSteps = 0,
    }
    self._jobSequence = 0
    self._queueCursor = 0
    self._uiFlushQueued = false
end

function Performance:ResetTelemetry()
    self.telemetry = {
        jobsScheduled = 0,
        jobsCompleted = 0,
        jobSteps = 0,
        jobYields = 0,
        pausedSkips = 0,
        deferredUIRefreshCount = 0,
        uiRefreshFlushes = 0,
        uiRefreshMarks = 0,
        averageStepCostMs = 0,
        maxStepCostMs = 0,
        overBudgetSteps = 0,
    }
end

function Performance:OnEnable()
    if not self.ticker then
        self.ticker = self:ScheduleRepeatingTimer("RunNextStep", TICK_INTERVAL)
    end
end

function Performance:ScheduleJob(jobType, fn, opts)
    if type(fn) ~= "function" then return nil end

    opts = opts or {}
    local category = opts.category or jobType or "general"
    local queue = self.jobQueues[category]
    if not queue then
        queue = {}
        self.jobQueues[category] = queue
        self.jobOrder[#self.jobOrder + 1] = category
    end

    self._jobSequence = self._jobSequence + 1
    local job = {
        id = self._jobSequence,
        type = jobType or "job",
        category = category,
        label = opts.label or jobType or "job",
        fn = fn,
        budgetMs = opts.budgetMs or DEFAULT_BUDGET_MS,
        maxStepsPerRun = opts.maxStepsPerRun or 1,
        enqueuedAt = time(),
        state = opts.state or {},
    }

    queue[#queue + 1] = job
    self.telemetry.jobsScheduled = self.telemetry.jobsScheduled + 1
    return job.id
end

function Performance:PauseCategory(category)
    if not category then return end
    self.pausedCategories[category] = true
end

function Performance:ResumeCategory(category)
    if not category then return end
    self.pausedCategories[category] = nil
end

function Performance:IsCategoryPaused(category)
    return category and self.pausedCategories[category] == true or false
end

function Performance:HasPendingJobs(category)
    if category then
        return self.jobQueues[category] and #self.jobQueues[category] > 0 or false
    end
    for _, queue in pairs(self.jobQueues) do
        if #queue > 0 then return true end
    end
    return false
end

function Performance:GetNextRunnableCategory()
    local total = #self.jobOrder
    if total == 0 then return nil end

    for offset = 1, total do
        local index = ((self._queueCursor + offset - 1) % total) + 1
        local category = self.jobOrder[index]
        local queue = self.jobQueues[category]
        if queue and #queue > 0 then
            if not self:IsCategoryPaused(category) then
                self._queueCursor = index
                return category, queue
            end
            self.telemetry.pausedSkips = self.telemetry.pausedSkips + 1
        end
    end

    return nil
end

function Performance:RunJobStep(job, budgetMs)
    local startedAt = nowMs()
    local stepBudget = min(job.budgetMs or DEFAULT_BUDGET_MS, budgetMs or DEFAULT_BUDGET_MS)
    local keepGoing, newState = safeCall(job.fn, job.state, {
        budgetMs = stepBudget,
        startedAtMs = startedAt,
        jobId = job.id,
        jobType = job.type,
        category = job.category,
    })
    local elapsed = nowMs() - startedAt

    self.telemetry.jobSteps = self.telemetry.jobSteps + 1
    local n = self.telemetry.jobSteps
    self.telemetry.averageStepCostMs = ((self.telemetry.averageStepCostMs * (n - 1)) + elapsed) / n
    if elapsed > (self.telemetry.maxStepCostMs or 0) then
        self.telemetry.maxStepCostMs = elapsed
    end
    if elapsed > stepBudget then
        self.telemetry.overBudgetSteps = (self.telemetry.overBudgetSteps or 0) + 1
    end

    if newState ~= nil then
        job.state = newState
    end

    if keepGoing then
        self.telemetry.jobYields = self.telemetry.jobYields + 1
        return true, elapsed
    end

    self.telemetry.jobsCompleted = self.telemetry.jobsCompleted + 1
    return false, elapsed
end

function Performance:RunNextStep()
    local startedAt = nowMs()
    local budgetMs = DEFAULT_BUDGET_MS
    local remainingSteps = DEFAULT_MAX_STEPS

    while remainingSteps > 0 and (nowMs() - startedAt) < budgetMs do
        local category, queue = self:GetNextRunnableCategory()
        if not category then break end

        local job = queue[1]
        if not job then break end

        local keepGoing, elapsed = self:RunJobStep(job, budgetMs - (nowMs() - startedAt))
        remainingSteps = remainingSteps - 1

        if keepGoing then
            tremove(queue, 1)
            queue[#queue + 1] = job
        else
            tremove(queue, 1)
        end

        if elapsed <= 0 then
            break
        end
    end

    if self._uiFlushQueued then
        self:FlushDeferredUIRefresh()
    end
end

function Performance:MarkUIRefreshNeeded(scope)
    if scope then
        self.pendingUIRefreshScopes[scope] = true
    else
        self.pendingUIRefreshScopes.general = true
    end
    self._uiFlushQueued = true
    self.telemetry.uiRefreshMarks = self.telemetry.uiRefreshMarks + 1
end

function Performance:FlushDeferredUIRefresh(force)
    if not next(self.pendingUIRefreshScopes) then
        self._uiFlushQueued = false
        return false
    end

    if not force and self:IsCategoryPaused("ui") then
        return false
    end

    local ui = Addon.UI
    if not (ui and ui.frame and ui.frame:IsShown() and ui.Refresh) then
        return false
    end

    local scopes = self.pendingUIRefreshScopes
    self.pendingUIRefreshScopes = {}
    self._uiFlushQueued = false
    self.telemetry.deferredUIRefreshCount = self.telemetry.deferredUIRefreshCount + countKeys(scopes)
    self.telemetry.uiRefreshFlushes = self.telemetry.uiRefreshFlushes + 1
    safeCall(ui.Refresh, ui, scopes)
    return true
end

function Performance:GetTelemetry()
    return self.telemetry
end

function Performance:GetQueueLengths()
    local result = {}
    for category, queue in pairs(self.jobQueues or {}) do
        result[category] = #queue
    end
    return result
end

function Performance:GetUiState()
    return {
        pendingCategories = countKeys(self.jobQueues),
        pausedCategories = countKeys(self.pausedCategories),
        pendingUIRefresh = countKeys(self.pendingUIRefreshScopes),
        averageStepCostMs = self.telemetry.averageStepCostMs,
    }
end

function Performance:GetDebugSnapshot()
    return {
        telemetry = self:GetTelemetry(),
        queueLengths = self:GetQueueLengths(),
        pendingUIRefresh = countKeys(self.pendingUIRefreshScopes),
        pausedCategories = self.pausedCategories,
        tickInterval = TICK_INTERVAL,
        defaultBudgetMs = DEFAULT_BUDGET_MS,
    }
end

function Performance:DumpDebugStatus()
    local snapshot = self:GetDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    local queueLengths = snapshot.queueLengths or {}
    local queueParts = {}
    for category, size in pairs(queueLengths) do
        queueParts[#queueParts + 1] = string.format("%s=%d", tostring(category), tonumber(size) or 0)
    end
    table.sort(queueParts)
    Addon:Print(string.format(
        "Perf steps=%d avg=%.2fms max=%.2fms overBudget=%d uiFlush=%d uiMarks=%d queues=%s",
        telemetry.jobSteps or 0,
        telemetry.averageStepCostMs or 0,
        telemetry.maxStepCostMs or 0,
        telemetry.overBudgetSteps or 0,
        telemetry.uiRefreshFlushes or 0,
        telemetry.uiRefreshMarks or 0,
        #queueParts > 0 and table.concat(queueParts, ", ") or "none"
    ))
end
