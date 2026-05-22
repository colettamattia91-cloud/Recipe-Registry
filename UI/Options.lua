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

local function clampTuning(field, value)
    local bounds = TUNING_BOUNDS[field]
    if not bounds then return value end
    value = tonumber(value) or bounds.default
    if value < bounds.min then return bounds.min end
    if value > bounds.max then return bounds.max end
    return value
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

local function createHeader(parent, text, anchor, yOffset)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOffset or -18)
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

local function setMinimapShown(shown)
    local profile = getProfile()
    if not profile then return end
    profile.minimap.hide = shown ~= true
    if Addon.MinimapButton then
        Addon.MinimapButton:Refresh()
    end
end

function Options:RefreshControls()
    local profile = getProfile()
    if not profile then return end
    if self.categoryCheck then
        self.categoryCheck:SetChecked(profile.useRecipeCategories ~= false)
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
    if self.pullDelaySlider then
        self.pullDelaySlider:SetDisplayValue(profile.tuning.blockPullDelaySeconds)
    end
    if self.maxSeedSlider then
        self.maxSeedSlider:SetDisplayValue(profile.tuning.maxInboundSeedSessions)
    end
    if self.pullTimeoutSlider then
        self.pullTimeoutSlider:SetDisplayValue(profile.tuning.blockPullResponseTimeoutSeconds)
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
        content:SetSize(560, 720)
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

    local layoutHeader = createHeader(content, "Directory Layout", version, -18)
    local categoryCheck = createCheck(content, "Show AtlasLoot recipe categories when available", function(self)
        setRecipeCategoriesEnabled(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    categoryCheck:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", -2, -8)
    self.categoryCheck = categoryCheck

    local categoryHelp = createText(content, "When enabled, selecting a profession can expand into All plus AtlasLoot categories.")
    categoryHelp:SetPoint("TOPLEFT", categoryCheck, "BOTTOMLEFT", 28, 0)

    local searchHeader = createHeader(content, "Search Defaults", categoryHelp, -18)
    local recipeSearchRadio = createRadio(content, "Recipe names only", function()
        setSearchMode("recipe")
        Options:RefreshControls()
    end)
    recipeSearchRadio:SetPoint("TOPLEFT", searchHeader, "BOTTOMLEFT", -2, -8)
    self.recipeSearchRadio = recipeSearchRadio

    local materialSearchRadio = createRadio(content, "Recipe names and materials", function()
        setSearchMode("materials")
        Options:RefreshControls()
    end)
    materialSearchRadio:SetPoint("TOPLEFT", recipeSearchRadio, "BOTTOMLEFT", 0, -2)
    self.materialSearchRadio = materialSearchRadio

    local searchHelp = createText(content, "This sets the default scope. The search bar can still be changed quickly while browsing.")
    searchHelp:SetPoint("TOPLEFT", materialSearchRadio, "BOTTOMLEFT", 28, 0)

    local accessHeader = createHeader(content, "Access", searchHelp, -18)
    local minimapCheck = createCheck(content, "Show minimap button", function(self)
        setMinimapShown(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    minimapCheck:SetPoint("TOPLEFT", accessHeader, "BOTTOMLEFT", -2, -8)
    self.minimapCheck = minimapCheck

    local openButton = createButton(content, "Open Recipe Registry", 180, function()
        if Addon.UI then
            Addon.UI:Toggle()
        end
    end)
    openButton:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 2, -10)

    local tuningHeader = createHeader(content, "Sync Tuning", openButton, -28)
    local tuningHelp = createText(content,
        "Advanced. Defaults work for most setups; lower the pull delay only on fast PCs, raise it if you see stutter during massive syncs.")
    tuningHelp:SetPoint("TOPLEFT", tuningHeader, "BOTTOMLEFT", 0, -6)

    -- Each slider needs ~16px slider body + ~12-14px below for the
    -- low/high tick labels rendered by OptionsSliderTemplate. The next
    -- anchor below has to leave room for both, otherwise the next
    -- slider's title text overlaps the previous slider's tick labels.
    local SLIDER_VERTICAL_GAP = 56

    local pullDelaySlider = createSlider(content,
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

    local maxSeedSlider = createSlider(content,
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

    local pullTimeoutSlider = createSlider(content,
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

    local toolsHeader = createHeader(content, "Tools", pullTimeoutSlider, -44)
    local priceDiagButton = createButton(content, "Price Providers Status", 180, function()
        if Addon.Market and Addon.Market.DumpStatus then
            Addon.Market:DumpStatus("")
        end
    end)
    priceDiagButton:SetPoint("TOPLEFT", toolsHeader, "BOTTOMLEFT", -6, -8)

    local perfButton = createButton(content, "Toggle Perf Debug", 180, function()
        Addon:SlashHandler("perf toggle")
    end)
    perfButton:SetPoint("TOPLEFT", priceDiagButton, "BOTTOMLEFT", 0, -8)

    local perfDumpButton = createButton(content, "Dump Perf Status", 180, function()
        Addon:SlashHandler("perf dump")
    end)
    perfDumpButton:SetPoint("TOPLEFT", perfButton, "BOTTOMLEFT", 0, -8)

    local help = createText(content, "Slash commands: /rr, /rr options, /rr perf [toggle|dump|reset], /rr prices <item name|item link>, /rr share [guild|party|raid|say].")
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
        if Addon.UI then
            Addon.UI.searchMode = "recipe"
            Addon.UI.selectedRecipeKey = nil
        end
        if Addon.MinimapButton then
            Addon.MinimapButton:Refresh()
        end
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
