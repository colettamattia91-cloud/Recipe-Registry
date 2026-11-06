-- Una gilda simulata, per provare il sync fra piu' client veri.
--
-- Il sync si e' rotto piu' volte per cose che con un client solo non si
-- vedono: un seed che tace, due compagni che divergono per sempre, un pezzo di
-- sussurro perso. Questo harness mette in piedi N client, ognuno nel suo
-- ambiente Lua (setfenv) con i suoi file di runtime -- Data e Sync veri, la
-- codifica vera con AceSerializer e LibDeflate -- e li fa parlare su un canale
-- finto che si comporta come quello vero, e peggio quando serve:
--
--   * pezzi da 255 byte, come AceComm;
--   * un secchiello di token per mittente come ChatThrottleLib (800 B/s,
--     raffica di 4000) con le tre priorita' ALERT, NORMAL, BULK;
--   * perdite di due tipi: il pezzo che il client rifiuta (la callback dice
--     didSend=false, come ChatThrottleLib per un codice diverso da 3) e quello
--     che il server perde dopo averlo accettato (nessuno lo sa);
--   * ritardi variabili, quindi messaggi fuori ordine, e duplicati;
--   * l'eco dei messaggi di gilda al mittente, come fa WoW.
--
-- Core non si carica (vuole frame, UI, comandi): il login, l'ingresso nel
-- mondo, il roster e il bucket delle fusioni li fa Peer:Login nello stesso
-- ordine di Core.lua. Il tempo e' virtuale: Sim:Run avanza da un evento al
-- prossimo, e un errore Lua in qualunque client finisce in sim.errors invece
-- di fermare tutto.
--
-- Un client puo' girare su un albero vecchio -- "forever-v0.1.5" -- letto con
-- git show, per mescolare versioni nella stessa gilda.

local Sim = {}
Sim.__index = Sim
local Peer = {}
Peer.__index = Peer

local ADDON_FOLDER = "RecipeRegistry_Forever"
-- l'ordine del TOC, ristretto a cio' che il sync tocca
local FILES = {
    "Core/Compat.lua", "Core/BuildInfo.lua",
    "Data/Data.lua", "Data/DataGuildScope.lua", "Data/DataScan.lua", "Data/DataSnapshot.lua",
    "Data/DataIndex.lua", "Data/MergeEngine.lua",
    "Sync/SyncPausePolicy.lua",
    "Sync/Sync.lua", "Sync/SyncRuntime.lua", "Sync/SyncProtocol.lua", "Sync/SyncCodec.lua",
    "Sync/SyncRequests.lua", "Sync/SyncTransfer.lua", "Sync/SyncDiagnostics.lua",
}
local TREE_VERSIONS = { working = "0.1.6" }

local CPS, BURST, PART = 800, 4000, 254
local PRIORITIES = { "ALERT", "NORMAL", "BULK" }
local REALM = "CamWoW EU4 Realm 7 PvE"

-- ---------------------------------------------------------------- librerie

local sharedLibStub
local function libStub()
    if sharedLibStub then return sharedLibStub end
    local env = setmetatable({}, { __index = _G })
    env._G = env
    for _, rel in ipairs({ "Libs/LibStub/LibStub.lua", "Libs/AceSerializer-3.0/AceSerializer-3.0.lua",
        "Libs/LibDeflate/LibDeflate.lua" }) do
        local chunk = assert(loadfile(rel))
        setfenv(chunk, env)
        chunk()
    end
    sharedLibStub = env.LibStub
    return sharedLibStub
end

-- il tipo di un messaggio sul filo, per le statistiche: lo si decodifica come
-- farebbe chi lo riceve
local function wireKind(text)
    local LS = libStub()
    local ser, deflate = LS("AceSerializer-3.0"), LS("LibDeflate")
    local raw = text
    if type(text) == "string" and text:sub(1, 4) == "RR1|" then
        local decoded = deflate:DecodeForWoWAddonChannel(text:sub(5))
        raw = decoded and deflate:DecompressDeflate(decoded) or nil
    end
    if type(raw) ~= "string" then return "?" end
    local ok, payload = ser:Deserialize(raw)
    return ok and type(payload) == "table" and tostring(payload.kind or "?") or "?"
