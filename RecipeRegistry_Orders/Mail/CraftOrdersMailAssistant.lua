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

-- Pre-fills WoW's SendMail UI (recipient / subject / body) with the
-- composed batch so the user only needs to drag-and-drop attachments
-- and click Send. This is the "Compose" UX path — keeps the
-- attachment flow manual (no bag scan needed) while removing the
-- copy-paste of subject + body.
--
-- Returns true on success or false + reason on failure. Reasons are
-- explicit so the Board can surface a helpful error: mailbox-closed,
-- invalid-order, no-shippable-items, send-ui-missing.
function Assistant:OpenComposer(order, opts)
    opts = opts or {}
    if not self:IsMailboxOpen() then return false, "mailbox-closed" end

    local batches = self:PlanBatches(order)
    if #batches == 0 then return false, "no-shippable-items" end

    -- v1 always composes the first batch. Multi-batch orders need
    -- the user to come back to the mailbox per batch — the composer
    -- only stages one mail at a time because the UI can only hold
    -- one outgoing message.
    local batchIndex = tonumber(opts.batchIndex) or 1
    local batch = batches[batchIndex]
    if not batch then return false, "batch-out-of-range" end

    local mail, err = self:ComposeMail(order, batch)
    if not mail then return false, err end

    -- Find the SendMail UI globals. Their names are stable across
    -- the TBC client; defensive nil-checks below mean an addon that
    -- breaks one of these globals (very rare) downgrades to a no-op
    -- with a clean error rather than throwing.
    local sendTab    = _G.MailFrameTab2
    local nameBox    = _G.SendMailNameEditBox
    local subjectBox = _G.SendMailSubjectEditBox
    local bodyBox    = _G.SendMailBodyEditBox
    if not (subjectBox and bodyBox and nameBox) then
        return false, "send-ui-missing"
    end

    if sendTab and type(sendTab.Click) == "function" then
        sendTab:Click()
    end
    if type(nameBox.SetText) == "function" then
        nameBox:SetText(mail.recipient)
    end
    if type(subjectBox.SetText) == "function" then
        subjectBox:SetText(mail.subject)
    end
    if type(bodyBox.SetText) == "function" then
        bodyBox:SetText(mail.body)
    end

    -- Remember the staged send so a follow-up MAIL_SEND_SUCCESS event
    -- can credit the right batch on the right order. Times out after
    -- PENDING_SEND_TTL seconds so an unrelated successful send fired
    -- minutes later doesn't get misattributed.
    local now = time and time() or 0
    self._pendingSend = {
        orderId      = order.id,
        batchIndex   = batchIndex,
        totalBatches = #batches,
        recipient    = mail.recipient,
        items        = self:BatchItemsAsMap(batch),
        stagedAt     = now,
        expiresAt    = now + self.PENDING_SEND_TTL,
    }

    -- Auto-attach via the bag-scan supplier unless the caller opts
    -- out (opts.autoAttach == false) or BagScan is unavailable. The
    -- user always retains the final click on the in-game Send button,
    -- so a wrong attach is recoverable: they see what landed in the
    -- slots and can cancel before sending.
    local autoAttach = opts.autoAttach
    if autoAttach == nil then autoAttach = true end
    local attachSummary
    if autoAttach then
        local summary = self:AutoAttachBatch(order, batchIndex)
        if type(summary) == "table" then attachSummary = summary end
    end

    return true, {
        recipient    = mail.recipient,
        subject      = mail.subject,
        batchIndex   = batchIndex,
        totalBatches = #batches,
        autoAttach   = attachSummary,
    }
end

-- Default TTL on a staged Compose (seconds). After this window the
-- pending-send is dropped so an unrelated mail success doesn't get
-- attributed to the wrong order.
Assistant.PENDING_SEND_TTL = 120

-- Returns the pending-send descriptor if still valid; clears + returns
-- nil if expired. Used by the Mailbox MAIL_SEND_SUCCESS handler so the
-- TTL check lives in one place.
function Assistant:ConsumePendingSend(now)
    local pending = self._pendingSend
    if not pending then return nil end
    now = tonumber(now) or (time and time() or 0)
    self._pendingSend = nil
    if pending.expiresAt and now > pending.expiresAt then return nil end
    return pending
end

function Assistant:PeekPendingSend()
    return self._pendingSend
end

function Assistant:ClearPendingSend()
    self._pendingSend = nil
end

-- Returns a supplier callback bound to BagScan. The callback walks
-- the bag inventory for each itemID and either picks up the full
-- stack or splits the exact count onto the cursor; SendBatch's
-- ClickSendMailItemButton then attaches whatever's on the cursor.
-- Used internally by OpenComposer's auto-attach path and also
-- exposed so slash commands / tests can opt in directly.
function Assistant:DefaultBagSupplier()
    local bagScan = Addon.BagScan
    if not (bagScan and type(bagScan.Pick) == "function") then return nil end
    return function(itemID, count)
        local ok = bagScan:Pick(itemID, count)
        return ok == true
    end
