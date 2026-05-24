local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Cart = {}
Addon.Cart = Cart

-- The cart is a per-character buffer of pending order lines, kept
-- between sessions in RecipeRegistry_OrdersCharDB.cart. Each line
-- records the target crafter alongside the recipe so a single
-- checkout can dispatch the cart into N orders (one per crafter).

local function getCharDB()
    return Addon.charDB
end

local function ensureCart()
    local db = getCharDB()
    if not db then return nil end
    if type(db.cart) ~= "table" then
        db.cart = { lines = {} }
    end
    if type(db.cart.lines) ~= "table" then
        db.cart.lines = {}
    end
    return db.cart
end

local function notifyChanged(reason)
    if type(Addon.SendMessage) == "function" then
        Addon:SendMessage("CraftOrders:CartChanged", reason)
    end
end

local function nowSeconds()
    if type(time) == "function" then return time() end
    return 0
end

local function validateLine(line)
    if type(line) ~= "table" then return "invalid-line" end
    local recipeKey = tonumber(line.recipeKey)
    local quantity  = tonumber(line.quantity)
    if not recipeKey or recipeKey == 0 then return "invalid-line-recipekey" end
    if not quantity or quantity <= 0 then return "invalid-line-quantity" end
    if type(line.crafter) ~= "string" or line.crafter == "" then return "missing-crafter" end
    return nil
end

function Cart:GetCart()
    return ensureCart()
end

function Cart:GetLines()
    local cart = ensureCart()
    return cart and cart.lines or {}
end

function Cart:CountLines()
    return #(self:GetLines() or {})
end

function Cart:IsEmpty()
    return self:CountLines() == 0
end

-- Returns the index of a line matching (recipeKey, crafter), or nil.
-- Used so AddLine can merge quantities into an existing entry rather
-- than spawning duplicate rows.
function Cart:FindLineIndex(recipeKey, crafter)
    local lines = self:GetLines()
    for index = 1, #lines do
        local line = lines[index]
        if line.recipeKey == recipeKey and line.crafter == crafter then
            return index
        end
    end
    return nil
end

-- Adds a line. If a line with the same (recipeKey, crafter) already
-- exists, quantities are merged (one cart row per recipe-per-crafter,
-- not one per click). Returns the index of the affected line and
-- whether it was a merge.
function Cart:AddLine(line)
    local err = validateLine(line)
    if err then return nil, err end

    local cart = ensureCart()
    if not cart then return nil, "store-not-ready" end

    local recipeKey = tonumber(line.recipeKey)
    local quantity  = tonumber(line.quantity)
    local crafter   = line.crafter

    local existingIndex = self:FindLineIndex(recipeKey, crafter)
    if existingIndex then
        local existing = cart.lines[existingIndex]
        existing.quantity = (tonumber(existing.quantity) or 0) + quantity
        existing.recipeLabel  = line.recipeLabel  or existing.recipeLabel
        existing.outputItemID = tonumber(line.outputItemID) or existing.outputItemID
        existing.updatedAt    = nowSeconds()
        notifyChanged("merge")
        return existingIndex, true
    end

    cart.lines[#cart.lines + 1] = {
        recipeKey    = recipeKey,
        quantity     = quantity,
        crafter      = crafter,
        recipeLabel  = line.recipeLabel,
        outputItemID = tonumber(line.outputItemID),
        addedAt      = nowSeconds(),
        updatedAt    = nowSeconds(),
    }
    notifyChanged("add")
    return #cart.lines, false
end

function Cart:RemoveLineAt(index)
    local cart = ensureCart()
    if not cart then return false, "store-not-ready" end
    index = tonumber(index)
    if not index or index < 1 or index > #cart.lines then
        return false, "invalid-index"
    end
    table.remove(cart.lines, index)
    notifyChanged("remove")
    return true
end

