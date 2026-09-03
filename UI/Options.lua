local Addon = _G.RecipeRegistry
local Options = Addon:NewModule("Options")
Addon.Options = Options

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_11"

local function getCategoryID(category)
    if type(category) ~= "table" then return nil end
    if type(category.GetID) == "function" then
        local ok, id = pcall(category.GetID, category)
        if ok and id then return id end
    end
    return category.ID or category.id
end

local function registerOptionsPanel(module, panel)
    if not panel then return false end
    if module._optionsRegistered then return true end

    if type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function" then
        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and category then
            module.settingsCategory = category
            module.settingsCategoryID = getCategoryID(category)
            if type(Settings.RegisterAddOnCategory) == "function" then
                pcall(Settings.RegisterAddOnCategory, category)
            end
            module._optionsRegistered = true
            return true
        end
    end

    if type(InterfaceOptions_AddCategory) == "function" then
        pcall(InterfaceOptions_AddCategory, panel)
        module._optionsRegistered = true
        return true
    end
    if type(InterfaceOptionsFrame_AddCategory) == "function" then
        pcall(InterfaceOptionsFrame_AddCategory, panel)
        module._optionsRegistered = true
        return true
    end
    return false
end

local TUNING_BOUNDS = {
    blockPullDelaySeconds          = { default = 2.5, min = 1.0, max = 5.0 },
    maxInboundSeedSessions         = { default = 4,   min = 1,   max = 4   },
    blockPullResponseTimeoutSeconds = { default = 60,  min = 30,  max = 120 },
}

local FILTER_PROFESSIONS = {
    { key = "alchemy",        label = "Alchemy" },
    { key = "blacksmithing",  label = "Blacksmithing" },
    { key = "enchanting",     label = "Enchanting" },
    { key = "engineering",    label = "Engineering" },
    { key = "jewelcrafting",  label = "Jewelcrafting" },
    { key = "leatherworking", label = "Leatherworking" },
    { key = "tailoring",      label = "Tailoring" },
    { key = "cooking",        label = "Cooking" },
}

local function clampTuning(field, value)
    local bounds = TUNING_BOUNDS[field]
    if not bounds then return value end
    value = tonumber(value) or bounds.default
    if value < bounds.min then return bounds.min end
    if value > bounds.max then return bounds.max end
    return value
end

local function hasMetadataPlugin()
    return type(Addon.RecipeMetadata) == "table"
end

local function ensureRecipePrefilters(profile)
    if not profile then return nil end
    if type(profile.recipePrefilters) ~= "table" then
        profile.recipePrefilters = {}
    end
    local filters = profile.recipePrefilters
    if filters.showRemoteBopOutputRecipes == nil then
        filters.showRemoteBopOutputRecipes = false
    end
    if filters.showOnlyProfitableRecipes == nil then
        filters.showOnlyProfitableRecipes = false
    end
    if type(filters.expansionDefaults) ~= "table" then
        filters.expansionDefaults = {}
    end
    if filters.expansionDefaults.vanilla == nil then
        filters.expansionDefaults.vanilla = false
    end
    if filters.expansionDefaults.tbc == nil then
        filters.expansionDefaults.tbc = true
    end
    if type(filters.professionExpansionOverrides) ~= "table" then
        filters.professionExpansionOverrides = {}
    end
    return filters
end

local function resetRecipePrefilters(profile)
    if not profile then return end
    profile.recipePrefilters = {
        showRemoteBopOutputRecipes = false,
        showOnlyProfitableRecipes = false,
        expansionDefaults = {
            -- Match DB_DEFAULTS in Data.lua — TBC-only by default. Vanilla
            -- recipes are an opt-in via the global Vanilla checkbox.
            vanilla = false,
            tbc = true,
        },
        professionExpansionOverrides = {},
    }
end

local function getProfile()
    if not (Addon.db and Addon.db.profile) then return nil end
    local profile = Addon.db.profile
    if profile.searchMode ~= "materials" then
        profile.searchMode = "recipe"
    end
    if profile.defaultSearchMode ~= "materials" then
        profile.defaultSearchMode = "recipe"
    end
    if profile.useRecipeCategories == nil then
        profile.useRecipeCategories = true
    end
    if type(profile.minimap) ~= "table" then
        profile.minimap = { hide = false, minimapPos = 220 }
    end
    if profile.minimap.hide == nil then
        profile.minimap.hide = false
    end
    if type(profile.tuning) ~= "table" then
        profile.tuning = {}
    end
    for field, bounds in pairs(TUNING_BOUNDS) do
        profile.tuning[field] = clampTuning(field, profile.tuning[field] or bounds.default)
    end
    if type(profile.mainFrame) ~= "table" then
        profile.mainFrame = {}
    end
    ensureRecipePrefilters(profile)
    return profile
end

local function setTuning(field, value)
    local profile = getProfile()
    if not profile then return end
    profile.tuning[field] = clampTuning(field, value)
end

local function createButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 180, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local SECTION_LEFT_X = 14
local function createHeader(parent, text, anchor, yOffset)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    -- Two-anchor trick: LEFT pins X to a fixed margin on the panel, TOP pins
    -- Y to the previous element's bottom. Without the LEFT anchor each
    -- header inherited the X of its anchor (which was usually an indented
    -- help-text), and the panel staircased to the right with every section.
    header:SetPoint("LEFT", parent, "LEFT", SECTION_LEFT_X, 0)
    header:SetPoint("TOP", anchor, "BOTTOM", 0, yOffset or -18)
    header:SetText(text)
    return header
end

