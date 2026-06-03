-- Backend coverage for Postal compatibility detection. The actual
-- defensive strategy (re-scan on MAIL_INBOX_UPDATE) is already
-- exercised by orders_mailbox_orchestrator_spec.lua; here we only
-- verify the detection surface so the slash diag and any future
-- adaptive logic can branch on it.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local function freshPlugin()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({})
end

io.write("Craft Orders Postal compat\n")

Test.it("DetectPostal returns false when Postal globals are absent", function()
    local plugin = freshPlugin()
    _G.Postal = nil
    _G.Postal_OpenAll = nil
    local detected = plugin.Mailbox:DetectPostal()
    Test.eq(detected, false)
    Test.eq(plugin.Mailbox:IsPostalDetected(), false)
end)

Test.it("DetectPostal returns true when _G.Postal is a table", function()
    local plugin = freshPlugin()
    _G.Postal = { version = "v3.5.7" }
    local detected, version = plugin.Mailbox:DetectPostal()
    Test.eq(detected, true)
    Test.eq(version, "v3.5.7")
    Test.eq(plugin.Mailbox:IsPostalDetected(), true)
    Test.eq(plugin.Mailbox:GetPostalVersion(), "v3.5.7")
    _G.Postal = nil
end)

Test.it("DetectPostal returns true when only Postal_OpenAll is exposed", function()
    local plugin = freshPlugin()
    _G.Postal = nil
    _G.Postal_OpenAll = function() end
    local detected = plugin.Mailbox:DetectPostal()
    Test.eq(detected, true)
    _G.Postal_OpenAll = nil
end)

Test.it("Detection result flips back to false after the Postal globals are cleared", function()
    local plugin = freshPlugin()
    _G.Postal = {}
    Test.eq(plugin.Mailbox:DetectPostal(), true)
    _G.Postal = nil
    -- A re-detection (e.g. triggered by an ADDON_LOADED follow-up
    -- after a /reload that disabled Postal) must reflect the new
    -- world state.
    Test.eq(plugin.Mailbox:DetectPostal(), false)
end)
