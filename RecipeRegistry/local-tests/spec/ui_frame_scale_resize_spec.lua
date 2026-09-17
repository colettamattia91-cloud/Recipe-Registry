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

local function makeRegion()
    return {
        SetText = function(self, value) self.textValue = value end,
        Show = function(self) self.visible = true end,
        Hide = function(self) self.visible = false end,
        GetStringHeight = function() return 16 end,
        ClearAllPoints = function() end,
        SetPoint = function() end,
    }
end

local function makeDetailLine()
    local line = {
        text = makeRegion(),
        actionButton = makeRegion(),
        ClearAllPoints = function() end,
        SetPoint = function() end,
        Show = function(self) self.visible = true end,
        Hide = function(self) self.visible = false end,
    }
    function line:SetWidth(width) self.width = width end
    function line:SetHeight(height) self.height = height end
    return line
end

local function makeScaledFrame()
    local frame = {}
    function frame:SetScale(scale) self.scale = scale end
    function frame:SetSize(width, height) self.width, self.height = width, height end
    function frame:ClearAllPoints() end
    function frame:SetPoint(...) self.point = { ... } end
    return frame
end

local function freshUiAddon()
    local addon = Loader.Load({ files = getUiFiles() })
    return addon, addon.UI
end

io.write("UI frame scale and resize\n")

Test.it("clamps and persists the main window scale", function()
    local addon, ui = freshUiAddon()
    ui.frame = makeScaledFrame()

    ui:SetFrameScale(2.0)
    Test.eq(addon.db.profile.mainFrame.scale, 1.2, "oversized scale should clamp to the max")
    Test.eq(ui.frame.scale, 1.2, "clamped scale should be applied to the frame")

    ui:SetFrameScale(0.1)
    Test.eq(addon.db.profile.mainFrame.scale, 0.6, "undersized scale should clamp to the min")
    Test.eq(ui.frame.scale, 0.6, "clamped scale should be applied to the frame")

    ui:SetFrameScale("not-a-number")
    Test.eq(addon.db.profile.mainFrame.scale, 1, "invalid scale should fall back to 1")
end)

Test.it("restores placement with the saved scale applied", function()
    local addon, ui = freshUiAddon()
    ui.frame = makeScaledFrame()
    addon.db.profile.mainFrame = { scale = 0.8, width = 1100, height = 700 }

    ui:RestoreFramePlacement()

    Test.eq(ui.frame.scale, 0.8, "saved scale should be applied on restore")
    Test.eq(ui.frame.width, 1100, "saved width should be restored")
    Test.eq(ui.frame.height, 700, "saved height should be restored")
end)

Test.it("keeps the minimum window size on restore", function()
    local _addon, ui = freshUiAddon()
    ui.frame = makeScaledFrame()
    local settings = { width = 400, height = 300 }
    _G.RecipeRegistry.db.profile.mainFrame = settings

    ui:RestoreFramePlacement()

    Test.eq(ui.frame.width, 1000, "width should not go below the resize minimum")
    Test.eq(ui.frame.height, 620, "height should not go below the resize minimum")
end)

Test.it("detail lines follow the live detail scroll width", function()
    local _addon, ui = freshUiAddon()
    local detailContent = { SetWidth = function(self, w) self.width = w end,
                            SetHeight = function(self, h) self.height = h end }
    local line = makeDetailLine()
    ui.frame = {
        detailScroll = { GetWidth = function() return 524 end },
        detailContent = detailContent,
        detailLines = { line },
    }

    ui:RenderDetailLines({ "Materials" }, {}, {})

    Test.eq(line.width, 524, "detail line should adopt the scroll width")
    Test.eq(detailContent.width, 524, "detail content should adopt the scroll width")
end)

Test.it("detail lines fall back to the legacy width without a laid-out scroll", function()
    local _addon, ui = freshUiAddon()
    local line = makeDetailLine()
    ui.frame = {
        detailContent = { SetWidth = function(self, w) self.width = w end,
                          SetHeight = function(self, h) self.height = h end },
        detailLines = { line },
    }

    ui:RenderDetailLines({ "Materials" }, {}, {})

    Test.eq(line.width, 420, "missing scroll should fall back to the legacy 420px width")
end)

io.write(string.format("UI frame scale and resize: %d test(s) passed\n", Test.count))