-- A header that opens a page rather than continuing a column: the first
-- section on a page has nothing above it to hang from.
local function createPageHeader(page, text)
    local header = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", page, "TOPLEFT", SECTION_LEFT_X, -4)
    header:SetText(text)
    return header
end

local function createText(parent, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontDisableSmall")
    fs:SetWidth(560)
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

local function createCheck(parent, label, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check.text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    check.text:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.text:SetText(label or "")
    check:SetScript("OnClick", onClick)
    return check
end

local function createRadio(parent, label, onClick)
    local radio = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    radio:SetSize(24, 24)
    radio.text = radio:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    radio.text:SetPoint("LEFT", radio, "RIGHT", 4, 0)
    radio.text:SetText(label or "")
    radio:SetScript("OnClick", onClick)
    return radio
end

local function createColumnHeader(parent, text, width)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetWidth(width or 80)
    fs:SetJustifyH("CENTER")
    fs:SetText(text or "")
    return fs
end

-- The panel was one column eleven hundred pixels tall: seven unrelated
-- sections, scrolled past each other, with the sync sliders below the fold on
-- most resolutions. These are the same sections, grouped by what a person came
-- to change and put on pages, so each one is a screenful and the tab strip is
-- the table of contents.
--
-- Pages carry their own height because a WoW frame does not size itself to its
-- children; the scroll child is resized to the open page, which is also what
-- stops a short page from scrolling into empty space.
local OPTION_PAGES = {
    { key = "browsing",  label = "Browsing",  height = 300 },
    { key = "filters",   label = "Filters",   height = 560 },
    { key = "interface", label = "Interface", height = 380 },
    { key = "sync",      label = "Sync",      height = 320 },
    { key = "tools",     label = "Tools",     height = 260 },
}
local OPTION_PAGE_TOP = -96

local function createOptionPages(content, scrollFrame)
    local pages, buttons = {}, {}

    local function show(key)
        for pageKey, page in pairs(pages) do
            if pageKey == key then page:Show() else page:Hide() end
        end
        for buttonKey, button in pairs(buttons) do
            -- The open page's button is held down, which is how a Blizzard
            -- panel says "you are here" without a second widget for it.
            if button.SetButtonState then
                button:SetButtonState(buttonKey == key and "PUSHED" or "NORMAL", buttonKey == key)
            end
        end
        for _, definition in ipairs(OPTION_PAGES) do
            if definition.key == key and content.SetHeight then
                content:SetHeight(definition.height - OPTION_PAGE_TOP)
            end
        end
        if scrollFrame and scrollFrame.SetVerticalScroll then
            scrollFrame:SetVerticalScroll(0)
        end
    end

    local previous = nil
    for _, definition in ipairs(OPTION_PAGES) do
        local page = CreateFrame("Frame", nil, content)
        page:SetPoint("TOPLEFT", content, "TOPLEFT", 0, OPTION_PAGE_TOP)
        page:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, OPTION_PAGE_TOP)
        page:SetHeight(definition.height)
        page:Hide()
        pages[definition.key] = page

        local button = createButton(content, definition.label, 96, function()
            show(definition.key)
        end)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", content, "TOPLEFT", SECTION_LEFT_X, -64)
        end
        buttons[definition.key] = button
        previous = button
    end

    show(OPTION_PAGES[1].key)
    return pages, buttons, show
end

local function setHoverTooltip(frame, title, body)
    if not frame then return end
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if title then GameTooltip:AddLine(title) end
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function setCheckEnabled(check, enabled)
    if not check then return end
    if enabled then
        check:Enable()
        check:SetAlpha(1.0)
    else
        check:Disable()
        check:SetAlpha(0.4)
    end
end

local SLIDER_BACKDROP = {
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile     = true,
    tileSize = 8,
    edgeSize = 8,
    insets   = { left = 3, right = 3, top = 6, bottom = 6 },
}

local _sliderCounter = 0
local function createSlider(parent, label, low, high, step, valueFormat, onValueChanged)
    _sliderCounter = _sliderCounter + 1
    local name = "RecipeRegistryOptionsSlider" .. _sliderCounter
    -- TBC Classic 2.5.x ships OptionsSliderTemplate with a backdrop in
    -- XML, but on some clients the trough texture doesn't render unless
    -- the frame also pulls in BackdropTemplate. We try the combined
    -- template first; if the client rejects the inheritance string we
    -- fall back to the plain template and apply SetBackdrop manually so
    -- the user still sees the slider track and not just the thumb.
    local slider
    local ok, frame = pcall(CreateFrame, "Slider", name, parent, "OptionsSliderTemplate,BackdropTemplate")
    if ok and frame then
        slider = frame
    else
        slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    end
    if type(slider.SetBackdrop) == "function" then
        slider:SetBackdrop(SLIDER_BACKDROP)
    end
    slider:SetWidth(260)
    slider:SetHeight(18)
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step or 1)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end

    local fmt = valueFormat or "%s"

    -- OptionsSliderTemplate places low/high labels below the slider's
    -- bottom-left and bottom-right corners. Putting the current value to
    -- the right of the slider (the previous layout) caused it to overlap
    -- the "high" label on shorter values. Fold the current value into
    -- the title text instead — single source of truth, no collisions.
    local titleText = _G[name .. "Text"]
    local function applyTitle(value)
        if not titleText then return end
        titleText:SetText(string.format("%s: %s", label or "", string.format(fmt, value)))
    end

    local lowLabel = _G[name .. "Low"]
    if lowLabel then lowLabel:SetText(string.format(fmt, low)) end
    local highLabel = _G[name .. "High"]
    if highLabel then highLabel:SetText(string.format(fmt, high)) end

    slider.valueFormat = fmt
    slider.applyTitle = applyTitle

    function slider:SetDisplayValue(value)
        self:SetValue(value)
        applyTitle(value)
    end

    slider:SetScript("OnValueChanged", function(self, value, userInput)
        applyTitle(value)
        if userInput and onValueChanged then
            onValueChanged(value)
        end
    end)
    return slider
