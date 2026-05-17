local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local GetNumSkillLines = GetNumSkillLines
local GetSkillLineInfo = GetSkillLineInfo
local GetNumTradeSkills = GetNumTradeSkills
local GetTradeSkillInfo = GetTradeSkillInfo
local GetTradeSkillItemLink = GetTradeSkillItemLink
local GetTradeSkillRecipeLink = GetTradeSkillRecipeLink
local ExpandTradeSkillSubClass = ExpandTradeSkillSubClass
local GetTradeSkillLine = GetTradeSkillLine
local GetNumCrafts = GetNumCrafts
local GetCraftInfo = GetCraftInfo
local GetCraftItemLink = GetCraftItemLink
local GetCraftRecipeLink = GetCraftRecipeLink
local GetCraftSkillLine = GetCraftSkillLine
local GetCraftDisplaySkillLine = GetCraftDisplaySkillLine
local time = time
local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local TRACKED = Private.TRACKED
local clearCraftFilters = Private.clearCraftFilters
local clearTradeSkillFilters = Private.clearTradeSkillFilters
local countRecipeKeys = Private.countRecipeKeys
local detectSpecialization = Private.detectSpecialization
local extractItemID = Private.extractItemID
local extractSpellID = Private.extractSpellID
local isSubsetOf = Private.isSubsetOf
local isValidRecipeKey = Private.isValidRecipeKey
local newScanTelemetry = Private.newScanTelemetry
local restoreCraftFilters = Private.restoreCraftFilters
local restoreTradeSkillFilters = Private.restoreTradeSkillFilters
local snapshotCraftFilters = Private.snapshotCraftFilters
local snapshotTradeSkillFilters = Private.snapshotTradeSkillFilters
local stableRecipeSignature = Private.stableRecipeSignature

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

    local newRev = self:TouchLocalRevision("specialization:" .. tostring(profession))
    prof = entry.professions[profession]
    prof.blockRevision = newRev or prof.blockRevision
    prof.lastUpdatedAt = entry.updatedAt or time()
    prof.lastSeenInGuildAt = entry.lastSeenInGuildAt or prof.lastUpdatedAt
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    entry.professions[profession] = self:NormalizeProfessionBlock(entry, profession, prof)
    if self.MarkSyncIndexDirty then
        self:MarkSyncIndexDirty("specialization")
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

function Data:DetectProfessions()
    self._currentProfs = {}
    local metadataChanged = false
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and name then
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
                    self:MarkSyncIndexDirty("detect-profession")
                end
            end
        end
    end
    Addon:RequestRefresh("detect-professions")
    return metadataChanged
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

function Data:GetActiveTradeSkillProfession()
    local title = GetTradeSkillLine and GetTradeSkillLine()
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
    if type(GetNumTradeSkills) ~= "function" or type(GetTradeSkillInfo) ~= "function" then
        return false, "trade-api-missing", canonical
    end
    local numSkills = GetNumTradeSkills()
    if type(numSkills) ~= "number" or numSkills <= 0 then
        return false, "trade-data-not-ready", canonical
    end
    return true, nil, canonical, numSkills
end

function Data:GetActiveCraftProfession()
    local title = GetCraftSkillLine and GetCraftSkillLine(1)
    if not title or title == "" or title == "UNKNOWN" then
        title = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
    end
    if not title or title == "" or title == "UNKNOWN" then
        return nil, "craft-no-title"
    end
    local canonical = self:GetCanonicalProfession(title)
    if canonical ~= "Enchanting" then
        return canonical, "craft-not-enchanting"
    end
    return canonical
end

function Data:CanScanCraftData()
    local canonical, reason = self:GetActiveCraftProfession()
    if not canonical then
        return false, reason or "craft-no-title", canonical
    end
    if reason then
        return false, reason, canonical
    end
    if type(GetNumCrafts) ~= "function" or type(GetCraftInfo) ~= "function" then
        return false, "craft-api-missing", canonical
    end
    local numCrafts = GetNumCrafts()
    if type(numCrafts) ~= "number" or numCrafts <= 0 then
        return false, "craft-data-not-ready", canonical
    end
    return true, nil, canonical, numCrafts
end

function Data:GetVisibleTrackedProfessionContext()
    local tradeFrame = _G.TradeSkillFrame
    if tradeFrame and type(tradeFrame.IsShown) == "function" and tradeFrame:IsShown() then
        local canonical, reason = self:GetActiveTradeSkillProfession()
        if canonical and not reason then
            return canonical, "trade", nil
        end
        return nil, "trade", reason or "trade-no-title"
    end

    local craftFrame = _G.CraftFrame
    if craftFrame and type(craftFrame.IsShown) == "function" and craftFrame:IsShown() then
        local canonical, reason = self:GetActiveCraftProfession()
        if canonical and not reason then
            return canonical, "craft", nil
        end
        return nil, "craft", reason or "craft-no-title"
    end

    return nil, nil, "no-visible-profession-frame"
