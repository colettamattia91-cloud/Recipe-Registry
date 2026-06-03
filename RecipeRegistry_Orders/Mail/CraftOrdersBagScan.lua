local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local BagScan = {}
Addon.BagScan = BagScan

-- Bag inventory helper for the outgoing Mail Assistant. Walks bags 0
-- (backpack) through NUM_BAG_SLOTS (4 on TBC) and exposes the
-- per-stack view needed to attach items to outgoing mail.
--
-- v1 only knows how to source a Pick from a SINGLE stack: if you ask
-- for 100 Peacebloom and no stack has at least 100, the call fails
-- with split-across-stacks. Multi-stack consolidation (combine 60+40
-- into a 100 cursor pickup) is a follow-up — TBC's PickupContainerItem
-- only lifts one stack at a time and the mail attach slot accepts
-- exactly one cursor item, so consolidation needs an intermediate
-- stash step we're skipping for now.

-- TBC's bag IDs run 0..NUM_BAG_SLOTS. C_Container is the modern shim
-- that newer 2.5.x builds expose; we fall back to the loose globals
-- when the shim isn't there. Both surfaces are wrapped here so the
-- rest of the addon never branches on them itself.
local function getNumSlots(bagId)
    if _G.C_Container and _G.C_Container.GetContainerNumSlots then
        return _G.C_Container.GetContainerNumSlots(bagId) or 0
    end
    if type(_G.GetContainerNumSlots) == "function" then
        return _G.GetContainerNumSlots(bagId) or 0
    end
    return 0
end

local function readSlot(bagId, slot)
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

local function pickStack(bagId, slot)
    if _G.C_Container and _G.C_Container.PickupContainerItem then
        _G.C_Container.PickupContainerItem(bagId, slot)
    elseif type(_G.PickupContainerItem) == "function" then
        _G.PickupContainerItem(bagId, slot)
    end
end

local function splitStack(bagId, slot, count)
    if _G.C_Container and _G.C_Container.SplitContainerItem then
        _G.C_Container.SplitContainerItem(bagId, slot, count)
    elseif type(_G.SplitContainerItem) == "function" then
        _G.SplitContainerItem(bagId, slot, count)
    end
end

-- Returns every stack of itemID across all bags as an array of
-- { bagId, slot, count }. Largest stack first; tie-break by
-- (bagId, slot) to keep behaviour deterministic across reloads.
function BagScan:IndexItem(itemID)
    local out = {}
    itemID = tonumber(itemID)
    if not itemID then return out end
    local numBags = tonumber(_G.NUM_BAG_SLOTS) or 4
    for bagId = 0, numBags do
        local slots = getNumSlots(bagId)
        for slot = 1, slots do
            local found, count = readSlot(bagId, slot)
            if found == itemID and (count or 0) > 0 then
                out[#out + 1] = { bagId = bagId, slot = slot, count = count }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.bagId ~= b.bagId then return a.bagId < b.bagId end
        return a.slot < b.slot
    end)
    return out
end

function BagScan:CountItem(itemID)
    local total = 0
    local stacks = self:IndexItem(itemID)
    for index = 1, #stacks do total = total + (stacks[index].count or 0) end
    return total
end

-- Picks `count` items of itemID onto the cursor. Walks the indexed
-- stacks largest first and either lifts the whole stack
-- (PickupContainerItem) or splits the exact count from it
-- (SplitContainerItem). Returns true + the source descriptor on
-- success, or false + reason on failure. Failure modes:
--   - "no-stack"           : item not present in bags
--   - "split-across-stacks": no single stack has >= count
function BagScan:Pick(itemID, count)
    count = tonumber(count) or 0
    if count <= 0 then return false, "invalid-count" end
    local stacks = self:IndexItem(itemID)
    if #stacks == 0 then return false, "no-stack" end

    -- Prefer the smallest stack that still satisfies the request:
    -- avoids breaking the largest stack when a smaller one would do.
    -- Falls back to the largest if no single-stack fit exists.
    local pickIndex
    for index = #stacks, 1, -1 do
        if (stacks[index].count or 0) >= count then
            pickIndex = index
            break
        end
    end
    if not pickIndex then
        return false, "split-across-stacks"
    end
    local source = stacks[pickIndex]
    if source.count == count then
        pickStack(source.bagId, source.slot)
    else
        splitStack(source.bagId, source.slot, count)
    end
    return true, source
end
