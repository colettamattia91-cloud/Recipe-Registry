-- Backend coverage for the Craft Orders board's "Recent events" tail
-- in the detail panel. The renderer is a thin wrapper around
-- Board:FormatRecentEventLines + summarizeEvent; correctness lives
-- here, away from a panel frame.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = { label = "Major Healing Potion", createdItemID = 22829, reagents = {} },
    [858] = { label = "Lesser Mana Potion",   createdItemID = 3385,  reagents = {} },
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
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function specWith()
    return {
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = {
            { recipeKey = 929, quantity = 2, recipeLabel = "Major Healing Potion" },
        },
    }
end

local function findSubstring(lines, needle)
    for index = 1, #lines do
        if type(lines[index]) == "string" and lines[index]:find(needle, 1, true) then
            return index, lines[index]
        end
    end
    return nil, nil
end

io.write("Craft Orders board recent events\n")

Test.it("returns empty when no order or no events", function()
    local plugin = freshPlugin()
    Test.eq(#plugin.Board:FormatRecentEventLines(nil, 5), 0)
end)

Test.it("creates surface OrderCreated entry on a fresh order", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(specWith())
    local lines = plugin.Board:FormatRecentEventLines(order, 5)
    Test.eq(#lines, 1)
    Test.truthy(lines[1]:find("created", 1, true),
        "OrderCreated should render with the 'created' verb")
    Test.truthy(lines[1]:find("1 line", 1, true),
        "should report line count")
    Test.truthy(lines[1]:find("Mattia", 1, true),
        "should attribute to the requester")
end)

Test.it("state transitions render with the arrow form fromState -> toState", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(specWith())
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))

    local lines = plugin.Board:FormatRecentEventLines(order, 5)
    Test.gte(#lines, 2)
    Test.truthy(findSubstring(lines, "Draft -> MaterialsSent"),
        "state-transition payload should surface as 'Draft -> MaterialsSent'")
end)

Test.it("line additions render with the recipe label", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(specWith())
    plugin.Store:AddLine(order.id, {
        recipeKey = 858, quantity = 3, recipeLabel = "Lesser Mana Potion",
    }, "Mattia-TestRealm")

    local lines = plugin.Board:FormatRecentEventLines(order, 5)
    Test.truthy(findSubstring(lines, "line + Lesser Mana Potion x3"),
        "line-added payload should surface the label and quantity")
end)

Test.it("filters out events belonging to other orders", function()
    local plugin = freshPlugin()
    local kept   = plugin.Store:CreateDraft(specWith())
    local other  = plugin.Store:CreateDraft(specWith())
    Test.truthy(plugin.Store:Transition(other.id, "Cancelled", "requester"))

    local lines = plugin.Board:FormatRecentEventLines(kept, 5)
    -- The kept order has exactly one event (its own OrderCreated). The
    -- other order's create + cancel events must not leak in.
    Test.eq(#lines, 1)
    Test.truthy(lines[1]:find("created", 1, true))
    Test.falsy(findSubstring(lines, "Cancelled"),
        "other orders' state transitions must not appear in this tail")
end)

Test.it("respects the limit even when there are more matching events", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(specWith())
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsSent", "requester"))
    Test.truthy(plugin.Store:Transition(order.id, "MaterialsReceived", "crafter"))
    Test.truthy(plugin.Store:Transition(order.id, "Accepted", "crafter"))

    local lines = plugin.Board:FormatRecentEventLines(order, 2)
    Test.eq(#lines, 2)
    -- Tail should be the *most recent* two: MaterialsReceived -> Accepted
    -- is the very last; the one before is MaterialsSent -> MaterialsReceived.
    Test.truthy(findSubstring(lines, "MaterialsReceived -> Accepted"))
    Test.truthy(findSubstring(lines, "MaterialsSent -> MaterialsReceived"))
end)

Test.it("FormatDetailLines includes the Recent events section once events exist", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(specWith())
    local detail = plugin.Board:FormatDetailLines(order)
    local joined = table.concat(detail, "\n")
    Test.truthy(joined:find("Recent events:", 1, true),
        "detail panel should render the Recent events section header")
end)
