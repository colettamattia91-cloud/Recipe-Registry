local Addon = _G.RecipeRegistry
local Market = Addon:NewModule("Market", "AceEvent-3.0")
Addon.Market = Market

local GetItemInfo = Addon.Compat.GetItemInfo

local TSM_SOURCES = { "dbmarket", "dbminbuyout" }
-- What a vendor charges, as TSM models it. Kept apart from TSM_SOURCES:
-- these are acquisition prices for reagents, never a sale value for what
-- the recipe produces.
local TSM_VENDOR_SOURCES = { "vendorbuy" }
-- The auction house keeps 5% of the sale price in TBC. Only ever applied to
-- the profit line, and only when the player asks for it.
local AUCTION_HOUSE_CUT = 0.05

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
    self.vendorCache = {}
end

local function vendorPriceStore(create)
    local db = Addon.db
    local global = db and db.global
    if not global then return nil end
    if type(global.vendorPrices) ~= "table" then
        if not create then return nil end
        global.vendorPrices = {}
    end
    return global.vendorPrices
end

-- Vendor prices come from two places, in order of trust:
--   * what we watched a merchant charge this account, which is the real
--     price including any faction discount the character has;
--   * TSM's vendorbuy source, for players who run TSM and have never
--     opened the relevant vendor.
-- Auctionator has no vendor-buy data, so its users rely on the scan.
function Market:GetVendorPrice(itemID)
    if not itemID then return nil end

    local store = vendorPriceStore(false)
    local scanned = store and store[itemID]
    if type(scanned) == "number" and scanned > 0 then
        return scanned, "Vendor"
    end

    local itemString = itemStringFromID(itemID)
    local api = _G.TSM_API
    if itemString and api and type(api.GetCustomPriceValue) == "function" then
        for _, source in ipairs(TSM_VENDOR_SOURCES) do
            local ok, value = pcall(api.GetCustomPriceValue, source, itemString)
            local copper = ok and clampCopper(value) or nil
            if copper and copper > 0 then
                return copper, "TSM:" .. source
            end
        end
    end

    local tsm4 = _G.TSM_API_FOUR
    local customPrice = tsm4 and tsm4.CustomPrice
    if itemString and customPrice and type(customPrice.GetValue) == "function" then
        for _, source in ipairs(TSM_VENDOR_SOURCES) do
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

-- The set of items worth remembering a vendor price for: everything the
-- metadata lists as a reagent of some recipe. Nothing else is ever priced
-- as a material, so recording it would grow a saved table forever on the
-- strength of every junk item the player ever walked past. Built once from
-- the metadata, which is static.
function Market:GetPriceableReagentIds()
    if self._reagentIds then return self._reagentIds end

    local metadata = Addon.RecipeMetadata
    self._reagentIds = (metadata and metadata.GetReagentItemIds
        and metadata:GetReagentItemIds()) or {}
    return self._reagentIds
end

-- Reagents like vials, thread and spices are sold by vendors at a fixed
-- price and often have no auctions at all. Reading only the auction sources
-- either priced them far above what anyone actually pays, or left them
-- unpriced -- which silently dropped every alchemy recipe out of the
-- profit filter, since every flask needs a vial.
--
-- Every merchant window we open is scanned once and folded into the
-- account-wide store. One value per item, not per vendor: what a vendor
-- charges for a given item is the same everywhere (a reputation discount
-- shaves a few percent and is not worth modelling), so the last price seen
-- simply wins.
--
-- Only reagents are recorded, which is what bounds the table: the metadata
-- has a fixed set of them, so the store cannot grow past it however many
-- merchants the player visits. Items bought with an alternate currency
-- (honor, tokens, badges) are skipped too: their copper price is not what
-- they cost.
function Market:ScanMerchantPrices()
    local getNum = _G.GetMerchantNumItems
    local getInfo = _G.GetMerchantItemInfo
    if type(getNum) ~= "function" or type(getInfo) ~= "function" then return 0 end

    local store = vendorPriceStore(true)
    if not store then return 0 end

    local reagentIds = self:GetPriceableReagentIds()
    local getLink = _G.GetMerchantItemLink
    local learned = 0
    local count = getNum() or 0
    for index = 1, count do
        local ok, _name, _texture, price, quantity, _available, _usable, extendedCost = pcall(getInfo, index)
        if ok and extendedCost ~= true then
            local unit = clampCopper((tonumber(price) or 0) / math.max(1, tonumber(quantity) or 1))
            local itemID
            if type(getLink) == "function" then
                local okLink, link = pcall(getLink, index)
                itemID = okLink and link and extractItemIDFromQuery(link) or nil
            end
            if itemID and reagentIds[itemID] and unit and unit > 0 and store[itemID] ~= unit then
                store[itemID] = unit
                learned = learned + 1
            end
        end
    end

    if learned > 0 then
        -- Derived costs downstream are now stale for anything using these
        -- reagents; the same invalidation the auction house close uses.
        self:InvalidatePriceCache("merchant-scan")
    end
    return learned
