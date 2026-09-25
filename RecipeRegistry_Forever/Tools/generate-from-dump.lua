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
-- Il datamining, se c'e'.
--
-- Porta i campi che il client non espone per ricetta: requiredSkill,
-- skillLevels, l'espansione vera e classMask -- e, per oggetto, il legame:
-- MiningItems[itemId] e' il bindType di ItemSparse, 1 = legato quando si
-- raccoglie. Arriva gia' tradotto in Lua da convert-mining.ps1, perche' il
-- bundle e' JSON e qui non lo leggeremmo.
-- La provenienza raccolta a mano, da Tools/acquisition-worksheet.tsv.
--
-- Non viene dal client e non viene dal datamining: chi vende una ricetta, chi
-- la droppa e chi la insegna lo decide il server, e finche' non esiste un
-- database di Forever quella colonna si riempie a mano -- in gioco aprendo il
-- venditore, o leggendo una fonte e citandola. Il TSV e' il foglio dove si
-- scrive; questo lo legge e basta.
local acquisition = {}
local acquisitionBySpell = {}
local acquisitionRows = 0

local function loadAcquisition(path)
    local file = io.open(path, "r")
    if not file then error("worksheet non leggibile: " .. tostring(path)) end
    local header
    for line in file:lines() do
        line = line:gsub("\r$", "")
        local fields = {}
        for value in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = value end
        if not header then
            header = {}
            for index, name in ipairs(fields) do header[name] = index end
            if not header.recipeItemId then error("worksheet senza colonna recipeItemId") end
        else
            local function get(name)
                local index = header[name]
                local value = index and fields[index] or nil
                if value == nil or value == "" then return nil end
                return value
            end
            local itemId = tonumber(get("recipeItemId"))
            local spellId = tonumber(get("spellId"))
            local kind = get("sourceKind")
            -- Una riga senza provenienza e' una riga ancora da riempire, non
            -- un dato: si salta, cosi' il conteggio dice la verita'.
            if kind and (itemId or spellId) then
                -- Nome, zona e fazione possono portare piu' valori separati da
                -- " | ": una ricetta venduta da due NPC, uno per fazione, e'
                -- la forma normale dei quartermaster a Merchant's Favor. Si
                -- srotolano in piu' sourcePlaces, che e' la verita': sono due
                -- persone in due posti, non una con due nomi.
                local function split(value)
                    if not value then return {} end
                    local parts = {}
                    for piece in (value .. " | "):gmatch("%s*(.-)%s*| ") do
                        if piece ~= "" then parts[#parts + 1] = piece end
                    end
                    if #parts == 0 then parts[1] = value end
                    return parts
                end
                local names, zones, factions = split(get("npcName")), split(get("zone")), split(get("faction"))
                local xs, ys = split(get("x")), split(get("y"))
                local places = {}
                for i = 1, math.max(#names, #zones, 1) do
                    local place = {
                        name = names[i] or names[1],
                        zone = zones[i] or zones[1],
                        -- Le coordinate seguono il loro NPC: due venditori
                        -- stanno in due punti, e riusare le prime per il
                        -- secondo e' un numero preciso e sbagliato.
                        x = tonumber(xs[i] or (#xs == 1 and xs[1] or nil)),
                        y = tonumber(ys[i] or (#ys == 1 and ys[1] or nil)),
                        faction = factions[i] or (#factions == 1 and factions[1] or nil),
                    }
                    if place.name or place.zone then places[#places + 1] = place end
                end
                local entry = {
                    kind = kind,
                    places = places,
                    bossDrop = get("bossDrop") == "true",
                    worldDrop = get("worldDrop") == "true",
                    trainerTitle = get("trainerTitle"),
                }
                -- Due indici perche' due forme di ricetta. Quella insegnata da
                -- un oggetto si riconosce dall'oggetto, che e' cio' che si
                -- vede in gioco. Quella che un oggetto non ce l'ha -- le
                -- ricette da trainer -- si riconosce solo dallo spell, e senza
                -- questo secondo indice non si potrebbe correggere: e' il caso
                -- di Enchant Bracer - Strength, che la deduzione dava per
                -- trainer e che invece vende Dalria.
                if itemId then acquisition[itemId] = entry end
                if spellId then acquisitionBySpell[spellId] = entry end
                acquisitionRows = acquisitionRows + 1
            end
        end
    end
    file:close()
end

local mining = {}
local miningItems = {}
-- Gli oggetti che questa build del client non descrive: nessuna riga in
-- ItemSparse, quindi nemmeno un nome. Una ricetta che produce uno di questi
-- esiste nei dati e non nel gioco.
local miningUnshipped = {}
local miningPath

-- Il livello a cui si impara una ricetta vanilla, dal dataset TBC
-- (Tools/captures/tbc-vanilla-skill.tsv, scritto da extract-tbc-acquisition.lua).
-- Serve per le ricette dei trainer: il client di Forever per quelle dice 1.
local vanillaSkill = {}
local function loadVanillaSkill(path)
    local file = assert(io.open(path, "r"))
    local header = true
    for line in file:lines() do
        if header then
            header = false
        else
            local spellId, skill = line:match("^(%d+)\t(%d+)")
            if spellId then vanillaSkill[tonumber(spellId)] = tonumber(skill) end
        end
    end
    file:close()
end

-- A che livello di mestiere si impara la ricetta, e da dove lo sappiamo.
--
-- Il campo del client, SkillLineAbility.MinSkillLineRank, vale 1 su 2503
-- ricette su 2519: il livello che un trainer chiede e' dato del server. Messo
-- nel record cosi' com'era, l'addon mostrava "1" su ogni riga. Quindi:
--   1. il livello che chiede l'oggetto-ricetta (ItemSparse.RequiredSkillRank),
--      dato del client di Forever, per le ricette che un oggetto insegna;
--   2. il livello vanilla dal dataset TBC, per le ricette dei trainer;
--   3. MinSkillLineRank, solo quando dice qualcosa (sopra 1);
--   4. niente: meglio nessun livello che uno falso.
local function resolveRequiredSkill(spellId, mined)
    if mined and tonumber(mined.recipeItemSkill) and mined.recipeItemSkill > 0 then
        return mined.recipeItemSkill, "recipeItem"
    end
    if vanillaSkill[spellId] then
        return vanillaSkill[spellId], "vanilla"
    end
    if mined and tonumber(mined.requiredSkill) and mined.requiredSkill > 1 then
        return mined.requiredSkill, "client"
    end
    return nil, nil
end
local requiredSkillSources = {}
for index = 3, #(arg or {}) do
    local value = tostring(arg[index])
    local acquisitionPath = value:match("^%-%-acquisition=(.+)$")
    local path = value:match("^%-%-mining=(.+)$")
    local vanillaSkillPath = value:match("^%-%-vanilla%-skill=(.+)$")
    if acquisitionPath then
        loadAcquisition(acquisitionPath)
    elseif vanillaSkillPath then
        loadVanillaSkill(vanillaSkillPath)
    elseif path then
        miningPath = path
        local env = {}
        local loader, loadErr = loadfile(path)
        if not loader then error(loadErr) end
        setfenv(loader, env)
        loader()
        mining = env.MiningRecipes or {}
        miningItems = env.MiningItems or {}
        miningUnshipped = env.MiningUnshippedItems or {}
    else
        local extra = {}
        local loader, loadErr = loadfile(value)
        if not loader then error(loadErr) end
        setfenv(loader, extra)
        loader()
        local incoming = (extra.RecipeRegistryDumpDB or extra.RecipeRegistryLogDB or {}).dumps
        if type(incoming) ~= "table" or not next(incoming) then
            error("nessun dump in " .. value)
        end
        for name, dump in pairs(incoming) do
            local previous = dumps[name]
            if not previous or tostring(dump.at or "") >= tostring(previous.at or "") then
                dumps[name] = dump
            end
        end
    end
end

for name, dump in pairs(dumps) do
    if type(dump) ~= "table" or type(dump.recipes) ~= "table" or #dump.recipes == 0
        or (dump.recipeCount and dump.recipeCount ~= #dump.recipes) then
        error("dump incompleto per " .. tostring(name) .. "; output non modificato")
    end
end

-- L'espansione di una ricetta la porta il datamining: 1557 vengono da vanilla,
-- 962 sono aggiunte di Forever. EXPANSION e' il ripiego per quelle che il
-- datamining non copre.
--
-- E' provenienza, non un asse di navigazione: l'addon non ci filtra e non ci
-- ramifica sopra piu' niente, il campo resta nel record come requiredSkill e
-- classMask, per chi un giorno lo vorra' mostrare.
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
-- categoria. Di quello che resta conta solo il primo anello: nel client Forever
-- l'albero ha un livello solo sotto il mestiere, in tutti e dodici i mestieri,
-- quindi di sottocategorie non ce ne sono e il dataset non le porta.
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
local placements = {}
local categoriesByProfession = {}
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

-- In ordine, non come capita.
--
-- Una ricetta puo' stare in due mestieri -- la 461692, Synthetic Gordok Ogre
-- Suit, sta in Leatherworking e Tailoring -- e in quel caso uno dei due e' il
-- primario nel record. Scorrere i dump con pairs lasciava decidere alla tabella
-- hash: rigenerando senza toccare niente il primario poteva cambiare, e con lui
-- il diff del file. Ordinati, la scelta e' sempre la stessa.
local dumpNames = {}
for professionName in pairs(dumps) do dumpNames[#dumpNames + 1] = professionName end
table.sort(dumpNames)

for _, professionName in ipairs(dumpNames) do
    local dump = dumps[professionName]
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
                local category, sortOrder
                if chain then
                    category = categoryKey(chain[1])
                    sortOrder = tonumber(chain[1].uiOrder)
                    if category then
                        noteInto(categoriesByProfession, professionKey,
                            { key = category, label = tostring(chain[1].name or category), order = sortOrder or 999 })
                    end
                end
                -- L'espansione vera, quando il datamining la conosce: 1559
                -- ricette vengono da vanilla e 990 sono aggiunte di Forever.
                -- Senza, resta la costante. E' provenienza e basta: l'addon non
                -- ci filtra e non ci ramifica sopra.
                local mined = mining[spellId]
                local requiredSkill, requiredSkillSource = resolveRequiredSkill(spellId, mined)
                requiredSkillSources[requiredSkillSource or "none"] =
                    (requiredSkillSources[requiredSkillSource or "none"] or 0) + 1
                local record = {
                    profession = professionKey,
                    expansion = (mined and mined.expansion) or EXPANSION,
                    requiredSkill = requiredSkill,
                    skillLevels = mined and mined.skillLevels or nil,
                    classMask = mined and mined.classMask or nil,
                    -- L'oggetto che insegna la ricetta -- un Pattern, dei Plans --
                    -- dal datamining: il client non lo dice per ricetta. Su
                    -- Forever il datamining lo trova solo passando da
                    -- ItemXItemEffect, come retail; senza, era vuoto per tutte.
                    recipeItemId = mined and mined.recipeItemId or nil,
                    createdItemId = tonumber(row.outputItemID),
                    category = category,
                    sortOrder = sortOrder,
                }
                local qMin = tonumber(row.quantityMin) or 1
                local qMax = tonumber(row.quantityMax) or qMin
                if qMin ~= 1 or qMax ~= 1 then
                    record.createdCount = qMin
                    record.createdCountMax = qMax
                end
                -- Una ricetta che non produce un oggetto NON e' per questo "solo
                -- per se'". Questa riga lo deduceva, ed era sbagliato: gli
                -- incantamenti non producono niente e si mettono sugli oggetti
                -- di chiunque. Marcarli self-only nascondeva al filtro tutti gli
                -- incantamenti dei compagni di gilda -- 179 su 179 -- che e'
                -- proprio "chi mi incanta i bracciali?", la domanda per cui
                -- l'addon esiste. Visto in gioco il 2026-09-21, col primo sync.
                --
                -- Su TBC il flag e' stretto e viene da conoscenza esplicita: 4
                -- ricette, gli incantamenti agli anelli, che l'incantatore mette
                -- solo sui propri. Su Forever non esistono. Se un giorno si
                -- sapra' di una ricetta davvero self-only, la si dichiara in
                -- RecipeMetadata_Overrides.lua, selfOnlyOutputlessBySpellId.
                if not record.createdItemId then
                    stats.withoutOutput = stats.withoutOutput + 1
                end
                -- Il BoP e' un fatto dell'oggetto prodotto, non della ricetta: si
                -- legge dal legame che il datamining da' per quell'oggetto, e
                -- l'oggetto e' quello che dice il client. Cosi' era anche su TBC,
                -- dove il bopOutput statico veniva da ItemSparse. Senza oggetto
                -- (gli incantamenti) non c'e' niente da legare, e il campo resta
                -- assente. Senza legame noto resta assente anche lui, e decide a
                -- runtime il client, come prima.
                local bind = record.createdItemId and miningItems[record.createdItemId]
                if bind ~= nil then
                    record.bopOutput = tonumber(bind) == 1
                end
                -- Una ricetta il cui prodotto il client non sa nemmeno
                -- nominare non e' una ricetta che ti manca: e' contenuto che
                -- questa build non spedisce -- avanzi di Season of Discovery,
                -- roba di Forever non ancora attiva, i rimossi storici di
                -- vanilla. Listarla fra "quelle che ti mancano" manda il
                -- giocatore a cercare una ricetta che non esiste, quindi si
                -- marca `removed` e il tab Collection la esclude da solo.
                -- Stesso taglio che fa ForeverChanges, che su alchemy ne
                -- scarta 18 delle sue 197.
                if record.createdItemId and miningUnshipped[record.createdItemId] then
                    record.removed = true
                end
                -- La provenienza raccolta a mano, se per questa ricetta c'e'.
                -- Si indicizza sull'oggetto-ricetta perche' e' quello che si
                -- vede in gioco: la riga del venditore, l'oggetto che cade.
                local got = (record.recipeItemId and acquisition[record.recipeItemId])
                    or acquisitionBySpell[spellId]
                if got then
                    record.sourceKind = got.kind
                    record.bossDrop = got.bossDrop or nil
                    record.worldDrop = got.worldDrop or nil
                    record.trainerTitle = got.trainerTitle
                    if got.places and #got.places > 0 then
                        record.sourcePlaces = got.places
                    end
                end
                -- Niente deduzione per esclusione: l'assenza di un
                -- oggetto-ricetta dice che non la insegna un OGGETTO, non che
                -- la insegni un trainer. Poteva essere una discovery, un
                -- premio di quest o un sottoprodotto -- Fire Oil si impara
                -- lavorando e non la insegna nessuno. Qui c'era quella
                -- deduzione, misurata al 90%, e il 10% restante erano righe
                -- inventate indistinguibili da quelle lette. La provenienza
                -- delle ricette vanilla arriva dal dataset TBC, che quel dato
                -- ce l'ha per davvero; quella di Forever resta vuota finche'
                -- non la si raccoglie.
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
                -- Una ricetta in due mestieri non e' un errore da risolvere:
                -- e' come il client la racconta, e il dataset TBC ha lo stesso
                -- caso con Transmute Gold, che sta sotto Mining e Alchemy. Il
                -- primo mestiere in ordine resta il primario del record, gli
                -- altri si aggiungono in "professions"; le collocazioni restano
                -- separate perche' la categoria e' diversa in ogni mestiere.
                placements[spellId] = placements[spellId] or {}
                placements[spellId][#placements[spellId] + 1] = {
                    profession = professionKey,
                    category = category,
                }
                local existing = records[spellId]
                if existing then
                    if existing.profession ~= professionKey then
                        existing.professions = existing.professions or { existing.profession }
                        local already = false
                        for _, p in ipairs(existing.professions) do
                            if p == professionKey then already = true end
                        end
                        if not already then
                            existing.professions[#existing.professions + 1] = professionKey
                            stats.multiProfession = (stats.multiProfession or 0) + 1
                        end
                    else
                        -- lo stesso ID due volte nello stesso mestiere: il
                        -- client lo fa (Obsidian Reaver in Blacksmithing) e le
                        -- due righe sono identiche, quindi non c'e' niente da
                        -- scegliere
                        stats.duplicated = (stats.duplicated or 0) + 1
                    end
                else
                    records[spellId] = record
                    stats.recipes = stats.recipes + 1
                end
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
local recipeItemToSpellId = {}
local navProfessions = {}
for _, spellId in ipairs(ids) do
    local r = records[spellId]
    if r.recipeItemId and not recipeItemToSpellId[r.recipeItemId] then
        recipeItemToSpellId[r.recipeItemId] = spellId
    end
    if r.createdItemId then
        local bucket = createdItemToSpellIds[r.createdItemId]
        if not bucket then bucket = {}; createdItemToSpellIds[r.createdItemId] = bucket end
        bucket[#bucket + 1] = spellId
    end
    -- una riga per collocazione, non una per record: una ricetta di due
    -- mestieri deve comparire nella barra laterale di entrambi, ognuno sotto
    -- la sua categoria
    for _, place in ipairs(placements[spellId] or {}) do
        local prof = navProfessions[place.profession]
        if not prof then prof = { all = {}, categories = {} }; navProfessions[place.profession] = prof end
        local seenAll = false
        for _, id in ipairs(prof.all) do if id == spellId then seenAll = true break end end
        if not seenAll then prof.all[#prof.all + 1] = spellId end
        if place.category then
            local cat = prof.categories[place.category]
            if not cat then cat = { all = {} }; prof.categories[place.category] = cat end
            local seenCat = false
            for _, id in ipairs(cat.all) do if id == spellId then seenCat = true break end end
            if not seenCat then cat.all[#cat.all + 1] = spellId end
        end
    end
end

local buildList = {}
for build in pairs(builds) do buildList[#buildList + 1] = build end
table.sort(buildList)

local out = {}
local function emit(line) out[#out + 1] = line end

-- I nomi di zona si internano: una citta' che compare su cento righe si
-- scrive una volta sola e le righe portano il numero. E' la stessa forma del
-- dataset TBC, che RecipeMetadata:GetSource risolve da zoneNamesById.
local zoneNames, zoneIds, zoneCount = {}, {}, 0
local function zoneId(name)
    if not zoneIds[name] then
        zoneCount = zoneCount + 1
        zoneIds[name] = zoneCount
        zoneNames[zoneCount] = name
    end
    return zoneIds[name]
end

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

-- Il censimento della copertura.
--
-- Serve a sapere cosa c'e' e soprattutto cosa non c'e', senza doverlo dedurre
-- leggendo i record. I campi assenti non sono dimenticanze: sono informazioni
-- che ne' il client ne' il datamining espongono oggi, e finiscono in testa al
-- file generato perche' e' il posto dove qualcuno le cerchera'.
local COVERAGE_FIELDS = {
    { "profession",     "client",     "di che mestiere e'" },
    { "category",       "client",     "dove sta nella barra laterale" },
    { "reagents",       "client",     "cosa serve per farla" },
    { "createdItemId",  "client",     "cosa produce" },
    { "createdCount",   "client",     "quante ne produce, se diverso da una" },
    { "requiredSkill",  "datamining + TBC", "a che livello si impara: oggetto-ricetta, poi vanilla" },
    { "skillLevels",    "datamining", "le soglie di difficolta'" },
    { "expansion",      "datamining", "vanilla o aggiunta di Forever" },
    { "classMask",      "datamining", "quali classi possono impararla" },
    { "bopOutput",      "datamining", "se il prodotto e' legato quando si raccoglie" },
    { "recipeItemId",   "datamining", "l'oggetto che insegna la ricetta" },
    { "removed",        "datamining", "nei dati del client ma non nel gioco" },
    { "sourceKind",     "a mano",     "da dove si ottiene" },
    { "sourcePlaces",   "a mano",     "chi la vende o la droppa, e dove" },
}
local MISSING_FIELDS = {
    { "trainerTitle",     "quale trainer la insegna" },
    { "specialization",   "se richiede una specializzazione" },
    { "phase",            "in che fase di contenuto arriva" },
}

local coverage = {}
for _, field in ipairs(COVERAGE_FIELDS) do coverage[field[1]] = 0 end
for _, spellId in ipairs(ids) do
    local r = records[spellId]
    for _, field in ipairs(COVERAGE_FIELDS) do
        local value = r[field[1]]
        if value ~= nil and (type(value) ~= "table" or next(value) ~= nil) then
            coverage[field[1]] = coverage[field[1]] + 1
        end
    end
end

emit("-- Generato da Tools/generate-from-dump.lua dal dump in gioco. Non modificare a mano.")
emit("--")
emit("-- Due fonti, ognuna per cio' che sa.")
emit("--")
emit("-- Il client, con /rrdump su una sessione viva: la struttura -- quali ricette")
emit("-- esistono, cosa producono, con che reagenti, in che categoria. E' la fonte")
emit("-- aggiornata, perche' conosce anche cio' che una patch ha aggiunto ieri.")
emit("--")
emit("-- Il datamining di ../WowForeverMining: i campi che il client non espone per")
emit("-- ricetta -- requiredSkill, le soglie di difficolta', l'espansione di origine")
emit("-- e classMask. Legge i file del gioco invece di interrogare l'API.")
emit("--")
emit("-- Dove si sovrappongono vince il client. Il censimento qui sotto dice riga per")
emit("-- riga chi ha riempito cosa, e cosa non ha riempito nessuno dei due.")
emit("--")
emit(string.format("-- Mestieri coperti: %d. Ricette: %d.", stats.professions, #ids))
emit("--")
emit("-- Copertura dei campi, su " .. tostring(#ids) .. " ricette:")
for _, field in ipairs(COVERAGE_FIELDS) do
    local n = coverage[field[1]]
    emit(string.format("--   %-16s %5d  (%s) %s", field[1], n, field[2], field[3]))
end
emit("--")
emit("-- Quello che ancora manca, e da dove dovra' arrivare:")
for _, field in ipairs(MISSING_FIELDS) do
    emit(string.format("--   %-16s %s", field[1], field[2]))
end
emit("--")
emit("-- Nessuno di questi e' esposto dal client per ricetta: GetRecipeSourceText")
emit("-- tace su tutte e GetRecipeRequirements e' quasi sempre vuota. Vanno presi")
emit("-- dal datamining quando imparera' a estrarli, o catturati in gioco dai")
emit("-- trainer, che e' un lavoro di raccolta a se'.")
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
    if r.professions and #r.professions > 1 then
        local parts = {}
        for i, prof in ipairs(r.professions) do parts[i] = string.format("%q", prof) end
        emit(string.format("            professions = { %s },", table.concat(parts, ", ")))
    end
    emit(string.format("            expansion = %q,", r.expansion))
    if r.createdItemId then emit(string.format("            createdItemId = %d,", r.createdItemId)) end
    if r.recipeItemId then emit(string.format("            recipeItemId = %d,", r.recipeItemId)) end
    if r.bopOutput ~= nil then emit(string.format("            bopOutput = %s,", tostring(r.bopOutput))) end
    -- Solo quando e' vero: `removed = false` su 2167 record sarebbe rumore, e
    -- RecipeMetadata:IsRemoved legge l'assenza come "non rimossa".
    if r.removed then emit("            removed = true,") end
    if r.sourceKind then
        emit(string.format("            sourceKind = %q,", r.sourceKind))
        if r.bossDrop then emit("            bossDrop = true,") end
        if r.worldDrop then emit("            worldDrop = true,") end
        if r.trainerTitle then emit(string.format("            trainerTitle = %q,", r.trainerTitle)) end
        if r.sourcePlaces then
            local parts = {}
            for _, place in ipairs(r.sourcePlaces) do
                local fields = {}
                if place.name then fields[#fields + 1] = string.format("name = %q", place.name) end
                -- La zona e' un id internato, non una stringa: RecipeMetadata
                -- la risolve da zoneNamesById, e una citta' che compare su
                -- cento righe si scrive una volta sola.
                if place.zone then fields[#fields + 1] = string.format("zone = %d", zoneId(place.zone)) end
                if place.x then fields[#fields + 1] = string.format("x = %s", tostring(place.x)) end
                if place.y then fields[#fields + 1] = string.format("y = %s", tostring(place.y)) end
                if place.faction then fields[#fields + 1] = string.format("faction = %q", place.faction) end
                parts[#parts + 1] = "{ " .. table.concat(fields, ", ") .. " }"
            end
            emit(string.format("            sourcePlaces = { %s },", table.concat(parts, ", ")))
        end
    end
    if r.category then emit(string.format("            category = %q,", r.category)) end
    if r.sortOrder then emit(string.format("            sortOrder = %d,", r.sortOrder)) end
    if r.requiredSkill then emit(string.format("            requiredSkill = %d,", r.requiredSkill)) end
    if r.skillLevels and #r.skillLevels > 0 then
        local parts = {}
        for i, level in ipairs(r.skillLevels) do parts[i] = tostring(level) end
        emit(string.format("            skillLevels = { %s },", table.concat(parts, ", ")))
    end
    if r.classMask then emit(string.format("            classMask = %d,", r.classMask)) end
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

-- L'oggetto che insegna una ricetta, all'indietro: e' cio' che permette al
-- tooltip di un Pattern di dire chi sa gia' fare la ricetta che insegna.
emit("    recipeItemToSpellId = {")
for _, itemId in ipairs(sortedKeys(recipeItemToSpellId)) do
    emit(string.format("        [%d] = %d,", itemId, recipeItemToSpellId[itemId]))
end
emit("    },")
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

-- I nomi di zona servono alla libreria delle fonti, che qui non abbiamo.
if zoneCount == 0 then
    emit("    zoneNamesById = {},")
else
    emit("    zoneNamesById = {")
    for id = 1, zoneCount do
        emit(string.format("        [%d] = %q,", id, zoneNames[id]))
    end
    emit("    },")
end
emit("")

emit("    navTree = {")
for _, profession in ipairs(sortedKeys(navProfessions)) do
    local prof = navProfessions[profession]
    emit(string.format("        [%q] = {", profession))
    table.sort(prof.all)
    emitIdList("            ", "_all", prof.all)
    for _, categoryKey in ipairs(sortedKeys(prof.categories)) do
        local cat = prof.categories[categoryKey]
        emit(string.format("            [%q] = {", categoryKey))
        table.sort(cat.all)
        emitIdList("                ", "_all", cat.all)
        emit("            },")
    end
    emit("        },")
end
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
print(string.format("  in piu' mestieri %d, righe doppie nel client %d",
    stats.multiProfession or 0, stats.duplicated or 0))
if miningPath then
    local enriched = coverage.requiredSkill or 0
    print(string.format("  arricchite dal datamining: %d su %d (%s)", enriched, #ids, miningPath))
    print(string.format("  livello richiesto: oggetto-ricetta %d, vanilla %d, client %d, ignoto %d",
        requiredSkillSources.recipeItem or 0, requiredSkillSources.vanilla or 0,
        requiredSkillSources.client or 0, requiredSkillSources.none or 0))
else
    print("  nessun datamining: mancano requiredSkill, skillLevels, espansione, classMask")
end
print(string.format("  indici: %d oggetti prodotti, %d categorie",
    #sortedKeys(createdItemToSpellIds), categoryCount))
