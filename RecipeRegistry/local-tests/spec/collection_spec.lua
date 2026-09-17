-- The Collection view: the CURRENT character's own profession recipe book,
-- learned and not. Answers a different question from the rest of the addon,
-- so it gets its own projection rather than reusing the guild recipe list.
local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local _metadataAddon, _wow, addon = Loader.LoadMetadata()
local data = addon.Data

-- spell 36391 = a TBC blacksmithing plan requiring skill 375, creating item
-- 30033. Two keys, and the difference between them is the whole point of the
-- fixture below: the CATALOGUE is indexed by spell id, but a profession scan
-- keys a recipe by the item it creates, falling back to the negative spell id
-- only for a craft that makes no item. Writing the scan fixture in the
-- catalogue's key shape -- as this spec used to -- asserts a convention the
-- game never produces, and hid a bug that reported every learned recipe of
-- every item-making profession as missing.
local PLAN = -36391
local PLAN_SPELL = PLAN

local function setLocalProfession(professionName, opts)
    opts = opts or {}
    local playerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(playerKey)
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[professionName] = data:NormalizeProfessionBlock(entry, professionName, {
        recipes = opts.recipes or {},
        skillRank = opts.skillRank or 375,
        skillMaxRank = 375,
        specialization = opts.specialization,
        sourceType = "owner",
    })
    data:InvalidateRecipeCaches()
end

local function clearLocalProfessions()
    local entry = data:GetOrCreateMember(data:GetPlayerKey())
    entry.professions = {}
    data:InvalidateRecipeCaches()
end

local function findRow(rows, recipeKey)
    for _, row in ipairs(rows) do
        if row.recipeKey == recipeKey then return row end
    end
    return nil
end

io.write("Collection\n")

Test.it("reports nothing until the character has a scanned profession", function()
    clearLocalProfessions()
    Test.eq(#data:BuildCollectionRows(), 0)
end)

Test.it("lists a catalogued recipe the character has not learned", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildCollectionRows()
    Test.gte(#rows, 1)
    local row = findRow(rows, PLAN)
    Test.truthy(row ~= nil, "expected the unlearned plan to be listed")
    Test.eq(row.collection.professionName, "Blacksmithing")
    Test.eq(row.crafterCount, 0)
end)

-- The whole difference between this and the old "missing recipes" list: a
-- recipe you have is still part of the collection, it is just the collected
-- half of it.
Test.it("keeps a recipe the character knows, marked as learned", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, recipes = { [PLAN] = true } })

    Test.eq(data:IsRecipeKnownByCurrentPlayer(PLAN), true)
    local row = findRow(data:BuildCollectionRows(), PLAN)
    Test.truthy(row ~= nil, "a learned recipe belongs in the collection")
    Test.eq(row.collection.known, true)
end)

Test.it("marks an unlearned recipe as not known", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local row = findRow(data:BuildCollectionRows(), PLAN)
    Test.truthy(row ~= nil)
    Test.eq(row.collection.known, false)
end)

-- The count in a profession header is known against total, so both halves
-- have to be countable off one list.
Test.it("counts the learned half against the whole book", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })
    local total = #data:BuildCollectionRows()

    setLocalProfession("Blacksmithing", { skillRank = 375, recipes = { [PLAN] = true } })
    local rows = data:BuildCollectionRows()
    Test.eq(#rows, total)

    local known = 0
    for _, row in ipairs(rows) do
        if row.collection.known then known = known + 1 end
    end
    Test.eq(known, 1)
end)

-- The two key shapes, which is what the first build of this view got wrong.
--
-- The catalogue is indexed by spell id. A profession scan is not: it keys a
-- recipe by the item it creates and uses the negative spell id only when the
-- craft makes no item. Enchanting is the one profession where the two agree,
-- which is exactly why the bug survived -- the old fixture wrote scan data in
-- the catalogue's shape, so the suite stayed green while every item-making
-- profession in the game reported nothing learned.
Test.it("finds a recipe the scan recorded by its created item", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, recipes = { [30033] = true } })

    local row = findRow(data:BuildCollectionRows(), PLAN_SPELL)
    Test.truthy(row ~= nil, "the plan should still be listed")
    Test.eq(row.collection.known, true)
end)

