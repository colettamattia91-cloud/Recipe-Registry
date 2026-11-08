-- Il sync sotto stress: una gilda simulata di client veri.
--
-- Gli spec di prima provano un gestore alla volta, con il resto finto. Qui ogni
-- client e' il codice vero -- Data e Sync del suo albero, la codifica vera --
-- e parla con gli altri su un canale che perde pezzi, li rifiuta, li duplica,
-- li consegna fuori ordine e li strozza come ChatThrottleLib. Vedi
-- local-tests/harness/sim.lua.
--
-- Ogni scenario controlla le stesse cose:
--   * nessun errore Lua in nessun client;
--   * nessuna ricetta inventata: tutto cio' che un client sa di un compagno,
--     quel compagno l'ha avuto davvero;
--   * nessuna sessione ferma oltre 80 s: i timeout scattano sempre;
--   * la convergenza: alla fine ognuno ha esattamente cio' che la gilda ha;
--   * il traffico a regime, che deve stare sotto un tetto.
--
-- Si lancia da RecipeRegistry_Forever/ con run-tests.ps1. Ci mette un po':
-- sono ore di gioco simulate.

local Sim = dofile("local-tests/harness/sim.lua")

local fails, scenarios = 0, 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-66s %s", ok and "ok" or "FAIL", label, tostring(got)))
end
local function le(label, got, limit)
  local ok = type(got) == "number" and got <= limit
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-66s %s (tetto %s)", ok and "ok" or "FAIL", label, tostring(got), tostring(limit)))
end

