local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = {
        label = "Major Healing Potion",
        createdItemID = 22829,
        reagents = {
            { itemID = 2447, count = 1, name = "Peacebloom", icon = "p", quality = 1 },
            { itemID = 765,  count = 1, name = "Silverleaf", icon = "s", quality = 1 },
        },
    },
    [858] = {
        label = "Lesser Mana Potion",
        createdItemID = 3385,
        reagents = {
            { itemID = 785, count = 2, name = "Mageroyal",  icon = "m", quality = 1 },
            { itemID = 765, count = 1, name = "Silverleaf", icon = "s", quality = 1 },
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
    return Loader.LoadOrders({ recipeRegistryStub = makeStub() })
end

local function lineFor(recipeKey, quantity)
    local info = RECIPES[recipeKey]
    return {
        recipeKey   = recipeKey,
        quantity    = quantity,
        recipeLabel = info and info.label,
    }
end

local function defaultSpec(overrides)
    local spec = {
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { lineFor(929, 2) },
    }
    if overrides then
        for key, value in pairs(overrides) do
            spec[key] = value
        end
    end
    return spec
end

io.write("Craft Orders board (data-side)\n")

Test.it("BuildRowList returns empty when no orders exist", function()
    local plugin = freshPlugin()
    Test.eq(#plugin.Board:BuildRowList(), 0)
end)

Test.it("each row exposes displayId, status, requester/crafter shortened, line summary", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec())
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 1)
    local row = rows[1]
    Test.eq(row.id, order.id)
    Test.eq(row.status, "Draft")
    Test.eq(row.requesterShort, "Mattia", "realm stripped for compact column")
    Test.eq(row.crafterShort, "Bob")
    Test.eq(row.lineCount, 1)
    Test.eq(row.firstLineLabel, "Major Healing Potion x2")
    Test.truthy(row.displayId == order.id or #row.displayId < #order.id)
end)

Test.it("multi-line orders mark the row label with (+N more)", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = {
            lineFor(929, 2),
            lineFor(858, 3),
        },
    }))
    local rows = plugin.Board:BuildRowList()
    Test.eq(rows[1].lineCount, 2)
    Test.truthy(rows[1].firstLineLabel:find("(+1 more)", 1, true),
        "expected '(+1 more)' marker, got: " .. rows[1].firstLineLabel)
    Test.eq(rows[1].id, order.id)
end)

Test.it("BuildRowList sorts by updatedAt desc with id tiebreak", function()
    local plugin = freshPlugin()
    local wow = Loader.Wow.GetState()
    local first = plugin.Store:CreateDraft(defaultSpec())
    wow.now = wow.now + 1
    local second = plugin.Store:CreateDraft(defaultSpec())
    wow.now = wow.now + 1
    -- Touch `first` so its updatedAt jumps past `second`.
    plugin.Store:AddLine(first.id, lineFor(858, 1))
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 2)
    Test.eq(rows[1].id, first.id, "most recently updated bubbles up")
    Test.eq(rows[2].id, second.id)
end)

