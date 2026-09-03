-- Top-level tab visibility. Tabs are declared once in the UI module's
-- registry; the nav layout, the options panel and the fallback when a tab is
-- switched off all read from it, so a future tab needs no extra plumbing.
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

local addon = Loader.Load({ files = getUiFiles() })
local ui = addon.UI

local function definitionFor(key)
    for _, definition in ipairs(ui:GetMainTabDefinitions()) do
        if definition.key == key then return definition end
    end
    return nil
end

io.write("Main tabs\n")

Test.it("declares every tab in one registry", function()
    local definitions = ui:GetMainTabDefinitions()
    Test.gte(#definitions, 3)
    Test.eq(definitions[1].key, "recipes")
    Test.truthy(definitionFor("addon") ~= nil)
    Test.truthy(definitionFor("collection") ~= nil)
end)

Test.it("shows every tab by default", function()
    addon.db.profile.tabs = {}
    Test.eq(ui:IsMainTabEnabled("recipes"), true)
    Test.eq(ui:IsMainTabEnabled("addon"), true)
    Test.eq(ui:IsMainTabEnabled("collection"), true)
end)

Test.it("hides an optional tab that was switched off", function()
    ui:SetMainView("recipes")
    ui:SetMainTabEnabled("addon", false)
    Test.eq(ui:IsMainTabEnabled("addon"), false)
    Test.eq(ui:IsMainTabEnabled("collection"), true)

    ui:SetMainTabEnabled("addon", true)
    Test.eq(ui:IsMainTabEnabled("addon"), true)
end)

Test.it("never lets the recipes tab be switched off", function()
    Test.eq(definitionFor("recipes").optional, false)
    ui:SetMainTabEnabled("recipes", false)
    Test.eq(ui:IsMainTabEnabled("recipes"), true)
end)

Test.it("refuses to open a tab that is switched off", function()
    ui:SetMainTabEnabled("collection", false)
    ui:SetMainView("collection")
    Test.eq(ui:GetMainView(), "recipes")
    ui:SetMainTabEnabled("collection", true)
end)

Test.it("moves you off a tab you switch off while standing on it", function()
    ui:SetMainView("addon")
    Test.eq(ui:GetMainView(), "addon")

    ui:SetMainTabEnabled("addon", false)
    Test.eq(ui:GetMainView(), "recipes")
    ui:SetMainTabEnabled("addon", true)
end)

Test.it("resolves every historical name of the guild members tab", function()
    -- The view name is stored verbatim in the profile, so a rename has to
    -- keep old saved values working.
    local label = definitionFor("addon").label
    Test.eq(label, "Guild members")

    for _, legacy in ipairs({ "Addon Status", "Guild Addon Adoption", "Guild Addons" }) do
        addon.db.profile.selectedProfession = legacy
        ui:OnInitialize()
        Test.eq(ui:GetMainView(), "addon", "legacy name " .. legacy .. " should still open the tab")
    end
end)

Test.it("resolves the collection tab's old name", function()
    -- Same reason: the tab shipped as "Missing recipes" and the view name is
    -- stored verbatim, so a profile written before the rename still has to
    -- land on the tab.
    Test.eq(definitionFor("collection").label, "Collection")

    addon.db.profile.selectedProfession = "Missing recipes"
    ui:OnInitialize()
    Test.eq(ui:GetMainView(), "collection")
end)

Test.it("drops a saved view whose tab is no longer shown", function()
    addon.db.profile.selectedProfession = "Guild members"
    addon.db.profile.tabs = { addon = false }
    ui:OnInitialize()
    Test.eq(ui:GetMainView(), "recipes")
    addon.db.profile.tabs = {}
end)

io.write(string.format("Main tabs: %d test(s) passed\n", Test.count))
