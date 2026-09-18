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

SLASH_RRDUMP1 = "/rrdump"
SlashCmdList["RRDUMP"] = function(message)
    if (message or ""):lower():match("^%s*status%s*$") then
        local names = {}
        local dumps = RecipeRegistryDumpDB and RecipeRegistryDumpDB.dumps or {}
        for name in pairs(dumps) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            print(string.format("rrdump: %s = %d ricette", name, #dumps[name].recipes))
        end
        if #names == 0 then print("rrdump: nessun mestiere raccolto in questa sessione.") end
        return
    end
    local ok, err = pcall(runDump)
    if not ok then print("rrdump: raccolta fallita: " .. tostring(err)) end
end
