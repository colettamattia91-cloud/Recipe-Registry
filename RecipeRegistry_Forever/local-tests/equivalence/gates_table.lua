-- La tabella dei cancelli del sync, per run-equivalence.ps1.
--
-- Gli scenari della gilda simulata passano dai cancelli solo nelle
-- combinazioni che capitano. Qui un client simulato viene messo a forza in
-- ogni combinazione degli stati che i cancelli guardano -- SavedVariables,
-- giocatore, warmup, cambio di zona, roster, indice, istanza, combattimento,
-- sessione in corso; e per il compagno versione, caps, sessione in entrata,
-- backoff -- e si scrive cosa risponde ogni cancello, insieme agli effetti che
-- ha avuto (HELLO programmati, eventi, sessioni chiuse).
--
-- Due esecuzioni, col codice di prima (RR_SIM_WORKING_REF) e con quello nuovo,
-- devono scrivere lo stesso file. Si lancia dalla cartella dell'addon:
--   lua local-tests/equivalence/gates_table.lua
-- Con RR_SIM_RECORD scrive <cartella>/gates.txt, altrimenti dice solo quante
-- righe avrebbe scritto.

local Sim = dofile("local-tests/harness/sim.lua")

local out = {}
local function emit(line) out[#out + 1] = line end

local function text(v)
    if type(v) == "table" then
        return "{" .. table.concat(Sim.SerializeForRecord(v, ""), ";") .. "}"
    end
    return tostring(v)
end

Sim.recordLabel = "tabella dei cancelli"
local sim = Sim.New({ seed = 1 })
local probe = sim:AddPeer("Gate Probe", { professions = { { "Cooking", { 2679, 6888 } } } })
local PEER = "Gate Peer"
sim:AddPeer(PEER, { online = false })
-- che il client finisca login, roster e indice come in gioco
sim:Run(120)

local S, D = probe.Sync, probe.Data
local now = function() return probe.env.time() end
local WIRE = probe.Addon.WIRE_VERSION

-- ---------------------------------------------------------------- effetti
-- I cancelli hanno effetti: RefreshSyncReadyState programma un HELLO quando il
-- sync diventa pronto, registra eventi, ecc. Si intercettano e si scrivono.
-- Quelli che metterebbero in moto timer si fermano qui; ClearInboundSeedSessions
-- prosegue, perche' quello che svuota conta per le risposte dopo.
local calls = {}
local function intercept(name, passthrough)
    local original = S[name]
    S[name] = function(self, ...)
        local n = select("#", ...)
        local args = { ... }
        local parts = {}
        for i = 1, n do
            local v = args[i]
            if type(v) == "table" then
                parts[#parts + 1] = string.format("{reason=%s,peer=%s,extra=%s}",
                    tostring(v.reason), tostring(v.peer), tostring(v.extra))
            else
                parts[#parts + 1] = tostring(v)
            end
        end
        calls[#calls + 1] = name .. "(" .. table.concat(parts, ",") .. ")"
        if passthrough and original then
            return original(self, ...)
        end
    end
end
intercept("ScheduleHello", false)
intercept("RecordSyncEvent", false)
intercept("ResetDiscoveryRetry", false)
intercept("ScheduleDiscoveryRetry", false)
intercept("ClearInboundSeedSessions", true)

local function flushCalls()
    if #calls > 0 then
        emit("  effetti: " .. table.concat(calls, " "))
    end
    calls = {}
end

-- ---------------------------------------------------------------- stato
-- Roster e indice li dice Data: si sostituiscono le due letture con lo stato
-- della combinazione.
local state = {}
D.GetRosterTrustState = function()
    return { trusted = state.roster == true, reason = state.roster and "trusted" or "roster-incomplete" }
end
D.GetSyncIndexReadiness = function()
    return { ready = state.index == "ready", indexStatus = state.index }
end

local function applyLocal(s)
    state = s
    S.savedVariablesReady = s.sv
    S.playerReady = s.player
    S.warmupUntil = s.warmup and (now() + 100) or 0
    S.worldTransitionUntil = s.transition and (now() + 100) or 0
    probe.inInstance = s.instance
    probe.inCombat = s.combat
    if s.session == "none" then
        S.outboundSeedSession = nil
    else
        S.outboundSeedSession = { state = s.session, seedKey = PEER, startedAt = now(), lastProgressAt = now() }
    end
end

local function localLabel(s)
    return string.format("sv=%s player=%s warmup=%s transition=%s roster=%s index=%s instance=%s combat=%s session=%s",
        tostring(s.sv), tostring(s.player), tostring(s.warmup), tostring(s.transition), tostring(s.roster),
        tostring(s.index), tostring(s.instance), tostring(s.combat), tostring(s.session))
end

local KINDS = { "HELLO", "SUMMARY", "INDEX_DIFF_REQUEST", "INDEX_DIFF_RESPONSE", "BLOCK_PULL_REQUEST",
    "BLOCK_SNAPSHOT", "BLOCK_PULL_REFUSED", "UNKNOWN_KIND" }
local BOOLS = { false, true }
local INDEX = { "ready", "dirty", "building" }
local SESSIONS = { "none", "seed-selected", "waiting-index-diff", "waiting-block" }

-- ---------------------------------------------------------------- parte 1
-- Lo stato locale: ogni combinazione, nello stesso ordine ogni volta (anche le
-- transizioni da una riga all'altra fanno parte di cio' che si confronta).
local localCount = 0
for _, sv in ipairs(BOOLS) do
for _, player in ipairs(BOOLS) do
for _, warmup in ipairs(BOOLS) do
for _, transition in ipairs(BOOLS) do
for _, roster in ipairs(BOOLS) do
for _, index in ipairs(INDEX) do
for _, instance in ipairs(BOOLS) do
for _, combat in ipairs(BOOLS) do
for _, session in ipairs(SESSIONS) do
    localCount = localCount + 1
    local s = { sv = sv, player = player, warmup = warmup, transition = transition, roster = roster,
        index = index, instance = instance, combat = combat, session = session }
    applyLocal(s)
    emit("L " .. localLabel(s))
    local ready, reason = S:RefreshSyncReadyState("gate-table")
    emit(string.format("  refresh=%s,%s syncReady=%s notReady=%s activePull=%s roster=%s,%s index=%s,%s",
        tostring(ready), tostring(reason), tostring(S.syncReady), tostring(S.lastSyncNotReadyReason),
        tostring(S.indexUsableForActivePull), tostring(S.rosterPreflightReady), tostring(S.rosterPreflightReason),
        tostring(S.indexReady), tostring(S.indexStatus)))
    flushCalls()
    for _, kind in ipairs(KINDS) do
        local allowed, why = S:CanRunSyncProtocol(kind)
        emit(string.format("  run %s = %s,%s", kind, tostring(allowed), tostring(why)))
        flushCalls()
    end
    local allowed, why = S:CanRunSyncProtocol(nil)
    emit(string.format("  run nil = %s,%s", tostring(allowed), tostring(why)))
    flushCalls()
    local serve, serveWhy = S:CanServeCachedBlocks()
    emit(string.format("  serveCached = %s,%s", tostring(serve), tostring(serveWhy)))
    emit(string.format("  advancePull=%s deferHeavy=%s warmup=%s,%s transition=%s,%s",
        tostring(S:CanAdvanceOutboundPullSession()), tostring(S:ShouldDeferHeavyLifecycleWork("gate-table")),
        tostring(S:IsInWarmup()), tostring(S:GetWarmupRemaining()),
        tostring(S:IsInWorldTransition()), tostring(S:GetWorldTransitionRemaining())))
    emit("  caps = " .. text(S:GetLocalProtocolCaps()))
    flushCalls()
end end end end end end end end end

-- ---------------------------------------------------------------- parte 2
-- Il compagno: versione, caps, sessione in entrata, backoff, sessione in
-- uscita verso di lui, su quattro stati locali tipici.
local LOCAL_STATES = {
    { name = "pronto", s = { sv = true, player = true, warmup = false, transition = false, roster = true,
        index = "ready", instance = false, combat = false, session = "none" } },
    { name = "indice-sporco", s = { sv = true, player = true, warmup = false, transition = false, roster = true,
        index = "dirty", instance = false, combat = false, session = "none" } },
    { name = "istanza", s = { sv = true, player = true, warmup = false, transition = false, roster = true,
        index = "ready", instance = true, combat = false, session = "none" } },
    { name = "warmup", s = { sv = true, player = true, warmup = true, transition = false, roster = true,
        index = "ready", instance = false, combat = false, session = "none" } },
}

local function normalCaps()
    return {
        wireVersion = WIRE, addonVersion = "0.1.6", buildChannel = "release", buildId = "sim",
        capabilities = { indexDiffSync = true, blockPullSync = true },
        indexDiffSync = true, blockPullSync = true,
        canReceiveBlockPull = true, canSendBlockSnapshot = true, isPausedForSync = false,
    }
end

local CAPS = {
    { name = "nessuna", caps = nil },
    { name = "normali", caps = normalCaps },
    { name = "in-pausa", caps = function() local c = normalCaps(); c.isPausedForSync = true; return c end },
    { name = "non-riceve", caps = function() local c = normalCaps(); c.canReceiveBlockPull = false; return c end },
    { name = "non-manda", caps = function() local c = normalCaps(); c.canSendBlockSnapshot = false; return c end },
    { name = "senza-capability", caps = function()
        local c = normalCaps(); c.capabilities = {}; c.indexDiffSync = false; c.blockPullSync = false; return c end },
}

local VERSIONS = {
    { name = "sconosciuto", payload = nil },
    { name = "compatibile", payload = { addonVersion = "0.1.6", wireVersion = WIRE, buildChannel = "release" } },
    { name = "canale-dev", payload = { addonVersion = "0.1.6", wireVersion = WIRE, buildChannel = "dev" } },
    { name = "senza-canale", payload = { addonVersion = "0.1.6", wireVersion = WIRE } },
    { name = "wire-nuovo", payload = { addonVersion = "0.2.0", wireVersion = WIRE + 1, buildChannel = "release" } },
    { name = "wire-vecchio", payload = { addonVersion = "0.0.1", wireVersion = WIRE - 1, buildChannel = "release" } },
}

local OUTBOUND = { "none", "waiting-index-diff", "waiting-block" }
local PURPOSES = { "dispatch", "serve", "summary", "index-diff", "block-pull", "hello", "other" }

local peerCount = 0
for _, ls in ipairs(LOCAL_STATES) do
for _, version in ipairs(VERSIONS) do
for _, capsRow in ipairs(CAPS) do
for _, inbound in ipairs(BOOLS) do
for _, backoff in ipairs(BOOLS) do
for _, outbound in ipairs(OUTBOUND) do
    peerCount = peerCount + 1
    applyLocal(ls.s)
    S:RefreshSyncReadyState("gate-table-peer")
    S.peerVersions[PEER] = nil
    S.peerCaps[PEER] = nil
    S.onlineNodes[PEER] = nil
    S.inboundSeedSessions = {}
    S._peerSessionBackoffUntil = {}
    S.activeHelloCycle = { helloId = "HELLO-1", cycleId = 1, summaries = {} }
    if version.payload then
        local payload = {}
        for k, v in pairs(version.payload) do payload[k] = v end
        payload.sender = PEER
        payload.caps = capsRow.caps and capsRow.caps() or nil
        S:ObservePeerVersion(PEER, payload)
    end
    if capsRow.caps then
        S:RecordPeerCaps(PEER, capsRow.caps())
    end
    if inbound then
        S.inboundSeedSessions[PEER] = { ["REQ-1"] = { requesterKey = PEER, requestId = "REQ-1",
            servedBlocks = 0, createdAt = now(), lastActivity = now(), state = "ready",
            offeredBlocks = {}, offeredBlockCount = 0 } }
    end
    if backoff then
        S._peerSessionBackoffUntil[PEER] = now() + 100
    end
    if outbound == "none" then
        S.outboundSeedSession = nil
    else
        S.outboundSeedSession = { state = outbound, seedKey = PEER, startedAt = now(), lastProgressAt = now() }
    end
    calls = {}
    emit(string.format("C locale=%s versione=%s caps=%s entrata=%s backoff=%s uscita=%s",
        ls.name, version.name, capsRow.name, tostring(inbound), tostring(backoff), outbound))
    for _, purpose in ipairs(PURPOSES) do
        local ok, why = S:CanExchangeDataWithPeer(PEER, purpose, { source = PEER, memberKey = PEER })
        emit(string.format("  exchange %s = %s,%s", purpose, tostring(ok), tostring(why)))
    end
    for _, kind in ipairs(KINDS) do
        for _, helloId in ipairs({ "HELLO-1", "HELLO-2" }) do
            local accepted = S:ShouldAcceptInboundPayload({ kind = kind, sender = PEER, helloId = helloId }, PEER)
            emit(string.format("  accept %s %s = %s", kind, helloId, tostring(accepted)))
        end
    end
    local served, servedWhy = S:CanServeInboundSeed(PEER)
    emit(string.format("  serveInbound = %s,%s", tostring(served), tostring(servedWhy)))
    emit(string.format("  backoff=%s ineligible=%s compat=%s", tostring(S:IsPeerBackoffActive(PEER)),
        tostring(S.peerVersions[PEER] and S.peerVersions[PEER].ineligibleReason),
        tostring(S.peerVersions[PEER] and S.peerVersions[PEER].compatibility)))
    flushCalls()
end end end end end end

-- ---------------------------------------------------------------- parte 3
-- La diagnostica: che le sue funzioni girino senza errori, sullo stato di
-- adesso. Il contenuto cambia di proposito quando si toglie un campo morto,
-- quindi qui si confronta solo ok o errore; CleanCorruptState in prova a secco
-- restituisce conteggi, e quelli si confrontano.
for _, name in ipairs({ "GetRuntimeObservabilitySnapshot", "GetUiState", "GetDebugSnapshot",
    "GetAlphaDebugSnapshot", "DumpVersionStatus", "DumpPeerVersions", "DumpOfflineSyncStatus", "DumpStatus" }) do
    local fn = S[name]
    local ok, err = true, nil
    if fn then ok, err = pcall(fn, S) end
    emit(string.format("G %s = %s%s", name, fn and tostring(ok) or "assente", ok and "" or (" " .. tostring(err))))
end
local okClean, stats = pcall(S.CleanCorruptState, S, { dryRun = true })
emit("G CleanCorruptState = " .. tostring(okClean) .. " " .. text(stats))

Sim.FinishCurrent()

local dir = os.getenv("RR_SIM_RECORD")
if dir and dir ~= "" then
    local f = assert(io.open(dir .. "/gates.txt", "wb"))
    f:write(table.concat(out, "\n"), "\n")
    f:close()
end
print(string.format("tabella dei cancelli: %d stati locali, %d combinazioni di compagno, %d righe, errori del simulatore %d",
    localCount, peerCount, #out, #sim.errors))
for i = 1, math.min(3, #sim.errors) do print("  " .. sim.errors[i]:sub(1, 600)) end
os.exit(#sim.errors == 0 and 0 or 1)
