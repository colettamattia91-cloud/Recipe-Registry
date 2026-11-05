-- Multiple saved sessions must accumulate professions; the latest capture of
-- one profession replaces only that profession, regardless of input order.
local base = "local-tests/specs/.dump-generator-"
local paths = { base .. "old.lua", base .. "new.lua", base .. "output.lua", base .. "mining.lua",
    base .. "vanilla-skill.tsv", base .. "capture.lua", base .. "structure.lua", base .. "worksheet.tsv",
    base .. "trainer-skill.tsv" }
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
    -- Linen Bag: il vanilla la vendeva dal trainer a 45, su Forever il client
    -- la da' da sola a 1 (AcquireMethod 1). L'addon diceva 45.
    write(paths[4], [[MiningRecipes = {
    [2] = { requiredSkill = 1, acquireMethod = 1, skillLevels = { 1, 30, 65 } },
    [3] = { recipeItemId = 5003, recipeItemSkill = 140, requiredSkill = 1, acquireMethod = 0, skillLevels = { 1, 165, 205 } },
    [7443] = { requiredSkill = 1, skillLevels = { 1, 0, 0 } },
}]])
    local learned = generate(paths[1], paths[2], "--mining=" .. paths[4], "--vanilla-skill=" .. paths[5])
    assert(learned.recipesBySpellId[2].requiredSkill == 1, "a recipe the game grants by itself is learned at the client's rank")
    assert(learned.recipesBySpellId[3].requiredSkill == 140, "a recipe bought from a trainer keeps the old order")
    -- Le soglie: il client ne da' tre (dove si impara, giallo, grigio), l'addon
    -- ne legge quattro. Il verde e' la meta' fra giallo e grigio, l'arancione
    -- il livello del record.
    local ladder = learned.recipesBySpellId[2].skillLevels
    assert(ladder and #ladder == 4 and ladder[1] == 1 and ladder[2] == 30 and ladder[3] == 47 and ladder[4] == 65,
        "three client thresholds become the four-step ladder")
    local bought = learned.recipesBySpellId[3].skillLevels
    assert(bought[1] == 140 and bought[3] == 185, "orange starts where the recipe is learned")
    assert(learned.recipesBySpellId[7443].skillLevels == nil, "thresholds at zero are no ladder")
    -- Il livello del trainer di Forever (Wowhead) batte il vanilla, ma non il
    -- client: ne' l'oggetto-ricetta ne' una ricetta che il gioco da' da sola.
    write(paths[9], "spellId\trequiredSkill\tname\n2\t5\tLinen Bag\n3\t120\tPotion\n7443\t40\tCoarse Weightstone\n")
    local trained = generate(paths[1], paths[2], "--mining=" .. paths[4], "--vanilla-skill=" .. paths[5],
        "--trainer-skill=" .. paths[9])
    assert(trained.recipesBySpellId[7443].requiredSkill == 40, "the Forever trainer's rank comes before the vanilla one")
    assert(trained.recipesBySpellId[7443].skillLevels == nil, "a rank alone makes no ladder")
    assert(trained.recipesBySpellId[3].requiredSkill == 140, "the recipe item still comes first")
    assert(trained.recipesBySpellId[2].requiredSkill == 1, "and so does a recipe the game grants by itself")
    write(paths[4], "MiningRecipes = { [7443] = { requiredSkill = 1, skillLevels = { 1, 40, 55 } } }\n")
    write(paths[5], "spellId\trequiredSkill\n7443\t65\n")
    local lowered = generate(paths[1], paths[2], "--mining=" .. paths[4], "--vanilla-skill=" .. paths[5],
        "--trainer-skill=" .. paths[9])
    local weightstone = lowered.recipesBySpellId[7443]
    assert(weightstone.requiredSkill == 40 and weightstone.skillLevels[1] == 40,
        "orange starts at the trainer's rank, not at the vanilla one")
    -- I nomi con le virgolette. Il worksheet lo scrive il modulo csv di
    -- Python, che racchiude fra virgolette il campo che ne contiene e le
    -- raddoppia dentro. Letto com'era, "Ziri ""The Wrench"" Littlesprocket"
    -- arrivava in gioco cosi', e in una lista il primo NPC prendeva la
    -- virgoletta d'apertura.
    write(paths[8], 'profession\tspellId\trecipeItemId\tsourceKind\tnpcName\tzone\n'
        .. 'cooking\t2\t\tvendor\t"Jazzrik | ""Cookie"" McWeaksauce"\tBadlands | Redridge Mountains\n'
        .. 'alchemy\t3\t\tvendor\t"Ziri ""The Wrench"" Littlesprocket"\tGnomeregan\n')
    local sold = generate(paths[1], paths[2], "--acquisition=" .. paths[8])
    local listed = sold.recipesBySpellId[2].sourcePlaces
    assert(listed[1].name == "Jazzrik", "the opening quote of the field is not part of the first name")
    assert(listed[2].name == '"Cookie" McWeaksauce', "a doubled quote inside the field is one quote")
    assert(sold.recipesBySpellId[3].sourcePlaces[1].name == 'Ziri "The Wrench" Littlesprocket',
        "a quoted name comes back as the game writes it")
    -- Una ricetta che la build corrente non elenca piu' (Disorienting Smog
    -- Potion con la 70532) la cattura del client ce l'ha ancora: si marca
    -- `removed` e resta intera, coi dati che il ripiego le ha dato.
    write(paths[4], [[MiningRecipes = { [3] = { recipeItemId = 5003, expansion = 'forever' } }
MiningRemovedSpells = { [3] = true }]])
    local gone = generate(paths[1], paths[2], "--mining=" .. paths[4])
    assert(gone.recipesBySpellId[3].removed == true, "a recipe the build no longer lists is removed")
    assert(gone.recipesBySpellId[3].recipeItemId == 5003, "a removed recipe keeps its data")
    assert(gone.recipesBySpellId[2].removed == nil, "the others stay in the game")
    -- La struttura dal datamining. Il dump e' della build 100 e il datamining
    -- della 300: nel frattempo la ricetta 3 ha cambiato prodotto, categoria e
    -- reagenti, e la 4 e' nata. La 5 c'era gia' alla 100 e il dump non la
    -- elenca, quindi il gioco la nasconde (Basic Campfire); la 6 sta su una
    -- skill line di cui non c'e' un dump (i veleni dei rogue).
    write(paths[6], [[RecipeRegistryDumpDB = { dumps = {
        Alchemy = { at = "2026-09-18 10:00:00", build = { "1.60.1", "100" },
            categories = { ["1"] = { categoryID = 1, name = "Alchemy", parentCategoryID = 0 },
                ["50"] = { categoryID = 50, name = "Potions", uiOrder = 5, parentCategoryID = 1 } },
            recipes = { { recipeID = 3, outputItemID = 33, categoryID = 50,
                reagents = { { itemID = 765, count = 2 }, { itemID = 766, count = 1 } } } } },
        Cooking = { at = "2026-09-18 10:00:00", build = { "1.60.1", "100" },
            categories = { ["2"] = { categoryID = 2, name = "Cooking", parentCategoryID = 0 },
                ["70"] = { categoryID = 70, name = "Meals", uiOrder = 1, parentCategoryID = 2 } },
            recipes = { { recipeID = 3, outputItemID = 33, categoryID = 70 } } },
    } }]])
    local structure = [[MiningRecipes = {
    [3] = { profession = 'alchemy', createdItemId = 34, category = 60, since = '1.60.1.100',
        reagents = { { itemId = 766, count = 1 }, { itemId = 765, count = 3 }, { itemId = 767, count = 1 } } },
    [4] = { profession = 'alchemy', category = 60, since = '1.60.1.300', reagents = { { itemId = 900, count = 1 } } },
    [5] = { profession = 'alchemy', since = '1.60.1.100' },
    [6] = { profession = 'skill:40', since = '1.60.1.300' },
}
MiningStructure = true
MiningCategories = { [1] = { name = "Alchemy", order = 0 }, [60] = { name = "Elixirs", order = 7, parent = 1 } }
]]
    write(paths[7], structure .. "MiningBuilds = { '1.60.1.300', '1.60.1.100' }\n")
    local built = generate(paths[6], "--mining=" .. paths[7])
    local three = built.recipesBySpellId[3]
    assert(three.createdItemId == 34 and built.createdItemToSpellIds[34][1] == 3, "the created item comes from the datamining")
    assert(three.category == "c60" and three.sortOrder == 7, "so does the category")
    assert(three.reagents[1].itemId == 765 and three.reagents[1].count == 3, "the counts are the datamining's")
    assert(three.reagents[2].itemId == 766, "the order is the game's, from the dump")
    assert(three.reagents[3].itemId == 767, "a reagent only the datamining knows goes last")
    assert(built.navTree.alchemy.c60 and not built.navTree.alchemy.c50, "the recipe moves to its new category")
    assert(built.navTree.cooking.c70, "in a profession the datamining does not give it, the dump's category stays")
    assert(built.recipesBySpellId[4] and built.recipesBySpellId[4].profession == "alchemy", "a recipe born after the dump comes in")
    assert(built.recipesBySpellId[4].category == "c60", "with its category")
    assert(built.recipesBySpellId[5] == nil, "one the game already hid at the dump's build stays out")
    assert(built.recipesBySpellId[6] == nil, "so does one from a skill line with no dump")
    assert(built.metadataVersion == "forever-1.60.1.300", "the version follows the datamining's build")
    -- Se le build lette non arrivano alla build del dump, il nuovo non si
    -- distingue dal nascosto: non entra niente.
    write(paths[7], structure .. "MiningBuilds = { '1.60.1.300' }\n")
    local unsure = generate(paths[6], "--mining=" .. paths[7])
    assert(unsure.recipesBySpellId[4] == nil, "without the dump's build to compare with, nothing new comes in")
    assert(unsure.recipesBySpellId[3].category == "c60", "the structure still comes from the datamining")
    -- Un datamining di formato vecchio non porta la struttura: resta il dump.
    write(paths[7], "MiningRecipes = { [3] = { createdItemId = 34, category = 60 } }\n")
    local plain = generate(paths[6], "--mining=" .. paths[7])
    assert(plain.recipesBySpellId[3].createdItemId == 33 and plain.recipesBySpellId[3].reagents[1].count == 2,
        "without MiningStructure the dump's structure stays")
    assert(plain.metadataVersion == "forever-ingame-1.60.1.100", "and the version follows the dump")
    local reverse = generate(paths[2], paths[1])
    assert(reverse.recipesBySpellId[3] and not reverse.recipesBySpellId[1], "older captures cannot replace newer ones")
end)
for _, path in ipairs(paths) do os.remove(path) end
assert(ok, err)
print("PASS generator: multiple sessions, legacy format, newest capture, reagents, indices, outputless is not self-only, static BoP from item binding, recipe items, required skill, recipes learned by themselves, four-step difficulty ladder, Forever trainer ranks, quoted names from the worksheet, recipes the build no longer lists, structure from the datamining")
