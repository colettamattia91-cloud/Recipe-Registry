-- Backend coverage for the planner's lazy-reagents path. RR's
-- GetRecipeDisplayInfo returns a fast skeleton with reagents = {};
-- the reagents are materialized on demand by EnsureRecipeReagents or
-- as a side effect of GetRecipeDetail. Without going through one of
-- those, the planner would silently report "no materials" for every
-- freshly-seen recipe in a session — which is exactly the symptom
-- reported in-game.

local Loader = dofile("local-tests/harness/load-addon.lua")
local Test   = dofile("local-tests/harness/test.lua")

-- A real-shape RR data API: GetRecipeDisplayInfo never includes
-- reagents (matches what production does after the lazy-load
-- optimization). The Planner must therefore call GetRecipeDetail or
-- EnsureRecipeReagents to materialize them.
local LAZY_REAGENTS = {
    [3115] = {
        itemID = 3115, count = 1, name = "Heavy Stone", icon = "h", quality = 1,
    },
}

local function makeStubLazy()
    return {
        Data = {
            GetRecipeDisplayInfo = function(_, recipeKey)
                if recipeKey ~= 3116 then return nil end
                return {
                    recipeKey      = 3116,
                    label          = "Heavy Weightstone",
                    createdItemID  = 3241,
                    reagents       = {}, -- lazy: empty until materialized
                }
            end,
            EnsureRecipeReagents = function(_, info)
                if info and info.recipeKey == 3116 then
                    info.reagents = { LAZY_REAGENTS[3115] }
                end
                return info
            end,
        },
    }
end

-- A second stub that ONLY exposes GetRecipeDetail (no
-- EnsureRecipeReagents). Mirrors what some RR builds may do where
-- GetRecipeDetail is the one-stop shop and the lazy helper isn't
-- public.
local function makeStubDetail()
    return {
        Data = {
            GetRecipeDetail = function(_, recipeKey)
                if recipeKey ~= 3116 then return nil end
                return {
                    recipeKey      = 3116,
                    label          = "Heavy Weightstone",
                    createdItemID  = 3241,
                    reagents       = { LAZY_REAGENTS[3115] },
                }
            end,
        },
    }
end

local function freshPlugin(stub)
    Loader.Wow.Reset()
    Loader.Wow.SetPlayer("Mattia", "TestRealm")
    return Loader.LoadOrders({ recipeRegistryStub = stub })
end

io.write("Craft Orders planner lazy-reagents path\n")

Test.it("ComputeFromLines materializes reagents via EnsureRecipeReagents fallback", function()
    local plugin = freshPlugin(makeStubLazy())
    local materials, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 3116, quantity = 5 },
    })
    Test.eq(#missing, 0,
        "the recipe is well-known; missing must be empty after EnsureRecipeReagents fires")
    Test.truthy(materials[3115], "Heavy Stone reagent must show up in the planned materials")
    Test.eq(materials[3115].required, 5,
        "5 crafts * 1 stone per craft = 5 required")
end)

Test.it("ComputeFromLines uses GetRecipeDetail when EnsureRecipeReagents isn't exposed", function()
    local plugin = freshPlugin(makeStubDetail())
    local materials, missing = plugin.Planner:ComputeFromLines({
        { recipeKey = 3116, quantity = 3 },
    })
    Test.eq(#missing, 0)
    Test.truthy(materials[3115])
    Test.eq(materials[3115].required, 3)
end)

Test.it("CreateDraft followed by RecomputeOrder ends with non-empty materials", function()
    -- The bug surface that the user reported: an order created via
    -- the cart -> Store:CreateDraft path showed "Materials: none
    -- computed" because the planner saw empty reagents from
    -- GetRecipeDisplayInfo. This spec walks the same code path and
    -- asserts materials are populated end-to-end.
    local plugin = freshPlugin(makeStubLazy())
    local order = plugin.Store:CreateDraft({
        requester = "Mattia-TestRealm",
        crafter   = "Bob-TestRealm",
        lines     = { { recipeKey = 3116, quantity = 4, recipeLabel = "Heavy Weightstone" } },
    })
    Test.truthy(order)
    Test.truthy(order.materials[3115], "draft order must end with computed materials")
    Test.eq(order.materials[3115].required, 4)
end)
