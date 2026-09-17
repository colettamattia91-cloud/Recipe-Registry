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

local addon, wow = Loader.Load({
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

-- Elixir of Lion's Strength: BoE output, no self-only flag — a plain
-- requestable craft in the metadata fixture.
local REQUESTABLE_RECIPE_KEY = -2329
local REMOTE_KEY = "Remotealchemist-TestRealm"

Test.it("keeps the quick-request button available inside instances", function()
    wow.SetInstance(true, "party")

    -- Guard: the spec is only meaningful while the pause policy really
    -- reports protocol traffic as paused.
    Test.eq(addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_PULL_REQUEST"), true)

    local meta, requestable, reason = ui:GetCrafterRequestMeta(REQUESTABLE_RECIPE_KEY, {
        memberKey = REMOTE_KEY,
        online = true,
    }, data:GetPlayerKey())

    Test.eq(requestable, true)
    Test.eq(reason, "requestable")
    Test.truthy(meta, "remote crafter should have request metadata")
    -- The Ask button only sends a whisper, so an instance must not hide it.
    Test.eq(meta.canRequest, true)
    Test.eq(meta.canWhisper, true)

    wow.SetInstance(false)
end)

Test.it("keeps the quick-request button available in combat", function()
    wow.SetCombat(true)

    local meta = ui:GetCrafterRequestMeta(REQUESTABLE_RECIPE_KEY, {
        memberKey = REMOTE_KEY,
        online = true,
    }, data:GetPlayerKey())

    Test.truthy(meta, "remote crafter should have request metadata")
    Test.eq(meta.canRequest, true)

    wow.SetCombat(false)
end)

Test.it("still hides the quick-request button for non-requestable crafts inside instances", function()
    wow.SetInstance(true, "raid")

    local meta, requestable, reason = ui:GetCrafterRequestMeta(-35530, {
        memberKey = "Remotebop-TestRealm",
        online = true,
    }, data:GetPlayerKey())

    Test.eq(requestable, false)
    Test.eq(reason, "not-requestable-bop-output")
    Test.eq(meta.canRequest, false)
    Test.eq(meta.canWhisper, true)

    wow.SetInstance(false)
end)
