-- Backend coverage for the Craft Orders tab badge. Verifies the
-- "action-required" counter, the label formatting, and the host
-- hook integration (mocked via a stub RR.UI).

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = { label = "Major Healing Potion", createdItemID = 22829, reagents = {} },
}

-- Stub RR.UI that records every SetExternalTabLabel call so the spec
-- can assert what the plugin pushed. The :Method calls all flow
-- through self.<method>, so we mirror them as regular functions taking
-- a self argument.
local function makeUIRecorder()
    local labels = {}
    local ui = {
        labels = labels,
        registered = {},
    }
    function ui:RegisterExternalTab(spec)
        self.registered[spec.id] = spec.label
        return true
    end
    function ui:SetExternalTabLabel(id, label)
        labels[#labels + 1] = { id = id, label = label }
        self.registered[id] = label
        return true
    end
    return ui
end

local function makeStub(uiRecorder)
    return {
        UI = uiRecorder,
        Data = {
            GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end,
        },
    }
end

local function freshPlugin(playerName)
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer(playerName or "Mattia", "TestRealm")
    local ui = makeUIRecorder()
    local plugin = Loader.LoadOrders({ recipeRegistryStub = makeStub(ui) })
    return plugin, ui
end

local function spec(requester, crafter)
    return {
        requester = requester,
        crafter   = crafter,
        lines     = { { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" } },
    }
end

io.write("Craft Orders tab badge\n")

Test.it("CountActionRequired is zero with no orders", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:CountActionRequired(), 0)
end)

Test.it("CountActionRequired counts orders where local player has actions", function()
    local plugin = freshPlugin("Mattia")
    -- I'm requester on ord1 (Draft -> I can mark MaterialsSent or Cancel).
    plugin.Store:CreateDraft(spec("Mattia-TestRealm", "Bob-TestRealm"))
    -- I'm crafter on ord2 in MaterialsSent (-> I can mark received).
    local ord2 = plugin.Store:CreateDraft(spec("Bob-TestRealm", "Mattia-TestRealm"))
    Test.truthy(plugin.Store:Transition(ord2.id, "MaterialsSent", "requester"))
    -- I'm uninvolved in ord3.
    plugin.Store:CreateDraft(spec("Carl-TestRealm", "Dora-TestRealm"))

    Test.eq(plugin.Board:CountActionRequired(), 2)
end)

Test.it("orders in terminal states do not count", function()
    local plugin = freshPlugin("Mattia")
    local ord = plugin.Store:CreateDraft(spec("Mattia-TestRealm", "Bob-TestRealm"))
    Test.truthy(plugin.Store:Transition(ord.id, "Cancelled", "requester"))
    Test.eq(plugin.Board:CountActionRequired(), 0)
end)

Test.it("ComputeTabLabel returns the bare label when nothing needs action", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:ComputeTabLabel(), "Craft Orders")
end)

Test.it("ComputeTabLabel appends the counter when at least one needs action", function()
    local plugin = freshPlugin("Mattia")
    plugin.Store:CreateDraft(spec("Mattia-TestRealm", "Bob-TestRealm"))
    Test.eq(plugin.Board:ComputeTabLabel(), "Craft Orders (1)")

    plugin.Store:CreateDraft(spec("Mattia-TestRealm", "Carl-TestRealm"))
    Test.eq(plugin.Board:ComputeTabLabel(), "Craft Orders (2)")
end)

Test.it("RefreshTabLabel pushes the current label to RR.UI", function()
    local plugin, ui = freshPlugin("Mattia")
    plugin.Store:CreateDraft(spec("Mattia-TestRealm", "Bob-TestRealm"))
    Test.truthy(plugin.Board:RefreshTabLabel())
    local last = ui.labels[#ui.labels]
    Test.truthy(last, "should have pushed at least one label")
    Test.eq(last.id, "orders")
    Test.eq(last.label, "Craft Orders (1)")
end)

Test.it("RefreshTabLabel gracefully no-ops when the host hook is missing", function()
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    -- Stub RR without a UI table: the plugin must not blow up.
    local plugin = Loader.LoadOrders({
        recipeRegistryStub = {
            Data = { GetRecipeDisplayInfo = function(_, key) return RECIPES[key] end },
        },
    })
    local ok, err = plugin.Board:RefreshTabLabel()
    Test.eq(ok, nil)
    Test.eq(err, "hook-missing")
end)
