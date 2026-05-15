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
    return profile
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
end

function Options:EnsurePanel()
    if self.panel then
        registerOptionsPanel(self, self.panel)
        return self.panel
    end

    local panel = CreateFrame("Frame", "RecipeRegistryOptionsPanel", InterfaceOptionsFramePanelContainer)
    panel.name = "Recipe Registry"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Recipe Registry")

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", title, "RIGHT", 8, 0)
    icon:SetTexture(ICON_TEXTURE)

    local subtitle = createText(panel, "Guild crafting directory settings", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)

    local version = createText(panel, "Version: " .. tostring(Addon.DISPLAY_VERSION or "?"))
    version:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)

    local layoutHeader = createHeader(panel, "Directory Layout", version, -18)
    local categoryCheck = createCheck(panel, "Show AtlasLoot recipe categories when available", function(self)
        setRecipeCategoriesEnabled(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    categoryCheck:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", -2, -8)
    self.categoryCheck = categoryCheck

    local categoryHelp = createText(panel, "When enabled, selecting a profession can expand into All plus AtlasLoot categories.")
    categoryHelp:SetPoint("TOPLEFT", categoryCheck, "BOTTOMLEFT", 28, 0)

    local searchHeader = createHeader(panel, "Search Defaults", categoryHelp, -18)
    local recipeSearchRadio = createRadio(panel, "Recipe names only", function()
        setSearchMode("recipe")
        Options:RefreshControls()
    end)
    recipeSearchRadio:SetPoint("TOPLEFT", searchHeader, "BOTTOMLEFT", -2, -8)
    self.recipeSearchRadio = recipeSearchRadio

    local materialSearchRadio = createRadio(panel, "Recipe names and materials", function()
        setSearchMode("materials")
        Options:RefreshControls()
    end)
    materialSearchRadio:SetPoint("TOPLEFT", recipeSearchRadio, "BOTTOMLEFT", 0, -2)
    self.materialSearchRadio = materialSearchRadio

    local searchHelp = createText(panel, "This sets the default scope. The search bar can still be changed quickly while browsing.")
    searchHelp:SetPoint("TOPLEFT", materialSearchRadio, "BOTTOMLEFT", 28, 0)

    local accessHeader = createHeader(panel, "Access", searchHelp, -18)
    local minimapCheck = createCheck(panel, "Show minimap button", function(self)
        setMinimapShown(self:GetChecked() and true or false)
        Options:RefreshControls()
    end)
    minimapCheck:SetPoint("TOPLEFT", accessHeader, "BOTTOMLEFT", -2, -8)
    self.minimapCheck = minimapCheck

    local openButton = createButton(panel, "Open Recipe Registry", 180, function()
        if Addon.UI then
            Addon.UI:Toggle()
        end
    end)
    openButton:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 2, -10)

    local toolsHeader = createHeader(panel, "Tools", openButton, -18)
    local priceDiagButton = createButton(panel, "Price Providers Status", 180, function()
        if Addon.Market and Addon.Market.DumpStatus then
            Addon.Market:DumpStatus("")
        end
    end)
    priceDiagButton:SetPoint("TOPLEFT", toolsHeader, "BOTTOMLEFT", 0, -8)

    local perfButton = createButton(panel, "Toggle Perf Debug", 180, function()
        Addon:SlashHandler("perf toggle")
    end)
    perfButton:SetPoint("TOPLEFT", priceDiagButton, "BOTTOMLEFT", 0, -8)

    local perfDumpButton = createButton(panel, "Dump Perf Status", 180, function()
        Addon:SlashHandler("perf dump")
    end)
    perfDumpButton:SetPoint("TOPLEFT", perfButton, "BOTTOMLEFT", 0, -8)

    local mockButton = createButton(panel, "Start Mock Sync", 180, function()
        Addon:SlashHandler("mock start medium")
    end)
    mockButton:SetPoint("TOPLEFT", perfDumpButton, "BOTTOMLEFT", 0, -8)

    local help = createText(panel, "Slash commands: /rr, /rr options, /rr perf [toggle|dump|reset], /rr mock [status|start <light|medium|heavy|burst|bootstrap>|stop|reset], /rr prices <item name|item link>, /rr share [guild|party|raid|say].")
    help:SetPoint("TOPLEFT", mockButton, "BOTTOMLEFT", 0, -14)

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
