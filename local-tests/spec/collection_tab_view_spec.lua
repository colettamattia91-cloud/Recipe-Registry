-- The Collection tab as a table: row height, column widths, the one filter, and
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

local COLLECTION_VIEW = "Collection"
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

io.write("Collection tab view\n")

-- The browser row is 70px tall because it stacks a title, a crafter line and
-- a metadata line. A collection row is one line, and a blacksmith's book runs
-- to nearly four hundred of them.
Test.it("uses a compact row height for the table, not the browser height", function()
    useView(nil)
    local browserHeight = ui:GetListRowHeight()

    useView(COLLECTION_VIEW)
    local collectionHeight = ui:GetListRowHeight()
    Test.lte(collectionHeight, 32)
    Test.truthy(collectionHeight < browserHeight,
        "the table row should be shorter than the browser row")

    useView(ADDON_VIEW)
    Test.lte(ui:GetListRowHeight(), 32)
end)

Test.it("falls back to a full-width row before the first layout", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)
    local collectionWidth = ui:GetListRowWidth()

    useView(nil)
    local browserWidth = ui:GetListRowWidth()
    Test.truthy(collectionWidth > browserWidth,
        "the full-width table must not size itself for the browser column")
end)

Test.it("lays out five columns that fit the row", function()
    useView(COLLECTION_VIEW)
    withScrollWidth(1170)

    local nameWidth, skillWidth, sourceWidth, specWidth, factionWidth = ui:GetCollectionColumnWidths()
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
    useView(COLLECTION_VIEW)
    withScrollWidth(1170)
    local narrowName, narrowSkill, narrowSource, narrowSpec, narrowFaction = ui:GetCollectionColumnWidths()

    withScrollWidth(1570)
    local wideName, wideSkill, wideSource, wideSpec, wideFaction = ui:GetCollectionColumnWidths()

    Test.truthy(wideName > narrowName, "the name column should grow")
    Test.truthy(wideSource > narrowSource, "the source column should grow")
    Test.eq(wideSkill, narrowSkill)
    Test.eq(wideSpec, narrowSpec)
    Test.eq(wideFaction, narrowFaction)
end)

Test.it("keeps both flexible columns readable at the minimum window size", function()
    useView(COLLECTION_VIEW)
    withScrollWidth(990)
    local nameWidth, _, sourceWidth = ui:GetCollectionColumnWidths()
    Test.gte(nameWidth, 190)
    Test.gte(sourceWidth, 140)
end)

-- The help line under the control strip is the only place that can explain an
-- empty list, and an empty list has more than one cause.
Test.it("says what the filter is showing, and why the list is empty", function()
    local help = { SetText = function(self, value) self.value = value end }
    local button = {
        SetText = function(self, value) self.value = value end,
        SetLabel = function(self, value) self.label = value end,
        SetSelected = function(self, on) self.selected = on end,
    }
    ui.frame = { collectionHelp = help, collectionFilterButton = button }
    useView(COLLECTION_VIEW)

    local playerKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(playerKey)
    entry.guildStatus = "active"
    entry.sourceType = "owner"
    entry.updatedAt = entry.updatedAt or 100
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions = {}
    data:InvalidateRecipeCaches()

    ui._collectionShownCount = 0
    data:SetCollectionFilter("all")
    ui:RefreshCollectionControls()
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

    ui._collectionShownCount = 40
    ui:RefreshCollectionControls()
    -- The unfiltered state is never highlighted: a full book must not look
    -- like a filtered one.
    Test.eq(button.selected, false)
    Test.eq(button.label, "Show: All")
    Test.truthy(help.value:find("ticked") ~= nil, "got: " .. tostring(help.value))

    data:SetCollectionFilter("unlearned")
    ui:RefreshCollectionControls()
    Test.eq(button.selected, true)
    Test.eq(button.label, "Show: Not learned")
    Test.truthy(help.value:find("still to learn") ~= nil, "got: " .. tostring(help.value))

    data:SetCollectionFilter("ready")
    ui:RefreshCollectionControls()
    Test.eq(button.label, "Show: Ready to learn")

    -- Empty because of the filter, not because the collection is empty.
    ui._collectionShownCount = 0
    ui:RefreshCollectionControls()
    Test.truthy(help.value:find("widen") ~= nil,
        "an empty filtered list should say how to widen it, got: " .. tostring(help.value))

    data:SetCollectionFilter("all")
end)

