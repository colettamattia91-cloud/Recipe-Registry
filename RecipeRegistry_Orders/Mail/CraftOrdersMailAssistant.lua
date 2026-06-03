local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Assistant = {}
Addon.MailAssistant = Assistant

-- Outgoing-mail orchestration for material shipments.
--
-- Splits an order's required materials into batches no bigger than
-- ATTACHMENTS_PER_MAIL distinct items each, generates a subject and
-- body for each batch (human header + marker block at the bottom),
-- and exposes a SendBatch entry point that drives the WoW mailbox
-- API. v1 deliberately keeps the bag-scan / cursor dance behind a
-- supplier callback so the planning + composition is testable in
-- isolation; the in-game wiring lives in the plugin OnEnable path
-- once the unit-level logic is locked.

Assistant.ATTACHMENTS_PER_MAIL = 12
Assistant.SUBJECT_MAX = 50

local function shortenOrderId(id, length)
    if type(id) ~= "string" then return "?" end
    length = length or 8
    if #id <= length then return id end
    return id:sub(1, length)
end

-- Collects the items that should be shipped for the order. Skips
-- non-mailable, excluded, and zero-quantity buckets. Returns an array
-- of { itemID, count, name } sorted by itemID for deterministic
-- packing — same input always produces the same batch split.
function Assistant:GatherShippableItems(order)
    local out = {}
    if type(order) ~= "table" or type(order.materials) ~= "table" then
        return out
    end
    local ids = {}
    for itemID in pairs(order.materials) do ids[#ids + 1] = itemID end
    table.sort(ids)
    for index = 1, #ids do
        local bucket = order.materials[ids[index]]
        local provided = tonumber(bucket.requesterProvided) or 0
        if provided > 0 and bucket.mailable ~= false and bucket.excluded ~= true then
            out[#out + 1] = {
                itemID = bucket.itemID,
                count  = provided,
                name   = bucket.name,
            }
        end
    end
    return out
end

-- Splits the shippable items into batches of at most
-- ATTACHMENTS_PER_MAIL distinct items each. Each item ends up in
-- exactly one batch — this v1 packing does NOT split a single item
-- across mails based on its stack size. That's a deliberate phase-2
-- limitation: TBC stack-size data lives in GetItemInfo which is not
-- guaranteed to be cached at composition time, so we defer per-stack
-- splitting until a later iteration that can scan the bag inventory.
function Assistant:PlanBatches(order)
    local items = self:GatherShippableItems(order)
    local batches = {}
    if #items == 0 then return batches end

    local perMail = self.ATTACHMENTS_PER_MAIL
    local cursor = 1
    while cursor <= #items do
        local batchItems = {}
        for offset = 0, perMail - 1 do
            local source = items[cursor + offset]
            if not source then break end
            batchItems[#batchItems + 1] = source
        end
        batches[#batches + 1] = {
            batchNumber  = #batches + 1,
            totalBatches = 0,         -- patched below once we know the total
            items        = batchItems,
        }
        cursor = cursor + perMail
    end

    for index = 1, #batches do
        batches[index].totalBatches = #batches
    end
    return batches
end

function Assistant:FormatSubject(order, batch)
    -- "[RR] Order <shortId> (b/B)" keeps it under the 50-char target.
    local shortId = shortenOrderId(order and order.id, 8)
    return string.format("[RR] Order %s (%d/%d)",
        shortId, batch.batchNumber or 1, batch.totalBatches or 1)
end

-- Builds the multi-line human-readable header above the marker. The
-- format is deliberately readable as a normal in-game letter; only
-- the trailing marker block is machine-parsed.
local function buildBodyHeader(order, batch)
    local lines = {}
    lines[#lines + 1] = string.format("Materials for order %s",
        shortenOrderId(order and order.id, 12))
    lines[#lines + 1] = string.format("Batch %d of %d",
        batch.batchNumber or 1, batch.totalBatches or 1)
    if order.lines and #order.lines > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Recipes:"
        for index = 1, #order.lines do
            local line = order.lines[index]
            lines[#lines + 1] = string.format("  - %s x%d",
                tostring(line.recipeLabel or ("recipe:" .. tostring(line.recipeKey))),
                tonumber(line.quantity) or 0)
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Attached:"
    for index = 1, #batch.items do
        local item = batch.items[index]
        lines[#lines + 1] = string.format("  - %s x%d",
            tostring(item.name or ("item:" .. tostring(item.itemID))),
            tonumber(item.count) or 0)
    end
    return table.concat(lines, "\n")
end

-- Returns the items map { [itemID] = count } that the marker codec
-- consumes. Extracted as a method so the scanner-side equality check
-- has a single helper to call.
function Assistant:BatchItemsAsMap(batch)
    local out = {}
    if type(batch) ~= "table" or type(batch.items) ~= "table" then return out end
    for index = 1, #batch.items do
        local item = batch.items[index]
        if item and item.itemID then
            out[item.itemID] = (out[item.itemID] or 0) + (tonumber(item.count) or 0)
        end
    end
    return out
end

-- Composes a full mail spec for a single batch:
--   { recipient, subject, body, attachments = { {itemID,count,name}, ... } }
-- The body already includes the marker block; callers should pass
-- subject/body verbatim to SendMail. recipient defaults to the
-- order's crafter (Char-Realm key).
function Assistant:ComposeMail(order, batch)
    if type(order) ~= "table" then return nil, "invalid-order" end
    if type(batch) ~= "table" then return nil, "invalid-batch" end
    if type(order.crafter) ~= "string" or order.crafter == "" then
        return nil, "missing-crafter"
    end
    if type(order.requester) ~= "string" or order.requester == "" then
        return nil, "missing-requester"
    end

    local marker = Addon.MailMarker
    if not (marker and type(marker.Encode) == "function") then
        return nil, "marker-missing"
    end

    local markerBlock, err = marker:Encode({
        orderId      = order.id,
        requester    = order.requester,
        crafter      = order.crafter,
        batchNumber  = batch.batchNumber,
        totalBatches = batch.totalBatches,
        items        = self:BatchItemsAsMap(batch),
    })
    if not markerBlock then return nil, err end

    local body = buildBodyHeader(order, batch) .. "\n\n" .. markerBlock
    return {
        recipient   = order.crafter,
        subject     = self:FormatSubject(order, batch),
        body        = body,
        attachments = batch.items,
    }
end

-- Drives the actual mail send for one batch. Preconditions:
--   - mailbox open (or test caller bypass via opts.skipMailboxCheck)
--   - supplier(itemID, count) callback returns true after staging the
--     item on the cursor (so ClickSendMailItemButton picks it up).
--     In production the supplier is a bag-scan helper; in tests it's
--     a stub that calls Wow.PutItemOnCursor before returning.
-- Returns true on success, or false + reason on failure. Failure
-- modes are explicit so the caller can branch (no-attachments,
-- supplier-fail, ...).
function Assistant:SendBatch(order, batch, supplier, opts)
    opts = opts or {}
    if type(supplier) ~= "function" then return false, "missing-supplier" end

    if not opts.skipMailboxCheck then
        -- The TBC API doesn't expose IsMailboxOpen as a global, but
        -- SendMail will fail silently when the mailbox isn't open.
        -- We surface that explicitly rather than letting a no-op slip
        -- through. The host checks MAIL_SHOW/MAIL_CLOSED to flip a
        -- local flag; we read that flag via getMailboxOpen below.
        if type(self.IsMailboxOpen) == "function" and not self:IsMailboxOpen() then
            return false, "mailbox-closed"
        end
    end

    local mail, composeErr = self:ComposeMail(order, batch)
    if not mail then return false, composeErr end
    if #mail.attachments == 0 then return false, "no-attachments" end

    if type(_G.ClickSendMailItemButton) ~= "function"
        or type(_G.SendMail) ~= "function" then
        return false, "mail-api-missing"
    end

    for slot = 1, #mail.attachments do
        local item = mail.attachments[slot]
        local ok = supplier(item.itemID, item.count)
        if not ok then
            return false, "supplier-failed:" .. tostring(item.itemID)
        end
        _G.ClickSendMailItemButton(slot)
    end

    _G.SendMail(mail.recipient, mail.subject, mail.body)
    return true
end

-- The host updates this flag from MAIL_SHOW/MAIL_CLOSED events. We
-- expose it as a method so tests can override; the production path
-- has the plugin's mailbox handler call SetMailboxOpen(true/false).
function Assistant:SetMailboxOpen(value)
    self._mailboxOpen = value == true
end

function Assistant:IsMailboxOpen()
    return self._mailboxOpen == true
end
