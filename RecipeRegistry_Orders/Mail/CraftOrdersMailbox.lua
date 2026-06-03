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

-- Detects Postal (or a compatible OpenAll provider) so the runtime
-- can adapt. Postal is a heavily-used mail enhancer that auto-loots
-- the inbox on open; if it fires before our scanner walks the mails,
-- RR-marked attachments disappear before we can record receipts.
--
-- The defensive design: we don't try to hook or reorder Postal. The
-- MAIL_INBOX_UPDATE-driven re-scan already fires multiple times as
-- the inbox repopulates after a Postal pass, so a normally-paced
-- OpenAll still ends up walking the inbox state our scanner needs.
-- We surface detection here so /rrord mail status can report it
-- and a future iteration can add explicit hooks if Postal proves
-- too fast in practice.
function Mailbox:DetectPostal()
    local postal = _G.Postal
    if type(postal) ~= "table" then
        if type(_G.Postal_OpenAll) ~= "function" then
            self._postalDetected = false
            return false
        end
    end
    self._postalDetected = true
    -- Some Postal versions expose a top-level version; grab it when
    -- available so diagnostics can report it.
    if type(postal) == "table" then
        self._postalVersion = postal.version or postal.Version or postal.VERSION
    end
    return true, self._postalVersion
end

function Mailbox:IsPostalDetected()
    return self._postalDetected == true
end

-- Grace window before a MaterialsSent order with no observed inbox
-- receipt gets downgraded to MaterialsAssumed (§8.3). 2 hours by
-- default — TBC mail between accounts takes ~1 hour, and the spec
-- explicitly rejects 30 minutes as too short.
Mailbox.GRACE_WINDOW_SECONDS = 2 * 3600

-- Walks the event log for the order's most recent state-transition
-- to MaterialsSent and returns its timestamp, or nil when the order
-- has never been in MaterialsSent. Used by the assumed-receipt
-- timer to measure how long the materials have been "in flight".
function Mailbox:GetMaterialsSentAt(order)
    if type(order) ~= "table" or type(order.id) ~= "string" then return nil end
    local store = Addon.Store
    if not (store and type(store.GetRecentEvents) == "function") then return nil end

    -- The events are appended in seq order; the most recent matching
    -- entry is the freshest. We scan the tail to keep this cheap.
    local events = store:GetRecentEvents(500)
    local lastAt
    for index = 1, #events do
        local event = events[index]
        if event.orderId == order.id
            and event.kind == "OrderUpdated"
            and event.payload
            and event.payload.change == "state-transition"
            and event.payload.toState == "MaterialsSent" then
            lastAt = event.at
        end
    end
    return lastAt
end

-- A batch slot counts as "observed in inbox" when the scanner wrote
-- one for it. Tamper-flagged receipts also count: the crafter has
-- visibility on what arrived (even if it's wrong), so they don't
-- need the assumed-receipt downgrade.
local function hasAnyObservedReceipt(order)
    if type(order.batches) ~= "table" then return false end
    for _, slot in pairs(order.batches) do
        if type(slot) == "table" and slot.source == "scanner" then
            return true
        end
    end
    return false
end

function Mailbox:NeedsAssumedReceipt(order, now)
    if type(order) ~= "table" then return false end
    if order.status ~= "MaterialsSent" then return false end
    if hasAnyObservedReceipt(order) then return false end

    local sentAt = self:GetMaterialsSentAt(order)
    if not sentAt then return false end
    now = tonumber(now) or (time and time() or 0)
    return (now - sentAt) >= self.GRACE_WINDOW_SECONDS
end

-- Walks every order where the local player is the crafter and the
-- assumed-receipt criteria fire, then transitions each one to
-- MaterialsAssumed via the state machine (system actor). Returns a
-- summary { eligible, transitioned } so MAIL_SHOW can log + the
-- spec can assert. Safe to call repeatedly: orders already in
-- MaterialsAssumed (or past it) are skipped because of the status
-- guard inside NeedsAssumedReceipt.
function Mailbox:ApplyAssumedReceipts(opts)
    opts = opts or {}
    local summary = { eligible = 0, transitioned = 0 }
    local store = Addon.Store
    if not (store and type(store.ListOrders) == "function"
        and type(store.Transition) == "function") then
        return summary
    end

    local me
    if type(Addon.GetLocalPlayerKey) == "function" then
        local ok, key = pcall(Addon.GetLocalPlayerKey, Addon)
        if ok and type(key) == "string" and key ~= "" then me = key end
    end
    if not me then return summary end

    local orders = store:ListOrders({ crafter = me })
    local now = opts.now
    for index = 1, #orders do
        local order = orders[index]
        if self:NeedsAssumedReceipt(order, now) then
            summary.eligible = summary.eligible + 1
            local ok = store:Transition(order.id, "MaterialsAssumed", "system", {
                reason     = "grace-window",
                graceAfter = self.GRACE_WINDOW_SECONDS,
            })
            if ok then summary.transitioned = summary.transitioned + 1 end
        end
    end
    return summary
end

function Mailbox:GetPostalVersion()
    return self._postalVersion
end

-- Lifecycle entry point called from the plugin's OnEnable. Idempotent.
-- Skips silently when the host doesn't expose RegisterEvent (test
-- harness lite mode); tests drive ProcessInbox / OnMailSendSuccess
-- directly.
function Mailbox:OnEnable()
    if self._wired then return end
    if type(Addon.RegisterEvent) ~= "function" then return end

    -- Initial Postal sweep + re-check on ADDON_LOADED in case Postal
    -- loads after we do.
    self:DetectPostal()
    Addon:RegisterEvent("ADDON_LOADED", function()
        Mailbox:DetectPostal()
    end)

    Addon:RegisterEvent("MAIL_SHOW", function()
        if Addon.MailAssistant and Addon.MailAssistant.SetMailboxOpen then
            Addon.MailAssistant:SetMailboxOpen(true)
        end
        Mailbox:ProcessInbox()
        -- After the scan: any MaterialsSent order older than the
        -- grace window with no observed receipt downgrades to
        -- MaterialsAssumed so the crafter doesn't sit on an order
        -- forever waiting for a mail that never came.
        Mailbox:ApplyAssumedReceipts()
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
