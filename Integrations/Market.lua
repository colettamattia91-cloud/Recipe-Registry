local Addon = _G.RecipeRegistry
local Market = Addon:NewModule("Market", "AceEvent-3.0")
Addon.Market = Market

local GetItemInfo = Addon.Compat.GetItemInfo

local TSM_SOURCES = { "dbmarket", "dbminbuyout" }

local function itemStringFromID(itemID)
    if not itemID then return nil end
    return "i:" .. tostring(itemID)
end

local function normalizeName(name)
    if not name then return "" end
    return tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function itemNameFromID(itemID)
    if not itemID or type(GetItemInfo) ~= "function" then return nil end
    local name = GetItemInfo(itemID)
    return name
end

local function extractItemIDFromQuery(query)
    if not query or query == "" then return nil end
    local text = tostring(query)
    local itemID = text:match("|Hitem:(%d+)") or text:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

local function extractItemLinkFromQuery(query)
    if not query or query == "" then return nil end
    local text = tostring(query)
    local plainLink = text:match("(|Hitem:[^|]+|h%[[^%]]+%]|h)")
    if plainLink then
        return plainLink
    end
    local coloredLink = text:match("(|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)")
    if coloredLink then
        return coloredLink
    end
    return nil
end

local function extractItemNameFromQuery(query)
    if not query or query == "" then return "" end
    local text = tostring(query)
    local linkedName = text:match("|h%[([^%]]+)%]|h")
    if linkedName and linkedName ~= "" then
        return linkedName
    end
    return text
end

