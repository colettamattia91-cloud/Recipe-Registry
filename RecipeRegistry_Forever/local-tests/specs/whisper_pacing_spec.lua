-- La coda dei sussurri: un pezzo alla volta.
--
-- L'08/11 una sonda in gioco ha mostrato che il server di Forever scarta i
-- pezzi di un sussurro addon partiti nello stesso istante: la stessa richiesta
-- da 5 pezzi, a 7 compagni, con i pezzi tutti insieme come li spedisce AceComm
-- non e' arrivata mai (0/10), con un pezzo ogni 0.1-1 s quasi sempre. Da li'
-- la coda in SyncProtocol.lua. Qui si controlla che:
--
--   * i pezzi siano esattamente quelli di AceComm-3.0, e che AceComm li
--     ricomponga: chi riceve puo' avere qualunque versione dell'addon;
--   * fra un pezzo e l'altro passino 0.25 s dalla partenza vera, cioe' dalla
--     callback di ChatThrottleLib, anche quando la libreria li trattiene;
--   * un messaggio si finisca prima del prossimo, con la priorita' che decide
--     solo fra un messaggio e l'altro;
--   * un pezzo rifiutato chiuda il suo messaggio, e una callback che non
--     torna non fermi la coda;
--   * le buste sussurrate passino dalla coda, e la gilda no.
--
-- Si lancia da RecipeRegistry_Forever/ con run-tests.ps1.

local modules = {}
local traces = {}
local clock = 1793975000.0

