-- La provenienza delle ricette vanilla, presa dal dataset TBC.
--
-- Le ricette che Forever eredita da vanilla hanno lo stesso spellId di quelle
-- dell'albero TBC, e li' la provenienza c'e' gia': chi le vende, chi le
-- droppa, quale trainer le insegna, con NPC, zona e coordinate risolte da
-- anni di lavoro su cmangos. Copiare quel dato e' leggere una fonte, non
-- dedurre: se lo spell e' lo stesso, la ricetta e' la stessa.
--
-- Cio' che Forever ha aggiunto non e' qui e non deve esserci: quelle ricette
-- non esistono in TBC, e restano senza provenienza finche' non la si
-- raccoglie.
--
-- Scrive anche, a parte, il livello a cui la ricetta si impara. Il client di
-- Forever non lo porta per le ricette dei trainer: SkillLineAbility dice 1 su
-- quasi tutte, perche' il livello che il trainer chiede e' dato del server. Il
-- dataset TBC lo ha, verificato. Forever potrebbe aver spostato qualche
-- requisito, ma e' improbabile, e un valore vanilla e' meglio di un 1 che
-- dice il falso. File separato perche' non e' provenienza, e perche'
-- build-acquisition-worksheet.py prende ogni riga di tbc-vanilla.tsv come una
-- provenienza trovata.
--
--   lua Tools/extract-tbc-acquisition.lua ../RecipeRegistry/Data/Metadata/RecipeMetadata_Generated.lua Tools/captures/tbc-vanilla.tsv Tools/captures/tbc-vanilla-skill.tsv

local tbcPath = arg and arg[1]
local outPath = (arg and arg[2]) or "Tools/captures/tbc-vanilla.tsv"
local skillPath = (arg and arg[3]) or "Tools/captures/tbc-vanilla-skill.tsv"
if not tbcPath then
    io.stderr:write("uso: lua Tools/extract-tbc-acquisition.lua <RecipeMetadata_Generated.lua del TBC> [output.tsv]\n")
    os.exit(2)
end

local env = {}
local chunk, err = loadfile(tbcPath)
if not chunk then io.stderr:write("dataset TBC illeggibile: " .. tostring(err) .. "\n") os.exit(1) end
setfenv(chunk, env)
chunk()

local tbc = env.RecipeRegistryRecipeMetadata
if type(tbc) ~= "table" or type(tbc.recipesBySpellId) ~= "table" then
    io.stderr:write("il file non contiene RecipeRegistryRecipeMetadata.recipesBySpellId\n")
    os.exit(1)
end
local zones = tbc.zoneNamesById or {}

local rows, counts = {}, {}
for spellId, record in pairs(tbc.recipesBySpellId) do
    if record.sourceKind then
        -- Le chiavi del dataset TBC possono essere negative (una ricetta senza
        -- oggetto prodotto si indicizza su -spellId). Qui serve lo spell nudo,
        -- perche' e' con quello che il dataset Forever indicizza.
        local id = math.abs(tonumber(spellId) or 0)
        local names, zoneNames, factions = {}, {}, {}
        for _, place in ipairs(record.sourcePlaces or {}) do
            names[#names + 1] = place.name or ""
            zoneNames[#zoneNames + 1] = (place.zone and zones[place.zone]) or ""
            factions[#factions + 1] = place.faction or ""
        end
        local function join(list)
            local any = false
            for _, value in ipairs(list) do if value ~= "" then any = true end end
            if not any then return "" end
            return table.concat(list, " | ")
        end
        rows[#rows + 1] = {
            spellId = id,
            sourceKind = record.sourceKind,
            npcName = join(names),
            zone = join(zoneNames),
            faction = join(factions),
            bossDrop = record.bossDrop and "true" or "",
            worldDrop = record.worldDrop and "true" or "",
            trainerTitle = record.trainerTitle or "",
        }
        counts[record.sourceKind] = (counts[record.sourceKind] or 0) + 1
    end
end

table.sort(rows, function(a, b) return a.spellId < b.spellId end)

local COLS = { "spellId", "sourceKind", "npcName", "zone", "faction",
               "bossDrop", "worldDrop", "trainerTitle" }
local file = assert(io.open(outPath, "w"))
file:write(table.concat(COLS, "\t") .. "\n")
for _, row in ipairs(rows) do
    local fields = {}
    for index, name in ipairs(COLS) do fields[index] = tostring(row[name]) end
    file:write(table.concat(fields, "\t") .. "\n")
end
file:close()

print(string.format("scritte %d righe -> %s", #rows, outPath))

local skills = {}
for spellId, record in pairs(tbc.recipesBySpellId) do
    local skill = tonumber(record.requiredSkill)
    if skill and skill > 0 then
        skills[#skills + 1] = { spellId = math.abs(tonumber(spellId) or 0), requiredSkill = skill }
    end
end
table.sort(skills, function(a, b) return a.spellId < b.spellId end)
local skillFile = assert(io.open(skillPath, "w"))
skillFile:write("spellId\trequiredSkill\n")
for _, row in ipairs(skills) do
    skillFile:write(string.format("%d\t%d\n", row.spellId, row.requiredSkill))
end
skillFile:close()
print(string.format("scritti %d livelli -> %s", #skills, skillPath))
local kinds = {}
for kind in pairs(counts) do kinds[#kinds + 1] = kind end
table.sort(kinds)
for _, kind in ipairs(kinds) do print(string.format("   %-12s %d", kind, counts[kind])) end
