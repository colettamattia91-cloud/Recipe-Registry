-- La chiave di proprietario su Forever.
--
-- Primo spec dell'albero Forever, e la ragione per cui esiste: su questo client
-- un personaggio si chiama "Nome Cognome" e il realm non e' identita', mentre
-- il client una stringa la risponde comunque. Insieme, le due cose toccano la
-- chiave con cui viaggia tutto -- blocchi, fingerprint, routing dei sussurri --
-- e il modo di sbagliare e' silenzioso: due chiavi per la stessa persona,
-- contenuto diviso, fingerprint che non convergono.
--
-- La chiave e' il nome nudo. Il confine dei dati e' la gilda, imposto dal
-- trasporto (sync in "GUILD" e "WHISPER" verso il roster), e dentro una gilda
-- i nomi sono unici: il realm non ha niente da aggiungere.
--
-- I valori qui sotto non sono inventati: sono quelli che il client beta
-- 1.60.1.69913 ha risposto il 2026-09-18 a UnitFullName e GetRealmName.
--
-- Niente harness condiviso: Forever non ne ha ancora uno, e per interrogare le
-- funzioni di chiave basta uno stub che regga il caricamento di Data.lua.
-- Si lancia da RecipeRegistry_Forever/ con run-tests.ps1.

-- stub minimo: basta a caricare Data.lua e interrogare le funzioni di chiave
local modules = {}
_G.RecipeRegistry = setmetatable({
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  RegisterEvent = function() end, RegisterBucketEvent = function() end,
  Compat = setmetatable({}, {__index = function() return function() end end}),
}, {__index = function() return function() end end})

-- quello che il client ha risposto davvero il 2026-09-18
local PLAYER_NAME, PLAYER_REALM = "Kaedros Davian", "ClassicBetaPvE2"
_G.UnitFullName = function() return PLAYER_NAME, PLAYER_REALM end
_G.GetRealmName = function() return "Classic Beta PvE 2" end
_G.GetNumGuildMembers = function() return 0 end

dofile("Data/Data.lua")
local Data = _G.RecipeRegistry.Data or modules["Data"]

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-46s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

print("== la chiave e' il nome ==")
t("GetPlayerKey", Data:GetPlayerKey(), "Kaedros Davian")
t("GetMemberKeyName", Data:GetMemberKeyName("Kaedros Davian"), "Kaedros Davian")

print("\n== roster -> chiave: deve coincidere col personaggio locale ==")
t("nome nudo", Data:MemberKeyFromFullName("Kaedros Davian"), "Kaedros Davian")
t("nome col realm del client", Data:MemberKeyFromFullName("Kaedros Davian-ClassicBetaPvE2"), "Kaedros Davian")
t("cognome col trattino", Data:MemberKeyFromFullName("Jean-Luc Picard"), "Jean-Luc Picard")
t("cognome col trattino + realm", Data:MemberKeyFromFullName("Jean-Luc Picard-ClassicBetaPvE2"), "Jean-Luc Picard")
t("nome singolo", Data:MemberKeyFromFullName("Kaedros"), "Kaedros")

-- Un suffisso che NON e' il nostro realm resta nella chiave. Serve se un giorno
-- il roster elencasse qualcuno di un altro shard -- un altro ruleset, visto che
-- il realm di questo client si chiama "ClassicBetaPvE2": ruleset piu' numero.
-- In WoW una gilda e' di un realm solo, quindi non dovrebbe succedere; se
-- succedesse, due persone diverse con lo stesso nome avrebbero due chiavi
-- diverse invece di fondersi in una, e la chiave resta un bersaglio valido per
-- un sussurro.
t("suffisso di un altro ruleset: resta", Data:MemberKeyFromFullName("Kaedros Davian-ClassicBetaPvP1"), "Kaedros Davian-ClassicBetaPvP1")
t("e non collide con il nostro", Data:MemberKeyFromFullName("Kaedros Davian-ClassicBetaPvE2") ~= Data:MemberKeyFromFullName("Kaedros Davian-ClassicBetaPvP1"), true)
t("stringa vuota", Data:MemberKeyFromFullName(""), nil)

print("\n== il realm cambia sotto i piedi: la chiave no ==")
PLAYER_REALM = "ForeverShard7"
_G.GetRealmName = function() return "Forever Shard 7" end
t("GetPlayerKey dopo il cambio", Data:GetPlayerKey(), "Kaedros Davian")
t("roster dopo il cambio", Data:MemberKeyFromFullName("Kaedros Davian-ForeverShard7"), "Kaedros Davian")