end

-- Auto-attaches the items of a single batch by driving the bag-scan
-- supplier + ClickSendMailItemButton, WITHOUT calling SendMail. The
-- user reviews the staged mail and clicks the in-game Send button
-- themselves. Returns a summary:
--   { attached = N, missing = { { itemID, needed, available }, ... } }
-- Missing entries cover both no-stack and split-across-stacks
-- failures; the user attaches those slots manually.
-- Returns the finished items the crafter owes the requester for this
-- order: { itemID, count, name } per distinct output. v1 looks up
-- numCreated per craft via RR's recipe display info; when that's
-- unavailable, falls back to assuming 1 output per craft. Lines
-- without a known outputItemID are dropped.
function Assistant:PlanDeliveryItems(order)
    local out = {}
    if type(order) ~= "table" or type(order.lines) ~= "table" then return out end

    local rr = _G.RecipeRegistry
    local getInfo
    if rr and rr.Data and type(rr.Data.GetRecipeDisplayInfo) == "function" then
        getInfo = function(key)
            local ok, info = pcall(rr.Data.GetRecipeDisplayInfo, rr.Data, key)
            if ok then return info end
        end
    end

    local totals = {}
    for index = 1, #order.lines do
        local line = order.lines[index]
        local quantity = tonumber(line.quantity) or 0
        if quantity > 0 then
            local info = getInfo and getInfo(line.recipeKey) or nil
            local outputItemID = line.outputItemID
                or (info and info.createdItemID)
            if outputItemID then
                local numCreated = tonumber(info and info.numCreated) or 1
                local total = quantity * numCreated
                local bucket = totals[outputItemID]
                if not bucket then
                    bucket = {
                        itemID = outputItemID,
                        name   = info and (info.createdItemName or info.label) or nil,
                        count  = 0,
                    }
                    totals[outputItemID] = bucket
                end
                bucket.count = bucket.count + total
            end
        end
    end

    -- Deterministic order so the batch packing is stable.
    local ids = {}
    for itemID in pairs(totals) do ids[#ids + 1] = itemID end
    table.sort(ids)
    for _, itemID in ipairs(ids) do out[#out + 1] = totals[itemID] end
    return out
end

-- Splits the delivery items into batches under ATTACHMENTS_PER_MAIL.
-- Same packing logic as PlanBatches but sources from the planned
-- output table instead of the materials buckets, and tags each batch
-- with kind = "delivery" so downstream code never mistakes one for
-- the other.
function Assistant:PlanDeliveryBatches(order)
    local items = self:PlanDeliveryItems(order)
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
            totalBatches = 0,
            kind         = "delivery",
            items        = batchItems,
        }
        cursor = cursor + perMail
    end
    for index = 1, #batches do batches[index].totalBatches = #batches end
    return batches
end

function Assistant:ComposeDeliveryMail(order, batch)
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
        kind         = marker.KIND_DELIVERY,
        batchNumber  = batch.batchNumber,
        totalBatches = batch.totalBatches,
        items        = self:BatchItemsAsMap(batch),
    })
    if not markerBlock then return nil, err end

    local lines = {}
    lines[#lines + 1] = string.format("Delivery for order %s",
        shortenOrderId(order.id, 12))
    lines[#lines + 1] = string.format("Batch %d of %d",
        batch.batchNumber or 1, batch.totalBatches or 1)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Attached:"
    for index = 1, #batch.items do
        local item = batch.items[index]
        lines[#lines + 1] = string.format("  - %s x%d",
            tostring(item.name or ("item:" .. tostring(item.itemID))),
            tonumber(item.count) or 0)
    end

    local body = table.concat(lines, "\n") .. "\n\n" .. markerBlock
    return {
        recipient   = order.requester,
        subject     = string.format("[RR] Delivery %s (%d/%d)",
            shortenOrderId(order.id, 8),
            batch.batchNumber or 1, batch.totalBatches or 1),
        body        = body,
        attachments = batch.items,
    }
end

