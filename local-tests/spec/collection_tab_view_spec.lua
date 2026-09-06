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

    local nameWidth, statusWidth, skillWidth, sourceWidth, specWidth = ui:GetCollectionColumnWidths()
    for _, width in ipairs({ nameWidth, statusWidth, skillWidth, sourceWidth, specWidth }) do
        Test.gte(width, 1)
    end
    -- 40px icon inset plus the 16px the rows are indented under their
    -- profession header, four 8px gaps, 10px of right margin.
    local total = 56 + nameWidth + statusWidth + skillWidth + sourceWidth + specWidth + (8 * 4) + 10
    Test.lte(total, ui:GetListRowWidth() + 1)
end)

-- Status, skill and specialization are as wide as their longest content and
-- no wider. The recipe name and the source are the two that get cut off, so
-- they take everything the window gains.
Test.it("gives the extra width to the name and the source", function()
    useView(COLLECTION_VIEW)
    withScrollWidth(1170)
    local narrowName, narrowStatus, narrowSkill, narrowSource, narrowSpec = ui:GetCollectionColumnWidths()

    withScrollWidth(1570)
    local wideName, wideStatus, wideSkill, wideSource, wideSpec = ui:GetCollectionColumnWidths()

    Test.truthy(wideName > narrowName, "the name column should grow")
    Test.truthy(wideSource > narrowSource, "the source column should grow")
    Test.eq(wideStatus, narrowStatus)
    Test.eq(wideSkill, narrowSkill)
    Test.eq(wideSpec, narrowSpec)
end)

