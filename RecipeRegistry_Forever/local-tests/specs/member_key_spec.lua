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
-- I valori qui sotto non sono inventati: sono quelli che il client beta ha
-- risposto in gioco il 2026-09-26: UnitNameUnmodified, il roster e il
-- mittente dei messaggi addon.
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

-- quello che il client ha risposto davvero il 2026-09-26
local PLAYER_FIRST, PLAYER_SURNAME = "Kaedros", "Davian"
_G.UnitNameUnmodified = function() return PLAYER_FIRST, PLAYER_SURNAME end
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

print("\n== roster -> chiave: il nome passa com'e' ==")
-- Verificato in gioco il 26/09: 120 membri, tutti "Nome Cognome", nessuno con
-- un trattino; il mittente dei messaggi addon arriva nudo in GUILD e WHISPER.
-- Non c'e' un suffisso di realm da togliere, e il nome non si tocca: un
-- trattino, se c'e', fa parte del nome.
t("nome e cognome", Data:MemberKeyFromFullName("Kaedros Davian"), "Kaedros Davian")
t("cognome col trattino", Data:MemberKeyFromFullName("Jean-Luc Picard"), "Jean-Luc Picard")
t("nome singolo", Data:MemberKeyFromFullName("Kaedros"), "Kaedros")
t("stringa vuota", Data:MemberKeyFromFullName(""), nil)
t("non stringa", Data:MemberKeyFromFullName(nil), nil)

print("\n== il nome del giocatore: nome e cognome ==")
-- UnitNameUnmodified da' nome e cognome separati. Leggere solo il primo --
-- come si faceva fino al 25/09 con UnitFullName -- dava "Kaedros", un
-- proprietario che il roster non conosce, sempre offline.
t("nome e cognome", Data:GetPlayerKey(), "Kaedros Davian")
t("coincide col roster", Data:MemberKeyFromFullName("Kaedros Davian"), Data:GetPlayerKey())
PLAYER_SURNAME = nil
t("senza cognome, il nome", Data:GetPlayerKey(), "Kaedros")
PLAYER_SURNAME = "Davian"

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