end

local function refreshOpenDirectory()
    if Addon.UI and Addon.UI.frame and Addon.UI.frame:IsShown() then
        Addon.UI:Refresh()
    end
end

local function invalidateRecipeFilters(professionKey, reason)
    if Addon.RecipeUiFilters and Addon.RecipeUiFilters.InvalidateProfessionProjection then
        Addon.RecipeUiFilters:InvalidateProfessionProjection(professionKey, reason)
    else
        if Addon.Data and Addon.Data.InvalidateRecipeCaches then
            Addon.Data:InvalidateRecipeCaches("list")
        end
    end
    refreshOpenDirectory()
end

-- Both of these now go through RecipeUiFilters, which is where the collection
-- strip and the recipe header write the same two settings. The panel keeps its
-- own refresh of the open directory; the module handles the cache
-- invalidation that every writer needs.
local function setFilterExpansionDefault(expansion, enabled)
    local profile = getProfile()
    if not profile then return end
    local filters = ensureRecipePrefilters(profile)
    local module = Addon.RecipeUiFilters
    if module and module.SetExpansionDefaults then
        local vanilla = filters.expansionDefaults.vanilla ~= false
        local tbc = filters.expansionDefaults.tbc ~= false
        if expansion == "vanilla" then vanilla = enabled == true else tbc = enabled == true end
        -- The panel is allowed to switch both off: it shows a warning line for
        -- exactly that state, and a checkbox that refuses to move is worse.
        if not module:SetExpansionDefaults(vanilla, tbc, "filters:global-" .. tostring(expansion)) then
            filters.expansionDefaults[expansion] = enabled == true
        end
        refreshOpenDirectory()
        return
    end
    filters.expansionDefaults[expansion] = enabled == true
    invalidateRecipeFilters(nil, "filters:global-" .. tostring(expansion))
end

local function setRemoteBopVisible(enabled)
    local profile = getProfile()
    if not profile then return end
    local filters = ensureRecipePrefilters(profile)
    filters.showRemoteBopOutputRecipes = enabled == true
    invalidateRecipeFilters(nil, "filters:remote-bop")
end

local function setProfitableOnly(enabled)
    local profile = getProfile()
    if not profile then return end
    local filters = ensureRecipePrefilters(profile)
    local module = Addon.RecipeUiFilters
    if module and module.SetProfitableOnly then
        module:SetProfitableOnly(enabled)
        refreshOpenDirectory()
        return
    end
    filters.showOnlyProfitableRecipes = enabled == true
    invalidateRecipeFilters(nil, "filters:profitable-only")
end

-- The collection tab lists every profession this character has. Some
-- people level a profession they have no intention of completing, so each
-- one can be dropped from that view without touching the recipe browser.
local function setCollectionEnabled(professionLabel, enabled)
    if Addon.Data and Addon.Data.SetCollectionEnabledForProfession then
        Addon.Data:SetCollectionEnabledForProfession(professionLabel, enabled)
    end
    if Addon.UI and Addon.UI.RefreshRecipeList then
        Addon.UI:RefreshRecipeList()
    end
end

local function createProfessionOverride(filters, professionKey)
    local overrides = filters.professionExpansionOverrides
    local override = overrides[professionKey]
    if type(override) ~= "table" then
        override = {}
        overrides[professionKey] = override
    end
    override.inherit = false
    if override.vanilla == nil then
        override.vanilla = filters.expansionDefaults.vanilla ~= false
    end
    if override.tbc == nil then
        override.tbc = filters.expansionDefaults.tbc ~= false
    end
    return override
end

local function setProfessionCustom(professionKey, custom)
    local profile = getProfile()
    if not profile then return end
    local filters = ensureRecipePrefilters(profile)
    if custom == true then
        createProfessionOverride(filters, professionKey)
    else
        filters.professionExpansionOverrides[professionKey] = nil
    end
    invalidateRecipeFilters(professionKey, "filters:" .. tostring(professionKey))
end

local function setProfessionExpansion(professionKey, expansion, enabled)
    local profile = getProfile()
    if not profile then return end
    local filters = ensureRecipePrefilters(profile)
    local override = createProfessionOverride(filters, professionKey)
    override[expansion] = enabled == true
    invalidateRecipeFilters(professionKey, "filters:" .. tostring(professionKey))
end

local function getFilterWarning(filters)
    local defaults = filters and filters.expansionDefaults or {}
    if defaults.vanilla == false and defaults.tbc == false then
        return "Warning: global filters hide every Vanilla and TBC recipe."
    end

    local overrides = filters and filters.professionExpansionOverrides or {}
    for _, profession in ipairs(FILTER_PROFESSIONS) do
        local override = overrides[profession.key]
        if type(override) == "table" and override.inherit == false
            and override.vanilla == false and override.tbc == false then
            return "Warning: one or more custom profession filters hide every Vanilla and TBC recipe."
        end
    end
    return ""
end

