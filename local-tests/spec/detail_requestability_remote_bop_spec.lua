local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function getUiFiles()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "UI/MainFrame.lua"
    return files
end

local addon = Loader.Load({
    files = getUiFiles(),
    metadataFixture = true,
})
Loader.LoadMetadata({
    reset = false,
    loadCore = false,
    fixture = true,
})

local data = addon.Data
local ui = addon.UI

Test.it("does not offer quick request for remote BoP output crafters", function()
    local remoteKey = "Remotebop-TestRealm"
    local requestable, reason = data:GetRecipeRequestability(-35530, remoteKey)
    Test.eq(requestable, false)
    Test.eq(reason, "not-requestable-bop-output")

    local meta, uiRequestable, uiReason = ui:GetCrafterRequestMeta(-35530, {
        memberKey = remoteKey,
        online = true,
    }, data:GetPlayerKey())

    Test.eq(uiRequestable, false)
    Test.eq(uiReason, "not-requestable-bop-output")
    Test.truthy(meta, "remote crafter should still have whisper metadata")
    Test.eq(meta.canWhisper, true)
    Test.eq(meta.canRequest, false)
end)

Test.it("does not offer quick request for remote self-only outputless crafters", function()
    local meta, requestable, reason = ui:GetCrafterRequestMeta(-27924, {
        memberKey = "Remotering-TestRealm",
        online = true,
    }, data:GetPlayerKey())

    Test.eq(requestable, false)
    Test.eq(reason, "not-requestable-self-only")
    Test.truthy(meta, "remote crafter should still have whisper metadata")
    Test.eq(meta.canRequest, false)
end)
