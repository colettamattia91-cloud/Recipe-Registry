local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local time = time
local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local TRACKED = Private.TRACKED
local countRecipeKeys = Private.countRecipeKeys
local detectSpecialization = Private.detectSpecialization
local extractItemID = Private.extractItemID
local extractSpellID = Private.extractSpellID
local isValidRecipeKey = Private.isValidRecipeKey
local newScanTelemetry = Private.newScanTelemetry
-- Set-difference compare on two recipe-key maps. Used by ApplyScanResult to
-- decide whether a scan actually altered the local recipe set; the old code
-- stored a pre-joined `prof.signature` in SavedVariables for the same
-- purpose, but that string was pure duplicated data and cost ~100s of KB
-- written to disk on every logout for medium guilds. Comparing the two key
-- sets directly is a few hundred hashtable lookups — negligible.
local function recipeSetDiffers(currentRecipes, nextRecipeKeys)
    if not currentRecipes then
        return next(nextRecipeKeys or {}) ~= nil
    end
    for key in pairs(nextRecipeKeys or {}) do
        if not currentRecipes[key] then
            return true
        end
    end
    for key in pairs(currentRecipes) do
        if not (nextRecipeKeys and nextRecipeKeys[key]) then
            return true
        end
    end
    return false
end

local function isManualScanReason(reason)
    local text = tostring(reason or "")
    return text == "manual" or text == "manual-rescan" or text == "manual-refresh"
end

local function resolveScanContext(opts)
    opts = opts or {}
    local reason = tostring(opts.reason or "manual")
    local notifyMode = tostring(opts.notifyMode or (isManualScanReason(reason) and "manual" or "auto"))
    return {
        reason = reason,
        notifyMode = notifyMode,
    }
end

local function debugSuppressedScan(self, context, message)
    if Addon.debugMode then
        Addon:Debug("Suppressed scan", tostring(context.reason), tostring(context.notifyMode), message)
    end
end

-- True when the created item maps to more than one crafting spell in the
-- metadata library (Gold Bar via Smelt Gold and Transmute: Iron to Gold;
-- the elemental transmute pairs). Stored as the item key alone, such rows
-- lose "which recipe does this crafter actually know".
local function isAmbiguousCreatedItem(itemID)
    local metadata = Addon.RecipeMetadata
    if not (metadata and metadata.NormalizeRecipeKey) then
        return false
    end
    local normalized = metadata:NormalizeRecipeKey(itemID)
    return normalized ~= nil and normalized.ambiguousSpellIds ~= nil
end

-- Returns the primary recipe key plus, for ambiguous created items, the
-- spell key from the recipe link as a second additive key. Both keys are
-- stored: the item key keeps old clients and existing peer replicas
-- converging (additive merge never removes keys), the spell key carries
-- the exact recipe so the UI can resolve reagents. Never swap the item
-- key for the spell key — replicas that already hold the item key would
-- stay one key richer than the owner block forever, producing the
-- endless fingerprint-mismatch re-pull loop the sync invariants forbid.
local function buildScannedRecipeKey(itemLink, recipeLink)
    local itemID, invalidItemID = extractItemID(itemLink)
    if invalidItemID then
        return invalidItemID
    end
    if itemID then
        local spellID = extractSpellID(recipeLink)
        if spellID and isAmbiguousCreatedItem(itemID) then
            return itemID, -spellID
        end
        return itemID
    end
    local spellID = extractSpellID(recipeLink)
    if spellID then
        return -spellID
    end
    return nil
end

function Data:ApplyLocalProfessionMetadata(profession, metadata)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[profession] or { recipes = {} }
    local oldSpecialization = prof.specialization
    local newSpecialization = metadata and metadata.specialization or nil
    local specializationChanged = oldSpecialization ~= newSpecialization

    prof.skillRank = metadata and (metadata.skillRank or 0) or prof.skillRank or 0
    prof.skillMaxRank = metadata and (metadata.skillMaxRank or 0) or prof.skillMaxRank or 0
    prof.specialization = newSpecialization
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    prof.lastSeenInGuildAt = time()
    entry.professions[profession] = self:NormalizeProfessionBlock(entry, profession, prof)

    if not specializationChanged then
        return false, oldSpecialization, newSpecialization
    end

    prof = entry.professions[profession]
    local changedAt = time()
    entry.updatedAt = changedAt
    prof.lastUpdatedAt = changedAt
    prof.lastSeenInGuildAt = entry.lastSeenInGuildAt or prof.lastUpdatedAt
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    entry.professions[profession] = self:NormalizeProfessionBlock(entry, profession, prof)
    if self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty(
            "specialization",
            self:BuildSyncBlockKey(self:GetPlayerKey(), profession)
        )
    end
    Addon:Debug(
        "Specialization changed",
        profession,
        tostring(oldSpecialization or "none"),
        "->",
        tostring(newSpecialization or "none")
    )
    return true, oldSpecialization, newSpecialization
end

