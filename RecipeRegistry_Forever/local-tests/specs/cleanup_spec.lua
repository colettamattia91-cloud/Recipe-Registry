-- La pulizia automatica e il dataset vuoto.
--
-- Questo spec esiste per un bug preciso, trovato in gioco il 2026-09-18: la
-- scansione registrava correttamente le tre ricette di Alchemy, e otto secondi
-- dopo il login sparivano tutte. Nessun errore, nessun messaggio -- solo
-- invalidRecipesBlocked=3 nella telemetria.
--
-- La causa: l'auto-clean cancella le chiavi che il dataset dei metadati non
-- conosce, fidandosi del fatto che quella guardia "si astiene quando i metadati
-- non sono ancora caricati". Su Forever il dataset E' caricato, ed e' il
-- segnaposto vuoto. "Non ancora pronto" e "pronto e vuoto" non erano la stessa
-- cosa, e la differenza cancellava tutto.

local modules = {}
_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function() end, Print = function() end, SystemPrint = function() end,
  RequestRefresh = function() end,
  -- il client conosce gli oggetti veri: senza questo l'ultimo cancello,
  -- IsRecipeKeyResolvableInClient, nasconderebbe tutto per finta
  Compat = setmetatable({
    GetItemInfoInstant = function(id) return id end,
    GetItemInfo = function(id) return "item " .. tostring(id) end,
    GetSpellInfo = function(id) return "spell " .. tostring(id) end,
  }, { __index = function() return function() end end }),
}

_G.UnitFullName = function() return "Kaedros Davian", "ClassicBetaPvE2" end
_G.GetRealmName = function() return "Classic Beta PvE 2" end
_G.GetNumGuildMembers = function() return 0 end
_G.time = os.time
_G.GetTime = os.clock

dofile("Data/Data.lua")
dofile("Data/DataScan.lua")
dofile("Data/RecipeUiFilters.lua")
dofile("Data/DataCleanup.lua")
local Data = _G.RecipeRegistry.Data or modules["Data"]
local Filters = _G.RecipeRegistry.RecipeUiFilters or modules["RecipeUiFilters"]
_G.RecipeRegistry.Data = Data
_G.RecipeRegistry.RecipeUiFilters = Filters
_G.RecipeRegistry.Trace = function() end
Data.db = { global = { members = {}, options = {} } }

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-54s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

-- una delle tre vere: Elixir of Minor Force, contenuto aggiunto da Forever
local FOREVER_RECIPE = 247755
local opts = { checkMetadataCatalogued = true, checkProfessionMismatches = false }

print("== dataset assente: nessuna opinione ==")
_G.RecipeRegistry.RecipeMetadata = nil
t("la ricetta resta", Data:ShouldCleanRecipeFromProfession("Alchemy", FOREVER_RECIPE, opts), false)

print("\n== dataset caricato ma vuoto: nemmeno ==")
-- e' il segnaposto di Forever: metadataVersion c'e', contenuto no
_G.RecipeRegistry.RecipeMetadata = {
  metadataVersion = "forever-pending",
  _recordsBySpellId = {},
  _generated = { recipeItemToSpellId = {}, createdItemToSpellIds = {} },
}
t("la ricetta resta", Data:ShouldCleanRecipeFromProfession("Alchemy", FOREVER_RECIPE, opts), false)
t("e l'accessore pubblico concorda", Data:IsRecipeKeyCatalogued(FOREVER_RECIPE), true)

print("\n== dataset pieno che non la conosce: quella si' ==")
-- qui il giudizio e' informato, e serve: e' il caso per cui la guardia esiste,
-- oggetti veri che non sono ricette e che un client vecchio aveva salvato
_G.RecipeRegistry.RecipeMetadata = {
  metadataVersion = "forever-1",
  _recordsBySpellId = { [7183] = { profession = "alchemy" } },
  _generated = {
    recipeItemToSpellId = { [5997] = 7183 },
    createdItemToSpellIds = {},
    -- serve a MetadataKnowsProfession: e' da qui che si sa quali mestieri
    -- il dataset copre davvero
    recipesBySpellId = { [7183] = { profession = "alchemy" } },
  },
}
Data._metadataProfessions = nil
t("la sconosciuta va via", Data:ShouldCleanRecipeFromProfession("Alchemy", FOREVER_RECIPE, opts), true)
t("quella catalogata resta", Data:ShouldCleanRecipeFromProfession("Alchemy", 5997, opts), false)

print("\n== e lo stesso vale per il filtro della UI ==")
-- hideUncataloguedRecipes nasconde le chiavi-oggetto che il dataset non
-- conosce. Con il segnaposto vuoto le nasconderebbe tutte, perche' ogni
-- ricetta scansionata e' una chiave-oggetto positiva.
Data.db.profile = { recipePrefilters = { hideUncataloguedRecipes = true,
  expansionDefaults = { vanilla = true, tbc = true }, professionExpansionOverrides = {} } }
_G.RecipeRegistry.RecipeMetadata = {
  metadataVersion = "forever-pending",
  _recordsBySpellId = {}, _generated = { recipeItemToSpellId = {}, createdItemToSpellIds = {} },
  -- vuoto vuol dire che non sa niente di nessuna ricetta: e' il segnaposto
  GetRecipeInfo = function() return nil end,
  GetMetadataResolutionStatus = function() return "unresolved" end,
}
local visible, why = Filters:RecipePasses(FOREVER_RECIPE, nil, nil)
t("con dataset vuoto la ricetta si vede", visible, true)
t("e non per la via del nascondi-non-catalogate", why ~= "hidden-uncatalogued", true)
t("passa dalla via conservativa", why, "visible-unresolved-conservative")

print("\n== un dataset parziale giudica solo cio' che copre ==")
-- e' lo stato normale di un dataset raccolto in gioco: si riempie un mestiere
-- per volta. Il primo dump di Alchemy non deve far cancellare Cooking.
_G.RecipeRegistry.RecipeMetadata = {
  metadataVersion = "forever-ingame-1.60.1.69913",
  _recordsBySpellId = { [7183] = { profession = "alchemy" } },
  _generated = {
    recipeItemToSpellId = { [5997] = 7183 }, createdItemToSpellIds = {},
    recipesBySpellId = { [7183] = { profession = "alchemy" } },
  },
  GetRecipeInfo = function() return nil end,
  GetMetadataResolutionStatus = function() return "unresolved" end,
}
Data._metadataProfessions = nil
t("il dataset sa di alchemy", Data:MetadataKnowsProfession("alchemy"), true)
t("e non sa niente di cooking", Data:MetadataKnowsProfession("cooking"), false)
t("una ricetta di alchemy che non conosce va via",
  Data:ShouldCleanRecipeFromProfession("Alchemy", FOREVER_RECIPE, opts), true)
t("una di cooking resta",
  Data:ShouldCleanRecipeFromProfession("Cooking", FOREVER_RECIPE, opts), false)

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