Test.it("keeps both flexible columns readable at the minimum window size", function()
    useView(COLLECTION_VIEW)
    withScrollWidth(990)
    local nameWidth, _, _, sourceWidth = ui:GetCollectionColumnWidths()
    Test.gte(nameWidth, 190)
    Test.gte(sourceWidth, 150)
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
    -- The one control now stands for every axis the table can be narrowed by,
    -- so "unfiltered" means the expansions are open too.
    -- Both of these refresh the list, which wants a real frame; the stub is
    -- put back straight after.
    ui.frame = nil
    ui:SetExpansionFilter("all")
    ui:ClearCollectionColumnFilters()
    ui.frame = { collectionHelp = help, collectionFilterButton = button }
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

-- Rows are no longer a uniform height: a recipe sold in four cities is four
-- lines tall, so each row carries its own height and its offset from the top
-- of the list. Everything that used to multiply an index by a constant now
-- reads those two numbers instead.
local function sourceRow(profession, lineCount, known)
    local lines = {}
    for i = 1, lineCount do lines[i] = "Vendor: Somebody " .. i .. " (Somewhere)" end
    return {
        collection = {
            professionName = profession,
            known = known or false,
            skillMet = true,
            specializationMet = true,
            sourceLines = lines,
        },
    }
end

Test.it("makes a row as tall as its source list", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)
    data:SetCollectionFilter("all")

    local display = ui:BuildCollectionDisplayRows({
        sourceRow("Alchemy", 1),
        sourceRow("Alchemy", 3),
    })

    local drawn = {}
    for _, row in ipairs(display) do
        if row.rowType == "collection" then drawn[#drawn + 1] = row end
    end
    Test.eq(#drawn, 2)
    Test.truthy(drawn[2]._rowHeight > drawn[1]._rowHeight,
        "a three-place recipe should be taller than a one-place recipe")
    -- Two extra lines at 14px on top of the 30px single-line row.
    Test.eq(drawn[2]._rowHeight - drawn[1]._rowHeight, 28)
end)

Test.it("stacks every row against the one above it", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)

    local display = ui:BuildCollectionDisplayRows({
        sourceRow("Alchemy", 2),
        sourceRow("Alchemy", 1),
        sourceRow("Alchemy", 4),
    })

    local expected = 0
    for _, row in ipairs(display) do
        Test.eq(row._rowOffset, expected)
        expected = expected + row._rowHeight
    end
    -- The content height is the far edge of the last row, not a row count
    -- times a constant.
    Test.eq(ui._collectionContentHeight, expected)
end)

-- The dataset's own maximum is four places. A row is capped there so a future
-- data change cannot produce a row taller than the window.
Test.it("caps how tall one row can get", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)

    local display = ui:BuildCollectionDisplayRows({ sourceRow("Alchemy", 4), sourceRow("Alchemy", 12) })
    local drawn = {}
    for _, row in ipairs(display) do
        if row.rowType == "collection" then drawn[#drawn + 1] = row end
    end
    Test.eq(drawn[1]._rowHeight, drawn[2]._rowHeight)
end)

Test.it("gives a group header its own height", function()
    ui.frame = nil
    useView(COLLECTION_VIEW)

    local display = ui:BuildCollectionDisplayRows({ sourceRow("Alchemy", 1) })
    local header, group, recipe
    for _, row in ipairs(display) do
        if row.rowType == "collectionHeader" then header = row end
        if row.rowType == "collectionGroup" then group = row end
        if row.rowType == "collection" then recipe = row end
    end
    Test.truthy(header ~= nil and group ~= nil and recipe ~= nil)
    Test.truthy(group._rowHeight > recipe._rowHeight,
        "a profession header should stand out from the rows under it")
end)

-- The row pool is shared by three tables that draw nothing alike: the recipe
-- browser, the guild members table and the collection table. A row arrives
-- owning whatever font strings the view that used it last left showing, so
-- every bind has to put the other two views away before it draws. Missing one
-- direction put the collection's columns on top of the guild members table.
--
-- Checked against the source rather than by building three frame hierarchies:
-- what has to hold is that no bind path can be added without the reset, and
-- that is a property of the code, not of one rendered row.
local function readMainFrame()
    local handle = assert(io.open("UI/MainFrame.lua", "r"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local mainFrameSource = readMainFrame()

local function bodyOf(signature)
    local startAt = mainFrameSource:find(signature, 1, true)
    if not startAt then return nil end
    local stopAt = mainFrameSource:find("\nend", startAt, true)
    if not stopAt then return nil end
    return mainFrameSource:sub(startAt, stopAt)
end

Test.it("puts the other tables away before drawing a guild members row", function()
    local reset = bodyOf("local function prepareAddonStatusRow(")
    Test.truthy(reset ~= nil, "expected a shared reset for guild members rows")
    Test.truthy(reset:find("HideCollectionRowParts", 1, true) ~= nil,
        "the reset must hide the collection columns")
    Test.truthy(reset:find("HideRecipeRowParts", 1, true) ~= nil,
        "the reset must hide the recipe browser parts")
    -- The state behind the columns goes too, or a guild members row still
    -- answers as a collection row when the mouse crosses it.
    Test.truthy(reset:find("row.collectionInfo = nil", 1, true) ~= nil)

    for _, name in ipairs({
        "function UI:BindAddonStatusGroupRow(",
        "function UI:BindAddonStatusHeaderRow(",
        "function UI:BindAddonStatusRow(",
    }) do
        local body = bodyOf(name)
        Test.truthy(body ~= nil, "expected " .. name)
        Test.truthy(body:find("prepareAddonStatusRow(", 1, true) ~= nil,
            name .. " must go through the shared reset")
    end
end)

Test.it("puts the other tables away before drawing a collection row", function()
    local reset = bodyOf("local function prepareCollectionRow(")
    Test.truthy(reset ~= nil, "expected a shared reset for collection rows")
    Test.truthy(reset:find("HideRecipeRowParts", 1, true) ~= nil)
    Test.truthy(reset:find("SetAddonStatusPartsVisible", 1, true) ~= nil,
        "the reset must hide the guild members columns")
end)

Test.it("puts the other tables away before drawing a browser row", function()
    local body = bodyOf("function UI:BindRecipeRow(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("HideCollectionRowParts", 1, true) ~= nil)
    Test.truthy(body:find("SetAddonStatusPartsVisible", 1, true) ~= nil)
end)

-- The hit area is a Button, not a font string: left showing over another
-- table it would swallow that table's mouse events, not merely draw over them.
Test.it("hides the name hit area with the rest of the collection row", function()
    local body = bodyOf("function UI:HideCollectionRowParts(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("collectionNameHit", 1, true) ~= nil,
        "the tooltip hit area must be hidden too")
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

-- WoW's fonts do not carry the geometric-shapes block, so the UTF-8 triangles
-- these headers used to draw came out as empty boxes -- in the collection, in
-- guild members, and in the detail panel's Offline toggle alike. Nothing at
-- runtime can tell a missing glyph from a drawn one, so the guard is that the
-- source no longer asks for one.
Test.it("draws collapse toggles with art, not with a glyph the font lacks", function()
    Test.eq(mainFrameSource:find("\\226\\150", 1, true), nil,
        "the UTF-8 triangles do not render in WoW; use collapseTag instead")
    for _, name in ipairs({
        "function UI:BindCollectionGroupRow(",
        "function UI:BindAddonStatusGroupRow(",
    }) do
        local body = bodyOf(name)
        Test.truthy(body ~= nil, "expected " .. name)
        Test.truthy(body:find("collapseTag(", 1, true) ~= nil,
            name .. " must take its arrow from the shared tag")
    end
end)

-- SetWordWrap(false) collapses a font string to a single line, which threw
-- away the newlines the stacked source writes: a recipe sold by two vendors
-- showed one. The source column is the one column that keeps wrapping on.
Test.it("lets the source column keep its newlines", function()
    local body = bodyOf("local function makeCollectionColumn(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("if not multiline and fs.SetWordWrap", 1, true) ~= nil,
        "wrapping must stay on for the multiline column")
    local parts = bodyOf("function UI:EnsureCollectionRowParts(")
    Test.truthy(parts ~= nil)
    Test.truthy(parts:find("makeCollectionColumn(row, row.collectionSkill, sourceWidth, true)", 1, true) ~= nil,
        "the source column must be built as the multiline one")
end)

-- Two vendors are two lines. The row was already measured for them; what had
-- gone missing was the text ever reaching the screen as two lines.
Test.it("stacks every place the recipe can be learned from", function()
    local text = ui:CollectionSourceText({
        sourceKind = "vendor",
        sourceLines = {
            "Vendor: Kradu Grimblade (Hellfire Peninsula)",
            "Vendor: Zula Slagfury (Hellfire Peninsula)",
        },
    }, false)
    Test.truthy(text:find("Kradu Grimblade", 1, true) ~= nil)
    Test.truthy(text:find("Zula Slagfury", 1, true) ~= nil)
    Test.truthy(text:find("\n", 1, true) ~= nil, "the two vendors must be on two lines")
end)

-- Four is the dataset's maximum and the row height stops there, so the text
-- has to stop there too.
Test.it("stops the stacked source where the row height stops", function()
    local lines = {}
    for i = 1, 9 do lines[i] = "Vendor: Somebody " .. i .. " (Somewhere)" end
    local text = ui:CollectionSourceText({ sourceKind = "vendor", sourceLines = lines }, false)
    local count = 1
    for _ in text:gmatch("\n") do count = count + 1 end
    Test.eq(count, 4)
end)

-- The bands were wide enough that a 335 recipe still read green at skill 375,
-- forty points past it. Grey means "this will not move the bar any more", and
-- forty points past the requirement is squarely that.
local GREY, GREEN, YELLOW, ORANGE, RED = "|cff808080", "|cff40bf40", "|cffffff00", "|cffff8040", "|cffff4040"

local function skillColour(required, rank)
    local text = ui:CollectionSkillText({ requiredSkill = required, skillRank = rank }, false)
    return text:sub(1, 10)
end

Test.it("greys a recipe the character has long outgrown", function()
    -- The case Mattia reported: Engineering 375, recipe 335.
    Test.eq(skillColour(335, 375), GREY)
    Test.eq(skillColour(345, 375), GREY)
    Test.eq(skillColour(350, 375), GREEN)
    Test.eq(skillColour(360, 375), YELLOW)
    Test.eq(skillColour(370, 375), ORANGE)
    Test.eq(skillColour(375, 375), ORANGE)
    -- Out of reach is the one colour WoW itself never shows, because the game
    -- never lists a recipe you cannot learn. This view exists to list them.
    Test.eq(skillColour(380, 375), RED)
end)

Test.it("says nothing rather than guessing when the skill is unknown", function()
    local text = ui:CollectionSkillText({ skillRank = 375 }, false)
    Test.truthy(text:find("-", 1, true) ~= nil,
        "686 of 2151 records carry no requiredSkill; the column must not invent one")
end)

-- The hint is a button parented to the centre panel, and the full-width views
-- take that panel over. Both of its refresh calls live in the recipe-list
-- build, which never runs for those views -- so the layout switch is the only
-- place that can put it away on the way in.
Test.it("puts the hidden-expansion hint away when a full-width view takes over", function()
    local body = bodyOf("function UI:ApplyMainLayout(")
    Test.truthy(body ~= nil)
    local branch = body:find("if self:IsFullWidthView() then", 1, true)
    local otherwise = body:find("\n    else", 1, true)
    Test.truthy(branch ~= nil and otherwise ~= nil and otherwise > branch)
    Test.truthy(body:sub(branch, otherwise):find("RefreshHiddenExpansionHint", 1, true) ~= nil,
        "the full-width branch must refresh the hint, which hides it there")
end)

-- The column headers: the guild members table has sorted and filtered from its
-- headers since it was built, and the collection table -- which is longer, and
-- the one people scan looking for a hole -- had neither.
local function columnRow(profession, opts)
    opts = opts or {}
    return {
        recipeKey = opts.recipeKey or -1,
        label = opts.label,
        _collectionResolved = opts.label ~= nil or nil,
        collection = {
            professionName = profession,
            known = opts.known or false,
            requiredSkill = opts.requiredSkill,
            skillRank = opts.skillRank or 375,
            skillMet = opts.skillMet ~= false,
            specializationMet = opts.specializationMet ~= false,
            specializationSpellId = opts.specializationSpellId,
            specializationName = opts.specializationName,
            sourceKind = opts.sourceKind,
            sourceLabel = opts.sourceLabel,
            sourceLines = opts.sourceLines,
            phase = opts.phase,
        },
    }
end

local function drawnRows(display)
    local out = {}
    for _, row in ipairs(display) do
        if row.rowType == "collection" then out[#out + 1] = row end
    end
    return out
end

local function resetColumnState()
    ui.frame = nil
    useView(COLLECTION_VIEW)
    ui.collectionFilters = { skill = "all", source = "all", spec = "all", phase = "all" }
    ui.collectionSortKey = "default"
    ui.collectionSortDir = "asc"
    data:SetCollectionFilter("all")
end

Test.it("narrows the table one column at a time", function()
    resetColumnState()
    local rows = {
        columnRow("Engineering", { recipeKey = -1, requiredSkill = 300, sourceKind = "trainer" }),
        columnRow("Engineering", { recipeKey = -2, requiredSkill = 400, skillMet = false, sourceKind = "vendor" }),
        columnRow("Engineering", { recipeKey = -3, sourceKind = "vendor" }),
        columnRow("Engineering", { recipeKey = -4, requiredSkill = 350, sourceKind = "drop",
            specializationSpellId = 20222, specializationName = "Gnomish", specializationMet = false }),
    }

    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 4)

    -- Skill asks only about the number, so it stays orthogonal to status.
    ui.collectionFilters.skill = "outofreach"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 1)
    ui.collectionFilters.skill = "noskill"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 1)
    ui.collectionFilters.skill = "inreach"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 2)
    ui.collectionFilters.skill = "all"

    ui.collectionFilters.source = "vendor"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 2)
    ui.collectionFilters.source = "all"

    ui.collectionFilters.spec = "required"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 1)
    ui.collectionFilters.spec = "have"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 0)
    ui.collectionFilters.spec = "none"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 3)

    -- Whatever the columns hide, the profession header still counts the book.
    local display = ui:BuildCollectionDisplayRows(rows)
    for _, row in ipairs(display) do
        if row.rowType == "collectionGroup" then Test.eq(row.count, 4) end
    end
    resetColumnState()
