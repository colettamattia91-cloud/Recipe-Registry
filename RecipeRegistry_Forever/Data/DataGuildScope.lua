local Addon = _G.RecipeRegistry
local Data = Addon.Data

local pairs = pairs
local next = next
local type = type
local max = math.max
local tostring = tostring

-- Un cassetto per gilda.
--
-- RecipeRegistryDB e' uno per account, e fino allo schema 3 i membri stavano
-- tutti in una tabella sola, db.global.members. Il sync il confine della gilda
-- lo rispettava gia' -- parla solo in GUILD e WHISPER verso il roster -- ma il
-- disco no: un personaggio senza gilda, o in un'altra gilda, leggeva quello
-- che un suo alt aveva salvato. Visto in gioco il 2026-10-17: "Dudu Davian",
-- senza gilda, vedeva le ricette dei compagni di gilda di "Kaedros Davian".
--
-- Da qui i membri stanno in un cassetto per ambito:
--
--   db.global.guilds[<nome della gilda>].members   un personaggio in gilda
--   db.global.unguilded[<chiave>].members          un personaggio senza gilda
--
-- Il secondo e' per personaggio, non condiviso: senza gilda non c'e' sync, e
-- l'unica voce che ci finisce e' quella del personaggio stesso. Un cassetto
-- condiviso fra tutti gli alt senza gilda rifarebbe in piccolo lo stesso bug.
--
-- La voce del giocatore segue il personaggio. Le sue ricette sono un fatto suo,
-- non della gilda: quando cambia ambito -- entra, esce, cambia gilda -- la sua
-- voce si sposta con lui, ovunque fosse, e si fonde se di la' ce n'e' gia' una.
-- E' la stessa regola a riparare la corsa del login, dove IsInGuild() puo'
-- rispondere false per qualche istante: la voce va nel cassetto senza gilda e
-- torna indietro appena la gilda si fa viva, senza perdere niente.
--
-- Il nome della gilda e' la chiave. Una gilda rinominata lascia un cassetto
-- orfano: limite accettato il 2026-09-22, il sync ripopola quello nuovo.

local SCHEMA_VERSION = 4

local function trace(fmt, ...)
    if Addon.Tracef then
        Addon:Tracef("sync", fmt, ...)
    end
end

-- Ambito corrente, letto dal client. nil finche' non si sa: prima del login
-- (il nome del giocatore non c'e' ancora), e in gilda finche' GetGuildInfo
-- tace, che al login succede fino all'arrivo del roster.
local function resolveScope(data)
    if type(IsLoggedIn) == "function" and not IsLoggedIn() then
        return nil
    end
    local playerKey = data:GetPlayerKey()
    if playerKey == "Unknown" then
        return nil
    end
    if not (type(IsInGuild) == "function" and IsInGuild() == true) then
        return "unguilded", playerKey
    end
    local guildName = type(GetGuildInfo) == "function" and GetGuildInfo("player") or nil
    if type(guildName) ~= "string" or guildName == "" then
        return nil
    end
    return "guild", guildName
end

local function getContainer(data, kind)
    local global = data.db.global
    local field = kind == "guild" and "guilds" or "unguilded"
    if type(global[field]) ~= "table" then
        global[field] = {}
    end
    return global[field]
end

local function ensureDrawer(data, kind, name)
    local container = getContainer(data, kind)
    local drawer = container[name]
    if type(drawer) ~= "table" then
        drawer = {}
        container[name] = drawer
    end
    if type(drawer.members) ~= "table" then
        drawer.members = {}
    end
    return drawer
end

local function getLegacyMembers(data)
    local legacy = data.db.global.members
    return type(legacy) == "table" and legacy or nil
end

-- Ogni tabella di membri che non e' quella corrente: il cassetto provvisorio,
-- la tabella dello schema 3 e gli altri cassetti.
local function eachOtherMembersTable(data, current, fn)
    if data._pendingMembers and data._pendingMembers ~= current then
        fn(data._pendingMembers)
    end
    local legacy = getLegacyMembers(data)
    if legacy and legacy ~= current then
        fn(legacy)
    end
    for _, field in pairs({ "guilds", "unguilded" }) do
        local container = data.db.global[field]
        if type(container) == "table" then
            for _, drawer in pairs(container) do
                if type(drawer) == "table" and type(drawer.members) == "table" and drawer.members ~= current then
                    fn(drawer.members)
                end
            end
        end
    end
end

