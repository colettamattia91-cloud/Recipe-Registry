-- Il database delle ricette in memoria: i record sono quelli del file generato.
--
-- Fino al 14/11 RecipeMetadata:_Rebuild copiava ogni record e rifaceva gli
-- indici per oggetto: 5 MB in piu' sui 3,6 del file, per un dato statico che
-- nessuno modifica. Ora si usano i record del file, e una ricetta riceve una
-- copia sua solo se una correzione a mano la tocca -- cosi' il file resta
-- com'e' anche quando _Rebuild gira di nuovo con correzioni diverse.
--
-- Lo spec carica il file generato vero.

_G.RecipeRegistry = {}
dofile("Data/Metadata/RecipeMetadata_Generated.lua")
dofile("Data/Metadata/RecipeMetadata_Overrides.lua")

local function kb()
  collectgarbage("collect"); collectgarbage("collect")
  return collectgarbage("count")
end
local before = kb()
dofile("Data/Metadata/RecipeMetadata.lua")
local added = kb() - before

local M = RecipeRegistry.RecipeMetadata
local generated = RecipeRegistryRecipeMetadata
local emptyOverrides = RecipeRegistryRecipeMetadataOverrides

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-66s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

-- una ricetta con oggetto-ricetta e oggetto prodotto, e l'oggetto prodotto
-- fatto da lei sola
local spellId, sample
for id, record in pairs(generated.recipesBySpellId) do
  local created = record.createdItemId and generated.createdItemToSpellIds[record.createdItemId]
  if record.recipeItemId and created and #created == 1 and (not spellId or id < spellId) then
    spellId, sample = id, record
  end
end

print("== senza correzioni ==")
t("il record e' quello del file, non una copia", M:GetRecipeInfo(-spellId) == sample, true)
t("con il suo spellId", sample.spellId, spellId)
t("trovato dall'oggetto-ricetta", M:GetRecipeInfo(sample.recipeItemId) == sample, true)
t("trovato dall'oggetto prodotto", M:GetRecipeInfo(sample.createdItemId) == sample, true)
t("indice per oggetto-ricetta: quello del file", M._recipeItemToSpellId == generated.recipeItemToSpellId, true)
t("indice per oggetto prodotto: quello del file", M._createdItemToSpellIds == generated.createdItemToSpellIds, true)
-- 187 KB misurati il 14/11 (lo spellId aggiunto ai record); la copia di
-- prima ne aggiungeva 5000
t("_Rebuild aggiunge meno di 1 MB al file caricato", added < 1024, true)

print("\n== una correzione a mano ==")
local originalItem, originalCategory = sample.recipeItemId, sample.category
_G.RecipeRegistryRecipeMetadataOverrides = {
  recipeItemBySpellId = { [spellId] = 999001 },
  categoryBySpellId = { [spellId] = { category = "c-prova", sortOrder = 1 } },
}
M:_Rebuild()
local fixed = M:GetRecipeInfo(-spellId)
t("la ricetta corretta e' una copia", fixed ~= sample, true)
t("con la correzione", fixed.recipeItemId, 999001)
t("e la categoria corretta", fixed.category, "c-prova")
t("il file generato non cambia", sample.recipeItemId, originalItem)
t("nemmeno la categoria", sample.category, originalCategory)
t("gli indici si rifanno: il nuovo oggetto trova la ricetta", M:GetRecipeInfo(999001) == fixed, true)
t("e il vecchio non piu'", M:GetRecipeInfo(originalItem), nil)
t("gli indici non sono quelli del file", M._recipeItemToSpellId ~= generated.recipeItemToSpellId, true)
t("il file conserva il suo indice", generated.recipeItemToSpellId[originalItem], spellId)
local other = next(generated.recipesBySpellId)
if other == spellId then other = next(generated.recipesBySpellId, other) end
t("le altre ricette restano quelle del file", M:GetRecipeInfo(-other) == generated.recipesBySpellId[other], true)

print("\n== una correzione per oggetto prodotto ==")
_G.RecipeRegistryRecipeMetadataOverrides = {
  bindTypeByCreatedItemId = { [sample.createdItemId] = sample.bopOutput and 0 or 1 },
}
M:_Rebuild()
local bound = M:GetRecipeInfo(-spellId)
t("anche questa da' una copia", bound ~= sample, true)
t("con il legame corretto", bound.bopOutput, not sample.bopOutput)
t("indici di nuovo quelli del file: l'oggetto non cambia", M._recipeItemToSpellId == generated.recipeItemToSpellId, true)

print("\n== tolte le correzioni ==")
_G.RecipeRegistryRecipeMetadataOverrides = emptyOverrides
M:_Rebuild()
t("torna il record del file", M:GetRecipeInfo(-spellId) == sample, true)
t("con l'oggetto di sempre", M:GetRecipeInfo(originalItem) == sample, true)

-- Piu' provenienze (26/11), sul file vero: Pattern: Blue Suede Armor cade da
-- Shadowsworn Thug ed e' premio di Leather Technique. GetSource da' la
-- principale nei campi di sempre e le altre in `also`, con le zone risolte.
print("\n== piu' provenienze ==")
local blueSuede = M:GetSource(-1255024)
t("principale: drop", blueSuede and blueSuede.kind, "drop")
local quest = blueSuede and blueSuede.also and blueSuede.also[1]
t("poi la quest", quest and quest.kind, "quest")
t("col suo nome", quest and quest.places and quest.places[1].name, "Leather Technique")
t("e la zona per nome, non per id", quest and quest.places and quest.places[1].zone, "Desolace")
local single = 0
for id, record in pairs(generated.recipesBySpellId) do
  if record.sourceKind and not record.alsoSources then single = id; break end
end
local one = M:GetSource(-single)
t("una ricetta con una provenienza sola non ha also", one and one.also, nil)

print("\n== dati senza indici, come i dati finti ==")
_G.RecipeRegistryRecipeMetadata = {
  recipesBySpellId = {
    [101] = { profession = "alchemy", recipeItemId = 501, createdItemId = 601 },
    [102] = { profession = "engineering", createdItemId = 601 },
  },
}
M:_Rebuild()
t("gli indici si costruiscono", M._recipeItemToSpellId[501], 101)
t("anche per oggetto prodotto, in ordine", table.concat(M._createdItemToSpellIds[601], ","), "101,102")
t("un oggetto ambiguo non sceglie da solo", M:GetRecipeInfo(601), nil)
local hinted = M:GetRecipeInfo(601, "engineering")
t("ma con il mestiere si'", hinted and hinted.spellId, 102)
_G.RecipeRegistryRecipeMetadata = generated
M:_Rebuild()

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
