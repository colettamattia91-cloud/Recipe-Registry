local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Marker = {}
Addon.MailMarker = Marker

-- Marker codec for the Craft Orders mail protocol.
--
-- The mail body's last block is a single-line, JSON-like machine
-- record bracketed by '--RR-ORDER--' and '--RR-END--' fences so a
-- scanner can locate it without scanning the entire body. Format
-- (see docs/craft-orders-roadmap.md §7.1):
--
--   --RR-ORDER--
--   {id="...",req="Char-Realm",cra="Char-Realm",b=1,bt=3,sv=1,h="<hash>",items={[itemID]=count,...}}
--   --RR-END--
--
-- v1 is hand-rolled rather than reused from AceSerializer because the
-- body is *human-readable* and we want the same encoding to work
-- across plugin versions, even when AceSerializer's framing changes.
-- The format is stable, line-delimited, and easy to inspect in-game.

Marker.SCHEMA_VERSION = 1
Marker.FENCE_BEGIN    = "--RR-ORDER--"
Marker.FENCE_END      = "--RR-END--"

-- Kind discriminator for the mail body:
--   "materials": requester -> crafter, attached items are reagents
--                expected by the recipe (default for back-compat;
--                a marker missing the k= field decodes as materials).
--   "delivery":  crafter -> requester, attached items are the
--                finished outputs the crafter is delivering.
Marker.KIND_MATERIALS = "materials"
Marker.KIND_DELIVERY  = "delivery"

-- Lua 5.1 has no native bitwise XOR. Walk each bit position of the
-- two operands, flipping the result bit when exactly one input has it
-- set. Inputs are non-negative integers in [0, 2^32); the result fits
-- in the same range. Slow per call but the marker hashes operate on
-- a few hundred bytes at most, so the cost is irrelevant in practice.
local function bxor32(a, b)
    local result = 0
    local bit = 1
    for _ = 1, 32 do
        local aHas = math.floor(a / bit) % 2 == 1
        local bHas = math.floor(b / bit) % 2 == 1
        if aHas ~= bHas then
            result = result + bit
        end
        bit = bit * 2
    end
    return result
end

-- FNV-1a-like deterministic hash. NOT a cryptographic primitive: the
-- roadmap is explicit that this is for accidental-corruption and
-- casual-tamper detection in a guild trust environment (§7.4). A
-- motivated adversary can always rebuild a body marker that matches
-- their attachments; the goal is making *protocol-vs-reality drift*
-- visible to both sender and recipient.
--
-- Returns a short hex string (8 chars). Operates on the canonical
-- text representation of the items table so identical item sets
-- always hash the same regardless of insertion order.
local function fnv1a(str)
    -- 32-bit FNV offset basis + prime, computed in Lua's 53-bit
    -- double math with a manual modulo 2^32 to stay stable across
    -- Lua builds.
    local h = 2166136261
    for index = 1, #str do
        h = bxor32(h, string.byte(str, index))
        h = (h * 16777619) % 4294967296
    end
    return string.format("%08x", math.floor(h))
end