print("\n== il 25/09 il cognome e' passato nel secondo valore ==")
-- UnitFullName risponde "Kaedros", "Davian"; il roster resta "Kaedros Davian".
-- Leggere solo il primo valore dava "Kaedros": un proprietario che il roster
-- non conosce, quindi sempre offline, e le scansioni finivano li'.
PLAYER_NAME, PLAYER_REALM = "Kaedros", "Davian"
_G.GetRealmName = function() return "Classic Beta PvE 2" end
t("GetPlayerKey col cognome a parte", Data:GetPlayerKey(), "Kaedros Davian")
t("coincide col roster", Data:MemberKeyFromFullName("Kaedros Davian"), Data:GetPlayerKey())
-- il cognome non e' un realm: prima il token del realm si leggeva da li'
t("il cognome non e' scambiato per realm", Data:MemberKeyFromFullName("Anna-Davian"), "Anna-Davian")
t("il realm vero si scarta ancora", Data:MemberKeyFromFullName("Anna Rossi-ClassicBetaPvE2"), "Anna Rossi")
PLAYER_REALM = nil
t("senza secondo valore", Data:GetPlayerKey(), "Kaedros")
PLAYER_NAME, PLAYER_REALM = "Kaedros Davian", "ClassicBetaPvE2"

print("\n== l'API del client per i nomi unici per regione ==")
-- Verificato in gioco il 26/09: RegionalUniqueNamesEnabled() true,
-- UnitNameUnmodified("player") -> "Kaedros", "Davian". Quando c'e', decide lei,
-- qualunque cosa risponda UnitFullName.
_G.RegionalUniqueNamesEnabled = function() return true end
_G.UnitNameUnmodified = function() return "Kaedros", "Davian" end
PLAYER_NAME, PLAYER_REALM = "Qualcosa", "DiStrano"
t("nome e cognome dall'API", Data:GetPlayerKey(), "Kaedros Davian")
_G.UnitNameUnmodified = function() return "Kaedros", nil end
t("senza cognome, il nome", Data:GetPlayerKey(), "Kaedros")
-- se il client dice che i nomi NON sono unici per regione, si torna alla
-- deduzione su UnitFullName
_G.RegionalUniqueNamesEnabled = function() return false end
PLAYER_NAME, PLAYER_REALM = "Kaedros", "Davian"
t("API spenta: la deduzione di prima", Data:GetPlayerKey(), "Kaedros Davian")
_G.RegionalUniqueNamesEnabled, _G.UnitNameUnmodified = nil, nil
PLAYER_NAME, PLAYER_REALM = "Kaedros Davian", "ClassicBetaPvE2"

print("\n== IsValidMemberKey: cosa deve passare ==")
t("nome e cognome", Data:IsValidMemberKey("Kaedros Davian"), true)
t("cognome col trattino", Data:IsValidMemberKey("Jean-Luc Picard"), true)
t("nome singolo", Data:IsValidMemberKey("Kaedros"), true)
t("accentato", Data:IsValidMemberKey("Elenore Desclaux"), true)

print("\n== IsValidMemberKey: cosa deve fermare ==")
t("vuota", Data:IsValidMemberKey(""), false)
t("non stringa", Data:IsValidMemberKey(42), false)
-- ":" spezzerebbe le chiavi di blocco "proprietario::professione"
t("coi due punti", Data:IsValidMemberKey("Kaedros:Davian"), false)
t("col separatore di blocco", Data:IsValidMemberKey("Kaedros::Alchemy"), false)
-- "|" e' l'escape di WoW: iniezione di colori e link nelle stringhe della UI
t("con la pipe", Data:IsValidMemberKey("Kaedros|cffff0000X"), false)
t("con un a capo", Data:IsValidMemberKey("Kaedros\nDavian"), false)
-- spazi ai bordi: due chiavi gemelle per lo stesso personaggio
t("spazio in testa", Data:IsValidMemberKey(" Kaedros Davian"), false)
t("spazio in coda", Data:IsValidMemberKey("Kaedros Davian "), false)

print("\n== il sync usa la stessa regola ==")
-- Il sync aveva un validatore suo, arrivato da TBC, che pretendeva il trattino
-- di "Nome-Reame". Su Forever scartava ogni peer come identita' non valida, e
-- due client nella stessa gilda non si vedevano. Adesso chiede a Data: se
-- qualcuno gli ridesse una regola propria, il primo caso qui sotto fallirebbe.
rawset(_G.RecipeRegistry, "Data", Data)
dofile("Sync/Sync.lua")
local Sync = modules["Sync"]
t("un peer Forever e' un peer", Sync:IsValidSyncMemberKey("Kaedros Davian"), true)
t("anche col trattino nel cognome", Sync:IsValidSyncMemberKey("Jean-Luc Picard"), true)
t("nome singolo", Sync:IsValidSyncMemberKey("Kaedros"), true)
t("la propria identita' e' valida", Sync:IsValidSyncMemberKey(Data:GetPlayerKey()), true)
t("chiave di un altro shard", Sync:IsValidSyncMemberKey("Kaedros Davian-ClassicBetaPvP1"), true)
t("i due punti restano fuori", Sync:IsValidSyncMemberKey("Kaedros::alchemy"), false)
t("il pipe resta fuori", Sync:IsValidSyncMemberKey("Kaedros|cff"), false)
t("vuota", Sync:IsValidSyncMemberKey(""), false)

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
