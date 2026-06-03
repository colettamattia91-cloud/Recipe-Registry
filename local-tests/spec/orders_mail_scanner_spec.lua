-- Backend coverage for the incoming Mail Scanner: inbox walk, marker
-- detection, attachment read, and the §7.4 integrity checks.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label         = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
}

local function makeStub()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

local function freshPlugin()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Bob", "TestRealm")  -- the crafter scans the inbox
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function draftOrder(plugin)
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" } },
    })
    plugin.Planner:RecomputeOrder(order)
    return order
end

-- Builds an inbox mail that mirrors what the Assistant would have
-- sent. Used by tests that want the happy path before perturbing
-- pieces to exercise tamper detection.
local function injectMail(plugin, order, opts)
    opts = opts or {}
    local batches = plugin.MailAssistant:PlanBatches(order)
    local mail = plugin.MailAssistant:ComposeMail(order, batches[1])
    -- The sender argument lets the test override the inbox sender
    -- (e.g. "Stranger-TestRealm" to fail the sender-match check).
    local senderField = opts.sender or "Mattia-TestRealm"
    return Loader.Wow.AddInboxMail({
        sender  = senderField,
        subject = mail.subject,
        body    = opts.bodyOverride or mail.body,
        items   = opts.itemsOverride or {
            { itemID = 2447, count = 2, name = "Peacebloom" },
            { itemID = 765,  count = 2, name = "Silverleaf" },
        },
    })
end

io.write("Craft Orders mail scanner\n")

Test.it("NormalizeSender appends the default realm when missing", function()
    local plugin = freshPlugin()
    Test.eq(plugin.MailScanner:NormalizeSender("Mattia", "TestRealm"),
        "Mattia-TestRealm")
    Test.eq(plugin.MailScanner:NormalizeSender("Mattia-OtherRealm", "TestRealm"),
        "Mattia-OtherRealm",
        "an already-qualified sender must not be re-qualified")
    Test.eq(plugin.MailScanner:NormalizeSender("", "TestRealm"), nil)
end)

Test.it("ScanInbox returns empty when the inbox has no RR mails", function()
    local plugin = freshPlugin()
    Loader.Wow.AddInboxMail({
        sender  = "Stranger-Realm",
        subject = "Hey",
        body    = "Just saying hi! No marker here.",
        items   = {},
    })
    local results = plugin.MailScanner:ScanInbox()
    Test.eq(#results, 0)
end)

Test.it("ScanInbox finds and decodes an RR-marked mail", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    injectMail(plugin, order)
    local results = plugin.MailScanner:ScanInbox()
    Test.eq(#results, 1)
    Test.eq(results[1].marker.orderId, order.id)
    Test.eq(results[1].sender, "Mattia-TestRealm")
    Test.eq(results[1].observed[2447], 2,
        "observed map should reflect the actual attachments")
end)

Test.it("VerifyIntegrity passes for a well-formed mail from the right sender", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    injectMail(plugin, order)
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.valid, true)
    Test.eq(outcome.senderMatch, true)
    Test.eq(outcome.hashMatch, true)
    Test.eq(outcome.itemsMatch, true)
    Test.eq(outcome.batchMatch, true)
    Test.eq(#outcome.tamperFlags, 0)
end)

Test.it("VerifyIntegrity flags sender mismatch", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    injectMail(plugin, order, { sender = "Stranger-TestRealm" })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.valid, false)
    Test.eq(outcome.senderMatch, false)
    local joined = table.concat(outcome.tamperFlags, ",")
    Test.truthy(joined:find("sender-mismatch", 1, true))
end)

Test.it("VerifyIntegrity flags hash mismatch when the marker hash was tampered with", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Compose normally, then swap the hash in the body for garbage.
    local batches = plugin.MailAssistant:PlanBatches(order)
    local mail = plugin.MailAssistant:ComposeMail(order, batches[1])
    local tampered = mail.body:gsub('h="%x+"', 'h="deadbeef"')
    Loader.Wow.AddInboxMail({
        sender  = "Mattia-TestRealm",
        subject = mail.subject,
        body    = tampered,
        items   = {
            { itemID = 2447, count = 2, name = "Peacebloom" },
            { itemID = 765,  count = 2, name = "Silverleaf" },
        },
    })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.hashMatch, false)
    Test.eq(outcome.valid, false)
end)

Test.it("VerifyIntegrity flags missing attachments", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Marker promises 2 of each item; we only deliver 1 of each.
    injectMail(plugin, order, {
        itemsOverride = {
            { itemID = 2447, count = 1, name = "Peacebloom" },
            { itemID = 765,  count = 1, name = "Silverleaf" },
        },
    })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.itemsMatch, false)
    Test.eq(outcome.valid, false)
    local joined = table.concat(outcome.tamperFlags, ",")
    Test.truthy(joined:find("item-count-mismatch:2447", 1, true)
        or joined:find("item-count-mismatch:765", 1, true))
end)

Test.it("VerifyIntegrity flags entirely missing items as item-missing, not count-mismatch", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    -- Drop Silverleaf entirely from the inbox attachments.
    injectMail(plugin, order, {
        itemsOverride = {
            { itemID = 2447, count = 2, name = "Peacebloom" },
        },
    })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.itemsMatch, false)
    local joined = table.concat(outcome.tamperFlags, ",")
    Test.truthy(joined:find("item-missing:765", 1, true))
end)

Test.it("VerifyIntegrity tolerates extra attachments beyond the marker", function()
    local plugin = freshPlugin()
    local order = draftOrder(plugin)
    injectMail(plugin, order, {
        itemsOverride = {
            { itemID = 2447, count = 2, name = "Peacebloom" },
            { itemID = 765,  count = 2, name = "Silverleaf" },
            { itemID = 9999, count = 5, name = "Bonus" },
        },
    })
    local results = plugin.MailScanner:ScanInbox()
    local outcome = plugin.MailScanner:VerifyIntegrity(results[1], order)
    Test.eq(outcome.valid, true,
        "extras in the inbox must not fail the integrity check")
end)
