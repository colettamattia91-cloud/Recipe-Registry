-- Multiple saved sessions must accumulate professions; the latest capture of
-- one profession replaces only that profession, regardless of input order.
local base = "local-tests/specs/.dump-generator-"
local paths = { base .. "old.lua", base .. "new.lua", base .. "output.lua" }
local function write(path, content)
    local file = assert(io.open(path, "w")); file:write(content); file:close()
end
local function generate(first, second)
    local env = setmetatable({ arg = { first, paths[3], second } }, { __index = _G })
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
    local reverse = generate(paths[2], paths[1])
    assert(reverse.recipesBySpellId[3] and not reverse.recipesBySpellId[1], "older captures cannot replace newer ones")
end)
for _, path in ipairs(paths) do os.remove(path) end
assert(ok, err)
print("PASS generator: multiple sessions, legacy format, newest capture, reagents and indices")
