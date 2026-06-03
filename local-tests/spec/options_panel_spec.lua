local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function makeFrame()
    local frame = {
        shown = false,
        scripts = {},
        children = {},
    }
    function frame:SetSize(width, height)
        self.width = width
        self.height = height
    end
    function frame:SetWidth(width)
        self.width = width
    end
    function frame:SetHeight(height)
        self.height = height
    end
    function frame:SetPoint(...)
        self.point = { ... }
    end
    function frame:SetText(text)
        self.text = text
    end
    function frame:SetJustifyH(justify)
        self.justifyH = justify
    end
    function frame:SetTexture(texture)
        self.texture = texture
    end
    function frame:SetColorTexture(r, g, b, a)
        self.colorTexture = { r, g, b, a }
    end
    function frame:SetScript(scriptName, callback)
        self.scripts[scriptName] = callback
    end
    function frame:HookScript(scriptName, callback)
        self.scripts[scriptName] = callback
    end
    function frame:Enable()
        self.enabled = true
    end
    function frame:Disable()
        self.enabled = false
    end
    function frame:SetAlpha(alpha)
        self.alpha = alpha
    end
    function frame:SetChecked(value)
        self.checked = value == true
    end
    function frame:GetChecked()
        return self.checked == true
    end
    function frame:IsShown()
        return self.shown == true
    end
    function frame:Show()
        self.shown = true
    end
    function frame:Hide()
        self.shown = false
    end
    -- Slider template surface used by createSlider in Options.lua.
    function frame:SetMinMaxValues(low, high)
        self.minValue, self.maxValue = low, high
    end
    function frame:SetValueStep(step)
        self.valueStep = step
    end
    function frame:SetObeyStepOnDrag(flag)
        self.obeyStep = flag == true
    end
    function frame:SetValue(value)
        self.value = value
    end
    function frame:GetValue()
        return self.value
    end
    -- ScrollFrame surface used by the options panel wrapper.
    function frame:SetScrollChild(child)
        self.scrollChild = child
    end
    function frame:CreateFontString()
        local child = makeFrame()
        self.children[#self.children + 1] = child
        return child
    end
    function frame:CreateTexture()
        local child = makeFrame()
        self.children[#self.children + 1] = child
        return child
    end
    return frame
end

local function installUiStubs(mode)
    local state = {}
    _G.InterfaceOptionsFramePanelContainer = makeFrame()
    _G.CreateFrame = function(_frameType, name, parent, template)
        local frame = makeFrame()
        frame.name = name
        frame.parent = parent
        frame.template = template
        return frame
    end
    _G.GameTooltip = {
        SetOwner = function() end,
        AddLine = function() end,
        Show = function() end,
        Hide = function() end,
    }

    if mode == "settings" then
        _G.Settings = {
            RegisterCanvasLayoutCategory = function(panel, name)
                state.registeredPanel = panel
                state.registeredName = name
                return { ID = 731 }
            end,
            RegisterAddOnCategory = function(category)
                state.addonCategoryID = category.ID
            end,
            OpenToCategory = function(categoryID)
                state.openedCategoryID = categoryID
            end,
        }
    else
        _G.Settings = nil
        _G.InterfaceOptions_AddCategory = function(panel)
            state.legacyRegisteredPanel = panel
        end
        _G.InterfaceOptionsFrame_OpenToCategory = function(panel)
            state.legacyOpenCount = (state.legacyOpenCount or 0) + 1
            state.legacyOpenedPanel = panel
        end
    end

    return state
end

local function loadAddonWithOptions(mode)
    local addon = Loader.Load()
    local uiState = installUiStubs(mode)
    local chunk = loadfile("Options.lua") or assert(loadfile("UI/Options.lua"))
    chunk("RecipeRegistry", {})
    return addon, uiState
end

io.write("Options panel\n")

Test.it("registers and opens through the modern Settings API from slash command", function()
    local addon, uiState = loadAddonWithOptions("settings")

    addon:SlashHandler("options")

    Test.truthy(addon.Options.panel, "options panel should be created lazily")
    Test.eq(uiState.registeredPanel, addon.Options.panel, "panel should be registered")
    Test.eq(uiState.registeredName, "Recipe Registry", "registered settings name")
    Test.eq(uiState.addonCategoryID, 731, "addon category should be registered")
    Test.eq(uiState.openedCategoryID, 731, "slash command should open settings category")
end)

Test.it("falls back to legacy InterfaceOptions registration and opening", function()
    local addon, uiState = loadAddonWithOptions("legacy")

    addon.Options:OnEnable()
    addon:SlashHandler("config")

    Test.eq(uiState.legacyRegisteredPanel, addon.Options.panel, "legacy panel should be registered")
    Test.eq(uiState.legacyOpenedPanel, addon.Options.panel, "legacy command should open panel")
    Test.eq(uiState.legacyOpenCount, 2, "legacy open should keep the double-open workaround")
end)

io.write(string.format("Options panel: %d test(s) passed\n", Test.count))
