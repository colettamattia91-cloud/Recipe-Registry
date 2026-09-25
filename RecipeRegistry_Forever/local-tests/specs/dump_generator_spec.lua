-- Multiple saved sessions must accumulate professions; the latest capture of
-- one profession replaces only that profession, regardless of input order.
local base = "local-tests/specs/.dump-generator-"
local paths = { base .. "old.lua", base .. "new.lua", base .. "output.lua", base .. "mining.lua",
    base .. "vanilla-skill.tsv" }
local function write(path, content)
    local file = assert(io.open(path, "w")); file:write(content); file:close()
end
local function generate(first, second, ...)
    local env = setmetatable({ arg = { first, paths[3], second, ... } }, { __index = _G })
    local generator = assert(loadfile("Tools/generate-from-dump.lua"))
    setfenv(generator, env)
    generator()
    local output = {}
    local chunk = assert(loadfile(paths[3])); setfenv(chunk, output); chunk()
    return output.RecipeRegistryRecipeMetadata
end
local ok, err = pcall(function()
    write(paths[1], [[RecipeRegistryLogDB = { dumps = {
        Alchemy = { at = "2026-09-18 10:00:00", recipes = { { recipeID = 1, outputItemID = 11 } } },
        Cooking = { at = "2026-09-18 10:00:00", recipes = { { recipeID = 2, outputItemID = 22 } } },
        Enchanting = { at = "2026-09-18 10:00:00", recipes = { { recipeID = 7443 } } },
    } }]])
    write(paths[2], [[RecipeRegistryDumpDB = { dumps = {
        Alchemy = { at = "2026-09-18 11:00:00", recipes = { { recipeID = 3, outputItemID = 33,
            reagents = { { itemID = 765, count = 2 } } } } },
    } }]])
    local metadata = generate(paths[1], paths[2])
    assert(metadata.recipesBySpellId[2], "another profession was lost")
    assert(metadata.recipesBySpellId[3] and not metadata.recipesBySpellId[1], "latest profession capture must win")
    assert(metadata.recipesBySpellId[3].reagents[1].count == 2)
    assert(metadata.createdItemToSpellIds[33][1] == 3)
    -- Enchant Chest - Minor Intellect: non produce un oggetto, e si mette sul
    -- petto di chiunque. Il generatore lo marcava self-only perche' senza
    -- oggetto, e il filtro nascondeva cosi' ogni incantamento dei compagni.
    local enchant = metadata.recipesBySpellId[7443]
    assert(enchant and enchant.createdItemId == nil, "enchant fixture missing")
    assert(enchant.selfOnlyOutputless == nil, "an enchant without an item is not self-only")
    -- Il BoP viene dal legame dell'oggetto prodotto, preso dal datamining
    -- (MiningItems, il bindType di ItemSparse), come su TBC. Non dalla ricetta,
    -- e non dal fatto che un oggetto ci sia o no.
    write(paths[4], [[MiningRecipes = { [3] = { recipeItemId = 5003 } }
MiningItems = { [22] = 1, [33] = 2 }]])
    local mined = generate(paths[1], paths[2], "--mining=" .. paths[4])
    assert(mined.recipesBySpellId[2].bopOutput == true, "item bound on pickup must give bopOutput = true")
    assert(mined.recipesBySpellId[3].bopOutput == false, "item bound on equip is not BoP")
    assert(mined.recipesBySpellId[7443].bopOutput == nil, "no created item, nothing to bind")
    assert(metadata.recipesBySpellId[2].bopOutput == nil, "without datamining the bind is unknown, not false")
    -- L'oggetto che insegna la ricetta arriva dal datamining, e all'indietro
    -- serve al tooltip del Pattern. Una ricetta senza non ne inventa uno.
    assert(mined.recipesBySpellId[3].recipeItemId == 5003, "recipe item must reach the record")
    assert(mined.recipeItemToSpellId[5003] == 3, "recipe item must reach the reverse index")
    assert(mined.recipesBySpellId[2].recipeItemId == nil, "no recipe item is not a recipe item")
    -- Il livello a cui si impara. Il client dice 1 su quasi tutto -- e' il
    -- valore di SkillLineAbility, il vero requisito del trainer e' dato del
    -- server -- quindi prima l'oggetto-ricetta, poi il vanilla, e un 1 del
    -- client non passa per un livello.
    write(paths[4], [[MiningRecipes = {
    [2] = { requiredSkill = 1 },
    [3] = { recipeItemId = 5003, recipeItemSkill = 140, requiredSkill = 1 },
    [7443] = { requiredSkill = 1 },
}]])
    write(paths[5], "spellId\trequiredSkill\n2\t75\n3\t999\n")
    local skilled = generate(paths[1], paths[2], "--mining=" .. paths[4], "--vanilla-skill=" .. paths[5])
    assert(skilled.recipesBySpellId[3].requiredSkill == 140, "the recipe item's rank comes first")
    assert(skilled.recipesBySpellId[2].requiredSkill == 75, "then the vanilla rank")
    assert(skilled.recipesBySpellId[7443].requiredSkill == nil, "a client 1 is not a requirement")
    local reverse = generate(paths[2], paths[1])
    assert(reverse.recipesBySpellId[3] and not reverse.recipesBySpellId[1], "older captures cannot replace newer ones")
end)
for _, path in ipairs(paths) do os.remove(path) end
assert(ok, err)
print("PASS generator: multiple sessions, legacy format, newest capture, reagents, indices, outputless is not self-only, static BoP from item binding, recipe items, required skill")
