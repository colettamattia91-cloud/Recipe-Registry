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

local function installUiStubs()
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
    _G.Settings = {
        RegisterCanvasLayoutCategory = function()
            return { ID = 731 }
        end,
        RegisterAddOnCategory = function() end,
        OpenToCategory = function() end,
    }
end

local function loadAddonWithMetadataOptions()
    local metadataAddon, _wow, addon = Loader.LoadMetadata()
    Test.truthy(metadataAddon)
    installUiStubs()
    local chunk = loadfile("Options.lua") or assert(loadfile("UI/Options.lua"))
    chunk("RecipeRegistry", {})
    addon.Options:EnsurePanel()
    return addon
end

local function click(check, checked)
    check:SetChecked(checked)
    check.scripts.OnClick(check)
end

io.write("Options per-profession inheritance\n")

Test.it("writes global expansion and remote BoP settings", function()
    local addon = loadAddonWithMetadataOptions()
    local options = addon.Options
    local filters = addon.db.profile.recipePrefilters

    Test.truthy(options.globalVanillaCheck, "global Vanilla control should exist")
    Test.truthy(options.globalTbcCheck, "global TBC control should exist")
    Test.truthy(options.remoteBopCheck, "remote BoP control should exist")
    Test.eq(options.globalVanillaCheck:GetChecked(), true)
    Test.eq(options.globalTbcCheck:GetChecked(), true)
    Test.eq(options.remoteBopCheck:GetChecked(), false)

    click(options.globalVanillaCheck, false)
    click(options.remoteBopCheck, true)

    Test.eq(filters.expansionDefaults.vanilla, false)
    Test.eq(filters.expansionDefaults.tbc, true)
    Test.eq(filters.showRemoteBopOutputRecipes, true)
    Test.eq(addon.Performance.pendingUIRefreshScopes["filters:global-vanilla"], true)
    Test.eq(addon.Performance.pendingUIRefreshScopes["filters:remote-bop"], true)
end)

Test.it("stores custom profession overrides and returns to inherited defaults", function()
    local addon = loadAddonWithMetadataOptions()
    local options = addon.Options
    local filters = addon.db.profile.recipePrefilters
    local row = options.professionFilterControls.engineering

    Test.truthy(row, "engineering row should exist")
    Test.eq(row.customCheck:GetChecked(), false)
    Test.eq(row.vanillaCheck:GetChecked(), true)
    Test.eq(row.tbcCheck:GetChecked(), true)

    click(row.customCheck, true)
    local override = filters.professionExpansionOverrides.engineering
    Test.eq(override.inherit, false)
    Test.eq(override.vanilla, true)
    Test.eq(override.tbc, true)
    Test.eq(row.customCheck:GetChecked(), true)

    click(row.vanillaCheck, false)
    override = filters.professionExpansionOverrides.engineering
    Test.eq(override.inherit, false)
    Test.eq(override.vanilla, false)
    Test.eq(override.tbc, true)
    Test.eq(addon.Performance.pendingUIRefreshScopes["filters:engineering"], true)

    click(row.customCheck, false)
    Test.eq(filters.professionExpansionOverrides.engineering, nil)
    Test.eq(row.customCheck:GetChecked(), false)
    Test.eq(row.vanillaCheck:GetChecked(), true)
    Test.eq(row.tbcCheck:GetChecked(), true)
end)

Test.it("warns when a custom profession disables every supported expansion", function()
    local addon = loadAddonWithMetadataOptions()
    local options = addon.Options
    local row = options.professionFilterControls.engineering

    click(row.customCheck, true)
    click(row.vanillaCheck, false)
    click(row.tbcCheck, false)

    Test.truthy(options.filterWarning.text:find("custom profession filters", 1, true))
end)

io.write(string.format("Options per-profession inheritance: %d test(s) passed\n", Test.count))
