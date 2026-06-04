local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Planner = {}
Addon.Planner = Planner

local function getRR()
    return _G.RecipeRegistry
end

-- RR exposes two read paths for a recipe:
--   GetRecipeDisplayInfo: fast lookup that returns an empty reagents
--                         table (per-reagent name resolution is the
--                         dominant cost on profession-switch and is
--                         deferred until someone actually asks).
--   GetRecipeDetail:      same lookup plus EnsureRecipeReagents +
--                         crafters resolution; this is what the
--                         detail panel uses.
-- The planner needs the reagents, so it has to go through Detail —
-- otherwise materials always come back empty for any recipe whose
-- reagents haven't been materialized yet (the common case for a
-- freshly-loaded session).
local function getRecipeDisplayInfo(recipeKey)
    local rr = getRR()
    if not (rr and rr.Data) then return nil end
    if type(rr.Data.GetRecipeDetail) == "function" then
        local ok, info = pcall(rr.Data.GetRecipeDetail, rr.Data, recipeKey)
        if ok and type(info) == "table" then return info end
    end
    -- Fallback for hosts that only expose GetRecipeDisplayInfo (e.g.
    -- the unit-test stub): explicitly materialize reagents on the
    -- returned record so the planner sees them.
    if type(rr.Data.GetRecipeDisplayInfo) ~= "function" then return nil end
    local ok, info = pcall(rr.Data.GetRecipeDisplayInfo, rr.Data, recipeKey)
    if not (ok and type(info) == "table") then return nil end
    if type(rr.Data.EnsureRecipeReagents) == "function" then
        pcall(rr.Data.EnsureRecipeReagents, rr.Data, info)
    end
    return info
end

-- Aggregate reagents across all order lines. Returns:
--   materials: { [itemID] = { itemID, name, icon, quality, required,
--                              requesterProvided, crafterProvided,
--                              mailable, excluded } }
--   missing:   array of { recipeKey, quantity, reason } for lines whose
--              recipe info was unavailable (RR not loaded, AtlasLoot
--              missing data, unknown recipeKey).
--
-- v1 defaults all materials to requester-provided. Later phases will
-- let the requester override per-item via UI / slash before sending.
function Planner:ComputeFromLines(lines)
    local materials = {}
    local missing = {}

    if type(lines) ~= "table" then
        return materials, missing
    end

    for index = 1, #lines do
        local line = lines[index]
        local recipeKey = tonumber(line and line.recipeKey)
        local quantity = tonumber(line and line.quantity) or 0
        if recipeKey and quantity > 0 then
            local info = getRecipeDisplayInfo(recipeKey)
            if info and type(info.reagents) == "table" and #info.reagents > 0 then
                for ri = 1, #info.reagents do
                    local reagent = info.reagents[ri]
                    local itemID = tonumber(reagent and reagent.itemID)
                    local perCraft = tonumber(reagent and reagent.count) or 1
                    if itemID then
                        local addedCount = perCraft * quantity
                        local bucket = materials[itemID]
                        if not bucket then
                            bucket = {
                                itemID            = itemID,
                                name              = reagent.name,
                                icon              = reagent.icon,
                                quality           = reagent.quality,
                                required          = 0,
                                requesterProvided = 0,
                                crafterProvided   = 0,
                                mailable          = true,
                                excluded          = false,
                            }
                            materials[itemID] = bucket
                        end
                        bucket.required = bucket.required + addedCount
                        bucket.requesterProvided = bucket.required
                    end
                end
            else
                missing[#missing + 1] = {
                    recipeKey = recipeKey,
                    quantity  = quantity,
                    reason    = (info and "no-reagents") or "no-info",
                }
            end
        end
    end

    return materials, missing
end

function Planner:RecomputeOrder(order)
    if type(order) ~= "table" then return false, "invalid-order" end
    local materials, missing = self:ComputeFromLines(order.lines)
    order.materials = materials
    if missing and #missing > 0 then
        order._plannerMissing = missing
    else
        order._plannerMissing = nil
    end
    return true
end

function Planner:CountMaterials(order)
    local distinct = 0
    local totalUnits = 0
    for _, bucket in pairs(order and order.materials or {}) do
        distinct = distinct + 1
        totalUnits = totalUnits + (bucket.required or 0)
    end
    return distinct, totalUnits
end

-- Sorted materials view for UI. Sorts by name then itemID for stable
-- presentation.
function Planner:GetSortedMaterials(order)
    local list = {}
    for _, bucket in pairs(order and order.materials or {}) do
        list[#list + 1] = bucket
    end
    table.sort(list, function(a, b)
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an ~= bn then return an < bn end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    return list
end
