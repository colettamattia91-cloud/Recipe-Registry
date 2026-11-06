-- Chi cambia mestiere, visto dagli altri.
--
-- Il bug, visto in gioco il 2026-11-06: un compagno passato ad Alchemy
-- risultava alla gilda con tre mestieri principali, Alchemy, Mining e
-- Skinning. Sul suo client PruneDroppedProfessions aveva fatto il suo lavoro;
-- sulle repliche no, perche' il sync e' additivo e nessun messaggio diceva che
-- un blocco non c'era piu'. Peggio: chi ancora l'aveva lo offriva come
-- "missing" a chiunque, proprietario compreso.
--
-- Ora il proprietario dichiara i suoi mestieri nel HELLO e nel SUMMARY, chi lo
-- sente pota gli altri e li segna, e un blocco segnato non si ritira da un
-- compagno rimasto indietro. Si lancia da RecipeRegistry_Forever/ con
-- run-tests.ps1.

local modules = {}
local traces = {}
_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function() end, Print = function() end, SystemPrint = function() end,
  Tracef = function(_, _, fmt, ...) traces[#traces + 1] = string.format(fmt, ...) end,
  RequestRefresh = function() end,
  Compat = setmetatable({
    GetItemInfoInstant = function(id) return id end,
    GetItemInfo = function(id) return "item " .. tostring(id) end,
    GetSpellInfo = function(id) return "spell " .. tostring(id) end,
  }, { __index = function() return function() end end }),
}
local Addon = _G.RecipeRegistry

_G.UnitNameUnmodified = function() return "Kaedros", "Davian" end
_G.GetRealmName = function() return "CamWoW EU4 Realm 7 PvE" end
_G.GetNumGuildMembers = function() return 0 end
_G.IsSpellKnown = function() return false end
_G.C_SpellBook = { IsSpellKnown = function() return false end }
_G.time = os.time
_G.GetTime = os.clock

-- i mestieri del personaggio locale, come li dice GetProfessions
local localProfessions = { "Tailoring", "Cooking" }
_G.GetProfessions = function()
  local idx = {}
  for i = 1, #localProfessions do idx[i] = i end
  return unpack(idx)
end
_G.GetProfessionInfo = function(i) return localProfessions[i], nil, 1, 75 end

dofile("Data/Data.lua")
dofile("Data/DataGuildScope.lua")
dofile("Data/DataScan.lua")
dofile("Data/DataIndex.lua")
dofile("Data/DataSnapshot.lua")
dofile("Data/MergeEngine.lua")
local Data = Addon.Data or modules["Data"]
Addon.Data = Data
Addon.MergeEngine = Addon.MergeEngine or modules["MergeEngine"]
-- l'indice di sync rimanda la ricostruzione con AceTimer: qui non serve
Data.ScheduleTimer = function() return {} end
Data.CancelTimer = function() end

-- quello che BuildWantedBlockOrder chiede al resto del modulo Sync
Addon.Sync = { _private = { constants = {} } }
dofile("Sync/SyncRequests.lua")
local Sync = Addon.Sync

Data.db = { global = { options = {} } }
_G.RecipeRegistry.charDB = { favorites = {} }

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-60s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

local function set(keys)
  local out = {}
  for _, k in ipairs(keys) do out[k] = true end
  return out
end