-- Mutates quantity and/or crafter for the line at the given index.
-- Quantity must remain positive. Crafter changes can cause a merge
-- with another line that already targets the new crafter for this
-- recipe; in that case the lines are collapsed and the merged-into
-- index is returned.
function Cart:UpdateLineAt(index, patch)
    local cart = ensureCart()
    if not cart then return nil, "store-not-ready" end
    index = tonumber(index)
    if not index or index < 1 or index > #cart.lines then
        return nil, "invalid-index"
    end
    if type(patch) ~= "table" then return nil, "invalid-patch" end

    local line = cart.lines[index]
    local newQuantity = patch.quantity ~= nil and tonumber(patch.quantity) or line.quantity
    local newCrafter  = patch.crafter  ~= nil and patch.crafter            or line.crafter

    if not newQuantity or newQuantity <= 0 then return nil, "invalid-line-quantity" end
    if type(newCrafter) ~= "string" or newCrafter == "" then return nil, "missing-crafter" end

    if newCrafter ~= line.crafter then
        local existing = self:FindLineIndex(line.recipeKey, newCrafter)
        if existing and existing ~= index then
            -- Merge: bump existing line, drop this one.
            cart.lines[existing].quantity = (tonumber(cart.lines[existing].quantity) or 0) + newQuantity
            cart.lines[existing].updatedAt = nowSeconds()
            table.remove(cart.lines, index)
            notifyChanged("merge")
            -- After remove, existing's index may have shifted down by 1
            -- if it was after the removed slot.
            if existing > index then existing = existing - 1 end
            return existing, true
        end
    end

    line.quantity = newQuantity
    line.crafter  = newCrafter
    line.updatedAt = nowSeconds()
    notifyChanged("update")
    return index, false
end

function Cart:Clear()
    local cart = ensureCart()
    if not cart then return end
    if #cart.lines == 0 then return end
    cart.lines = {}
    notifyChanged("clear")
end

-- Buckets lines by their target crafter. Returns:
--   { [crafterKey] = { crafter = ..., lines = { line1, line2, ... } }, ... }
-- Order within a bucket follows cart order.
function Cart:GroupByCrafter()
    local groups = {}
    local lines = self:GetLines()
    for index = 1, #lines do
        local line = lines[index]
        local crafterKey = line.crafter
        if type(crafterKey) == "string" and crafterKey ~= "" then
            local group = groups[crafterKey]
            if not group then
                group = { crafter = crafterKey, lines = {} }
                groups[crafterKey] = group
            end
            group.lines[#group.lines + 1] = line
        end
    end
    return groups
end

-- Translates the cart into N concrete orders via Store:CreateDraft —
-- one order per distinct crafter. Returns:
--   { created = {orderId, ...}, errors = {{crafter, reason}, ...} }
-- On full success the cart is cleared. On partial success the cart is
-- left intact for the user to retry; the caller decides what to do
-- with the partial result.
function Cart:Checkout(opts)
    opts = opts or {}
    local store = Addon.Store
    if not store then return nil, "store-not-ready" end

    local requester = opts.requester
    if type(requester) ~= "string" or requester == "" then
        if type(Addon.GetLocalPlayerKey) == "function" then
            requester = Addon:GetLocalPlayerKey()
        end
    end
    if type(requester) ~= "string" or requester == "" then
        return nil, "missing-requester"
    end

    local lines = self:GetLines()
    if #lines == 0 then return nil, "empty-cart" end

    local groups = self:GroupByCrafter()
    local result = { created = {}, errors = {} }

    -- Stable iteration order: sort crafter keys.
    local keys = {}
    for key in pairs(groups) do keys[#keys + 1] = key end
    table.sort(keys)

    for _, crafterKey in ipairs(keys) do
        local group = groups[crafterKey]
        local spec  = {
            requester    = requester,
            crafter      = crafterKey,
            deliveryMode = opts.deliveryMode or "mail",
            lines        = {},
        }
        for index = 1, #group.lines do
            local source = group.lines[index]
            spec.lines[index] = {
                recipeKey    = source.recipeKey,
                quantity     = source.quantity,
                recipeLabel  = source.recipeLabel,
                outputItemID = source.outputItemID,
            }
        end

        local order, err = store:CreateDraft(spec)
        if order then
            result.created[#result.created + 1] = order.id
        else
            result.errors[#result.errors + 1] = { crafter = crafterKey, reason = err }
        end
    end

    if #result.errors == 0 then
        self:Clear()
    end
    return result
end
