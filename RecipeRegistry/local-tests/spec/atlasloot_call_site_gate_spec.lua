local Test = dofile("local-tests/harness/test.lua")

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local contents = handle:read("*a")
    handle:close()
    return contents
end

local function fileExists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function runtimeFilesFromToc()
    local paths = { "RecipeRegistry.toc" }
    for line in readFile("RecipeRegistry.toc"):gmatch("[^\r\n]+") do
        local path = line:match("^%s*([^#%s].-%.lua)%s*$")
        if path then
            paths[#paths + 1] = path:gsub("\\", "/")
        end
    end
    return paths
end

Test.it("keeps AtlasLoot references out of the release runtime surface", function()
    for _, path in ipairs(runtimeFilesFromToc()) do
        local contents = readFile(path)
        Test.falsy(contents:lower():find("atlasloot", 1, true), path .. " must not reference AtlasLoot")
    end
end)

Test.it("removes the legacy AtlasLoot data module from the loaded addon", function()
    Test.falsy(fileExists("Data/DataAtlasLoot.lua"), "Data/DataAtlasLoot.lua should not ship in the runtime addon")
end)
