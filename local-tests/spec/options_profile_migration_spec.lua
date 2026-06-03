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
    return state
end

local function loadOptions(addon)
    installUiStubs()
    local chunk = loadfile("Options.lua") or assert(loadfile("UI/Options.lua"))
    chunk("RecipeRegistry", {})
    return addon.Options
end

io.write("Options profile migration\n")

Test.it("adds missing prefilter keys without clobbering existing values", function()
    local addon = Loader.Load({
        savedVariables = {
            db = {
                profile = {
                    recipePrefilters = {
                        showRemoteBopOutputRecipes = true,
                        expansionDefaults = {
                            vanilla = false,
                        },
                        professionExpansionOverrides = "corrupt",
                    },
                },
            },
        },
    })

    local filters = addon.db.profile.recipePrefilters
    Test.eq(filters.showRemoteBopOutputRecipes, true)
    Test.eq(filters.expansionDefaults.vanilla, false)
    Test.eq(filters.expansionDefaults.tbc, true)
    Test.eq(type(filters.professionExpansionOverrides), "table")
end)

Test.it("creates safe defaults when the saved prefilter block is missing", function()
    local addon = Loader.Load({
        savedVariables = {
            db = {
                profile = {
                    recipePrefilters = false,
                },
            },
        },
    })

    local filters = addon.db.profile.recipePrefilters
    Test.eq(filters.showRemoteBopOutputRecipes, false)
    Test.eq(filters.expansionDefaults.vanilla, false)  -- TBC-only default
    Test.eq(filters.expansionDefaults.tbc, true)
    Test.eq(type(filters.professionExpansionOverrides), "table")
end)

Test.it("defaults and repairs the recipe category view mode", function()
    local fresh = Loader.Load()
    Test.eq(fresh.db.profile.recipeCategoryView, "expanded")

    local invalid = Loader.Load({
        savedVariables = { db = { profile = { recipeCategoryView = "bogus" } } },
    })
    Test.eq(invalid.db.profile.recipeCategoryView, "expanded")

    local accordion = Loader.Load({
        savedVariables = { db = { profile = { recipeCategoryView = "accordion" } } },
    })
    Test.eq(accordion.db.profile.recipeCategoryView, "accordion")
end)

Test.it("shows a clear metadata plugin hint when filter controls are unavailable", function()
    local addon = Loader.Load()
    -- Simulate a broken/unloaded metadata module to check the fallback hint.
    addon.RecipeMetadata = nil
    local options = loadOptions(addon)

    options:EnsurePanel()

    Test.truthy(options.filterPluginHint, "plugin hint should be present")
    Test.truthy(
        options.filterPluginHint.text:find("Recipe metadata module not loaded", 1, true),
        "plugin hint should explain why filters are unavailable"
    )
    Test.eq(options.globalVanillaCheck, nil, "global filter controls should not be created without plugin")
end)

Test.it("resets migrated prefilters from the panel defaults action", function()
    local metadataAddon, _wow, addon = Loader.LoadMetadata({
        savedVariables = {
            db = {
                profile = {
                    recipePrefilters = {
                        showRemoteBopOutputRecipes = true,
                        expansionDefaults = {
                            vanilla = false,
                            tbc = false,
                        },
                        professionExpansionOverrides = {
                            engineering = { inherit = false, vanilla = false, tbc = true },
                        },
                    },
                },
            },
        },
    })
    Test.truthy(metadataAddon)
    local options = loadOptions(addon)
    local panel = options:EnsurePanel()

    panel.default()

    local filters = addon.db.profile.recipePrefilters
    Test.eq(filters.showRemoteBopOutputRecipes, false)
    Test.eq(filters.expansionDefaults.vanilla, false)  -- TBC-only default
    Test.eq(filters.expansionDefaults.tbc, true)
    Test.eq(Test.countKeys(filters.professionExpansionOverrides), 0)
end)

io.write(string.format("Options profile migration: %d test(s) passed\n", Test.count))
