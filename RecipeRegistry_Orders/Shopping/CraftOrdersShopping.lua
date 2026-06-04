local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Shopping = {}
Addon.Shopping = Shopping

-- Aggregated "materials I still need to gather" view across every
-- outgoing order the local account holds (Draft + MaterialsPartial).
-- For each distinct itemID, this collapses:
--   - planned requirements   (sum of required across orders)
--   - already-credited stock (crafterProvided + already-sent batches)
--   - already-on-hand stock  (bag inventory + bank inventory cache)
-- The "still to gather" number is what the user must still acquire
-- (positive) or already covers (zero). The breakdown per contributing
-- order is preserved so the UI can hover-explain each row.
--
-- v1 scope: bank inventory is per-character (the snapshot at the most
-- recent BANKFRAME_OPENED). Multi-character bank sum lands with §9.9.

local STATUS_DRAFT = "Draft"
local STATUS_PARTIAL = "MaterialsPartial"

local function ensureDB()
    if not (Addon.db and Addon.db.global) then return nil end
    local db = Addon.db.global
    db.bankSnapshots = db.bankSnapshots or {}
    return db
end

local function getLocalPlayerKey()
    if type(Addon.GetLocalPlayerKey) ~= "function" then return nil end
    local ok, key = pcall(Addon.GetLocalPlayerKey, Addon)
    if not ok or type(key) ~= "string" or key == "" then return nil end
    return key
end

