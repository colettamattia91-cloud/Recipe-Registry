-- Genera RecipeMetadata_Generated.lua per Forever, dal dump in gioco.
--
-- L'albero TBC prende il dataset da un dump di wago e lo passa a
-- tools/recipe-metadata/generate_recipe_metadata.py. Per Forever quella fonte
-- non esiste ancora, ma il client una fonte ce l'ha: GetAllRecipeIDs non
-- restituisce cio' che il personaggio sa fare, restituisce il CATALOGO del
-- mestiere -- tutte le sue ricette, apprese o no. Aprendo un mestiere si ha
-- sotto mano tutto quello che il dataset dovrebbe contenere per quel mestiere.
--
-- Il dump lo produce /rrdump in gioco (addon di sviluppo Collector), un mestiere per
-- volta, e finisce nelle SavedVariables. Questo script le legge e ne fa il
-- dataset.
--
-- Uso, dalla cartella RecipeRegistry_Forever:
--   lua Tools/generate-from-dump.lua <percorso/RecipeRegistry_Forever.lua>
--
-- IL FILE NON E' SOLO UN ELENCO DI RICETTE. Il modulo RecipeMetadata non
-- ricostruisce gli indici: se li aspetta gia' pronti nel file, ed e' per questo
-- che emettiamo anche createdItemToSpellIds, categoriesByProfession, navTree e
-- compagnia. Emettere solo recipesBySpellId compila benissimo e poi l'addon non
-- mostra niente, perche' il cancello "nascondi le non catalogate" interroga
-- createdItemToSpellIds e non ci trova nulla. Successo il 2026-09-18.
--
-- Cosa NON contiene, e va saputo prima di fidarsene: requiredSkill, skillLevels,
-- sourceKind, i trainer, le classi, le fasi. Il client non li espone per ricetta
-- -- GetRecipeSourceText tace e GetRecipeRequirements e' quasi sempre vuota --
-- e vanno presi dal datamining, che legge i file invece di interrogare l'API.
-- Quello che esce di qui e' la struttura: cosa esiste, cosa produce, con che
-- reagenti, in che categoria.

local input = arg and arg[1]
local output = (arg and arg[2]) or "Data/Metadata/RecipeMetadata_Generated.lua"
if not input then
    io.stderr:write("uso: lua Tools/generate-from-dump.lua <dump.lua> [output.lua] [altri-dump.lua ...]\n")
    os.exit(2)
end

-- Le SavedVariables sono Lua: si caricano invece di parsarle. In un ambiente
-- suo, perche' assegnano globali e non sono roba nostra.
local env = {}
local chunk, err = loadfile(input)
if not chunk then
    io.stderr:write("non riesco a leggere il dump: " .. tostring(err) .. "\n")
    os.exit(1)
end
setfenv(chunk, env)
local ok, runErr = pcall(chunk)
if not ok then
    io.stderr:write("il dump non e' Lua valido: " .. tostring(runErr) .. "\n")
    os.exit(1)
end

local dumps = (env.RecipeRegistryDumpDB or env.RecipeRegistryLogDB or {}).dumps
if type(dumps) ~= "table" or not next(dumps) then
    io.stderr:write("nessun dump: esegui /rrdump con il mestiere aperto, poi /reload e archivia il file.\n")
    os.exit(1)
end

-- Merge captures from separate sessions without depending on the beta's
-- SavedVariables reader. Newest capture wins per profession; other professions
-- remain. Input order breaks ties deterministically.
for index = 3, #(arg or {}) do
    local extra = {}
    local loader, loadErr = loadfile(arg[index])
    if not loader then error(loadErr) end
    setfenv(loader, extra)
    loader()
    local incoming = (extra.RecipeRegistryDumpDB or extra.RecipeRegistryLogDB or {}).dumps
    if type(incoming) ~= "table" or not next(incoming) then
        error("nessun dump in " .. tostring(arg[index]))
    end
    for name, dump in pairs(incoming) do
        local previous = dumps[name]
        if not previous or tostring(dump.at or "") >= tostring(previous.at or "") then
            dumps[name] = dump
        end
    end
end