end

function Data:ScanTradeSkill(opts)
    self:EnsureScanState()
    local context = resolveScanContext(opts)
    local canScan, reason, canonical, initialNumSkills = self:CanScanTradeSkillData()
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
    local filterState = snapshotTradeSkillFilters()
    clearTradeSkillFilters()

    local recipes = {}
    local collapsedHeaders = {}
    local ok, err = pcall(function()
        local numSkills = initialNumSkills or GetNumTradeSkills() or 0
        for i = numSkills, 1, -1 do
            local headerName, recipeType, _, isExpanded = GetTradeSkillInfo(i)
            if recipeType == "header" and not isExpanded then
                collapsedHeaders[headerName or i] = true
                pcall(ExpandTradeSkillSubClass, i)
            end
        end

        numSkills = GetNumTradeSkills() or 0
        for i = 1, numSkills do
            local recipeName, recipeType = GetTradeSkillInfo(i)
            if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
                local itemID, invalidItemID = extractItemID(GetTradeSkillItemLink(i))
                local recipeKey = invalidItemID or itemID or -(extractSpellID(GetTradeSkillRecipeLink(i)) or i)
                if isValidRecipeKey(recipeKey) then
                    recipes[recipeKey] = true
                else
                    self:RecordInvalidRecipeKey(recipeKey, "scan", self:GetPlayerKey(), canonical)
                    Addon:Debug("Blocked invalid recipe from TradeSkill scan:", recipeKey, "profession:", canonical)
                end
            end
        end

        if next(collapsedHeaders) then
            numSkills = GetNumTradeSkills() or 0
            local CollapseTradeSkillSubClass = CollapseTradeSkillSubClass
            if type(CollapseTradeSkillSubClass) == "function" then
                for i = 1, numSkills do
                    local headerName, recipeType, _, isExpanded = GetTradeSkillInfo(i)
                    if recipeType == "header" and isExpanded and collapsedHeaders[headerName or i] then
                        pcall(CollapseTradeSkillSubClass, i)
                    end
                end
            end
        end
    end)

    restoreTradeSkillFilters(filterState)

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

function Data:ScanCraft(opts)
    self:EnsureScanState()
    local context = resolveScanContext(opts)
    local canScan, reason, canonical, initialNumCrafts = self:CanScanCraftData()
    if not canScan then
        if reason == "craft-not-enchanting" then
            Addon:Debug("ScanCraft skipped: CraftFrame shows", canonical or "nil")
        end
        return self:SkipScan(canonical, reason or "craft-data-not-ready", nil, context)
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
    local filterState = snapshotCraftFilters()
    clearCraftFilters()

    local recipes = {}
    local ok, err = pcall(function()
        for i = 1, (initialNumCrafts or GetNumCrafts() or 0) do
            local recipeName, recipeType = GetCraftInfo(i)
            if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
                local itemID, invalidItemID = extractItemID(GetCraftItemLink(i))
                local recipeKey = invalidItemID or itemID or -(extractSpellID(GetCraftRecipeLink(i)) or i)
                if isValidRecipeKey(recipeKey) then
                    recipes[recipeKey] = true
                else
                    self:RecordInvalidRecipeKey(recipeKey, "scan", self:GetPlayerKey(), canonical)
                    Addon:Debug("Blocked invalid recipe from Craft scan:", recipeKey, "profession:", canonical)
                end
            end
        end
    end)

    restoreCraftFilters(filterState)

    if not ok then
        self:RecordScanTelemetry("scansFailed")
        self._scanTelemetry.lastScanReason = context.reason
        self._scanTelemetry.lastScanNotifyMode = context.notifyMode
        if context.notifyMode == "manual" then
            Addon:Print("Craft scan failed: " .. tostring(err))
        else
            Addon:Debug("Craft scan failed:", tostring(err), "reason:", context.reason)
        end
        return self:MakeScanResult(canonical, {
            valid = false,
            failed = true,
            skipReason = "craft-scan-failed",
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
    local oldSignature = prof.signature or ""
    local newSignature = stableRecipeSignature(recipeKeys)
    local recipeChanged = (oldSignature ~= newSignature)
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
    prof.signature = newSignature
    prof.count = count
    prof.lastScan = time()
    prof.blockRevision = entry.rev or prof.blockRevision or 0
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
        if specializationChanged and not recipeChanged then
            self:TouchLocalRevision("specialization-scan:" .. profession)
        else
            self:TouchLocalRevision("scan:" .. profession)
        end
        prof.blockRevision = entry.rev or prof.blockRevision
        if self.MarkSyncIndexDirty then
            self:MarkSyncIndexDirty(specializationChanged and not recipeChanged and "specialization-scan" or "scan")
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
