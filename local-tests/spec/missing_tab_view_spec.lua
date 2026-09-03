-- The Missing tab as a table: row height, column widths, the one filter, and
-- the tooltip that carries what the columns have to clip.
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
local data = addon.Data

local MISSING_VIEW = "Missing recipes"
local ADDON_VIEW = "Guild members"

-- SetMainView drives a full refresh through frames the harness does not
-- build; the view itself is just this field, which is what every Is*View
-- predicate reads.
local function useView(view)
    ui.selectedProfession = view
end

local function withScrollWidth(width)
    ui.frame = {
        recipeScroll = { GetWidth = function() return width end },
    }
end

io.write("Missing tab view\n")

-- The browser row is 70px tall because it stacks a title, a crafter line and
-- a metadata line. A missing row is one line, and a blacksmith is missing
-- three hundred recipes.
Test.it("uses a compact row height for the table, not the browser height", function()
    useView(nil)
    local browserHeight = ui:GetListRowHeight()

    useView(MISSING_VIEW)
    local missingHeight = ui:GetListRowHeight()
    Test.lte(missingHeight, 32)
    Test.truthy(missingHeight < browserHeight,
        "the table row should be shorter than the browser row")

    useView(ADDON_VIEW)
    Test.lte(ui:GetListRowHeight(), 32)
end)

Test.it("falls back to a full-width row before the first layout", function()
    ui.frame = nil
    useView(MISSING_VIEW)
    local missingWidth = ui:GetListRowWidth()

    useView(nil)
    local browserWidth = ui:GetListRowWidth()
    Test.truthy(missingWidth > browserWidth,
        "the full-width table must not size itself for the browser column")
end)

Test.it("lays out five columns that fit the row", function()
    useView(MISSING_VIEW)
    withScrollWidth(1170)

    local nameWidth, skillWidth, sourceWidth, specWidth, factionWidth = ui:GetMissingColumnWidths()
    for _, width in ipairs({ nameWidth, skillWidth, sourceWidth, specWidth, factionWidth }) do
        Test.gte(width, 1)
    end
    -- 40px icon inset, four 8px gaps, 10px of right margin.
    local total = 40 + nameWidth + skillWidth + sourceWidth + specWidth + factionWidth + (8 * 4) + 10
    Test.lte(total, ui:GetListRowWidth() + 1)
end)

-- Skill, specialization and faction are as wide as their longest content and
-- no wider. The recipe name and the source are the two that get cut off, so
-- they take everything the window gains.
Test.it("gives the extra width to the name and the source", function()
    useView(MISSING_VIEW)
    withScrollWidth(1170)
    local narrowName, narrowSkill, narrowSource, narrowSpec, narrowFaction = ui:GetMissingColumnWidths()

    withScrollWidth(1570)
    local wideName, wideSkill, wideSource, wideSpec, wideFaction = ui:GetMissingColumnWidths()

    Test.truthy(wideName > narrowName, "the name column should grow")
    Test.truthy(wideSource > narrowSource, "the source column should grow")
    Test.eq(wideSkill, narrowSkill)
    Test.eq(wideSpec, narrowSpec)
    Test.eq(wideFaction, narrowFaction)
end)

Test.it("keeps both flexible columns readable at the minimum window size", function()
    useView(MISSING_VIEW)
    withScrollWidth(990)
    local nameWidth, _, sourceWidth = ui:GetMissingColumnWidths()
    Test.gte(nameWidth, 190)
    Test.gte(sourceWidth, 140)
end)

-- The help line under the control strip is the only place that can explain an
-- empty list, and an empty list has three different causes.
Test.it("explains an empty list with the filter on", function()
    local help = { SetText = function(self, value) self.value = value end }
    local toggle = { SetSelected = function(self, on) self.selected = on end }
    ui.frame = { missingHelp = help, missingLearnableToggle = toggle }
    useView(MISSING_VIEW)

    local playerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(playerKey)
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = {}
    data:InvalidateRecipeCaches()

    ui._missingRecipeCount = 0
    data:SetMissingRecipesLearnableOnly(false)
    ui:RefreshMissingControls()
    Test.truthy(help.value:find("Open your profession windows") ~= nil,
        "an unscanned character should be told to open the window, got: " .. tostring(help.value))

    entry.professions = {
        Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
            recipes = {},
            skillRank = 375,
            skillMaxRank = 375,
            sourceType = "owner",
        }),
    }
    data:InvalidateRecipeCaches()

    ui:RefreshMissingControls()
    Test.eq(toggle.selected, false)
    Test.truthy(help.value:find("can still learn") ~= nil, "got: " .. tostring(help.value))

    data:SetMissingRecipesLearnableOnly(true)
    ui._missingRecipeCount = 12
    ui:RefreshMissingControls()
    Test.eq(toggle.selected, true)
    Test.truthy(help.value:find("right now") ~= nil, "got: " .. tostring(help.value))

    ui._missingRecipeCount = 0
    ui:RefreshMissingControls()
    Test.truthy(help.value:find("Ready to learn") ~= nil,
        "an empty filtered list should name the filter, got: " .. tostring(help.value))

    data:SetMissingRecipesLearnableOnly(false)