Test.it("status filter propagates through to the store list", function()
    local plugin = freshPlugin()
    local draft = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(draft.id, "MaterialsSent", "requester")

    local sentOnly = plugin.Board:BuildRowList({ status = "MaterialsSent" })
    Test.eq(#sentOnly, 1)
    Test.eq(sentOnly[1].id, draft.id)
end)

Test.it("FormatDetailLines returns a placeholder when nothing is selected", function()
    local plugin = freshPlugin()
    local lines = plugin.Board:FormatDetailLines(nil)
    Test.eq(#lines, 1)
    Test.eq(lines[1], "No order selected.")
end)

Test.it("FormatDetailLines lists id, status, parties, lines and materials", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = {
            lineFor(929, 2),
            lineFor(858, 1),
        },
    }))
    local lines = plugin.Board:FormatDetailLines(order)
    local joined = table.concat(lines, "\n")
    -- The "Order" prefix is gold-coloured now, so the literal "Order <id>"
    -- isn't a contiguous substring; check the prefix and the id separately.
    Test.truthy(joined:find("Order", 1, true))
    Test.truthy(joined:find(order.id, 1, true), "order id embedded")
    -- Field labels are wrapped in grey colour codes, so trailing-space
    -- substrings don't survive. Match the label proper instead.
    Test.truthy(joined:find("Status:", 1, true), "Status label present")
    Test.truthy(joined:find("Draft", 1, true), "status value embedded (possibly colourised)")
    Test.truthy(joined:find("Requester:", 1, true), "Requester label present")
    Test.truthy(joined:find("Mattia", 1, true), "requester short name embedded")
    Test.falsy(joined:find("Mattia-TestRealm", 1, true),
        "full Char-Realm form is reserved for storage; UI uses the short name")
    Test.truthy(joined:find("Crafter:", 1, true))
    Test.truthy(joined:find("Bob", 1, true))
    Test.truthy(joined:find("Lines:", 1, true))
    Test.truthy(joined:find("Materials (3 distinct):", 1, true),
        "Peacebloom + Silverleaf + Mageroyal => 3 distinct")
    -- Material names are present without item:ID prefix; provider tag
    -- now appears uncoloured-or-coloured but always with the literal
    -- word "requester" (no surrounding brackets).
    Test.truthy(joined:find("Peacebloom", 1, true))
    Test.truthy(joined:find("requester|r", 1, true) or joined:find("  requester ", 1, true)
        or joined:find("requester|r", 1, true),
        "default provider tag (requester) should appear, possibly colourised")
    -- Item IDs must not leak into the detail panel anymore.
    Test.falsy(joined:find("item:2447", 1, true),
        "raw item:<id> formatting has been retired")
end)

Test.it("FormatDetailLines reflects provider splits after SetProvider", function()
    local plugin = freshPlugin()
    local order = plugin.Store:CreateDraft(defaultSpec({
        lines = { lineFor(929, 4) },
    }))
    plugin.Store:SetProvider(order.id, 2447, "crafter", 1)
    local joined = table.concat(plugin.Board:FormatDetailLines(order), "\n")
    -- Colour codes split the fragments on the wire; assert each side
    -- separately rather than the full "requester N / crafter M" run.
    Test.truthy(joined:find("requester 3", 1, true),
        "requester half of the split should be visible")
    Test.truthy(joined:find("crafter 1", 1, true),
        "crafter half of the split should be visible")
end)

Test.it("GetSelectedOrder returns the live order record or nil", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:GetSelectedOrder(), nil)
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Board:SetSelectedOrder(order.id)
    local selected = plugin.Board:GetSelectedOrder()
    Test.truthy(selected)
    Test.eq(selected.id, order.id)
    plugin.Board:SetSelectedOrder("rr-ord-bogus")
    Test.eq(plugin.Board:GetSelectedOrder(), nil)
end)

Test.it("RegisterTab returns hook-missing if RR has no UI hook", function()
    local plugin = freshPlugin()  -- stub has no UI
    local ok, err = plugin.Board:RegisterTab()
    Test.eq(ok, nil)
    Test.eq(err, "hook-missing")
end)

Test.it("RegisterTab calls RR.UI:RegisterExternalTab with the expected spec", function()
    Loader.Wow.Reset()
    local received
    local plugin = Loader.LoadOrders({
        recipeRegistryStub = {
            Data = {},
            UI = {
                RegisterExternalTab = function(_, spec)
                    received = spec
                    return true
                end,
            },
        },
    })
    local ok = plugin.Board:RegisterTab()
    Test.truthy(ok)
    Test.truthy(received)
    Test.eq(received.id, "orders")
    Test.eq(received.label, "Craft Orders")
    Test.eq(type(received.build), "function")
    Test.eq(type(received.onSelect), "function")
    Test.eq(type(received.onDeselect), "function")
    Test.truthy(plugin.Board.tabRegistered)
end)

Test.it("OnEnable wires up tab registration when RR exposes the hook", function()
    Loader.Wow.Reset()
    local registerCalls = 0
    local plugin = Loader.LoadOrders({
        recipeRegistryStub = {
            Data = {},
            UI = {
                RegisterExternalTab = function(_, _)
                    registerCalls = registerCalls + 1
                    return true
                end,
            },
        },
        enable = true,
    })
    Test.eq(registerCalls, 1, "OnEnable should register exactly once")
    Test.truthy(plugin.Board.tabRegistered)
end)