-- I mestieri del personaggio, senza finestra.
--
-- Su un client classic questa lista si leggeva da GetNumSkillLines /
-- GetSkillLineInfo, cioe' dalla finestra abilita': un array piatto in cui i
-- mestieri stanno mescolati ad armi, lingue e intestazioni, da cui il filtro su
-- isHeader e su TRACKED. Su questo client quelle due funzioni non esistono --
-- confermato in gioco il 2026-09-18, "attempt to call a nil value" aprendo la
-- scheda mestieri -- e al loro posto c'e' GetProfessions(), che restituisce
-- direttamente gli indici dei mestieri appresi.
--
-- Il guadagno non e' la rinomina, e' che GetProfessionInfo risponde **a
-- finestra chiusa**: nome, rank e maxRank arrivano da una chiamata invece che
-- da una lista che esiste solo mentre un frame e' aperto. Quindi questa
-- funzione puo' girare al login, e non deve piu' aspettare che l'utente apra
-- qualcosa.
--
-- GetProfessions restituisce cinque valori posizionali -- i due mestieri
-- principali, archeologia, pesca, cucina -- e i buchi sono nil. Per questo la
-- tabella si attraversa con pairs e non con ipairs: ipairs si fermerebbe al
-- primo buco, e chi ha un mestiere solo perderebbe cucina.
function Data:DetectProfessions()
    self._currentProfs = {}
    local metadataChanged = false
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then
        Addon:Debug("DetectProfessions: GetProfessions/GetProfessionInfo non disponibili")
        return false
    end
    local primary, secondary, archaeology, fishing, cooking = GetProfessions()
    for _, professionIndex in pairs({ primary, secondary, archaeology, fishing, cooking }) do
        local name, _, skillRank, skillMaxRank = GetProfessionInfo(professionIndex)
        if name then
            local canonical = self:GetCanonicalProfession(name)
            if TRACKED[canonical] then
                local specialization = detectSpecialization(canonical)
                self._currentProfs[canonical] = {
                    skillRank = skillRank or 0,
                    skillMaxRank = skillMaxRank or 0,
                    specialization = specialization,
                }
                local entry = self:GetOrCreateMember(self:GetPlayerKey())
                local wasNewProfession = entry.professions[canonical] == nil
                entry.professions[canonical] = entry.professions[canonical] or { recipes = {} }
                local changed = self:ApplyLocalProfessionMetadata(canonical, self._currentProfs[canonical])
                metadataChanged = changed or metadataChanged
                if wasNewProfession and self.MarkSyncIndexDirty then
                    self:MarkSyncIndexDirty(
                        "detect-profession",
                        self:BuildSyncBlockKey(self:GetPlayerKey(), canonical)
                    )
                end
            end
        end
    end
    -- Chi cambia mestiere non deve restare due mestieri.
    --
    -- Prima di questa riga DetectProfessions sapeva solo aggiungere: chi
    -- abbandonava Alchemy per Engineering restava in gilda come alchimista per
    -- sempre, con le sue ricette, e nessuno se ne accorgeva. Quello che il
    -- personaggio ha adesso e' _currentProfs, e basta: tutto il resto del suo
    -- blocco se ne va, ricette e catalogo compresi.
    metadataChanged = self:PruneDroppedProfessions() or metadataChanged

    Addon:RequestRefresh("detect-professions")
    return metadataChanged
end