local function replicaBlock(recipes)
  return { recipes = set(recipes), count = #recipes, sourceType = "replica", guildStatus = "active" }
end

local function wantedKeys(rows)
  local keys = {}
  for _, row in ipairs(rows) do keys[#keys + 1] = row.blockKey end
  table.sort(keys)
  return table.concat(keys, ",")
end

local ALARNOS = "Alarnos Duskhallow"
local members = Data:GetMembersDB()
-- com'era nel database di Kaedros il 06/11: tre mestieri principali
members[ALARNOS] = {
  owner = ALARNOS, sourceType = "replica", guildStatus = "active",
  professions = {
    Cooking = replicaBlock({ 2679, 6888 }),
    Skinning = replicaBlock({ 279979 }),
    Mining = replicaBlock({ 2840 }),
    Alchemy = replicaBlock({ 247755 }),
  },
}
local alarnos = members[ALARNOS]

print("== chi non ha ancora parlato non perde niente ==")
t("lista assente: niente", Data:ApplyOwnerProfessionDeclaration(ALARNOS, nil), false)
t("lista vuota: niente", Data:ApplyOwnerProfessionDeclaration(ALARNOS, {}), false)
-- un nome che non e' un mestiere tracciato non conta come dichiarazione
t("solo nomi sconosciuti: niente", Data:ApplyOwnerProfessionDeclaration(ALARNOS, { "Archaeology" }), false)
t("Skinning ancora li'", alarnos.professions.Skinning ~= nil, true)
t("Mining ancora li'", alarnos.professions.Mining ~= nil, true)
t("una dichiarazione non crea voci", Data:ApplyOwnerProfessionDeclaration("Nessuno Mai", { "Cooking" }), false)
t("e infatti Nessuno Mai non c'e'", Data:GetMember("Nessuno Mai"), nil)

print("\n== la dichiarazione del proprietario pota ==")
-- Herbalism non ha ricette, quindi nessun blocco: dichiararlo e' innocuo
local pruned, dropped = Data:ApplyOwnerProfessionDeclaration(ALARNOS,
  { "Alchemy", "Cooking", "First Aid", "Fishing", "Herbalism" })
t("ha potato", pruned, true)
t("cosa", table.concat(dropped or {}, ","), "Mining,Skinning")
t("Skinning via", alarnos.professions.Skinning, nil)
t("Mining via", alarnos.professions.Mining, nil)
t("Alchemy resta", alarnos.professions.Alchemy ~= nil, true)
t("Cooking resta, con le sue ricette", alarnos.professions.Cooking.recipes[2679], true)
t("Skinning segnata", alarnos.droppedProfessions and alarnos.droppedProfessions.Skinning, true)
t("Mining segnata", alarnos.droppedProfessions and alarnos.droppedProfessions.Mining, true)
t("la seconda volta non c'e' altro da potare", Data:ApplyOwnerProfessionDeclaration(ALARNOS,
  { "Alchemy", "Cooking", "First Aid", "Fishing", "Herbalism" }), false)

print("\n== un compagno rimasto indietro non lo rimette ==")
local offered = {
  { blockKey = ALARNOS .. "::Skinning", count = 1, fingerprint = "bf3:1:a", reason = "missing" },
  { blockKey = ALARNOS .. "::Mining", count = 1, fingerprint = "bf3:1:b", reason = "missing" },
  { blockKey = ALARNOS .. "::Cooking", count = 3, fingerprint = "bf3:3:c", reason = "requester-lower-count-fingerprint-mismatch" },
}
t("da Prv Qt si chiede solo Cooking", wantedKeys(Sync:BuildWantedBlockOrder(offered, "Prv Qt")), ALARNOS .. "::Cooking")
t("e la traccia lo dice", traces[#traces]:match("^block%-owner%-dropped%-skip") ~= nil, true)

local ok, result = Data:ApplyIncomingBlockAdditive(ALARNOS .. "::Skinning", {
  blockKey = ALARNOS .. "::Skinning", ownerCharacter = ALARNOS, professionKey = "Skinning",
  recipeKeys = { 279979 },
}, { sourceType = "replica" })
t("se arriva lo stesso, non e' un errore", ok, true)
t("ma e' rifiutato", result and result.refused, "owner-dropped")
t("e Skinning non torna", alarnos.professions.Skinning, nil)

print("\n== il proprietario stesso vale piu' del segno ==")
t("se il seed e' Alarnos, Skinning si chiede",
  wantedKeys(Sync:BuildWantedBlockOrder({ offered[1] }, ALARNOS)), ALARNOS .. "::Skinning")
ok, result = Data:ApplyIncomingBlockAdditive(ALARNOS .. "::Skinning", {
  blockKey = ALARNOS .. "::Skinning", ownerCharacter = ALARNOS, professionKey = "Skinning",
  recipeKeys = { 279979 },
}, { sourceType = "owner", fromOwner = true })
t("accettato", ok and result and result.refused == nil, true)
t("Skinning di nuovo", alarnos.professions.Skinning ~= nil, true)
t("il segno di Skinning se n'e' andato", alarnos.droppedProfessions and alarnos.droppedProfessions.Skinning, nil)
t("quello di Mining resta", alarnos.droppedProfessions and alarnos.droppedProfessions.Mining, true)

print("\n== un mestiere ripreso, detto dal proprietario ==")
Data:ApplyOwnerProfessionDeclaration(ALARNOS, { "Alchemy", "Cooking", "Mining", "Skinning" })
t("nessun segno rimasto", alarnos.droppedProfessions, nil)
t("Mining si chiede di nuovo a chiunque",
  wantedKeys(Sync:BuildWantedBlockOrder({ offered[2] }, "Prv Qt")), ALARNOS .. "::Mining")

print("\n== un mestiere mai visto arriva da chiunque ==")
-- il segno vale solo per cio' che la dichiarazione ha tolto: un mestiere
-- nuovo non aspetta di incontrare il proprietario
t("Tailoring da Prv Qt",
  wantedKeys(Sync:BuildWantedBlockOrder({ { blockKey = ALARNOS .. "::Tailoring", count = 2 } }, "Prv Qt")),
  ALARNOS .. "::Tailoring")

print("\n== il personaggio locale ==")
local me = Data:GetPlayerKey()
t("chiave", me, "Kaedros Davian")
Data._currentProfs = nil
t("prima di GetProfessions non si dichiara", Data:GetDeclaredProfessionList(), nil)
Data:DetectProfessions()
t("poi si', in ordine", table.concat(Data:GetDeclaredProfessionList() or {}, ","), "Cooking,Tailoring")
t("la propria dichiarazione non si applica a se'", Data:ApplyOwnerProfessionDeclaration(me, { "Cooking" }), false)
t("Tailoring c'e' ancora", Data:GetMember(me).professions.Tailoring ~= nil, true)

-- passa a Engineering: la potatura locale c'era gia', il resto e' nuovo
localProfessions = { "Engineering", "Cooking" }
Data:GetMember(me).professions.Tailoring.recipes = set({ 2996 })
Data:DetectProfessions()
t("Tailoring potata in locale", Data:GetMember(me).professions.Tailoring, nil)
t("la dichiarazione nuova", table.concat(Data:GetDeclaredProfessionList() or {}, ","), "Cooking,Engineering")
local mine = { { blockKey = me .. "::Tailoring", count = 1, reason = "missing" },
               { blockKey = me .. "::Cooking", count = 4, reason = "missing" } }
t("non si richiede ai compagni la propria Tailoring",
  wantedKeys(Sync:BuildWantedBlockOrder(mine, "Prv Qt")), me .. "::Cooking")
ok, result = Data:ApplyIncomingBlockAdditive(me .. "::Tailoring", {
  blockKey = me .. "::Tailoring", ownerCharacter = me, professionKey = "Tailoring",
  recipeKeys = { 2996 },
}, { sourceType = "replica" })
t("e se arriva lo stesso, rifiutata", result and result.refused, "owner-dropped")
t("Tailoring non torna", Data:GetMember(me).professions.Tailoring, nil)

-- client senza risposta: nessuna opinione, come per la potatura locale
Data._currentProfs = {}
t("senza GetProfessions nessun rifiuto",
  wantedKeys(Sync:BuildWantedBlockOrder({ mine[1] }, "Prv Qt")), me .. "::Tailoring")

print("\n== sul filo: HELLO e SUMMARY ==")
dofile("Sync/SyncProtocol.lua")
-- il resto del modulo Sync, ridotto a cio' che questi quattro percorsi toccano
Sync.telemetry = {}
Sync.syncReady = true
Sync.GetSelfKey = function() return me end
Sync.IsValidSyncMemberKey = function(_, key) return type(key) == "string" and key ~= "" end
Sync.CanRunSyncProtocol = function() return true, "ready" end
Sync.ScheduleTimer = function() return {} end
Sync.CancelTimer = function() end
Sync.GetPeerVersionInfo = function() return {} end
local sent = {}
Sync.SendGuildEnvelope = function(_, kind, payload) sent[kind] = payload; return true end
Sync.SendDirectEnvelope = function(_, kind, payload) sent[kind] = payload; return true end
local realSummary = Data.BuildLocalSummary
Data.BuildLocalSummary = function()
  return { indexStatus = "ready", globalFingerprint = "gf3:mine" }
end

Data:DetectProfessions()
Sync:BroadcastHello()
t("il HELLO porta i mestieri", table.concat(sent.HELLO and sent.HELLO.professions or {}, ","), "Cooking,Engineering")
Sync:SendSummary("Prv Qt", "hello-1")
t("e il SUMMARY anche", table.concat(sent.SUMMARY and sent.SUMMARY.professions or {}, ","), "Cooking,Engineering")

-- Alarnos ha ripreso Mining e Skinning nella sezione sopra; ora li lascia di nuovo
local function alarnosHas(prof) return alarnos.professions[prof] ~= nil end
alarnos.professions.Mining = replicaBlock({ 2840 })
-- il terzo argomento e' il mittente come lo da' CHAT_MSG_ADDON, non quello
-- scritto nel payload
Sync.syncReady = false
Sync:HandleSummary({ sender = ALARNOS, professions = { "Alchemy", "Cooking" } }, "WHISPER", ALARNOS)
t("a sync non pronto la dichiarazione aspetta", alarnosHas("Mining"), true)
Sync.syncReady = true

print("\n== una dichiarazione falsa non cancella niente ==")
-- Prv Qt scrive nel payload di essere Alarnos: il client dice chi e' davvero
Sync:HandleSummary({ sender = ALARNOS, professions = { "Cooking" } }, "WHISPER", "Prv Qt")
t("SUMMARY falso: Mining resta", alarnosHas("Mining"), true)
Sync:HandleHello({ key = ALARNOS, sender = ALARNOS, indexStatus = "ready", globalFingerprint = "gf3:x",
  professions = { "Cooking" } }, "GUILD", "Prv Qt")
t("HELLO falso: Alchemy resta", alarnosHas("Alchemy"), true)
-- e la traccia dice perche'
local lastIgnored
for _, line in ipairs(traces) do
  if line:match("^owner%-declaration%-ignored") then lastIgnored = line end
end
t("la traccia", lastIgnored, "owner-declaration-ignored owner=" .. ALARNOS .. " sender=Prv Qt reason=sender-mismatch")
-- senza mittente del client (MockSync chiama i gestori direttamente) non si pota
Sync:HandleSummary({ sender = ALARNOS, professions = { "Cooking" } })
t("senza mittente del client: niente", alarnosHas("Mining"), true)

print("\n== quella vera si' ==")
Sync:HandleSummary({ sender = ALARNOS, professions = { "Alchemy", "Cooking", "Skinning" } }, "WHISPER", ALARNOS)
t("dal SUMMARY di Alarnos: Mining via", alarnosHas("Mining"), false)
t("Skinning dichiarata, resta", alarnosHas("Skinning"), true)
-- la dichiarazione di un altro parla solo di lui
Sync:HandleSummary({ sender = "Prv Qt", professions = { "Tailoring" } }, "WHISPER", "Prv Qt")
t("il SUMMARY di Prv Qt non tocca Alarnos", alarnosHas("Skinning"), true)
-- un HELLO di un client vecchio, senza il campo
Sync:HandleHello({ key = ALARNOS, sender = ALARNOS, indexStatus = "ready", globalFingerprint = "gf3:x" },
  "GUILD", ALARNOS)
t("HELLO senza mestieri: niente", alarnosHas("Skinning"), true)
sent.SUMMARY = nil
Sync:HandleHello({ key = ALARNOS, sender = ALARNOS, indexStatus = "ready", globalFingerprint = "gf3:x",
  professions = { "Alchemy", "Cooking" } }, "GUILD", ALARNOS)
t("dal HELLO di Alarnos: Skinning via", alarnosHas("Skinning"), false)
t("e il SUMMARY di risposta e' partito", sent.SUMMARY ~= nil, true)
Data.BuildLocalSummary = realSummary

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