for name, dump in pairs(dumps) do
    if type(dump) ~= "table" or type(dump.recipes) ~= "table" or #dump.recipes == 0
        or (dump.recipeCount and dump.recipeCount ~= #dump.recipes) then
        error("dump incompleto per " .. tostring(name) .. "; output non modificato")
    end
end

-- L'albero di navigazione e il filtro per espansione conoscono due valori,
-- "vanilla" e "tbc", cablati in GetProfessionExpansionsFromNav. Forever e'
-- contenuto vanilla piu' aggiunte e non ha ancora una tassonomia sua: finche'
-- non ce l'ha, tutto sta sotto "vanilla". E' grossolano ma vero al livello che
-- conta, e soprattutto tiene le ricette visibili -- un valore che quel codice
-- non conosce le farebbe sparire dalla barra laterale.
local EXPANSION = "vanilla"

-- Le chiavi di mestiere devono combaciare con quelle del bundle di datamining
-- (out/bundle/forever-local-*/recipes.json), che e' la fonte destinata a
-- sostituire questa. La slugatura meccanica darebbe "firstaid"; il bundle dice
-- "first_aid", e vince lui.
local PROFESSION_KEY_OVERRIDES = {
    ["first aid"] = "first_aid",
}

-- Solo per i nomi di mestiere: "First Aid" -> "first_aid". Le categorie non
-- passano di qui, vedi categoryKey.
local function slug(text)
    if type(text) ~= "string" then return nil end
    local lowered = text:lower()
    if PROFESSION_KEY_OVERRIDES[lowered] then
        return PROFESSION_KEY_OVERRIDES[lowered]
    end
    local out = lowered:gsub("[^%a%d]", "")
    if out == "" then return nil end
    return out
end

-- La chiave di una categoria e' il suo ID nel gioco, non il nome slugato.
--
-- Le categorie sono gia' quelle del client: il nome che finisce in "label" e'
-- quello che GetCategoryInfo restituisce. La chiave pero' serve stabile, e
-- slugare il nome la legherebbe alla lingua del client di chi ha fatto il dump:
-- un dump italiano direbbe "pozioni" dove uno inglese dice "potions", e due
-- dataset raccolti da persone diverse non si fonderebbero mai. L'ID no, e'
-- lo stesso ovunque.
local function categoryKey(info)
    local id = info and tonumber(info.categoryID)
    if not id then return nil end
    return "c" .. tostring(id)
end

-- La catena di categorie di una ricetta, dalla piu' alta alla sua. Si risale
-- fino alla radice, poi si scarta la radice: quella e' il mestiere, non una
-- categoria.
local function categoryChain(categories, categoryID)
    if type(categories) ~= "table" then return nil end
    local chain, seen, cursor = {}, {}, categoryID
    while cursor do
        local key = tostring(cursor)
        if seen[key] then break end   -- un albero con un ciclo non deve appendere lo script
        seen[key] = true
        local info = categories[key]
        if type(info) ~= "table" then break end
        table.insert(chain, 1, info)
        local parent = info.parentCategoryID
        cursor = (parent and parent ~= 0) and parent or nil
    end
    if #chain == 0 then return nil end
    if #chain > 1 then table.remove(chain, 1) end
    return chain
end

local records = {}
local categoriesByProfession = {}
local subcategoriesByProfession = {}
local stats = { professions = 0, recipes = 0, withReagents = 0, withoutOutput = 0 }
local builds = {}

local function noteInto(bucketTable, key, entry)
    local bucket = bucketTable[key]
    if not bucket then
        bucket = { order = {}, byKey = {} }
        bucketTable[key] = bucket
    end
    if entry and entry.key and not bucket.byKey[entry.key] then
        bucket.byKey[entry.key] = entry
        bucket.order[#bucket.order + 1] = entry
    end
    return bucket
end

for professionName, dump in pairs(dumps) do
    if type(dump) == "table" and type(dump.recipes) == "table" then
        stats.professions = stats.professions + 1
        local declared = dump.profession
        if declared == "nil" then declared = nil end
        local professionKey = slug(declared or professionName)
        if type(dump.build) == "table" and dump.build[1] then
            builds[tostring(dump.build[1]) .. "." .. tostring(dump.build[2])] = true
        end
        for _, row in ipairs(dump.recipes) do
            local spellId = tonumber(row.recipeID)
            if spellId and professionKey then
                local chain = categoryChain(dump.categories, row.categoryID)
                local category, subcategory, sortOrder
                if chain then
                    category = categoryKey(chain[1])
                    sortOrder = tonumber(chain[1].uiOrder)
                    if category then
                        noteInto(categoriesByProfession, professionKey,
                            { key = category, label = tostring(chain[1].name or category), order = sortOrder or 999 })
                    end
                    if chain[2] and category then
                        subcategory = categoryKey(chain[2])
                        local prof = subcategoriesByProfession[professionKey]
                        if not prof then prof = {}; subcategoriesByProfession[professionKey] = prof end
                        if subcategory then
                            noteInto(prof, category,
                                { key = subcategory, label = tostring(chain[2].name or subcategory),
                                  order = tonumber(chain[2].uiOrder) or 999 })
                        end
                    end
                end
                local record = {
                    profession = professionKey,
                    expansion = EXPANSION,
                    createdItemId = tonumber(row.outputItemID),
                    category = category,
                    subcategory = subcategory,
                    sortOrder = sortOrder,
                }
                local qMin = tonumber(row.quantityMin) or 1
                local qMax = tonumber(row.quantityMax) or qMin
                if qMin ~= 1 or qMax ~= 1 then
                    record.createdCount = qMin
                    record.createdCountMax = qMax
                end
                if not record.createdItemId then
                    -- una ricetta senza oggetto prodotto e' un effetto su di se'
                    record.selfOnlyOutputless = true
                    stats.withoutOutput = stats.withoutOutput + 1
                end
                if type(row.reagents) == "table" and #row.reagents > 0 then
                    local reagents = {}
                    for _, r in ipairs(row.reagents) do
                        local itemId = tonumber(r.itemID)
                        if itemId then
                            reagents[#reagents + 1] = { itemId = itemId, count = tonumber(r.count) or 1 }
                        end
                    end
                    if #reagents > 0 then
                        record.reagents = reagents
                        stats.withReagents = stats.withReagents + 1
                    end
                end
                records[spellId] = record
                stats.recipes = stats.recipes + 1
            end
        end
    end
end

-- Ordinato per spellId: il file va in git, e un ordine stabile e' la differenza
-- fra un diff leggibile e ottomila righe cambiate a ogni rigenerazione.
local ids = {}
for spellId in pairs(records) do ids[#ids + 1] = spellId end
table.sort(ids)

-- Gli indici che il modulo si aspetta gia' costruiti nel file.
local createdItemToSpellIds = {}
local navProfessions = {}
for _, spellId in ipairs(ids) do
    local r = records[spellId]
    if r.createdItemId then
        local bucket = createdItemToSpellIds[r.createdItemId]
        if not bucket then bucket = {}; createdItemToSpellIds[r.createdItemId] = bucket end
        bucket[#bucket + 1] = spellId
    end
    local prof = navProfessions[r.profession]
    if not prof then prof = { all = {}, categories = {} }; navProfessions[r.profession] = prof end
    prof.all[#prof.all + 1] = spellId
    if r.category then
        local cat = prof.categories[r.category]
        if not cat then cat = { all = {}, subs = {} }; prof.categories[r.category] = cat end
        cat.all[#cat.all + 1] = spellId
        if r.subcategory then
            local sub = cat.subs[r.subcategory]
            if not sub then sub = {}; cat.subs[r.subcategory] = sub end
            sub[#sub + 1] = spellId
        end
    end
end

local buildList = {}
for build in pairs(builds) do buildList[#buildList + 1] = build end
table.sort(buildList)

local out = {}
local function emit(line) out[#out + 1] = line end

local function sortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function emitIdList(indent, name, list)
    if #list == 0 then
        emit(string.format("%s%s = {},", indent, name))
        return
    end
    local parts = {}
    for i, id in ipairs(list) do parts[i] = tostring(id) end
    emit(string.format("%s%s = { %s },", indent, name, table.concat(parts, ", ")))
end

emit("-- Generato da Tools/generate-from-dump.lua dal dump in gioco. Non modificare a mano.")
emit("--")
emit("-- Fonte: /rrdump su un client vivo, un mestiere per volta. Contiene la")
emit("-- struttura -- ricette, oggetti prodotti, reagenti, categorie -- e non contiene")
emit("-- requiredSkill, skillLevels, sourceKind, trainer, classi e fasi: il client non")
emit("-- li espone per ricetta. Quelli arrivano dal datamining.")
emit("--")
emit("-- expansion vale \"vanilla\" per tutte: Forever non ha ancora una tassonomia sua,")
emit("-- e l'albero di navigazione conosce solo vanilla e tbc.")
emit("--")
emit(string.format("-- Mestieri coperti: %d. Ricette: %d.", stats.professions, #ids))
emit("RecipeRegistryRecipeMetadata = {")
emit("    schemaVersion = 1,")
emit(string.format("    metadataVersion = %q,", "forever-ingame-" .. (buildList[1] or "sconosciuto")))
emit('    flavor = "forever",')
emit("")
emit("    recipesBySpellId = {")

for _, spellId in ipairs(ids) do
    local r = records[spellId]
    emit(string.format("        [%d] = {", spellId))
    emit(string.format("            profession = %q,", r.profession))
    emit(string.format("            expansion = %q,", r.expansion))
    if r.createdItemId then emit(string.format("            createdItemId = %d,", r.createdItemId)) end
    if r.category then emit(string.format("            category = %q,", r.category)) end
    if r.subcategory then emit(string.format("            subcategory = %q,", r.subcategory)) end
    if r.sortOrder then emit(string.format("            sortOrder = %d,", r.sortOrder)) end
    if r.createdCount then
        emit(string.format("            createdCount = %d,", r.createdCount))
        emit(string.format("            createdCountMax = %d,", r.createdCountMax))
    end
    if r.selfOnlyOutputless then emit("            selfOnlyOutputless = true,") end
    if r.reagents then
        emit("            reagents = {")
        for _, reagent in ipairs(r.reagents) do
            emit(string.format("                { itemId = %d, count = %d },", reagent.itemId, reagent.count))
        end
        emit("            },")
    end
    emit("        },")
end
emit("    },")
emit("")

-- Nessuna ricetta del client dichiara l'oggetto che la insegna: il campo esiste
-- perche' il modulo lo cerca, e resta vuoto finche' non arriva dal datamining.
emit("    recipeItemToSpellId = {},")
emit("")

emit("    createdItemToSpellIds = {")
for _, itemId in ipairs(sortedKeys(createdItemToSpellIds)) do
    local list = createdItemToSpellIds[itemId]
    table.sort(list)
    emitIdList("        ", string.format("[%d]", itemId), list)
end
emit("    },")
emit("")

local function emitLabelled(bucket, indent)
    table.sort(bucket.order, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    for _, entry in ipairs(bucket.order) do
        emit(string.format("%s{ key = %q, label = %q, order = %d },", indent, entry.key, entry.label, entry.order))
    end
end

emit("    categoriesByProfession = {")
for _, profession in ipairs(sortedKeys(categoriesByProfession)) do
    emit(string.format("        [%q] = {", profession))
    emitLabelled(categoriesByProfession[profession], "            ")
    emit("        },")
end
emit("    },")
emit("")

emit("    subcategoriesByProfession = {")
for _, profession in ipairs(sortedKeys(subcategoriesByProfession)) do
    emit(string.format("        [%q] = {", profession))
    local prof = subcategoriesByProfession[profession]
    for _, categoryKey in ipairs(sortedKeys(prof)) do
        emit(string.format("            [%q] = {", categoryKey))
        emitLabelled(prof[categoryKey], "                ")
        emit("            },")
    end
    emit("        },")
end
emit("    },")
emit("")

-- I nomi di zona servono alla libreria delle fonti, che qui non abbiamo.
emit("    zoneNamesById = {},")
emit("")

emit("    navTree = {")
emit(string.format("        [%q] = {", EXPANSION))
for _, profession in ipairs(sortedKeys(navProfessions)) do
    local prof = navProfessions[profession]
    emit(string.format("            [%q] = {", profession))
    table.sort(prof.all)
    emitIdList("                ", "_all", prof.all)
    for _, categoryKey in ipairs(sortedKeys(prof.categories)) do
        local cat = prof.categories[categoryKey]
        emit(string.format("                [%q] = {", categoryKey))
        table.sort(cat.all)
        emitIdList("                    ", "_all", cat.all)
        for _, subKey in ipairs(sortedKeys(cat.subs)) do
            local sub = cat.subs[subKey]
            table.sort(sub)
            emitIdList("                    ", string.format("[%q]", subKey), sub)
        end
        emit("                },")
    end
    emit("            },")
end
emit("        },")
emit("    },")
emit("}")
emit("")

local file, writeErr = io.open(output, "w")
if not file then
    io.stderr:write("non riesco a scrivere " .. output .. ": " .. tostring(writeErr) .. "\n")
    os.exit(1)
end
file:write(table.concat(out, "\n"))
file:close()

local categoryCount = 0
for _, bucket in pairs(categoriesByProfession) do categoryCount = categoryCount + #bucket.order end

print(string.format("scritto %s", output))
print(string.format("  mestieri %d, ricette %d, con reagenti %d, senza oggetto prodotto %d",
    stats.professions, stats.recipes, stats.withReagents, stats.withoutOutput))
print(string.format("  indici: %d oggetti prodotti, %d categorie",
    #sortedKeys(createdItemToSpellIds), categoryCount))