end)

-- Two controls a few pixels apart that both say "status" must not be able to
-- disagree, so the header reads and writes the strip button's setting.
Test.it("gives the status column the filter the strip button already had", function()
    resetColumnState()
    Test.eq(ui:GetCollectionColumnFilter("status"), "all")

    ui:CycleCollectionColumnFilter("status")
    Test.eq(data:GetCollectionFilter(), "unlearned")
    Test.eq(ui:GetCollectionColumnFilter("status"), "unlearned")

    data:SetCollectionFilter("ready")
    Test.eq(ui:GetCollectionColumnFilter("status"), "ready")
    resetColumnState()
end)

Test.it("cycles a column filter back round to everything", function()
    resetColumnState()
    for _ = 1, 4 do ui:CycleCollectionColumnFilter("skill") end
    Test.eq(ui:GetCollectionColumnFilter("skill"), "all")
    Test.eq(ui:HasCollectionColumnFilter(), false)

    ui:CycleCollectionColumnFilter("source")
    Test.eq(ui:HasCollectionColumnFilter(), true)
    ui:ClearCollectionColumnFilters()
    Test.eq(ui:HasCollectionColumnFilter(), false)
    resetColumnState()
end)

Test.it("sorts by a column, then the other way, then back to the built order", function()
    resetColumnState()
    local rows = {
        columnRow("Engineering", { recipeKey = -1, requiredSkill = 350 }),
        columnRow("Engineering", { recipeKey = -2, requiredSkill = 300 }),
        columnRow("Engineering", { recipeKey = -3, requiredSkill = 375 }),
    }

    ui:SetCollectionSort("skill")
    Test.eq(ui.collectionSortDir, "asc")
    local drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    Test.eq(drawn[1].collection.requiredSkill, 300)
    Test.eq(drawn[3].collection.requiredSkill, 375)

    ui:SetCollectionSort("skill")
    Test.eq(ui.collectionSortDir, "desc")
    drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    Test.eq(drawn[1].collection.requiredSkill, 375)

    -- A third click is not a fourth sort order: it hands the list back to the
    -- order the data layer built, which is the one the view opens on.
    ui:SetCollectionSort("skill")
    Test.eq(ui.collectionSortKey, "default")
    resetColumnState()
end)

-- Names are resolved lazily by design, so sorting by them has to ask for them.
Test.it("resolves the names it needs to sort by name", function()
    resetColumnState()
    local rows = {
        columnRow("Engineering", { recipeKey = -1, label = "Zapthrottle Mote Extractor" }),
        columnRow("Engineering", { recipeKey = -2, label = "Adamantite Rifle" }),
        columnRow("Engineering", { recipeKey = -3, label = "Mechanical Yeti" }),
    }

    ui:SetCollectionSort("name")
    local drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    Test.eq(drawn[1].label, "Adamantite Rifle")
    Test.eq(drawn[3].label, "Zapthrottle Mote Extractor")
    resetColumnState()
end)

