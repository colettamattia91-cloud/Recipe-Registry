local Addon = _G.RecipeRegistry
local Tooltip = Addon:NewModule("Tooltip", "AceEvent-3.0", "AceTimer-3.0")
Addon.Tooltip = Tooltip

local MAX_TOOLTIP_CRAFTERS = 5
local TOOLTIP_INDEX_RECIPES_PER_STEP = 64

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local tostring = tostring
local tonumber = tonumber

local function extractItemID(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

local function makeItemKey(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    return "item:" .. tostring(itemID)
end

local function makeSpellKey(spellID)
    spellID = tonumber(spellID)
    if not spellID then return nil end
    return "spell:" .. tostring(spellID)
end

local function getRecipeMetadata()
    return Addon.RecipeMetadata
end

local function addRecipeKey(index, key, recipeKey)
    if not key or recipeKey == nil then return end
    local bucket = index[key]
    if not bucket then
        bucket = { recipeKeys = {}, seen = {} }
        index[key] = bucket
    end

    local seenKey = tostring(recipeKey)
    if bucket.seen[seenKey] then return end
    bucket.seen[seenKey] = true
    bucket.recipeKeys[#bucket.recipeKeys + 1] = recipeKey
end

local function sortRows(rows)
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.skillRank ~= b.skillRank then return a.skillRank > b.skillRank end
        if a.memberKey ~= b.memberKey then return tostring(a.memberKey) < tostring(b.memberKey) end
        if a.profession ~= b.profession then return tostring(a.profession) < tostring(b.profession) end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)
end

function Tooltip:OnEnable()
    self.indexDirty = true
    self.index = {}
    self.indexVersion = 0
    self._indexBuildGeneration = 0
    self._indexBuildJobActive = false
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "InvalidateIndex")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "InvalidateIndex")
    self.watchedTooltips = self.watchedTooltips or {}
    if GameTooltip then
        self.watchedTooltips[GameTooltip] = true
    end
    if ItemRefTooltip then
        self.watchedTooltips[ItemRefTooltip] = true
    end
    self:RegisterTooltipHooks()
    self:InvalidateIndex()
end

-- TooltipUtil.GetDisplayedSpell risponde (nome, spellID); prendere l'ultimo
-- valore numerico regge anche se un giorno ci aggiunge qualcosa davanti.
local function lastNumericValue(...)
    for i = select("#", ...), 1, -1 do
        local value = tonumber((select(i, ...)))
        if value then return value end
    end
    return nil
end

-- La pipeline retail dei tooltip, se il client ce l'ha.
--
-- Su Forever e' l'unica che c'e'. Sondato in gioco il 2026-09-21:
-- TooltipDataProcessor e TooltipUtil sono tabelle, GameTooltip:GetItem e' ancora
-- una funzione -- ma lo SCRIPT OnTooltipSetItem non esiste piu'. Questo file
-- arrivava da TBC con i soli script legacy, e qui non si agganciava a niente:
-- _tooltipHooksRegistered restava nil e i crafter non comparivano mai, senza un
-- errore. Il percorso legacy e' stato tolto invece che tenuto come ripiego,
-- perche' su questo client non scatta mai.
--
-- Su retail non e' GetItem a sparire, come si poteva pensare: e' lo script. Gli
-- accessori sono rimasti, gli eventi no.
local function retailTooltipPipeline()
    local processor = _G.TooltipDataProcessor
    local dataTypes = _G.Enum and _G.Enum.TooltipDataType
    if type(processor) ~= "table" or type(processor.AddTooltipPostCall) ~= "function" then
        return nil
    end
    if type(dataTypes) ~= "table" or dataTypes.Item == nil then
        return nil
    end
    return processor, dataTypes
end