end

function Market:OnEnable()
    -- TSM and Auctionator refresh their price data when the player runs
    -- an auction-house scan. The cleanest moment to drop our derived
    -- cache is when the AH window closes — by then the upstream scan
    -- (if any) has finished writing. We also invalidate the recipe
    -- detail cache so an open recipe panel recomputes its cost block
    -- on next refresh.
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", "OnAuctionHouseClosed")
    self:RegisterEvent("MERCHANT_SHOW", "OnMerchantShow")
end

function Market:OnMerchantShow()
    self:ScanMerchantPrices()
end

function Market:OnAuctionHouseClosed()
    self:InvalidatePriceCache("auction-house-closed")
end

function Market:InvalidatePriceCache(reason)
    self.priceCache = {}
    self.vendorCache = {}
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
function Market:GetMarketPrice(itemID, itemLink)
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

-- What it costs to obtain one of an item: the cheaper of the auction house
-- and the vendor. Used for reagents only. What a recipe PRODUCES is valued
-- with GetMarketPrice instead -- a vendor's asking price is what you pay to
-- buy, never what you get for selling.
function Market:GetMaterialCost(itemID, itemLink)
    if not itemID then return nil, nil end

    local market, marketSource = self:GetMarketPrice(itemID, itemLink)

    self.vendorCache = self.vendorCache or {}
    local cachedVendor = self.vendorCache[itemID]
    if not cachedVendor then
        local price, source = self:GetVendorPrice(itemID)
        cachedVendor = { price = price, source = source }
        self.vendorCache[itemID] = cachedVendor
    end
    local vendor, vendorSource = cachedVendor.price, cachedVendor.source

    if market and vendor then
        if vendor <= market then
            return vendor, vendorSource
        end
        return market, marketSource
    end
    if market then
        return market, marketSource
    end
    return vendor, vendorSource
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

-- What one craft is worth at market, and the profit against its reagent
-- cost. Prices the created item through the same per-item cache the
-- reagents use (GetMaterialCost is item-generic despite the name), so the
-- output of one recipe is already priced when it turns up as a reagent of
-- another.
--
-- Profit is only marked complete when every reagent priced: a partial cost
-- understates the spend, which would show a phantom profit on exactly the
-- recipes whose materials nobody has listed.
-- The auction house takes its cut off the sale, never off what you paid for
-- the materials, so it applies to the output value alone. Off by default:
-- the gross figure is also the price to list at.
function Market:GetSaleMultiplier()
    local profile = Addon.db and Addon.db.profile
    if profile and profile.subtractAuctionHouseCut == true then
        return 1 - AUCTION_HOUSE_CUT, true
    end
    return 1, false
end

local function applyCraftValue(self, detail)
    detail.value = nil
    detail.profit = nil

    local createdItemID = detail.createdItemID
    if not createdItemID then return end

    -- Market price, not GetMaterialCost: the created item may well be sold
    -- by a vendor too, and that vendor's asking price is not what the craft
    -- is worth to sell.
    local unitPrice, source = self:GetMarketPrice(createdItemID)
    if not unitPrice then return end

    local count = tonumber(detail.numCreated) or 1
    local countMax = tonumber(detail.numCreatedMax) or count
    detail.value = {
        unitPrice = unitPrice,
        source = source,
        count = count,
        countMax = countMax,
        total = unitPrice * count,
        totalMax = unitPrice * countMax,
    }

    local cost = detail.cost
    if not cost or (cost.pricedCount or 0) <= 0 then return end

    local multiplier, taxed = self:GetSaleMultiplier()
    detail.profit = {
        total = math.floor(detail.value.total * multiplier) - cost.total,
        totalMax = math.floor(detail.value.totalMax * multiplier) - cost.total,
        complete = (cost.missingCount or 0) == 0,
        taxed = taxed,
    }