Test.it("says on the header which way it is sorted and what it is filtering", function()
    resetColumnState()
    Test.eq(ui:GetCollectionHeaderText("name", "Recipe"), "Recipe")

    ui:SetCollectionSort("name")
    Test.truthy(ui:GetCollectionHeaderText("name", "Recipe"):find("^", 1, true) ~= nil)

    ui.collectionFilters.source = "vendor"
    local text = ui:GetCollectionHeaderText("source", "Learned from")
    Test.truthy(text:find("ffffd100", 1, true) ~= nil,
        "a narrowed column says so in its colour, got: " .. text)
    -- Which filter is in force is said by the colour and by the tick in the
    -- column's menu, not by the header text: the narrowest column is 62 pixels
    -- and the value written in clipped the half that mattered.
    Test.truthy(#text < 40, "a header has to fit its column, got: " .. text)
    resetColumnState()
end)

-- Header buttons are Buttons on a pooled row shared with two other tables: one
-- left showing swallows the clicks of whatever is drawn there next.
Test.it("puts the collection header buttons away with the rest of the row", function()
    local hide = bodyOf("function UI:HideCollectionRowParts(")
    Test.truthy(hide ~= nil)
    Test.truthy(hide:find("SetCollectionHeaderButtonsVisible", 1, true) ~= nil,
        "the shared reset must hide the header buttons too")
    local prepare = bodyOf("local function prepareCollectionRow(")
    Test.truthy(prepare:find("SetCollectionHeaderButtonsVisible(row, false)", 1, true) ~= nil,
        "every collection row starts without them")
    local header = bodyOf("function UI:BindCollectionHeaderRow(")
    Test.truthy(header:find("SetCollectionHeaderButtonsVisible(row, true)", 1, true) ~= nil,
        "only the header row shows them")
end)

-- The recipe browser's search box has always been the top-left control. The
-- two full-width tables pinned theirs to the opposite edge, on top of a button.
Test.it("puts every search box on the left of its strip", function()
    for _, name in ipairs({ "collectionSearchBox", "addonStatusSearchBox" }) do
        local at = mainFrameSource:find(name .. ':SetPoint%("LEFT"')
        Test.truthy(at ~= nil, name .. " must be anchored to the left of its strip")
    end
    for _, name in ipairs({ "collectionSearchLabel", "addonStatusSearchLabel" }) do
        local at = mainFrameSource:find(name .. ':SetPoint%("LEFT"')
        Test.truthy(at ~= nil, name .. " must sit beside its box on the left")
    end
end)

-- Three states, and the fourth combination is an empty browser.
Test.it("never lets the expansion filter show nothing", function()
    ui.frame = nil
    local filters = addon.RecipeUiFilters
    Test.truthy(filters ~= nil)
    Test.eq(filters:SetExpansionDefaults(false, false), false)

    for _, key in ipairs({ "all", "tbc", "vanilla" }) do
        ui:SetExpansionFilter(key)
        local vanilla, tbc = filters:GetExpansionDefaults()
        Test.truthy(vanilla or tbc, "at least one expansion has to stay visible")
        Test.eq(ui:GetExpansionFilterState().key, key)
    end

    filters:SetExpansionDefaults(false, true)
end)

-- A per-profession override outranks the global pair, which is what made the
-- in-window control look broken: "TBC only" left every Vanilla recipe of an
-- overridden profession in the list. The control has to mean what it says.
Test.it("puts an overriding profession back in step when an expansion is chosen", function()
    ui.frame = nil
    local filters = addon.RecipeUiFilters
    local prefilters = addon.db.profile.recipePrefilters
    prefilters.professionExpansionOverrides = {
        engineering = { inherit = false, vanilla = true, tbc = true },
    }
    -- While one disagrees, the control refuses to report a state the list does
    -- not obey.
    Test.eq(ui:GetExpansionFilterState().key, "mixed")

    ui:SetExpansionFilter("tbc")
    Test.eq(next(prefilters.professionExpansionOverrides), nil)
    Test.eq(ui:GetExpansionFilterState().key, "tbc")
    local visibility = filters:GetEffectiveExpansionVisibility("engineering")
    Test.eq(visibility.vanilla, false)
end)

Test.it("toggles the profit filter from the browser, not only the options panel", function()
    local filters = addon.RecipeUiFilters
    Test.eq(ui:IsProfitableOnly(), false)
    ui:ToggleProfitableOnly()
    Test.eq(filters:IsProfitableOnly(), true)
    ui:ToggleProfitableOnly()
    Test.eq(ui:IsProfitableOnly(), false)
end)

-- Difficulty is not something this addon gets to invent. The game colours a
-- recipe against four thresholds the recipe itself carries, every recipe guide
-- ships those four numbers, and TradeSkillTypeColor is Blizzard's own colour
-- table. The generator now reads the four off the source; this checks the
-- column uses them rather than guessing from the skill requirement.
local function levelledSkill(levels, required, rank)
    return ui:CollectionSkillText({
        requiredSkill = required,
        skillRank = rank,
        skillLevels = levels,
    }, false):sub(1, 10)
end

Test.it("colours a recipe against its own four thresholds", function()
    -- Orange 300-324, yellow 325-339, green 340-354, grey from 355.
    local levels = { 300, 325, 340, 355 }
    Test.eq(levelledSkill(levels, 300, 300), ORANGE)
    Test.eq(levelledSkill(levels, 300, 324), ORANGE)
    Test.eq(levelledSkill(levels, 300, 325), YELLOW)
    Test.eq(levelledSkill(levels, 300, 339), YELLOW)
    Test.eq(levelledSkill(levels, 300, 340), GREEN)
    Test.eq(levelledSkill(levels, 300, 354), GREEN)
    Test.eq(levelledSkill(levels, 300, 355), GREY)
    Test.eq(levelledSkill(levels, 300, 375), GREY)
end)

-- The whole point of reading the real numbers: the spread is per recipe, so
-- two recipes with the same requirement can be different colours at the same
-- skill, and no approximation from the requirement can produce that.
Test.it("lets two recipes of the same requirement differ in colour", function()
    local tight = { 300, 305, 310, 315 }
    local wide = { 300, 330, 350, 370 }
    Test.eq(levelledSkill(tight, 300, 320), GREY)
    Test.eq(levelledSkill(wide, 300, 320), ORANGE)
end)

-- 59 of the 2151 records state no ladder, and they still need a colour.
Test.it("falls back to the spacing only when the recipe states no ladder", function()
    Test.eq(levelledSkill(nil, 335, 375), GREY)
    Test.eq(levelledSkill({ 335 }, 335, 375), GREY)
end)

Test.it("still refuses to colour a recipe it cannot learn as a trade colour", function()
    Test.eq(levelledSkill({ 380, 390, 400, 410 }, 380, 375), RED)
end)

-- Faction belongs to the vendor, not to the recipe: the pair of vendors that
-- makes a recipe available to both sides is exactly the case a recipe-level
-- banner cannot describe.
Test.it("hangs the faction banner on the line whose NPC it belongs to", function()
    local text = ui:CollectionSourceText({
        sourceKind = "vendor",
        sourceLines = {
            "Vendor: Pratt McGrubben (Feralas)",
            "Vendor: Jangdor Swiftstrider (Feralas)",
        },
        sourceLineInfo = {
            { name = "Pratt McGrubben", faction = "alliance", x = 30.6, y = 42.7 },
            { name = "Jangdor Swiftstrider", faction = "horde", x = 74.5, y = 42.9 },
        },
    }, false)

    local first, second = text:match("^(.-)\n(.*)$")
    Test.truthy(first ~= nil, "two vendors are two lines")
    Test.truthy(first:find("BannerPVP_02", 1, true) ~= nil, "the Alliance vendor carries the Alliance banner")
    Test.truthy(second:find("BannerPVP_01", 1, true) ~= nil, "the Horde vendor carries the Horde banner")
end)

Test.it("keeps the recipe-level banner when no line claims one", function()
    local text = ui:CollectionSourceText({
        sourceKind = "quest",
        faction = "horde",
        sourceLines = { "Quest in Durotar" },
    }, false)
    Test.truthy(text:find("BannerPVP_01", 1, true) ~= nil)
end)

Test.it("puts the map position in the tooltip, where there is room for it", function()
    local lines = {}
    _G.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function() end,
        AddLine = function(_, text) lines[#lines + 1] = tostring(text) end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = tostring(left) .. "|" .. tostring(right) end,
        Show = function() end,
        Hide = function() end,
    }

    ui:ShowCollectionRowTooltip({
        collectionLabel = "Plans: Something",
        collectionInfo = {
            professionName = "Blacksmithing",
            sourceKind = "vendor",
            sourceLines = { "Vendor: Kendor Kabonka (Stormwind City)" },
            sourceLineInfo = { { name = "Kendor Kabonka", x = 77.5, y = 53.5, faction = "alliance" } },
        },
    })

    local joined = table.concat(lines, "\n")
    Test.truthy(joined:find("77.5, 53.5", 1, true) ~= nil, "got: " .. joined)
end)

-- The data behind all of the above: without it the column is back to guessing.
Test.it("ships the four thresholds and the per-NPC places in the metadata", function()
    local metadata = addon.RecipeMetadata
    Test.truthy(metadata ~= nil)
    Test.truthy(metadata.GetSkillLevels ~= nil, "the reader must expose the ladder")

    local generated = _G.RecipeRegistryRecipeMetadata
    Test.truthy(generated ~= nil, "the generated payload should be loaded")
    local withLevels, withCoords, total = 0, 0, 0
    for _, record in pairs(generated.recipesBySpellId or {}) do
        total = total + 1
        if type(record.skillLevels) == "table" and #record.skillLevels == 4 then
            withLevels = withLevels + 1
        end
        for _, place in ipairs(record.sourcePlaces or {}) do
            if place.x and place.y then
                withCoords = withCoords + 1
                break
            end
        end
    end
    Test.gte(total, 2000)
    -- Nearly all of them; the handful without are what the fallback is for.
    Test.gte(withLevels, math.floor(total * 0.9))
    Test.gte(withCoords, 500)
end)

-- A header with a warmer background and a taller row was still reading as one
-- more row in a list of four hundred. Indenting what belongs to it is what a
-- list does instead.
Test.it("indents the recipes under the profession they belong to", function()
    local parts = bodyOf("function UI:EnsureCollectionRowParts(")
    Test.truthy(parts ~= nil)
    Test.truthy(parts:find('row.collectionSectionTitle:SetPoint("LEFT", 10, 0)', 1, true) ~= nil,
        "the profession header keeps the left margin")
    local prepare = bodyOf("local function prepareCollectionRow(")
    Test.truthy(prepare:find("COLLECTION_GROUP_INDENT", 1, true) ~= nil,
        "a recipe row starts further in than its header")
    Test.truthy(mainFrameSource:find("local COLLECTION_NAME_INSET = 40 + COLLECTION_GROUP_INDENT", 1, true) ~= nil,
        "the name column moves with the icon, or the two come apart")
end)

-- Three figures a reader compares -- what it costs, what it sells for, what is
-- left -- used to start at three different x positions, in two headed blocks,
-- with the price provenance repeated in the middle of them.
Test.it("gives the money block a column of its own to line up in", function()
    local ensure = bodyOf("function UI:EnsureDetailLine(")
    Test.truthy(ensure ~= nil)
    Test.truthy(ensure:find("line.value", 1, true) ~= nil, "a detail line needs a value column")
    Test.truthy(ensure:find('line.value:SetJustifyH("RIGHT")', 1, true) ~= nil,
        "money lines up on its units, so the column is right-justified")

    local render = bodyOf("function UI:RenderDetailLines(")
    Test.truthy(render:find("meta.value", 1, true) ~= nil,
        "the renderer has to be told which lines carry a figure")
    -- The Ask button and the value column both want the right-hand end of the
    -- line, so exactly one of them can be showing.
    Test.truthy(render:find("setShownIfChanged(line.value, false)", 1, true) ~= nil,
        "a crafter line must put the value column away")

    Test.eq(mainFrameSource:find("Cost estimate", 1, true), nil,
        "cost, value and profit are one block now")
    Test.truthy(mainFrameSource:find("Cost and profit", 1, true) ~= nil)
end)

-- Seven sections in one eleven-hundred-pixel column put the sync sliders below
-- the fold on most resolutions.
Test.it("splits the options panel into pages", function()
    local handle = assert(io.open("UI/Options.lua", "r"))
    local optionsSource = handle:read("*a")
    handle:close()

    for _, page in ipairs({ "browsing", "filters", "interface", "sync", "tools" }) do
        Test.truthy(optionsSource:find('key = "' .. page .. '"', 1, true) ~= nil,
            "expected an options page for " .. page)
    end
    -- Every section header now opens a page rather than continuing a column.
    Test.eq(optionsSource:find('createHeader(content,', 1, true), nil,
        "no section may still be anchored to the one before it across pages")
    Test.truthy(optionsSource:find("createPageHeader(pageFilters", 1, true) ~= nil)
    Test.truthy(optionsSource:find("createPageHeader(pageSync", 1, true) ~= nil)
end)

-- A third of the Skill column read as a dash: SkillLineAbility does not carry
-- a required skill for a trainer-taught recipe, and the primary snapshot is
-- the only place the pipeline was looking. The obtain-side source states the
-- number on the same line the difficulty ladder comes from.
Test.it("knows the skill a recipe takes for all but a handful", function()
    local generated = _G.RecipeRegistryRecipeMetadata
    Test.truthy(generated ~= nil)
    local total, missing = 0, 0
    for _, record in pairs(generated.recipesBySpellId or {}) do
        total = total + 1
        if record.requiredSkill == nil then missing = missing + 1 end
    end
    Test.gte(total, 2000)
    Test.lte(missing, 40)
end)

-- Guards for the regressions the first in-game pass of this work turned up.
-- Every one of them was invisible to the suite as it stood, which is why they
-- reached the client.

-- The sidebar re-anchors its own profession label on every refresh. Anchoring
-- it back to the search buttons put it on top of the filter control below
-- them, and dragged the profession scroll up over that control with it.
Test.it("re-anchors the profession label below the filter control, not over it", function()
    local body = bodyOf("function UI:RefreshProfessionButtons(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("recipeFilterButton", 1, true) ~= nil,
        "the refresh has to know what sits above the profession list")
    Test.eq(body:find('profLabel:SetPoint("TOPLEFT", self.frame.searchRecipes', 1, true), nil,
        "anchoring it back to the search buttons is what buried the filter control")
end)

-- Each view has its own search box and its own text. The list was reading the
-- recipe browser's over the top of whichever view was open, so the collection's
-- box did nothing at all.
Test.it("searches with the text belonging to the view being drawn", function()
    local body = bodyOf("function UI:RefreshRecipeList(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("ActivateSearchForCurrentView", 1, true) ~= nil,
        "the list must ask the view which search text is its own")
    Test.eq(body:find("self.searchText = self.recipeSearchText", 1, true), nil,
        "one view's search text must not be written over another's")
end)

-- The sort switch lives in the corner the full-width strips take over, so
-- left showing it peered out from behind their buttons.
Test.it("keeps the sort switch out of the full-width views", function()
    local count = 0
    local at = 1
    while true do
        local found = mainFrameSource:find("setShownIfChanged(self.frame.sortSwitch, not self:IsFullWidthView())", at, true)
        if not found then break end
        count = count + 1
        at = found + 1
    end
    Test.eq(count, 2, "both list-finalise paths show it, so both have to gate it")
end)

-- A money string is one line or it is nonsense: wrapped, each coin icon ends
-- up under a number it does not belong to.
Test.it("never wraps a figure in the money column", function()
    local body = bodyOf("function UI:EnsureDetailLine(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("line.value:SetWordWrap(false)", 1, true) ~= nil,
        "the money column must not wrap")
    Test.truthy(mainFrameSource:find("local DETAIL_VALUE_WIDTH = 132", 1, true) ~= nil,
        "and it must be wide enough for gold, silver and copper with their icons")
end)

-- WoW's fonts carry Latin-1 and little else. The earlier sweep for this used a
-- grep that silently did nothing, so em dashes and bullets shipped in header
-- subtitles and chat prints. This one reads the bytes.
Test.it("keeps every string the player can see inside ASCII", function()
    local offenders = {}
    for _, path in ipairs({ "UI/MainFrame.lua", "UI/Options.lua", "UI/Tooltip.lua", "Core/Core.lua" }) do
        local handle = assert(io.open(path, "r"))
        local lineNumber = 0
        for line in handle:lines() do
            lineNumber = lineNumber + 1
            -- Comments are never drawn, so they may say what they like.
            if not line:match("^%s*%-%-") then
                for index = 1, #line do
                    if line:byte(index) > 127 then
                        offenders[#offenders + 1] = path .. ":" .. lineNumber
                        break
                    end
                end
            end
        end
        handle:close()
    end
    Test.eq(#offenders, 0, "non-ASCII in a drawn string: " .. table.concat(offenders, ", "))
end)

-- Filters were one card button per axis and they multiplied: three in the
-- collection strip, two more in the sidebar.
Test.it("gives each view one filter control, not one per axis", function()
    for _, name in ipairs({
        "collectionExpansionButton", "collectionResetButton", "expansionButton", "profitButton",
    }) do
        Test.eq(mainFrameSource:find("f." .. name .. " =", 1, true), nil,
            name .. " should have been folded into the one filter menu")
    end
    Test.truthy(bodyOf("function UI:OpenCollectionFilterMenu(") ~= nil)
    Test.truthy(bodyOf("function UI:OpenRecipeFilterMenu(") ~= nil)
    Test.truthy(bodyOf("function UI:OpenDropdown(") ~= nil)
end)

-- The auction house cut is not an interface preference and the profit filter
-- is not a filing preference.
Test.it("files the money settings under money", function()
    local handle = assert(io.open("UI/Options.lua", "r"))
    local optionsSource = handle:read("*a")
    handle:close()

    Test.truthy(optionsSource:find('key = "economy"', 1, true) ~= nil,
        "the panel needs somewhere for the money settings to live")
    Test.truthy(optionsSource:find("createCheck(pageEconomy, \"Subtract the 5%", 1, true) ~= nil,
        "the auction house cut belongs there, not next to the minimap switch")
    Test.truthy(optionsSource:find("createButton(pageEconomy, \"Price Providers Status\"", 1, true) ~= nil,
        "so does where the prices come from")
    -- A passing question is not a setting: it left the panel for the browser.
    Test.eq(optionsSource:find("profitableOnlyCheck", 1, true), nil,
        "the profit filter is a filter control now, not an option")
end)

-- The files the game actually loads, in the TOC's own order, so a new file is
-- guarded the day it is added rather than the day somebody remembers to list
-- it here. The libraries are somebody else's code.
local function loadedSourcePaths()
    local paths = {}
    local handle = assert(io.open("RecipeRegistry.toc", "r"))
    for line in handle:lines() do
        local entry = line:match("^([^#%s][^%s]*%.lua)%s*$")
        if entry and not entry:match("^Libs") then
            paths[#paths + 1] = (entry:gsub("\\", "/"))
        end
    end
    handle:close()
    Test.gte(#paths, 20, "the TOC should list the whole addon")
    return paths
end

-- A menu is anchored to the control that opened it, and that control is
-- hidden with its view. Left open, it floated over the tab you had just
-- switched to, still writing the settings of the one you left.
Test.it("takes the open menu away with the view it belongs to", function()
    local body = bodyOf("function UI:SetMainView(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("self:CloseDropdown()", 1, true) ~= nil,
        "switching tabs has to close whatever menu is open")
    Test.truthy(bodyOf("function UI:CloseDropdown(") ~= nil)
end)

-- Which expansions to list is a question about a profession's whole book, so
-- it is asked in the tab that lists one. The browser answers it with the
-- banner over the list, against the profession actually being looked at.
Test.it("asks about expansions in the collection and about prices in the browser", function()
    local browser = bodyOf("function UI:OpenRecipeFilterMenu(")
    Test.truthy(browser ~= nil)
    Test.eq(browser:find("BuildExpansionMenuItems", 1, true), nil,
        "the expansion filter left the sidebar")
    Test.truthy(browser:find("Profitable crafts only", 1, true) ~= nil,
        "and the price filter is what stayed")

    local collection = bodyOf("function UI:OpenCollectionFilterMenu(")
    Test.truthy(collection ~= nil)
    Test.truthy(collection:find("BuildExpansionMenuItems", 1, true) ~= nil,
        "which is where the expansion filter went")

    -- The warning about a profession set on its own has to travel with the
    -- control: it is the only thing that explains a list that looks wrong.
    Test.truthy(bodyOf("function UI:ShowCollectionFilterTooltip(") ~= nil)
    Test.eq(mainFrameSource:find("function UI:ShowExpansionFilterTooltip(", 1, true), nil,
        "one tooltip for two controls made sense only while both carried expansions")
end)

Test.it("says which way the browser's one filter is set", function()
    local body = bodyOf("function UI:RefreshFilterControls(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("Profitable crafts only", 1, true) ~= nil)
    Test.truthy(body:find("Every craft", 1, true) ~= nil)
    Test.eq(body:find("GetExpansionFilterState", 1, true), nil,
        "the sidebar control no longer carries the expansion axis")
end)

-- A title is the only menu item that can be a sentence, and a FontString with
-- no width does not stop at the frame edge: the note about professions set on
-- their own ran clean out of the menu.
Test.it("keeps a menu title inside the menu", function()
    local body = bodyOf("function UI:OpenDropdown(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("label:SetWidth(width - 16)", 1, true) ~= nil,
        "a title has to be bounded by the width the popup is about to get")
    Test.truthy(body:find("label:SetWordWrap(true)", 1, true) ~= nil,
        "and it has to wrap rather than run on")
    Test.truthy(body:find("label:GetStringHeight()", 1, true) ~= nil,
        "and the row has to grow to however many lines that takes")
end)

-- The X beside the collection's search box wiped the browser's text and left
-- the collection's where it was. Three boxes, three cases: the two-way branch
-- is the same one that made the collection's box do nothing at all.
Test.it("clears the search box belonging to the view being drawn", function()
    local body = bodyOf("function UI:ClearSearch(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("IsCollectionView", 1, true) ~= nil,
        "the collection has its own search text and the clear button has to name it")
    Test.truthy(body:find("self.collectionSearchText = \"\"", 1, true) ~= nil)

    local focus = bodyOf("function UI:ClearSearchFocus(")
    Test.truthy(focus ~= nil)
    Test.truthy(focus:find("collectionSearchBox", 1, true) ~= nil,
        "and the box it belongs to has to give up focus with it")
end)

-- A window nothing can be raised above is a window that is always in the way.
-- MEDIUM is where the game's own panels live; Toplevel is the mechanism by
-- which whichever window you clicked last comes to the front.
Test.it("lets another window come in front of this one", function()
    local body = bodyOf("function UI:CreateMainFrame(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find('f:SetFrameStrata("MEDIUM")', 1, true) ~= nil,
        "HIGH put the window above the bags and every other panel, always")
    Test.truthy(body:find("f:SetToplevel(true)", 1, true) ~= nil,
        "and without Toplevel nothing in its own strata can be raised over it")
end)

-- A phase is a release date, not a property of the recipe, so most of the book
-- has none: the column says something only when the answer is "not yet".
Test.it("narrows the table to a content phase", function()
    resetColumnState()
    local rows = {
        columnRow("Engineering", { recipeKey = -1 }),
        columnRow("Engineering", { recipeKey = -2, phase = 3 }),
        columnRow("Engineering", { recipeKey = -3, phase = 5 }),
        columnRow("Engineering", { recipeKey = -4, phase = 5 }),
    }
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 4)

    ui.collectionFilters.phase = "base"
    local drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    Test.eq(#drawn, 1, "only what was there from the start")
    Test.eq(drawn[1].recipeKey, -1)

    ui.collectionFilters.phase = "later"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 3,
        "everything that arrived after launch, whichever phase")

    ui.collectionFilters.phase = "p5"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 2)

    ui.collectionFilters.phase = "p2"
    Test.eq(#drawnRows(ui:BuildCollectionDisplayRows(rows)), 0,
        "a phase nothing in the list belongs to empties it rather than ignoring it")

    ui:ClearCollectionColumnFilters()
    Test.eq(ui:GetCollectionColumnFilter("phase"), "all",
        "and the one clear button has to know about the new column")
end)

Test.it("sorts the phase column with base content first", function()
    resetColumnState()
    local rows = {
        columnRow("Engineering", { recipeKey = -1, phase = 5 }),
        columnRow("Engineering", { recipeKey = -2 }),
        columnRow("Engineering", { recipeKey = -3, phase = 3 }),
    }

    ui:SetCollectionSort("phase")
    local drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    -- Absent is 1: it is the phase base content would carry if the field were
    -- written, and it belongs at the near end of the ladder, not off it.
    Test.eq(drawn[1].recipeKey, -2)
    Test.eq(drawn[2].collection.phase, 3)
    Test.eq(drawn[3].collection.phase, 5)

    ui:SetCollectionSort("phase")
    drawn = drawnRows(ui:BuildCollectionDisplayRows(rows))
    Test.eq(drawn[1].collection.phase, 5)
end)

Test.it("writes the phase only when it is not from the start", function()
    Test.truthy(mainFrameSource:find("local COLLECTION_PHASE_TEXT", 1, true) ~= nil)
    local body = bodyOf("function UI:BindCollectionRow(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("COLLECTION_PHASE_TEXT[collection.phase or 0]", 1, true) ~= nil,
        "the row reads the phase off the collection record")
    Test.truthy(body:find('setTextIfChanged(row.collectionPhase, "")', 1, true) ~= nil,
        "and base content leaves the column empty rather than writing a 1")
end)

-- A column of prices had its coin icons landing at four different x
-- positions: a zero silver was dropped entirely and a single-digit copper
-- shifted everything after it.
Test.it("pads money so the coins line up down a column", function()
    local body = bodyOf("local function formatMoney(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find('string.format("%02d %s", s, silverIcon)', 1, true) ~= nil,
        "silver is written once gold is there, padded")
    Test.truthy(body:find('string.format("%02d %s", c, copperIcon)', 1, true) ~= nil,
        "and so is copper")
    -- The smallest denomination present still leads without a pad: "5 c",
    -- not "05 c".
    Test.truthy(body:find('string.format("%d %s", c, copperIcon)', 1, true) ~= nil)
end)

-- The panel is as wide as the window allows, and a price pinned to its right
-- edge ended up half a screen from the reagent it belonged to.
Test.it("keeps the money column beside its label, not at the window edge", function()
    Test.truthy(mainFrameSource:find("local DETAIL_MAX_MEASURE = 560", 1, true) ~= nil)
    local body = bodyOf("function UI:RenderDetailLines(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("local slack = math.max(0, lineWidth - DETAIL_MAX_MEASURE)", 1, true) ~= nil)
    Test.truthy(body:find('line.value:SetPoint("TOPRIGHT", -(4 + slack), 0)', 1, true) ~= nil,
        "the value column moves in by the slack")
    Test.truthy(body:find("DETAIL_VALUE_WIDTH + 12 + slack", 1, true) ~= nil,
        "and the text column stops where it starts")
end)

-- The browser row is 70 pixels and holds three lines. Stacking the crafter
-- count above the online count made stats two lines by itself, which pushed
-- the profession out through the bottom border -- visible in a global search,
-- which is the only view that writes the profession.
Test.it("keeps a browser row inside its own border", function()
    local body = bodyOf("function UI:BindRecipeRow(")
        or bodyOf("function UI:BindRecipeListRow(")
        or mainFrameSource
    Test.eq(body:find('table.concat(statsParts, "\\n")', 1, true), nil,
        "a stacked stats block is a second line the row has no room for")
    Test.truthy(mainFrameSource:find('table.concat(statsParts, "  -  ")', 1, true) ~= nil)
end)

-- The same number in two tabs must not be two different colours, and the
-- banner belongs to the line whose NPC it is.
Test.it("colours the detail panel's skill line the way the table does", function()
    Test.truthy(bodyOf("local function skillRequirementColour(") ~= nil)
    local collection = bodyOf("function UI:CollectionSkillText(")
    Test.truthy(collection:find("skillRequirementColour(", 1, true) ~= nil,
        "the column reads the shared rule rather than its own copy")

    -- Colour codes do not nest: an inner |r would end the outer grey and drop
    -- the rest of the line back to white.
    Test.truthy(mainFrameSource:find('"|cff8f949cRequires|r " .. table.concat(requirements', 1, true) ~= nil,
        "the line is built in segments, not wrapped in one colour")
    Test.eq(mainFrameSource:find('"|cff8f949cRequires %s|r"', 1, true), nil)
end)

Test.it("hangs the faction banner on the place it belongs to in the detail panel", function()
    Test.truthy(mainFrameSource:find("local lineInfo = source.lineInfo", 1, true) ~= nil,
        "the detail panel has the same per-place information the tooltip uses")
    Test.truthy(mainFrameSource:find("ALLIANCE_INLINE_TAG", 1, true) ~= nil)
    Test.truthy(mainFrameSource:find("HORDE_INLINE_TAG", 1, true) ~= nil)
end)

-- The unit price used to sit on a second line of its own, which put the
-- multiplier and the number it multiplies an inch apart, and doubled the
-- height of the materials block.
Test.it("writes a reagent, its multiplier and its unit price on one line", function()
    Test.truthy(mainFrameSource:find('text .. string.format("   |cff6f7480%s each|r", formatMoney(reagent.unitCost))', 1, true) ~= nil,
        "the unit price joins the name line rather than starting a new one")
    Test.eq(mainFrameSource:find('lines[#lines + 1] = string.format("|cff6f7480   %s each|r"', 1, true), nil,
        "and no longer costs the block a line per reagent")
end)

-- A price watched at a merchant is fixed and repeatable; an auction price is
-- one snapshot of a market. Worth saying which the figure is.
Test.it("marks a price that came from a merchant", function()
    Test.truthy(mainFrameSource:find('reagent.unitCostSource == "Vendor"', 1, true) ~= nil)
    Test.truthy(mainFrameSource:find('"   |cff7f9f6fvendor|r"', 1, true) ~= nil)
end)

-- The last number in a texture escape is a vertical offset, and -5 sank the
-- coins well below the digits they belong to.
Test.it("sits the coin icons on the same line as their numbers", function()
    local body = bodyOf("local function formatMoney(")
    Test.truthy(body ~= nil)
    Test.eq(body:find("UI-GoldIcon:12:12:0:-5", 1, true), nil)
    Test.truthy(body:find("UI-GoldIcon:12:12:0:-1", 1, true) ~= nil)
    Test.truthy(body:find("UI-CopperIcon:12:12:0:-1", 1, true) ~= nil)
end)

-- "No price data" covered two different states, and read as though the addon
-- knew nothing about a craft it had costed to the silver.
Test.it("tells a partial price apart from no price at all", function()
    Test.truthy(mainFrameSource:find('rowData.visibilityReason == "visible-partial-price"', 1, true) ~= nil)
    Test.truthy(mainFrameSource:find('"|cff8f949cbest case|r"', 1, true) ~= nil,
        "one missing reagent makes the figure a ceiling, not an unknown")
    Test.truthy(mainFrameSource:find('"|cff8f949cno price data|r"', 1, true) ~= nil,
        "and the old label is kept for the case it actually describes")
end)

-- Closing the auction house is not the only moment the numbers change: a scan
-- rewrites the provider's database while the window is still open.
Test.it("follows an auction scan, not only the window closing", function()
    local handle = assert(io.open("Integrations/Market.lua", "r"))
    local market = handle:read("*a")
    handle:close()
    -- RegisterEvent THROWS on a name the client does not know, and that
    -- aborts the rest of OnEnable: REPLICATE_ITEM_LIST_UPDATE does not exist
    -- in 2.5.x, and registering it above MERCHANT_SHOW took the merchant scan
    -- down with it. Anything optional goes through the guarded call, and the
    -- events the addon cannot work without are registered first.
    local enable = market:match("function Market:OnEnable%(%)(.-)\nend")
    Test.truthy(enable ~= nil)
    Test.eq(enable:find("REPLICATE_ITEM_LIST_UPDATE", 1, true), nil,
        "an event this client does not have must not be registered")
    Test.truthy(enable:find('RegisterOptionalEvent("AUCTION_ITEM_LIST_UPDATE"', 1, true) ~= nil)
    Test.truthy(market:find("local ok = pcall(self.RegisterEvent, self, event, handler)", 1, true) ~= nil)
    Test.truthy(enable:find('RegisterEvent("MERCHANT_SHOW"', 1, true)
        < enable:find("RegisterOptionalEvent(", 1, true),
        "the scan the addon needs is registered before anything that may throw")
    -- Debounced rather than throttled: the panel is often open at the auction
    -- house, and a throttle would churn it under the reader for the whole scan.
    Test.truthy(market:find("AUCTION_SETTLE_DELAY", 1, true) ~= nil)
    Test.truthy(market:find("function Market:OnAuctionScanSettled(", 1, true) ~= nil)
    -- A price refresh must cost what a price refresh costs: the "metadata"
    -- scope also drops the ownership index, which is a full member walk to
    -- rebuild and has nothing to do with what anything costs.
    Test.truthy(market:find('InvalidateRecipeCaches("prices")', 1, true) ~= nil)
    Test.eq(market:find('InvalidateRecipeCaches("metadata")', 1, true), nil)
    -- And an empty cache holds nothing stale, so the events after the first
    -- one cost a table lookup instead of a rebuild.
    Test.truthy(market:find("if not next(self.priceCache or {})", 1, true) ~= nil)
end)

-- Linking a craft used to mean selecting the row, then reaching for the item
-- at the top of the details panel. The row itself is where the cursor already
-- is, and the auction house search field is the reason to want it.
Test.it("links the craft from the list row itself", function()
    for _, fn in ipairs({ "function UI:BindRecipeRow(", "function UI:BindCollectionRow(" }) do
        local body = bodyOf(fn)
        Test.truthy(body ~= nil, fn)
        for _, field in ipairs({ "linkCreatedItemID", "linkRecipeItemID", "linkSpellID" }) do
            Test.truthy(body:find("row." .. field .. " = detail.", 1, true) ~= nil,
                fn .. " has to carry " .. field)
        end
    end
    Test.truthy(mainFrameSource:find("insertLinkInChat(recipeLinkFor(", 1, true) ~= nil)
end)

-- An enchant creates no item, and one learned from a trainer has no pattern
-- either -- so a shift-click on it used to hand over nothing at all. The spell
-- is not a consolation prize there: for an enchant the spell IS the recipe.
Test.it("falls back to the spell for a recipe that makes no item", function()
    local body = bodyOf("local function recipeLinkFor(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("getItemLinkByID(createdItemID)", 1, true) ~= nil)
    Test.truthy(body:find("getItemLinkByID(recipeItemID)", 1, true) ~= nil)
    Test.truthy(body:find("GetSpellLink(spellID)", 1, true) ~= nil)
    -- Order matters: what an auction house search wants is the thing being
    -- bought, which is the output before the formula on the shelf.
    Test.truthy(body:find("createdItemID", 1, true) < body:find("recipeItemID", 1, true))
    Test.truthy(body:find("recipeItemID", 1, true) < body:find("spellID", 1, true))

    -- And the rule is stated once: the detail panel's own link button reads
    -- it rather than keeping a second copy that could drift.
    Test.truthy(mainFrameSource:find("insertLinkInChat(recipeLinkFor(detail.createdItemID", 1, true) ~= nil)
end)

-- HandleModifiedItemClick decides for itself whether a modifier is down and
-- says no when none is. ChatEdit_InsertLink does not ask, so reached on every
-- unmodified click it pasted the link into whatever chat box was open.
Test.it("keeps the chat fallback behind the modifier", function()
    local body = bodyOf("local function insertLinkInChat(")
    Test.truthy(body ~= nil)
    Test.truthy(body:find("if isChatLinkModifierDown() and type(ChatEdit_InsertLink)", 1, true) ~= nil)
    Test.truthy(bodyOf("local function isChatLinkModifierDown(") ~= nil)
end)

-- A file-level local is an upvalue only for the code written below it. A
-- function written above the declaration sees the name as a global, which is
-- nil: OpenCollectionFilterMenu read COLLECTION_FILTER_LABELS that way and
-- threw on the first click of the filter button, and CollectionSourceText read
-- COLLECTION_KNOWN_DIM that way and silently painted learned rows in the
-- source colour instead of the dim one. Lua warns about neither.
local function readsName(line, name)
    local from = 1
    while true do
        local first, last = line:find(name, from, true)
        if not first then return false end
        local before = first > 1 and line:sub(first - 1, first - 1) or ""
        local after = line:sub(last + 1, last + 1)
        -- A field or a method of the same name is somebody else's.
        if not before:match("[%w_.:]") and not after:match("[%w_]") then
            return true
        end
        from = last + 1
    end
end

Test.it("declares every file-level local above the code that reads it", function()
    local offenders = {}
    for _, path in ipairs(loadedSourcePaths()) do
        local lines = {}
        local handle = assert(io.open(path, "r"))
        for line in handle:lines() do
            -- Comments and string literals are not code; a name inside one is
            -- not a read of it.
            lines[#lines + 1] = line:gsub("%-%-.*$", ""):gsub("[\"\'][^\"\']*[\"\']", "")
        end
        handle:close()

        local declaredAt, shadowed = {}, {}
        for number, line in ipairs(lines) do
            local name = line:match("^local%s+function%s+([%a_][%w_]*)")
                or line:match("^local%s+([%a_][%w_]*)")
            if name and not declaredAt[name] then declaredAt[name] = number end
            local inner = line:match("^%s+local%s+function%s+([%a_][%w_]*)")
                or line:match("^%s+local%s+([%a_][%w_]*)")
            if inner then shadowed[inner] = true end
        end

        for name, declaration in pairs(declaredAt) do
            -- A name that is also a local inside some function cannot be told
            -- apart from that one by reading the file line by line.
            if not shadowed[name] then
                for number = 1, declaration - 1 do
                    if readsName(lines[number], name) then
                        offenders[#offenders + 1] = string.format(
                            "%s:%d reads %s, declared at :%d", path, number, name, declaration)
                        break
                    end
                end
            end
        end
    end
    Test.eq(#offenders, 0, "local read above its declaration: " .. table.concat(offenders, ", "))
end)

io.write(string.format("Collection tab view: %d test(s) passed\n", Test.count))
