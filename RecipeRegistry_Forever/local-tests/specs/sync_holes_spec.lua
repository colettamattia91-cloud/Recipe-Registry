-- I buchi del protocollo: dove chi chiede restava ad aspettare per niente.
--
-- Visto nel log di Kaedros il 06/11, sulla 0.1.4: 18 index diff in 22 minuti,
-- 2 utili, 2 vuoti e 14 scaduti dopo 60 s senza una risposta. Le impronte
-- della gilda non convergevano, e a ogni HELLO si rifaceva lo stesso giro.
-- Da li' la verifica dei gestori, e da li' questo spec:
--
--   * l'uscita dal combattimento apriva un warmup di 6 s che chiudeva le
--     sessioni da seed, faceva rifiutare tutto in silenzio e rimandava un
--     HELLO -- chi livella ci stava dentro di continuo;
--   * ogni "no" del seed era un return muto, sull'index diff e sul block pull,
--     e il busy che esisteva non poteva partire proprio a seed non pronto;
--   * il richiedente aspettava 60 s un index diff e poi il prossimo HELLO,
--     senza provare il candidato dopo;
--   * una richiesta nuova si scontrava con la sessione vecchia dello stesso
--     compagno, ancora viva sul seed;
--   * un pezzo di sussurro rifiutato dal client spariva senza traccia;
--   * due compagni che divergono in un modo che il pull non chiude rifacevano
--     a ogni HELLO lo stesso index diff vuoto.
--
-- Si lancia da RecipeRegistry_Forever/ con run-tests.ps1.

local modules = {}
local traces = {}
local clock = 1793975000

