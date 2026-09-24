-- Development-only collector for the static resolution database.
-- /rrdump captures the active profession, including unlearned recipes.
-- It does not read or update character ownership or guild data.
local frame = CreateFrame("Frame")
local addonName = ...
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    if type(RecipeRegistryDumpDB) ~= "table" then RecipeRegistryDumpDB = {} end
    self:UnregisterEvent("ADDON_LOADED")
end)
local function describe(value)
    local t = type(value)
    if t == "string" or t == "number" or t == "boolean" then return value end
    if t == "nil" then return "nil" end
    return "<" .. t .. ">"
end

-- una tabella di ritorno dell'API, appiattita a un livello: i valori annidati
-- diventano la loro forma, non il loro contenuto, perche' qui interessa sapere
-- quali campi esistono e di che tipo sono
local function flatten(tbl)
    if type(tbl) ~= "table" then return describe(tbl) end
    local out = {}
    for k, v in pairs(tbl) do
        local key = tostring(k)
        if type(v) == "table" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            out[key] = "<table n=" .. n .. ">"
        else
            out[key] = describe(v)
        end
    end
    return out
end

local function safe(fn, ...)
    if type(fn) ~= "function" then return nil, "not-a-function" end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil, tostring(a) end
    return a, nil, b, c
end

local function runDump()
    local CT = _G.C_TradeSkillUI
    if not CT or type(CT.GetAllRecipeIDs) ~= "function" then
        print("|cffff5555rrdump|r: C_TradeSkillUI non disponibile")
        return
    end
    -- Capture the currently open profession, not a residual data source.
    local ready = type(CT.IsTradeSkillReady) == "function" and CT.IsTradeSkillReady() or false
    if not ready then
        print("rrdump: apri il mestiere e aspetta che la lista sia pronta.")
        return
    end
    local ids = safe(CT.GetAllRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then
        print("|cffff5555rrdump|r: nessuna ricetta da leggere. Apri un mestiere almeno una volta in questa sessione.")
        return
    end

    -- Di chi sono davvero queste ricette.
    --
    -- GetBaseProfessionInfo dice quale mestiere e' aperto; GetProfessionInfoByRecipeID
    -- dice a chi appartengono gli ID che stiamo per archiviare. Di solito
    -- coincidono, ma nel giro "impara, dumpa, dimentica, passa al successivo"
    -- possono divergere per un istante: la finestra e' gia' del mestiere nuovo
    -- mentre la lista e' ancora quella di prima. Fidarsi della finestra
    -- archivierebbe il catalogo di Alchemy sotto Blacksmithing, e sarebbe
    -- indistinguibile da un dato buono.
    --
    -- Quindi comanda la lista, e se la finestra non e' d'accordo non si sceglie:
    -- si rifiuta e si riprova fra un secondo. Un dump mancato costa un comando,
    -- uno etichettato male costa la fiducia in tutto il dataset.
    local fromRecipes
    if CT.GetProfessionInfoByRecipeID then
        local byRecipe = safe(CT.GetProfessionInfoByRecipeID, ids[1])
        fromRecipes = type(byRecipe) == "table"
            and (byRecipe.parentProfessionName or byRecipe.professionName) or nil
    end
    if fromRecipes == "" then fromRecipes = nil end

    local base = safe(CT.GetBaseProfessionInfo)
    local fromWindow = type(base) == "table" and base.professionName or nil
    if fromWindow == "" then fromWindow = nil end

    if fromRecipes and fromWindow and fromRecipes ~= fromWindow then
        print(string.format(
            "|cffff5555rrdump|r: la finestra dice %s ma le ricette sono di %s -- la lista non ha ancora cambiato mestiere. Riprova fra un secondo.",
            tostring(fromWindow), tostring(fromRecipes)))
        return
    end

    local professionName = fromRecipes or fromWindow
    if type(professionName) ~= "string" or professionName == "" then
        print("rrdump: mestiere non identificato, riprova quando la lista e' pronta.")
        return
    end
    local out = {
        at = date("%Y-%m-%d %H:%M:%S"),
        kind = "dump",
        build = { GetBuildInfo() },
        profession = describe(professionName),
        recipeCount = #ids,
        sessionReady = ready,
        recipes = {},
        categories = {},
    }

    local seenCategories = {}
    for i = 1, #ids do
        local id = ids[i]
        local info = safe(CT.GetRecipeInfo, id)
        if type(info) == "table" then
            local row = {
                recipeID = id,
                name = describe(info.name),
                categoryID = info.categoryID,
                skillLineAbilityID = info.skillLineAbilityID,
                -- NON si prende info.favorite, e non e' una dimenticanza:
                -- quello e' il preferito della UI di Blizzard, che vive nelle
                -- sue impostazioni. I preferiti dell'addon sono un'altra cosa,
                -- stanno in charDB.favorites e sono per personaggio. Mescolarli
                -- vorrebbe dire sovrascrivere le scelte dell'utente da una
                -- parte o dall'altra senza che nessuno l'abbia chiesto.
                itemLevel = info.itemLevel,
                numSkillUps = info.numSkillUps,
                maxTrivialLevel = info.maxTrivialLevel,
                isEnchantingRecipe = info.isEnchantingRecipe and true or false,
                isGatheringRecipe = info.isGatheringRecipe and true or false,
                itemLink = describe(safe(CT.GetRecipeItemLink, id)),
                recipeLink = describe(safe(CT.GetRecipeLink, id)),
                sourceText = describe(CT.GetRecipeSourceText and safe(CT.GetRecipeSourceText, id)),
                -- non appiattite: su Alchemy sono vuote, ma su Cooking la
                -- ricetta del falo' ne porta tre, e appiattirle le riduceva a
                -- "<table n=3>". Se dicono "serve un falo' vicino" o "serve
                -- skill N", sono proprio i campi che al dataset mancano.
                requirements = (function()
                    local reqs = CT.GetRecipeRequirements and safe(CT.GetRecipeRequirements, id)
                    if type(reqs) ~= "table" then return describe(reqs) end
                    local out = {}
                    for i, req in ipairs(reqs) do out[i] = flatten(req) end
                    return out
                end)(),
            }
            if info.categoryID then seenCategories[info.categoryID] = true end

            local schematic = safe(CT.GetRecipeSchematic, id, false)
            if type(schematic) ~= "table" then
                error("schema non disponibile per " .. tostring(id) .. "; dump precedente conservato")
            end
            if type(schematic) == "table" then
                -- Preserve every slot/alternative in the source dump. The
                -- generated flat reagent list currently uses the first choice.
                row.reagentSlotSchematics = schematic.reagentSlotSchematics
                row.outputItemID = schematic.outputItemID
                row.quantityMin = schematic.quantityMin
                row.quantityMax = schematic.quantityMax
                row.reagents = {}
                for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                    local first = slot.reagents and slot.reagents[1]
                    if first and first.itemID then
                        row.reagents[#row.reagents + 1] = {
                            itemID = first.itemID,
                            count = slot.quantityRequired or 1,
                            required = slot.required and true or false,
                        }
                    end
                end
            end
            out.recipes[#out.recipes + 1] = row
        end
    end

    if #out.recipes ~= #ids then
        error("lista incompleta; dump precedente conservato, riprova fra qualche secondo")
    end

    -- Anche le categorie genitrici, risalendo. Le ricette pendono dalle
    -- sotto-intestazioni, e senza i genitori non si distingue "Elixirs sotto la
    -- radice Alchemy" da una gerarchia piu' profonda: il generatore deve poter
    -- scartare la radice invece di prenderla per una categoria.
    local pending = {}
    for categoryID in pairs(seenCategories) do pending[#pending + 1] = categoryID end
    while #pending > 0 do
        local categoryID = table.remove(pending)
        local key = tostring(categoryID)
        if out.categories[key] == nil then
            local info = safe(CT.GetCategoryInfo, categoryID)
            out.categories[key] = flatten(info)
            local parent = type(info) == "table" and info.parentCategoryID or nil
            if parent and parent ~= 0 and out.categories[tostring(parent)] == nil then
                pending[#pending + 1] = parent
            end
        end
    end

    local db = _G.RecipeRegistryDumpDB
    if type(db) ~= "table" then
        print("|cffff5555rrdump|r: RecipeRegistryDumpDB non pronto")
        return
    end
    if type(db.dumps) ~= "table" then db.dumps = {} end
    -- per mestiere, in sovrascrittura: il dump valido e' l'ultimo
    db.dumps[tostring(professionName or "sconosciuto")] = out

    local withReagents = 0
    for _, row in ipairs(out.recipes) do
        if row.reagents and #row.reagents > 0 then withReagents = withReagents + 1 end
    end
    local reagentRows, distinct = 0, {}
    for _, row in ipairs(out.recipes) do
        for _, r in ipairs(row.reagents or {}) do
            reagentRows = reagentRows + 1
            distinct[r.itemID] = true
        end
    end
    local categoryCount, distinctCount = 0, 0
    for _ in pairs(out.categories) do categoryCount = categoryCount + 1 end
    for _ in pairs(distinct) do distinctCount = distinctCount + 1 end
    print(string.format("|cff33ff99rrdump|r: %s -> %d ricette (%d con reagenti), %d righe reagente su %d oggetti distinti, %d categorie%s. /reload per scriverlo su disco.",
        tostring(professionName), #out.recipes, withReagents, reagentRows, distinctCount, categoryCount,
        ""))
end

-- Il venditore aperto adesso: chi e', dove sta, cosa vende.
--
-- Serve perche' la provenienza di una ricetta non e' nei file del client --
-- chi la vende lo decide il server, e lo dice solo quando apri la finestra.
-- I quartermaster a Merchant's Favor sono il caso che ripaga: quattordici NPC
-- in due punti della mappa che vendono 316 delle ricette nuove di Forever.
--
-- Manuale come il resto dell'addon. Un aggancio a MERCHANT_SHOW catturerebbe
-- ogni venditore che apri per caso, e questo resta uno strumento che non fa
-- niente finche' non glielo chiedi.
local function vendorPosition()
    local C_Map = _G.C_Map
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
        local mapID = safe(C_Map.GetBestMapForUnit, "player")
        if mapID then
            local pos = safe(C_Map.GetPlayerMapPosition, mapID, "player")
            if type(pos) == "table" and pos.GetXY then
                local ok, x, y = pcall(pos.GetXY, pos)
                -- 0,0 non e' una posizione, e' l'assenza di una posizione:
                -- succede in istanza o prima che la mappa sia pronta.
                if ok and x and y and not (x == 0 and y == 0) then
                    return mapID, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
                end
            end
        end
        return mapID, nil, nil
    end
    local x, y = safe(_G.GetPlayerMapPosition, "player")
    if x and y and not (x == 0 and y == 0) then
        return nil, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
    end
    return nil, nil, nil
end

-- Classe 9 = Recipe: i pattern, le formule, gli schemi. Serve solo a dire in
-- chat quanto di utile c'era nella finestra; il passo offline legge gli id.
-- GetItemInfo risponde nil per un oggetto non ancora in cache, quindi questo
-- conteggio puo' essere basso alla prima apertura. I dati no.
local function linkIsRecipe(link)
    if type(link) ~= "string" or type(_G.GetItemInfo) ~= "function" then return false end
    local ok, _, _, _, _, _, _, _, _, _, _, _, classID = pcall(_G.GetItemInfo, link)
    return ok and classID == 9
end

-- L'API del venditore, qualunque nome porti su questo client.
--
-- Qui c'era il solo percorso classic, ed era sbagliato per costruzione:
-- Forever ha un client retail-shaped, e su quello i merchant stanno sotto
-- C_MerchantFrame. Invece di indovinare una seconda volta si prova quello che
-- c'e', in ordine, e se non risponde niente si stampa cosa il client espone
-- davvero -- che e' l'unica risposta utile a chi sta davanti al venditore.
local function merchantApi()
    local CM = _G.C_MerchantFrame
    local function pick(namespaced, global)
        if type(CM) == "table" and type(CM[namespaced]) == "function" then
            return CM[namespaced], "C_MerchantFrame." .. namespaced
        end
        if type(_G[global]) == "function" then
            return _G[global], global
        end
        return nil, nil
    end
    local num, numName = pick("GetNumItems", "GetMerchantNumItems")
    if not num then num, numName = pick("GetMerchantNumItems", "GetMerchantNumItems") end
    local info, infoName = pick("GetItemInfo", "GetMerchantItemInfo")
    local link, linkName = pick("GetItemLink", "GetMerchantItemLink")
    return num, info, link, string.format("%s / %s / %s",
        tostring(numName), tostring(infoName), tostring(linkName))
end

-- Una riga del venditore, normalizzata. La forma retail restituisce una
-- tabella, quella classic otto valori: si accettano entrambe invece di
-- scommettere su una.
local function merchantItem(infoFn, index)
    local a, _b, c, d, e, _f, _g, h = infoFn(index)
    if type(a) == "table" then
        return {
            name = a.name,
            price = a.price,
            quantity = a.stackCount or a.quantity,
            available = a.numAvailable,
            extendedCost = (a.hasExtendedCost or a.extendedCost) and true or false,
            -- L'id direttamente dalla tabella quando c'e': il link non arriva
            -- finche' il client non ha l'oggetto in cache, e sulla prima
            -- apertura di un quartermaster e' la maggioranza degli slot.
            itemID = a.itemID or a.itemId or a.id,
            -- La tabella com'e', appiattita. Non si sa ancora quali campi
            -- porti su questo client, e registrarli e' il modo di smettere di
            -- indovinare: la prossima cattura si legge questa e si sa.
            raw = flatten(a),
        }
    end
    return { name = a, price = c, quantity = d, available = e, extendedCost = h and true or false }
end

-- Cosa espone questo client in fatto di venditori. Si stampa quando niente
-- risponde, e si puo' chiedere con /rrdump api: una riga di diagnosi vale piu'
-- di un altro giro di tentativi.
local function printMerchantApi()
    local names = {}
    for key in pairs(_G) do
        if type(key) == "string" and key:find("Merchant") then names[#names + 1] = key end
    end
    table.sort(names)
    print("rrdump: globali con 'Merchant': " .. (#names > 0 and table.concat(names, ", ") or "nessuna"))
    local CM = _G.C_MerchantFrame
    if type(CM) == "table" then
        local fields = {}
        for key in pairs(CM) do fields[#fields + 1] = tostring(key) end
        table.sort(fields)
        print("rrdump: C_MerchantFrame: " .. (#fields > 0 and table.concat(fields, ", ") or "vuoto"))
    else
        print("rrdump: C_MerchantFrame non esiste.")
    end
end

local function runVendorDump()
    local numFn, infoFn, linkFn, which = merchantApi()
    if not (numFn and infoFn) then
        -- Detto invece che taciuto: un no-op silenzioso qui si legge come
        -- "quel venditore non vende niente", e ci si torna a controllare.
        print("|cffff5555rrdump|r: API del venditore non trovata. Questo e' cio' che c'e':")
        printMerchantApi()
        return
    end
    local count = tonumber(safe(numFn)) or 0
    if count == 0 then
        print("rrdump: nessun venditore aperto (o non vende niente). API: " .. which)
        return
    end

    local guid = UnitGUID("npc") or UnitGUID("target")
    local npcID = guid and tonumber(string.match(guid, "-(%d+)-%x+$")) or nil
    local mapID, x, y = vendorPosition()
    local out = {
        at = date("%Y-%m-%d %H:%M:%S"),
        kind = "vendor",
        name = describe(UnitName("npc") or UnitName("target")),
        npcID = npcID,
        guid = describe(guid),
        zone = describe(GetRealZoneText and GetRealZoneText()),
        subZone = describe(GetSubZoneText and GetSubZoneText()),
        mapID = mapID,
        x = x,
        y = y,
        -- I quartermaster sono divisi per fazione e vendono gli stessi
        -- mestieri a entrambe: senza questo le due catture non si distinguono.
        faction = describe(UnitFactionGroup and UnitFactionGroup("player")),
        items = {},
    }

    local recipes, unread = 0, 0
    for index = 1, count do
        local link = linkFn and linkFn(index) or nil
        local row = merchantItem(infoFn, index)
        local isRecipe = linkIsRecipe(link)
        if isRecipe then recipes = recipes + 1 end
        local itemID = (link and tonumber(string.match(link, "item:(%d+)"))) or row.itemID
        -- Uno slot senza id e senza nome non e' uno slot vuoto: e' uno slot
        -- che il client non ha ancora risolto. Contarlo e dirlo e' la
        -- differenza tra accorgersene qui e accorgersene a casa.
        if not itemID and not row.name then unread = unread + 1 end
        out.items[#out.items + 1] = {
            itemID = itemID,
            raw = row.raw,
            name = describe(row.name),
            link = describe(link),
            price = row.price,
            quantity = row.quantity,
            available = row.available,
            -- Del costo non ci interessa l'importo: questi si pagano in
            -- valuta e quanto costino non e' il dato che stiamo raccogliendo.
            -- Il booleano resta perche' e' l'unica cosa che distingue un
            -- quartermaster da un venditore in oro senza sapere chi sia.
            extendedCost = row.extendedCost,
            isRecipe = isRecipe or nil,
        }
    end
    -- Quale forma dell'API ha risposto: la prossima volta che il client cambia
    -- sotto i piedi, l'archivio dice da dove veniva il dato.
    out.api = which

    local db = _G.RecipeRegistryDumpDB
    if type(db) ~= "table" then
        print("|cffff5555rrdump|r: RecipeRegistryDumpDB non pronto")
        return
    end
    if type(db.vendors) ~= "table" then db.vendors = {} end
    -- Per NPC, come i dump per mestiere. Ma NON sempre in sovrascrittura: qui
    -- si rilancia apposta per far risolvere gli slot mancanti, e una seconda
    -- cattura peggiore della prima -- meno slot letti, perche' il client ha
    -- scaricato la cache -- cancellerebbe quella buona. Vince chi ha meno
    -- slot non risolti. La chiave e' l'id quando c'e', perche' il nome e'
    -- localizzato e due NPC possono chiamarsi uguale.
    local key = tostring(npcID or out.name)
    local previous = db.vendors[key]
    out.unread = unread
    if type(previous) == "table" and (tonumber(previous.unread) or 0) < unread then
        print(string.format("rrdump: cattura precedente migliore (%d slot non letti contro %d), tenuta quella.",
            previous.unread, unread))
        return
    end
    db.vendors[key] = out

    print(string.format("|cff33ff99rrdump|r: %s -> %d oggetti%s. /reload per scriverlo su disco.",
        tostring(out.name), #out.items,
        x and string.format(", a %.1f %.1f in %s", x, y, tostring(out.zone)) or ""))
    if unread > 0 then
        -- Detto forte, perche' una cattura a meta' sembra una cattura.
        print(string.format("|cffff5555rrdump|r: %d slot su %d non ancora risolti dal client. Lascia la finestra aperta qualche secondo e rilancia /rrdump vendor.",
            unread, #out.items))
    end
end

SLASH_RRDUMP1 = "/rrdump"
SlashCmdList["RRDUMP"] = function(message)
    local argument = (message or ""):lower():match("^%s*(%a*)%s*$")
    if argument == "vendor" then
        local ok, err = pcall(runVendorDump)
        if not ok then print("rrdump: cattura del venditore fallita: " .. tostring(err)) end
        return
    end
    if argument == "api" then
        local numFn, infoFn, _linkFn, which = merchantApi()
        print("rrdump: API del venditore -> " .. which)
        print("rrdump: utilizzabile: " .. tostring(numFn ~= nil and infoFn ~= nil))
        printMerchantApi()
        return
    end
    if (message or ""):lower():match("^%s*status%s*$") then
        local names = {}
        local dumps = RecipeRegistryDumpDB and RecipeRegistryDumpDB.dumps or {}
        for name in pairs(dumps) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            print(string.format("rrdump: %s = %d ricette", name, #dumps[name].recipes))
        end
        if #names == 0 then print("rrdump: nessun mestiere raccolto in questa sessione.") end
        -- I venditori si contano perche' il giro ha un bersaglio noto: sette
        -- quartermaster per fazione, e sapere sul posto quanti ne mancano
        -- evita di scoprirlo dopo il volo di ritorno.
        local vendors, withRecipes = 0, 0
        for _, entry in pairs(RecipeRegistryDumpDB and RecipeRegistryDumpDB.vendors or {}) do
            vendors = vendors + 1
            for _, item in ipairs(entry.items or {}) do
                if item.isRecipe then withRecipes = withRecipes + 1 break end
            end
        end
        if vendors > 0 then
            print(string.format("rrdump: %d venditori raccolti, %d con ricette.", vendors, withRecipes))
        end
        return
    end
    local ok, err = pcall(runDump)
    if not ok then print("rrdump: raccolta fallita: " .. tostring(err)) end
end
