-- Un cassetto per gilda.
--
-- Il bug, visto in gioco il 2026-10-17: "Dudu Davian", senza gilda, vedeva le
-- ricette dei compagni di gilda di "Kaedros Davian", un altro personaggio dello
-- stesso account. Il sync non c'entrava: RecipeRegistryDB e' uno per account,
-- e i membri stavano tutti in una tabella sola.
--
-- I casi a due gilde in gioco non si possono provare -- servirebbe fondarne
-- una -- quindi stanno qui, con uno stub di IsInGuild, GetGuildInfo e del
-- roster. Si lancia da RecipeRegistry_Forever/ con run-tests.ps1.

local modules = {}
_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function() end, Print = function() end, Tracef = function() end,
  RequestRefresh = function() end,
  Compat = setmetatable({}, { __index = function() return function() end end }),
}

-- il client, come lo vede ogni scenario
local client = {}
local function login(first, surname, guild, roster)
  client.first, client.surname = first, surname
  client.inGuild = guild ~= nil
  client.guildName = guild
  client.roster = roster or {}
end
_G.UnitNameUnmodified = function() return client.first, client.surname end
_G.IsLoggedIn = function() return true end
_G.IsInGuild = function() return client.inGuild end
_G.GetGuildInfo = function() return client.guildName end
_G.GetNumGuildMembers = function() return #client.roster end
_G.GetGuildRosterInfo = function(i) return client.roster[i] end
_G.time = os.time
_G.GetTime = os.clock

dofile("Data/Data.lua")
dofile("Data/DataGuildScope.lua")
local Data = _G.RecipeRegistry.Data or modules["Data"]

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-58s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

local function entry(owner, sourceType, recipes, lastUpdatedAt)
  local set = {}
  for _, k in ipairs(recipes or { 1 }) do set[k] = true end
  return {
    owner = owner, sourceType = sourceType, updatedAt = lastUpdatedAt or 100,
    professions = { Alchemy = { recipes = set, lastUpdatedAt = lastUpdatedAt or 100, skillRank = 10 } },
  }
end

local function count(tbl)
  local n = 0
  for _ in pairs(tbl or {}) do n = n + 1 end
  return n
end

-- il file di un account allo schema 3: la gilda di Kaedros, Kaedros, e Dudu
-- che ha aperto il suo mestiere senza gilda
local function schema3File()
  return { global = { meta = { schemaVersion = 3 }, members = {
    ["Kaedros Davian"] = entry("Kaedros Davian", "owner", { 1, 2 }),
    ["Dudu Davian"] = entry("Dudu Davian", "owner", { 9 }),
    ["Aria Vento"] = entry("Aria Vento", "replica"),
    ["Bram Sasso"] = entry("Bram Sasso", "replica"),
    ["Cora Fiume"] = entry("Cora Fiume", "replica"),
  } } }
end

local KAEDROS_ROSTER = { "Kaedros Davian", "Aria Vento", "Bram Sasso", "Cora Fiume", "Zed Nuovo" }

local function newSession(db)
  Data.db = db
  Data._guildScope = nil
  Data._pendingMembers = nil
  Data._legacyClaimVerdict = nil
  Data:MigrateDatabase()
end

print("== il bug: Dudu senza gilda non vede la gilda di Kaedros ==")
local db = schema3File()
login("Dudu", "Davian", nil)
newSession(db)
local members = Data:GetMembersDB()
t("vede solo se stesso", count(members), 1)
t("e se stesso c'e'", members["Dudu Davian"] ~= nil, true)
t("Aria non c'e'", Data:GetMember("Aria Vento"), nil)
t("Kaedros non c'e'", Data:GetMember("Kaedros Davian"), nil)
t("ambito", Data:GetGuildScope().kind, "unguilded")
-- la tabella vecchia resta li', per la gilda a cui appartiene
t("la tabella vecchia aspetta", db.global.members ~= nil, true)
t("senza Dudu, che e' venuto via", db.global.members["Dudu Davian"], nil)
t("lo schema resta 3", db.global.meta.schemaVersion, 3)
t("il cassetto di Dudu e' suo", db.global.unguilded["Dudu Davian"].members["Dudu Davian"] ~= nil, true)

print("\n== poi Kaedros, in gilda: il roster prova che la tabella e' sua ==")
login("Kaedros", "Davian", "Lame d'Argento", {})
newSession(db)
members = Data:GetMembersDB()
t("roster non ancora arrivato: solo Kaedros", count(members), 1)
t("la tabella vecchia aspetta ancora", db.global.members ~= nil, true)
client.roster = KAEDROS_ROSTER
Data:RefreshGuildScope("guild-roster-update")
members = Data:GetMembersDB()
t("col roster: tutta la gilda", count(members), 4)
t("Aria c'e'", members["Aria Vento"] ~= nil, true)
t("Dudu no: e' un alt fuori dal roster", members["Dudu Davian"], nil)
t("la tabella vecchia se n'e' andata", db.global.members, nil)
t("schema 4", db.global.meta.schemaVersion, 4)
t("le ricette di Kaedros intatte", members["Kaedros Davian"].professions.Alchemy.count, 2)