local function setSearchMode(mode)
    local profile = getProfile()
    if not profile then return end
    mode = mode == "materials" and "materials" or "recipe"
    profile.defaultSearchMode = mode
    profile.searchMode = mode
    if Addon.UI then
        Addon.UI.searchMode = mode
        Addon.UI.selectedRecipeKey = nil
        if Addon.UI.frame and Addon.UI.frame:IsShown() then
            Addon.UI:ApplySearchNow()
        end
    end
end

local function setRecipeCategoriesEnabled(enabled)
    local profile = getProfile()
    if not profile then return end
    profile.useRecipeCategories = enabled == true
    if Addon.UI then
        Addon.UI.selectedRecipeKey = nil
    end
    refreshOpenDirectory()
end

local function setRecipeCategoryView(viewMode)
    local profile = getProfile()
    if not profile then return end
    if viewMode ~= "accordion" and viewMode ~= "categoriesOnly" then
        viewMode = "expanded"
    end
    profile.recipeCategoryView = viewMode
    -- View mode only changes sidebar layout, not which recipes are visible,
    -- so no list/category cache invalidation is needed — just drop transient
    -- accordion state and rebuild the open directory.
    if Addon.UI then
        Addon.UI.expandedCategory = nil
    end
    refreshOpenDirectory()
end

local function setMinimapShown(shown)
    local profile = getProfile()
    if not profile then return end
    profile.minimap.hide = shown ~= true
    if Addon.MinimapButton then
        Addon.MinimapButton:Refresh()
    end
end

local function setAuctionCutSubtracted(enabled)
    local profile = getProfile()
    if not profile then return end
    profile.subtractAuctionHouseCut = enabled == true
    -- Read while building the cost block, and it also moves the profit
    -- filter's verdict, so cached lists and details have to go.
    if Addon.Market and Addon.Market.InvalidatePriceCache then
        Addon.Market:InvalidatePriceCache("auction-cut-option")
    end
end

local function setMainTabEnabled(tabKey, enabled)
    if Addon.UI and Addon.UI.SetMainTabEnabled then
        Addon.UI:SetMainTabEnabled(tabKey, enabled)
    end
end

local function setTooltipCraftersShown(shown)
    local profile = getProfile()
    if not profile then return end
    -- Read live by Tooltip:AddCraftLines on every render, so no cache or
    -- hook needs invalidating here.
    profile.showTooltipCrafters = shown == true
end

function Options:RefreshControls()
    local profile = getProfile()
    if not profile then return end
    if self.categoryCheck then
        self.categoryCheck:SetChecked(profile.useRecipeCategories ~= false)
    end
    local categoriesEnabled = profile.useRecipeCategories ~= false
    local categoryView = profile.recipeCategoryView
    if categoryView ~= "accordion" and categoryView ~= "categoriesOnly" then
        categoryView = "expanded"
    end
    if self.categoryViewExpandedRadio then
        self.categoryViewExpandedRadio:SetChecked(categoryView == "expanded")
        setCheckEnabled(self.categoryViewExpandedRadio, categoriesEnabled)
    end
    if self.categoryViewAccordionRadio then
        self.categoryViewAccordionRadio:SetChecked(categoryView == "accordion")
        setCheckEnabled(self.categoryViewAccordionRadio, categoriesEnabled)
    end
    if self.categoryViewCategoriesOnlyRadio then
        self.categoryViewCategoriesOnlyRadio:SetChecked(categoryView == "categoriesOnly")
        setCheckEnabled(self.categoryViewCategoriesOnlyRadio, categoriesEnabled)
    end
    if self.recipeSearchRadio then
        self.recipeSearchRadio:SetChecked(profile.defaultSearchMode ~= "materials")
    end
    if self.materialSearchRadio then
        self.materialSearchRadio:SetChecked(profile.defaultSearchMode == "materials")
    end
    if self.minimapCheck then
        self.minimapCheck:SetChecked(not profile.minimap.hide)
    end
    if self.tooltipCraftersCheck then
        self.tooltipCraftersCheck:SetChecked(profile.showTooltipCrafters ~= false)
    end
    if self.auctionCutCheck then
        self.auctionCutCheck:SetChecked(profile.subtractAuctionHouseCut == true)
    end
    if self.mainTabChecks and Addon.UI and Addon.UI.IsMainTabEnabled then
        for tabKey, check in pairs(self.mainTabChecks) do
            check:SetChecked(Addon.UI:IsMainTabEnabled(tabKey) ~= false)
        end
    end
    if self.scaleSlider then
        local scale = tonumber(profile.mainFrame and profile.mainFrame.scale) or 1
        self.scaleSlider:SetDisplayValue(math.floor(scale * 100 + 0.5))
    end
    if self.pullDelaySlider then
        self.pullDelaySlider:SetDisplayValue(profile.tuning.blockPullDelaySeconds)
    end
    if self.maxSeedSlider then
        self.maxSeedSlider:SetDisplayValue(profile.tuning.maxInboundSeedSessions)
    end
    if self.pullTimeoutSlider then
        self.pullTimeoutSlider:SetDisplayValue(profile.tuning.blockPullResponseTimeoutSeconds)
    end
    local filters = ensureRecipePrefilters(profile)
    if self.filterPluginHint then
        if hasMetadataPlugin() then
            local metadata = Addon.RecipeMetadata
            self.filterPluginHint:SetText("Recipe metadata loaded. Metadata version: " .. tostring(metadata and metadata.metadataVersion or "?"))
        else
            self.filterPluginHint:SetText("Recipe metadata module not loaded. Recipe filters are unavailable.")
        end
    end
    if self.globalVanillaCheck then
        self.globalVanillaCheck:SetChecked(filters.expansionDefaults.vanilla ~= false)
    end
    if self.globalTbcCheck then
        self.globalTbcCheck:SetChecked(filters.expansionDefaults.tbc ~= false)
    end
    if self.remoteBopCheck then
        self.remoteBopCheck:SetChecked(filters.showRemoteBopOutputRecipes == true)
    end
    if self.profitableOnlyCheck then
        self.profitableOnlyCheck:SetChecked(filters.showOnlyProfitableRecipes == true)
    end
    if self.professionFilterControls then
        for _, profession in ipairs(FILTER_PROFESSIONS) do
            local row = self.professionFilterControls[profession.key]
            if row then
                local override = filters.professionExpansionOverrides[profession.key]
                local custom = type(override) == "table" and override.inherit == false
                row.customCheck:SetChecked(custom)
                if row.collectionCheck then
                    local enabled = true
                    if Addon.Data and Addon.Data.IsCollectionEnabledForProfession then
                        enabled = Addon.Data:IsCollectionEnabledForProfession(row.professionLabel) ~= false
                    end
                    row.collectionCheck:SetChecked(enabled)
                end
                if custom then
                    row.vanillaCheck:SetChecked(override.vanilla ~= false)
                    row.tbcCheck:SetChecked(override.tbc ~= false)
                else
                    row.vanillaCheck:SetChecked(filters.expansionDefaults.vanilla ~= false)
                    row.tbcCheck:SetChecked(filters.expansionDefaults.tbc ~= false)
                end
                setCheckEnabled(row.vanillaCheck, custom)
                setCheckEnabled(row.tbcCheck, custom)
            end
        end
    end
    if self.filterWarning then
        self.filterWarning:SetText(getFilterWarning(filters))
    end