-- Due voci dello stesso personaggio diventano una. Additiva come il sync: le
-- ricette si uniscono, nessuna si perde; rango e specializzazione vengono dal
-- blocco aggiornato piu' di recente.
local function mergeMemberEntry(data, members, memberKey, incoming)
    if type(incoming) ~= "table" then
        return
    end
    local existing = members[memberKey]
    if type(existing) ~= "table" then
        members[memberKey] = incoming
        return
    end
    existing.professions = type(existing.professions) == "table" and existing.professions or {}
    existing.updatedAt = max(tonumber(existing.updatedAt or 0) or 0, tonumber(incoming.updatedAt or 0) or 0)
    for professionKey, prof in pairs(type(incoming.professions) == "table" and incoming.professions or {}) do
        local have = existing.professions[professionKey]
        if type(have) ~= "table" then
            existing.professions[professionKey] = prof
        elseif type(prof) == "table" then
            have.recipes = type(have.recipes) == "table" and have.recipes or {}
            for recipeKey, value in pairs(type(prof.recipes) == "table" and prof.recipes or {}) do
                if have.recipes[recipeKey] == nil then
                    have.recipes[recipeKey] = value
                end
            end
            if (tonumber(prof.lastUpdatedAt or 0) or 0) > (tonumber(have.lastUpdatedAt or 0) or 0) then
                have.skillRank = prof.skillRank
                have.skillMaxRank = prof.skillMaxRank
                have.specialization = prof.specialization
                have.lastUpdatedAt = prof.lastUpdatedAt
            end
        end
    end
    data:NormalizeMemberEntry(existing, memberKey)
end

-- Porta la voce del giocatore nel cassetto corrente, da ovunque fosse.
local function adoptOwnEntry(data, members)
    local playerKey = data:GetPlayerKey()
    local moved = false
    eachOtherMembersTable(data, members, function(source)
        local entry = source[playerKey]
        if entry ~= nil then
            source[playerKey] = nil
            mergeMemberEntry(data, members, playerKey, entry)
            moved = true
        end
    end)
    return moved
end

-- Un cassetto senza nessuno dentro non serve a niente, e il cassetto senza
-- gilda di un personaggio che ne e' uscito resterebbe nel file per sempre.
local function pruneEmptyDrawers(data, keep)
    for _, field in pairs({ "guilds", "unguilded" }) do
        local container = data.db.global[field]
        if type(container) == "table" then
            for name, drawer in pairs(container) do
                if drawer ~= keep and (type(drawer) ~= "table"
                    or type(drawer.members) ~= "table"
                    or next(drawer.members) == nil)
                then
                    container[name] = nil
                end
            end
            if next(container) == nil then
                data.db.global[field] = nil
            end
        end
    end
end

local function liveRosterKeys(data)
    local total = type(GetNumGuildMembers) == "function" and (GetNumGuildMembers() or 0) or 0
    if total <= 0 or type(GetGuildRosterInfo) ~= "function" then
        return nil
    end
    local keys = {}
    for index = 1, total do
        local memberKey = data:MemberKeyFromFullName((GetGuildRosterInfo(index)))
        if memberKey then
            keys[memberKey] = true
        end
    end
    return keys
end

local function markScopeChanged(data, reason)
    if data.MarkSyncIndexDirty then
        data:MarkSyncIndexDirty(reason, nil, { full = true })
    end
    if data.ScheduleSyncIndexPrepare then
        data:ScheduleSyncIndexPrepare(reason, 0.5)
    end
    data:InvalidateRecipeCaches("members")
    if Addon.RequestRefresh then
        Addon:RequestRefresh(reason)
    end
end

function Data:GetGuildScope()
    if not self._guildScope then
        self:RefreshGuildScope("lazy")
    end
    local scope = self._guildScope
    if not scope then
        return nil
    end
    return { kind = scope.kind, name = scope.name }
end

