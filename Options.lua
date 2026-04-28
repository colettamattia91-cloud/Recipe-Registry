local Addon = _G.RecipeRegistry
local Options = Addon:NewModule("Options")
Addon.Options = Options

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_11"

local function createButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 160, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

function Options:OnEnable()
    if self.panel then return end

    local panel = CreateFrame("Frame", "RecipeRegistryOptionsPanel", InterfaceOptionsFramePanelContainer)
    panel.name = "Recipe Registry"

    if type(InterfaceOptions_AddCategory) == "function" then
        InterfaceOptions_AddCategory(panel)
    elseif type(InterfaceOptionsFrame_AddCategory) == "function" then
        InterfaceOptionsFrame_AddCategory(panel)
    end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Recipe Registry")

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", title, "RIGHT", 8, 0)
    icon:SetTexture(ICON_TEXTURE)

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Guild crafting directory settings")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)
    version:SetText("Version: " .. tostring(Addon.DISPLAY_VERSION or "?"))

    local openButton = createButton(panel, "Open Recipe Registry", 180, function()
        if Addon.UI then
            Addon.UI:Toggle()
        end
    end)
    openButton:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -16)

    local minimapButton = createButton(panel, "Toggle Minimap Button", 180, function()
        if Addon.MinimapButton then
            Addon.MinimapButton:ToggleHidden()
        end
    end)
    minimapButton:SetPoint("TOPLEFT", openButton, "BOTTOMLEFT", 0, -8)

    local priceDiagButton = createButton(panel, "Price Providers Status", 180, function()
        if Addon.Market and Addon.Market.DumpStatus then
            Addon.Market:DumpStatus("")
        end
    end)
    priceDiagButton:SetPoint("TOPLEFT", minimapButton, "BOTTOMLEFT", 0, -8)

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

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", mockButton, "BOTTOMLEFT", 0, -14)
    help:SetWidth(560)
    help:SetJustifyH("LEFT")
    help:SetText("Slash commands: /rr, /rr perf [toggle|dump|reset], /rr mock [status|start <light|medium|heavy|burst|bootstrap>|stop|reset], /rr prices <item name|item link>, /rr share [guild|party|raid|say]. In recipe details, Shift-click title/materials to insert links in chat. Online crafters show a request icon: click it to whisper a craft request.")

    panel.default = function()
    end

    self.panel = panel
end
