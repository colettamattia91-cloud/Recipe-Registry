-- L'ordine delle righe della scheda Recipes.
--
-- Tre modalita', una funzione sola per la lista, la sua versione a passi e i
-- preferiti: prima erano tre copie dello stesso confronto. Il caso nuovo e'
-- "skill", il livello a cui si impara. Una ricetta di cui nessuna fonte sa il
-- livello va in fondo, non in testa: trattarla come livello 0 la metterebbe
-- prima di tutte, ed e' proprio l'ordine sbagliato che il dataset vecchio,
-- con 1 su ogni ricetta, dava.

local Addon = { Compat = setmetatable({}, { __index = function() return function() end end }) }
_G.RecipeRegistry = Addon
Addon.Data = {
  _private = {
    lowerSafe = function(v) return string.lower(tostring(v or "")) end,
  },
}
dofile("Data/DataCatalog.lua")
local Data = Addon.Data

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-46s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

local function row(label, minRank, quality)
  return { label = label, recipeKey = label, detail = { minRank = minRank, createdItemQuality = quality } }
end

local function sorted(mode)
  local rows = {
    row("Bolt of Silk Cloth", 125, 1),
    row("Brown Linen Vest", 10, 1),
    row("Ninja Rope", nil, 1),
    row("Azure Silk Hood", 145, 2),
    row("Admiral's Hat", nil, 3),
  }
  table.sort(rows, function(a, b) return Data:CompareRecipeRows(a, b, mode) end)
  local labels = {}
  for i, r in ipairs(rows) do labels[i] = r.label end
  return table.concat(labels, ", ")
end

print("== alpha ==")
t("per nome", sorted("alpha"),
  "Admiral's Hat, Azure Silk Hood, Bolt of Silk Cloth, Brown Linen Vest, Ninja Rope")

print("\n== rarity ==")
t("qualita' prima, poi nome", sorted("rarity"),
  "Admiral's Hat, Azure Silk Hood, Bolt of Silk Cloth, Brown Linen Vest, Ninja Rope")

print("\n== skill ==")
t("livello crescente, i senza livello in fondo", sorted("skill"),
  "Brown Linen Vest, Bolt of Silk Cloth, Azure Silk Hood, Admiral's Hat, Ninja Rope")

print("\n== skill, dal piu' alto ==")
t("livello decrescente, i senza livello sempre in fondo", sorted("skilldesc"),
  "Azure Silk Hood, Bolt of Silk Cloth, Brown Linen Vest, Admiral's Hat, Ninja Rope")

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