-- il tempo e i timer li fa avanzare lo spec
local timers = {}
local function schedule(fn, delay)
  local handle = { at = clock + (tonumber(delay) or 0), fn = fn }
  timers[#timers + 1] = handle
  return handle
end
local function advance(seconds)
  local target = clock + seconds
  while true do
    local nextHandle, nextIndex
    for i, h in ipairs(timers) do
      if not h.cancelled and h.at <= target and (not nextHandle or h.at < nextHandle.at) then
        nextHandle, nextIndex = h, i
      end
    end
    if not nextHandle then break end
    table.remove(timers, nextIndex)
    if nextHandle.at > clock then clock = nextHandle.at end
    nextHandle.fn()
  end
  clock = target
end

_G.time = function() return math.floor(clock) end
_G.GetTime = function() return clock end

-- ChatThrottleLib finta: registra ogni pezzo con l'ora in cui parte. "subito"
-- richiama appena lo riceve, "trattieni" lo tiene finche' lo spec lo libera
local wire, held = {}, {}
local ctlMode, refuseIndex = "subito", nil
local function depart(row, didSend)
  row.at = clock
  wire[#wire + 1] = row
  if row.cb then row.cb(row.arg, didSend, didSend and 0 or 9) end
end
_G.ChatThrottleLib = {
  SendAddonMessage = function(_, prio, prefix, text, chattype, target, queue, cb, arg)
    local row = { prio = prio, prefix = prefix, text = text, chattype = chattype, target = target,
      queue = queue, cb = cb, arg = arg }
    if ctlMode == "trattieni" then
      held[#held + 1] = row
    else
      local n = #wire + 1
      depart(row, refuseIndex ~= n)
    end
  end,
}
local function release(didSend)
  local row = table.remove(held, 1)
  if row then depart(row, didSend ~= false) end
end
local function resetWire() wire, held, ctlMode, refuseIndex = {}, {}, "subito", nil end

-- AceComm-3.0 vera, sopra la ChatThrottleLib finta
local onAddonEvent
_G.CreateFrame = function()
  return { SetScript = function(_, _, fn) onAddonEvent = fn end, UnregisterAllEvents = function() end,
    RegisterEvent = function() end }
end
_G.Ambiguate = function(name) return name end
_G.securecallfunction = function(fn, ...) return fn(...) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
_G.C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
dofile("Libs/AceComm-3.0/AceComm-3.0.lua")
dofile("Libs/AceSerializer-3.0/AceSerializer-3.0.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")
local AceComm = LibStub("AceComm-3.0")

_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function() end, Print = function() end, SystemPrint = function() end,
  Tracef = function(_, _, fmt, ...) traces[#traces + 1] = string.format(fmt, ...) end,
  RequestRefresh = function() end,
  SendMessage = function() end,
  COMM_PREFIX = "RRDEV",
  ADDON_VERSION = "0.1.6", WIRE_VERSION = 3, BUILD_CHANNEL = "dev", BUILD_ID = "forever-dev",
  Compat = setmetatable({}, { __index = function() return function() end end }),
}
local Addon = _G.RecipeRegistry
_G.UnitNameUnmodified = function() return "Kaedros", "Davian" end
_G.GetRealmName = function() return "CamWoW EU4 Realm 7 PvE" end
_G.GetNumGuildMembers = function() return 0 end
_G.IsInInstance = function() return false end
_G.InCombatLockdown = function() return false end
_G.IsInRaid = function() return false end

dofile("Data/Data.lua")
dofile("Data/DataGuildScope.lua")
local Data = Addon.Data or modules["Data"]
Addon.Data = Data
Data.ScheduleTimer = function() return {} end
Data.CancelTimer = function() end
Data.db = { global = { options = {} } }

dofile("Sync/Sync.lua")
dofile("Sync/SyncRuntime.lua")
dofile("Sync/SyncProtocol.lua")
dofile("Sync/SyncCodec.lua")
local Sync = Addon.Sync
Sync.ScheduleTimer = function(_, fn, delay) return schedule(fn, delay) end
Sync.CancelTimer = function(_, handle) if type(handle) == "table" then handle.cancelled = true end end
Sync.RegisterEvent = function() end
Sync.CanRunSyncProtocol = function() return true end
AceComm:Embed(Sync)
Sync:OnInitialize()

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-62s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

-- un testo che sembra il filo vero: binario, con | e byte alti, senza \0
local function sample(n, seed)
  local out, x = {}, seed or 7
  for i = 1, n do
    x = (x * 1103515245 + 12345) % 2147483648
    out[i] = string.char(1 + (x % 255))
  end
  local s = table.concat(out)
  -- che non cominci per caso con un carattere di controllo
  return "R" .. s:sub(2)
end

local function partsOf(rows)
  local out = {}
  for i, row in ipairs(rows) do out[i] = row.text end
  return out
end

-- -------------------------------------------------------------------------
print("== i pezzi sono quelli di AceComm ==")
local cases = {
  { "corto", sample(40) },
  { "255 byte, un pezzo solo", sample(255) },
  { "256 byte, due pezzi", sample(256) },
  { "tre pezzi esatti", sample(254 * 3) },
  { "1200 byte, come un index diff", sample(1200) },
  { "comincia con \\001, corto: va scappato", "\001" .. sample(30):sub(2) },
  { "comincia con \\002 e fa 255 byte: va a pezzi", "\002" .. sample(255):sub(2) },
}
for _, case in ipairs(cases) do
  local label, text = case[1], case[2]
  resetWire()
  AceComm:SendCommMessage("RRDEV", text, "WHISPER", "Bea Rossi", "ALERT")
  local expected = partsOf(wire)
  resetWire()
  Sync:SendWhisper("RRDEV", text, "Bea Rossi", "ALERT")
  advance(30)
  local got = partsOf(wire)
  local same = #got == #expected
  for i = 1, math.max(#got, #expected) do
    if got[i] ~= expected[i] then same = false end
  end
  t(label .. string.format(" (%d pezzi)", #expected), same, true)

  -- e AceComm, dall'altra parte, li ricompone
  local received
  local receiver = {}
  AceComm:Embed(receiver)
  receiver:RegisterComm("RRDEV", function(_, message) received = message end)
  for _, part in ipairs(got) do
    onAddonEvent(nil, "CHAT_MSG_ADDON", "RRDEV", part, "WHISPER", "Kaedros Davian")
  end
  receiver:UnregisterAllComm()
  t("  ricomposto da AceComm", received == text, true)
end

-- -------------------------------------------------------------------------
print("\n== fra un pezzo e l'altro 0.25 s, dalla partenza vera ==")
resetWire()
local started = clock
Sync:SendWhisper("RRDEV", sample(1200), "Bea Rossi", "ALERT")
t("il primo parte subito", #wire == 1 and wire[1].at == started, true)
advance(30)
t("cinque pezzi", #wire, 5)
local minGap = math.huge
for i = 2, #wire do minGap = math.min(minGap, wire[i].at - wire[i - 1].at) end
t("la distanza minima e' 0.25 s", math.abs(minGap - 0.25) < 1e-9, true)
t("in tutto un secondo", math.abs((wire[#wire].at - wire[1].at) - 1.0) < 1e-9, true)

-- la libreria trattiene il primo pezzo (banda finita, altro traffico): il
-- secondo non le si affida finche' il primo non e' uscito
resetWire()
ctlMode = "trattieni"
Sync:SendWhisper("RRDEV", sample(600), "Bea Rossi", "ALERT")
advance(2)
t("trattenuto: un pezzo solo affidato", #held, 1)
t("e niente sul filo", #wire, 0)
release()
local departed = clock
advance(0.2)
t("uscito il primo: il secondo aspetta ancora", #held, 0)
advance(0.1)
t("dopo 0.25 s dalla partenza il secondo e' affidato", #held, 1)
t("non prima", held[1] ~= nil and clock - departed >= 0.25, true)
release(); advance(1); release(); advance(1)
t("tre pezzi, tutti usciti", #wire, 3)

-- anche fra un messaggio e l'altro: due sussurri da un pezzo non escono insieme
resetWire()
Sync:SendWhisper("RRDEV", "uno", "Bea Rossi", "ALERT")
Sync:SendWhisper("RRDEV", "due", "Cora Bianchi", "ALERT")
advance(5)
t("due messaggi da un pezzo, distanziati", #wire == 2 and math.abs(wire[2].at - wire[1].at - 0.25) < 1e-9, true)

-- -------------------------------------------------------------------------
print("\n== un messaggio alla volta, la priorita' fra un messaggio e l'altro ==")
resetWire()
advance(1)
Sync:SendWhisper("RRDEV", sample(1200, 1), "Bea Rossi", "BULK")     -- 5 pezzi
Sync:SendWhisper("RRDEV", sample(400, 2), "Cora Bianchi", "NORMAL") -- 2 pezzi
Sync:SendWhisper("RRDEV", "busy", "Dario Neri", "ALERT")            -- 1 pezzo
advance(30)
local order = {}
for _, row in ipairs(wire) do order[#order + 1] = row.target:sub(1, 1) end
t("prima il messaggio cominciato, poi ALERT, poi NORMAL", table.concat(order), "BBBBBDCC")
t("la coda e' vuota", Sync:GetWhisperQueueDepth(), 0)

-- -------------------------------------------------------------------------
print("\n== pezzi rifiutati e callback che non tornano ==")
resetWire()
advance(1)
local progress = {}
refuseIndex = 2
Sync:SendWhisper("RRDEV", sample(1200), "Bea Rossi", "ALERT", function(_, sent, total, didSend)
  progress[#progress + 1] = string.format("%d/%d:%s", sent, total, tostring(didSend))
end)
Sync:SendWhisper("RRDEV", "dopo", "Cora Bianchi", "ALERT")
advance(30)
t("il rifiutato chiude il suo messaggio", #wire, 3)
t("la callback come AceComm: byte spediti e totali", table.concat(progress, " "), "254/1200:true 508/1200:false")
t("il messaggio dopo parte lo stesso", wire[3] and wire[3].text, "dopo")

resetWire()
advance(1)
ctlMode = "trattieni"
Sync:SendWhisper("RRDEV", "perso", "Bea Rossi", "ALERT")
Sync:SendWhisper("RRDEV", "dopo", "Cora Bianchi", "ALERT")
advance(10)
t("la callback non torna: la coda aspetta", #held, 1)
advance(6)
t("dopo 15 s va avanti", #held, 2)
t("e lo scrive nel log", traces[#traces]:sub(1, 18), "whisper-part-stall")
-- la callback in ritardo, quando arriva, non deve far ripartire niente due volte
release(); advance(1)
release(); advance(1)
t("niente pezzi doppi", #wire, 2)
ctlMode = "subito"

-- -------------------------------------------------------------------------
print("\n== le buste: i sussurri dalla coda, la gilda no ==")
resetWire()
advance(1)
local blocks = {}
for i = 1, 69 do
  blocks["Socio " .. i .. "::Tailoring"] = { count = 100 + i, fingerprint = "bf3:" .. (100 + i) .. ":" .. string.format("%08x", i * 2654435761 % 4294967296) }
end
Sync:SendDirectEnvelope("INDEX_DIFF_REQUEST", { requestId = "DIFFREQ:Bea Rossi:1", blocks = blocks }, "Bea Rossi", "ALERT")
advance(0.01)
t("una richiesta lunga: il primo pezzo e basta, subito", #wire, 1)
advance(30)
t("poi gli altri, distanziati", #wire > 1, true)
local paced = true
for i = 2, #wire do
  if wire[i].at - wire[i - 1].at < 0.25 - 1e-9 then paced = false end
end
t("tutti a 0.25 s", paced, true)
t("sul canale dei sussurri", wire[1].chattype, "WHISPER")
local received
local receiver = {}
AceComm:Embed(receiver)
receiver:RegisterComm("RRDEV", function(_, message) received = message end)
for _, row in ipairs(wire) do onAddonEvent(nil, "CHAT_MSG_ADDON", "RRDEV", row.text, "WHISPER", "Kaedros Davian") end
receiver:UnregisterAllComm()
local payload = received and Sync:DecodeWirePayload(received)
t("e dall'altra parte e' la stessa richiesta", payload and payload.requestId, "DIFFREQ:Bea Rossi:1")

resetWire()
Sync:SendRefusalEnvelope("BLOCK_PULL_REFUSED", { requestId = "BLOCKREQ:1", blockKey = "A::B", reason = "paused" }, "Bea Rossi")
advance(5)
t("anche i rifiuti sussurrano dalla coda", #wire == 1 and wire[1].chattype == "WHISPER", true)

resetWire()
Sync:SendGuildEnvelope("HELLO", { key = "Kaedros Davian", helloId = "h1", professions = { "Tailoring" },
  padding = sample(600) })
t("la gilda resta com'era: AceComm, tutti i pezzi insieme", #wire > 1 and wire[#wire].at == wire[1].at, true)
t("sul canale di gilda", wire[1] and wire[1].chattype, "GUILD")

-- il modo "table-fast" dei test di prima: niente pezzi, passa da SendCommMessage
local viaComm
local realSend = Sync.SendCommMessage
Sync.SendCommMessage = function(_, _, msg, distribution) viaComm = { msg = msg, distribution = distribution } end
Sync:SendWhisper("RRDEV", { kind = "SUMMARY" }, "Bea Rossi", "ALERT")
Sync.SendCommMessage = realSend
t("un payload tabella va a SendCommMessage", viaComm and viaComm.distribution, "WHISPER")

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