Test.it("GetStatusColor returns a sensible palette across the 13 states", function()
    local plugin = freshPlugin()
    local Board = plugin.Board

    local terminalR = select(1, Board:GetStatusColor("Failed"))
    Test.gte(terminalR, 0.5, "Failed should be in the red family")

    local goodR, goodG, goodB = Board:GetStatusColor("Completed")
    Test.gte(goodG, goodR, "Completed should be greener than red")
    Test.gte(goodG, goodB, "Completed should be greener than blue")

    local missingR, missingG = Board:GetStatusColor("MaterialsMissing")
    Test.gte(missingR, 0.8, "MaterialsMissing should look red-ish")
    Test.lte(missingG, 0.6, "MaterialsMissing should not look green")

    -- Unknown states fall back to a neutral mid-grey so the UI never
    -- shows white-on-black for an unforeseen state.
    local fallbackR, fallbackG, fallbackB = Board:GetStatusColor("BogusFutureState")
    Test.eq(fallbackR, fallbackG)
    Test.eq(fallbackG, fallbackB)
    Test.gte(fallbackR, 0.5)
end)

Test.it("OnRowClicked updates selection and exposes the bound order", function()
    local plugin = freshPlugin()
    local first  = plugin.Store:CreateDraft(defaultSpec())
    local second = plugin.Store:CreateDraft(defaultSpec({
        lines = { lineFor(858, 1) },
    }))

    plugin.Board:OnRowClicked(second.id)
    Test.eq(plugin.Board.selectedOrderId, second.id)
    local selected = plugin.Board:GetSelectedOrder()
    Test.truthy(selected)
    Test.eq(selected.id, second.id)

    plugin.Board:OnRowClicked(first.id)
    Test.eq(plugin.Board.selectedOrderId, first.id)
end)

Test.it("filter cycle walks all -> active -> done -> all", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:GetFilter(), "all")
    Test.eq(plugin.Board:CycleFilter(), "active")
    Test.eq(plugin.Board:CycleFilter(), "done")
    Test.eq(plugin.Board:CycleFilter(), "all")
end)

Test.it("filter 'active' hides terminal-state orders", function()
    local plugin = freshPlugin()
    local activeDraft = plugin.Store:CreateDraft(defaultSpec())
    local toCancel = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(toCancel.id, "Cancelled", "requester")

    local allRows = plugin.Board:BuildRowList({ bucket = "all" })
    Test.eq(#allRows, 2)

    local activeRows = plugin.Board:BuildRowList({ bucket = "active" })
    Test.eq(#activeRows, 1)
    Test.eq(activeRows[1].id, activeDraft.id)

    local doneRows = plugin.Board:BuildRowList({ bucket = "done" })
    Test.eq(#doneRows, 1)
    Test.eq(doneRows[1].id, toCancel.id)
end)

Test.it("SetFilter persists across BuildRowList calls and clears selection", function()
    local plugin = freshPlugin()
    plugin.Store:CreateDraft(defaultSpec())
    local order = plugin.Store:CreateDraft(defaultSpec())
    plugin.Store:Transition(order.id, "Completed", "requester")
    -- Direct transition Draft -> Completed isn't legal; force via store
    -- write to set up the test bucket. Use Cancelled instead, which IS
    -- a legal Draft transition.
    plugin.Store:Transition(order.id, "Cancelled", "requester")

    plugin.Board:SetSelectedOrder("some-id")
    Test.eq(plugin.Board.selectedOrderId, "some-id")
    Test.truthy(plugin.Board:SetFilter("done"))
    Test.eq(plugin.Board:GetFilter(), "done")
    -- SetFilter should drop the dangling selection so Refresh re-elects
    -- the first row of the new view.
    Test.eq(plugin.Board.selectedOrderId, nil)

    Test.falsy(plugin.Board:SetFilter("bogus"))
    Test.eq(plugin.Board:GetFilter(), "done", "unknown filter values are rejected")
end)

io.write(string.format("Craft Orders board (data-side): %d test(s) passed\n", Test.count))