-- Canonical text form of an items table: keys sorted ascending,
-- formatted as "itemID=count" joined by commas. This is what we hash
-- and also what we use to compare two markers' items for equality.
local function canonicalItemString(items)
    if type(items) ~= "table" then return "" end
    local ids = {}
    for itemID in pairs(items) do
        ids[#ids + 1] = tonumber(itemID) or 0
    end
    table.sort(ids)
    local parts = {}
    for index = 1, #ids do
        local id = ids[index]
        local count = tonumber(items[id]) or 0
        parts[index] = string.format("%d=%d", id, count)
    end
    return table.concat(parts, ",")
end

function Marker:CanonicalItems(items)
    return canonicalItemString(items)
end

function Marker:CanonicalHash(items)
    return fnv1a(canonicalItemString(items))
end

-- Encodes a marker block as the full multi-line text (fences + body),
-- ready to be appended to a mail body. The caller is responsible for
-- the human-readable header above the marker. Returns the encoded
-- string. Items is a map of itemID -> count.
function Marker:Encode(spec)
    if type(spec) ~= "table" then return nil, "invalid-spec" end
    if type(spec.orderId) ~= "string" or spec.orderId == "" then return nil, "missing-orderId" end
    if type(spec.requester) ~= "string" or spec.requester == "" then return nil, "missing-requester" end
    if type(spec.crafter) ~= "string" or spec.crafter == "" then return nil, "missing-crafter" end
    local batchNumber = tonumber(spec.batchNumber) or 1
    local totalBatches = tonumber(spec.totalBatches) or 1
    if batchNumber < 1 or totalBatches < 1 or batchNumber > totalBatches then
        return nil, "invalid-batch"
    end
    if type(spec.items) ~= "table" then return nil, "missing-items" end

    -- Render items as {[id]=count,[id]=count,...} with keys sorted so
    -- two encodings of the same logical set produce byte-identical
    -- output (matches the hashing invariant).
    local ids = {}
    for itemID in pairs(spec.items) do
        ids[#ids + 1] = tonumber(itemID) or 0
    end
    table.sort(ids)
    local itemParts = {}
    for index = 1, #ids do
        local id = ids[index]
        itemParts[index] = string.format("[%d]=%d", id, tonumber(spec.items[id]) or 0)
    end
    local itemsBlock = "{" .. table.concat(itemParts, ",") .. "}"

    local hash = self:CanonicalHash(spec.items)
    local kind = spec.kind or Marker.KIND_MATERIALS

    local payload = string.format(
        'id="%s",req="%s",cra="%s",k="%s",b=%d,bt=%d,sv=%d,h="%s",items=%s',
        spec.orderId, spec.requester, spec.crafter, kind,
        batchNumber, totalBatches, Marker.SCHEMA_VERSION,
        hash, itemsBlock
    )

    return string.format("%s\n{%s}\n%s",
        Marker.FENCE_BEGIN, payload, Marker.FENCE_END)
end

-- Extracts the items={...} sub-string from the payload, returning the
-- raw inner content (without the outer braces). Returns nil if the
-- items key is absent or malformed.
local function extractItemsRaw(payload)
    local startPos = payload:find("items=", 1, true)
    if not startPos then return nil end
    -- Skip past 'items=' itself.
    local braceStart = payload:find("{", startPos + 6, true)
    if not braceStart then return nil end
    -- Walk forward tracking depth so nested braces inside the items
    -- block (none expected but defensive) don't trip us.
    local depth = 0
    for index = braceStart, #payload do
        local ch = payload:sub(index, index)
        if ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
                return payload:sub(braceStart + 1, index - 1)
            end
        end
    end
    return nil
end

local function parseItemsRaw(raw)
    if type(raw) ~= "string" then return nil end
    local items = {}
    -- Match each [id]=count pair. The body is hand-rolled by Encode
    -- so the format is predictable; we still tolerate whitespace.
    for id, count in raw:gmatch("%[(%-?%d+)%]%s*=%s*(%-?%d+)") do
        items[tonumber(id)] = tonumber(count)
    end
    return items
end

-- Extracts a string-typed key from the payload (the format is
-- key="value"). Returns nil when the key is absent or not a string.
local function extractStringField(payload, key)
    return payload:match(key .. '="([^"]*)"')
end

local function extractNumberField(payload, key)
    return tonumber(payload:match(key .. "=(%-?%d+)"))
end

-- Decodes a mail body. Returns the parsed marker table on success or
-- nil + reason on failure. The body may contain arbitrary text above
-- and below the marker block; only the content between the fences is
-- parsed.
function Marker:Decode(body)
    if type(body) ~= "string" or body == "" then return nil, "empty-body" end
    local beginIdx = body:find(Marker.FENCE_BEGIN, 1, true)
    if not beginIdx then return nil, "no-marker" end
    local endIdx = body:find(Marker.FENCE_END, beginIdx + #Marker.FENCE_BEGIN, true)
    if not endIdx then return nil, "no-end-fence" end

    local inner = body:sub(beginIdx + #Marker.FENCE_BEGIN, endIdx - 1)
    -- Strip the outer {...} that wraps the payload.
    local openBrace  = inner:find("{", 1, true)
    local closeBrace = inner:find("}", openBrace and openBrace + 1 or 1, true)
    if not openBrace or not closeBrace then return nil, "no-payload" end
    -- Find the matching close brace at depth 0 (items has its own).
    local depth = 0
    local payloadEnd
    for index = openBrace, #inner do
        local ch = inner:sub(index, index)
        if ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
                payloadEnd = index
                break
            end
        end
    end
    if not payloadEnd then return nil, "unbalanced-payload" end
    local payload = inner:sub(openBrace + 1, payloadEnd - 1)

    local orderId   = extractStringField(payload, "id")
    local requester = extractStringField(payload, "req")
    local crafter   = extractStringField(payload, "cra")
    local hash      = extractStringField(payload, "h")
    local kind      = extractStringField(payload, "k")
    local batch     = extractNumberField(payload, "b")
    local total     = extractNumberField(payload, "bt")
    local schema    = extractNumberField(payload, "sv")
    local itemsRaw  = extractItemsRaw(payload)
    if not (orderId and requester and crafter and hash and batch and total and schema and itemsRaw) then
        return nil, "missing-fields"
    end
    -- Markers from pre-kind versions decode as materials so the
    -- scanner keeps working against old mail bodies.
    if not kind or kind == "" then kind = Marker.KIND_MATERIALS end

    return {
        orderId       = orderId,
        requester     = requester,
        crafter       = crafter,
        kind          = kind,
        batchNumber   = batch,
        totalBatches  = total,
        schemaVersion = schema,
        hash          = hash,
        items         = parseItemsRaw(itemsRaw) or {},
    }
end
