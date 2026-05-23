local ADDON_NAME = "RecipeRegistry_Metadata"

local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0")

_G.RecipeRegistry_Metadata = Addon
Addon.ADDON_VERSION = "0.1.0"

local function trimInput(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function splitCommand(input)
    input = trimInput(input)
    local command, rest = input:match("^(%S+)%s*(.*)$")
    return command or "", rest or ""
end

function Addon:OnInitialize()
    self:RegisterChatCommand("rrmeta", "SlashHandler")
end

function Addon:SlashHandler(input)
    local command = splitCommand(input)
    command = command:lower()

    if command == "diag" and self.Diagnostics and self.Diagnostics.PrintDiagnostics then
        self.Diagnostics:PrintDiagnostics()
        return
    end

    if command == "version" and self.Diagnostics and self.Diagnostics.PrintVersion then
        self.Diagnostics:PrintVersion()
        return
    end

    self:Print("Recipe Registry Metadata commands: /rrmeta diag, /rrmeta version")
end