-- Walk all known orders and keep only the ones where the local player
-- is the requester AND the order is still in the "I'm gathering /
-- shipping" phase. Past those states the materials have left our
-- hands and don't belong in a shopping list.
local function listGatheringOrders(store, requester)
    local out = {}
    if not (store and store.ListOrders and requester) then return out end
    local raw = store:ListOrders({ requester = requester })
    for index = 1, #raw do
        local order = raw[index]
        if order.status == STATUS_DRAFT or order.status == STATUS_PARTIAL then
            out[#out + 1] = order
        end
    end
    return out
end

-- Returns how many of itemID we've already shipped for `order` across
-- every batch that carries a sentAt stamp. RecordBatchSent stores the
-- per-batch items map on batches[n].sentItems.
local function alreadySentForOrder(order, itemID)
    if not (order and order.batches) then return 0 end
    local sent = 0
    for _, slot in pairs(order.batches) do
        if slot and slot.sentAt and slot.sentItems then
            sent = sent + (tonumber(slot.sentItems[itemID]) or 0)
        end
    end
    return sent
end

local function safeItemLink(itemID, fallbackName)
    if type(_G.GetItemInfo) == "function" then
        local _, link = _G.GetItemInfo(itemID)
        if link and link ~= "" then return link end
    end
    return string.format("|cff9d9d9d|Hitem:%d::::::::::0|h[%s]|h|r",
        tonumber(itemID) or 0,
        tostring(fallbackName or ("item:" .. tostring(itemID))))
end

-- Inventory side: bag count is live (BagScan walks bags 0..NUM_BAG_SLOTS
-- on every call); bank count comes from the cached snapshot the player
-- last produced when they opened a bank window.
local function countInBags(itemID)
    local bagScan = Addon.BagScan
    if bagScan and type(bagScan.CountItem) == "function" then
        return bagScan:CountItem(itemID) or 0
    end
    return 0
end

local function countInBankSnapshot(snapshot, itemID)
    if type(snapshot) ~= "table" or type(snapshot.items) ~= "table" then return 0 end
    return tonumber(snapshot.items[itemID]) or 0
end

-- Public: returns the aggregated shopping list. Shape:
--   {
--     materials = { { itemID, name, link, required, sent, inBags,
--                     inBank, stillToGather, contributingOrders }, ... },
--     orderCount = N,
--     distinctItems = K,
--     bankSnapshot = { atOpen, lastSeenAt, charKey } | nil,
--   }
-- Rows are sorted by stillToGather DESC then name ASC so the most
-- urgent rows surface at the top.
function Shopping:ComputeAggregated()
    local store = Addon.Store
    local me = getLocalPlayerKey()
    local db = ensureDB()
    local snapshot = db and me and db.bankSnapshots[me] or nil
    local result = {
        materials = {},
        orderCount = 0,
        distinctItems = 0,
        bankSnapshot = snapshot and { lastSeenAt = snapshot.lastSeenAt } or nil,
    }
    if not (store and me) then return result end

    local orders = listGatheringOrders(store, me)
    result.orderCount = #orders

    -- buckets keyed by itemID; we aggregate per item across orders.
    local buckets = {}
    for index = 1, #orders do
        local order = orders[index]
        for itemID, mat in pairs(order.materials or {}) do
            -- Skip excluded materials and the slice the crafter agreed
            -- to provide; both are out of the requester's gathering
            -- workload by definition.
            if not mat.excluded then
                local required        = tonumber(mat.required) or 0
                local crafterProvided = tonumber(mat.crafterProvided) or 0
                local requesterShare  = math.max(0, required - crafterProvided)
                if requesterShare > 0 then
                    local bucket = buckets[itemID]
                    if not bucket then
                        bucket = {
                            itemID             = itemID,
                            name               = mat.name,
                            quality            = mat.quality,
                            required           = 0,
                            sent               = 0,
                            contributingOrders = {},
                        }
                        buckets[itemID] = bucket
                    end
                    bucket.required = bucket.required + requesterShare
                    bucket.sent     = bucket.sent + alreadySentForOrder(order, itemID)
                    bucket.contributingOrders[#bucket.contributingOrders + 1] = {
                        orderId   = order.id,
                        crafter   = order.crafter,
                        quantity  = requesterShare,
                    }
                end
            end
        end
    end

    -- Compute on-hand counts + still-to-gather, finalize rows.
    local list = result.materials
    for itemID, bucket in pairs(buckets) do
        bucket.link = safeItemLink(itemID, bucket.name)
        bucket.inBags = countInBags(itemID)
        bucket.inBank = countInBankSnapshot(snapshot, itemID)
        bucket.stillToGather = math.max(0,
            bucket.required - bucket.sent - bucket.inBags - bucket.inBank)
        list[#list + 1] = bucket
    end
    result.distinctItems = #list

    table.sort(list, function(a, b)
        if a.stillToGather ~= b.stillToGather then
            return a.stillToGather > b.stillToGather
        end
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an ~= bn then return an < bn end
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    return result
end

-- Walks bank bags (main bank = -1, bank slots 5..11 on TBC) while the
-- bank UI is open and caches the per-itemID count in the global DB.
-- Called from BANKFRAME_OPENED. Keyed by local player so each char
-- has its own snapshot.
local BANK_BAG_IDS = { -1, 5, 6, 7, 8, 9, 10, 11 }

local function getContainerNumSlots(bagId)
    if _G.C_Container and _G.C_Container.GetContainerNumSlots then
        return _G.C_Container.GetContainerNumSlots(bagId) or 0
    end
    if type(_G.GetContainerNumSlots) == "function" then
        return _G.GetContainerNumSlots(bagId) or 0
    end
    return 0
end

local function readContainerSlot(bagId, slot)
    if type(_G.GetContainerItemInfo) == "function" then
        local _, count, _, _, _, _, _, _, _, itemID = _G.GetContainerItemInfo(bagId, slot)
        if itemID then return itemID, count or 1 end
    end
    if _G.C_Container and _G.C_Container.GetContainerItemInfo then
        local info = _G.C_Container.GetContainerItemInfo(bagId, slot)
        if info and info.itemID then return info.itemID, info.stackCount or 1 end
    end
    return nil
end

function Shopping:UpdateBankSnapshot()
    local db = ensureDB()
    local me = getLocalPlayerKey()
    if not (db and me) then return nil, "no-identity" end

    local items = {}
    for _, bagId in ipairs(BANK_BAG_IDS) do
        local slots = getContainerNumSlots(bagId)
        for slot = 1, slots do
            local itemID, count = readContainerSlot(bagId, slot)
            if itemID and count > 0 then
                items[itemID] = (items[itemID] or 0) + count
            end
        end
    end

    db.bankSnapshots[me] = {
        items      = items,
        lastSeenAt = time and time() or 0,
    }
    return db.bankSnapshots[me]
end

function Shopping:GetBankSnapshot(charKey)
    local db = ensureDB()
    if not db then return nil end
    charKey = charKey or getLocalPlayerKey()
    if not charKey then return nil end
    return db.bankSnapshots[charKey]
end

-- Subscribes to BANKFRAME_OPENED so the snapshot refreshes every time
-- the player walks up to a banker. Idempotent. Skipped in the harness
-- when RegisterEvent isn't available; tests drive UpdateBankSnapshot
-- directly.
function Shopping:OnEnable()
    if self._wired then return end
    if type(Addon.RegisterEvent) ~= "function" then return end
    Addon:RegisterEvent("BANKFRAME_OPENED", function()
        Shopping:UpdateBankSnapshot()
    end)
    self._wired = true
end
