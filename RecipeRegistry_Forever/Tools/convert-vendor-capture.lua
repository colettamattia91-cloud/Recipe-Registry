-- Le catture dei venditori fatte in gioco -> un file di captures/.
--
-- `/rrdump vendor` scrive in RecipeRegistryDumpDB.vendors chi vende cosa, con
-- zona, sottozona, coordinate e fazione. Questo le traduce nella forma che
-- build-acquisition-worksheet.py legge.
--
-- E' la fonte migliore che abbiamo, e va sopra tutte le altre: il sito dava
-- Archmage Alvareaux in "Alterac Mountains" -- la Dalaran di vanilla, dato
-- Wowhead vecchio -- mentre in gioco sta in City of Dalaran, The Silver
-- Enclave, a 14 63.1. Uno e' un ricordo, l'altro e' dove devi andare.
--
-- Ogni cattura produce un file suo con la data, e il costruttore del worksheet
-- li legge tutti: il DB del Collector si azzera a ogni reload, e una sessione
-- non deve poter cancellare quelle prima.
--
--   lua Tools/convert-vendor-capture.lua <SavedVariables/RecipeRegistry_Forever_Collector.lua> [output.tsv]

local input = arg and arg[1]
local output = (arg and arg[2])
if not input then
    io.stderr:write("uso: lua Tools/convert-vendor-capture.lua <SavedVariables del Collector> [output.tsv]\n")
    os.exit(2)
end

local env = {}
local chunk, err = loadfile(input)
if not chunk then io.stderr:write("SavedVariables illeggibili: " .. tostring(err) .. "\n") os.exit(1) end
setfenv(chunk, env)
chunk()

local vendors = (env.RecipeRegistryDumpDB or {}).vendors
if type(vendors) ~= "table" or not next(vendors) then
    io.stderr:write("nessun venditore nella cattura: apri il venditore e lancia /rrdump vendor, poi /reload.\n")
    os.exit(1)
end

if not output then
    -- Il nome porta la data della cattura piu' recente, non quella di oggi:
    -- riconvertire lo stesso file due volte deve dare lo stesso nome.
    local stamp
    for _, entry in pairs(vendors) do
        local at = tostring(entry.at or ""):gsub("[^%d]", "")
        if at ~= "" and (not stamp or at > stamp) then stamp = at end
    end
    output = "Tools/captures/ingame-vendors-" .. (stamp and stamp:sub(1, 8) or "senzadata") .. ".tsv"
end

local COLS = { "recipeItemId", "itemName", "sourceKind", "npcName", "zone", "x", "y", "faction" }
local rows, npcCount, itemCount, unread = {}, 0, 0, 0

for _, entry in pairs(vendors) do
    npcCount = npcCount + 1
    -- La zona utile e' la sottozona quando c'e': "The Silver Enclave" dice
    -- dove sei, "City of Dalaran" dice solo in che citta'.
    local zone = entry.zone or ""
    if entry.subZone and entry.subZone ~= "" and entry.subZone ~= zone then
        zone = entry.subZone .. ", " .. zone
    end
    local faction = tostring(entry.faction or ""):lower()
    for _, item in ipairs(entry.items or {}) do
        if item.itemID then
            itemCount = itemCount + 1
            rows[#rows + 1] = {
                recipeItemId = item.itemID,
                itemName = tostring(item.name or ""),
                sourceKind = "vendor",
                npcName = tostring(entry.name or ""),
                zone = zone,
                x = entry.x and string.format("%.1f", entry.x) or "",
                y = entry.y and string.format("%.1f", entry.y) or "",
                faction = faction,
            }
        else
            unread = unread + 1
        end
    end
end

table.sort(rows, function(a, b)
    if a.recipeItemId ~= b.recipeItemId then return a.recipeItemId < b.recipeItemId end
    return a.npcName < b.npcName
end)

local file = assert(io.open(output, "w"))
file:write(table.concat(COLS, "\t") .. "\n")
for _, row in ipairs(rows) do
    local fields = {}
    for index, name in ipairs(COLS) do fields[index] = tostring(row[name]) end
    file:write(table.concat(fields, "\t") .. "\n")
end
file:close()

print(string.format("%d venditori, %d oggetti -> %s", npcCount, itemCount, output))
if unread > 0 then
    print(string.format("ATTENZIONE: %d slot non risolti dal client, non sono nel file. Sfoglia tutte le pagine del venditore e ricattura.", unread))
end