-- Both halves of "Blacksmithing (185/385)" come from the whole book: the
-- filter decides what is drawn, never what is counted.
Test.it("counts the collected half whatever the filter hides", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)

    local rows = {
        { collection = { professionName = "Blacksmithing", known = true,  skillMet = true,  specializationMet = true } },
        { collection = { professionName = "Blacksmithing", known = false, skillMet = true,  specializationMet = true } },
        { collection = { professionName = "Blacksmithing", known = false, skillMet = false, specializationMet = true } },
        { collection = { professionName = "Alchemy",       known = true,  skillMet = true,  specializationMet = true } },
    }

    data:SetCollectionFilter("ready")
    local display = ui:BuildCollectionDisplayRows(rows)

    local groups = {}
    local drawn = 0
    for _, row in ipairs(display) do
        if row.rowType == "collectionGroup" then
            groups[row.groupKey] = row
        elseif row.rowType == "collection" then
            drawn = drawn + 1
        end
    end

    Test.eq(groups.Blacksmithing.count, 3)
    Test.eq(groups.Blacksmithing.known, 1)
    Test.eq(groups.Alchemy.count, 1)
    Test.eq(groups.Alchemy.known, 1)
    -- Only the unlearned, reachable blacksmithing recipe survives "ready".
    Test.eq(drawn, 1)
    Test.eq(ui._collectionTotalCount, 4)
    Test.eq(ui._collectionKnownCount, 2)
    Test.eq(ui._collectionShownCount, 1)

    data:SetCollectionFilter("all")
    display = ui:BuildCollectionDisplayRows(rows)
    Test.eq(ui._collectionShownCount, 4)
end)

-- A collapsed profession still counts: collapsing is about ink, not about
-- what is in the book.
Test.it("keeps counting a profession that is collapsed", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)
    data:SetCollectionFilter("all")

    local rows = {
        { collection = { professionName = "Alchemy", known = true,  skillMet = true, specializationMet = true } },
        { collection = { professionName = "Alchemy", known = false, skillMet = true, specializationMet = true } },
    }

    ui._collapsedCollectionGroups = { Alchemy = true }
    local display = ui:BuildCollectionDisplayRows(rows)
    ui._collapsedCollectionGroups = nil

    local drawn = 0
    local group
    for _, row in ipairs(display) do
        if row.rowType == "collectionGroup" then group = row end
        if row.rowType == "collection" then drawn = drawn + 1 end
    end
    Test.eq(drawn, 0)
    Test.eq(group.count, 2)
    Test.eq(group.known, 1)
    Test.eq(ui._collectionShownCount, 2)
end)

-- The strip's own title and the recipe header are anchored to the same
-- corner of the same frame, so showing both drew one over the other.
Test.it("shows one title in the collection view, not two", function()
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
        collectionControls = controls,
        collectionHelp = help,
        collectionLearnableToggle = toggle,
    }

    useView(COLLECTION_VIEW)
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

    ui:ShowCollectionRowTooltip({
        tooltipLink = "item:22307",
        collectionLabel = "Plans: Felsteel Longblade",
        collectionInfo = {
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

-- A recipe already in the book keeps its source line -- "where did I get
-- this" is a real question -- but nothing in the tooltip may still read as
-- something you have to go and do.
Test.it("tells a learned recipe apart in the tooltip", function()
    local lines = {}
    _G.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function(_, link) lines[#lines + 1] = "link:" .. tostring(link) end,
        AddLine = function(_, text) lines[#lines + 1] = tostring(text) end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = tostring(left) .. "|" .. tostring(right) end,
        Show = function() end,
        Hide = function() end,
    }

    ui:ShowCollectionRowTooltip({
        tooltipLink = "item:22307",
        collectionLabel = "Plans: Felsteel Longblade",
        collectionInfo = {
            known = true,
            professionName = "Blacksmithing",
            requiredSkill = 365,
            skillRank = 375,
            skillMet = true,
            sourceKind = "vendor",
            sourceLabel = "Vendor: Kradu Grimblade (Hellfire Peninsula)",
            sourceLines = { "Vendor: Kradu Grimblade (Hellfire Peninsula)" },
        },
    })

    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("Where it comes from", 1, true) ~= nil,
        "a learned recipe is not somewhere to go, got: " .. joined)
    Test.eq(joined:find("Where to learn", 1, true), nil)
    Test.truthy(joined:find("Learned|Blacksmithing", 1, true) ~= nil)
    -- The skill it once needed is history.
    Test.eq(joined:find("you: 375", 1, true), nil)
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

    ui:ShowCollectionRowTooltip({
        collectionLabel = "Transmute: Primal Might",
        collectionInfo = {
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

io.write(string.format("Collection tab view: %d test(s) passed\n", Test.count))