function Tooltip:RegisterRetailTooltipHooks(processor, dataTypes)
    -- Le post-call arrivano per OGNI tooltip del gioco, confronti, tooltip
    -- incorporati e protetti compresi. Scriviamo solo su quelli che guardiamo,
    -- e mai su uno protetto, dove toccarlo e' un errore.
    local function accept(tooltip)
        if not self.watchedTooltips[tooltip] then return false end
        if tooltip.IsForbidden and tooltip:IsForbidden() then return false end
        -- Ogni post-call segue una ricostruzione del tooltip, che ha gia'
        -- svuotato le righe. La chiave anti-doppione di AddCraftLines vale
        -- dentro una costruzione; fra una e l'altra, se restasse, al primo
        -- aggiornamento del tooltip le nostre righe sparirebbero e non
        -- tornerebbero piu'.
        tooltip._rrCraftRenderedKey = nil
        return true
    end

    processor.AddTooltipPostCall(dataTypes.Item, function(tooltip, data)
        if not accept(tooltip) then return end
        local itemID = type(data) == "table" and tonumber(data.id) or nil
        if not itemID then
            local util = _G.TooltipUtil
            if type(util) == "table" and type(util.GetDisplayedItem) == "function" then
                local _, link, id = util.GetDisplayedItem(tooltip)
                itemID = tonumber(id) or extractItemID(link)
            end
        end
        self:OnTooltipSetItem(tooltip, itemID)
    end)

    if dataTypes.Spell ~= nil then
        processor.AddTooltipPostCall(dataTypes.Spell, function(tooltip, data)
            if not accept(tooltip) then return end
            local spellID = type(data) == "table" and tonumber(data.id) or nil
            if not spellID then
                local util = _G.TooltipUtil
                if type(util) == "table" and type(util.GetDisplayedSpell) == "function" then
                    spellID = lastNumericValue(util.GetDisplayedSpell(tooltip))
                end
            end
            self:OnTooltipSetSpell(tooltip, spellID)
        end)
    end
end

