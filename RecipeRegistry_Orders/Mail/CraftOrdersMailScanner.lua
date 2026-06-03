local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Scanner = {}
Addon.MailScanner = Scanner

-- Incoming-mail scanner for Craft Orders.
--
-- The scanner reads the inbox via the TBC mailbox API, identifies any
-- mails whose body contains an RR marker block, decodes them, and
-- runs the integrity checks from docs/craft-orders-roadmap.md §7.4.
-- Output is a list of { mailIndex, sender, subject, marker,
-- observed, valid, tamperFlags } results. Wiring those results into
-- the ledger / event log is the caller's job — keeping that out of
-- here means the scanner is fully testable against the harness's
-- mailbox mock without touching the store.

-- TBC's GetInboxHeaderInfo returns the sender either as "Char-Realm"
-- (cross-realm) or just "Char" (same realm). The requester key
-- stored on the order is always "Char-Realm" per the project's
-- storage convention, so we normalize to that form. The default
-- realm is the local realm; the caller can override via opts.realm
-- for tests that want to simulate a different home realm.
function Scanner:NormalizeSender(rawSender, defaultRealm)
    if type(rawSender) ~= "string" or rawSender == "" then return nil end
    if rawSender:find("-", 1, true) then return rawSender end
    if type(defaultRealm) ~= "string" or defaultRealm == "" then
        return rawSender
    end
    -- Strip whitespace and hyphens from the realm so it matches the
    -- storage convention RR uses elsewhere.
    local realm = defaultRealm:gsub("[%s%-]", "")
    return rawSender .. "-" .. realm
end

-- Reads all attachments on the given inbox mail and returns the
-- observed items as { [itemID] = count, ... }. Counts are summed when
-- the same itemID appears in multiple slots (e.g. partial stacks).
function Scanner:ReadAttachments(mailIndex)
    local out = {}
    if type(_G.GetInboxHeaderInfo) ~= "function" then return out end
    local _, _, _, _, _, _, _, attachCount = _G.GetInboxHeaderInfo(mailIndex)
    attachCount = tonumber(attachCount) or 0
    if attachCount == 0 then return out end
    if type(_G.GetInboxItem) ~= "function" then return out end
    for slot = 1, attachCount do
        local _, itemID, _, count = _G.GetInboxItem(mailIndex, slot)
        itemID = tonumber(itemID)
        if itemID then
            out[itemID] = (out[itemID] or 0) + (tonumber(count) or 0)
        end
    end
    return out
end

-- Walks the inbox once and returns the list of mails carrying an RR
-- marker. Each entry includes the decoded marker, the observed items
-- (read from actual attachments), and the raw header info so the
-- caller can run integrity checks against a specific order.
function Scanner:ScanInbox(opts)
    opts = opts or {}
    local out = {}
    if type(_G.GetInboxNumItems) ~= "function" then return out end
    local marker = Addon.MailMarker
    if not (marker and type(marker.Decode) == "function") then return out end

    local realm = opts.realm
    if not realm and type(_G.GetRealmName) == "function" then
        realm = _G.GetRealmName()
    end

    local total = tonumber(_G.GetInboxNumItems()) or 0
    for index = 1, total do
        local _, _, rawSender, subject = _G.GetInboxHeaderInfo(index)
        local body = type(_G.GetInboxText) == "function"
            and (_G.GetInboxText(index) or "") or ""
        local decoded = marker:Decode(body)
        if decoded then
            out[#out + 1] = {
                mailIndex = index,
                sender    = self:NormalizeSender(rawSender, realm),
                rawSender = rawSender,
                subject   = subject,
                marker    = decoded,
                observed  = self:ReadAttachments(index),
            }
        end
    end
    return out
end

-- Per-mail integrity verification (roadmap §7.4). Runs the four
-- checks against the given order and returns an outcome:
--   { valid = bool, senderMatch, hashMatch, itemsMatch,
--     batchMatch, tamperFlags = { "sender-mismatch", ... } }
-- The caller pairs each scan result with the matching order (lookup
-- by marker.orderId) and feeds both here. The function makes no
-- store mutations; the caller decides how to record the outcome.
function Scanner:VerifyIntegrity(scanEntry, order)
    if type(scanEntry) ~= "table" or type(order) ~= "table" then
        return { valid = false, tamperFlags = { "invalid-input" } }
    end
    local marker = scanEntry.marker
    if type(marker) ~= "table" then
        return { valid = false, tamperFlags = { "no-marker" } }
    end

    local flags = {}
    local function flag(name) flags[#flags + 1] = name end

    local senderMatch = scanEntry.sender == order.requester
    if not senderMatch then flag("sender-mismatch") end

    -- Recompute the hash over the marker's items table and compare to
    -- the hash the sender wrote in. A mismatch is either accidental
    -- corruption or deliberate tampering — either way the mail can't
    -- be trusted as-declared.
    local codec = Addon.MailMarker
    local recomputedHash = codec and codec:CanonicalHash(marker.items) or nil
    local hashMatch = recomputedHash ~= nil and recomputedHash == marker.hash
    if not hashMatch then flag("hash-mismatch") end

    -- Marker-vs-attachments: every promised item must be present in
    -- the inbox attachments with at least the promised count. The
    -- inverse (extra items in the inbox not in the marker) does NOT
    -- fail the check — extras are tolerated.
    local itemsMatch = true
    local observed = scanEntry.observed or {}
    for itemID, promisedCount in pairs(marker.items or {}) do
        local actual = tonumber(observed[itemID]) or 0
        if actual < (tonumber(promisedCount) or 0) then
            itemsMatch = false
            if actual == 0 then
                flag("item-missing:" .. tostring(itemID))
            else
                flag("item-count-mismatch:" .. tostring(itemID))
            end
        end
    end

    -- Batch identity: the marker's (batchNumber, totalBatches) must
    -- be coherent (1..N within N) AND, if the order's ledger knows
    -- about this batch slot, the totals must agree. v1 only checks
    -- shape; ledger reconciliation lives in the store-wiring step
    -- and will append to tamperFlags from there.
    local batchMatch = true
    local bn = tonumber(marker.batchNumber)
    local bt = tonumber(marker.totalBatches)
    if not bn or not bt or bn < 1 or bt < 1 or bn > bt then
        batchMatch = false
        flag("batch-mismatch")
    end

    return {
        valid       = senderMatch and hashMatch and itemsMatch and batchMatch,
        senderMatch = senderMatch,
        hashMatch   = hashMatch,
        itemsMatch  = itemsMatch,
        batchMatch  = batchMatch,
        tamperFlags = flags,
        recomputedHash = recomputedHash,
    }
end