-- I mestieri che il personaggio non ha piu', tolti dal suo blocco e dal catalogo
-- salvato. Vale solo per il proprietario locale: di un compagno non sappiamo
-- cosa abbia abbandonato finche' non ce lo racconta lui.
function Data:PruneDroppedProfessions()
    local current = self._currentProfs
    if type(current) ~= "table" or not next(current) then
        -- nessun mestiere rilevato: puo' voler dire "non ne ha" oppure "l'API
        -- non ha ancora risposto", e non sono la stessa cosa. Nel dubbio non si
        -- cancella niente.
        return false
    end
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMembersDB()[playerKey]
    if type(entry) ~= "table" or type(entry.professions) ~= "table" then
        return false
    end

    local dropped = {}
    for professionKey in pairs(entry.professions) do
        if not current[professionKey] then
            dropped[#dropped + 1] = professionKey
        end
    end
    if #dropped == 0 then return false end

    local catalog = Addon.charDB and Addon.charDB.recipeCatalog
    for _, professionKey in ipairs(dropped) do
        entry.professions[professionKey] = nil
        if type(catalog) == "table" then
            catalog[professionKey] = nil
        end
        if self._scanNeededByProfession then self._scanNeededByProfession[professionKey] = nil end
        if self.MarkSyncIndexDirty then
            self:MarkSyncIndexDirty("profession-dropped", self:BuildSyncBlockKey(playerKey, professionKey))
        end
        Addon:Debug("Profession dropped, block removed:", professionKey)
    end
    return true
end

function Data:EnsureScanState()
    self._scanNeededByProfession = self._scanNeededByProfession or {}
    self._genericScanAttempts = self._genericScanAttempts or {}
    if type(self._scanTelemetry) ~= "table" then
        self._scanTelemetry = newScanTelemetry()
    end
end

function Data:RecordScanTelemetry(field, amount)
    self:EnsureScanState()
    self._scanTelemetry[field] = (self._scanTelemetry[field] or 0) + (amount or 1)
end

function Data:RecordInvalidRecipeKey(recipeKey, context, memberKey, profession)
    self:EnsureScanState()
    local t = self._scanTelemetry
    t.invalidRecipesBlocked = (t.invalidRecipesBlocked or 0) + 1
    if context == "snapshot" then
        t.invalidRecipesSnapshot = (t.invalidRecipesSnapshot or 0) + 1
    elseif context == "inbound" then
        t.invalidRecipesInbound = (t.invalidRecipesInbound or 0) + 1
    elseif context == "clean" then
        t.invalidRecipesCleaned = (t.invalidRecipesCleaned or 0) + 1
    elseif context == "scan" then
        t.invalidRecipesScan = (t.invalidRecipesScan or 0) + 1
    end
    t.lastInvalidRecipeKey = recipeKey
    t.lastInvalidRecipeContext = context
    t.lastInvalidRecipeMember = memberKey
    t.lastInvalidRecipeProfession = profession
end

function Data:MarkScanNeeded(profession, reason)
    self:EnsureScanState()
    local context = resolveScanContext({ reason = reason })
    local canonical = profession and self:GetCanonicalProfession(profession) or nil
    if canonical and TRACKED[canonical] then
        self._scanNeededByProfession[canonical] = context.reason
    else
        self._genericScanNeeded = context.reason
        self._genericScanAttempts = {}
    end
    self._scanNeeded = true
    self:RecordScanTelemetry("signals")
    self._scanTelemetry.lastScanReason = context.reason
    self._scanTelemetry.lastScanNotifyMode = context.notifyMode
    if context.reason == "recipe-learned" then
        self:RecordScanTelemetry("scanTriggeredRecipeLearned")
    elseif isManualScanReason(context.reason) then
        self:RecordScanTelemetry("scanTriggeredManual")
    end
end

function Data:HasScanPending(profession)
    self:EnsureScanState()
    local canonical = profession and self:GetCanonicalProfession(profession) or nil
    if canonical and self._scanNeededByProfession[canonical] then
        return true
    end
    if self._genericScanNeeded ~= nil then
        return true
    end
    return self._scanNeeded == true and next(self._scanNeededByProfession) == nil
end

function Data:HasAnyScanPending()
    self:EnsureScanState()
    if self._genericScanNeeded ~= nil then
        return true
    end
    return next(self._scanNeededByProfession) ~= nil
end

function Data:SyncLegacyScanFlag()
    self._scanNeeded = self:HasAnyScanPending()
end

function Data:CompleteScanAttempt(result)
    if not result or not result.profession then return end
    self:EnsureScanState()
    if not result.valid or result.suspectedPartial then
        self:SyncLegacyScanFlag()
        return
    end

    local hadGenericPending = self._genericScanNeeded ~= nil
        or (self._scanNeeded == true and next(self._scanNeededByProfession) == nil)
    local genericReason = self._genericScanNeeded
    self._scanNeededByProfession[result.profession] = nil
    if hadGenericPending then
        if result.changed or isManualScanReason(genericReason) or genericReason == nil then
            self._genericScanNeeded = nil
            self._genericScanAttempts = {}
        else
            self._genericScanAttempts[result.profession] = true
        end
    end
    self:SyncLegacyScanFlag()
end

function Data:MakeScanResult(profession, opts)
    opts = opts or {}
    return {
        profession = profession,
        changed = opts.changed == true,
        valid = opts.valid == true,
        skipped = opts.skipped == true,
        failed = opts.failed == true,
        skipReason = opts.skipReason,
        count = opts.count or 0,
        previousCount = opts.previousCount or 0,
        suspectedPartial = opts.suspectedPartial == true,
        reason = opts.reason,
        notifyMode = opts.notifyMode,
    }
end

function Data:SkipScan(profession, reason, previousCount, opts)
    self:EnsureScanState()
    local context = resolveScanContext(opts)
    self:RecordScanTelemetry("scansSkipped")
    self._scanTelemetry.lastProfession = profession
    self._scanTelemetry.lastSkipReason = reason
    self._scanTelemetry.lastScanReason = context.reason
    self._scanTelemetry.lastScanNotifyMode = context.notifyMode
    return self:MakeScanResult(profession, {
        skipped = true,
        skipReason = reason,
        previousCount = previousCount or 0,
        reason = context.reason,
        notifyMode = context.notifyMode,
    })
end

function Data:GetScanTelemetry()
    self:EnsureScanState()
    return self._scanTelemetry
end

function Data:ResetScanTelemetry()
    self._scanTelemetry = newScanTelemetry()
end

function Data:DumpScanStatus()
    local scan = self:GetScanTelemetry()
    Addon:SystemPrint(string.format(
        "Scan signals=%d started=%d changed=%d unchanged=%d skipped=%d failed=%d partial=%d invalid=%d pending=%s last=%s/%s reason=%s notify=%s autoSuppressed=%d skillSkips=%d/%d",
        scan.signals or 0,
        scan.scansStarted or 0,
        scan.scansChanged or 0,
        scan.scansUnchanged or 0,
        scan.scansSkipped or 0,
        scan.scansFailed or 0,
        scan.suspectedPartial or 0,
        scan.invalidRecipesBlocked or 0,
        tostring(self:HasAnyScanPending()),
        tostring(scan.lastProfession or "none"),
        tostring(scan.lastSkipReason or "none"),
        tostring(scan.lastScanReason or "none"),
        tostring(scan.lastScanNotifyMode or "none"),
        scan.scanAutoSuppressedUnchanged or 0,
        scan.scanSkippedWeaponSkill or 0,
        scan.scanSkippedGenericSkill or 0
    ))
    if (scan.invalidRecipesBlocked or 0) > 0 then
        Addon:SystemPrint(string.format(
            "Recipe validation snapshot=%d inbound=%d cleaned=%d last=%s/%s/%s/%s",
            scan.invalidRecipesSnapshot or 0,
            scan.invalidRecipesInbound or 0,
            scan.invalidRecipesCleaned or 0,
            tostring(scan.lastInvalidRecipeContext or "none"),
            tostring(scan.lastInvalidRecipeKey or "none"),
            tostring(scan.lastInvalidRecipeMember or "none"),
            tostring(scan.lastInvalidRecipeProfession or "none")
        ))
    end
end

-- Quale mestiere sta rispondendo adesso.
--
-- C_TradeSkillUI espone UNA sorgente dati alla volta: GetAllRecipeIDs elenca il
-- mestiere "corrente", che cambia quando l'utente ne apre uno e sopravvive al
-- /reload. Verificato in gioco il 2026-09-18: aperta Cooking, la lista passa da
-- 197 righe (Alchemy) a 132, e resta Cooking anche dopo un reload in cui non si
-- apre nulla.
--
-- Non esiste un modo pulito di sceglierlo da codice. Provati e scartati:
-- SetProfessionChildSkillLineID accetta la chiamata e non sposta niente,
-- GetProfessionSpells torna vuota, e OpenTradeSkill viene bloccata -- e comunque
-- aprire finestre addosso all'utente non e' una cosa che facciamo.
--
-- GetBaseProfessionInfo e' la fonte ovvia ma non e' affidabile: a finestra
-- chiusa risponde professionName = "" pur essendoci una lista valida. Per
-- questo la seconda strada e' quella buona -- GetProfessionInfoByRecipeID su una
-- ricetta qualunque della lista dice di chi e', e ha risposto correttamente
-- "Cooking" proprio nei casi in cui GetBaseProfessionInfo taceva.
local function activeProfessionName()
    local CT = _G.C_TradeSkillUI
    if not CT then return nil end
    local base = type(CT.GetBaseProfessionInfo) == "function" and CT.GetBaseProfessionInfo()
    if type(base) == "table" and type(base.professionName) == "string" and base.professionName ~= "" then
        return base.professionName
    end
    if type(CT.GetAllRecipeIDs) ~= "function" or type(CT.GetProfessionInfoByRecipeID) ~= "function" then
        return nil
    end
    local ids = CT.GetAllRecipeIDs()
    if type(ids) ~= "table" or not ids[1] then return nil end
    local info = CT.GetProfessionInfoByRecipeID(ids[1])
    if type(info) ~= "table" then return nil end
    -- il mestiere "padre" e' quello con il nome che conosciamo: la ricetta
    -- risponde professionID 2939 / parentProfessionID 185, e 185 e' Cooking
    local name = info.parentProfessionName
    if type(name) ~= "string" or name == "" then name = info.professionName end
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

function Data:GetActiveTradeSkillProfession()
    local title = activeProfessionName()
    if not title or title == "" or title == "UNKNOWN" then
        return nil, "trade-no-title"
    end
    local canonical = self:GetCanonicalProfession(title)
    if not TRACKED[canonical] then
        return canonical, "trade-untracked"
    end
    return canonical
end

function Data:CanScanTradeSkillData()
    local canonical, reason = self:GetActiveTradeSkillProfession()
    if not canonical then
        return false, reason or "trade-no-title", canonical
    end
    if reason then
        return false, reason, canonical
    end
    local CT = _G.C_TradeSkillUI
    if not CT or type(CT.GetAllRecipeIDs) ~= "function" or type(CT.GetRecipeInfo) ~= "function" then
        return false, "trade-api-missing", canonical
    end
    -- Il cancello che conta, e che costa il guadagno piu' vistoso di questa
    -- riscrittura.
    --
    -- A sessione chiusa GetAllRecipeIDs risponde comunque, e risponde bene: 197
    -- righe, quelle giuste, quelle dell'ultimo mestiere aperto. Ma non e' una
    -- sorgente viva, e' cio' che e' rimasto dell'ultima volta -- lo dicono tre
    -- cose insieme: GetBaseProfessionInfo torna vuoto, IsTradeSkillReady torna
    -- false, e il catalogo resta quello del mestiere aperto per ultimo anche
    -- dopo un /reload.
    --
    -- Era allettante scansionare comunque, al login, senza chiedere niente
    -- all'utente. Ma registrare uno snapshot vecchio come verita' e' il danno
    -- peggiore che questo addon possa fare: dichiara alla gilda che sai fare
    -- cose che magari non sai piu', o tace su quelle che hai imparato dopo, e
    -- lo fa senza un errore da nessuna parte. Quindi si legge solo quando il
    -- client conferma che la sessione e' viva.
    if type(CT.IsTradeSkillReady) == "function" and not CT.IsTradeSkillReady() then
        return false, "trade-session-closed", canonical
    end
    -- Non e' detto che la finestra aperta sia la tua.
    --
    -- Cliccando il mestiere che un compagno ha linkato in chat si apre la
    -- finestra con le SUE ricette, e da fuori e' identica: stessa API, stessi
    -- ID, TRADE_SKILL_SHOW che scatta regolarmente. Senza questa guardia la
    -- scansione le registrerebbe come tue e il sync le pubblicherebbe alla
    -- gilda a tuo nome -- dati sbagliati su di te, prodotti da un gesto
    -- innocuo, e nessun modo di accorgersene dopo.
    --
    -- Stessa cosa per il mestiere di gilda e per la lavorazione presso un PNG:
    -- in tutti e tre i casi la lista che il client espone non descrive questo
    -- personaggio.
    if type(CT.IsTradeSkillLinked) == "function" and CT.IsTradeSkillLinked() then
        return false, "trade-linked", canonical
    end
    if type(CT.IsTradeSkillGuild) == "function" and CT.IsTradeSkillGuild() then
        return false, "trade-guild", canonical
    end
    if type(CT.IsNPCCrafting) == "function" and CT.IsNPCCrafting() then
        return false, "trade-npc", canonical
    end
    local ids = CT.GetAllRecipeIDs()
    if type(ids) ~= "table" or #ids <= 0 then
        return false, "trade-data-not-ready", canonical
    end
    return true, nil, canonical, ids
end

-- Il contesto non e' piu' "quale frame e' visibile".
--
-- ProfessionsFrame viene creato solo la prima volta che l'utente apre un
-- mestiere: a freddo e' nil, e testarne l'esistenza direbbe "nessun mestiere"
-- mentre la lista risponde benissimo. Quello che conta e' se c'e' una sorgente
-- dati leggibile, non se c'e' una finestra aperta.
function Data:GetVisibleTrackedProfessionContext()
    local canonical, reason = self:GetActiveTradeSkillProfession()
    if canonical and not reason then
        return canonical, "trade", nil
    end
    if canonical then
        return nil, "trade", reason
    end
    return nil, nil, reason or "no-trade-skill-data"
end

-- Il catalogo di un mestiere: tutti i suoi recipeID, appresi o no.
--
-- Si puo' leggere solo con una sessione viva, ed e' l'unica cosa per cui quella
-- sessione serva ancora. Salvato per personaggio in CharDB, fuori dal database
-- di gilda: e' dato di gioco, non contenuto da condividere. In sovrascrittura,
-- perche' l'elenco valido e' quello che il client dice adesso.
-- Nel catalogo va la CHIAVE gia' calcolata, non solo l'ID.
--
-- La chiave si ricava da GetRecipeItemLink e GetRecipeLink, e quelle rispondono
-- sulle ricette del mestiere corrente. Al login il mestiere corrente e' uno
-- solo, quindi calcolarle allora funzionerebbe per uno e fallirebbe in silenzio
-- per gli altri tre. Calcolate qui, mentre la sessione e' viva, la scansione dal
-- libro non dipende piu' da quelle API: le basta sapere quali ID sono appresi.
function Data:StoreRecipeCatalog(profession, entries)
    if not profession or type(entries) ~= "table" or #entries == 0 then return false end
    local charDB = Addon.charDB
    if type(charDB) ~= "table" then return false end
    if type(charDB.recipeCatalog) ~= "table" then charDB.recipeCatalog = {} end
    charDB.recipeCatalog[profession] = entries
    Addon:Debug("Recipe catalog stored:", profession, #entries, "recipes")
    return true
end

function Data:GetRecipeCatalog(profession)
    local charDB = Addon.charDB
    local catalog = type(charDB) == "table" and charDB.recipeCatalog or nil
    local stored = type(catalog) == "table" and catalog[profession] or nil
    if type(stored) == "table" and #stored > 0 then return stored end
    return nil
end

-- Cosa il personaggio sa fare, senza aprire niente.
--
-- Il libro degli incantesimi non ELENCA le ricette -- sotto la riga di un
-- mestiere c'e' solo la sua abilita', verificato in gioco il 2026-09-18 -- ma
-- C_SpellBook.IsSpellKnown sa rispondere su una ricetta: true sui tre elisir
-- appresi del personaggio di prova, false sulle due che non conosceva. E'
-- l'oracolo che mancava. Attenzione a non confonderlo con il globale
-- IsSpellKnown, che su quegli stessi ID risponde false a tutti.
--
-- Quindi: il catalogo dice cosa chiedere, l'oracolo dice cosa sai. La coppia
-- copre tutti i mestieri in una volta, al login, senza toccare la UI.
--
-- Il limite, e va detto invece che scoperto: una ricetta introdotta da una
-- patch nuova non e' nel catalogo salvato, quindi resta invisibile finche' non
-- si riapre quel mestiere una volta. Il buco si chiude da solo la prima volta
-- che ci si lavora, ed e' il motivo per cui questa non sostituisce la scansione
-- dalla sessione: la affianca.
function Data:ScanKnownFromSpellBook(opts)
    self:EnsureScanState()
    local context = resolveScanContext(opts)
    local CSB = _G.C_SpellBook
    if type(CSB) ~= "table" or type(CSB.IsSpellKnown) ~= "function" then
        return self:SkipScan(nil, "spellbook-api-missing", nil, context)
    end
    local current = self._currentProfs
    if type(current) ~= "table" or not next(current) then
        return self:SkipScan(nil, "no-professions", nil, context)
    end

    local scanned, changedAny = 0, false
    for profession in pairs(current) do
        local catalog = self:GetRecipeCatalog(profession)
        if catalog then
            local recipes = {}
            for i = 1, #catalog do
                local row = catalog[i]
                local recipeID = type(row) == "table" and row.id or nil
                if recipeID then
                    local ok, known = pcall(CSB.IsSpellKnown, recipeID)
                    if ok and known then
                        if isValidRecipeKey(row.key) then recipes[row.key] = true end
                        if isValidRecipeKey(row.variant) then recipes[row.variant] = true end
                    end
                end
            end
            if next(recipes) then
                local result = self:ApplyScanResult(profession, recipes, context)
                scanned = scanned + 1
                if result and result.changed then changedAny = true end
            end
        end
    end

    if scanned == 0 then
        return self:SkipScan(nil, "no-catalog", nil, context)
    end
    return self:MakeScanResult(nil, {
        valid = true,
        changed = changedAny,
        count = scanned,
        reason = context.reason,
        notifyMode = context.notifyMode,
    })
end

-- Il dataset nomina i mestieri con la chiave minuscola ("first_aid"), TRACKED
-- con l'etichetta ("First Aid"). Questa e' la traduzione, e serve solo quando
-- il client non risponde e si ricade sul dataset.
local PROFESSION_LABEL_BY_KEY = {}
for label in pairs(TRACKED) do
    PROFESSION_LABEL_BY_KEY[tostring(label):lower():gsub("[^%a%d]", "")] = label
end
PROFESSION_LABEL_BY_KEY["first_aid"] = "First Aid"

-- Una ricetta appena imparata, risolta da sola.
--
-- NEW_RECIPE_LEARNED porta con se' il recipeID, e su questo client tanto basta:
-- GetRecipeSchematic e GetRecipeItemLink rispondono per un ID qualunque, anche
-- di un mestiere che il personaggio non ha -- verificato il 2026-09-18 chiedendo
-- una ricetta di Alchemy dopo averla dimenticata, e il client ha risposto
-- ugualmente con nome e oggetto prodotto. Non sono legate alla sessione aperta.
--
-- Quindi non serve ne' aprire il mestiere ne' consultare il dataset: impari una
-- ricetta in un dungeon e finisce nel database e nel sync in pochi secondi,
-- dove sei. Prima di oggi l'addon si limitava a segnarsi un promemoria e a
-- chiedere all'utente di aprire il pannello -- era l'unica cosa possibile su un
-- client classic, dove la lista viveva dentro la finestra.
--
-- IsSpellKnown fa da conferma: l'evento dice "e' successo qualcosa", l'oracolo
-- dice "questa ricetta adesso la sai". Senza, un evento spurio scriverebbe nel
-- database una ricetta che non hai, e il sync la pubblicherebbe.
function Data:LearnRecipeFromSignal(recipeID, reason)
    recipeID = tonumber(recipeID)
    if not recipeID then return false, "no-recipe-id" end
    local CT = _G.C_TradeSkillUI
    if type(CT) ~= "table" then return false, "trade-api-missing" end

    -- L'oracolo non e' facoltativo. Scritto com'era, la conferma saltava in due
    -- casi -- API assente, e pcall fallita, perche' "ok and not known" e' falso
    -- anche quando ok e' falso -- e in entrambi si finiva a scrivere nel
    -- database su un evento e basta. Se l'oracolo non risponde si rinuncia: la
    -- ricetta la prendera' la scansione dalla finestra, piu' tardi e sicura.
    -- ScanKnownFromSpellBook si comporta gia' cosi'.
    local CSB = _G.C_SpellBook
    if type(CSB) ~= "table" or type(CSB.IsSpellKnown) ~= "function" then
        return false, "spellbook-api-missing"
    end
    local confirmed, known = pcall(CSB.IsSpellKnown, recipeID)
    if not confirmed then return false, "spellbook-error" end
    if not known then return false, "not-known" end

    -- Prima il client, poi il dataset.
    --
    -- Il client e' la fonte aggiornata: conosce anche le ricette che una patch
    -- ha aggiunto dopo che il dataset e' stato generato, e su questo client
    -- risponde per un ID qualunque. Il dataset e' la rete per quando non
    -- risponde: le stesse due informazioni -- di che mestiere e' e cosa produce
    -- -- le ha gia' dentro, quindi non serve nessuna scansione in nessuno dei
    -- due casi.
    local info = type(CT.GetProfessionInfoByRecipeID) == "function"
        and CT.GetProfessionInfoByRecipeID(recipeID) or nil
    local professionName = type(info) == "table"
        and (info.parentProfessionName or info.professionName) or nil

    local record
    local metadata = Addon.RecipeMetadata
    if type(metadata) == "table" and metadata.GetRecipeInfo then
        local okRecord, found = pcall(metadata.GetRecipeInfo, metadata, -recipeID)
        record = okRecord and found or nil
    end
    if (type(professionName) ~= "string" or professionName == "") and type(record) == "table" then
        professionName = PROFESSION_LABEL_BY_KEY[record.profession] or record.profession
    end

    if type(professionName) ~= "string" or professionName == "" then
        return false, "no-profession"
    end
    local canonical = self:GetCanonicalProfession(professionName)
    if not TRACKED[canonical] then return false, "untracked" end

    local recipeKey, variantSpellKey = buildScannedRecipeKey(
        type(CT.GetRecipeItemLink) == "function" and CT.GetRecipeItemLink(recipeID) or nil,
        type(CT.GetRecipeLink) == "function" and CT.GetRecipeLink(recipeID) or nil
    )
    if not isValidRecipeKey(recipeKey) and type(record) == "table" then
        -- dal dataset: l'oggetto prodotto, o lo spell negativo se non ne produce
        recipeKey = record.createdItemId or -recipeID
        variantSpellKey = nil
    end
    if not isValidRecipeKey(recipeKey) then
        self:RecordInvalidRecipeKey(recipeKey, "learned", self:GetPlayerKey(), canonical)
        return false, "invalid-key"
    end

    local playerKey = self:GetPlayerKey()
    local entry = self:GetOrCreateMember(playerKey)
    local prof = entry.professions[canonical]
    if not prof then
        -- il mestiere non e' ancora nel blocco: lo crea DetectProfessions, che
        -- gira su questo stesso segnale. Qui si evita di inventarne uno a meta'.
        return false, "profession-not-detected"
    end

    prof.recipes = prof.recipes or {}
    local added = false
    if not prof.recipes[recipeKey] then prof.recipes[recipeKey] = true; added = true end
    if variantSpellKey and isValidRecipeKey(variantSpellKey) and not prof.recipes[variantSpellKey] then
        prof.recipes[variantSpellKey] = true
        added = true
    end
    if not added then return false, "already-known" end

    prof.count = countRecipeKeys(prof.recipes)
    prof.lastUpdatedAt = time()
    entry.updatedAt = prof.lastUpdatedAt
    if self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty(reason or "recipe-learned", self:BuildSyncBlockKey(playerKey, canonical))
    end
    Addon:Debug("Recipe learned and resolved:", canonical, recipeKey, "from", recipeID)
    return true, nil, canonical, recipeKey
end

-- La scansione.
--
-- Su un client classic erano centocinquanta righe, e quasi tutte esistevano per
-- aggirare il fatto che i dati vivessero dentro una lista di UI: spegnere i
-- filtri dell'utente e rimetterli, espandere le intestazioni e ricollassarle,
-- saltare le righe header dentro l'array piatto. Niente di tutto questo esiste
-- qui. C_TradeSkillUI espone ID di ricetta, non righe di lista, e non c'e'
-- niente da aprire perche' niente e' nascosto.
--
-- Quello che resta e' il mestiere vero: prendi gli ID, tieni quelli appresi,
-- costruisci la chiave. GetAllRecipeIDs restituisce il CATALOGO del mestiere --
-- tutte le sue ricette, apprese o no: su Alchemy a livello 1 sono 197 righe di
-- cui 3 tue. Quindi il filtro su info.learned non e' un dettaglio, e' la
-- scansione: senza, dichiareremmo alla gilda di saper fare tutto.
--
-- La chiave di ricetta non cambia rispetto a TBC, ed e' il motivo per cui wire,
-- SavedVariables e fingerprint non si accorgono di questa riscrittura:
-- GetRecipeItemLink da' un |Hitem:...| e GetRecipeLink un |Henchant:...|, che
-- extractItemID ed extractSpellID leggono gia' entrambi.
function Data:ScanTradeSkill(opts)
    self:EnsureScanState()
    local context = resolveScanContext(opts)
    local canScan, reason, canonical, recipeIDs = self:CanScanTradeSkillData()
    if not canScan then
        return self:SkipScan(canonical, reason or "trade-data-not-ready", nil, context)
    end

    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[canonical]
    local hasData = prof and prof.count and prof.count > 0
    if hasData and not self:HasScanPending(canonical) then
        return self:SkipScan(canonical, "cached", prof.count or 0, context)
    end

    self:RecordScanTelemetry("scansStarted")
    self._scanTelemetry.lastProfession = canonical
    self._scanTelemetry.lastSkipReason = nil
    self._scanTelemetry.lastScanReason = context.reason
    self._scanTelemetry.lastScanNotifyMode = context.notifyMode

    local CT = _G.C_TradeSkillUI
    local recipes = {}
    local catalog = {}
    local ok, err = pcall(function()
        for i = 1, #recipeIDs do
            local recipeID = recipeIDs[i]
            local info = CT.GetRecipeInfo(recipeID)
            if type(info) == "table" then
                -- la chiave si calcola per TUTTE, anche per le non apprese: e'
                -- cio' che finisce nel catalogo, e serve a riconoscerle il
                -- giorno che le imparerai, quando questa sessione non ci sara'
                local recipeKey, variantSpellKey = buildScannedRecipeKey(
                    CT.GetRecipeItemLink(recipeID),
                    CT.GetRecipeLink(recipeID)
                )
                if isValidRecipeKey(recipeKey) then
                    local entry = { id = recipeID, key = recipeKey, variant = variantSpellKey }
                    catalog[#catalog + 1] = entry
                    if info.learned then
                        recipes[recipeKey] = true
                        if variantSpellKey and isValidRecipeKey(variantSpellKey) then
                            recipes[variantSpellKey] = true
                        end
                    end
                elseif info.learned then
                    self:RecordInvalidRecipeKey(recipeKey, "scan", self:GetPlayerKey(), canonical)
                    Addon:Debug("Blocked invalid recipe from TradeSkill scan:", recipeKey, "profession:", canonical)
                end
            end
        end
    end)

    -- Il catalogo si salva solo se il giro e' arrivato in fondo: uno a meta'
    -- sarebbe peggio di nessuno, perche' al login sembrerebbe completo.
    if ok then
        self:StoreRecipeCatalog(canonical, catalog)
    end

    if not ok then
        self:RecordScanTelemetry("scansFailed")
        self._scanTelemetry.lastScanReason = context.reason
        self._scanTelemetry.lastScanNotifyMode = context.notifyMode
        if context.notifyMode == "manual" then
            Addon:Print("Trade skill scan failed: " .. tostring(err))
        else
            Addon:Debug("Trade skill scan failed:", tostring(err), "reason:", context.reason)
        end
        return self:MakeScanResult(canonical, {
            valid = false,
            failed = true,
            skipReason = "trade-scan-failed",
            previousCount = prof and prof.count or 0,
            reason = context.reason,
            notifyMode = context.notifyMode,
        })
    end

    return self:ApplyScanResult(canonical, recipes, context)
end

function Data:WarnSuspiciousScan(profession, previousCount, count)
    self._lastPartialScanWarning = self._lastPartialScanWarning or {}
    local now = time()
    local last = self._lastPartialScanWarning[profession] or 0
    if now - last >= 60 then
        self._lastPartialScanWarning[profession] = now
        Addon:SystemPrint(string.format(
            "Skipped %s scan: found %d recipe(s), keeping existing owner data with %d. Reopen the profession to retry.",
            tostring(profession),
            count or 0,
            previousCount or 0
        ))
    else
        Addon:Debug("Skipped suspicious partial scan", profession, "new", count or 0, "old", previousCount or 0)
    end
end

function Data:ApplyScanResult(profession, recipeKeys, opts)
    local context = resolveScanContext(opts)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[profession] or { recipes = {} }
    local recipeChanged = recipeSetDiffers(prof.recipes, recipeKeys)
    local previousCount = prof.count or countRecipeKeys(prof.recipes)
    local count = countRecipeKeys(recipeKeys)
    local oldSpecialization = prof.specialization

    if previousCount > 0 and count < previousCount then
        self:RecordScanTelemetry("suspectedPartial")
        prof.lastScanAttempt = time()
        prof.lastScanSkipReason = "suspected-partial"
        entry.professions[profession] = prof
        self:WarnSuspiciousScan(profession, previousCount, count)
        local result = self:MakeScanResult(profession, {
            valid = true,
            changed = false,
            count = count,
            previousCount = previousCount,
            suspectedPartial = true,
            skipReason = "suspected-partial",
            reason = context.reason,
            notifyMode = context.notifyMode,
        })
        self:CompleteScanAttempt(result)
        return result
    end

    prof.recipes = {}
    for recipeKey in pairs(recipeKeys or {}) do
        prof.recipes[recipeKey] = true
    end
    prof.signature = nil  -- legacy field; nil-out so SavedVariables sheds it on next save
    prof.count = count
    prof.lastScan = time()
    prof.lastUpdatedAt = prof.lastScan
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    prof.lastSeenInGuildAt = prof.lastScan

    if self._currentProfs[profession] then
        prof.skillRank = self._currentProfs[profession].skillRank or 0
        prof.skillMaxRank = self._currentProfs[profession].skillMaxRank or 0
        prof.specialization = self._currentProfs[profession].specialization
    end
    local specializationChanged = oldSpecialization ~= prof.specialization
    local changed = recipeChanged or specializationChanged

    entry.professions[profession] = prof
    self._scanTelemetry.lastScanReason = context.reason
    self._scanTelemetry.lastScanNotifyMode = context.notifyMode

    if changed then
        self:RecordScanTelemetry("scansChanged")
        entry.updatedAt = prof.lastScan
        if self.MarkSyncIndexDirty then
            self:MarkSyncIndexDirty(
                specializationChanged and not recipeChanged and "specialization-scan" or "scan",
                self:BuildSyncBlockKey(self:GetPlayerKey(), profession)
            )
        end
        if recipeChanged then
            Addon:Debug("Scan changed", profession, count, "recipe ids")
        else
            Addon:Debug(
                "Scan specialization changed",
                profession,
                tostring(oldSpecialization or "none"),
                "->",
                tostring(prof.specialization or "none")
            )
        end
        if context.notifyMode == "manual" then
            if recipeChanged then
                Addon:Print(string.format("Scanned %s: %d recipe(s) found.", profession, count))
            else
                Addon:Print(string.format(
                    "Scanned %s: specialization updated to %s.",
                    profession,
                    tostring(prof.specialization or "none")
                ))
            end
        else
            debugSuppressedScan(self, context, string.format(
                "%s changed (%d recipe(s))",
                tostring(profession),
                count
            ))
        end
    else
        self:RecordScanTelemetry("scansUnchanged")
        if context.notifyMode == "manual" then
            Addon:Print(string.format("Scanned %s: unchanged (%d recipe(s)).", profession, count))
        else
            self:RecordScanTelemetry("scanAutoSuppressedUnchanged")
            debugSuppressedScan(self, context, string.format(
                "%s unchanged (%d recipe(s))",
                tostring(profession),
                count
            ))
        end
    end

    self:InvalidateRecipeCaches()
    Addon:RequestRefresh("scan")
    local result = self:MakeScanResult(profession, {
        valid = true,
        changed = changed,
        count = count,
        previousCount = previousCount,
        reason = context.reason,
        notifyMode = context.notifyMode,
    })
    self:CompleteScanAttempt(result)
    return result
end