-- The same recipe recorded the other way: an ambiguous created item makes the
-- scanner write both keys, so a variant recorded only under the spell id
-- counts too.
Test.it("finds a recipe recorded under the spell id alone", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, recipes = { [-36391] = true } })

    local row = findRow(data:BuildCollectionRows(), PLAN_SPELL)
    Test.truthy(row ~= nil)
    Test.eq(row.collection.known, true)
end)

-- The row itself keeps the CATALOGUE key, and that is not a detail: a created
-- item shared by more than one recipe is dropped from the by-item index, so a
-- row keyed by its item would come back with no name, no icon and no source.
-- 21885 is such an item; -28580 resolves, 21885 does not.
Test.it("keys a row so that it always resolves", function()
    clearLocalProfessions()
    setLocalProfession("Alchemy", { skillRank = 375 })

    -- Spelled out rather than using the DISCOVERY constant, which this file
    -- declares further down next to the tests that read it.
    local meta = addon.RecipeMetadata
    Test.eq(meta:GetRecipeInfo(-28580, "alchemy").sourceKind, "discovery")
    Test.eq(meta:GetRecipeInfo(21885, "alchemy"), nil)

    local row = findRow(data:BuildCollectionRows(), -28580)
    Test.truthy(row ~= nil, "the discovery should be listed under its spell key")
    data:ResolveCollectionRow(row)
    Test.truthy(row.detail ~= nil, "a row must resolve to a display record")
    Test.eq(row.collection.sourceKind, "discovery")
    clearLocalProfessions()
end)

-- The count that read 0/385 while the key shape was wrong.
Test.it("counts a real scan against the catalogue", function()
    setLocalProfession("Blacksmithing", {
        skillRank = 375,
        recipes = { [30033] = true, [7925] = true },
    })
    -- 7925 is a vanilla plan, so vanilla has to be visible for it to be a
    -- candidate at all.
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.expansionDefaults.vanilla = true
    prefilters.expansionDefaults.tbc = true
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")

    local known = 0
    for _, row in ipairs(data:BuildCollectionRows()) do
        if row.collection.known then known = known + 1 end
    end
    -- 7925 is the removed recipe: excluded when you do not have it, kept when
    -- you do, so both scanned recipes are found.
    Test.eq(known, 2)

    prefilters.expansionDefaults.vanilla = false
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")
end)

Test.it("flags a recipe the skill rank cannot reach yet", function()
    setLocalProfession("Blacksmithing", { skillRank = 1 })

    local row = findRow(data:BuildCollectionRows(), PLAN)
    Test.truthy(row ~= nil)
    Test.truthy(row.collection.requiredSkill ~= nil, "the plan should carry a required skill")
    Test.eq(row.collection.skillMet, false)
    Test.eq(row.collection.skillRank, 1)
end)

Test.it("reports how the recipe is taught", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildCollectionRows()
    local counts, distinct = {}, 0
    for _, row in ipairs(rows) do
        local kind = row.collection.sourceKind
        Test.truthy(kind ~= nil, "every row should say where the recipe comes from")
        if not counts[kind] then distinct = distinct + 1 end
        counts[kind] = (counts[kind] or 0) + 1
    end

    -- Blacksmithing spans several kinds; a projection that collapsed to one
    -- value would be useless.
    Test.gte(distinct, 3)
    Test.gte(counts.trainer or 0, 1)
    Test.gte(counts.vendor or 0, 1)

    -- "Recipe item" is the fallback for a recipe whose source is unknown.
    -- Nothing in the dataset should reach it any more: a row landing there
    -- means the metadata lost its source, not that the recipe has none.
    Test.eq(counts.item, nil)
end)

Test.it("marks a specialization the character does not have", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local gated
    for _, row in ipairs(data:BuildCollectionRows()) do
        if row.collection.specializationSpellId then
            gated = row
            break
        end
    end
    Test.truthy(gated ~= nil, "expected at least one specialization-gated blacksmithing recipe")
    Test.eq(gated.collection.specializationMet, false)
    Test.truthy(gated.collection.specializationName ~= nil, "the requirement should resolve to a display name")
end)

