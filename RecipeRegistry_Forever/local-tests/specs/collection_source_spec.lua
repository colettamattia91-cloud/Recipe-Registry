-- La scheda Collezione con una provenienza che non si conosce.
--
-- Data:DescribeRecipeSource risponde nil quando non sa da dove viene una
-- ricetta: su Forever e' il caso di quasi tutte quelle dei trainer, perche' la
-- provenienza non si indovina piu'. Chi costruisce le righe della Collezione
-- leggeva comunque source.lineInfo, source.faction e source.places, e un nil li'
-- e' un errore Lua su ogni ricetta senza provenienza: la scheda non si apriva.
--
-- Qui il descrittore e' uno stub: si vuole sapere cosa fa la Collezione con
-- le sue due risposte, non come ci arriva.

local modules = {}
_G.RecipeRegistry = setmetatable({
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
}, {__index = function() return function() end end})
local Addon = _G.RecipeRegistry
Addon.Data = {}
Addon.RecipeUiFilters = {
  NormalizeProfessionKey = function(_, name) return name:lower() end,
}

-- 2158 insegnata da un ricettario, 2149 da un trainer: provenienza ignota
local records = {
  [2158] = { spellId = 2158, requiredSkill = 1, recipeItemId = 2406 },
  [2149] = { spellId = 2149, requiredSkill = 1 },
}
Addon.RecipeMetadata = {
  BuildProfessionSpellIdHash = function() return { [2158] = true, [2149] = true } end,
  GetRecipeInfo = function(_, recipeKey) return records[-recipeKey] end,
  GetCreatedItemId = function() return nil end,
}

_G.UnitClass = function() return "Warrior", "WARRIOR" end
dofile("Data/DataCollection.lua")
local Data = Addon.Data

Data.IsRecipeKnownByCurrentPlayer = function() return false end
Data.DescribeRecipeSource = function(_, recipeKey)
  if recipeKey == -2158 then
    return { kind = "item", label = "Pattern: Fine Leather Boots",
             lines = { "Pattern: Fine Leather Boots" }, known = true, recipeItemId = 2406 }
  end
  return nil
end

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-46s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

local ok, rows = pcall(Data.BuildCollectionRowsForProfession, Data, "Leatherworking", { skillRank = 1 })
t("le righe si costruiscono", ok, true)
if not ok then print("     " .. tostring(rows)); rows = {} end

local byKey = {}
for _, row in ipairs(rows) do byKey[row.recipeKey] = row.collection end
t("una riga per ricetta", #rows, 2)

print("\n== ricetta da trainer: provenienza vuota, non indovinata ==")
local trainer = byKey[-2149] or {}
t("sourceKind", trainer.sourceKind, nil)
t("sourceLabel", trainer.sourceLabel, nil)
t("sourceLines", trainer.sourceLines, nil)
t("faction", trainer.faction, nil)

print("\n== ricetta da ricettario: il nome del Pattern ==")
local pattern = byKey[-2158] or {}
t("sourceKind", pattern.sourceKind, "item")
t("sourceLabel", pattern.sourceLabel, "Pattern: Fine Leather Boots")
t("sourceLines[1]", pattern.sourceLines and pattern.sourceLines[1], "Pattern: Fine Leather Boots")

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