end

-- ---------------------------------------------------------------- sorgenti

local treeCache = {}
local function readTree(tree)
    if treeCache[tree] then return treeCache[tree] end
    local files = {}
    for _, rel in ipairs(FILES) do
        local src
        if tree == "working" then
            local f = assert(io.open(rel, "rb"))
            src = f:read("*a")
            f:close()
        else
            local p = io.popen('git show "' .. tree .. ":" .. ADDON_FOLDER .. "/" .. rel .. '" 2>nul')
            src = p and p:read("*a") or ""
            if p then p:close() end
            if src == "" then
                return nil, "git show " .. tree .. ":" .. rel .. " non ha restituito niente"
            end
        end
        files[rel] = src
    end
    treeCache[tree] = files
    return files
end

function Sim.TreeAvailable(tree)
    return readTree(tree) ~= nil
end

-- ---------------------------------------------------------------- tempo

local function heapPush(h, ev)
    h[#h + 1] = ev
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        local a, b = h[p], h[i]
        if a.at < b.at or (a.at == b.at and a.seq < b.seq) then break end
        h[p], h[i] = b, a
        i = p
    end
end

local function heapPop(h)
    local top = h[1]
    if not top then return nil end
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i, n = 1, #h
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            local function less(x, y) return h[x].at < h[y].at or (h[x].at == h[y].at and h[x].seq < h[y].seq) end
            if l <= n and less(l, s) then s = l end
            if r <= n and less(r, s) then s = r end
            if s == i then break end
            h[s], h[i] = h[i], h[s]
            i = s
        end
    end
    return top
end

function Sim.New(opts)
    opts = opts or {}
    local sim = setmetatable({
        clock = opts.start or 1793975000,
        seq = 0,
        queue = {},
        peers = {},
        order = {},
        guildName = opts.guildName or "Grumpy Old Men",
        errors = {},
        violations = {},
        stats = { sent = {}, bytes = {}, delivered = 0, lostParts = 0, rejectedParts = 0, whisperOffline = 0 },
        log = {},
        net = {
            lossReject = opts.lossReject or 0,
            lossSilent = opts.lossSilent or 0,
            latencyMin = opts.latencyMin or 0.2,
            latencyMax = opts.latencyMax or 1.5,
            duplicate = opts.duplicate or 0,
        },
        stuckLimit = opts.stuckLimit or 80,
    }, Sim)
    math.randomseed(opts.seed or 1)
    sim:Every(10, function() sim:CheckStuckSessions() end)
    return sim
end

function Sim:Schedule(delay, fn, owner)
    self.seq = self.seq + 1
    local ev = { at = self.clock + math.max(0, delay or 0), seq = self.seq, fn = fn, owner = owner,
        gen = owner and owner.gen or nil }
    heapPush(self.queue, ev)
    return ev
end

function Sim:Every(interval, fn)
    local function tick()
        self:Schedule(interval, tick)
        fn()
    end
    self:Schedule(interval, tick)
end

function Sim:RecordError(peer, err)
    local where = peer and peer.name or "sim"
    self.errors[#self.errors + 1] = string.format("[%d] %s: %s", self.clock, where, tostring(err))
end

function Sim:Violation(text)
    self.violations[#self.violations + 1] = string.format("[%d] %s", self.clock, text)
end

-- avanza il tempo di `seconds`, eseguendo tutto cio' che scade
function Sim:Run(seconds)
    local target = self.clock + seconds
    while true do
        local ev = self.queue[1]
        if not ev or ev.at > target then break end
        heapPop(self.queue)
        if not ev.cancelled then
            local owner = ev.owner
            -- un client che si e' scollegato o ha rifatto login non esegue
            -- piu' i timer della sessione di prima
            if not owner or (owner.online and owner.gen == ev.gen) then
                self.clock = ev.at
                local ok, err = xpcall(ev.fn, debug.traceback)
                if not ok then self:RecordError(owner, err) end
            end
        end
    end
    self.clock = target
end

-- ---------------------------------------------------------------- canale

function Sim:Transmit(peer, prefix, text, distribution, target, prio, callbackFn, callbackArg)
    if type(text) ~= "string" then
        self:RecordError(peer, "SendCommMessage con un messaggio non stringa: " .. type(text))
        return
    end
    local kind = wireKind(text)
    self.stats.sent[kind] = (self.stats.sent[kind] or 0) + 1
    self.stats.bytes[kind] = (self.stats.bytes[kind] or 0) + #text
    peer.bytesSent = (peer.bytesSent or 0) + #text
    peer.sentByKind[kind] = (peer.sentByKind[kind] or 0) + 1
    local nParts = (#text <= 255) and 1 or math.ceil(#text / PART)
    local msg = { from = peer, prefix = prefix, text = text, distribution = distribution, target = target,
        parts = nParts, lost = false, kind = kind, gen = peer.gen }
    local queue = peer.link[prio] or peer.link.NORMAL
    for i = 1, nParts do
        local size = (i < nParts) and 255 or (#text - (nParts - 1) * PART + (nParts > 1 and 1 or 0))
        queue[#queue + 1] = { msg = msg, index = i, size = size + 40,
            bytes = math.min(i * PART, #text), callbackFn = callbackFn, callbackArg = callbackArg }
    end
    self:PumpLink(peer)
end

function Sim:PumpLink(peer)
    if peer.pumpScheduled then return end
    local part, queue
    for _, p in ipairs(PRIORITIES) do
        if #peer.link[p] > 0 then queue = peer.link[p]; part = queue[1]; break end
    end
    if not part then return end
    peer.tokens = math.min(BURST, peer.tokens + (self.clock - peer.tokensAt) * CPS)
    peer.tokensAt = self.clock
    local wait = part.size > peer.tokens and (part.size - peer.tokens) / CPS or 0
    peer.pumpScheduled = true
    self:Schedule(wait, function()
        peer.pumpScheduled = false
        peer.tokens = math.min(BURST, peer.tokens + (self.clock - peer.tokensAt) * CPS)
        peer.tokensAt = self.clock
        table.remove(queue, 1)
        peer.tokens = peer.tokens - part.size
        self:SendPart(peer, part)
        self:PumpLink(peer)
    end, peer)
end

function Sim:SendPart(peer, part)
    local msg = part.msg
    local r = math.random()
    local didSend = true
    if r < self.net.lossReject then
        didSend = false
        msg.lost = true
        self.stats.rejectedParts = self.stats.rejectedParts + 1
    elseif r < self.net.lossReject + self.net.lossSilent then
        msg.lost = true
        self.stats.lostParts = self.stats.lostParts + 1
    end
    if part.callbackFn then
        local ok, err = xpcall(function()
            part.callbackFn(part.callbackArg, part.bytes, #msg.text, didSend)
        end, debug.traceback)
        if not ok then self:RecordError(peer, err) end
    end
    if part.index == msg.parts and not msg.lost then
        self:Deliver(msg)
        if self.net.duplicate > 0 and math.random() < self.net.duplicate then
            self:Deliver(msg, 1 + math.random() * 3)
        end
    end
end

function Sim:Deliver(msg, extraDelay)
    local recipients = {}
    if msg.distribution == "GUILD" then
        for _, name in ipairs(self.order) do
            local p = self.peers[name]
            if p.online and p.prefix == msg.prefix then recipients[#recipients + 1] = p end
        end
    elseif msg.distribution == "WHISPER" then
        local p = self.peers[msg.target]
        if p and p.online and p.prefix == msg.prefix then
            recipients[1] = p
        else
            self.stats.whisperOffline = self.stats.whisperOffline + 1
        end
    end
    for _, p in ipairs(recipients) do
        local latency = self.net.latencyMin + math.random() * (self.net.latencyMax - self.net.latencyMin)
        self:Schedule(latency + (extraDelay or 0), function()
            self.stats.delivered = self.stats.delivered + 1
            p.Sync:OnCommReceived(msg.prefix, msg.text, msg.distribution, msg.from.name)
        end, p)
    end
end

-- ---------------------------------------------------------------- client

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

local function toSet(list)
    local s = {}
    for _, k in ipairs(list or {}) do s[k] = true end
    return s
end

-- professions: lista ordinata { { "Cooking", { 2679, 6888 } }, { "Mining", {...} } }
function Sim:AddPeer(name, opts)
    opts = opts or {}
    local peer = setmetatable({
        sim = self, name = name, tree = opts.tree or "working",
        online = false, gen = 0, inCombat = false, inInstance = false,
        professions = {}, ever = {},
        savedDB = nil, charDB = nil, sentByKind = {},
    }, Peer)
    self.peers[name] = peer
    self.order[#self.order + 1] = name
    peer:SetProfessionList(opts.professions or {}, true)
    if opts.online ~= false then
        peer:Login()
    end
    return peer
end

function Peer:SetProfessionList(list, quiet)
    self.professions = {}
    for _, row in ipairs(list) do
        local prof, recipes = row[1], row[2] or {}
        self.professions[#self.professions + 1] = { name = prof, recipes = toSet(recipes) }
        self.ever[prof] = self.ever[prof] or {}
        for _, k in ipairs(recipes) do self.ever[prof][k] = true end
    end
    if not quiet and self.online then
        -- SKILL_LINES_CHANGED, poi il giocatore apre i mestieri
        self:Call(function() self.Data:DetectProfessions() end)
        self:ScanAll()
    end
end

-- ricette nuove in un mestiere che ha gia': come NEW_RECIPE_LEARNED seguito
-- dalla finestra aperta
function Peer:Learn(prof, recipes)
    for _, row in ipairs(self.professions) do
        if row.name == prof then
            for _, k in ipairs(recipes) do
                row.recipes[k] = true
                self.ever[prof][k] = true
            end
            if self.online then
                self:Call(function()
                    self.Data:ApplyScanResult(prof, row.recipes, { reason = "sim-learn", notifyMode = "silent" })
                end)
            end
            return true
        end
    end
    return false
end

function Peer:HasProfession(prof)
    for _, row in ipairs(self.professions) do
        if row.name == prof then return true end
    end
    return false
end

function Peer:Call(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then self.sim:RecordError(self, err) end
    return ok
end

function Peer:Trace(line)
    local word = line:match("^(%S+)") or line
    self.traceCounts[word] = (self.traceCounts[word] or 0) + 1
    local ring = self.traces
    ring[#ring + 1] = string.format("[%d] %s", self.sim.clock, line)
    if #ring > 4000 then table.remove(ring, 1) end
end

function Peer:Count(word)
    return self.traceCounts[word] or 0
end

function Peer:BuildEnvironment()
    local sim, peer = self.sim, self
    local env = setmetatable({}, { __index = _G })
    env._G = env

    -- il client WoW, visto da questo personaggio
    local first, surname = peer.name:match("^(%S+)%s+(.+)$")
    env.time = function() return math.floor(sim.clock) end
    env.GetTime = function() return sim.clock end
    env.UnitNameUnmodified = function() return first or peer.name, surname end
    env.GetRealmName = function() return REALM end
    env.IsLoggedIn = function() return true end
    env.IsInGuild = function() return true end
    env.GetGuildInfo = function() return sim.guildName, "Member", 1 end
    env.GetNumGuildMembers = function() return #sim.order, #sim.order end
    env.GetGuildRosterInfo = function(i)
        local other = sim.peers[sim.order[i]]
        if not other then return nil end
        return other.name, "Member", 1, 60, "Warrior", "Elwynn Forest", "", "", other.online == true, 0, "WARRIOR"
    end
    env.GetGuildRosterLastOnline = function(i)
        local other = sim.peers[sim.order[i]]
        if other and other.online then return nil end
        return 0, 0, 0, 2
    end
    local function rosterRequest() peer:RequestRosterUpdate(1) end
    env.C_GuildInfo = { GuildRoster = rosterRequest }
    env.GuildRoster = rosterRequest
    env.GetProfessions = function()
        local idx = {}
        for i = 1, math.min(5, #peer.professions) do idx[i] = i end
        return unpack(idx, 1, 5)
    end
    env.GetProfessionInfo = function(i)
        local row = peer.professions[i]
        if not row then return nil end
        return row.name, nil, 75, 300
    end
    env.IsInInstance = function() return peer.inInstance end
    env.InCombatLockdown = function() return peer.inCombat end
    env.IsInRaid = function() return false end
    env.IsSpellKnown = function() return false end
    env.C_SpellBook = { IsSpellKnown = function() return false end }
    env.C_Item = {
        GetItemInfoInstant = function(id) return type(id) == "number" and id > 0 and id or nil end,
        GetItemInfo = function(id) return "item " .. tostring(id) end,
    }
    env.C_Spell = { GetSpellInfo = function(id)
        return type(id) == "number" and { name = "spell " .. id, spellID = id, iconID = 1 } or nil
    end }
    local version = TREE_VERSIONS[peer.tree] or (peer.tree:match("v(%d+%.%d+%.%d+)$")) or "0.0.0"
    -- tutti sullo stesso canale: il TOC del ramo dice dev, quelli dei tag release
    env.C_AddOns = { GetAddOnMetadata = function(_, field)
        if field == "Version" then return version end
        if field == "X-Build-Channel" then return "release" end
        if field == "X-Build-ID" then return "sim" end
        return nil
    end }

    -- le librerie: AceDB tiene le SavedVariables fra un login e l'altro
    local LS = libStub()
    env.LibStub = function(libName, silent)
        if libName == "AceDB-3.0" then
            return { New = function(_, _, defaults)
                if not peer.savedDB then
                    peer.savedDB = { global = deepcopy(defaults.global or {}), profile = deepcopy(defaults.profile or {}), char = {} }
                end
                return peer.savedDB
            end }
        end
        return LS(libName, silent)
    end
    peer.charDB = peer.charDB or {}
    env.RecipeRegistryCharDB = peer.charDB

    -- AceAddon, AceTimer, AceEvent, AceComm, ridotte a cio' che i moduli usano
    local function mix(target)
        function target:ScheduleTimer(callback, delay, ...)
            local owner, args, n = self, { ... }, select("#", ...)
            local handle = {}
            handle.ev = sim:Schedule(tonumber(delay) or 0, function()
                handle.done = true
                if type(callback) == "string" then owner[callback](owner, unpack(args, 1, n))
                else callback(unpack(args, 1, n)) end
            end, peer)
            return handle
        end
        function target:ScheduleRepeatingTimer(callback, interval, ...)
            local owner, args, n = self, { ... }, select("#", ...)
            local handle = {}
            local function fire()
                if handle.cancelled then return end
                handle.ev = sim:Schedule(interval, fire, peer)
                if type(callback) == "string" then owner[callback](owner, unpack(args, 1, n))
                else callback(unpack(args, 1, n)) end
            end
            handle.ev = sim:Schedule(interval, fire, peer)
            return handle
        end
        function target:CancelTimer(handle)
            if type(handle) == "table" then
                handle.cancelled = true
                if handle.ev then handle.ev.cancelled = true end
            end
            return true
        end
        function target:CancelAllTimers() end
        function target:TimeLeft(handle)
            return type(handle) == "table" and handle.ev and math.max(0, handle.ev.at - sim.clock) or 0
        end
        function target:RegisterEvent() end
        function target:UnregisterEvent() end
        function target:RegisterMessage() end
        function target:RegisterBucketEvent() end
        function target:RegisterBucketMessage() end
        function target:RegisterComm(prefix) peer.prefix = prefix end
        function target:SendCommMessage(prefix, text, distribution, whisperTarget, prio, callbackFn, callbackArg)
            sim:Transmit(peer, prefix, text, distribution, whisperTarget, prio or "NORMAL", callbackFn, callbackArg)
        end
        return target
    end

    local Addon = mix({ modules = {} })
    function Addon:NewModule(moduleName)
        local m = mix({ moduleName = moduleName })
        self.modules[moduleName] = m
        return m
    end
    function Addon:Tracef(_, fmt, ...)
        local ok, line = pcall(string.format, fmt, ...)
        peer:Trace(ok and line or tostring(fmt))
    end
    function Addon:Trace(_, line) peer:Trace(tostring(line)) end
    function Addon:Debug() end
    function Addon:Print() end
    function Addon:SystemPrint() end
    function Addon:RequestRefresh() end
    -- il bucket di Core: le fusioni ricalcolano le impronte mezzo secondo dopo
    function Addon:SendMessage(message)
        if message == "RR_BLOCK_MERGE_POST" and not peer.mergeBucket then
            peer.mergeBucket = sim:Schedule(0.5, function()
                peer.mergeBucket = nil
                if peer.Data.RefreshSyncBlockRecord then
                    peer.Data:RefreshSyncBlockRecord(nil, "block-merge-bucket")
                end
            end, peer)
        end
    end
    function Addon:MarkSavedVariablesReady(reason)
        if self.Sync then
            self.Sync._savedVariablesReadyBootstrap = true
            if self.Sync.SetSavedVariablesReady then self.Sync:SetSavedVariablesReady(reason) end
        end
    end
    env.RecipeRegistry = Addon
    return env, Addon
end

function Peer:Login(isReload)
    local sim = self.sim
    local files, err = readTree(self.tree)
    if not files then error(err) end
    self.gen = self.gen + 1
    self.online = true
    self.prefix = nil
    self.link = { ALERT = {}, NORMAL = {}, BULK = {} }
    self.tokens, self.tokensAt, self.pumpScheduled = BURST, sim.clock, false
    self.traces, self.traceCounts = self.traces or {}, self.traceCounts or {}
    self.mergeBucket, self.rosterBucket = nil, nil

    local env, Addon = self:BuildEnvironment()
    self.env, self.Addon = env, Addon
    for _, rel in ipairs(FILES) do
        local chunk, loadErr = loadstring(files[rel], "@" .. self.tree .. "/" .. rel)
        if not chunk then error(loadErr) end
        setfenv(chunk, env)
        chunk(ADDON_FOLDER, {})
    end
    self.Data = Addon.Data or Addon.modules.Data
    self.Sync = Addon.Sync or Addon.modules.Sync
    self.Pause = Addon.SyncPausePolicy or Addon.modules.SyncPausePolicy
    Addon.Data, Addon.Sync, Addon.SyncPausePolicy = self.Data, self.Sync, self.Pause
    Addon.MergeEngine = Addon.MergeEngine or Addon.modules.MergeEngine

    local firstLogin = self.savedDB == nil
    self:Call(function()
        self.Data:OnInitialize()
        self.Sync:OnInitialize()
        self.Pause:OnEnable()
        -- OnPlayerLogin
        self.Data:RefreshGuildScope("player-login")
        self.Sync:Startup()
        self.Sync:SetPlayerReady("player-login")
        self.Data:DetectProfessions()
        -- OnPlayerEnteringWorld
        self.Sync:EnterWorldTransition(isReload and "reload" or "login", isReload and 25 or 30)
        self.Data:RequestRosterSnapshot(isReload and "reload" or "login", { cooldown = 0, source = "player-entering-world" })
        self.Data:ScheduleSyncIndexPrepare("player-entering-world", 1)
        self.Sync:RefreshSyncReadyState("player-entering-world")
    end)
    -- al primo login il giocatore apre i suoi mestieri; dopo, le ricette sono
    -- gia' nelle SavedVariables
    if firstLogin then self:ScanAll() end
    sim:Schedule(10, function()
        self.Sync:OnRosterPreflightWatchdog("login-watchdog")
        self.Sync:RefreshSyncReadyState("login-watchdog")
    end, self)
    -- chi era gia' in gioco vede l'ingresso nel roster
    sim:RosterChanged()
end

function Peer:ScanAll()
    for _, row in ipairs(self.professions) do
        if next(row.recipes) then
            self:Call(function()
                self.Data:ApplyScanResult(row.name, row.recipes, { reason = "sim-scan", notifyMode = "silent" })
            end)
        end
    end
end

function Peer:Logout()
    self.online = false
    self.sim:RosterChanged()
end

function Peer:Reload()
    self.online = false
    self:Login(true)
end

function Peer:RequestRosterUpdate(delay)
    if self.rosterBucket or not self.online then return end
    self.rosterBucket = self.sim:Schedule(delay or 1.5, function()
        self.rosterBucket = nil
        -- OnGuildRosterBucket + ProcessCoalescedGuildRosterUpdate
        self.Data:RefreshGuildScope("guild-roster-update")
        self.Data:RebuildOnlineCache()
        self.Sync:OnGuildRosterUpdate({ reason = "bucket" })
    end, self)
end

function Sim:RosterChanged()
    for _, name in ipairs(self.order) do
        local p = self.peers[name]
        if p.online then p:RequestRosterUpdate(1.5) end
    end
end

function Peer:SetCombat(on)
    self.inCombat = on == true
    self:Call(function() self.Pause:RefreshPauseState() end)
end

function Peer:SetInstance(on)
    self.inInstance = on == true
    self:Call(function()
        self.Pause:RefreshPauseState()
        -- OnPlayerEnteringWorld del cambio di zona
        self.Sync:EnterWorldTransition(on and "instance-enter" or "zone-enter", on and 15 or 12)
        self.Data:ScheduleSyncIndexPrepare("player-entering-world", 1)
        self.Sync:RefreshSyncReadyState("player-entering-world")
        if not on then self.Data:DetectProfessions() end
    end)
end

-- ---------------------------------------------------------------- verifiche

-- i blocchi non vuoti che un client ha nel suo cassetto di gilda
function Peer:Blocks()
    local out = {}
    local ok = self:Call(function()
        for owner, entry in pairs(self.Data:GetMembersDB()) do
            for prof, block in pairs(entry.professions or {}) do
                if next(block.recipes or {}) then
                    out[owner .. "::" .. prof] = block.recipes
                end
            end
        end
    end)
    return ok and out or {}
end

function Peer:Fingerprint()
    local fp
    self:Call(function() fp = self.Data:RefreshGlobalFingerprint("sim") end)
    return fp
end

-- cio' che la gilda dovrebbe sapere: i mestieri di ognuno, adesso
function Sim:TruthBlocks(names)
    local out = {}
    for _, name in ipairs(names or self.order) do
        local p = self.peers[name]
        for _, row in ipairs(p.professions) do
            if next(row.recipes) then out[p.name .. "::" .. row.name] = row.recipes end
        end
    end
    return out
end

local function sameSet(a, b)
    for k in pairs(a or {}) do if not (b and b[k]) then return false end end
    for k in pairs(b or {}) do if not (a and a[k]) then return false end end
    return true
end

-- Nessuna ricetta inventata: ogni ricetta che un client ha per un compagno e'
-- una che quel compagno ha avuto davvero, in quel mestiere.
function Sim:CheckNoInventedContent()
    for _, name in ipairs(self.order) do
        local p = self.peers[name]
        if p.env then
            for key, recipes in pairs(p:Blocks()) do
                local owner, prof = key:match("^(.-)::(.+)$")
                local truth = self.peers[owner] and self.peers[owner].ever[prof]
                if not truth then
                    self:Violation(string.format("%s ha un blocco che nessuno ha mai avuto: %s", name, key))
                else
                    for recipe in pairs(recipes) do
                        if not truth[recipe] then
                            self:Violation(string.format("%s ha in %s la ricetta %s, mai avuta", name, key, tostring(recipe)))
                        end
                    end
                end
            end
        end
    end
end

-- I blocchi che un client ha di troppo e quelli che gli mancano, rispetto alla
-- verita' della gilda.
function Sim:Diff(peer, truth)
    truth = truth or self:TruthBlocks()
    local have = peer:Blocks()
    local missing, extra, wrong = {}, {}, {}
    for key, recipes in pairs(truth) do
        if not have[key] then missing[#missing + 1] = key
        elseif not sameSet(have[key], recipes) then wrong[#wrong + 1] = key end
    end
    for key in pairs(have) do
        if not truth[key] then extra[#extra + 1] = key end
    end
    table.sort(missing); table.sort(extra); table.sort(wrong)
    return missing, extra, wrong
end

function Sim:IsConverged(names, truth)
    for _, name in ipairs(names or self.order) do
        local missing, extra, wrong = self:Diff(self.peers[name], truth)
        if #missing + #extra + #wrong > 0 then return false end
    end
    return true
end

-- gira finche' tutti hanno tutto, o finche' scade il tempo; restituisce i
-- secondi che ci sono voluti, o nil
function Sim:RunUntilConverged(maxSeconds, names, truth, step)
    local started = self.clock
    step = step or 15
    while self.clock - started < maxSeconds do
        self:Run(step)
        if self:IsConverged(names, truth) then return self.clock - started end
    end
    return nil
end

local WAITING = {
    ["seed-selected"] = true, ["waiting-index-diff"] = true, ["index-diff-ready"] = true,
    ["waiting-block"] = true, ["waiting-next-block-delay"] = true, ["request-next-block"] = true,
}

-- Nessuna sessione appesa: una sessione aperta che non fa progressi oltre il
-- limite vuol dire che i timeout non scattano.
function Sim:CheckStuckSessions()
    for _, name in ipairs(self.order) do
        local p = self.peers[name]
        local s = p.online and p.Sync and p.Sync.outboundSeedSession
        if type(s) == "table" and WAITING[s.state] then
            local since = self.clock - (s.lastProgressAt or s.startedAt or self.clock)
            if since > self.stuckLimit and not s._simReported then
                s._simReported = true
                self:Violation(string.format("%s: sessione verso %s ferma in %s da %d s",
                    name, tostring(s.seedKey), tostring(s.state), since))
            end
        end
    end
end

function Sim:Report(label)
    local kinds = {}
    for kind in pairs(self.stats.sent) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    local parts = {}
    for _, kind in ipairs(kinds) do
        parts[#parts + 1] = string.format("%s=%d", kind, self.stats.sent[kind])
    end
    return string.format("%s: %s | pezzi rifiutati=%d persi=%d sussurri a offline=%d",
        label or "traffico", table.concat(parts, " "), self.stats.rejectedParts, self.stats.lostParts,
        self.stats.whisperOffline)
end

function Sim:SnapshotSent()
    local copy = {}
    for k, v in pairs(self.stats.sent) do copy[k] = v end
    return copy
end

function Sim:SentSince(snapshot, kind)
    return (self.stats.sent[kind] or 0) - (snapshot[kind] or 0)
end

Sim.Peer = Peer
return Sim