Test.it("clears the specialization flag once the character has it", function()
    setLocalProfession("Blacksmithing", { skillRank = 375, specialization = "Armorsmith" })

    local armorsmithId = data:GetSpecializationSpellId("Blacksmithing", "Armorsmith")
    Test.eq(armorsmithId, 9788)

    local met, unmet = 0, 0
    for _, row in ipairs(data:BuildCollectionRows()) do
        if row.collection.specializationSpellId == armorsmithId then
            if row.collection.specializationMet then met = met + 1 else unmet = unmet + 1 end
        end
    end
    Test.gte(met, 1)
    Test.eq(unmet, 0)
end)

Test.it("honours the per-profession opt-out", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })
    Test.gte(#data:BuildCollectionRows(), 1)

    data:SetCollectionEnabledForProfession("Blacksmithing", false)
    Test.eq(data:IsCollectionEnabledForProfession("Blacksmithing"), false)
    Test.eq(#data:BuildCollectionRows(), 0)

    data:SetCollectionEnabledForProfession("Blacksmithing", true)
    Test.gte(#data:BuildCollectionRows(), 1)
end)

-- Ready to collect, then out of reach, then already collected: the order
-- puts what you can act on at the top and keeps the collected half as a
-- record underneath.
Test.it("orders ready, then blocked, then learned", function()
    setLocalProfession("Blacksmithing", { skillRank = 300, recipes = { [PLAN] = true } })

    local rows = data:BuildCollectionRows()
    Test.gte(#rows, 3)
    local function rank(row)
        if row.collection.known then return 2 end
        if row.collection.skillMet and row.collection.specializationMet then return 0 end
        return 1
    end
    local highest = 0
    local seen = {}
    for _, row in ipairs(rows) do
        local value = rank(row)
        Test.gte(value, highest)
        highest = value
        seen[value] = true
    end
    Test.truthy(seen[0], "expected a recipe ready to learn")
    Test.truthy(seen[1], "expected a recipe out of reach")
    Test.truthy(seen[2], "expected a learned recipe")
end)

Test.it("respects the expansion prefilter", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.expansionDefaults.vanilla = true
    prefilters.expansionDefaults.tbc = true
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")
    local both = #data:BuildCollectionRows()

    prefilters.expansionDefaults.vanilla = false
    addon.RecipeUiFilters:InvalidateProfessionProjection("blacksmithing", "spec")
    local tbcOnly = #data:BuildCollectionRows()

    Test.truthy(tbcOnly < both, "hiding Vanilla should shorten the collection list")
end)

-- Guards the fix for the freeze this view first shipped with: resolving a
-- name, icon and quality per candidate costs two GetItemInfo calls and a
-- slot in a 256-entry cache, and a two-profession character has more than
-- 600 candidates. Only the rows actually painted may be resolved.
Test.it("builds rows without resolving names or icons", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local rows = data:BuildCollectionRows()
    Test.gte(#rows, 100)
    for _, row in ipairs(rows) do
        Test.eq(row.detail, nil)
        Test.eq(row.label, nil)
    end
end)

Test.it("resolves a row on demand, once", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local row = data:BuildCollectionRows()[1]
    data:ResolveCollectionRow(row)
    Test.truthy(row.label ~= nil, "resolving should give the row a label")
    Test.eq(row._collectionResolved, true)

    -- A second call is a no-op: the renderer rebinds the same row on every
    -- scroll tick.
    local label = row.label
    row.detail = "sentinel"
    data:ResolveCollectionRow(row)
    Test.eq(row.detail, "sentinel")
    Test.eq(row.label, label)
end)

Test.it("keeps a stable order between rebuilds", function()
    setLocalProfession("Blacksmithing", { skillRank = 300 })

    local first = data:BuildCollectionRows()
    local second = data:BuildCollectionRows()
    Test.eq(#first, #second)
    for index = 1, #first do
        Test.eq(first[index].recipeKey, second[index].recipeKey)
    end
end)


-- Recipes that are in the client data but not in the game. There is nowhere
-- to go and learn one, so offering it is not an opportunity: it is a player
-- looking for a trainer who does not exist.
-- 9942 = Mithril Scale Gloves, a vanilla blacksmithing plan requiring skill
-- 220, flagged removed by the generator. Named by its created item, like
-- every other row key in this view.
local REMOVED = -9942
local REMOVED_SPELL = REMOVED

Test.it("never offers a recipe that is not in the game", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    local meta = addon.RecipeMetadata
    Test.eq(meta:IsRemoved(REMOVED_SPELL), true)

    local rows = data:BuildCollectionRows()
    Test.eq(findRow(rows, REMOVED), nil)
end)

Test.it("still offers a recipe of the same skill that is in the game", function()
    setLocalProfession("Blacksmithing", { skillRank = 375 })

    -- Guards the exclusion against being a blanket one: the removed flag has
    -- to be what removed the row, not the skill or the expansion.
    local rows = data:BuildCollectionRows()
    Test.truthy(#rows > 0, "some vanilla plans should still be offered")

    local anyRemoved = false
    for _, row in ipairs(rows) do
        if addon.RecipeMetadata:IsRemoved(row.recipeKey) then anyRemoved = true end
    end
    Test.eq(anyRemoved, false)
end)

Test.it("reads an absent flag as present in the game, not as unknown", function()
    Test.eq(addon.RecipeMetadata:IsRemoved(PLAN_SPELL), false)
    -- A recipe the metadata knows nothing about is not claimed to be removed.
    Test.eq(addon.RecipeMetadata:IsRemoved(-999999999), false)
end)

-- The metadata says where a recipe comes from; the recipe-item proxy is only
-- a guess for when it does not. Checking the proxy first, as this view used
-- to, meant the guess beat the data for every recipe with no pattern -- and
-- an alchemy discovery has none, so all seventeen were reported as taught by
-- a trainer who does not teach them.
-- 28580 = an alchemy discovery: no pattern to buy, learned at the cauldron.
-- It creates item 21885, which is the key the row carries.
local DISCOVERY = -28580
local DISCOVERY_SPELL = DISCOVERY

Test.it("lets the recorded source beat the recipe-item guess", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    local info = addon.RecipeMetadata:GetRecipeInfo(DISCOVERY_SPELL, "alchemy")
    Test.eq(info.recipeItemId, nil)
    Test.eq(addon.RecipeMetadata:GetSource(DISCOVERY_SPELL, info).kind, "discovery")

    local row = findRow(data:BuildCollectionRows(), DISCOVERY)
    Test.truthy(row ~= nil, "expected the discovery to be listed")
    Test.eq(row.collection.sourceKind, "discovery")
    Test.eq(row.collection.sourceLabel, "Discovery")
end)

Test.it("still guesses from the pattern when nothing is recorded", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    -- A recipe the metadata cannot place falls back to the old proxy rather
    -- than showing nothing: no pattern reads as trainer-taught.
    local kinds = {}
    for _, row in ipairs(data:BuildCollectionRows()) do
        kinds[row.collection.sourceKind] = true
    end
    Test.truthy(kinds.trainer, "trainer-taught recipes should still be reported")
    Test.eq(kinds.item, nil)
end)

-- Most trainer-taught recipes name nobody on purpose, but the specialization
-- trainers are named, and there the name is the whole answer: your own city
-- trainer will not teach you a Gnomish schematic.
Test.it("names the trainer when the source knows one", function()
    setLocalProfession("Engineering", { skillRank = 375 })

    local named
    for _, row in ipairs(data:BuildCollectionRows()) do
        if row.collection.sourceKind == "trainer" and row.collection.sourceLabel ~= "From a trainer" then
            named = row.collection.sourceLabel
            break
        end
    end
    Test.truthy(named ~= nil, "a specialization trainer should be named, not just placed")
    -- Name first, place in brackets: the name is what you act on.
    Test.truthy(named:find("Trainer: ") == 1, "the label should lead with the kind")
    Test.truthy(named:find("%(") ~= nil, "the zone should follow the name in brackets")
end)

-- Where every trainer of a recipe carries the same title, that title is the
-- answer -- and a better one than the names: there are five Master Engineering
-- Trainers spread across Outland, and the title is what the player reads under
-- each of them in the world.
Test.it("names the kind of trainer when every one of them is the same kind", function()
    local source = data:DescribeRecipeSource(-41314, "engineering")
    Test.eq(source.kind, "trainer")
    Test.eq(source.label, "Master Engineering Trainer (Outland)")

    -- A named specialization trainer still wins: a name you can walk up to
    -- beats a title you have to go looking for.
    local named = data:DescribeRecipeSource(-12906, "engineering")
    Test.truthy(named.label:find("Trainer: ") == 1,
        "the named trainers must not be replaced by their title")

    -- And a recipe several ranks of trainer teach keeps the honest fallback.
    local any = data:DescribeRecipeSource(-2149, "leatherworking")
    Test.eq(any.label, "From a trainer")
end)

-- AckisRecipeList names no trainer at all for any of the 770 trainer-taught
-- recipes in this dataset: it records that a trainer teaches the recipe, and
-- nothing more. The label has to stop at what was recorded -- "Any trainer"
-- turned that silence into a promise that every trainer stocks it, which is
-- flatly false for the class-gated goggles and unverified for the rest.
Test.it("says a trainer teaches it, not that every trainer does", function()
    setLocalProfession("Engineering", { skillRank = 375 })

    local bare = 0
    for _, row in ipairs(data:BuildCollectionRows()) do
        Test.ne(row.collection.sourceLabel, "Any trainer",
            "the label must not claim a ubiquity the source never stated")
        if row.collection.sourceLabel == "From a trainer" then bare = bare + 1 end
    end
    Test.gte(bare, 1)
end)

-- The source line is all the data records, so when the trainer teaches it to
-- some classes and not others, that is the rest of the answer. Without it the
-- row reads as a recipe any engineer could walk up and buy.
Test.it("names the classes a gated recipe is taught to", function()
    _wow.SetPlayerClass("ROGUE")
    setLocalProfession("Engineering", { skillRank = 375 })
    data:InvalidateRecipeCaches()

    local row = findRow(data:BuildCollectionRows(), -41317)
    Test.truthy(row ~= nil, "a rogue can learn the Deathblow X11 Goggles")
    Test.eq(row.collection.classMask, 1032)
    Test.eq(row.collection.classNames, "Rogue, Druid")

    Test.eq(data:DescribeClassMask(68), "Hunter, Shaman")
    Test.eq(data:DescribeClassMask(nil), nil)
    Test.eq(data:DescribeClassMask(0), nil, "a mask that restricts nothing says nothing")
    clearLocalProfessions()
end)

-- A specialization is not a hole you can fill by levelling: only being a
-- different smith would open it, so it is not one of the recipes you have
-- still to learn. A skill number IS a hole, and closes on its own.
Test.it("leaves a specialization you do not have out of the unlearned count", function()
    local blocked = {
        collection = { known = false, skillMet = true, specializationMet = false },
    }
    local reachable = {
        collection = { known = false, skillMet = false, specializationMet = true },
    }
    local mine = {
        collection = { known = true, skillMet = true, specializationMet = true },
    }

    Test.eq(data:CollectionRowPasses(blocked, "unlearned"), false)
    Test.eq(data:CollectionRowPasses(reachable, "unlearned"), true,
        "out of skill reach is still a hole: the profession goes up")
    Test.eq(data:CollectionRowPasses(mine, "unlearned"), false)

    -- The three states stay a strict narrowing: ready is a subset of unlearned.
    Test.eq(data:CollectionRowPasses(blocked, "ready"), false)
    Test.eq(data:CollectionRowPasses(reachable, "ready"), false)
    Test.eq(data:CollectionRowPasses(blocked, "all"), true,
        "and the whole book still shows it -- a specialization can be changed")
end)

-- Two independent lists could not say which vendor stands in which city:
-- "Xandar Goodbeard, Hagrus, Defias Profiteer (Loch Modan, Orgrimmar,
-- Westfall)" leaves the reader to guess the pairing. Vendor stock is often
-- limited, so the alternatives have to be listed rather than collapsed.
Test.it("keeps every vendor next to its own zone", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    -- Read the places off the ROW, not back out of the metadata by its key:
    -- a row is keyed by its created item, and an unhinted lookup on an
    -- ambiguous item can land on a different profession's record.
    local multi
    for _, row in ipairs(data:BuildCollectionRows()) do
        local places = row.collection.sourcePlaces
        if row.collection.sourceKind == "vendor" and places and #places > 1 then
            multi = row
            break
        end
    end
    Test.truthy(multi ~= nil, "expected a recipe sold by more than one vendor")

    local label = multi.collection.sourceLabel
    for _, place in ipairs(multi.collection.sourcePlaces) do
        -- Every vendor is named, and its own zone follows it in brackets.
        Test.truthy(label:find(place.name, 1, true) ~= nil,
            "the label should name " .. tostring(place.name))
        if place.zone then
            Test.truthy(label:find(place.name .. " (" .. place.zone .. ")", 1, true) ~= nil,
                tostring(place.name) .. " should carry its own zone")
        end
    end
end)

-- A colon introduces who, a preposition introduces where. "Quest: Hillsbrad
-- Foothills" reads as a quest by that name, which is not what the row means:
-- the source knows the zone and no quest name at all.
Test.it("does not write a place where a name would go", function()
    setLocalProfession("Alchemy", { skillRank = 375 })
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.expansionDefaults.vanilla = true
    addon.RecipeUiFilters:InvalidateProfessionProjection("alchemy", "spec")

    local seen = {}
    for _, row in ipairs(data:BuildCollectionRows()) do
        local hasName = false
        for _, place in ipairs(row.collection.sourcePlaces or {}) do
            hasName = hasName or place.name ~= nil
        end
        if not hasName then
            -- Nothing is named, so nothing may follow a colon.
            Test.eq(row.collection.sourceLabel:find(": "), nil)
            seen[row.collection.sourceKind] = row.collection.sourceLabel
        end
    end
    Test.truthy(seen.quest ~= nil, "expected a quest known only by its zone")
    Test.truthy(seen.quest:find("^Quest at ") == 1, "got: " .. tostring(seen.quest))
end)

-- One control with three states rather than two switches: the states are a
-- strict narrowing, so anything "unlearned" hides "ready" hides too.
local function countRows(rows, filter)
    local shown = 0
    for _, row in ipairs(rows) do
        if data:CollectionRowPasses(row, filter) then shown = shown + 1 end
    end
    return shown
end

Test.it("shows the whole book by default", function()
    setLocalProfession("Blacksmithing", { skillRank = 300, recipes = { [PLAN] = true } })
    Test.eq(data:GetCollectionFilter(), "all")

    local rows = data:BuildCollectionRows()
    Test.eq(countRows(rows, "all"), #rows)
end)

Test.it("narrows to the holes, then to the ones you can fill today", function()
    setLocalProfession("Blacksmithing", { skillRank = 300, recipes = { [PLAN] = true } })
    local rows = data:BuildCollectionRows()

    local all = countRows(rows, "all")
    local unlearned = countRows(rows, "unlearned")
    local ready = countRows(rows, "ready")

    Test.truthy(unlearned < all, "the learned recipe should drop out")
    Test.truthy(ready < unlearned, "recipes out of skill reach should drop out")

    for _, row in ipairs(rows) do
        if data:CollectionRowPasses(row, "ready") then
            Test.eq(row.collection.known, false)
            Test.eq(row.collection.skillMet, true)
            Test.eq(row.collection.specializationMet, true)
        end
        if data:CollectionRowPasses(row, "unlearned") then
            Test.eq(row.collection.known, false)
        end
    end
end)

-- The rows themselves never change with the filter: the profession headers
-- count what the filter hides, so the build has to hand over everything.
Test.it("builds the same rows whatever the filter says", function()
    setLocalProfession("Blacksmithing", { skillRank = 300, recipes = { [PLAN] = true } })
    local all = #data:BuildCollectionRows()

    data:SetCollectionFilter("ready")
    Test.eq(#data:BuildCollectionRows(), all)
    data:SetCollectionFilter("all")
end)

Test.it("cycles all to unlearned to ready and back", function()
    data:SetCollectionFilter("all")
    Test.eq(data:CycleCollectionFilter(), "unlearned")
    Test.eq(data:CycleCollectionFilter(), "ready")
    Test.eq(data:CycleCollectionFilter(), "all")
end)

Test.it("stores nothing for the default and refuses a value it does not know", function()
    data:SetCollectionFilter("ready")
    Test.eq(addon.db.profile.collectionFilter, "ready")

    data:SetCollectionFilter("all")
    -- Same shape as the per-profession opt-out: absence is the default, so a
    -- profile that never touched the filter and one set back to "all" are the
    -- same profile.
    Test.eq(addon.db.profile.collectionFilter, nil)

    data:SetCollectionFilter("nonsense")
    Test.eq(addon.db.profile.collectionFilter, nil)
    Test.eq(data:GetCollectionFilter(), "all")
end)

-- The tooltip lists the places one per line, because the table column clips.
Test.it("carries one source line per place onto the row", function()
    setLocalProfession("Alchemy", { skillRank = 375 })

    local multi
    for _, row in ipairs(data:BuildCollectionRows()) do
        if row.collection.sourcePlaces and #row.collection.sourcePlaces > 1 then
            multi = row
            break
        end
    end
    Test.truthy(multi ~= nil, "expected a recipe with more than one place")
    Test.eq(#multi.collection.sourceLines, #multi.collection.sourcePlaces)
end)

-- The predicate is two lines; the wiring is where the bug would be. 41317 is
-- the Deathblow X11 Goggles, whose ClassMask in the client data is 1032 --
-- Rogue and Druid -- and it is the only place the gate is exercised against
-- the real dataset rather than a fixture.
Test.it("keeps a class-gated recipe out of the book of a class that cannot learn it", function()
    local GOGGLES = -41317
    setLocalProfession("Engineering", { skillRank = 375 })

    _wow.SetPlayerClass("ROGUE")
    data:InvalidateRecipeCaches()
    Test.truthy(findRow(data:BuildCollectionRows(), GOGGLES) ~= nil,
        "a rogue's engineering trainer does teach these")

    _wow.SetPlayerClass("WARRIOR")
    data:InvalidateRecipeCaches()
    Test.eq(findRow(data:BuildCollectionRows(), GOGGLES), nil,
        "and a warrior's never will, so it is not a hole in the warrior's book")

    -- The ungated recipes of the same profession are untouched: the gate is a
    -- gate, not a profession filter.
    Test.truthy(#data:BuildCollectionRows() > 100,
        "hiding twenty-two recipes must not empty engineering")

    _wow.SetPlayerClass("ROGUE")
    data:InvalidateRecipeCaches()
    clearLocalProfessions()
end)

-- The detail panel colours its skill requirement against the character's own
-- rank, which means it needs one. nil and zero are different answers.
Test.it("reports this character's rank in a profession, or nothing", function()
    clearLocalProfessions()
    Test.eq(data:GetLocalProfessionRank("Engineering"), nil,
        "not an engineer is not an engineer at zero")
    Test.eq(data:GetLocalProfessionRank(nil), nil)

    setLocalProfession("Engineering", { skillRank = 340 })
    Test.eq(data:GetLocalProfessionRank("Engineering"), 340)
    Test.eq(data:GetLocalProfessionRank("Tailoring"), nil)
    clearLocalProfessions()
end)

-- Twenty-two engineering recipes are taught only to certain classes. For
-- everybody else they are not an unfilled hole in the collection: they are a
-- book that was never theirs, and listing them is a false positive nobody can
-- ever close.
Test.it("asks whether this character's class could learn the recipe at all", function()
    local addon, wow = Loader.Load()
    local data = addon.Data

    wow.SetPlayerClass("ROGUE")
    -- 1032 is Rogue plus Druid: the Deathblow X11 Goggles.
    Test.eq(data:CanCurrentClassLearn(1032), true)
    Test.eq(data:CanCurrentClassLearn(8), true, "rogue alone")
    Test.eq(data:CanCurrentClassLearn(1024), false, "druid alone")
    Test.eq(data:CanCurrentClassLearn(3), false, "warrior and paladin")

    wow.SetPlayerClass("DRUID")
    Test.eq(data:CanCurrentClassLearn(1032), true)
    Test.eq(data:CanCurrentClassLearn(8), false)

    -- No mask is not a gate, and neither is a zero one.
    wow.SetPlayerClass("WARRIOR")
    Test.eq(data:CanCurrentClassLearn(nil), true)
    Test.eq(data:CanCurrentClassLearn(0), true)

    -- A client that cannot say lets everything through: hiding a whole book on
    -- a guess is a worse failure than showing a row that does not apply.
    wow.SetPlayerClass(nil)
    Test.eq(data:CanCurrentClassLearn(1032), true)
    wow.SetPlayerClass("ROGUE")
end)

io.write(string.format("Collection: %d test(s) passed\n", Test.count))