_G.RecipeRegistry = {
  NewModule = function(self, name) local m = {}; modules[name] = m; return m end,
  Debug = function() end, Print = function() end, SystemPrint = function() end,
  Tracef = function(_, _, fmt, ...) traces[#traces + 1] = string.format(fmt, ...) end,
  RequestRefresh = function() end,
  SendMessage = function() end,
  COMM_PREFIX = "RRDEV",
  ADDON_VERSION = "0.1.6", WIRE_VERSION = 3, BUILD_CHANNEL = "dev", BUILD_ID = "forever-dev",
  Compat = setmetatable({
    GetItemInfoInstant = function(id) return id end,
    GetItemInfo = function(id) return "item " .. tostring(id) end,
    GetSpellInfo = function(id) return "spell " .. tostring(id) end,
  }, { __index = function() return function() end end }),
}
local Addon = _G.RecipeRegistry

-- il client: il tempo lo fa avanzare lo spec
_G.time = function() return clock end
_G.GetTime = function() return clock end
_G.UnitNameUnmodified = function() return "Kaedros", "Davian" end
_G.GetRealmName = function() return "CamWoW EU4 Realm 7 PvE" end
_G.GetNumGuildMembers = function() return 0 end
_G.IsSpellKnown = function() return false end
_G.C_SpellBook = { IsSpellKnown = function() return false end }
_G.GetProfessions = function() return 1 end
_G.GetProfessionInfo = function() return "Cooking", nil, 1, 75 end
local inCombat, inInstance = false, false
_G.InCombatLockdown = function() return inCombat end
_G.IsInInstance = function() return inInstance end
_G.IsInRaid = function() return false end

dofile("Data/Data.lua")
dofile("Data/DataGuildScope.lua")
dofile("Data/DataScan.lua")
dofile("Data/DataIndex.lua")
dofile("Data/DataSnapshot.lua")
dofile("Data/MergeEngine.lua")
local Data = Addon.Data or modules["Data"]
Addon.Data = Data
Addon.MergeEngine = Addon.MergeEngine or modules["MergeEngine"]
Data.ScheduleTimer = function() return {} end
Data.CancelTimer = function() end
Data.db = { global = { options = {} } }
Addon.charDB = { favorites = {} }

dofile("Sync/Sync.lua")
dofile("Sync/SyncRuntime.lua")
dofile("Sync/SyncProtocol.lua")
dofile("Sync/SyncRequests.lua")
dofile("Sync/SyncTransfer.lua")
dofile("Sync/SyncPausePolicy.lua")
local Sync = Addon.Sync
local Pause = Addon.SyncPausePolicy or modules["SyncPausePolicy"]
Addon.SyncPausePolicy = Pause
Pause.RegisterEvent = function() end

-- AceTimer, AceEvent e AceComm, ridotti a cio' che serve: i messaggi in uscita
-- restano in `sent`, con la callback dei pezzi che AceComm riceverebbe
Sync.ScheduleTimer = function() return {} end
Sync.CancelTimer = function() end
Sync.RegisterEvent = function() end
local sent = {}
Sync.EncodeWirePayload = function(_, payload) return payload end
Sync.DecodeWirePayload = function(_, text) return text end
Sync.SendCommMessage = function(_, prefix, msg, distribution, target, prio, callbackFn, callbackArg)
  sent[#sent + 1] = { kind = msg.kind, payload = msg, distribution = distribution, target = target,
    prio = prio, callbackFn = callbackFn, callbackArg = callbackArg }
end
Sync:OnInitialize()

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-62s %s", ok and "ok" or "FAIL", label, tostring(got)))
end
local function lastSent(kind)
  for i = #sent, 1, -1 do
    if sent[i].kind == kind then return sent[i] end
  end
  return nil
end
local function countSent(kind)
  local n = 0
  for _, row in ipairs(sent) do if row.kind == kind then n = n + 1 end end
  return n
end
local function lastTrace(prefix)
  for i = #traces, 1, -1 do
    if traces[i]:sub(1, #prefix) == prefix then return traces[i] end
  end
  return nil
end
-- sostituisce temporaneamente un metodo e conta le chiamate
local function spy(target, name, impl)
  local calls = {}
  local original = target[name]
  target[name] = function(self, ...)
    calls[#calls + 1] = { ... }
    if impl then return impl(self, ...) end
  end
  return calls, function() target[name] = original end
end

local ME = "Kaedros Davian"
local SEED_A, SEED_B, REQ = "Aldergar Lightsbane", "Dr Teeth", "Haillimi Borrelnoot"

print("== il combattimento non ferma piu' il sync ==")
do
  local warmups, restoreWarmup = spy(Sync, "EnterWarmup")
  local clears, restoreClears = spy(Sync, "ClearInboundSeedSessions")
  local hellos, restoreHello = spy(Sync, "ScheduleHello")
  local _, restoreReady = spy(Sync, "RefreshSyncReadyState")
  Pause:OnEnable()
  inCombat = true;  Pause:RefreshPauseState()
  t("in combattimento il protocollo va avanti", Pause:ShouldPauseProtocolTraffic("INDEX_DIFF_REQUEST"), false)
  t("la UI pesante invece si ferma", Pause:ShouldPauseHeavyUI(), true)
  -- un cambio di zona a meta' combattimento rimandava indice e HELLO
  Pause:RefreshPauseState()
  inCombat = false; Pause:RefreshPauseState()
  t("all'uscita nessun warmup", #warmups, 0)
  t("nessuna sessione da seed chiusa", #clears, 0)
  t("nessun HELLO rimandato", #hellos, 0)

  inInstance = true;  Pause:RefreshPauseState()
  t("in istanza il protocollo si ferma", Pause:ShouldPauseProtocolTraffic("INDEX_DIFF_REQUEST"), true)
  inInstance = false; Pause:RefreshPauseState()
  t("uscendo dall'istanza il warmup c'e'", warmups[1] and warmups[1][1], "instance-exit")
  t("di 15 s", warmups[1] and warmups[1][2], 15)
  t("e il HELLO di ripresa", hellos[1] and hellos[1][1], "pause-recovery")
  restoreWarmup(); restoreClears(); restoreHello(); restoreReady()
end

print("\n== il seed che non puo' lo dice ==")
do
  -- seed non pronto: anche il protocollo e' chiuso, e il busy deve partire lo stesso
  local _, restoreRun = spy(Sync, "CanRunSyncProtocol", function() return false, "warmup" end)
  local _, restoreServe = spy(Sync, "CanServeInboundSeed", function() return false, "warmup" end)
  Sync.syncReady = false
  Sync:HandleIndexDiffRequest({ sender = REQ, requestId = "DIFFREQ:" .. ME .. ":1", blocks = {} })
  local busy = lastSent("INDEX_DIFF_RESPONSE")
  t("index diff a seed non pronto: busy", busy and busy.payload.busy, true)
  t("con il motivo", busy and busy.payload.reason, "not-ready:warmup")
  t("a chi l'ha chiesto", busy and busy.target, REQ)
  t("e la richiesta giusta", busy and busy.payload.requestId, "DIFFREQ:" .. ME .. ":1")
  t("e il log del seed lo scrive", lastTrace("index-diff-refused") ~= nil, true)
  restoreServe()

  -- indice da ricostruire: prima un return muto anche questo
  local _, restoreServe2 = spy(Sync, "CanServeInboundSeed", function() return true, "ready" end)
  local _, restoreBuild = spy(Sync, "BuildIndexDiffResponseForRequest",
    function() return { ready = false, indexStatus = "not-ready" } end)
  Sync:HandleIndexDiffRequest({ sender = REQ, requestId = "DIFFREQ:" .. ME .. ":2", blocks = {} })
  t("indice non pronto: busy anche qui", lastSent("INDEX_DIFF_RESPONSE").payload.reason, "index-not-ready:not-ready")
  restoreBuild(); restoreServe2(); restoreRun()
  Sync.syncReady = true

  -- block pull senza sessione: e' la sessione chiusa dal warmup di prima
  local _, restoreRun2 = spy(Sync, "CanRunSyncProtocol", function() return true, "ready" end)
  local _, restoreServe3 = spy(Sync, "CanServeInboundSeed", function() return true, "ready" end)
  Sync:HandleBlockPullRequest({ sender = REQ, requestId = "BLOCKREQ:1", blockKey = "Alarnos Duskhallow::Cooking" })
  local refused = lastSent("BLOCK_PULL_REFUSED")
  t("block pull senza sessione: rifiutato", refused and refused.payload.reason, "unknown-request")
  t("per il blocco chiesto", refused and refused.payload.blockKey, "Alarnos Duskhallow::Cooking")

  Sync:RegisterInboundSeedSession(REQ, "DIFFREQ:" .. ME .. ":3", { { blockKey = "Alarnos Duskhallow::Cooking" } })
  Sync:HandleBlockPullRequest({ sender = REQ, requestId = "BLOCKREQ:2", blockKey = "Alarnos Duskhallow::Mining" })
  t("blocco non offerto", lastSent("BLOCK_PULL_REFUSED").payload.reason, "block-not-offered")
  -- offerto, ma nel frattempo sparito: qui non c'e' proprio
  Sync:HandleBlockPullRequest({ sender = REQ, requestId = "BLOCKREQ:3", blockKey = "Alarnos Duskhallow::Cooking" })
  t("offerto e poi sparito", lastSent("BLOCK_PULL_REFUSED").payload.reason, "snapshot-unavailable")
  restoreRun2(); restoreServe3()

  -- in istanza la richiesta si butta prima del gestore: ma un no parte
  local _, restoreAccept = spy(Sync, "ShouldAcceptInboundPayload", function() return true end)
  inInstance = true
  Sync:OnCommReceived("RRDEV", { kind = "INDEX_DIFF_REQUEST", sender = REQ, requestId = "DIFFREQ:" .. ME .. ":4", blocks = {} }, "WHISPER", REQ)
  t("in istanza: busy", lastSent("INDEX_DIFF_RESPONSE").payload.reason, "paused:PAUSED_INSTANCE")
  Sync:OnCommReceived("RRDEV", { kind = "BLOCK_PULL_REQUEST", sender = REQ, requestId = "BLOCKREQ:4", blockKey = "Alarnos Duskhallow::Cooking" }, "WHISPER", REQ)
  t("in istanza: block pull rifiutato", lastSent("BLOCK_PULL_REFUSED").payload.reason, "paused:PAUSED_INSTANCE")
  inInstance = false
  restoreAccept()
  local _, restoreReject = spy(Sync, "ShouldAcceptInboundPayload", function() return false end)
  Sync:OnCommReceived("RRDEV", { kind = "INDEX_DIFF_REQUEST", sender = REQ, requestId = "DIFFREQ:" .. ME .. ":5", blocks = {} }, "WHISPER", REQ)
  t("compagno non riconosciuto: busy", lastSent("INDEX_DIFF_RESPONSE").payload.reason, "not-accepted")
  restoreReject()
end

print("\n== la sessione vecchia dello stesso compagno lascia il posto ==")
do
  Sync.inboundSeedSessions = {}
  local first = Sync:RegisterInboundSeedSession(REQ, "DIFFREQ:" .. ME .. ":10", { { blockKey = "A::Cooking" } })
  local second, why = Sync:RegisterInboundSeedSession(REQ, "DIFFREQ:" .. ME .. ":11", { { blockKey = "A::Cooking" } })
  t("la prima apre", first ~= nil, true)
  t("la seconda non riceve per-requester-cap", second ~= nil, true)
  t("motivo", why, "ready")
  t("la vecchia non c'e' piu'", Sync.inboundSeedSessions[REQ]["DIFFREQ:" .. ME .. ":10"], nil)
  t("e il log lo dice", lastTrace("inbound-seed-session-superseded") ~= nil, true)
end

-- un giro HELLO con due candidati, come lo lascia SelectOutboundSeed
local function freshCycle()
  Sync.activeHelloCycle = {
    cycleId = 7, helloId = ME .. ":1793975000:7", summaries = {}, busySeedKeys = {},
    seedCandidates = {
      { peerKey = SEED_A, inTopBand = true, globalFingerprint = "gf3:A", activeContentCount = 470 },
      { peerKey = SEED_B, inTopBand = true, globalFingerprint = "gf3:B", activeContentCount = 469 },
    },
  }
end

print("\n== chi chiede non resta appeso ==")
do
  local _, restoreExchange = spy(Sync, "CanExchangeDataWithPeer", function() return true end)
  local _, restoreReady = spy(Sync, "RefreshSyncReadyState")
  Sync.syncReady = true

  -- un blocco che il seed non ha piu': si salta e si va avanti
  freshCycle()
  Sync.outboundSeedSession = {
    seedKey = SEED_A, state = "waiting-block", successfulBlockMerges = 0, nextWantedIndex = 1,
    activeBlockKey = "X::Cooking", activeBlockRequestId = "BLOCKREQ:a",
    wantedBlocks = { { blockKey = "X::Cooking" }, { blockKey = "X::Mining" } },
  }
  Sync:HandleReceivedBlockPullRefused({ sender = SEED_A, requestId = "BLOCKREQ:a", blockKey = "X::Cooking", reason = "snapshot-unavailable" })
  t("blocco sparito: si passa al prossimo", Sync.outboundSeedSession.nextWantedIndex, 2)
  t("con lo stesso seed", Sync.outboundSeedSession.seedKey, SEED_A)
  t("in attesa del prossimo pull", Sync.outboundSeedSession.state, "waiting-next-block-delay")

  -- il seed che non puo': si prova l'altro candidato subito
  Sync.outboundSeedSession.state = "waiting-block"
  Sync.outboundSeedSession.activeBlockKey = "X::Mining"
  Sync.outboundSeedSession.activeBlockRequestId = "BLOCKREQ:b"
  Sync:HandleReceivedBlockPullRefused({ sender = SEED_A, requestId = "BLOCKREQ:b", blockKey = "X::Mining", reason = "unknown-request" })
  t("seed che non puo': si passa all'altro", Sync.outboundSeedSession.seedKey, SEED_B)
  t("che parte da capo", Sync.outboundSeedSession.state, "seed-selected")

  -- un rifiuto che non e' per la richiesta in corso non tocca niente
  Sync.outboundSeedSession.state = "waiting-block"
  Sync.outboundSeedSession.activeBlockRequestId = "BLOCKREQ:c"
  t("rifiuto di un altro seed ignorato",
    Sync:HandleReceivedBlockPullRefused({ sender = SEED_A, requestId = "BLOCKREQ:c", reason = "unknown-request" }), false)

  -- l'index diff senza risposta: 30 s, poi il candidato dopo
  freshCycle()
  Sync.outboundSeedSession = {
    seedKey = SEED_A, state = "waiting-index-diff", successfulBlockMerges = 0,
    diffRequestId = "DIFFREQ:" .. SEED_A .. ":1", diffSentAt = clock, lastProgressAt = clock,
  }
  clock = clock + 29
  Sync:ProcessRequestQueue()
  t("a 29 s si aspetta ancora", Sync.outboundSeedSession.seedKey, SEED_A)
  clock = clock + 2
  Sync:ProcessRequestQueue()
  t("a 31 s si passa all'altro candidato", Sync.outboundSeedSession.seedKey, SEED_B)
  t("e il log lo dice", lastTrace("index-diff-timeout") ~= nil, true)

  -- e chi non ha risposto passa in fondo ai candidati: l'08/11 il canary
  -- chiedeva ad Alarnos a ogni HELLO, sempre a vuoto
  t("chi non ha risposto e' in fondo ai candidati", Sync:IsPeerBackoffActive(SEED_A), true)
  t("l'altro no", Sync:IsPeerBackoffActive(SEED_B), false)
  Sync.activeHelloCycle = {
    cycleId = 12, helloId = ME .. ":12", busySeedKeys = {},
    summaries = {
      [SEED_A] = { peerKey = SEED_A, globalFingerprint = "gf3:A", activeContentCount = 10 },
      [SEED_B] = { peerKey = SEED_B, globalFingerprint = "gf3:B", activeContentCount = 10 },
    },
  }
  Sync.outboundSeedSession = nil
  t("al giro dopo si elegge l'altro", Sync:SelectOutboundSeed(12), SEED_B)
  clock = clock + 121
  t("dopo due minuti torna candidato come gli altri", Sync:IsPeerBackoffActive(SEED_A), false)

  -- lo stesso per chi non consegna il blocco chiesto
  Sync.outboundSeedSession = {
    seedKey = SEED_B, state = "waiting-block", successfulBlockMerges = 0,
    activeBlockKey = "X::Mining", blockRequestedAt = clock, lastProgressAt = clock, startedAt = clock,
  }
  clock = clock + 61
  Sync:ProcessRequestQueue()
  t("blocco non consegnato: anche lui in fondo", Sync:IsPeerBackoffActive(SEED_B), true)
  restoreExchange(); restoreReady()
end

print("\n== i timeout scattano anche a protocollo fermo ==")
do
  -- trovato dalla gilda simulata: HELLO, 6 s di finestra, nel frattempo
  -- un'istanza; la sessione nasceva in pausa e non scadeva mai
  local _, restoreExchange = spy(Sync, "CanExchangeDataWithPeer", function() return true end)
  local _, restoreReady = spy(Sync, "RefreshSyncReadyState")
  inInstance = true
  Sync.activeHelloCycle = {
    cycleId = 9, helloId = ME .. ":9", busySeedKeys = {},
    summaries = { [SEED_A] = { peerKey = SEED_A, globalFingerprint = "gf3:A", activeContentCount = 10 } },
  }
  t("in istanza non si elegge nessun seed", Sync:SelectOutboundSeed(9), nil)
  t("e il log lo dice", lastTrace("seed-selection-skipped") ~= nil, true)

  -- una sessione aperta un attimo prima dell'istanza
  Sync.outboundSeedSession = { seedKey = SEED_A, state = "seed-selected", successfulBlockMerges = 0,
    startedAt = clock, lastProgressAt = clock }
  clock = clock + 59
  Sync:ProcessRequestQueue()
  t("a 59 s c'e' ancora", Sync.outboundSeedSession.state, "seed-selected")
  clock = clock + 2
  Sync:ProcessRequestQueue()
  t("a 61 s scade anche in istanza", Sync.outboundSeedSession.state, "aborted")
  t("per timeout", Sync.outboundSeedSession.abortReason, "session-timeout")

  -- un index diff scaduto in istanza chiude la sessione, non ne apre un'altra
  freshCycle()
  Sync.outboundSeedSession = { seedKey = SEED_A, state = "waiting-index-diff", successfulBlockMerges = 0,
    diffSentAt = clock, lastProgressAt = clock }
  clock = clock + 31
  Sync:ProcessRequestQueue()
  t("in istanza il ripiego chiude e basta", Sync.outboundSeedSession.state, "aborted")
  t("senza passare a un altro seed", Sync.outboundSeedSession.seedKey, SEED_A)
  inInstance = false
  restoreExchange(); restoreReady()
end

print("\n== i pezzi che non partono finiscono nel log ==")
do
  local _, restoreRun = spy(Sync, "CanRunSyncProtocol", function() return true, "ready" end)
  sent = {}
  Sync:SendDirectEnvelope("INDEX_DIFF_REQUEST", { requestId = "DIFFREQ:x", blocks = {} }, SEED_A, "ALERT")
  local msg = sent[#sent]
  t("la callback c'e'", type(msg.callbackFn), "function")
  -- AceComm la chiama per ogni pezzo con (arg, byte mandati, totale, partito?)
  msg.callbackFn(msg.callbackArg, 254, 1016, true)
  t("un pezzo partito non scrive niente", lastTrace("send-chunk-failed"), nil)
  msg.callbackFn(msg.callbackArg, 508, 1016, false)
  t("uno rifiutato si'", lastTrace("send-chunk-failed"),
    "send-chunk-failed kind=INDEX_DIFF_REQUEST via=WHISPER target=" .. SEED_A .. " at=508/1016")
  local before = #traces
  msg.callbackFn(msg.callbackArg, 762, 1016, false)
  t("il secondo dello stesso messaggio solo nel contatore", #traces, before)
  t("contatore", Sync.telemetry.sendChunksFailed, 2)
  -- i messaggi di gilda e i rifiuti passano dalla stessa callback
  Sync:SendGuildEnvelope("HELLO", { key = ME }, "ALERT")
  t("anche sul canale di gilda", type(sent[#sent].callbackFn), "function")
  Sync:SendIndexDiffBusy(REQ, { requestId = "DIFFREQ:y" }, "warmup")
  t("anche sui rifiuti", type(sent[#sent].callbackFn), "function")
  restoreRun()
end

print("\n== le coppie sterili: chi chiede ==")
do
  local localFp = "gf3:L"
  local _, restoreSettled = spy(Sync, "GetSettledLocalFingerprint", function() return localFp end)
  local _, restoreExchange = spy(Sync, "CanExchangeDataWithPeer", function() return true end)
  local _, restoreReady = spy(Sync, "RefreshSyncReadyState")
  local realSummary = Data.BuildLocalSummary
  Data.BuildLocalSummary = function() return { indexStatus = "ready", globalFingerprint = localFp } end
  local retries, restoreRetry = spy(Sync, "ScheduleDiscoveryRetry")

  local function emptyDiffFrom(seed, seedFp, offered)
    Sync.outboundSeedSession = {
      seedKey = seed, state = "waiting-index-diff", successfulBlockMerges = 0,
      diffRequestId = "DIFFREQ:" .. seed .. ":9", seedFingerprint = seedFp, localFingerprint = localFp,
      lastProgressAt = clock,
    }
    Sync:HandleReceivedIndexDiffResponse({ sender = seed, requestId = "DIFFREQ:" .. seed .. ":9", offeredBlocks = offered or {} })
  end
  local function cycleWith(seed, seedFp)
    Sync.activeHelloCycle = {
      cycleId = 8, helloId = ME .. ":8", busySeedKeys = {},
      summaries = { [seed] = { peerKey = seed, globalFingerprint = seedFp, activeContentCount = 470 } },
    }
    return Sync:SelectOutboundSeed(8)
  end

  emptyDiffFrom(SEED_A, "gf3:A")
  t("index diff vuoto: coppia registrata", lastTrace("sterile-pair-recorded side=pull peer=" .. SEED_A) ~= nil, true)
  t("al giro dopo, stesse impronte: non lo si elegge", cycleWith(SEED_A, "gf3:A"), nil)
  t("e non si rifa' la scoperta fra 20 s", #retries, 0)
  t("perche'", lastTrace("seed-selection-none-sterile") ~= nil, true)
  t("se cambia la sua impronta, si'", cycleWith(SEED_A, "gf3:A2"), SEED_A)

  emptyDiffFrom(SEED_A, "gf3:A")
  localFp = "gf3:L2"
  t("se cambia la mia, si'", cycleWith(SEED_A, "gf3:A"), SEED_A)
  localFp = "gf3:L"

  emptyDiffFrom(SEED_A, "gf3:A")
  Data:BumpDroppedMarksGeneration()
  t("se cambia un segno, si'", cycleWith(SEED_A, "gf3:A"), SEED_A)

  -- vuoto per un blocco segnato: sterile anche quello
  Data:GetMembersDB()["Alarnos Duskhallow"] = {
    owner = "Alarnos Duskhallow", guildStatus = "active", professions = {},
    droppedProfessions = { Mining = true },
  }
  emptyDiffFrom(SEED_A, "gf3:A", { { blockKey = "Alarnos Duskhallow::Mining", count = 1, fingerprint = "bf3:1:x", reason = "missing" } })
  t("solo blocchi segnati: sterile", lastTrace("sterile-pair-recorded"):find("reason=owner-dropped", 1, true) ~= nil, true)

  -- vuoto per saturazione: non sterile, la saturazione scade da sola
  Sync._sterilePairs = nil
  Data.db.global.syncSaturation = { blockFingerprints = { ["B::Cooking"] = { ["bf3:2:y"] = { noProgressCount = 2, saturatedUntil = clock + 100 } } } }
  emptyDiffFrom(SEED_B, "gf3:B", { { blockKey = "B::Cooking", count = 2, fingerprint = "bf3:2:y", reason = "missing" } })
  t("vuoto per saturazione: nessuna coppia", Sync._sterilePairs, nil)
  t("e lo si rielegge", cycleWith(SEED_B, "gf3:B"), SEED_B)

  -- la rete di sicurezza: dopo mezz'ora la coppia si dimentica
  emptyDiffFrom(SEED_A, "gf3:A")
  clock = clock + 1801
  t("dopo 30 minuti si riprova comunque", cycleWith(SEED_A, "gf3:A"), SEED_A)

  Data.BuildLocalSummary = realSummary
  restoreSettled(); restoreExchange(); restoreReady(); restoreRetry()
end

print("\n== le coppie sterili: chi risponde ==")
do
  local localFp = "gf3:L"
  local _, restoreSettled = spy(Sync, "GetSettledLocalFingerprint", function() return localFp end)
  local _, restoreRun = spy(Sync, "CanRunSyncProtocol", function() return true, "ready" end)
  local _, restoreServe = spy(Sync, "CanServeInboundSeed", function() return true, "ready" end)
  local _, restoreBuild = spy(Sync, "BuildIndexDiffResponseForRequest",
    function() return { ready = true, offeredBlocks = {} } end)
  local realSummary = Data.BuildLocalSummary
  Data.BuildLocalSummary = function() return { indexStatus = "ready", globalFingerprint = localFp } end
  Sync._sterilePairs = nil
  sent = {}

  local function helloFrom(fp)
    Sync:HandleHello({ key = REQ, sender = REQ, helloId = REQ .. ":1", indexStatus = "ready", globalFingerprint = fp }, "GUILD", REQ)
  end
  helloFrom("gf3:R")
  t("prima volta: il SUMMARY parte", countSent("SUMMARY"), 1)
  Sync:HandleIndexDiffRequest({ sender = REQ, requestId = "DIFFREQ:" .. ME .. ":20", blocks = {} })
  t("non avevamo niente da dargli", lastSent("INDEX_DIFF_RESPONSE").payload.busy, nil)
  t("coppia registrata", lastTrace("sterile-pair-recorded side=serve peer=" .. REQ) ~= nil, true)
  helloFrom("gf3:R")
  t("stesso HELLO: niente SUMMARY", countSent("SUMMARY"), 1)
  t("e il log dice perche'", lastTrace("summary-suppressed peer=" .. REQ .. " reason=sterile-pair") ~= nil, true)
  helloFrom("gf3:R2")
  t("impronta nuova: il SUMMARY riparte", countSent("SUMMARY"), 2)

  Data.BuildLocalSummary = realSummary
  restoreSettled(); restoreRun(); restoreServe(); restoreBuild()
end

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