end

function Options:EnsurePanel()
    if self.panel then
        registerOptionsPanel(self, self.panel)
        return self.panel
    end

    local panel = CreateFrame("Frame", "RecipeRegistryOptionsPanel", InterfaceOptionsFramePanelContainer)
    panel.name = "Recipe Registry"

    -- The InterfaceOptions panel container clips its children to the
    -- visible area. With the Sync Tuning sliders + Tools buttons the
    -- content height now exceeds the visible area on some screen sizes,
    -- so the tail of the panel disappears below the bottom. Wrapping
    -- everything in a ScrollFrame lets the user scroll to reach the
    -- buttons regardless of resolution.
    local scrollFrame
    if type(CreateFrame) == "function" then
        local ok, frame = pcall(CreateFrame, "ScrollFrame", "RecipeRegistryOptionsScroll", panel, "UIPanelScrollFrameTemplate")
        if ok then scrollFrame = frame end
    end
    local content
    if scrollFrame then
        scrollFrame:SetPoint("TOPLEFT", 0, 0)
        scrollFrame:SetPoint("BOTTOMRIGHT", -28, 0)
        content = CreateFrame("Frame", nil, scrollFrame)
        -- Resized to whichever page is open; see createOptionPages.
        content:SetSize(560, 420)
        scrollFrame:SetScrollChild(content)
    else
        content = panel
    end

    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Recipe Registry")

    local icon = content:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", title, "RIGHT", 8, 0)
    icon:SetTexture(ICON_TEXTURE)

    local subtitle = createText(content, "Guild crafting directory settings", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)

    local version = createText(content, "Version: " .. tostring(Addon.DISPLAY_VERSION or "?"))
    version:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)

    local pages, pageButtons, showPage = createOptionPages(content, scrollFrame)
    self.pages = pages
    self.pageButtons = pageButtons
    self.ShowPage = function(_, key) showPage(key) end
    local pageBrowsing = pages.browsing
    local pageFilters = pages.filters
    local pageInterface = pages.interface
    local pageSync = pages.sync
    local pageTools = pages.tools

    local layoutHeader = createPageHeader(pageBrowsing, "Directory Layout")
    local categoryCheck = createCheck(pageBrowsing, "Show recipe categories when available", function(self)
        setRecipeCategoriesEnabled(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    categoryCheck:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", -2, -8)
    self.categoryCheck = categoryCheck

    local categoryHelp = createText(pageBrowsing, "When enabled, selecting a profession can expand into All plus metadata categories.")
    categoryHelp:SetPoint("TOPLEFT", categoryCheck, "BOTTOMLEFT", 28, 0)

    local categoryViewLabel = createText(pageBrowsing, "Category view", "GameFontHighlightSmall")
    categoryViewLabel:SetPoint("TOPLEFT", categoryHelp, "BOTTOMLEFT", 0, -8)

    local expandedViewRadio = createRadio(pageBrowsing, "Expanded tree (all subcategories shown)", function()
        setRecipeCategoryView("expanded")
        Options:RefreshControls()
    end)
    expandedViewRadio:SetPoint("TOPLEFT", categoryViewLabel, "BOTTOMLEFT", -2, -6)
    self.categoryViewExpandedRadio = expandedViewRadio

    local accordionViewRadio = createRadio(pageBrowsing, "Collapsible (one category expanded at a time)", function()
        setRecipeCategoryView("accordion")
        Options:RefreshControls()
    end)
    accordionViewRadio:SetPoint("TOPLEFT", expandedViewRadio, "BOTTOMLEFT", 0, -2)
    self.categoryViewAccordionRadio = accordionViewRadio

    local categoriesOnlyViewRadio = createRadio(pageBrowsing, "Categories only (hide subcategories)", function()
        setRecipeCategoryView("categoriesOnly")
        Options:RefreshControls()
    end)
    categoriesOnlyViewRadio:SetPoint("TOPLEFT", accordionViewRadio, "BOTTOMLEFT", 0, -2)
    self.categoryViewCategoriesOnlyRadio = categoriesOnlyViewRadio

    local searchHeader = createHeader(pageBrowsing, "Search Defaults", categoriesOnlyViewRadio, -18)
    local recipeSearchRadio = createRadio(pageBrowsing, "Recipe names only", function()
        setSearchMode("recipe")
        Options:RefreshControls()
    end)
    recipeSearchRadio:SetPoint("TOPLEFT", searchHeader, "BOTTOMLEFT", -2, -8)
    self.recipeSearchRadio = recipeSearchRadio

    local materialSearchRadio = createRadio(pageBrowsing, "Recipe names and materials", function()
        setSearchMode("materials")
        Options:RefreshControls()
    end)
    materialSearchRadio:SetPoint("TOPLEFT", recipeSearchRadio, "BOTTOMLEFT", 0, -2)
    self.materialSearchRadio = materialSearchRadio

    local searchHelp = createText(pageBrowsing, "This sets the default scope. The search bar can still be changed quickly while browsing.")
    searchHelp:SetPoint("TOPLEFT", materialSearchRadio, "BOTTOMLEFT", 28, 0)

    local filterHeader = createPageHeader(pageFilters, "Recipe Filters")
    local filterPluginHint = createText(pageFilters, "")
    filterPluginHint:SetPoint("TOPLEFT", filterHeader, "BOTTOMLEFT", 0, -6)
    self.filterPluginHint = filterPluginHint

    local filterAnchor = filterPluginHint
    if hasMetadataPlugin() then
        local globalVanillaCheck = createCheck(pageFilters, "Show Vanilla recipes by default", function(self)
            setFilterExpansionDefault("vanilla", self:GetChecked() and true or false)
            Options:RefreshControls()
        end)
        globalVanillaCheck:SetPoint("TOPLEFT", filterPluginHint, "BOTTOMLEFT", -2, -8)
        self.globalVanillaCheck = globalVanillaCheck

        local globalTbcCheck = createCheck(pageFilters, "Show TBC recipes by default", function(self)
            setFilterExpansionDefault("tbc", self:GetChecked() and true or false)
            Options:RefreshControls()
        end)
        globalTbcCheck:SetPoint("TOPLEFT", globalVanillaCheck, "BOTTOMLEFT", 0, -2)
        self.globalTbcCheck = globalTbcCheck

        local remoteBopCheck = createCheck(pageFilters, "Show remote BoP and self-only recipes", function(self)
            setRemoteBopVisible(self:GetChecked() and true or false)
            Options:RefreshControls()
        end)
        remoteBopCheck:SetPoint("TOPLEFT", globalTbcCheck, "BOTTOMLEFT", 0, -2)
        self.remoteBopCheck = remoteBopCheck

        -- One switch, not a filter axis: a craft is in when the created item
        -- sells for more than its reagents, and out otherwise. Recipes whose
        -- price cannot be resolved end to end are out too, which is why this
        -- is opt-in -- without TSM or Auctionator data it empties the list.
        local profitableOnlyCheck = createCheck(pageFilters, "Show only profitable recipes (needs TSM or Auctionator)", function(self)
            setProfitableOnly(self:GetChecked() and true or false)
            Options:RefreshControls()
        end)
        profitableOnlyCheck:SetPoint("TOPLEFT", remoteBopCheck, "BOTTOMLEFT", 0, -2)
        self.profitableOnlyCheck = profitableOnlyCheck

        local matrixHeader = createText(pageFilters, "Profession overrides", "GameFontNormalSmall")
        matrixHeader:SetPoint("TOPLEFT", profitableOnlyCheck, "BOTTOMLEFT", 28, -10)

        local headerProfession = createColumnHeader(pageFilters, "Profession", 132)
        headerProfession:SetJustifyH("LEFT")
        headerProfession:SetPoint("TOPLEFT", matrixHeader, "BOTTOMLEFT", 0, -8)

        local headerCustom = createColumnHeader(pageFilters, "Custom")
        headerCustom:SetPoint("CENTER", headerProfession, "LEFT", 190 + 12, 0)

        local headerVanilla = createColumnHeader(pageFilters, "Vanilla")
        headerVanilla:SetPoint("CENTER", headerProfession, "LEFT", 284 + 12, 0)

        local headerTbc = createColumnHeader(pageFilters, "TBC")
        headerTbc:SetPoint("CENTER", headerProfession, "LEFT", 372 + 12, 0)

        local headerCollection = createColumnHeader(pageFilters, "Collection")
        headerCollection:SetPoint("CENTER", headerProfession, "LEFT", 460 + 12, 0)

        local separator = pageFilters:CreateTexture(nil, "ARTWORK")
        separator:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        separator:SetHeight(1)
        separator:SetPoint("TOPLEFT", headerProfession, "BOTTOMLEFT", 0, -3)
        separator:SetPoint("RIGHT", headerCollection, "RIGHT", 20, 0)

        self.professionFilterControls = {}
        local previous = separator
        for _, profession in ipairs(FILTER_PROFESSIONS) do
            local professionKey = profession.key
            local label = createText(pageFilters, profession.label, "GameFontHighlightSmall")
            label:SetWidth(132)
            label:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)

            local customCheck = createCheck(pageFilters, "", function(self)
                setProfessionCustom(professionKey, self:GetChecked() and true or false)
                Options:RefreshControls()
            end)
            customCheck:SetPoint("CENTER", label, "LEFT", 190 + 12, 0)
            setHoverTooltip(customCheck, "Custom override",
                "When enabled, " .. profession.label .. " uses its own Vanilla/TBC visibility instead of the global defaults above.")

            local vanillaCheck = createCheck(pageFilters, "", function(self)
                setProfessionExpansion(professionKey, "vanilla", self:GetChecked() and true or false)
                Options:RefreshControls()
            end)
            vanillaCheck:SetPoint("CENTER", label, "LEFT", 284 + 12, 0)
            setHoverTooltip(vanillaCheck, "Show Vanilla recipes",
                "Enable Custom on this row to change this value; otherwise it mirrors the global Vanilla default.")

            local tbcCheck = createCheck(pageFilters, "", function(self)
                setProfessionExpansion(professionKey, "tbc", self:GetChecked() and true or false)
                Options:RefreshControls()
            end)
            tbcCheck:SetPoint("CENTER", label, "LEFT", 372 + 12, 0)
            setHoverTooltip(tbcCheck, "Show TBC recipes",
                "Enable Custom on this row to change this value; otherwise it mirrors the global TBC default.")

            local collectionCheck = createCheck(pageFilters, "", function(self)
                setCollectionEnabled(profession.label, self:GetChecked() and true or false)
                Options:RefreshControls()
            end)
            collectionCheck:SetPoint("CENTER", label, "LEFT", 460 + 12, 0)
            setHoverTooltip(collectionCheck, "List in Collection",
                "When enabled, the Collection tab lists this character's " .. profession.label .. " recipe book -- learned and not. Only professions this character actually has are ever listed.")

            self.professionFilterControls[professionKey] = {
                label = label,
                customCheck = customCheck,
                vanillaCheck = vanillaCheck,
                tbcCheck = tbcCheck,
                collectionCheck = collectionCheck,
                professionLabel = profession.label,
            }
            previous = label
        end

        local filterWarning = createText(pageFilters, "", "GameFontDisableSmall")
        filterWarning:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -10)
        self.filterWarning = filterWarning
        filterAnchor = filterWarning
    end

    -- Driven off the UI module's tab registry, so a tab added there shows up
    -- here without touching this panel.
    local tabsHeader = createPageHeader(pageInterface, "Tabs")
    local tabDefinitions = (Addon.UI and Addon.UI.GetMainTabDefinitions
        and Addon.UI:GetMainTabDefinitions()) or {}
    local previousTabCheck = nil
    self.mainTabChecks = {}
    for _, definition in ipairs(tabDefinitions) do
        if definition.optional then
            local tabKey = definition.key
            local tabCheck = createCheck(pageInterface, "Show the " .. definition.label .. " tab", function(self)
                setMainTabEnabled(tabKey, self:GetChecked() and true or false)
                Options:RefreshControls()
            end)
            if previousTabCheck then
                tabCheck:SetPoint("TOPLEFT", previousTabCheck, "BOTTOMLEFT", 0, -4)
            else
                tabCheck:SetPoint("TOPLEFT", tabsHeader, "BOTTOMLEFT", -2, -8)
            end
            setHoverTooltip(tabCheck, definition.label,
                "Hides the tab from the top of the main window. The Recipes tab is always available, so switching every other tab off still leaves somewhere to land.")
            self.mainTabChecks[tabKey] = tabCheck
            previousTabCheck = tabCheck
        end
    end

    local accessHeader = createHeader(pageInterface, "Access", previousTabCheck or tabsHeader, -18)
    local minimapCheck = createCheck(pageInterface, "Show minimap button", function(self)
        setMinimapShown(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    minimapCheck:SetPoint("TOPLEFT", accessHeader, "BOTTOMLEFT", -2, -8)
    self.minimapCheck = minimapCheck

    local tooltipCraftersCheck = createCheck(pageInterface, "Show known crafters on item and spell tooltips", function(self)
        setTooltipCraftersShown(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    tooltipCraftersCheck:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 0, -4)
    setHoverTooltip(tooltipCraftersCheck, "Tooltip crafters",
        "Adds a Recipe Registry section to item, recipe, spell, and enchant tooltips listing guildmates who can craft them. Disable for leaner tooltips.")
    self.tooltipCraftersCheck = tooltipCraftersCheck

    local auctionCutCheck = createCheck(pageInterface, "Subtract the 5% auction house cut from profit", function(self)
        setAuctionCutSubtracted(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    auctionCutCheck:SetPoint("TOPLEFT", tooltipCraftersCheck, "BOTTOMLEFT", 0, -4)
    setHoverTooltip(auctionCutCheck, "Auction house cut",
        "Off by default: the \"Sells for\" figure stays gross, which is also the price to list your auction at. Turn this on to net the 5% the auction house keeps out of the profit line and the \"only profitable\" filter.")
    self.auctionCutCheck = auctionCutCheck

    local scaleSlider = createSlider(pageInterface,
        "Main window scale",
        60, 120, 5,
        "%d%%",
        function(value)
            if Addon.UI and Addon.UI.SetFrameScale then
                Addon.UI:SetFrameScale(value / 100)
            end
        end
    )
    scaleSlider:SetPoint("TOPLEFT", auctionCutCheck, "BOTTOMLEFT", 8, -26)
    setHoverTooltip(scaleSlider, "Main window scale",
        "Shrinks or enlarges the whole Recipe Registry window. Useful on small screens; you can also drag the grip in the window's bottom-right corner to resize it.")
    self.scaleSlider = scaleSlider

    local openButton = createButton(pageInterface, "Open Recipe Registry", 180, function()
        if Addon.UI then
            Addon.UI:Toggle()
        end
    end)
    openButton:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", -6, -30)

    local tuningHeader = createPageHeader(pageSync, "Sync Tuning")
    local tuningHelp = createText(pageSync,
        "Advanced. Defaults work for most setups; lower the pull delay only on fast PCs, raise it if you see stutter during massive syncs.")
    tuningHelp:SetPoint("TOPLEFT", tuningHeader, "BOTTOMLEFT", 0, -6)

    -- Each slider needs ~16px slider body + ~12-14px below for the
    -- low/high tick labels rendered by OptionsSliderTemplate. The next
    -- anchor below has to leave room for both, otherwise the next
    -- slider's title text overlaps the previous slider's tick labels.
    local SLIDER_VERTICAL_GAP = 56

    local pullDelaySlider = createSlider(pageSync,
        "Pull cadence",
        TUNING_BOUNDS.blockPullDelaySeconds.min,
        TUNING_BOUNDS.blockPullDelaySeconds.max,
        0.5,
        "%.1fs",
        function(value)
            setTuning("blockPullDelaySeconds", value)
        end
    )
    pullDelaySlider:SetPoint("TOPLEFT", tuningHelp, "BOTTOMLEFT", 6, -28)
    self.pullDelaySlider = pullDelaySlider

    local maxSeedSlider = createSlider(pageSync,
        "Max peers served in parallel",
        TUNING_BOUNDS.maxInboundSeedSessions.min,
        TUNING_BOUNDS.maxInboundSeedSessions.max,
        1,
        "%d",
        function(value)
            setTuning("maxInboundSeedSessions", value)
        end
    )
    maxSeedSlider:SetPoint("TOPLEFT", pullDelaySlider, "BOTTOMLEFT", 0, -SLIDER_VERTICAL_GAP)
    self.maxSeedSlider = maxSeedSlider

    local pullTimeoutSlider = createSlider(pageSync,
        "Block pull response timeout",
        TUNING_BOUNDS.blockPullResponseTimeoutSeconds.min,
        TUNING_BOUNDS.blockPullResponseTimeoutSeconds.max,
        5,
        "%ds",
        function(value)
            setTuning("blockPullResponseTimeoutSeconds", value)
        end
    )
    pullTimeoutSlider:SetPoint("TOPLEFT", maxSeedSlider, "BOTTOMLEFT", 0, -SLIDER_VERTICAL_GAP)
    self.pullTimeoutSlider = pullTimeoutSlider

    local toolsHeader = createPageHeader(pageTools, "Tools")
    local priceDiagButton = createButton(pageTools, "Price Providers Status", 180, function()
        if Addon.Market and Addon.Market.DumpStatus then
            Addon.Market:DumpStatus("")
        end
    end)
    priceDiagButton:SetPoint("TOPLEFT", toolsHeader, "BOTTOMLEFT", -6, -8)

    local perfButton = createButton(pageTools, "Toggle Perf Debug", 180, function()
        Addon:SlashHandler("perf toggle")
    end)
    perfButton:SetPoint("TOPLEFT", priceDiagButton, "BOTTOMLEFT", 0, -8)

    local perfDumpButton = createButton(pageTools, "Dump Perf Status", 180, function()
        Addon:SlashHandler("perf dump")
    end)
    perfDumpButton:SetPoint("TOPLEFT", perfButton, "BOTTOMLEFT", 0, -8)

    local help = createText(pageTools, "Slash commands: /rr, /rr options, /rr perf [toggle|dump|reset], /rr prices <item name|item link>, /rr share [guild|party|raid|say].")
    help:SetPoint("TOPLEFT", perfDumpButton, "BOTTOMLEFT", 0, -14)

    panel.refresh = function()
        Options:RefreshControls()
    end
    panel.default = function()
        local profile = getProfile()
        if not profile then return end
        profile.defaultSearchMode = "recipe"
        profile.searchMode = "recipe"
        profile.useRecipeCategories = true
        if type(profile.minimap) ~= "table" then
            profile.minimap = { hide = false, minimapPos = 220 }
        else
            profile.minimap.hide = false
        end
        profile.tuning = profile.tuning or {}
        for field, bounds in pairs(TUNING_BOUNDS) do
            profile.tuning[field] = bounds.default
        end
        if type(profile.mainFrame) == "table" then
            profile.mainFrame.scale = 1
        end
        if Addon.UI and Addon.UI.ApplyFrameScale then
            Addon.UI:ApplyFrameScale()
        end
        resetRecipePrefilters(profile)
        if Addon.UI then
            Addon.UI.searchMode = "recipe"
            Addon.UI.selectedRecipeKey = nil
        end
        if Addon.MinimapButton then
            Addon.MinimapButton:Refresh()
        end
        invalidateRecipeFilters(nil, "filters:defaults")
        refreshOpenDirectory()
        Options:RefreshControls()
    end

    self.panel = panel
    registerOptionsPanel(self, panel)
    self:RefreshControls()
    return panel
end

function Options:Open()
    local panel = self:EnsurePanel()
    if not panel then return false end

    if type(Settings) == "table" and type(Settings.OpenToCategory) == "function" then
        local categoryID = self.settingsCategoryID or getCategoryID(self.settingsCategory)
        if categoryID then
            local ok = pcall(Settings.OpenToCategory, categoryID)
            if ok then return true end
        end
        local ok = pcall(Settings.OpenToCategory, panel.name)
        if ok then return true end
    end

    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        return true
    end

    return false
end

function Options:OnEnable()
    self:EnsurePanel()
end