end)

-- The strip's own title and the recipe header are anchored to the same
-- corner of the same frame, so showing both drew one over the other.
Test.it("shows one title in the missing view, not two", function()
    local function stub()
        return {
            Show = function(self) self.visible = true end,
            Hide = function(self) self.visible = false end,
            SetText = function(self, value) self.value = value end,
            SetSelected = function(self, on) self.selected = on end,
        }
    end
    local header, controls, help, toggle = stub(), stub(), stub(), stub()
    ui.frame = {
        recipeHeader = header,
        missingControls = controls,
        missingHelp = help,
        missingLearnableToggle = toggle,
    }

    useView(MISSING_VIEW)
    ui:RefreshAddonStatusControls()
    Test.eq(header.visible, false)
    Test.eq(controls.visible, true)

    useView(nil)
    ui:RefreshAddonStatusControls()
    Test.eq(header.visible, true)
    Test.eq(controls.visible, false)
end)

-- The columns clip on purpose; everything they cut is in the tooltip.
Test.it("puts the whole source in the row tooltip", function()
    local lines = {}
    _G.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function(_, link) lines[#lines + 1] = "link:" .. tostring(link) end,
        AddLine = function(_, text) lines[#lines + 1] = tostring(text) end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = tostring(left) .. "|" .. tostring(right) end,
        Show = function() end,
        Hide = function() end,
    }

    ui:ShowMissingRowTooltip({
        tooltipLink = "item:22307",
        missingLabel = "Plans: Felsteel Longblade",
        missingInfo = {
            professionName = "Blacksmithing",
            requiredSkill = 365,
            skillRank = 300,
            skillMet = false,
            sourceKind = "vendor",
            sourceLabel = "Vendor: Kradu Grimblade (Hellfire Peninsula), Zula Slagfury (Hellfire Peninsula)",
            sourceLines = {
                "Vendor: Kradu Grimblade (Hellfire Peninsula)",
                "Vendor: Zula Slagfury (Hellfire Peninsula)",
            },
            faction = "alliance",
            specializationName = "Master Swordsmith",
            specializationMet = false,
        },
    })

    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("link:item:22307", 1, true) ~= nil,
        "the recipe's own tooltip should still be shown")
    Test.truthy(joined:find("Where to learn", 1, true) ~= nil)
    -- Both vendors, each on its own line: this is the half the column clips.
    Test.truthy(joined:find("Kradu Grimblade", 1, true) ~= nil)
    Test.truthy(joined:find("Zula Slagfury", 1, true) ~= nil)
    Test.truthy(joined:find("Alliance only", 1, true) ~= nil)
    Test.truthy(joined:find("Blacksmithing 365|you: 300", 1, true) ~= nil,
        "the skill requirement should sit next to the character's rank")
    Test.truthy(joined:find("Requires Master Swordsmith", 1, true) ~= nil)
end)

Test.it("still names the recipe when there is no item to hang the tooltip on", function()
    local lines = {}
    _G.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function() error("should not be called") end,
        AddLine = function(_, text) lines[#lines + 1] = tostring(text) end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = tostring(left) .. "|" .. tostring(right) end,
        Show = function() end,
        Hide = function() end,
    }

    ui:ShowMissingRowTooltip({
        missingLabel = "Transmute: Primal Might",
        missingInfo = {
            professionName = "Alchemy",
            sourceKind = "discovery",
            sourceLabel = "Discovery",
            sourceLines = { "Discovery" },
        },
    })

    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("Transmute: Primal Might", 1, true) ~= nil)
    Test.truthy(joined:find("Discovery", 1, true) ~= nil)
end)

io.write(string.format("Missing tab view: %d test(s) passed\n", Test.count))
