local Test = dofile("local-tests/harness/test.lua")

local projectionAllowlist = {
    "Data/DataCatalog.lua",
    "UI/MainFrame.lua",
    "UI/Tooltip.lua",
    "UI/Options.lua",
}

local blockedPatterns = {
    "AtlasLoot",
    "AtlasLootClassic",
}

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local contents = handle:read("*a")
    handle:close()
    return contents
end

Test.it("keeps AtlasLoot references out of the UI projection allowlist", function()
    for _, path in ipairs(projectionAllowlist) do
        local contents = readFile(path)
        for _, pattern in ipairs(blockedPatterns) do
            Test.falsy(contents:find(pattern, 1, true), path .. " must not reference " .. pattern)
        end
    end
end)

