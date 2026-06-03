local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Mailbox = {}
Addon.Mailbox = Mailbox

-- Mailbox-event orchestrator. Subscribes to MAIL_SHOW / MAIL_CLOSED
-- and routes incoming mails through the scanner -> integrity -> store
-- ledger pipeline. Owns no business logic of its own — it's the glue
-- between WoW's mailbox events and the assistant / scanner / store
-- pieces so each of those can be unit-tested in isolation without an
-- event loop.

-- Walks every entry returned by the scanner and, for each mail whose
-- marker.orderId names a known local order, runs the §7.4 integrity
-- check and writes the receipt to the store ledger. Returns a small
-- summary { scanned, recognized, recorded, tampered } so the slash
-- command and tests can introspect the run.
function Mailbox:ProcessInbox(opts)
    opts = opts or {}
    local summary = { scanned = 0, recognized = 0, recorded = 0, tampered = 0 }

    local scanner = Addon.MailScanner
    if not (scanner and type(scanner.ScanInbox) == "function") then
        return summary
    end
    local store = Addon.Store
    if not (store and type(store.GetOrder) == "function"
        and type(store.RecordBatchReceipt) == "function") then
        return summary
    end

    local results = scanner:ScanInbox({ realm = opts.realm })
    summary.scanned = #results

    for index = 1, #results do
        local entry = results[index]
        local marker = entry.marker
        local order = marker and marker.orderId and store:GetOrder(marker.orderId) or nil
        if order then
            summary.recognized = summary.recognized + 1
            local outcome = scanner:VerifyIntegrity(entry, order)

            local ok
            if marker.kind == "delivery" then
                if type(store.RecordDelivery) == "function" then
                    ok = store:RecordDelivery(order.id, {
                        batchNumber = marker.batchNumber or 1,
                        expected    = marker.items or {},
                        observed    = entry.observed or {},
                        sender      = entry.sender,
                        source      = "scanner",
                        mailIndex   = entry.mailIndex,
                        actor       = "system",
                        senderMatch = outcome.senderMatch,
                        hashMatch   = outcome.hashMatch,
                        itemsMatch  = outcome.itemsMatch,
                        batchMatch  = outcome.batchMatch,
                        valid       = outcome.valid,
                        tamperFlags = outcome.tamperFlags,
                    })
                    if ok then summary.delivered = (summary.delivered or 0) + 1 end
                end
            else
                ok = store:RecordBatchReceipt(order.id, marker.batchNumber or 1, {
                    expected    = marker.items or {},
                    observed    = entry.observed or {},
                    sender      = entry.sender,
                    source      = "scanner",
                    mailIndex   = entry.mailIndex,
                    receivedAt  = opts.now,
                    actor       = "system",
                    senderMatch = outcome.senderMatch,
                    hashMatch   = outcome.hashMatch,
                    itemsMatch  = outcome.itemsMatch,
                    batchMatch  = outcome.batchMatch,
                    valid       = outcome.valid,
                    tamperFlags = outcome.tamperFlags,
                })
            end

            if ok then summary.recorded = summary.recorded + 1 end
            if outcome.tamperFlags and #outcome.tamperFlags > 0 then
                summary.tampered = summary.tampered + 1
            end
        end
    end

    return summary
end

-- Consumes the Assistant's pending-send descriptor (if still valid)
-- and records the batch as sent on the order's ledger. Idempotent
-- when there's no pending or the TTL has expired. Returns the slot
-- on success, nil + reason otherwise.
function Mailbox:OnMailSendSuccess()
    local assistant = Addon.MailAssistant
    if not (assistant and type(assistant.ConsumePendingSend) == "function") then
        return nil, "assistant-missing"
    end
    local pending = assistant:ConsumePendingSend()
    if not pending then return nil, "no-pending-send" end

    local store = Addon.Store
    if not (store and type(store.RecordBatchSent) == "function") then
        return nil, "store-not-ready"
    end

    if pending.kind == "delivery" then
        -- Delivery sends are bookkept on order.delivered directly so a
        -- successful crafter -> requester mail materializes the
        -- outputs immediately for the crafter side. The requester
        -- side will see the same update via the scanner when their
        -- mailbox opens, but tagging it here keeps the crafter's UI
        -- responsive without waiting for the round trip.
        if type(store.RecordDelivery) ~= "function" then
            return nil, "delivery-recorder-missing"
        end
        local ok, err = store:RecordDelivery(pending.orderId, {
            batchNumber = pending.batchIndex,
            observed    = pending.items or {},
            source      = "self-sent",
            actor       = "crafter",
            valid       = true,
        })
        if not ok then return nil, err end
        return { kind = "delivery" }
    end

    local ok, slot = store:RecordBatchSent(pending.orderId, pending.batchIndex, {
        recipient = pending.recipient,
        items     = pending.items,
        sentBy    = Addon.GetLocalPlayerKey and Addon:GetLocalPlayerKey() or nil,
        actor     = "requester",
    })
    if not ok then return nil, slot end
    return slot
end

-- Lifecycle entry point called from the plugin's OnEnable. Idempotent.
-- Skips silently when the host doesn't expose RegisterEvent (test
-- harness lite mode); tests drive ProcessInbox / OnMailSendSuccess
-- directly.
function Mailbox:OnEnable()
    if self._wired then return end
    if type(Addon.RegisterEvent) ~= "function" then return end

    Addon:RegisterEvent("MAIL_SHOW", function()
        if Addon.MailAssistant and Addon.MailAssistant.SetMailboxOpen then
            Addon.MailAssistant:SetMailboxOpen(true)
        end
        Mailbox:ProcessInbox()
    end)
    Addon:RegisterEvent("MAIL_CLOSED", function()
        if Addon.MailAssistant and Addon.MailAssistant.SetMailboxOpen then
            Addon.MailAssistant:SetMailboxOpen(false)
        end
    end)
    -- MAIL_INBOX_UPDATE fires repeatedly as the inbox paginates; we
    -- run the same pipeline so receipts land even when the mailbox
    -- was already open at login.
    Addon:RegisterEvent("MAIL_INBOX_UPDATE", function()
        Mailbox:ProcessInbox()
    end)
    -- MAIL_SEND_SUCCESS lets the assistant credit a Compose'd batch
    -- as actually sent (sentAt stamp on the ledger).
    Addon:RegisterEvent("MAIL_SEND_SUCCESS", function()
        Mailbox:OnMailSendSuccess()
    end)

    self._wired = true
end