print("\n== e Dudu, di nuovo: ancora solo se stesso ==")
login("Dudu", "Davian", nil)
newSession(db)
t("vede solo se stesso", count(Data:GetMembersDB()), 1)
t("lo schema non torna indietro", db.global.meta.schemaVersion, 4)

print("\n== se il primo login e' di Kaedros, Dudu va nel suo cassetto ==")
db = schema3File()
login("Kaedros", "Davian", "Lame d'Argento", KAEDROS_ROSTER)
newSession(db)
members = Data:GetMembersDB()
t("la gilda", count(members), 4)
t("Dudu non e' fra i compagni", members["Dudu Davian"], nil)
t("Dudu e' parcheggiato", db.global.unguilded["Dudu Davian"].members["Dudu Davian"] ~= nil, true)
login("Dudu", "Davian", nil)
newSession(db)
t("e al suo login lo ritrova", Data:GetMembersDB()["Dudu Davian"].professions.Alchemy.count, 1)

print("\n== un alt che entra in un'altra gilda non si porta via la tabella ==")
db = schema3File()
login("Dudu", "Davian", "Altra Gilda", { "Dudu Davian", "Estraneo Uno", "Estraneo Due" })
newSession(db)
members = Data:GetMembersDB()
t("Dudu vede solo se stesso", count(members), 1)
t("la tabella vecchia resta per Kaedros", db.global.members ~= nil, true)
t("con la gilda di Kaedros dentro", db.global.members["Aria Vento"] ~= nil, true)
t("schema 3", db.global.meta.schemaVersion, 3)

print("\n== gilda non ancora nota: niente su disco, niente perso ==")
db = { global = { meta = { schemaVersion = 4 }, guilds = {
  ["Lame d'Argento"] = { members = { ["Kaedros Davian"] = entry("Kaedros Davian", "owner", { 1, 2 }, 100) } },
} } }
login("Kaedros", "Davian", "Lame d'Argento", KAEDROS_ROSTER)
client.guildName = nil   -- IsInGuild si', il nome non ancora
newSession(db)
t("ambito ignoto", Data:GetGuildScope(), nil)
local pending = Data:GetMembersDB()
t("tabella provvisoria vuota", count(pending), 0)
-- DetectProfessions al login scrive la voce del giocatore
Data:GetOrCreateMember("Kaedros Davian").professions.Alchemy = { recipes = { [3] = true }, lastUpdatedAt = 200, skillRank = 20 }
t("non e' finita nel cassetto", db.global.guilds["Lame d'Argento"].members["Kaedros Davian"].professions.Alchemy.recipes[3], nil)
client.guildName = "Lame d'Argento"
Data:RefreshGuildScope("guild-roster-update")
local alch = Data:GetMembersDB()["Kaedros Davian"].professions.Alchemy
t("le ricette si sommano", alch.count, 3)
t("il rango e' quello piu' recente", alch.skillRank, 20)

print("\n== la corsa del login: IsInGuild false per un attimo ==")
db = { global = { meta = { schemaVersion = 4 }, guilds = {
  ["Lame d'Argento"] = { members = {
    ["Kaedros Davian"] = entry("Kaedros Davian", "owner", { 1, 2 }),
    ["Aria Vento"] = entry("Aria Vento", "replica"),
  } },
} } }
login("Kaedros", "Davian", nil)
newSession(db)
t("per un attimo senza gilda", Data:GetGuildScope().kind, "unguilded")
t("la sua voce lo segue", Data:GetMembersDB()["Kaedros Davian"] ~= nil, true)
login("Kaedros", "Davian", "Lame d'Argento", KAEDROS_ROSTER)
Data:RefreshGuildScope("player-guild-update")
members = Data:GetMembersDB()
t("di nuovo in gilda", Data:GetGuildScope().name, "Lame d'Argento")
t("la voce e' tornata", members["Kaedros Davian"].professions.Alchemy.count, 2)
t("Aria c'e' ancora", members["Aria Vento"] ~= nil, true)
t("il cassetto vuoto se n'e' andato", db.global.unguilded, nil)

print("\n== uscire dalla gilda a sessione aperta ==")
login("Kaedros", "Davian", nil)
Data:RefreshGuildScope("player-guild-update")
t("vede solo se stesso", count(Data:GetMembersDB()), 1)
t("la gilda resta alla gilda", db.global.guilds["Lame d'Argento"].members["Aria Vento"] ~= nil, true)
t("senza Kaedros", db.global.guilds["Lame d'Argento"].members["Kaedros Davian"], nil)

print("\n== file nuovo: nessuna tabella vecchia, schema 4 ==")
db = { global = { meta = { schemaVersion = 3 } } }
login("Kaedros", "Davian", "Lame d'Argento", KAEDROS_ROSTER)
newSession(db)
t("vuoto", count(Data:GetMembersDB()), 0)
t("schema 4", db.global.meta.schemaVersion, 4)

print("")
if fails > 0 then
  print(fails .. " FAIL")
  os.exit(1)
end
print("all ok")