end

-- Per-row profit estimate for the "only profitable recipes" list filter.
--
-- Reads the raw metadata record rather than a display info: the list build
-- deliberately skips reagent materialization in recipe search mode because
-- the GetItemInfo call per reagent dominates profession-switch latency, and
-- pricing needs item IDs and counts, not names. Everything else is a table
-- read plus cache-backed price lookups.
--
-- Returns the profit in copper, or nil plus "unpriceable" when the craft
-- cannot be priced end to end (no created item, no reagents, or any leg
-- missing a price). Callers must keep those two apart: an unpriceable
-- recipe is not a known-unprofitable one.
function Market:EstimateRecipeProfit(recipeKey, info)
    local metadata = Addon.RecipeMetadata
    if not metadata then return nil, "unpriceable" end

    info = info or (metadata.GetRecipeInfo and metadata:GetRecipeInfo(recipeKey)) or nil
    if not info then return nil, "unpriceable" end

    local createdItemID = info.createdItemId
    if not createdItemID then return nil, "unpriceable" end

    local unitPrice = self:GetMarketPrice(createdItemID)
    if not unitPrice then return nil, "unpriceable" end

    local reagents = info.reagents
    if type(reagents) ~= "table" or #reagents == 0 then return nil, "unpriceable" end

    local cost = 0
    for index = 1, #reagents do
        local reagent = reagents[index]
        local price = reagent.itemId and self:GetMaterialCost(reagent.itemId) or nil
        if not price then
            return nil, "unpriceable"
        end
        cost = cost + price * (tonumber(reagent.count) or 1)
    end

    -- Conservative on random yields: the guaranteed quantity, not the lucky one.
    local count = tonumber(info.createdCount) or 1
    return math.floor(unitPrice * count * self:GetSaleMultiplier()) - cost
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

    -- Name the providers that actually priced something. Vendor entries
    -- reach this list too now, so the old TSM-or-Auctionator special case
    -- would have reported "N/A" for a craft whose reagents all came from a
    -- merchant.
    local providerSeen, providers = {}, {}
    for source in pairs(usedSources) do
        local provider = tostring(source):match("^[^:]+") or tostring(source)
        if not providerSeen[provider] then
            providerSeen[provider] = true
            providers[#providers + 1] = provider
        end
    end
    table.sort(providers)
    local sourceLabel = #providers > 0 and table.concat(providers, "/") or "N/A"

    detail.cost = {
        total = total,
        pricedCount = pricedCount,
        missingCount = missingCount,
        source = sourceLabel,
    }

    applyCraftValue(self, detail)
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
    local vendorKnown = 0
    local store = Addon.db and Addon.db.global and Addon.db.global.vendorPrices
    for _ in pairs(store or {}) do
        vendorKnown = vendorKnown + 1
    end
    Addon:Print(string.format("Price providers: TSM=%s Auctionator=%s cached=%d vendorItems=%d (invalidated on AH close)",
        hasTSM and "yes" or "no",
        hasAuctionator and "yes" or "no",
        cached,
        vendorKnown
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

    local vendorPrice, vendorSource = self:GetVendorPrice(itemID)
    if vendorPrice then
        Addon:Print(string.format("  vendor: %s (%s)", formatMoney(vendorPrice), tostring(vendorSource or "unknown")))
    end
    local price, source = self:GetMaterialCost(itemID, itemLink)
    local resolvedName = itemNameFromID(itemID) or "?"
    if price then
        Addon:Print(string.format("Item %s (%d) price=%s source=%s", resolvedName, itemID, formatMoney(price), tostring(source or "unknown")))
    else
        Addon:Print(string.format("No price available for item %s (%d) from TSM or Auctionator.", resolvedName, itemID))
    end
end
