local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Store = {}
Addon.Store = Store

local function getStateMachine()
    return Addon.StateMachine
end

local function generateOrderId()
    -- Order IDs are locally generated and only need to be unique within the
    -- producer's local store. Sync collisions across producers are avoided
    -- because peers carry their own producer key alongside the seq.
    return string.format("rr-ord-%d-%04d", time(), math.random(0, 9999))
end

local function ensureDB()
    if not (Addon.db and Addon.db.global) then
        error("CraftOrders store accessed before AceDB init")
    end
    local db = Addon.db.global
    db.orders = db.orders or {}
    db.events = db.events or { seq = 0, log = {}, tombstones = {} }
    db.events.log = db.events.log or {}
    db.events.tombstones = db.events.tombstones or {}
    return db
end

function Store:GetDB()
    return ensureDB()
end

function Store:GetOrder(orderId)
    if type(orderId) ~= "string" or orderId == "" then return nil end
    return self:GetDB().orders[orderId]
end

function Store:CountOrders()
    local count = 0
    for _ in pairs(self:GetDB().orders) do
        count = count + 1
    end
    return count
end

function Store:ListOrders(filter)
    filter = filter or {}
    local out = {}
    for _, order in pairs(self:GetDB().orders) do
        local include = true
        if filter.status and order.status ~= filter.status then include = false end
        if filter.requester and order.requester ~= filter.requester then include = false end
        if filter.crafter and order.crafter ~= filter.crafter then include = false end
        if include then
            out[#out + 1] = order
        end
    end
    table.sort(out, function(a, b)
        return (a.createdAt or 0) > (b.createdAt or 0)
    end)
    return out
end

local function validateSpec(spec)
    if type(spec) ~= "table" then return "invalid-spec" end
    if type(spec.requester) ~= "string" or spec.requester == "" then return "missing-requester" end
    if type(spec.crafter) ~= "string" or spec.crafter == "" then return "missing-crafter" end
    if type(spec.lines) ~= "table" or #spec.lines == 0 then return "no-lines" end
    for index = 1, #spec.lines do
        local line = spec.lines[index]
        if type(line) ~= "table" then return "invalid-line" end
        local recipeKey = tonumber(line.recipeKey)
        local quantity = tonumber(line.quantity)
        if not recipeKey or recipeKey == 0 then return "invalid-line-recipekey" end
        if not quantity or quantity <= 0 then return "invalid-line-quantity" end
    end
    return nil
end

function Store:CreateDraft(spec)
    local err = validateSpec(spec)
    if err then return nil, err end

    local SM = getStateMachine()
    local now = time()
    local order = {
        id            = generateOrderId(),
        schemaVersion = 1,
        requester     = spec.requester,
        crafter       = spec.crafter,
        createdAt     = now,
        updatedAt     = now,
        status        = SM.STATES.DRAFT,
        deliveryMode  = spec.deliveryMode or "mail",
        lines         = {},
        materials     = {},
        batches       = {},
        notes         = spec.notes or "",
        expiresAt     = nil,
    }
    for index = 1, #spec.lines do
        local line = spec.lines[index]
        order.lines[#order.lines + 1] = {
            recipeKey    = tonumber(line.recipeKey),
            quantity     = tonumber(line.quantity),
            recipeLabel  = line.recipeLabel,
            outputItemID = tonumber(line.outputItemID),
        }
    end

    self:GetDB().orders[order.id] = order

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end

    -- OrderCreated carries the full order snapshot so a remote peer's
    -- reducer can materialize the order from a single event, without
    -- needing additional bootstrap. lineCount stays in the payload as
    -- a redundant sanity field — the reducer cross-checks it against
    -- #lines after deserializing.
    local snapshotLines = {}
    for index = 1, #order.lines do
        local source = order.lines[index]
        snapshotLines[index] = {
            recipeKey    = source.recipeKey,
            quantity     = source.quantity,
            recipeLabel  = source.recipeLabel,
            outputItemID = source.outputItemID,
        }
    end
    self:AppendEvent({
        kind    = "OrderCreated",
        orderId = order.id,
        actor   = spec.requester,
        payload = {
            requester    = order.requester,
            crafter      = order.crafter,
            deliveryMode = order.deliveryMode,
            notes        = order.notes,
            lines        = snapshotLines,
            lineCount    = #order.lines,
            createdAt    = order.createdAt,
        },
    })

    return order
end

function Store:AddLine(orderId, line, actor)
    local order = self:GetOrder(orderId)
    if not order then return false, "unknown-order" end

    local SM = getStateMachine()
    if order.status ~= SM.STATES.DRAFT then
        return false, "not-draft"
    end

    if type(line) ~= "table" then return false, "invalid-line" end
    local recipeKey = tonumber(line.recipeKey)
    local quantity = tonumber(line.quantity)
    if not recipeKey or recipeKey == 0 then return false, "invalid-line-recipekey" end
    if not quantity or quantity <= 0 then return false, "invalid-line-quantity" end

    order.lines[#order.lines + 1] = {
        recipeKey    = recipeKey,
        quantity     = quantity,
        recipeLabel  = line.recipeLabel,
        outputItemID = tonumber(line.outputItemID),
    }
    order.updatedAt = time()

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end

    self:AppendEvent({
        kind    = "OrderUpdated",
        orderId = orderId,
        actor   = actor or order.requester,
        payload = {
            change      = "line-added",
            recipeKey   = recipeKey,
            quantity    = quantity,
            recipeLabel = line.recipeLabel,
            lineIndex   = #order.lines,
        },
    })
    return true, order
end

function Store:RemoveLine(orderId, lineIndex, actor)
    local order = self:GetOrder(orderId)
    if not order then return false, "unknown-order" end

    local SM = getStateMachine()
    if order.status ~= SM.STATES.DRAFT then
        return false, "not-draft"
    end

    lineIndex = tonumber(lineIndex)
    if not lineIndex or lineIndex < 1 or lineIndex > #(order.lines or {}) then
        return false, "invalid-line-index"
    end

    if #order.lines == 1 then
        return false, "last-line-protected"
    end

    local removed = table.remove(order.lines, lineIndex)
    order.updatedAt = time()

    if Addon.Planner and Addon.Planner.RecomputeOrder then
        Addon.Planner:RecomputeOrder(order)
    end

    self:AppendEvent({
        kind    = "OrderUpdated",
        orderId = orderId,
        actor   = actor or order.requester,
        payload = {
            change      = "line-removed",
            recipeKey   = removed and removed.recipeKey,
            quantity    = removed and removed.quantity,
            lineIndex   = lineIndex,
        },
    })
    return true, order
end

function Store:DeleteOrder(orderId, reason)
    local order = self:GetOrder(orderId)
    if not order then return false, "unknown-order" end

    local SM = getStateMachine()
    if order.status ~= SM.STATES.DRAFT then
        return false, "not-draft"
    end

    self:GetDB().orders[orderId] = nil

    self:AppendEvent({
        kind    = "Pruned",
        orderId = orderId,
        actor   = "system",
        payload = { reason = reason or "user-delete" },
    })
    self:GetDB().events.tombstones[orderId] = {
        at     = time(),
        reason = reason or "user-delete",
    }
    return true
end

-- Allows the requester to mark some quantity of a material as supplied
-- by the crafter (or pull it back to requester-provided). Provider is
-- "requester" or "crafter". Quantity is optional — when omitted the
-- full required amount goes to the named provider.
--
-- The total required quantity does not change; only the split between
-- requester-supplied and crafter-supplied does. Restricted to Draft
-- orders since this controls what the mail assistant will attach.
function Store:SetProvider(orderId, itemID, provider, quantity, actor)
    local order = self:GetOrder(orderId)
    if not order then return false, "unknown-order" end

    local SM = getStateMachine()
    if order.status ~= SM.STATES.DRAFT then
        return false, "not-draft"
    end

    if provider ~= "requester" and provider ~= "crafter" then
        return false, "invalid-provider"
    end

    itemID = tonumber(itemID)
    if not itemID then return false, "invalid-itemid" end

    local bucket = order.materials and order.materials[itemID] or nil
    if not bucket then return false, "unknown-material" end

    local required = tonumber(bucket.required) or 0
    if required <= 0 then return false, "material-required-zero" end

    local target = tonumber(quantity)
    if target == nil then
        target = required
    end
    if target < 0 then target = 0 end
    if target > required then target = required end

    local previousRequester = bucket.requesterProvided or 0
    local previousCrafter = bucket.crafterProvided or 0

    if provider == "crafter" then
        bucket.crafterProvided   = target
        bucket.requesterProvided = required - target
    else
        bucket.requesterProvided = target
        bucket.crafterProvided   = required - target
    end

    order.updatedAt = time()

    self:AppendEvent({
        kind    = "OrderUpdated",
        orderId = orderId,
        actor   = actor or order.requester,
        payload = {
            change            = "provider-set",
            itemID            = itemID,
            provider          = provider,
            quantity          = target,
            previousRequester = previousRequester,
            previousCrafter   = previousCrafter,
            newRequester      = bucket.requesterProvided,
            newCrafter        = bucket.crafterProvided,
        },
    })
    return true, bucket
end

function Store:Transition(orderId, toState, actor, payload)
    local order = self:GetOrder(orderId)
    if not order then return false, "unknown-order" end

    local SM = getStateMachine()
    local ok, err = SM:CanTransition(order.status, toState, actor)
    if not ok then return false, err end

    local fromState = order.status
    order.status = toState
    order.updatedAt = time()

    self:AppendEvent({
        kind    = "OrderUpdated",
        orderId = orderId,
        actor   = actor,
        payload = {
            change    = "state-transition",
            fromState = fromState,
            toState   = toState,
            details   = payload,
        },
    })
    return true
end

function Store:AppendEvent(event)
    if type(event) ~= "table" or type(event.kind) ~= "string" then
        return nil, "invalid-event"
    end
    local db = self:GetDB()
    db.events.seq = (db.events.seq or 0) + 1

    local producer = Addon.GetLocalPlayerKey and Addon:GetLocalPlayerKey() or "?"
    local entry = {
        seq           = db.events.seq,
        producer      = producer,
        orderId       = event.orderId,
        kind          = event.kind,
        actor         = event.actor,
        at            = time(),
        payload       = event.payload or {},
        schemaVersion = 1,
    }
    db.events.log[#db.events.log + 1] = entry

    -- Broadcast a generic "something changed" signal so subscribers
    -- (Board, future tooltip integrations) can re-render. Uses
    -- AceEvent-3.0 messages via the addon mixin; tests stub these as
    -- no-ops so the assertion harness is unaffected.
    if type(Addon.SendMessage) == "function" then
        Addon:SendMessage("CraftOrders:Changed", entry.kind, entry.orderId)
    end

    return entry
end

function Store:CountEvents()
    return #(self:GetDB().events.log or {})
end

function Store:GetRecentEvents(limit)
    limit = tonumber(limit) or 10
    local log = self:GetDB().events.log or {}
    local out = {}
    local start = math.max(1, #log - limit + 1)
    for index = start, #log do
        out[#out + 1] = log[index]
    end
    return out
end