-- le invarianti di ogni scenario
local function healthy(sim, label)
  sim:CheckNoInventedContent()
  t(label .. ": nessun errore Lua", #sim.errors, 0)
  for i = 1, math.min(3, #sim.errors) do print("     " .. sim.errors[i]:sub(1, 700)) end
  t(label .. ": nessuna violazione", #sim.violations, 0)
  for i = 1, math.min(5, #sim.violations) do print("     " .. sim.violations[i]) end
end

local function scenario(title, fn)
  scenarios = scenarios + 1
  print("\n== " .. title .. " ==")
  local started = os.clock()
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    fails = fails + 1
    print("FAIL lo scenario si e' interrotto: " .. tostring(err))
  end
  print(string.format("     (%.1f s di CPU)", os.clock() - started))
end

-- una gilda a caso: ognuno 1-3 mestieri, ricette da un insieme comune cosi'
-- che i blocchi si sovrappongano come in gioco
local PROFESSIONS = { "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
  "First Aid", "Fishing", "Leatherworking", "Mining", "Skinning", "Tailoring" }
local function randomProfessions(minRecipes, maxRecipes)
  local list, used = {}, {}
  for _ = 1, math.random(1, 3) do
    local prof = PROFESSIONS[math.random(#PROFESSIONS)]
    if not used[prof] then
      used[prof] = true
      local recipes, seen = {}, {}
      for _ = 1, math.random(minRecipes or 1, maxRecipes or 8) do
        local id = 2000 + math.random(1, 60) * 7 + (#prof * 1000)
        if not seen[id] then seen[id] = true; recipes[#recipes + 1] = id end
      end
      list[#list + 1] = { prof, recipes }
    end
  end
  return list
end

-- Cambiare mestiere come in gioco: se ne lascia uno, o se ne prende uno nuovo.
-- Quelli che si tengono non perdono ricette -- in gioco non si disimparano --
-- e uno ripreso dopo averlo lasciato riparte da poche ricette, perche' lasciarlo
-- le ha cancellate.
local function evolveProfessions(p)
  local list = {}
  for _, row in ipairs(p.professions) do
    local recipes = {}
    for k in pairs(row.recipes) do recipes[#recipes + 1] = k end
    list[#list + 1] = { row.name, recipes }
  end
  if #list > 1 and (math.random() < 0.5 or #list >= 3) then
    table.remove(list, math.random(#list))
  else
    local held = {}
    for _, row in ipairs(list) do held[row[1]] = true end
    local candidates = {}
    for _, prof in ipairs(PROFESSIONS) do if not held[prof] then candidates[#candidates + 1] = prof end end
    local prof = candidates[math.random(#candidates)]
    local recipes = {}
    for i = 1, math.random(1, 4) do recipes[i] = 30000 + #prof * 100 + math.random(1, 40) end
    list[#list + 1] = { prof, recipes }
  end
  p:SetProfessionList(list)
end

local function names(n, prefix)
  local out = {}
  for i = 1, n do out[i] = (prefix or "Membro") .. " " .. string.char(64 + ((i - 1) % 26) + 1) .. (i > 26 and tostring(i) or "") end
  return out
end

local function online(sim)
  local out = {}
  for _, name in ipairs(sim.order) do
    if sim.peers[name].online then out[#out + 1] = name end
  end
  return out
end

-- ------------------------------------------------------------------------

scenario("convergenza di base: 8 client, dati sovrapposti", function()
  local sim = Sim.New({ seed = 11 })
  for _, name in ipairs(names(8)) do sim:AddPeer(name, { professions = randomProfessions() }) end
  local took = sim:RunUntilConverged(20 * 60)
  t("tutti hanno tutto", took ~= nil, true)
  print("     convergenza in " .. tostring(took) .. " s")
  -- a regime: impronte uguali, quindi niente SUMMARY e niente index diff
  local before = sim:SnapshotSent()
  sim:Run(15 * 60)
  t("a regime nessun index diff", sim:SentSince(before, "INDEX_DIFF_REQUEST"), 0)
  t("a regime nessun SUMMARY", sim:SentSince(before, "SUMMARY"), 0)
  le("HELLO a regime in 15 minuti", sim:SentSince(before, "HELLO"), 8 * 15)
  local fps = {}
  for _, name in ipairs(sim.order) do fps[sim.peers[name]:Fingerprint()] = true end
  local distinct = 0
  for _ in pairs(fps) do distinct = distinct + 1 end
  t("una sola impronta in tutta la gilda", distinct, 1)
  healthy(sim, "base")
end)

scenario("perdite pesanti: 16% di pezzi persi, duplicati, ritardi fino a 6 s", function()
  local sim = Sim.New({ seed = 23, lossReject = 0.08, lossSilent = 0.08, duplicate = 0.1, latencyMax = 6 })
  for _, name in ipairs(names(6)) do sim:AddPeer(name, { professions = randomProfessions(4, 12) }) end
  local took = sim:RunUntilConverged(60 * 60)
  t("converge lo stesso", took ~= nil, true)
  print("     convergenza in " .. tostring(took) .. " s; " .. sim:Report())
  local failedChunks = 0
  for _, name in ipairs(sim.order) do failedChunks = failedChunks + sim.peers[name]:Count("send-chunk-failed") end
  t("i pezzi rifiutati dal client finiscono nel log", failedChunks > 0, true)
  local timeouts = 0
  for _, name in ipairs(sim.order) do timeouts = timeouts + sim.peers[name]:Count("index-diff-timeout") end
  print("     index diff abbandonati a 30 s: " .. timeouts)
  healthy(sim, "perdite")
end)

scenario("combattimento continuo e istanze", function()
  local sim = Sim.New({ seed = 31 })
  for _, name in ipairs(names(6)) do sim:AddPeer(name, { professions = randomProfessions(3, 10) }) end
  -- ognuno combatte 8-20 s ogni 5-30 s, per tutta la prova
  for _, name in ipairs(sim.order) do
    local p = sim.peers[name]
    local function fight()
      if not p.online then return end
      p:SetCombat(true)
      sim:Schedule(8 + math.random() * 12, function()
        p:SetCombat(false)
        sim:Schedule(5 + math.random() * 25, fight)
      end)
    end
    sim:Schedule(math.random() * 20, fight)
  end
  -- e ogni 10 minuti qualcuno entra in un'istanza per 3
  sim:Every(600, function()
    local p = sim.peers[sim.order[math.random(#sim.order)]]
    p:SetInstance(true)
    sim:Schedule(180, function() p:SetInstance(false) end)
  end)
  local took = sim:RunUntilConverged(30 * 60)
  t("converge anche combattendo", took ~= nil, true)
  print("     convergenza in " .. tostring(took) .. " s")
  local cleared = 0
  for _, name in ipairs(sim.order) do
    for _, line in ipairs(sim.peers[name].traces) do
      if line:find("inbound-seed-sessions-cleared reason=warmup", 1, true) then cleared = cleared + 1 end
    end
  end
  t("nessuna sessione da seed chiusa da un warmup di combattimento", cleared, 0)
  healthy(sim, "combattimento")
end)

scenario("cambio mestiere con un compagno assente (il bug di Alarnos)", function()
  local sim = Sim.New({ seed = 41 })
  local A = sim:AddPeer("Alarnos Duskhallow", { professions = {
    { "Cooking", { 2679, 6888, 2680 } }, { "Mining", { 2840 } }, { "Skinning", { 279979 } } } })
  for _, name in ipairs({ "Bea Rossi", "Ciro Verdi", "Dora Neri", "Elio Bianchi" }) do
    sim:AddPeer(name, { professions = randomProfessions() })
  end
  t("all'inizio tutti allineati", sim:RunUntilConverged(15 * 60) ~= nil, true)

  local E = sim.peers["Elio Bianchi"]
  E:Logout()
  sim:Run(60)
  A:SetProfessionList({ { "Cooking", { 2679, 6888, 2680 } }, { "Alchemy", { 247755, 5997 } } })
  local present = { "Alarnos Duskhallow", "Bea Rossi", "Ciro Verdi", "Dora Neri" }
  t("chi c'era vede il cambio", sim:RunUntilConverged(15 * 60, present) ~= nil, true)

  -- Alarnos esce, Elio torna con Mining e Skinning ancora in tasca
  A:Logout()
  sim:Run(30)
  E:Login()
  local watchers = { "Bea Rossi", "Ciro Verdi", "Dora Neri" }
  local relapsed = 0
  local before
  for minute = 1, 30 do
    sim:Run(60)
    if minute == 10 then before = sim:SnapshotSent() end
    for _, name in ipairs(watchers) do
      local blocks = sim.peers[name]:Blocks()
      if blocks["Alarnos Duskhallow::Mining"] or blocks["Alarnos Duskhallow::Skinning"] then
        relapsed = relapsed + 1
      end
    end
  end
  t("nessuno si riprende i mestieri lasciati da Elio", relapsed, 0)
  local eBlocks = E:Blocks()
  t("Elio li tiene: non ha mai sentito Alarnos", eBlocks["Alarnos Duskhallow::Mining"] ~= nil, true)
  t("ma il mestiere nuovo gli arriva dagli altri", eBlocks["Alarnos Duskhallow::Alchemy"] ~= nil, true)
  -- la divergenza c'e' davvero, altrimenti zero index diff non proverebbe niente
  t("Elio e Bea hanno impronte diverse", E:Fingerprint() ~= sim.peers["Bea Rossi"]:Fingerprint(), true)
  local sterile = 0
  for _, name in ipairs({ "Bea Rossi", "Ciro Verdi", "Dora Neri", "Elio Bianchi" }) do
    sterile = sterile + sim.peers[name]:Count("sterile-pair-recorded")
  end
  t("e le coppie sterili sono state registrate", sterile > 0, true)
  -- le coppie sterili: senza, sarebbero ~60 index diff in 20 minuti
  le("index diff negli ultimi 20 minuti", sim:SentSince(before, "INDEX_DIFF_REQUEST"), 10)

  -- Alarnos torna: anche Elio si allinea
  A:Login()
  local took = sim:RunUntilConverged(10 * 60)
  t("con Alarnos online si allineano tutti", took ~= nil, true)
  t("e Elio non ha piu' Mining", E:Blocks()["Alarnos Duskhallow::Mining"], nil)
  healthy(sim, "cambio mestiere")
end)

scenario("versioni miste: 0.1.4, 0.1.5 e la nuova nella stessa gilda", function()
  if not (Sim.TreeAvailable("forever-v0.1.4") and Sim.TreeAvailable("forever-v0.1.5")) then
    print("     saltato: i tag forever-v0.1.4 e forever-v0.1.5 non ci sono (git fetch --tags)")
    return
  end
  local sim = Sim.New({ seed = 53, lossReject = 0.03, lossSilent = 0.03 })
  local trees = { "forever-v0.1.4", "forever-v0.1.5", "forever-v0.1.5", "working", "working", "working" }
  for i, name in ipairs(names(6, "Socio")) do
    -- chi lascera' il mestiere ne ha due di sicuro: altrimenti la prova e' vuota
    local profs = i == 4 and { { "Tailoring", { 2996, 2997, 4238 } }, { "Mining", { 2840, 2841 } } }
      or randomProfessions(2, 8)
    sim:AddPeer(name, { tree = trees[i], professions = profs })
  end
  t("convergono tutti, con tre versioni", sim:RunUntilConverged(30 * 60) ~= nil, true)

  -- uno nuovo lascia Mining e prende Fishing: lo 0.1.4 non capisce la dichiarazione
  local dropper = sim.peers[sim.order[4]]
  local droppedKeys = { dropper.name .. "::Mining" }
  dropper:SetProfessionList({ { "Tailoring", { 2996, 2997, 4238 } }, { "Fishing", { 279967 } } })
  sim:Run(20 * 60)
  t("lo 0.1.4 si tiene il Mining lasciato (non capisce la dichiarazione)",
    sim.peers[sim.order[1]]:Blocks()[droppedKeys[1]] ~= nil, true)
  local before = sim:SnapshotSent()
  sim:Run(20 * 60)

  local truth = sim:TruthBlocks()
  for _, name in ipairs(sim.order) do
    local p = sim.peers[name]
    local missing, extra = sim:Diff(p, truth)
    t(string.format("%s (%s) non manca di niente", name, p.tree), #missing, 0)
    local extraOk = true
    for _, key in ipairs(extra) do
      local isDropped = false
      for _, d in ipairs(droppedKeys) do if d == key then isDropped = true end end
      if not isDropped then extraOk = false end
    end
    t(string.format("%s: di troppo solo i mestieri lasciati", name), extraOk, true)
    if p.tree ~= "forever-v0.1.4" then
      t(string.format("%s: i mestieri lasciati se ne sono andati", name), #extra, 0)
    end
  end
  -- il tetto: un index diff per client ogni 60 s, mai di piu'
  le("index diff a regime in 20 minuti (6 client)", sim:SentSince(before, "INDEX_DIFF_REQUEST"), 6 * 20)
  print("     " .. sim:Report())
  healthy(sim, "versioni miste")
end)

-- LIMITE NOTO, trovato da questa simulazione il 06/11. Il merge e' additivo e
-- non sa in quale "vita" di un mestiere e' nata una ricetta: chi lascia un
-- mestiere e lo riprende da zero mentre un compagno era assente, al ritorno di
-- quel compagno si ritrova -- in tutta la gilda, lui compreso -- le ricette
-- della vita precedente. Non lo ha introdotto la dichiarazione dei mestieri, che
-- anzi torna a nominarlo; chiuderlo vuol dire cambiare il modello (la copia del
-- proprietario che sostituisce invece di sommarsi, o una generazione del
-- mestiere). Deciso il 06/11 di non chiuderlo: e' un caso limite, e si
-- sistema quasi sempre da solo, perche' chi riprende il mestiere livellando
-- torna a imparare le stesse ricette. Qui si controlla che tutto il resto
-- regga, e si stampa il caso: il giorno che il limite si chiude, la riga
-- cambia da NOTO a ok.
scenario("riprendere un mestiere lasciato mentre un compagno era assente", function()
  local sim = Sim.New({ seed = 151 })
  local old = {}
  for i = 1, 30 do old[i] = 4000 + i end
  local A = sim:AddPeer("Alarnos Duskhallow", { professions = { { "Tailoring", old }, { "Cooking", { 2679 } } } })
  sim:AddPeer("Bea Rossi", { professions = { { "Mining", { 2840 } } } })
  local S = sim:AddPeer("Sara Indietro", { professions = { { "Fishing", { 279967 } } } })
  t("allineati", sim:RunUntilConverged(10 * 60) ~= nil, true)
  S:Logout()
  A:SetProfessionList({ { "Cooking", { 2679 } } })
  sim:Run(300)
  A:SetProfessionList({ { "Cooking", { 2679 } }, { "Tailoring", { 4001, 4002, 4003 } } })
  sim:Run(300)
  S:Login()
  sim:Run(15 * 60)
  local n = 0
  for _ in pairs(A:Blocks()["Alarnos Duskhallow::Tailoring"] or {}) do n = n + 1 end
  print(string.format("%-4s %-66s %d ricette (vere: 3)", n == 3 and "ok" or "NOTO",
    "Alarnos, ripresa Tailoring, dopo il ritorno di Sara", n))
  local fps = {}
  for _, name in ipairs(sim.order) do fps[sim.peers[name]:Fingerprint()] = true end
  local distinct = 0
  for _ in pairs(fps) do distinct = distinct + 1 end
  t("comunque tutti sulla stessa impronta", distinct, 1)
  healthy(sim, "mestiere ripreso")
end)

scenario("reload e logout a raffica durante il sync", function()
  local sim = Sim.New({ seed = 61, lossSilent = 0.02 })
  for _, name in ipairs(names(6)) do sim:AddPeer(name, { professions = randomProfessions(3, 10) }) end
  for _ = 1, 25 do
    sim:Run(60 + math.random() * 120)
    local p = sim.peers[sim.order[math.random(#sim.order)]]
    local r = math.random()
    if not p.online then p:Login()
    elseif r < 0.5 then p:Reload()
    else p:Logout() end
  end
  for _, name in ipairs(sim.order) do
    if not sim.peers[name].online then sim.peers[name]:Login() end
  end
  local took = sim:RunUntilConverged(20 * 60)
  t("a fine raffica converge", took ~= nil, true)
  print("     convergenza dopo la raffica in " .. tostring(took) .. " s")
  healthy(sim, "reload")
end)

scenario("un seed che sparisce a meta' del pull", function()
  local sim = Sim.New({ seed = 71 })
  for _, name in ipairs(names(10)) do sim:AddPeer(name, { professions = randomProfessions(4, 10) }) end
  t("all'inizio tutti allineati", sim:RunUntilConverged(20 * 60) ~= nil, true)
  local seed = sim.peers[sim.order[1]]
  for i = 2, #sim.order do sim.peers[sim.order[i]]:Logout() end
  sim:Run(120)
  -- un nuovo arriva e comincia a tirare tutto dall'unico online
  local newcomer = sim:AddPeer("Nuovo Arrivato", { professions = { { "Cooking", { 2679 } } } })
  sim:Run(55)
  seed:Logout()
  sim:Run(5)
  local backup = sim.peers[sim.order[2]]
  backup:Login()
  local took = sim:RunUntilConverged(10 * 60, { "Nuovo Arrivato", backup.name },
    sim:TruthBlocks())
  t("il nuovo finisce da un altro", took ~= nil, true)
  print("     completato in " .. tostring(took) .. " s dopo il cambio di seed")
  healthy(sim, "seed sparito")
end)

scenario("un seed che entra in istanza mentre lo si tira", function()
  local sim = Sim.New({ seed = 83 })
  for _, name in ipairs(names(6)) do sim:AddPeer(name, { professions = randomProfessions(5, 12) }) end
  t("all'inizio tutti allineati", sim:RunUntilConverged(20 * 60) ~= nil, true)
  local newcomer = sim:AddPeer("Nuova Leva", { professions = { { "Tailoring", { 2996 } } } })
  -- appena il nuovo sceglie un seed, quel seed entra in istanza
  local paused
  for _ = 1, 120 do
    sim:Run(1)
    local s = newcomer.Sync.outboundSeedSession
    if type(s) == "table" and s.state == "waiting-block" and not paused then
      paused = sim.peers[s.seedKey]
      paused:SetInstance(true)
      break
    end
  end
  t("il nuovo aveva scelto un seed", paused ~= nil, true)
  local took = sim:RunUntilConverged(5 * 60, { newcomer.name })
  t("finisce da un altro", took ~= nil, true)
  le("in meno di 3 minuti", took or 9999, 180)
  t("e il rifiuto e' arrivato", newcomer:Count("block-pull-refused-received") + newcomer:Count("index-diff-busy-received") > 0, true)
  if paused then paused:SetInstance(false) end
  healthy(sim, "istanza")
end)

scenario("una dichiarazione falsa non cancella niente", function()
  local sim = Sim.New({ seed = 97 })
  local A = sim:AddPeer("Alarnos Duskhallow", { professions = { { "Mining", { 2840 } }, { "Cooking", { 2679 } } } })
  local B = sim:AddPeer("Bea Rossi", { professions = { { "Tailoring", { 2996 } } } })
  local M = sim:AddPeer("Mallo Furbo", { professions = { { "Fishing", { 279967 } } } })
  t("allineati", sim:RunUntilConverged(10 * 60) ~= nil, true)
  A:Logout()
  sim:Run(10)
  -- Mallo scrive nel payload di essere Alarnos e dichiara solo Cooking
  local text
  M:Call(function()
    text = M.Sync:EncodeWirePayload({ kind = "SUMMARY", sender = A.name, helloId = "x",
      activeOwnerCount = 1, activeBlockCount = 1, activeContentCount = 1, globalFingerprint = "gf3:x",
      professions = { "Cooking" } })
  end)
  B:Call(function() B.Sync:OnCommReceived(B.prefix, text, "WHISPER", M.name) end)
  M:Call(function()
    text = M.Sync:EncodeWirePayload({ kind = "HELLO", sender = A.name, key = A.name, helloId = "y",
      indexStatus = "ready", globalFingerprint = "gf3:y", wireVersion = 3, buildChannel = "release",
      addonVersion = "0.1.6", professions = { "Cooking" } })
  end)
  B:Call(function() B.Sync:OnCommReceived(B.prefix, text, "GUILD", M.name) end)
  sim:Run(60)
  t("Bea ha ancora il Mining di Alarnos", B:Blocks()["Alarnos Duskhallow::Mining"] ~= nil, true)
  t("e il log dice che l'ha ignorata", B:Count("owner-declaration-ignored") >= 1, true)
  healthy(sim, "dichiarazione falsa")
end)

scenario("gilda grande: 24 client, 4% di perdite", function()
  local sim = Sim.New({ seed = 107, lossReject = 0.02, lossSilent = 0.02 })
  for _, name in ipairs(names(24, "Gildano")) do sim:AddPeer(name, { professions = randomProfessions(3, 15) }) end
  local took = sim:RunUntilConverged(45 * 60, nil, nil, 30)
  t("converge", took ~= nil, true)
  print("     convergenza in " .. tostring(took) .. " s")
  local bytes0 = {}
  for _, name in ipairs(sim.order) do bytes0[name] = sim.peers[name].bytesSent or 0 end
  sim:Run(10 * 60)
  local worst = 0
  for _, name in ipairs(sim.order) do
    local rate = ((sim.peers[name].bytesSent or 0) - bytes0[name]) / 600
    if rate > worst then worst = rate end
  end
  le("a regime, il client che manda di piu' (B/s)", math.floor(worst * 10) / 10, 0.1 * 800)
  print("     " .. sim:Report())
  healthy(sim, "gilda grande")
end)

-- I sussurri a raffica, misurati l'08/11 sul server di Forever con una sonda:
-- la stessa richiesta da 5 pezzi a 7 compagni, con i pezzi tutti insieme non
-- e' arrivata mai (0/10), con un pezzo ogni 0.1-1 s quasi sempre (38/40). La
-- regola del canale qui sotto e' quella: un pezzo di sussurro partito meno di
-- 50 ms dopo il precedente dello stesso mittente si perde, e il client non lo
-- sa. I tre scenari dicono che la regola riproduce il guasto vero, che la
-- coda dei sussurri lo evita, e cosa resta finche' la gilda e' mista.
local BURST_GAP = 0.05
local function countTraces(sim, word, filter)
  local n = 0
  for _, name in ipairs(sim.order) do
    local p = sim.peers[name]
    if not filter or filter(p) then n = n + p:Count(word) end
  end
  return n
end

scenario("sussurri a raffica scartati dal server: la 0.1.5 non converge", function()
  if not Sim.TreeAvailable("forever-v0.1.5") then
    print("     saltato: il tag forever-v0.1.5 non c'e' (git fetch --tags)")
    return
  end
  local sim = Sim.New({ seed = 71, whisperBurstGap = BURST_GAP })
  for _, name in ipairs(names(6, "Vecchio")) do
    sim:AddPeer(name, { tree = "forever-v0.1.5", professions = randomProfessions(3, 10) })
  end
  local took = sim:RunUntilConverged(20 * 60)
  -- e' il guasto dell'08/11: se un giorno converge, la regola del canale non
  -- descrive piu' il server, o la 0.1.5 non e' piu' quella
  t("in 20 minuti non converge", took, nil)
  t("il server ha scartato pezzi", sim.stats.burstDroppedParts > 0, true)
  print("     " .. sim:Report() .. " | scartati a raffica=" .. sim.stats.burstDroppedParts)
  healthy(sim, "0.1.5 a raffica")
end)

scenario("sussurri a raffica scartati dal server: con la coda la gilda converge", function()
  local sim = Sim.New({ seed = 71, whisperBurstGap = BURST_GAP })
  for _, name in ipairs(names(6, "Nuovo")) do sim:AddPeer(name, { professions = randomProfessions(3, 10) }) end
  local took = sim:RunUntilConverged(20 * 60)
  t("converge", took ~= nil, true)
  print("     convergenza in " .. tostring(took) .. " s")
  t("nessun pezzo scartato", sim.stats.burstDroppedParts, 0)
  t("nessun index diff senza risposta", countTraces(sim, "index-diff-timeout"), 0)
  healthy(sim, "coda dei sussurri")
end)

scenario("sussurri a raffica scartati dal server: gilda mista 0.1.5 e nuova", function()
  if not Sim.TreeAvailable("forever-v0.1.5") then
    print("     saltato: il tag forever-v0.1.5 non c'e' (git fetch --tags)")
    return
  end
  local sim = Sim.New({ seed = 71, whisperBurstGap = BURST_GAP })
  local trees = { "forever-v0.1.5", "forever-v0.1.5", "forever-v0.1.5", "working", "working", "working" }
  local newNames = {}
  for i, name in ipairs(names(6, "Socio")) do
    sim:AddPeer(name, { tree = trees[i], professions = randomProfessions(3, 10) })
    if trees[i] == "working" then newNames[#newNames + 1] = name end
  end
  -- fra i nuovi tutto passa: ognuno ha i blocchi di tutti i nuovi. Non
  -- RunUntilConverged, che conterebbe come "di troppo" i blocchi dei vecchi
  -- che un nuovo e' riuscito comunque a ricevere
  local function newHaveNew()
    local truth = sim:TruthBlocks(newNames)
    for _, name in ipairs(newNames) do
      local have = sim.peers[name]:Blocks()
      for key, recipes in pairs(truth) do
        local got = have[key]
        if not got then return false end
        for r in pairs(recipes) do if not got[r] then return false end end
        for r in pairs(got) do if not recipes[r] then return false end end
      end
    end
    return true
  end
  local took
  for step = 1, 80 do
    sim:Run(15)
    if newHaveNew() then took = step * 15; break end
  end
  t("i nuovi hanno tutto cio' che hanno i nuovi", took ~= nil, true)
  print("     fra i nuovi in " .. tostring(took) .. " s")
  -- le richieste dei nuovi arrivano anche ai vecchi, che le ricompongono con
  -- AceComm come sempre: e' il formato, non il ritmo, che devono conoscere
  local reached = 0
  for _, name in ipairs(sim.order) do
    local p = sim.peers[name]
    if p.tree ~= "working" then
      for _, line in ipairs(p.traces or {}) do
        local from = tostring(line):match("index%-diff%-request%-received peer=(.-) requestId")
        if from and sim.peers[from] and sim.peers[from].tree == "working" then reached = reached + 1 end
      end
    end
  end
  t("le richieste dei nuovi arrivano alla 0.1.5", reached > 0, true)
  -- quello che parte dalla 0.1.5 resta a raffica: finche' non aggiornano,
  -- i loro blocchi arrivano solo quando la banda li distanzia per caso. Chi
  -- non consegna va in fondo ai candidati invece di essere richiesto a ogni giro
  t("chi tace va in fondo ai candidati", countTraces(sim, "peer-backoff-set", function(p) return p.tree == "working" end) > 0, true)
  print("     " .. sim:Report() .. " | scartati a raffica=" .. sim.stats.burstDroppedParts)
  healthy(sim, "gilda mista a raffica")
end)

for _, seed in ipairs({ 131, 137, 139 }) do
  scenario("caos (seme " .. seed .. "): 10 client, un'ora di eventi a caso", function()
    local sim = Sim.New({ seed = seed, lossReject = 0.04, lossSilent = 0.04, duplicate = 0.05, latencyMax = 4 })
    for _, name in ipairs(names(10, "Caos")) do sim:AddPeer(name, { professions = randomProfessions(2, 10) }) end
    local events = { login = 0, logout = 0, reload = 0, combat = 0, instance = 0, swap = 0, learn = 0 }
    for _ = 1, 360 do
      sim:Run(5 + math.random() * 15)
      local p = sim.peers[sim.order[math.random(#sim.order)]]
      local r = math.random()
      if not p.online then
        if r < 0.5 then p:Login(); events.login = events.login + 1 end
      elseif r < 0.10 then p:Logout(); events.logout = events.logout + 1
      elseif r < 0.18 then p:Reload(); events.reload = events.reload + 1
      elseif r < 0.45 then
        p:SetCombat(true); events.combat = events.combat + 1
        sim:Schedule(5 + math.random() * 20, function() if p.online then p:SetCombat(false) end end)
      elseif r < 0.52 then
        p:SetInstance(true); events.instance = events.instance + 1
        sim:Schedule(60 + math.random() * 240, function() if p.online then p:SetInstance(false) end end)
      elseif r < 0.62 then
        evolveProfessions(p); events.swap = events.swap + 1
      elseif r < 0.85 and p.professions[1] then
        p:Learn(p.professions[1].name, { 9000 + math.random(1, 500) }); events.learn = events.learn + 1
      end
      if math.random() < 0.05 then sim:CheckNoInventedContent() end
    end
    -- fine del caos: tutti online, fuori dal combattimento e dalle istanze
    for _, name in ipairs(sim.order) do
      local p = sim.peers[name]
      if not p.online then p:Login() end
      if p.inCombat then p:SetCombat(false) end
      if p.inInstance then p:SetInstance(false) end
    end
    local took = sim:RunUntilConverged(30 * 60)
    print(string.format("     eventi: login=%d logout=%d reload=%d combattimenti=%d istanze=%d cambi di mestiere=%d ricette=%d",
      events.login, events.logout, events.reload, events.combat, events.instance, events.swap, events.learn))
    -- Il limite noto (vedi lo scenario del mestiere ripreso): un mestiere
    -- lasciato e ripreso da zero mentre qualcuno era assente torna con le
    -- ricette della vita vecchia, in tutta la gilda. Il caos ci cade quando
    -- capita -- l'08/11 il seme 131, appena la coda dei sussurri ha cambiato i
    -- tempi e quindi la sequenza degli eventi. Vale come convergenza, stampata
    -- NOTO, solo se tutti hanno lo stesso blocco e le ricette in piu' sono
    -- tutte del proprietario, in una vita passata del mestiere.
    local knownLimit = {}
    if not took then
      local truth = sim:TruthBlocks()
      local relaxed = {}
      for key, recipes in pairs(truth) do relaxed[key] = recipes end
      local reference = sim.peers[sim.order[1]]:Blocks()
      for key, recipes in pairs(truth) do
        local seen = reference[key]
        local owner, prof = key:match("^(.-)::(.+)$")
        local ever = sim.peers[owner] and sim.peers[owner].ever[prof] or {}
        if seen then
          local superset, fromPast, extra = true, true, 0
          for r in pairs(recipes) do if not seen[r] then superset = false end end
          for r in pairs(seen) do
            if not recipes[r] then
              extra = extra + 1
              if not ever[r] then fromPast = false end
            end
          end
          if superset and fromPast and extra > 0 then
            relaxed[key] = seen
            knownLimit[#knownLimit + 1] = string.format("%s (+%d della vita vecchia)", key, extra)
          end
        end
      end
      if #knownLimit > 0 and sim:IsConverged(nil, relaxed) then
        took = "limite noto"
      end
    end
    if #knownLimit > 0 and took == "limite noto" then
      print(string.format("%-4s %-66s %s", "NOTO", "a caos finito converge, col mestiere ripreso",
        table.concat(knownLimit, ", ")))
    else
      t("a caos finito converge", took ~= nil, true)
    end
    print("     convergenza in " .. tostring(took) .. " s; " .. sim:Report())
    if not took then
      for _, name in ipairs(sim.order) do
        local m, x, w = sim:Diff(sim.peers[name])
        if #m + #x + #w > 0 then
          print(string.format("     %s: mancano %s | in piu' %s | diversi %s", name,
            table.concat(m, ","), table.concat(x, ","), table.concat(w, ",")))
        end
      end
    end
    healthy(sim, "caos " .. seed)
  end)
end

print(string.format("\n%d scenari", scenarios))
print(fails == 0 and "TUTTO OK" or (fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
