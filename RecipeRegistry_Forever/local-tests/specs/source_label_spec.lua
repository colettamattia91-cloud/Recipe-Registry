-- La riga "Learned from" dei Blueprint.
--
-- I Blueprint sono le ricette da campo di Forever, e il filtro "Blueprint"
-- della Collezione legge il kind che il descrittore restituisce. Fino al 18/11
-- il tipo veniva dal testo di una fonte, che lo dava anche a idol e libram di
-- Enchanting; ora lo mette il builder dalla categoria "Camping" del client, e
-- porta con se' il trainer, il boss o il venditore quando si conoscono. Qui si fissa che cosa
-- ne fa il descrittore: il kind resta "blueprint" anche con un luogo, e il
-- luogo si vede.

local Addon = { Compat = setmetatable({}, { __index = function() return function() end end }) }
_G.RecipeRegistry = Addon
Addon.Data = {
  _private = {
    lowerSafe = function(v) return string.lower(tostring(v or "")) end,
  },
}
dofile("Data/DataCatalog.lua")
local Data = Addon.Data

local sources = {}
Addon.RecipeMetadata = {
  GetRecipeInfo = function(_, recipeKey) return { recipeKey = recipeKey } end,
  GetSource = function(_, recipeKey) return sources[recipeKey] end,
}

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-52s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

local function describe(source)
  sources[1] = source
  return Data:DescribeRecipeSource(1) or {}
end

print("== Blueprint ==")
local got = describe({ kind = "blueprint",
  places = { { name = "Gilnid", zone = "The Deadmines" } } })
t("con il boss: kind", got.kind, "blueprint")
t("con il boss: etichetta", got.label, "Blueprint: Gilnid (The Deadmines)")

got = describe({ kind = "blueprint" })
t("senza luogo: kind", got.kind, "blueprint")
t("senza luogo: etichetta", got.label, "Blueprint")

got = describe({ kind = "blueprint", places = { { zone = "Durotar" } } })
t("solo la zona", got.label, "Blueprint in Durotar")

-- Una fonte che lo segnasse world drop non lo toglie dal filtro.
got = describe({ kind = "blueprint", worldDrop = true })
t("world drop resta blueprint", got.kind, "blueprint")

print("\n== gli altri tipi non cambiano ==")
got = describe({ kind = "drop", places = { { name = "Gilnid", zone = "The Deadmines" } } })
t("drop", got.label, "Drop: Gilnid (The Deadmines)")
got = describe({ kind = "vendor", places = { { name = "Alynsia", zone = "Redridge Mountains" } } })
t("vendor", got.label, "Vendor: Alynsia (Redridge Mountains)")
got = describe({ kind = "drop", worldDrop = true })
t("world drop", got.kind, "worldDrop")

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
