local Wow = {}

local unpack = unpack
local realDate = os.date
local realType = type

local state

local PROFESSION_SPELLS = {
    [2259] = "Alchemy",
    [2018] = "Blacksmithing",
    [2550] = "Cooking",
    [7411] = "Enchanting",
    [4036] = "Engineering",
    [2366] = "Herbalism",
    [25229] = "Jewelcrafting",
    [2108] = "Leatherworking",
    [2575] = "Mining",
    [8613] = "Skinning",
    [3908] = "Tailoring",
    [2656] = "Mining",
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

local function applyDefaults(target, defaults)
    if realType(defaults) ~= "table" then return target end
    if realType(target) ~= "table" then target = {} end
    for key, value in pairs(defaults) do
        if realType(value) == "table" then
            target[key] = applyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local function sortedTimerIndex()
    local bestIndex, bestTimer
    for index, timer in ipairs(state.timers) do
        if not timer.cancelled then
            if not bestTimer
                or timer.dueAt < bestTimer.dueAt
                or (timer.dueAt == bestTimer.dueAt and timer.id < bestTimer.id) then
                bestIndex = index
                bestTimer = timer
            end
        end
    end
    return bestIndex, bestTimer
end

local function callScheduled(owner, callback, ...)
    if realType(callback) == "function" then
        return callback(...)
    end
    if realType(callback) == "string" and owner and realType(owner[callback]) == "function" then
        return owner[callback](owner, ...)
    end
    error("invalid scheduled callback: " .. tostring(callback))
end

local function scheduleTimer(owner, callback, delay, repeating)
    state.nextTimerId = state.nextTimerId + 1
    local timer = {
        id = state.nextTimerId,
        owner = owner,
        callback = callback,
        delay = delay or 0,
        dueAt = state.now + (delay or 0),
        repeating = repeating == true,
        cancelled = false,
    }
    state.timers[#state.timers + 1] = timer
    return timer
end

local function embedBaseMethods(target)
    function target:Print(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        state.prints[#state.prints + 1] = table.concat(parts, " ")
    end

    function target:RegisterChatCommand(command, method)
        self.__chatCommands = self.__chatCommands or {}
        self.__chatCommands[command] = method
    end

    function target:RegisterEvent(event, method)
        self.__events = self.__events or {}
        self.__events[event] = method or event
    end

    function target:UnregisterEvent(event)
        if self.__events then self.__events[event] = nil end
    end

    function target:ScheduleTimer(callback, delay, ...)
        local extra = { ... }
        if #extra > 0 then
            local original = callback
            callback = function()
                return callScheduled(self, original, unpack(extra))
            end
        end
        return scheduleTimer(self, callback, delay, false)
    end

    function target:ScheduleRepeatingTimer(callback, delay, ...)
        local extra = { ... }
        if #extra > 0 then
            local original = callback
            callback = function()
                return callScheduled(self, original, unpack(extra))
            end
        end
        return scheduleTimer(self, callback, delay, true)
    end

    function target:CancelTimer(timer)
        if timer then timer.cancelled = true end
    end

    function target:RegisterComm(prefix, method)
        self.__commPrefix = prefix
        self.__commMethod = method or "OnCommReceived"
    end

    function target:SendCommMessage(prefix, message, distribution, targetName, priority)
        state.sentComm[#state.sentComm + 1] = {
            prefix = prefix,
            message = message,
            distribution = distribution,
            target = targetName,
            priority = priority,
            sender = state.playerName,
        }
    end

    return target
end

local function newAddon(name)
    local addon = embedBaseMethods({
        name = name,
        __modules = {},
        __moduleOrder = {},
    })

    function addon:NewModule(moduleName)
        local module = embedBaseMethods({
            name = moduleName,
            moduleName = moduleName,
            parent = self,
        })
        self.__modules[moduleName] = module
        self.__moduleOrder[#self.__moduleOrder + 1] = module
        return module
    end

    return addon
end

local function installLibStub()
    local libs = {}

    local AceAddon = {}
    function AceAddon:NewAddon(name)
        return newAddon(name)
    end
    libs["AceAddon-3.0"] = AceAddon

    libs["AceDB-3.0"] = {
        New = function(_, dbName, defaults)
            local db = _G[dbName]
            if realType(db) ~= "table" then
                db = {}
                _G[dbName] = db
            end
            applyDefaults(db, defaults or {})
            db.global = db.global or {}
            db.profile = db.profile or {}
            return db
        end,
    }

    libs["AceSerializer-3.0"] = {
        Serialize = function(_, payload)
            return payload
        end,
        Deserialize = function(_, payload)
            return true, payload
        end,
    }

    local function libstub(name)
        local lib = libs[name]
        if not lib then error("missing test LibStub library: " .. tostring(name), 2) end
        return lib
    end

    _G.__RecipeRegistryTestLibs = libs
    _G.LibStub = libstub
end

local function makeFrame(shown)
    return {
        shown = shown == true,
        IsShown = function(self) return self.shown == true end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
    }
end

local function makeCheckButton()
    return {
        checked = false,
        GetChecked = function(self) return self.checked == true end,
        SetChecked = function(self, value) self.checked = value == true end,
    }
end

local function makeEditBox(initial)
    return {
        text = initial or "",
        GetText = function(self) return self.text or "" end,
        SetText = function(self, value)
            self.text = value or ""
            state.tradeSkill.nameFilter = self.text
        end,
    }
end

local function itemLink(itemID, name)
    if not itemID then return nil end
    return string.format("|Hitem:%d:0:0:0:0:0:0:0|h[%s]|h", itemID, name or ("Item " .. tostring(itemID)))
end

local function spellLink(spellID, name)
    if not spellID then return nil end
    return string.format("|Henchant:%d|h[%s]|h", spellID, name or ("Spell " .. tostring(spellID)))
end

local function normalizeRosterEntry(entry)
    if realType(entry) == "string" then
        return { name = entry, online = true }
    end
    return entry or {}
end

local function installWowGlobals()
    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message)
            state.chat[#state.chat + 1] = tostring(message)
        end,
    }

    _G.UIParent = makeFrame(true)
    _G.TradeSkillFrame = makeFrame(false)
    _G.CraftFrame = makeFrame(false)
    _G.TradeSkillFilterBox = makeEditBox("")
    _G.TradeSkillFrameAvailableFilterCheckButton = makeCheckButton()
    _G.TradeSkillFrameFilterSkillUps = makeCheckButton()

    _G.time = function() return math.floor(state.now) end
    _G.GetTime = function() return state.now end
    _G.debugprofilestop = function()
        state.perfNowMs = (state.perfNowMs or (state.now * 1000)) + 0.1
        return state.perfNowMs
    end
    _G.date = function(format, value) return realDate(format, value or math.floor(state.now)) end

    _G.GetRealmName = function() return state.realm end
    _G.UnitFullName = function(unit)
        if unit == "player" then return state.playerName, state.realm end
        return nil
    end
    _G.IsInGuild = function() return state.inGuild == true end
    _G.IsInRaid = function() return state.inRaid == true end
    _G.GetNumRaidMembers = function() return state.inRaid and 1 or 0 end
    _G.InCombatLockdown = function() return state.inCombat == true end
    _G.IsInInstance = function() return state.inInstance == true, state.instanceType or "none" end

    _G.GuildRoster = function()
        state.guildRosterRequested = state.guildRosterRequested + 1
    end
    _G.C_GuildInfo = {
        GuildRoster = _G.GuildRoster,
    }
    _G.GetNumGuildMembers = function()
        return #state.guildRoster
    end
    _G.GetGuildRosterInfo = function(index)
        local row = normalizeRosterEntry(state.guildRoster[index])
        if not row then return nil end
        return row.name,
            row.rankName,
            row.rankIndex,
            row.level,
            row.classDisplayName,
            row.zone,
            row.publicNote,
            row.officerNote,
            row.online,
            row.status,
            row.classFileName
    end

    _G.GetNumSkillLines = function()
        return #state.skillLines
    end
    _G.GetSkillLineInfo = function(index)
        local row = state.skillLines[index] or {}
        return row.name,
            row.isHeader == true,
            nil,
            row.skillRank or 0,
            nil,
            nil,
            row.skillMaxRank or 0
    end

    _G.GetSpellInfo = function(spellID)
        return state.spells[spellID] or PROFESSION_SPELLS[spellID] or ("Spell " .. tostring(spellID))
    end
    _G.IsSpellKnown = function(spellID)
        return state.knownSpells[spellID] == true
    end
    _G.GetSpellTexture = function(spellID)
        return "spell-icon-" .. tostring(spellID)
    end
    _G.GetItemInfo = function(itemID)
        itemID = tonumber(itemID)
        local item = state.items[itemID] or {}
        local name = item.name or ("Item " .. tostring(itemID))
        local link = item.link or itemLink(itemID, name)
        return name, link, item.quality or 1, nil, nil, nil, nil, nil, nil, item.icon or ("item-icon-" .. tostring(itemID))
    end
    _G.GetItemInfoInstant = function(itemID)
        return tonumber(itemID), nil, nil, nil, "item-icon-" .. tostring(itemID)
    end

    _G.GetTradeSkillLine = function()
        return state.tradeSkill.title
    end
    _G.GetNumTradeSkills = function()
        return #state.tradeSkill.entries
    end
    _G.GetTradeSkillInfo = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.name,
            row.type,
            nil,
            row.expanded ~= false
    end
    _G.GetTradeSkillItemLink = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.itemLink or itemLink(row.itemID, row.name)
    end
    _G.GetTradeSkillRecipeLink = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.recipeLink or spellLink(row.spellID, row.name)
    end
    _G.ExpandTradeSkillSubClass = function(index)
        if state.tradeSkill.entries[index] then state.tradeSkill.entries[index].expanded = true end
    end
    _G.CollapseTradeSkillSubClass = function(index)
        if state.tradeSkill.entries[index] then state.tradeSkill.entries[index].expanded = false end
    end
    _G.TradeSkillFrame_Update = function() end
    _G.GetTradeSkillSubClasses = function()
        return unpack(state.tradeSkill.subclasses)
    end
    _G.GetTradeSkillSubClassFilter = function(index)
        return state.tradeSkill.subclassFilter == 0 or state.tradeSkill.subclassFilter == index
    end
    _G.SetTradeSkillSubClassFilter = function(index)
        state.tradeSkill.subclassFilter = index or 0
    end
    _G.GetTradeSkillInvSlots = function()
        return unpack(state.tradeSkill.invSlots)
    end
    _G.GetTradeSkillInvSlotFilter = function(index)
        return state.tradeSkill.invSlotFilter == 0 or state.tradeSkill.invSlotFilter == index
    end
    _G.SetTradeSkillInvSlotFilter = function(index)
        state.tradeSkill.invSlotFilter = index or 0
    end
    _G.GetTradeSkillItemNameFilter = function()
        return state.tradeSkill.nameFilter or ""
    end
    _G.SetTradeSkillItemNameFilter = function(value)
        state.tradeSkill.nameFilter = value or ""
        _G.TradeSkillFilterBox.text = state.tradeSkill.nameFilter
    end
    _G.GetTradeSkillItemLevelFilter = function()
        return state.tradeSkill.itemLevelMin or 0, state.tradeSkill.itemLevelMax or 0
    end
    _G.SetTradeSkillItemLevelFilter = function(minLevel, maxLevel)
        state.tradeSkill.itemLevelMin = minLevel or 0
        state.tradeSkill.itemLevelMax = maxLevel or 0
    end
    _G.TradeSkillOnlyShowMakeable = function(value)
        state.tradeSkill.onlyMakeable = value == true
        _G.TradeSkillFrameAvailableFilterCheckButton:SetChecked(state.tradeSkill.onlyMakeable)
    end
    _G.TradeSkillOnlyShowSkillUps = function(value)
        state.tradeSkill.onlySkillUps = value == true
        _G.TradeSkillFrameFilterSkillUps:SetChecked(state.tradeSkill.onlySkillUps)
    end

    _G.GetCraftSkillLine = function(index)
        if index ~= nil and index <= 0 then return nil end
        return state.craftSkill.title
    end
    _G.GetCraftDisplaySkillLine = function()
        if state.craftSkill.title == "Beast Training" then return nil end
        return state.craftSkill.title
    end
    _G.GetNumCrafts = function()
        return #state.craftSkill.entries
    end
    _G.GetCraftInfo = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.name, row.type
    end
    _G.GetCraftItemLink = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.itemLink or itemLink(row.itemID, row.name)
    end
    _G.GetCraftRecipeLink = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.recipeLink or spellLink(row.spellID, row.name)
    end
    _G.GetCraftItemNameFilter = function()
        return state.craftSkill.nameFilter or ""
    end
    _G.SetCraftItemNameFilter = function(value)
        state.craftSkill.nameFilter = value or ""
    end
    _G.CraftFrame_Update = function() end
end

function Wow.Reset()
    state = {
        now = 1700000000,
        nextTimerId = 0,
        perfNowMs = 1700000000000,
        timers = {},
        prints = {},
        chat = {},
        sentComm = {},
        realm = "TestRealm",
        playerName = "Tester",
        inGuild = true,
        inCombat = false,
        inRaid = false,
        inInstance = false,
        instanceType = "none",
        guildRosterRequested = 0,
        guildRoster = {},
        skillLines = {},
        items = {},
        spells = {},
        knownSpells = {},
        tradeSkill = {
            title = nil,
            entries = {},
            subclasses = { "All" },
            invSlots = { "All" },
            subclassFilter = 0,
            invSlotFilter = 0,
            nameFilter = "",
            itemLevelMin = 0,
            itemLevelMax = 0,
            onlyMakeable = false,
            onlySkillUps = false,
        },
        craftSkill = {
            title = nil,
            entries = {},
            nameFilter = "",
        },
    }

    _G.RecipeRegistry = nil
    _G.RecipeRegistryDB = nil
    _G.RecipeRegistryCharDB = nil

    installLibStub()
    installWowGlobals()
    return state
end

function Wow.GetState()
    return state
end

function Wow.UseState(nextState)
    if not nextState then
        error("Wow.UseState requires a state table", 2)
    end
    state = nextState
    return state
end

function Wow.WithState(nextState, fn, ...)
    if realType(fn) ~= "function" then
        error("Wow.WithState requires a callback", 2)
    end
    local previous = state
    Wow.UseState(nextState)
    local result = { pcall(fn, ...) }
    if previous then
        Wow.UseState(previous)
    end
    if not result[1] then
        error(result[2], 2)
    end
    return unpack(result, 2)
end

function Wow.SetPlayer(name, realm)
    state.playerName = name or state.playerName
    state.realm = realm or state.realm
end

function Wow.SetGuildRoster(rows)
    state.guildRoster = deepcopy(rows or {})
end

function Wow.SetCombat(value)
    state.inCombat = value == true
end

function Wow.SetRaid(value)
    state.inRaid = value == true
end

function Wow.SetInstance(value, instanceType)
    state.inInstance = value == true
    state.instanceType = instanceType or (state.inInstance and "party" or "none")
end

function Wow.SetSkillLines(rows)
    state.skillLines = deepcopy(rows or {})
end

function Wow.SetKnownSpells(spellIDs)
    state.knownSpells = {}
    for _, spellID in ipairs(spellIDs or {}) do
        state.knownSpells[spellID] = true
    end
end

function Wow.SetTradeSkill(title, rows, opts)
    opts = opts or {}
    state.tradeSkill.title = title
    state.tradeSkill.entries = deepcopy(rows or {})
    state.tradeSkill.subclasses = deepcopy(opts.subclasses or { "All" })
    state.tradeSkill.invSlots = deepcopy(opts.invSlots or { "All" })
    state.tradeSkill.subclassFilter = opts.subclassFilter or 0
    state.tradeSkill.invSlotFilter = opts.invSlotFilter or 0
    state.tradeSkill.nameFilter = opts.nameFilter or ""
    _G.TradeSkillFilterBox.text = state.tradeSkill.nameFilter
    _G.TradeSkillFrame.shown = opts.shown ~= false
end

function Wow.SetCraftSkill(title, rows, opts)
    opts = opts or {}
    state.craftSkill.title = title
    state.craftSkill.entries = deepcopy(rows or {})
    state.craftSkill.nameFilter = opts.nameFilter or ""
    _G.CraftFrame.shown = opts.shown ~= false
end

function Wow.AdvanceTime(seconds)
    state.now = state.now + (seconds or 0)
end

function Wow.RunTimers(maxRuns)
    maxRuns = maxRuns or 100
    local ran = 0
    while ran < maxRuns do
        local index, timer = sortedTimerIndex()
        if not timer then break end
        table.remove(state.timers, index)
        if timer.dueAt > state.now then state.now = timer.dueAt end
        if not timer.cancelled then
            ran = ran + 1
            callScheduled(timer.owner, timer.callback)
            if timer.repeating and not timer.cancelled then
                timer.dueAt = state.now + (timer.delay or 0)
                state.timers[#state.timers + 1] = timer
            end
        end
    end
    return ran
end

function Wow.RunDueTimers(maxRuns)
    maxRuns = maxRuns or 100
    local ran = 0
    while ran < maxRuns do
        local index, timer = sortedTimerIndex()
        if not timer or timer.dueAt > state.now then break end
        table.remove(state.timers, index)
        if not timer.cancelled then
            ran = ran + 1
            callScheduled(timer.owner, timer.callback)
            if timer.repeating and not timer.cancelled then
                timer.dueAt = state.now + (timer.delay or 0)
                state.timers[#state.timers + 1] = timer
            end
        end
    end
    return ran
end

function Wow.GetPrints()
    return state.prints
end

function Wow.GetChatMessages()
    return state.chat
end

function Wow.GetSentComm()
    return state.sentComm
end

function Wow.DeliverComm(module, payload, opts)
    opts = opts or {}
    local target = module or (_G.RecipeRegistry and _G.RecipeRegistry.Sync)
    if not target or realType(target.OnCommReceived) ~= "function" then
        error("Wow.DeliverComm requires a module with OnCommReceived", 2)
    end
    local serializer = LibStub("AceSerializer-3.0")
    local message = serializer:Serialize(deepcopy(payload or {}))
    local prefix = opts.prefix or (_G.RecipeRegistry and _G.RecipeRegistry.ADDON_PREFIX) or "RRG1"
    local distribution = opts.distribution or "WHISPER"
    local sender = opts.sender or (payload and payload.sender) or state.playerName
    target:OnCommReceived(prefix, message, distribution, sender)
    return message
end

Wow.Reset()

return Wow
