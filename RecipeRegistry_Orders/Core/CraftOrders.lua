local ADDON_NAME = ...

local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceTimer-3.0"
)

_G.RecipeRegistry_Orders = Addon

Addon.ADDON_VERSION = "0.1.0"
Addon.SCHEMA_VERSION = 1

local DB_DEFAULTS = {
    global = {
        meta = {
            schemaVersion = 1,
            createdAt = 0,
        },
        orders     = {},
        ledger     = {},
        events     = {
            seq        = 0,
            log        = {},
            tombstones = {},
        },
        peers      = {},
        options    = {
            assumedReceiptGraceSeconds = 2 * 60 * 60,
            completedRetentionDays     = 14,
            cancelledRetentionDays     = 14,
            failedRetentionDays        = 30,
            tombstoneRetentionDays     = 60,
        },
    },
    profile = {},
}

local CHAR_DB_DEFAULTS = {
    drafts = {},
}

local function ensureCharDB()
    if type(_G.RecipeRegistry_OrdersCharDB) ~= "table" then
        _G.RecipeRegistry_OrdersCharDB = {}
    end
    local db = _G.RecipeRegistry_OrdersCharDB
    for key, value in pairs(CHAR_DB_DEFAULTS) do
        if db[key] == nil then
            if type(value) == "table" then
                db[key] = {}
            else
                db[key] = value
            end
        end
    end
    return db
end

local function getRR()
    return _G.RecipeRegistry
end

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

local function formatRRStatus()
    local rr = getRR()
    if not rr then
        return "|cffff5555missing|r"
    end
    return string.format(
        "|cff88ff88ok|r v%s channel=%s",
        tostring(rr.ADDON_VERSION or "?"),
        tostring(rr.BUILD_CHANNEL or "?")
    )
end

function Addon:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("RecipeRegistry_OrdersDB", DB_DEFAULTS, true)
    self.charDB = ensureCharDB()

    local meta = self.db.global.meta
    if (meta.createdAt or 0) == 0 then
        meta.createdAt = time()
    end

    self:RegisterChatCommand("rrord", "SlashHandler")

    self._loadCheckedAt = time()
    self._rrSeenAtLoad = getRR() ~= nil
    if not self._rrSeenAtLoad and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff5555RecipeRegistry_Orders error:|r RecipeRegistry not loaded — check TOC dependency."
        )
    end
end

function Addon:OnEnable()
    -- Skeleton phase: confirm load on enable so the user sees both the
    -- plugin and the RR-dependency link working without having to run a
    -- command. Replace with quiet behaviour once Phase 1 modules land.
    local rr = getRR()
    if rr and type(rr.Print) == "function" then
        rr:Print(string.format(
            "Craft Orders %s loaded. /rrord for status.",
            tostring(self.ADDON_VERSION)
        ))
    elseif DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffffcc00RecipeRegistry_Orders:|r loaded without RR access. /rrord for status."
        )
    end
end

local function splitCommand(text)
    local trimmed = (text or ""):match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return "", ""
    end
    local cmd, rest = trimmed:match("^(%S+)%s*(.-)$")
    return cmd or "", rest or ""
end

local function printHelp(self)
    self:Print("Recipe Registry — Craft Orders commands:")
    self:Print("/rrord            - show this help")
    self:Print("/rrord status     - plugin + RR-link diagnostics")
end

local function printStatus(self)
    self:Print(string.format("Craft Orders v%s (schema %d)", self.ADDON_VERSION, self.SCHEMA_VERSION))
    self:Print("RecipeRegistry link: " .. formatRRStatus())
    self:Print(string.format(
        "Storage: orders=%d events=%d peers=%d drafts=%d",
        countKeys(self.db.global.orders),
        #(self.db.global.events.log or {}),
        countKeys(self.db.global.peers),
        countKeys(self.charDB.drafts)
    ))
end

function Addon:SlashHandler(input)
    local cmd = splitCommand(input)
    cmd = cmd:lower()

    if cmd == "" or cmd == "help" then
        printHelp(self)
        return
    end

    if cmd == "status" or cmd == "diag" then
        printStatus(self)
        return
    end

    self:Print("Unknown command. /rrord for help.")
end
