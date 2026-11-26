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

-- Piu' provenienze per ricetta (26/11). Pattern: Blue Suede Armor cade da
-- Shadowsworn Thug ed e' premio di Leather Technique: le due righe si vedono
-- entrambe, ognuna col suo tipo, la principale per prima.
print("\n== piu' provenienze ==")
got = describe({ kind = "drop", places = { { name = "Shadowsworn Thug", zone = "Blasted Lands" } },
  also = { { kind = "quest", places = { { name = "Leather Technique", zone = "Desolace" } } } } })
t("kind resta la principale", got.kind, "drop")
t("due righe", #(got.lines or {}), 2)
t("prima riga: il drop", got.lines and got.lines[1], "Drop: Shadowsworn Thug (Blasted Lands)")
t("seconda riga: la quest", got.lines and got.lines[2], "Quest: Leather Technique (Desolace)")
t("tipo della prima riga", got.lineKinds and got.lineKinds[1], "drop")
t("tipo della seconda riga", got.lineKinds and got.lineKinds[2], "quest")
t("tutti i tipi, la principale per prima", table.concat(got.kinds or {}, ","), "drop,quest")
t("etichetta su una riga", got.label,
  "Drop: Shadowsworn Thug (Blasted Lands); Quest: Leather Technique (Desolace)")

-- Una principale senza luoghi (il trainer qualunque) e un venditore sotto: la
-- riga del trainer non ha lineInfo, quella del venditore si', al suo indice.
got = describe({ kind = "trainer",
  also = { { kind = "vendor", places = { { name = "Sovik", zone = "Orgrimmar", x = 75.6, y = 25.3, faction = "horde" } } } } })
t("trainer: prima riga", got.lines and got.lines[1], "From a trainer")
t("venditore: seconda riga", got.lines and got.lines[2], "Vendor: Sovik (Orgrimmar)")
t("niente lineInfo per il trainer", got.lineInfo and got.lineInfo[1], nil)
t("il venditore ha la sua x", got.lineInfo and got.lineInfo[2] and got.lineInfo[2].x, 75.6)
t("e la sua fazione", got.lineInfo and got.lineInfo[2] and got.lineInfo[2].faction, "horde")

-- Un world drop fra le altre ha il suo tipo, come da principale.
got = describe({ kind = "vendor", places = { { name = "Pratt McGrubben", zone = "Feralas" } },
  also = { { kind = "drop", worldDrop = true } } })
t("world drop sotto: tipo", got.lineKinds and got.lineKinds[2], "worldDrop")
t("world drop sotto: riga", got.lines and got.lines[2], "World drop")

-- Un secondo tipo uguale non diventa una seconda risposta alla stessa domanda.
got = describe({ kind = "vendor", places = { { name = "A", zone = "B" } },
  also = { { kind = "vendor", places = { { name = "C", zone = "D" } } } } })
t("tipo doppio scartato", #(got.lines or {}), 1)

-- Il Blueprint con un venditore sotto: il filtro lo trova sotto tutti e due.
got = describe({ kind = "blueprint", places = { { name = "Gilnid", zone = "The Deadmines" } },
  also = { { kind = "vendor", places = { { name = "Happy Camper" } } } } })
t("blueprint e vendor", table.concat(got.kinds or {}, ","), "blueprint,vendor")
t("riga del venditore", got.lines and got.lines[2], "Vendor: Happy Camper")

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
