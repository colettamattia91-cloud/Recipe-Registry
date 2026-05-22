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

function Addon:GetLocalPlayerKey()
    local rr = getRR()
    if rr and rr.Data and type(rr.Data.GetPlayerKey) == "function" then
        local ok, key = pcall(rr.Data.GetPlayerKey, rr.Data)
        if ok and type(key) == "string" and key ~= "" then
            return key
        end
    end
    if type(UnitFullName) == "function" then
        local name, realm = UnitFullName("player")
        if name then
            realm = (realm and realm ~= "") and realm or (GetRealmName and GetRealmName() or "UnknownRealm")
            realm = realm:gsub("[%s%-]", "")
            return name .. "-" .. realm
        end
    end
    return nil
end

local function getRecipeDisplayInfo(recipeKey)
    local rr = getRR()
    if not (rr and rr.Data and type(rr.Data.GetRecipeDisplayInfo) == "function") then
        return nil
    end
    local ok, info = pcall(rr.Data.GetRecipeDisplayInfo, rr.Data, recipeKey)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

local function shortenOrderId(id)
    if type(id) ~= "string" or #id <= 16 then return id end
    return id:sub(1, 8) .. "…" .. id:sub(-4)
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
    self:Print("/rrord                       - show this help")
    self:Print("/rrord diag                  - plugin + RR-link diagnostics")
    self:Print("/rrord new <recipeKey> <qty> <Char-Realm>  - create a draft order")
    self:Print("/rrord add <id|prefix> <recipeKey> <qty>   - add a line to a draft")
    self:Print("/rrord list                  - list known orders (newest first)")
    self:Print("/rrord status <id|prefix>    - show one order's detail + materials")
    self:Print("/rrord delete <id|prefix>    - delete a draft order")
end

local function printDiag(self)
    self:Print(string.format("Craft Orders v%s (schema %d)", self.ADDON_VERSION, self.SCHEMA_VERSION))
    self:Print("RecipeRegistry link: " .. formatRRStatus())
    self:Print("Local player key: " .. tostring(self:GetLocalPlayerKey() or "?"))
    self:Print(string.format(
        "Storage: orders=%d events=%d peers=%d drafts=%d",
        countKeys(self.db.global.orders),
        #(self.db.global.events.log or {}),
        countKeys(self.db.global.peers),
        countKeys(self.charDB.drafts)
    ))
end