-- _tooltipHooksRegistered e' la sonda da usare in gioco:
-- /dump RecipeRegistry.Tooltip._tooltipHooksRegistered
function Tooltip:RegisterTooltipHooks()
    if self._tooltipHooksRegistered then return end
    local processor, dataTypes = retailTooltipPipeline()
    if not processor then
        -- Senza pipeline (l'harness di test offline) non c'e' niente a cui
        -- agganciarsi: le righe dei crafter si provano chiamando AddCraftLines
        -- direttamente.
        return
    end
    self:RegisterRetailTooltipHooks(processor, dataTypes)
    self._tooltipHooksRegistered = true
end

function Tooltip:InvalidateIndex(_reason)
    -- The tooltip is a secondary feature: the cost of rebuilding the full
    -- recipe index (100+ ms on a large guild database) is too high to pay
    -- on every block merge or roster update. We just mark dirty here and
    -- bump the generation so any in-flight rebuild aborts on its next
    -- step check. The actual rebuild fires at well-defined lifecycle
    -- moments:
    --   - Sync:CompleteOutboundSeedSession on successful pull
    --   - Sync:AbortOutboundSeedSession with partial merges
    --   - Tooltip:GetRowsForKey lazily on user consultation when idle
    self._indexBuildGeneration = (self._indexBuildGeneration or 0) + 1
    self.indexDirty = true
    if self._timer then
        self:CancelTimer(self._timer, true)
        self._timer = nil
    end
end

function Tooltip:BuildIndexState(state)
    state = state or {}
    if state.initialized then
        return state
    end
    if not (Addon.Data and Addon.Data.GetRecipeIndex) then
        state.initialized = true
        state.recipeIndex = {}
        state.recipeKeys = {}
        state.index = {}
        state.indexVersion = (self.indexVersion or 0) + 1
        state.cursor = 1
        return state
    end

    local recipeIndex = Addon.Data:GetRecipeIndex() or {}
    local recipeKeys = {}
    for recipeKey in pairs(recipeIndex) do
        recipeKeys[#recipeKeys + 1] = recipeKey
    end
    sort(recipeKeys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    state.initialized = true
    state.recipeIndex = recipeIndex
    state.recipeKeys = recipeKeys
    state.index = {}
    state.indexVersion = (self.indexVersion or 0) + 1
    state.cursor = 1
    return state
end

function Tooltip:CommitBuiltIndex(index, version)
    self.index = index or {}
    self.indexVersion = version or ((self.indexVersion or 0) + 1)
    self.indexDirty = false
end

function Tooltip:RebuildIndex()
    local state = self:BuildIndexState({})
    local recipeIndex = state.recipeIndex or {}
    local index = state.index or {}

    for _, recipeKey in ipairs(state.recipeKeys or {}) do
        local indexed = recipeIndex[recipeKey]
        local numericKey = tonumber(recipeKey)
        local key
        if numericKey and numericKey > 0 then
            key = makeItemKey(numericKey)
        elseif numericKey and numericKey < 0 then
            key = makeSpellKey(-numericKey)
        end
        if key and indexed and indexed.crafterRows and #indexed.crafterRows > 0 then
            addRecipeKey(index, key, recipeKey)
        end
    end

    for _, bucket in pairs(index) do
        bucket.seen = nil
    end
    self:CommitBuiltIndex(index, state.indexVersion)
end

function Tooltip:RunIndexBuildStep(state)
    state = self:BuildIndexState(state)
    local currentGeneration = self._indexBuildGeneration or 0
    if (state.generation or 0) ~= currentGeneration then
        return false, state
    end

    local processed = 0
    local recipeKeys = state.recipeKeys or {}
    local recipeIndex = state.recipeIndex or {}
    local index = state.index or {}
    -- Partial alignment with the UI predicate: the tooltip is informational
    -- ("who knows this item / spell") and shouldn't follow user-preference
    -- filters like the BoP gate, because those answer a different
    -- question. But it MUST honor the garbage gates — otherwise hovering an
    -- ordinary item like a Worn Axe surfaces ghost crafter rows from old
    -- mocks, and clearing those entries from one user's DB doesn't stop
    -- their tooltip from showing them. Skip recipe keys that don't resolve
    -- in the WoW client, plus positive item keys the metadata doesn't
    -- catalogue (real-but-not-a-recipe items like Worn Axe).
    local resolvableCheck = Addon.Data and Addon.Data.IsRecipeKeyResolvableInClient
    local cataloguedCheck = Addon.Data and Addon.Data.IsRecipeKeyCatalogued

    while state.cursor <= #recipeKeys and processed < TOOLTIP_INDEX_RECIPES_PER_STEP do
        local recipeKey = recipeKeys[state.cursor]
        local indexed = recipeIndex[recipeKey]
        local numericKey = tonumber(recipeKey)
        local key
        if numericKey and numericKey > 0 then
            key = makeItemKey(numericKey)
        elseif numericKey and numericKey < 0 then
            key = makeSpellKey(-numericKey)
        end
        local skip = false
        if resolvableCheck and not Addon.Data:IsRecipeKeyResolvableInClient(recipeKey) then
            skip = true
        elseif cataloguedCheck and not Addon.Data:IsRecipeKeyCatalogued(recipeKey) then
            -- Real-but-not-a-recipe item (e.g. Worn Axe): WoW resolves it as a
            -- valid item but the metadata library doesn't map it to any recipe,
            -- so showing crafter rows on its tooltip would be garbage.
            skip = true
        end
        if not skip
            and key
            and indexed and indexed.crafterRows and #indexed.crafterRows > 0
        then
            addRecipeKey(index, key, recipeKey)
        end
        state.cursor = state.cursor + 1
        processed = processed + 1
    end

    if state.cursor <= #recipeKeys then
        return true, state
    end

    for _, bucket in pairs(index) do
        bucket.seen = nil
    end
    if (state.generation or 0) == (self._indexBuildGeneration or 0) then
        self:CommitBuiltIndex(index, state.indexVersion)
    end
    return false, state
end

function Tooltip:EnsureIndexBuildScheduled()
    if not self.indexDirty or self._indexBuildJobActive then return end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then return end
    if Addon.Sync and Addon.Sync.IsInWarmup and Addon.Sync:IsInWarmup() then
        return
    end
    if Addon.Sync and Addon.Sync.IsInWorldTransition and Addon.Sync:IsInWorldTransition() then
        return
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseTooltipRebuild() then
        return
    end

    self._indexBuildJobActive = true
    local generation = self._indexBuildGeneration or 0
    Addon.Performance:ScheduleJob("tooltip-index-build", function(state)
        state = state or {}
        state.generation = state.generation or generation
        local keepGoing, newState = self:RunIndexBuildStep(state)
        if not keepGoing then
            self._indexBuildJobActive = false
            if self.indexDirty and (state.generation or 0) ~= (self._indexBuildGeneration or 0) then
                self:EnsureIndexBuildScheduled()
            end
        end
        return keepGoing, newState
    end, {
        category = "ui",
        label = "tooltip-index-build",
        budgetMs = 2,
        state = {
            generation = generation,
        },
    })
end

function Tooltip:ResolveBucketRows(bucket)
    if not bucket then return nil end
    if not (Addon.Data and Addon.Data.GetRecipeCrafters) then return nil end

    local recipeKeys = bucket.recipeKeys or {}
    if #recipeKeys == 1 then
        return Addon.Data:GetRecipeCrafters(recipeKeys[1])
    end

    local rows = {}
    local seen = {}
    for _, recipeKey in ipairs(recipeKeys) do
        for _, row in ipairs(Addon.Data:GetRecipeCrafters(recipeKey) or {}) do
            local seenKey = table.concat({
                tostring(row.recipeKey or recipeKey or ""),
                tostring(row.memberKey or ""),
                tostring(row.profession or ""),
            }, "\031")
            if not seen[seenKey] then
                seen[seenKey] = true
                rows[#rows + 1] = row
            end
        end
    end
    sortRows(rows)
    return rows
end

function Tooltip:GetRowsForKey(key)
    if not key then return nil end
    if self.indexDirty then
        -- Serve stale (or empty) rows when we can't safely rebuild right
        -- now: combat lockdown, an active sync pull, warmup, or anything
        -- else that flags heavy lifecycle work as deferred. The index will
        -- be rebuilt at the next lifecycle moment (session-complete,
        -- session-abort with partial merges) and the user sees fresh data
        -- on the next hover.
        local mustServeStale = false
        if InCombatLockdown and InCombatLockdown() then
            mustServeStale = true
        elseif Addon.Sync and Addon.Sync.ShouldDeferHeavyLifecycleWork
            and Addon.Sync:ShouldDeferHeavyLifecycleWork("tooltip-lookup") then
            mustServeStale = true
        end
        if mustServeStale then
            local staleBucket = self.index and self.index[key]
            return self:ResolveBucketRows(staleBucket)
        end
        -- Idle path: schedule a chunked background rebuild and serve stale
        -- this round. The next hover after the build finishes will see
        -- fresh data. We avoid the synchronous RebuildIndex fallback
        -- because that pays the full 100+ ms cost on the hover frame.
        self:EnsureIndexBuildScheduled()
        if not self._indexBuildJobActive then
            self:RebuildIndex()
        end
    end
    local bucket = self.index and self.index[key]
    return self:ResolveBucketRows(bucket)
end

function Tooltip:MergeRows(...)
    local out = {}
    local seen = {}
    for index = 1, select("#", ...) do
        local rows = select(index, ...)
        for _, row in ipairs(rows or {}) do
            local key = table.concat({
                tostring(row.recipeKey or ""),
                tostring(row.memberKey or ""),
                tostring(row.profession or ""),
            }, "\031")
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = row
            end
        end
    end
    sortRows(out)
    return out
end

function Tooltip:GetRowsForItemID(itemID)
    local directKey = makeItemKey(itemID)
    local directRows = self:GetRowsForKey(directKey)
    if directRows and #directRows > 0 then
        return directRows, directKey
    end

    local metadata = getRecipeMetadata()
    if metadata then
        local info = metadata:GetRecipeInfo(itemID)
        local normalized = metadata:NormalizeRecipeKey(itemID)
        local spellID = normalized and normalized.spellId or (info and info.spellId)
        local createdItemID = info and metadata:GetCreatedItemId(itemID, info) or nil
        if normalized and normalized.source == "createdItem" then
            createdItemID = itemID
        end
        local rows = self:MergeRows(
            self:GetRowsForKey(makeSpellKey(spellID)),
            self:GetRowsForKey(makeItemKey(createdItemID))
        )
        if #rows > 0 then
            return rows, directKey
        end
    end

    return directRows, directKey
end

function Tooltip:GetRowsForSpellID(spellID)
    local directKey = makeSpellKey(spellID)
    local directRows = self:GetRowsForKey(directKey)
    if directRows and #directRows > 0 then
        return directRows, directKey
    end

    local metadata = getRecipeMetadata()
    if metadata then
        local info = metadata:GetRecipeInfo(-spellID)
        local createdItemID = info and metadata:GetCreatedItemId(-spellID, info) or nil
        local recipeItemID = info and metadata:GetRecipeItemId(-spellID, info) or nil
        local rows = self:MergeRows(
            self:GetRowsForKey(makeItemKey(createdItemID)),
            self:GetRowsForKey(makeItemKey(recipeItemID))
        )
        if #rows > 0 then
            return rows, directKey
        end
    end

    return directRows, directKey
end

function Tooltip:AddCraftLines(tooltip, rows, renderKey)
    -- User toggle from /rr options ("Show crafters on tooltips"). Gated at
    -- the single render choke point so both the item and spell tooltip
    -- paths honour it; the crafter index keeps updating in the background
    -- so re-enabling takes effect immediately.
    local profile = Addon.db and Addon.db.profile
    if profile and profile.showTooltipCrafters == false then return end
    if not rows or #rows == 0 then return end

    renderKey = tostring(renderKey or "craft") .. ":" .. tostring(self.indexVersion or 0)
    if tooltip._rrCraftRenderedKey == renderKey then return end
    tooltip._rrCraftRenderedKey = renderKey

    local onlineRows = {}
    for _, row in ipairs(rows) do
        if row.online then
            onlineRows[#onlineRows + 1] = row
        end
    end
    local displayRows = #onlineRows > 0 and onlineRows or rows
    local label = #onlineRows > 0 and string.format("%d online", #onlineRows)
        or string.format("%d offline known", #displayRows)

    tooltip:AddLine(" ")
    tooltip:AddLine("Recipe Registry", 1, 0.82, 0)
    tooltip:AddLine(label, 0.78, 0.78, 0.78)

    local maxRows = math.min(MAX_TOOLTIP_CRAFTERS, #displayRows)
    for i = 1, maxRows do
        local row = displayRows[i]
        local r, g, b = row.online and 0.4 or 0.65, row.online and 1 or 0.65, row.online and 0.4 or 0.65
        local nameText = string.format("%s (%s)", Addon.Data:GetMemberKeyName(tostring(row.memberKey)), tostring(row.profession))
        if row.specialization then
            nameText = nameText .. string.format(" [%s]", row.specialization)
        end
        tooltip:AddLine(nameText, r, g, b)
    end
    if #displayRows > maxRows then
        tooltip:AddLine(string.format("+%d more", #displayRows - maxRows), 0.7, 0.7, 0.7)
    end
    tooltip:Show()
end

function Tooltip:OnTooltipSetItem(tooltip, itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local rows, key = self:GetRowsForItemID(itemID)
    self:AddCraftLines(tooltip, rows, key)
end

function Tooltip:OnTooltipSetSpell(tooltip, spellID)
    spellID = tonumber(spellID)
    if not spellID then return end
    local rows, key = self:GetRowsForSpellID(spellID)
    self:AddCraftLines(tooltip, rows, key)
end