-- Symmetrical to OpenComposer but for the delivery half of the flow.
-- Same pending-send TTL bookkeeping so MAIL_SEND_SUCCESS credits the
-- delivery batch on the crafter's side.
function Assistant:OpenDeliveryComposer(order, opts)
    opts = opts or {}
    if not self:IsMailboxOpen() then return false, "mailbox-closed" end

    local batches = self:PlanDeliveryBatches(order)
    if #batches == 0 then return false, "no-shippable-outputs" end

    local batchIndex = tonumber(opts.batchIndex) or 1
    local batch = batches[batchIndex]
    if not batch then return false, "batch-out-of-range" end

    local mail, err = self:ComposeDeliveryMail(order, batch)
    if not mail then return false, err end

    local nameBox    = _G.SendMailNameEditBox
    local subjectBox = _G.SendMailSubjectEditBox
    local bodyBox    = _G.SendMailBodyEditBox
    if not (subjectBox and bodyBox and nameBox) then
        return false, "send-ui-missing"
    end
    local sendTab = _G.MailFrameTab2
    if sendTab and type(sendTab.Click) == "function" then sendTab:Click() end
    if type(nameBox.SetText) == "function"    then nameBox:SetText(mail.recipient)    end
    if type(subjectBox.SetText) == "function" then subjectBox:SetText(mail.subject)   end
    if type(bodyBox.SetText) == "function"    then bodyBox:SetText(mail.body)         end

    local now = time and time() or 0
    self._pendingSend = {
        orderId      = order.id,
        batchIndex   = batchIndex,
        totalBatches = #batches,
        recipient    = mail.recipient,
        items        = self:BatchItemsAsMap(batch),
        kind         = "delivery",
        stagedAt     = now,
        expiresAt    = now + self.PENDING_SEND_TTL,
    }

    -- Auto-attach via BagScan unless the caller opts out. The crafter
    -- has the finished items in their bags so the same supplier path
    -- works for delivery.
    local autoAttach = opts.autoAttach
    if autoAttach == nil then autoAttach = true end
    local attachSummary
    if autoAttach then
        local summary = self:AutoAttachDeliveryBatch(order, batchIndex)
        if type(summary) == "table" then attachSummary = summary end
    end

    return true, {
        recipient    = mail.recipient,
        subject      = mail.subject,
        batchIndex   = batchIndex,
        totalBatches = #batches,
        autoAttach   = attachSummary,
        kind         = "delivery",
    }
end

function Assistant:AutoAttachDeliveryBatch(order, batchIndex)
    local batches = self:PlanDeliveryBatches(order)
    if #batches == 0 then return nil, "no-shippable-outputs" end
    batchIndex = tonumber(batchIndex) or 1
    local batch = batches[batchIndex]
    if not batch then return nil, "batch-out-of-range" end

    local supplier = self:DefaultBagSupplier()
    if not supplier then return nil, "bag-scan-missing" end
    if type(_G.ClickSendMailItemButton) ~= "function" then
        return nil, "mail-api-missing"
    end

    local bagScan = Addon.BagScan
    local result = { attached = 0, missing = {} }
    local nextSlot = 1
    for index = 1, #batch.items do
        local item = batch.items[index]
        local need = tonumber(item.count) or 0
        local available = bagScan and bagScan:CountItem(item.itemID) or 0
        if need <= 0 then
            -- nothing to do
        elseif supplier(item.itemID, need) then
            _G.ClickSendMailItemButton(nextSlot)
            nextSlot = nextSlot + 1
            result.attached = result.attached + 1
        else
            result.missing[#result.missing + 1] = {
                itemID    = item.itemID,
                name      = item.name,
                needed    = need,
                available = available,
            }
        end
    end
    return result
end

function Assistant:AutoAttachBatch(order, batchIndex)
    local batches = self:PlanBatches(order)
    if #batches == 0 then return nil, "no-shippable-items" end
    batchIndex = tonumber(batchIndex) or 1
    local batch = batches[batchIndex]
    if not batch then return nil, "batch-out-of-range" end

    local supplier = self:DefaultBagSupplier()
    if not supplier then return nil, "bag-scan-missing" end
    if type(_G.ClickSendMailItemButton) ~= "function" then
        return nil, "mail-api-missing"
    end

    local bagScan = Addon.BagScan
    local result = { attached = 0, missing = {} }

    -- Track the cursor slot ourselves: a successful attach goes into
    -- slot N where N is the next free attach button. The WoW UI auto-
    -- selects the first free slot when ClickSendMailItemButton is
    -- called without a slot id, but we pass explicit slots so the
    -- attach order matches the batch order (easier for the user to
    -- read against the body's "Attached:" list).
    local nextSlot = 1
    for index = 1, #batch.items do
        local item = batch.items[index]
        local need = tonumber(item.count) or 0
        local available = bagScan and bagScan:CountItem(item.itemID) or 0
        if need <= 0 then
            -- nothing to do
        elseif supplier(item.itemID, need) then
            _G.ClickSendMailItemButton(nextSlot)
            nextSlot = nextSlot + 1
            result.attached = result.attached + 1
        else
            result.missing[#result.missing + 1] = {
                itemID    = item.itemID,
                name      = item.name,
                needed    = need,
                available = available,
            }
        end
    end
    return result
end