-- La tabella dello schema 3 a quale gilda appartiene? Alla prima che la prova
-- sua col roster, non alla prima che fa login: un alt entrato in un'altra
-- gilda prima che il personaggio di sempre rientri se la porterebbe via.
--
-- La prova sono le voci dei compagni (sourceType diverso da "owner"): almeno
-- meta' devono essere nel roster vivo. Gli alt dell'account non sono prova in
-- nessun senso; quelli che il roster non conosce non entrano nella gilda, ma
-- vanno parcheggiati nel loro cassetto senza gilda, da cui li riprende il loro
-- prossimo login.
--
-- Finche' il roster non arriva si aspetta, e si riprova al prossimo
-- GUILD_ROSTER_UPDATE.
function Data:TryClaimLegacyMembers(reason)
    local legacy = getLegacyMembers(self)
    local meta = self:GetGlobalMeta()
    if not legacy then
        meta.schemaVersion = max(meta.schemaVersion or 0, SCHEMA_VERSION)
        return false, "no-legacy"
    end
    if next(legacy) == nil then
        self.db.global.members = nil
        meta.schemaVersion = max(meta.schemaVersion or 0, SCHEMA_VERSION)
        return false, "legacy-empty"
    end
    local scope = self._guildScope
    if not scope or scope.kind ~= "guild" then
        return false, "not-in-guild"
    end
    local roster = liveRosterKeys(self)
    if not roster then
        return false, "roster-pending"
    end

    local peers, peersInRoster = 0, 0
    for memberKey, entry in pairs(legacy) do
        if not (type(entry) == "table" and entry.sourceType == "owner") then
            peers = peers + 1
            if roster[memberKey] then
                peersInRoster = peersInRoster + 1
            end
        end
    end
    if peersInRoster * 2 < peers then
        -- si riprova a ogni aggiornamento del roster; basta dirlo una volta
        local verdict = scope.id .. ":" .. peers .. ":" .. peersInRoster
        if self._legacyClaimVerdict ~= verdict then
            self._legacyClaimVerdict = verdict
            trace("guild-scope legacy-not-claimed guild=%s peers=%d inRoster=%d",
                tostring(scope.name), peers, peersInRoster)
        end
        return false, "roster-mismatch"
    end

    for memberKey, entry in pairs(legacy) do
        local ownAlt = type(entry) == "table" and entry.sourceType == "owner"
        if ownAlt and not roster[memberKey] then
            mergeMemberEntry(self, ensureDrawer(self, "unguilded", memberKey).members, memberKey, entry)
        else
            mergeMemberEntry(self, scope.members, memberKey, entry)
        end
    end
    self.db.global.members = nil
    meta.schemaVersion = max(meta.schemaVersion or 0, SCHEMA_VERSION)
    trace("guild-scope legacy-claimed guild=%s peers=%d inRoster=%d reason=%s",
        tostring(scope.name), peers, peersInRoster, tostring(reason or "unknown"))
    markScopeChanged(self, "guild-scope-legacy")
    return true, "claimed"
end

-- Rilegge l'ambito dal client e, se e' cambiato, apre il cassetto giusto.
-- Un ambito che il client non sa ancora dire non sposta niente: resta quello
-- che c'era, o il cassetto provvisorio se non c'era ancora niente.
function Data:RefreshGuildScope(reason)
    reason = tostring(reason or "unknown")
    local kind, name = resolveScope(self)
    if not kind then
        return false, "unresolved"
    end
    local scopeId = kind .. ":" .. name
    local previous = self._guildScope
    if previous and previous.id == scopeId then
        if kind == "guild" then
            self:TryClaimLegacyMembers(reason)
        end
        return false, "unchanged"
    end

    local drawer = ensureDrawer(self, kind, name)
    self._guildScope = { id = scopeId, kind = kind, name = name, members = drawer.members }
    adoptOwnEntry(self, drawer.members)
    self._pendingMembers = nil
    pruneEmptyDrawers(self, drawer)
    trace("guild-scope switch from=%s to=%s reason=%s",
        tostring(previous and previous.id or "none"), scopeId, reason)

    if kind == "guild" then
        self:TryClaimLegacyMembers(reason)
    else
        local meta = self:GetGlobalMeta()
        if not getLegacyMembers(self) then
            meta.schemaVersion = max(meta.schemaVersion or 0, SCHEMA_VERSION)
        end
    end

    -- Un cambio di gilda a sessione aperta: il roster di prima non dice piu'
    -- niente su chi c'e' adesso.
    if previous and kind == "guild" and self.RequestRosterSnapshot then
        self:RequestRosterSnapshot("guild-scope-change", { force = true, cooldown = 0, source = "guild-scope" })
    end
    markScopeChanged(self, "guild-scope")
    return true, scopeId
end

function Data:GetMembersDB()
    local scope = self._guildScope
    if not scope then
        self:RefreshGuildScope("lazy")
        scope = self._guildScope
    end
    if scope then
        return scope.members
    end
    -- Ambito ignoto: una tabella che non va su disco. Se qualcosa ci scrive la
    -- voce del giocatore -- DetectProfessions al login, prima che la gilda si
    -- presenti -- adoptOwnEntry la porta nel cassetto vero appena c'e'.
    self._pendingMembers = self._pendingMembers or {}
    return self._pendingMembers
end

-- Tutte le tabelle di membri del file, la corrente compresa: per la
-- normalizzazione al caricamento, che non deve aspettare la gilda.
function Data:ForEachStoredMembersTable(fn)
    eachOtherMembersTable(self, nil, fn)
end