local function formatMoney(copper)
    if type(copper) ~= "number" then return "n/a" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local goldIcon = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:0:-5|t"
    local silverIcon = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:0:-5|t"
    local copperIcon = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:0:-5|t"
    local parts = {}
    if g > 0 then parts[#parts + 1] = string.format("%d %s", g, goldIcon) end
    if s > 0 then parts[#parts + 1] = string.format("%d %s", s, silverIcon) end
    if c > 0 then parts[#parts + 1] = string.format("%d %s", c, copperIcon) end
    if #parts == 0 then return "0" end
    return table.concat(parts, " ")
end

local function clampCopper(value)
    if type(value) ~= "number" then return nil end
    if value < 0 then return nil end
    return math.floor(value + 0.5)
end

function Market:OnInitialize()
    self.priceCache = {}
end

function Market:OnEnable()
    -- TSM and Auctionator refresh their price data when the player runs
    -- an auction-house scan. The cleanest moment to drop our derived
    -- cache is when the AH window closes — by then the upstream scan
    -- (if any) has finished writing. We also invalidate the recipe
    -- detail cache so an open recipe panel recomputes its cost block
    -- on next refresh.
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", "OnAuctionHouseClosed")
end

function Market:OnAuctionHouseClosed()
    self:InvalidatePriceCache("auction-house-closed")
end

function Market:InvalidatePriceCache(reason)
    self.priceCache = {}
    if Addon.Data and Addon.Data.InvalidateRecipeCaches then
        Addon.Data:InvalidateRecipeCaches("metadata")
    end
    if Addon.RequestRefresh then
        Addon:RequestRefresh(reason or "prices")
    end
end

function Market:GetPriceFromTSM(itemID)
    local api = _G.TSM_API
    local itemString = itemStringFromID(itemID)
    if not itemString then return nil end

    if api and type(api.GetCustomPriceValue) == "function" then
        for _, source in ipairs(TSM_SOURCES) do
            local ok, value = pcall(api.GetCustomPriceValue, source, itemString)
            local copper = ok and clampCopper(value) or nil
            if copper and copper > 0 then
                return copper, "TSM:" .. source
            end
        end
    end

    local tsm4 = _G.TSM_API_FOUR
    local customPrice = tsm4 and tsm4.CustomPrice
    if customPrice and type(customPrice.GetValue) == "function" then
        for _, source in ipairs(TSM_SOURCES) do
            local okA, valueA = pcall(customPrice.GetValue, source, itemString)
            local copperA = okA and clampCopper(valueA) or nil
            if copperA and copperA > 0 then
                return copperA, "TSM:" .. source
            end

            local okB, valueB = pcall(customPrice.GetValue, itemString, source)
            local copperB = okB and clampCopper(valueB) or nil
            if copperB and copperB > 0 then
                return copperB, "TSM:" .. source
            end
        end
    end

    return nil
end

function Market:GetPriceFromAuctionator(itemID, itemLink)
    local auctionator = _G.Auctionator
    local api = auctionator and auctionator.API and auctionator.API.v1
    if not api then return nil end

    if type(api.GetAuctionPriceByItemID) == "function" then
        local ok, value = pcall(api.GetAuctionPriceByItemID, "RecipeRegistry", itemID)
        local copper = ok and clampCopper(value) or nil
        if copper and copper > 0 then
            return copper, "Auctionator"
        end
    end

    if type(api.GetAuctionPriceByItemLink) == "function" then
        local link = itemLink
        if not link and type(GetItemInfo) == "function" then
            local _, resolvedLink = GetItemInfo(itemID)
            link = resolvedLink
        end
        if link then
            local ok, value = pcall(api.GetAuctionPriceByItemLink, "RecipeRegistry", link)
            local copper = ok and clampCopper(value) or nil
            if copper and copper > 0 then
                return copper, "Auctionator"
            end
        end
    end

    return nil
end

-- Price cache lifetime is event-driven, not time-gated: the underlying
-- TSM/Auctionator data only changes when the user runs an auction-house
-- scan, so we wipe the cache on AUCTION_HOUSE_CLOSED instead of expiring
-- entries at an arbitrary clock interval. People who scan once a day (or
-- once a week) would otherwise pay a TSM/Auctionator query per material
-- per detail render every 30 seconds for the same stale numbers.
function Market:GetMaterialCost(itemID, itemLink)
    if not itemID then return nil, nil end

    local cached = self.priceCache[itemID]
    if cached then
        return cached.price, cached.source
    end

    local price, source = self:GetPriceFromTSM(itemID)
    if not price then
        price, source = self:GetPriceFromAuctionator(itemID, itemLink)
    end

    self.priceCache[itemID] = {
        price = price,
        source = source,
    }

    return price, source
end

function Market:ResolveItemQuery(query)
    if not query or query == "" then return nil end

    local fromLink = extractItemIDFromQuery(query)
    local itemLink = extractItemLinkFromQuery(query)
    if fromLink then
        return fromLink, itemLink
    end

    local asNumber = tonumber(query)
    if asNumber then
        return asNumber, itemLink
    end

    local wanted = normalizeName(extractItemNameFromQuery(query))
    if wanted == "" then return nil end

    local function checkName(id)
        local n = normalizeName(itemNameFromID(id))
        if n ~= "" and n == wanted then
            return id
        end
        return nil
    end

    if Addon.UI and Addon.UI.selectedRecipeKey and Addon.Data and Addon.Data.GetRecipeDetail then
        local detail = Addon.Data:GetRecipeDetail(Addon.UI.selectedRecipeKey, Addon.UI.selectedProfession)
        if detail then
            local id = checkName(detail.createdItemID)
            if id then return id, itemLink end
            id = checkName(detail.recipeItemID)
            if id then return id, itemLink end
            for _, reagent in ipairs(detail.reagents or {}) do
                id = checkName(reagent.itemID)
                if id then return id, itemLink end
            end
        end
    end

    if Addon.Data and Addon.Data.GetRecipeList then
        local rows = Addon.Data:GetRecipeList("All", "", "alpha") or {}
        local partialMatch = nil
        for _, row in ipairs(rows) do
                local detail = row.detail or (Addon.Data.GetRecipeDetail and Addon.Data:GetRecipeDetail(row.recipeKey))
                if detail then
                    local id = checkName(detail.createdItemID)
                    if id then return id, itemLink end
                    id = checkName(detail.recipeItemID)
                    if id then return id, itemLink end
                    for _, reagent in ipairs(detail.reagents or {}) do
                        local itemID = reagent.itemID
                        local n = normalizeName(itemNameFromID(itemID))
                        if n ~= "" then
                            if n == wanted then
                                return itemID, itemLink
                            end
                            if (not partialMatch) and n:find(wanted, 1, true) then
                                partialMatch = itemID
                        end
                    end
                end
            end
        end
        if partialMatch then return partialMatch, itemLink end
    end

    return nil
end

function Market:ApplyRecipeCosts(detail)
    if not detail then return end

    local reagents = detail.reagents or {}
    local total = 0
    local pricedCount = 0
    local missingCount = 0
    local usedSources = {}

    for _, reagent in ipairs(reagents) do
        local count = reagent.count or 1
        local unitPrice, source = self:GetMaterialCost(reagent.itemID)
        reagent.unitCost = unitPrice
        reagent.unitCostSource = source
        reagent.totalCost = unitPrice and (unitPrice * count) or nil

        if reagent.totalCost then
            total = total + reagent.totalCost
            pricedCount = pricedCount + 1
            if source then
                usedSources[source] = true
            end
        else
            missingCount = missingCount + 1
        end
    end

    local sourceLabel
    if usedSources["TSM:dbmarket"] or usedSources["TSM:dbminbuyout"] then
        sourceLabel = missingCount > 0 and "TSM/Auctionator" or "TSM"
    elseif usedSources["Auctionator"] then
        sourceLabel = "Auctionator"
    else
        sourceLabel = "N/A"
    end

    detail.cost = {
        total = total,
        pricedCount = pricedCount,
        missingCount = missingCount,
        source = sourceLabel,
    }
end

function Market:DumpStatus(rest)
    local hasTSM = (_G.TSM_API and type(_G.TSM_API.GetCustomPriceValue) == "function")
        or (_G.TSM_API_FOUR and _G.TSM_API_FOUR.CustomPrice and type(_G.TSM_API_FOUR.CustomPrice.GetValue) == "function")
    local hasAuctionator = (_G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1)
        and (type(_G.Auctionator.API.v1.GetAuctionPriceByItemID) == "function"
            or type(_G.Auctionator.API.v1.GetAuctionPriceByItemLink) == "function")

    local cached = 0
    for _ in pairs(self.priceCache or {}) do
        cached = cached + 1
    end
    Addon:Print(string.format("Price providers: TSM=%s Auctionator=%s cached=%d (invalidated on AH close)",
        hasTSM and "yes" or "no",
        hasAuctionator and "yes" or "no",
        cached
    ))

    local query = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then
        Addon:Print("Usage: /rr prices <item name|item link|itemID>")
        return
    end

    local itemID, itemLink = self:ResolveItemQuery(query)
    if not itemID then
        Addon:Print(string.format("Could not resolve item from '%s'. Use item link or exact name.", query))
        return
    end

    local price, source = self:GetMaterialCost(itemID, itemLink)
    local resolvedName = itemNameFromID(itemID) or "?"
    if price then
        Addon:Print(string.format("Item %s (%d) price=%s source=%s", resolvedName, itemID, formatMoney(price), tostring(source or "unknown")))
    else
        Addon:Print(string.format("No price available for item %s (%d) from TSM or Auctionator.", resolvedName, itemID))
    end
end
