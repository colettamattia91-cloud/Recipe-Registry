-- La scansione su Forever.
--
-- I numeri e i link qui sotto non sono inventati: sono quelli che il client beta
-- 1.60.1.69913 ha risposto il 2026-09-18 con Alchemy a livello 1. Il punto che
-- questo spec difende e' uno solo, ed e' quello che su TBC non esisteva:
-- GetAllRecipeIDs restituisce il CATALOGO del mestiere -- 197 ricette -- e solo
-- 3 sono apprese. Senza il filtro su info.learned l'addon dichiarerebbe alla
-- gilda di saper fare tutta l'alchimia del gioco.

-- Niente __index acchiappa-tutto qui: un campo mancante deve restare nil, non
-- diventare una funzione. buildScannedRecipeKey interroga Addon.RecipeMetadata e
-- si aspetta nil quando non c'e'; un finto oggetto lo farebbe esplodere, e lo
-- ha fatto mentre scrivevo questo spec.
local modules = {}
local debugLines = {}
_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function(_, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    debugLines[#debugLines + 1] = table.concat(parts, " ")
  end,
  Print = function() end,
  RequestRefresh = function() end,
  Compat = setmetatable({}, { __index = function() return function() end end }),
}

_G.UnitFullName = function() return "Kaedros Davian", "ClassicBetaPvE2" end
_G.GetRealmName = function() return "Classic Beta PvE 2" end
_G.GetNumGuildMembers = function() return 0 end
-- il globale risponde false anche sulle ricette apprese: e' la funzione
-- sbagliata, e lo spec lo fissa perche' e' un errore facile da rifare
_G.IsSpellKnown = function() return false end
-- quello che invece sa rispondere
local knownRecipes = { [7183] = true, [1245250] = true, [1245246] = true }
_G.C_SpellBook = { IsSpellKnown = function(id) return knownRecipes[id] == true end }
_G.GetProfessions = function() return 6 end
_G.GetProfessionInfo = function() return "Alchemy", nil, 1, 75, nil, nil, 171 end
-- in WoW time() e' un globale; qui no
_G.time = os.time
_G.GetTime = os.clock

-- Le tre apprese sono le vere ricette iniziali del personaggio di prova. Due su
-- tre sono contenuto Forever: item 247754 e 247755 stanno fuori da qualunque
-- intervallo vanilla, e sono la ragione per cui la scansione deve leggere il
-- client invece di fidarsi del dataset.
local RECIPES = {
  [7183]    = { learned = true,  name = "Elixir of Minor Defense", item = 5997 },
  [1245250] = { learned = true,  name = "Elixir of Minor Force",   item = 247755 },
  [1245246] = { learned = true,  name = "Minor Arcane Elixir",     item = 247754 },
  [1263078] = { learned = false, name = "Alchemy Laboratory",      item = 279990 },
  [22430]   = { learned = false, name = "Refined Scale of Onyxia", item = 17967 },
  [11473]   = { learned = false, name = "Ghost Dye",               item = 9210 },
}
local ORDER = { 1263078, 22430, 11473, 7183, 1245250, 1245246 }

local baseProfessionName = ""   -- come risponde a finestra chiusa: vuoto
local sessionReady = true
local linked = false
_G.C_TradeSkillUI = {
  GetAllRecipeIDs = function() return ORDER end,
  GetRecipeInfo = function(id)
    local r = RECIPES[id]
    if not r then return nil end
    return { recipeID = id, name = r.name, learned = r.learned, categoryID = 2450 }
  end,
  GetRecipeItemLink = function(id)
    local r = RECIPES[id]
    return r and ("|cnIQ1:|Hitem:" .. r.item .. "::::::::6:1487:::1:3524::::::|h[" .. r.name .. "]|h|r")
  end,
  GetRecipeLink = function(id)
    local r = RECIPES[id]
    return r and ("|cffffd000|Henchant:" .. id .. "|h[Alchemy: " .. r.name .. "]|h|r")
  end,
  -- true solo mentre una sessione mestiere e' aperta: e' il cancello che
  -- impedisce di registrare il catalogo rimasto dall'ultima volta
  IsTradeSkillReady = function() return sessionReady end,
  -- la finestra aperta potrebbe essere quella di un compagno
  IsTradeSkillLinked = function() return linked end,
  -- rispondono per un ID qualunque, anche di un mestiere non posseduto:
  -- verificato in gioco il 2026-09-18
  GetProfessionInfoByRecipeID = function()
    return { professionName = "Alchemy", parentProfessionName = "Alchemy" }
  end,
  IsTradeSkillGuild = function() return false end,
  IsNPCCrafting = function() return false end,
  GetBaseProfessionInfo = function() return { professionName = baseProfessionName } end,
  -- risponde anche quando GetBaseProfessionInfo tace: e' la seconda strada
  GetProfessionInfoByRecipeID = function()
    return { professionName = "Alchemy", parentProfessionName = "Alchemy", parentProfessionID = 171 }
  end,
}

dofile("Data/Data.lua")
dofile("Data/DataScan.lua")
local Data = _G.RecipeRegistry.Data or modules["Data"]

-- il minimo che ApplyScanResult si aspetta di trovare: qui non girano ne' AceDB
-- ne' OnInitialize
Data.db = { global = { members = {}, options = {} } }
Data._currentProfs = {}
_G.RecipeRegistry.charDB = { favorites = {} }

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-52s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

print("== il mestiere attivo, anche quando il client non lo dice ==")
baseProfessionName = ""
t("da GetProfessionInfoByRecipeID", Data:GetActiveTradeSkillProfession(), "Alchemy")
baseProfessionName = "Alchemy"
t("da GetBaseProfessionInfo", Data:GetActiveTradeSkillProfession(), "Alchemy")

print("\n== il cancello ==")
local canScan, reason, canonical, ids = Data:CanScanTradeSkillData()
t("puo' scansionare", canScan, true)
t("motivo", reason, nil)
t("mestiere", canonical, "Alchemy")
t("catalogo", type(ids) == "table" and #ids or nil, 6)

print("\n== la scansione tiene solo le apprese ==")
local result = Data:ScanTradeSkill({ reason = "test", notifyMode = "auto" })
-- quando fallisce, il perche' e' passato dal canale di debug: stamparlo li'
-- evita di doverlo andare a cercare
if not (result and result.valid) then
  for _, line in ipairs(debugLines) do print("   [debug] " .. line) end
end
local entry = Data:GetOrCreateMember(Data:GetPlayerKey())
local prof = entry.professions["Alchemy"]
t("scansione valida", result and result.valid, true)
t("ricette registrate", prof and prof.count, 3)

local keys = {}
for k in pairs(prof and prof.recipes or {}) do keys[#keys + 1] = k end
table.sort(keys)
t("le chiavi sono gli itemID delle apprese", table.concat(keys, ","), "5997,247754,247755")

print("\n== a sessione chiusa non si scansiona ==")
-- il catalogo risponde lo stesso, ma e' il residuo dell'ultimo mestiere aperto:
-- registrarlo pubblicherebbe alla gilda uno stato vecchio senza un errore
sessionReady = false
local canScanClosed, closedReason = Data:CanScanTradeSkillData()
t("cancello chiuso", canScanClosed, false)
t("motivo", closedReason, "trade-session-closed")
local closedResult = Data:ScanTradeSkill({ reason = "test", notifyMode = "auto" })
t("scansione saltata", closedResult and closedResult.skipped, true)
t("le ricette registrate restano quelle di prima", prof and prof.count, 3)
sessionReady = true

print("\n== il contesto non guarda piu' i frame ==")
-- ProfessionsFrame non esiste finche' l'utente non apre un mestiere: chiederne
-- l'esistenza direbbe "nessun mestiere" mentre la lista risponde benissimo
_G.ProfessionsFrame, _G.TradeSkillFrame = nil, nil
local ctxProf, ctxKind = Data:GetVisibleTrackedProfessionContext()
t("mestiere dal contesto", ctxProf, "Alchemy")
t("tipo di contesto", ctxKind, "trade")

print("\n== chi cambia mestiere non resta due mestieri ==")
-- il personaggio aveva Alchemy; adesso GetProfessions dice Engineering
_G.GetProfessionInfo = function() return "Engineering", nil, 1, 75, nil, nil, 202 end
Data:DetectProfessions()
t("Alchemy rimossa dal blocco", entry.professions["Alchemy"], nil)
t("Engineering al suo posto", entry.professions["Engineering"] ~= nil, true)

print("\n== la finestra di un altro non e' la tua ==")
-- cliccando un mestiere linkato in chat si apre la finestra con le ricette di
-- chi l'ha linkato: identica da fuori, e registrarla pubblicherebbe alla gilda
-- ricette altrui a nome tuo
linked = true
local linkedOk, linkedReason = Data:CanScanTradeSkillData()
t("cancello chiuso", linkedOk, false)
t("motivo", linkedReason, "trade-linked")
linked = false

print("\n== una ricetta imparata si risolve senza finestra ==")
-- e' il caso del dungeon: impari, e deve finire nel database da li', senza
-- aprire il mestiere e senza aspettare un reload
-- (la sezione precedente aveva cambiato mestiere: qui si torna ad Alchemy)
_G.GetProfessionInfo = function() return "Alchemy", nil, 1, 75, nil, nil, 171 end
Data:DetectProfessions()
sessionReady = false
local before = entry.professions["Alchemy"].count
knownRecipes[1263078] = true   -- Alchemy Laboratory, prima non appresa
-- una lista gia' costruita, come quella che la UI ha in mano
Data._recipeListCache = { stale = true }
local ok, why, prof, key = Data:LearnRecipeFromSignal(1263078, "test")
t("risolta", ok, true)
t("nel mestiere giusto", prof, "Alchemy")
t("con la chiave dell'oggetto prodotto", key, 279990)
t("e il conteggio cresce di uno", entry.professions["Alchemy"].count, before + 1)
-- visto in gioco il 25/09: ricetta scritta, addon fermo alla lista di prima
t("e la lista in cache se ne va", Data._recipeListCache, nil)

t("la seconda volta non ricresce", select(2, Data:LearnRecipeFromSignal(1263078, "test")), "already-known")
-- l'oracolo e' la conferma: un evento su una ricetta che non sai non scrive
knownRecipes[22430] = nil
t("evento spurio rifiutato", select(2, Data:LearnRecipeFromSignal(22430, "test")), "not-known")

-- Senza oracolo non si scrive. Scritta com'era, la conferma saltava sia con
-- l'API assente sia con la pcall fallita, e in entrambi i casi un evento
-- bastava a pubblicare alla gilda una ricetta che non hai.
local savedSpellBook = _G.C_SpellBook
local countBefore = entry.professions["Alchemy"].count

_G.C_SpellBook = nil
t("senza C_SpellBook si rinuncia", select(2, Data:LearnRecipeFromSignal(1245246, "test")), "spellbook-api-missing")

_G.C_SpellBook = { IsSpellKnown = function() error("boom") end }
t("se l'oracolo esplode si rinuncia", select(2, Data:LearnRecipeFromSignal(1245246, "test")), "spellbook-error")

t("e in nessuno dei due casi ha scritto", entry.professions["Alchemy"].count, countBefore)
_G.C_SpellBook = savedSpellBook
sessionReady = true

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