local function resolveOrderByPrefix(self, prefix)
    if type(prefix) ~= "string" or prefix == "" then
        return nil, "missing-id"
    end
    if self.Store:GetOrder(prefix) then
        return self.Store:GetOrder(prefix)
    end
    local matches = {}
    for _, order in ipairs(self.Store:ListOrders()) do
        if order.id:sub(1, #prefix) == prefix then
            matches[#matches + 1] = order
            if #matches > 1 then break end
        end
    end
    if #matches == 0 then return nil, "no-match" end
    if #matches > 1 then return nil, "ambiguous-prefix" end
    return matches[1]
end

local function cmdNew(self, rest)
    local recipeKeyArg, restAfterKey = splitCommand(rest)
    local quantityArg, restAfterQty = splitCommand(restAfterKey)
    local crafterArg = restAfterQty:match("^%s*(.-)%s*$") or ""

    local recipeKey = tonumber(recipeKeyArg)
    local quantity = tonumber(quantityArg)

    if not recipeKey or recipeKey == 0 then
        self:Print("Usage: /rrord new <recipeKey> <quantity> <Char-Realm>")
        self:Print("  recipeKey: positive itemID or negative spellID (see /rr r <id> in RR).")
        return
    end
    if not quantity or quantity <= 0 then
        self:Print("Quantity must be a positive integer.")
        return
    end
    if crafterArg == "" then
        self:Print("Missing crafter. Use full Char-Realm form (e.g. Mattia-PyrewoodVillage).")
        return
    end

    local requester = self:GetLocalPlayerKey()
    if not requester then
        self:Print("Could not determine local player key.")
        return
    end

    local info = getRecipeDisplayInfo(recipeKey)
    local recipeLabel = info and info.label or ("recipe:" .. tostring(recipeKey))

    local order, err = self.Store:CreateDraft({
        requester = requester,
        crafter   = crafterArg,
        lines = {
            {
                recipeKey    = recipeKey,
                quantity     = quantity,
                recipeLabel  = recipeLabel,
                outputItemID = info and info.createdItemID or nil,
            },
        },
    })
    if not order then
        self:Print("Failed to create draft: " .. tostring(err))
        return
    end

    self:Print(string.format(
        "Draft created: %s — %s x%d for %s.",
        shortenOrderId(order.id),
        recipeLabel,
        quantity,
        crafterArg
    ))
    self:Print("Full id: " .. order.id)
end

local function cmdList(self)
    local orders = self.Store:ListOrders()
    if #orders == 0 then
        self:Print("No orders.")
        return
    end
    self:Print(string.format("Orders: %d", #orders))
    for index = 1, #orders do
        local order = orders[index]
        local lineCount = #(order.lines or {})
        local firstLine = order.lines and order.lines[1] or nil
        local label = firstLine and firstLine.recipeLabel or "?"
        self:Print(string.format(
            "%s  [%s]  %s x%d%s  req=%s cra=%s",
            shortenOrderId(order.id),
            tostring(order.status),
            label,
            firstLine and firstLine.quantity or 0,
            lineCount > 1 and (" (+" .. (lineCount - 1) .. " more)") or "",
            tostring(order.requester),
            tostring(order.crafter)
        ))
    end
end

local function cmdStatus(self, rest)
    local prefix = (rest or ""):match("^%s*(.-)%s*$") or ""
    if prefix == "" then
        self:Print("Usage: /rrord status <id|prefix>")
        return
    end
    local order, err = resolveOrderByPrefix(self, prefix)
    if not order then
        self:Print("Order lookup failed: " .. tostring(err))
        return
    end
    self:Print(string.format("Order %s [%s]", order.id, tostring(order.status)))
    self:Print(string.format(
        "  requester=%s crafter=%s deliveryMode=%s",
        tostring(order.requester),
        tostring(order.crafter),
        tostring(order.deliveryMode)
    ))
    self:Print(string.format(
        "  created=%d updated=%d lines=%d",
        order.createdAt or 0,
        order.updatedAt or 0,
        #(order.lines or {})
    ))
    for index = 1, #(order.lines or {}) do
        local line = order.lines[index]
        self:Print(string.format(
            "    #%d  recipeKey=%d qty=%d  %s",
            index,
            line.recipeKey or 0,
            line.quantity or 0,
            tostring(line.recipeLabel or "?")
        ))
    end

    if self.Planner and self.Planner.GetSortedMaterials then
        local materials = self.Planner:GetSortedMaterials(order)
        if #materials > 0 then
            local distinct, totalUnits = self.Planner:CountMaterials(order)
            self:Print(string.format("  Materials (%d distinct, %d units total):", distinct, totalUnits))
            for index = 1, #materials do
                local m = materials[index]
                local providerTag = m.requesterProvided > 0 and "requester" or "crafter"
                self:Print(string.format(
                    "    item:%d x%d  (%s, %s)",
                    m.itemID,
                    m.required,
                    tostring(m.name or "?"),
                    providerTag
                ))
            end
        else
            self:Print("  Materials: none computed yet")
        end
        if order._plannerMissing and #order._plannerMissing > 0 then
            self:Print(string.format(
                "  |cffffcc00Warning:|r %d line(s) without reagent info (RR data missing for those recipeKeys)",
                #order._plannerMissing
            ))
        end
    end
end

local function cmdAdd(self, rest)
    local idArg, restAfterId = splitCommand(rest)
    local recipeKeyArg, restAfterKey = splitCommand(restAfterId)
    local quantityArg = (restAfterKey or ""):match("^%s*(%S+)%s*$") or ""

    if idArg == "" or recipeKeyArg == "" or quantityArg == "" then
        self:Print("Usage: /rrord add <id|prefix> <recipeKey> <quantity>")
        return
    end

    local recipeKey = tonumber(recipeKeyArg)
    local quantity = tonumber(quantityArg)
    if not recipeKey or recipeKey == 0 then
        self:Print("recipeKey must be a non-zero number.")
        return
    end
    if not quantity or quantity <= 0 then
        self:Print("Quantity must be a positive integer.")
        return
    end

    local order, err = resolveOrderByPrefix(self, idArg)
    if not order then
        self:Print("Order lookup failed: " .. tostring(err))
        return
    end

    local info = getRecipeDisplayInfo(recipeKey)
    local recipeLabel = info and info.label or ("recipe:" .. tostring(recipeKey))

    local ok, addErr = self.Store:AddLine(order.id, {
        recipeKey    = recipeKey,
        quantity     = quantity,
        recipeLabel  = recipeLabel,
        outputItemID = info and info.createdItemID or nil,
    }, self:GetLocalPlayerKey())
    if not ok then
        self:Print("Cannot add line: " .. tostring(addErr))
        return
    end

    self:Print(string.format(
        "Line added to %s: %s x%d (now %d lines).",
        shortenOrderId(order.id),
        recipeLabel,
        quantity,
        #order.lines
    ))
end

local function cmdDelete(self, rest)
    local prefix = (rest or ""):match("^%s*(.-)%s*$") or ""
    if prefix == "" then
        self:Print("Usage: /rrord delete <id|prefix>")
        return
    end
    local order, err = resolveOrderByPrefix(self, prefix)
    if not order then
        self:Print("Order lookup failed: " .. tostring(err))
        return
    end
    local ok, deleteErr = self.Store:DeleteOrder(order.id, "user-delete")
    if not ok then
        self:Print("Cannot delete: " .. tostring(deleteErr))
        return
    end
    self:Print("Deleted draft " .. shortenOrderId(order.id))
end

function Addon:SlashHandler(input)
    local cmd, rest = splitCommand(input)
    cmd = cmd:lower()

    if cmd == "" or cmd == "help" then
        printHelp(self)
        return
    end
    if cmd == "diag" or cmd == "status-self" then
        printDiag(self)
        return
    end
    if cmd == "new" then
        cmdNew(self, rest)
        return
    end
    if cmd == "add" then
        cmdAdd(self, rest)
        return
    end
    if cmd == "list" or cmd == "ls" then
        cmdList(self)
        return
    end
    if cmd == "status" or cmd == "show" then
        cmdStatus(self, rest)
        return
    end
    if cmd == "delete" or cmd == "del" or cmd == "rm" then
        cmdDelete(self, rest)
        return
    end

    self:Print("Unknown command: " .. cmd .. ". /rrord for help.")
end
