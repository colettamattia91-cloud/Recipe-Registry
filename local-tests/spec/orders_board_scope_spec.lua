-- Backend coverage for the Craft Orders board's "Scope" filter axis:
-- narrows the list to orders where the local player is either the
-- requester or the crafter, orthogonally to the existing status
-- bucket. Drives BuildRowList directly without building the panel.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

local RECIPES = {
    [929] = { label = "Major Healing Potion", createdItemID = 22829, reagents = {} },
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

local function spec(requester, crafter)
    return {
        requester = requester,
        crafter   = crafter,
        lines     = {
            { recipeKey = 929, quantity = 1, recipeLabel = "Major Healing Potion" },
        },
    }
end

-- Sets up three orders against the local player "Mattia-TestRealm":
--   ord1 — I'm requester, Bob crafts
--   ord2 — Bob requests, I craft
--   ord3 — Carl requests, Dora crafts (I'm neither)
local function seedThreeOrders(plugin)
    local me   = "Mattia-TestRealm"
    local bob  = "Bob-TestRealm"
    local carl = "Carl-TestRealm"
    local dora = "Dora-TestRealm"
    return {
        plugin.Store:CreateDraft(spec(me,   bob)),
        plugin.Store:CreateDraft(spec(bob,  me)),
        plugin.Store:CreateDraft(spec(carl, dora)),
    }
end

local function rowIds(rows)
    local out = {}
    for index = 1, #rows do out[index] = rows[index].id end
    return out
end

local function contains(list, value)
    for index = 1, #list do
        if list[index] == value then return true end
    end
    return false
end

io.write("Craft Orders board scope filter\n")

Test.it("default scope 'all' returns every order", function()
    local plugin = freshPlugin()
    local orders = seedThreeOrders(plugin)
    Test.eq(plugin.Board:GetScope(), "all")
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 3)
    local ids = rowIds(rows)
    Test.truthy(contains(ids, orders[1].id))
    Test.truthy(contains(ids, orders[2].id))
    Test.truthy(contains(ids, orders[3].id))
end)

Test.it("scope 'requester' keeps only orders the local player requested", function()
    local plugin = freshPlugin()
    local orders = seedThreeOrders(plugin)
    plugin.Board:SetScope("requester")
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 1)
    Test.eq(rows[1].id, orders[1].id, "ord1 is the one I requested")
end)

Test.it("scope 'crafter' keeps only orders the local player crafts", function()
    local plugin = freshPlugin()
    local orders = seedThreeOrders(plugin)
    plugin.Board:SetScope("crafter")
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 1)
    Test.eq(rows[1].id, orders[2].id, "ord2 is the one I craft")
end)

Test.it("scope composes with the status bucket filter", function()
    local plugin = freshPlugin()
    local orders = seedThreeOrders(plugin)
    -- Cancel my-requested order so it falls into the 'done' bucket.
    Test.truthy(plugin.Store:Transition(orders[1].id, "Cancelled", "requester"))

    plugin.Board:SetScope("requester")
    plugin.Board:SetFilter("active")
    Test.eq(#plugin.Board:BuildRowList(), 0,
        "the only requester-scoped order is now terminal, so 'active' is empty")

    plugin.Board:SetFilter("done")
    local rows = plugin.Board:BuildRowList()
    Test.eq(#rows, 1)
    Test.eq(rows[1].id, orders[1].id)
end)

Test.it("CycleScope walks all -> requester -> crafter -> all", function()
    local plugin = freshPlugin()
    Test.eq(plugin.Board:GetScope(), "all")
    Test.eq(plugin.Board:CycleScope(), "requester")
    Test.eq(plugin.Board:CycleScope(), "crafter")
    Test.eq(plugin.Board:CycleScope(), "all")
end)

Test.it("SetScope rejects unknown scopes without mutating state", function()
    local plugin = freshPlugin()
    plugin.Board:SetScope("requester")
    local ok, err = plugin.Board:SetScope("everyone")
    Test.eq(ok, false)
    Test.eq(err, "unknown-scope")
    Test.eq(plugin.Board:GetScope(), "requester")
end)

Test.it("an explicit filters.requester/crafter override wins over self.scope", function()
    local plugin = freshPlugin()
    local orders = seedThreeOrders(plugin)
    plugin.Board:SetScope("requester")

    -- Caller explicitly asks for Bob's-requested orders: the scope
    -- self-projection must not stomp this.
    local rows = plugin.Board:BuildRowList({ requester = "Bob-TestRealm" })
    Test.eq(#rows, 1)
    Test.eq(rows[1].id, orders[2].id, "should be Bob's requested order, not Mattia's")
end)
