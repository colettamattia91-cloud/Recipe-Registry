local Addon = _G.RecipeRegistry
local Sync = Addon.Sync
local Private = Sync._private
local Constants = Private.constants

local time = time

local PREFIX = Constants.PREFIX

local function shouldAttachProtocolCaps(kind)
    return kind == "HELLO"
end

local function recordUnsupportedMessage(self, kind, senderKey)
    self.telemetry.unsupportedMessagesIgnored = (self.telemetry.unsupportedMessagesIgnored or 0) + 1
    self.telemetry.lastUnsupportedMessageKind = tostring(kind or "unknown")
    self.telemetry.lastUnsupportedMessageSender = tostring(senderKey or "unknown")
    self.telemetry.lastUnsupportedMessageAt = time()
    if self.RecordSyncEvent then
        self:RecordSyncEvent("unsupportedMessageIgnored", {
            reason = tostring(kind or "unknown"),
            peer = senderKey,
        })
    end
    Addon:Tracef("sync",
        "unsupported-message kind=%s sender=%s",
        tostring(kind or "unknown"),
        tostring(senderKey or "unknown")
    )
end

-- I mestieri del mittente, letti dal suo HELLO o dal suo SUMMARY: vedi
-- Data:GetDeclaredProfessionList per chi la scrive e
-- Data:ApplyOwnerProfessionDeclaration per cosa ne fa chi la riceve. Un campo
-- in piu' che i client vecchi ignorano; da un client vecchio non arriva, e
-- allora non si pota niente. Solo a sync pronto: prima il cassetto di gilda
-- puo' non essere ancora quello giusto.
--
-- E solo se il messaggio viene davvero dal proprietario. Il mittente scritto
-- nel payload lo scrive chi manda, e nessuno lo confronta con quello che dice
-- il client: finche' il sync sapeva solo aggiungere, un falso poteva al
-- massimo inventare ricette; una dichiarazione falsa cancellerebbe i mestieri
-- di un altro dal database di tutta la gilda. Quindi qui si confronta col
-- mittente di CHAT_MSG_ADDON, passato da OnCommReceived. Sul live arriva nudo,
-- "Nome Cognome" (verificato il 05/11 in gilda e in sussurro); se un giorno
-- arrivasse in un'altra forma il confronto fallirebbe, e si salterebbe solo la
-- potatura -- il resto del sync non passa di qui.
local function isFromOwner(ownerKey, commSender)
    if type(commSender) ~= "string" or commSender == "" then
        return false
    end
    local data = Addon.Data
    local senderKey = data and data.MemberKeyFromFullName and data:MemberKeyFromFullName(commSender) or commSender
    return senderKey == ownerKey
end

local function applyOwnerProfessionDeclaration(self, ownerKey, professions, commSender)
    if type(professions) ~= "table" or self.syncReady ~= true then
        return false
    end
    if not self:IsValidSyncMemberKey(ownerKey) then
        return false
    end
    if not isFromOwner(ownerKey, commSender) then
        Addon:Tracef("sync",
            "owner-declaration-ignored owner=%s sender=%s reason=sender-mismatch",
            tostring(ownerKey),
            tostring(commSender or "none")
        )
        return false
    end
    local data = Addon.Data
    if not (data and data.ApplyOwnerProfessionDeclaration) then
        return false
    end
    return data:ApplyOwnerProfessionDeclaration(ownerKey, professions)
end

-- Una richiesta buttata prima di arrivare al suo gestore -- seed in istanza,
-- compagno che non risulta -- riceve comunque un no, con il motivo: altrimenti
-- chi l'ha mandata aspetta il timeout. Solo per le due richieste che
-- aspettano una risposta; tutto il resto si butta come prima.
local function refuseDroppedRequest(self, payload, peerKey, reason)
    if not peerKey or type(payload) ~= "table" then
        return
    end
    if payload.kind == "INDEX_DIFF_REQUEST" and self.SendIndexDiffBusy then
        self:SendIndexDiffBusy(peerKey, payload, reason)
    elseif payload.kind == "BLOCK_PULL_REQUEST" and self.SendBlockPullRefused then
        self:SendBlockPullRefused(peerKey, payload, reason)
    end
end

local function localProfessionDeclaration()
    local data = Addon.Data
    return data and data.GetDeclaredProfessionList and data:GetDeclaredProfessionList() or nil
end

local function shouldSendSummaryForHello(self, helloPayload, localSummary)
    if type(localSummary) ~= "table" then
        return false
    end
    if tostring(localSummary.indexStatus or "") ~= "ready" then
        return false
    end
    if tostring(helloPayload and helloPayload.indexStatus or "") ~= "ready" then
        return false
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("SUMMARY") then
        return false
    end
    if self.IsSummarySaturated and self:IsSummarySaturated() then
        return false
    end
    return tostring(localSummary.globalFingerprint or "") ~= tostring(helloPayload and helloPayload.globalFingerprint or "")
end

function Sync:BroadcastHello()
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("HELLO")
    end
    if not allowed then
        return false
    end
    local session = self.outboundSeedSession
    if type(session) == "table" and session.state and session.state ~= "completed" and session.state ~= "aborted" then
        return false
    end

    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello",
        allowDeferred = true,
    }) or {}
    -- If the index is merely dirty (cache populated, fingerprint not yet
    -- recomputed) try a synchronous prepare before giving up. This avoids the
    -- failure mode where the prepare timer was cancelled or never scheduled,
    -- which would otherwise leave HELLO permanently deferred.
    if tostring(summary.indexStatus or "") ~= "ready"
        and Addon.Data
        and Addon.Data.IsSyncIndexDirty
        and Addon.Data:IsSyncIndexDirty()
        and Addon.Data.PrepareSyncIndexNow
    then
        Addon.Data:PrepareSyncIndexNow("hello-sync-prepare")
        summary = Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
            reason = "hello-after-prepare",
            allowDeferred = false,
        }) or summary
    end
    if tostring(summary.indexStatus or "") ~= "ready" then
        if Addon.Data and Addon.Data.ScheduleSyncIndexPrepare then
            Addon.Data:ScheduleSyncIndexPrepare("hello-not-ready", 0.5)
        end
        if self.RefreshSyncReadyState then
            self:RefreshSyncReadyState("hello-not-ready")
        end
        if self.ScheduleHello then
            self:ScheduleHello("deferred:hello-not-ready")
        end
        return false
    end
    local cycle = self.BeginHelloCycle and self:BeginHelloCycle(self._pendingHelloCycleReason or "hello") or nil
    local sent = self:SendGuildEnvelope("HELLO", {
        key = self:GetSelfKey(),
        helloId = cycle and cycle.helloId or nil,
        version = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
        wireVersion = Addon.WIRE_VERSION,
        buildChannel = Addon.BUILD_CHANNEL,
        buildId = Addon.BUILD_ID,
        capabilities = Addon.CAPABILITIES,
        caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
        syncModel = summary.syncModel,
        indexStatus = summary.indexStatus,
        activeOwnerCount = summary.activeOwnerCount or 0,
        activeBlockCount = summary.activeBlockCount or 0,
        activeContentCount = summary.activeContentCount or 0,
        globalFingerprint = summary.globalFingerprint,
        professions = localProfessionDeclaration(),
    }, "ALERT")
    if sent then
        self.lastHelloAt = time()
        self.telemetry.helloSent = (self.telemetry.helloSent or 0) + 1
        self.telemetry.lastHelloSentAt = self.lastHelloAt
        self.telemetry.lastHelloId = cycle and cycle.helloId or nil
        self.telemetry.lastHelloFingerprint = summary.globalFingerprint
        self._pendingHelloCycleReason = nil
        if self.RecordSyncEvent then
            self:RecordSyncEvent("helloSent", {
                reason = cycle and cycle.reason or "hello",
                requestId = cycle and cycle.helloId or nil,
                extra = tostring(summary.globalFingerprint or "none"),
            })
        end
        Addon:Tracef("sync",
            "hello-sent helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
            tostring(cycle and cycle.helloId or "none"),
            tonumber(summary.activeOwnerCount or 0) or 0,
            tonumber(summary.activeBlockCount or 0) or 0,
            tonumber(summary.activeContentCount or 0) or 0,
            tostring(summary.globalFingerprint or "none")
        )
        if self._helloCycleTimer then
            self:CancelTimer(self._helloCycleTimer, true)
            self._helloCycleTimer = nil
        end
        if cycle then
            self._helloCycleTimer = self:ScheduleTimer(function()
                self._helloCycleTimer = nil
                self.telemetry.summaryCollectionTimeouts = (self.telemetry.summaryCollectionTimeouts or 0) + 1
                if self.SelectOutboundSeed then
                    self:SelectOutboundSeed(cycle.cycleId)
                end
            end, Constants.SUMMARY_COLLECTION_WINDOW or 6)
        end
        return true
    end
    return false
end

-- I pezzi che non partono.
--
-- AceComm spezza un messaggio oltre i 255 byte in pezzi, e ChatThrottleLib li
-- consegna al client uno alla volta. Se il client ne rifiuta uno, la libreria
-- lo rimette in coda solo per il codice 3 (throttle): con qualunque altro
-- codice lo butta, e chi riceve non riesce piu' a ricomporre il messaggio. Una
-- richiesta di index diff da ~1 KB e' fatta di 4-5 pezzi, un SUMMARY di uno.
-- Senza questa callback non lo sapremmo mai. Ci arriva solo se il pezzo e'
-- partito, non il codice -- da AceComm in gilda, dalla coda dei sussurri qui
-- sotto -- e per sapere se succede basta. (L'08/11 il client non ne ha
-- rifiutato nessuno: i pezzi li perdeva il server, vedi la coda.)
local function newSendTracker(kind, distribution, target)
    return { kind = kind, distribution = distribution, target = target, failed = 0 }
end

local function onChunkSent(tracker, sentBytes, totalBytes, didSend)
    if didSend ~= false or type(tracker) ~= "table" then
        return
    end
    tracker.failed = tracker.failed + 1
    local sync = Addon.Sync
    if sync and sync.telemetry then
        sync.telemetry.sendChunksFailed = (sync.telemetry.sendChunksFailed or 0) + 1
        sync.telemetry.lastSendChunkFailedKind = tracker.kind
        sync.telemetry.lastSendChunkFailedTarget = tracker.target
    end
    -- un pezzo perso basta a perdere il messaggio: si scrive il primo
    if tracker.failed == 1 then
        Addon:Tracef("sync",
            "send-chunk-failed kind=%s via=%s target=%s at=%s/%s",
            tostring(tracker.kind or "unknown"),
            tostring(tracker.distribution or "unknown"),
            tostring(tracker.target or "-"),
            tostring(sentBytes or "?"),
            tostring(totalBytes or "?")
        )
    end
end

-- I sussurri, un pezzo alla volta.
--
-- AceComm spezza un messaggio lungo e consegna tutti i pezzi insieme a
-- ChatThrottleLib, che li spedisce nello stesso frame finche' ha banda. Il
-- server di Forever i pezzi di un sussurro addon partiti nello stesso istante
-- li scarta, e chi riceve non ricompone niente: vedi WHISPER_PART_GAP_SECONDS
-- in Sync.lua per le misure. In gilda non succede.
--
-- Quindi i sussurri non passano piu' da AceComm: una coda sola spezza ogni
-- messaggio negli stessi pezzi che farebbe AceComm-3.0 (v14) e li affida a
-- ChatThrottleLib uno per volta. Il pezzo dopo parte quando la callback dice
-- che il precedente e' uscito e ne e' passata la distanza: cosi' la distanza
-- vale sul filo, anche quando la libreria tiene i pezzi in coda dietro altro
-- traffico e poi li lascerebbe andare insieme. Un messaggio si finisce prima
-- di cominciarne un altro, perche' chi riceve ricompone un solo messaggio a
-- pezzi alla volta per mittente; fra un messaggio e l'altro passa prima chi
-- ha la priorita' piu' alta. Chi riceve li ricompone con AceComm come sempre,
-- qualunque versione abbia: e' il formato, non il ritmo, che deve conoscere.
local WHISPER_MAX = 255           -- un messaggio intero, come AceComm
local WHISPER_PART = 254          -- un pezzo: 255 meno il byte di posizione
local WHISPER_PRIORITIES = { "ALERT", "NORMAL", "BULK" }

local function nowForPacing()
    return Private.nowForPacing and Private.nowForPacing() or time()
end

-- I pezzi di AceComm-3.0:SendCommMessage. Un messaggio che comincia con un
-- carattere di controllo va preceduto da \004 se ci sta, altrimenti va a pezzi;
-- a pezzi, \001 apre, \002 continua, \003 chiude.
local function splitLikeAceComm(text)
    local control = text:find("^[\001-\009]") ~= nil
    if control and #text + 1 <= WHISPER_MAX then
        return { "\004" .. text }
    end
    if not control and #text <= WHISPER_MAX then
        return { text }
    end
    local parts = { "\001" .. text:sub(1, WHISPER_PART) }
    local pos = 1 + WHISPER_PART
    while pos + WHISPER_PART <= #text do
        parts[#parts + 1] = "\002" .. text:sub(pos, pos + WHISPER_PART - 1)
        pos = pos + WHISPER_PART
    end
    parts[#parts + 1] = "\003" .. text:sub(pos)
    return parts
end
Private.splitWhisperLikeAceComm = splitLikeAceComm

local function whisperQueues(self)
    if not self._whisperQueues then
        self._whisperQueues = { ALERT = {}, NORMAL = {}, BULK = {} }
    end
    return self._whisperQueues
end

-- Un pezzo a ChatThrottleLib, che tiene il conto della banda con gli altri
-- addon e richiama quando il pezzo e' uscito davvero.
function Sync:SendWhisperPart(prefix, text, target, prio, onSent)
    local CTL = _G.ChatThrottleLib
    if CTL and CTL.SendAddonMessage then
        CTL:SendAddonMessage(prio, prefix, text, "WHISPER", target, prefix, function(_, didSend)
            onSent(didSend)
        end, nil)
        return
    end
    local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    local ok = send and pcall(send, prefix, text, "WHISPER", target) or false
    onSent(ok == true)
end

-- Al posto di SendCommMessage per i sussurri, con la stessa callback per pezzo:
-- callbackFn(callbackArg, byteSpediti, byteTotali, didSend).
function Sync:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    if type(text) ~= "string" then
        -- il modo "table-fast" dei test (EncodeWirePayload): niente pezzi
        self:SendCommMessage(prefix, text, "WHISPER", target, prio, callbackFn, callbackArg)
        return true
    end
    local queues = whisperQueues(self)
    local list = queues[prio] or queues.NORMAL
    local parts = splitLikeAceComm(text)
    list[#list + 1] = {
        prefix = prefix, target = target, prio = queues[prio] and prio or "NORMAL",
        parts = parts, nextPart = 1, total = #text,
        callbackFn = callbackFn, callbackArg = callbackArg,
        queuedAt = nowForPacing(),
    }
    self.telemetry.whisperMessagesQueued = (self.telemetry.whisperMessagesQueued or 0) + 1
    self.telemetry.whisperPartsQueued = (self.telemetry.whisperPartsQueued or 0) + #parts
    self:PumpWhisperQueue()
    return true
end

function Sync:GetWhisperQueueDepth()
    local depth = self._whisperCurrent and 1 or 0
    for _, list in pairs(whisperQueues(self)) do
        depth = depth + #list
    end
    return depth
end

function Sync:PumpWhisperQueue()
    if self._whisperInFlight or self._whisperPumpTimer then
        return
    end
    local message = self._whisperCurrent
    if not message then
        local queues = whisperQueues(self)
        for _, prio in ipairs(WHISPER_PRIORITIES) do
            if queues[prio][1] then
                message = table.remove(queues[prio], 1)
                break
            end
        end
        if not message then
            return
        end
        self._whisperCurrent = message
        local waited = nowForPacing() - (message.queuedAt or nowForPacing())
        if waited > (self.telemetry.whisperMaxQueueWait or 0) then
            self.telemetry.whisperMaxQueueWait = waited
        end
    end

    local gap = Constants.WHISPER_PART_GAP_SECONDS or 0.25
    local wait = (self._whisperLastPartAt or -gap) + gap - nowForPacing()
    if wait > 0 then
        self._whisperPumpTimer = self:ScheduleTimer(function()
            self._whisperPumpTimer = nil
            self:PumpWhisperQueue()
        end, wait)
        return
    end

    local index = message.nextPart
    local token = {}
    self._whisperInFlight = token
    local function onSent(didSend)
        if self._whisperInFlight ~= token then
            return
        end
        self._whisperInFlight = nil
        if token.watchdog then
            self:CancelTimer(token.watchdog, true)
            token.watchdog = nil
        end
        self._whisperLastPartAt = nowForPacing()
        self.telemetry.whisperPartsSent = (self.telemetry.whisperPartsSent or 0) + 1
        message.nextPart = index + 1
        -- un pezzo rifiutato perde il messaggio: il resto sarebbe solo banda
        if didSend == false or message.nextPart > #message.parts then
            self._whisperCurrent = nil
        end
        if message.callbackFn then
            local sentBytes = (index == #message.parts) and message.total or math.min(message.total, index * WHISPER_PART)
            local ok, err = pcall(message.callbackFn, message.callbackArg, sentBytes, message.total, didSend)
            if not ok then
                Addon:Tracef("sync", "whisper-callback-error %s", tostring(err))
            end
        end
        self:PumpWhisperQueue()
    end
    token.watchdog = self:ScheduleTimer(function()
        if self._whisperInFlight == token then
            token.watchdog = nil
            self.telemetry.whisperPartStalls = (self.telemetry.whisperPartStalls or 0) + 1
            Addon:Tracef("sync", "whisper-part-stall target=%s part=%d/%d",
                tostring(message.target), index, #message.parts)
            onSent(nil)
        end
    end, Constants.WHISPER_PART_STALL_SECONDS or 15)
    self:SendWhisperPart(message.prefix, message.parts[index], message.target, message.prio, onSent)
end

-- Un rifiuto -- busy all'index diff, BLOCK_PULL_REFUSED -- non passa da
-- CanRunSyncProtocol: si rifiuta proprio quando non si e' pronti, e un seed in
-- warmup che non puo' nemmeno dire "non posso" lascia chi chiede ad aspettare
-- il timeout. E' un sussurro di poche decine di byte.
function Sync:SendRefusalEnvelope(kind, payload, targetKey)
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return false
    end
    local target = self:GetWhisperTarget(targetKey)
    if not target then
        return false
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    local msg = self:EncodeWirePayload(payload)
    if msg then
        self:SendWhisper(PREFIX, msg, target, "ALERT",
            onChunkSent, newSendTracker(kind, "WHISPER", targetKey))
        return true
    end
    return false
end

function Sync:SendGuildEnvelope(kind, payload, priority)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol(kind)
    end
    if not allowed then
        return false
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return false
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    if shouldAttachProtocolCaps(kind) then
        payload.sentAt = time()
        payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
        payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
        payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
        payload.buildId = payload.buildId or Addon.BUILD_ID
        payload.capabilities = payload.capabilities or Addon.CAPABILITIES
        payload.caps = payload.caps or (self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
    end
    local msg = self:EncodeWirePayload(payload)
    if msg then
        self:SendCommMessage(PREFIX, msg, "GUILD", nil, priority or "NORMAL",
            onChunkSent, newSendTracker(kind, "GUILD", nil))
        return true
    end
    return false
end

function Sync:SendDirectEnvelope(kind, payload, targetKey, priority)
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol(kind)
    end
    if not allowed then
        return false
    end
    if self:IsRealTrafficSuppressed() then
        if Addon.MockSync and Addon.MockSync.RecordSuppressedSend then
            Addon.MockSync:RecordSuppressedSend()
        end
        return false
    end
    local target = self:GetWhisperTarget(targetKey)
    if not target then
        return false
    end
    payload.kind = kind
    payload.sender = self:GetSelfKey()
    if shouldAttachProtocolCaps(kind) then
        payload.sentAt = time()
        payload.addonVersion = payload.addonVersion or Addon.ADDON_VERSION or Addon.DISPLAY_VERSION
        payload.wireVersion = payload.wireVersion or Addon.WIRE_VERSION
        payload.buildChannel = payload.buildChannel or Addon.BUILD_CHANNEL
        payload.buildId = payload.buildId or Addon.BUILD_ID
        payload.capabilities = payload.capabilities or Addon.CAPABILITIES
        payload.caps = payload.caps or (self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
    end
    local msg = self:EncodeWirePayload(payload)
    if msg then
        self:SendWhisper(PREFIX, msg, target, priority or "NORMAL",
            onChunkSent, newSendTracker(kind, "WHISPER", targetKey))
        return true
    end
    return false
end

function Sync:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= PREFIX then
        return
    end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then
        return
    end

    local payload = self:DecodeWirePayload(text)
    if type(payload) ~= "table" then
        return
    end
    -- Guild-channel broadcasts loop the sender's own message back to them.
    -- Filter on BOTH `sender` and (for HELLO) `key`: HandleHello uses
    -- payload.key as the canonical identity, so a self-HELLO with a missing
    -- or mangled `sender` field but a correct `key` would still slip
    -- through and trigger a SUMMARY whisper back to ourselves.
    local selfKey = self:GetSelfKey()
    if payload.sender == selfKey then
        return
    end
    if payload.kind == "HELLO" and payload.key == selfKey then
        return
    end

    local peerKey = self:IsValidSyncMemberKey(payload.sender) and payload.sender or nil

    -- Refresh lastSeen on every inbound from a known peer, not just HELLO.
    -- PruneState runs every 5s and wipes onlineNodes + peerVersions for
    -- peers not seen in NODE_TIMEOUT (95s). During a long pull the
    -- requester only sends BLOCK_PULL_REQUEST, never re-HELLOs — so the
    -- seeder used to prune them mid-pull and then reject subsequent
    -- pulls via ShouldAcceptInboundPayload (no peer info -> drop).
    if peerKey and payload.kind ~= "HELLO" then
        self:TouchNode(peerKey, nil)
    end

    if payload.kind == "HELLO" then
        local allowed, dropReason, remoteChannel = self:IsInboundBuildChannelAllowed(payload, sender)
        if not allowed then
            self:RegisterBuildChannelDrop(peerKey or sender, payload, dropReason, remoteChannel)
            return
        end
        if peerKey and self.ObservePeerVersion then
            self:ObservePeerVersion(peerKey, payload)
        end
        if peerKey and self.MaybeNotifyPeerVersion then
            self:MaybeNotifyPeerVersion(peerKey)
        end
        if peerKey and self.ShouldAcceptInboundPayload and not self:ShouldAcceptInboundPayload(payload, peerKey) then
            Addon:Tracef("sync",
                "inbound-dropped kind=%s peer=%s reason=should-accept-rejected",
                tostring(payload.kind or "unknown"),
                tostring(peerKey or "unknown")
            )
            return
        end
    else
        if peerKey and self.ShouldAcceptInboundPayload and not self:ShouldAcceptInboundPayload(payload, peerKey) then
            Addon:Tracef("sync",
                "inbound-dropped kind=%s peer=%s reason=should-accept-rejected",
                tostring(payload.kind or "unknown"),
                tostring(peerKey or "unknown")
            )
            refuseDroppedRequest(self, payload, peerKey, "not-accepted")
            return
        end
    end

    local pauseReason = Addon.SyncPausePolicy and Addon.SyncPausePolicy:GetProtocolPauseReason(payload.kind) or nil
    if pauseReason then
        Addon:Tracef("sync",
            "inbound-dropped kind=%s peer=%s reason=paused:%s",
            tostring(payload.kind or "unknown"),
            tostring(peerKey or payload.sender or "unknown"),
            tostring(pauseReason)
        )
        refuseDroppedRequest(self, payload, peerKey, "paused:" .. tostring(pauseReason))
        return
    end

    if payload.kind == "HELLO" and payload.sender then
        self:TouchNode(payload.sender, payload.addonVersion or payload.version)
    end

    if payload.kind == "HELLO" then
        self:HandleHello(payload, distribution, sender)
    elseif payload.kind == "SUMMARY" then
        self:HandleSummary(payload, distribution, sender)
    elseif payload.kind == "INDEX_DIFF_REQUEST" then
        self:HandleIndexDiffRequest(payload, distribution, sender)
    elseif payload.kind == "INDEX_DIFF_RESPONSE" then
        self:HandleIndexDiffResponse(payload, distribution, sender)
    elseif payload.kind == "BLOCK_PULL_REQUEST" then
        self:HandleBlockPullRequest(payload, distribution, sender)
    elseif payload.kind == "BLOCK_SNAPSHOT" then
        self:HandleBlockSnapshot(payload, distribution, sender)
    elseif payload.kind == "BLOCK_PULL_REFUSED" then
        if self.HandleReceivedBlockPullRefused then
            self:HandleReceivedBlockPullRefused(payload)
        end
    else
        recordUnsupportedMessage(self, payload.kind, payload.sender)
    end
end

function Sync:HandleHello(payload, _distribution, commSender)
    if not self:IsValidSyncMemberKey(payload.key) then
        return
    end
    self._lastHelloSeenAt = self._lastHelloSeenAt or {}
    self._lastHelloSeenAt[payload.key] = time()
    -- l'impronta con cui questo compagno, fra poco, ci manda il suo digest:
    -- e' quella del suo HELLO, perche' ci elegge da questo suo giro
    self._peerHelloFingerprints = self._peerHelloFingerprints or {}
    self._peerHelloFingerprints[payload.key] = payload.globalFingerprint
    if self.RecordPeerCaps then
        self:RecordPeerCaps(payload.sender or payload.key, payload.caps)
    end
    Addon:Tracef("sync",
        "hello-received peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
        tostring(payload.sender or payload.key or "unknown"),
        tostring(payload.helloId or "none"),
        tonumber(payload.activeOwnerCount or 0) or 0,
        tonumber(payload.activeBlockCount or 0) or 0,
        tonumber(payload.activeContentCount or 0) or 0,
        tostring(payload.globalFingerprint or "none")
    )
    local ready, readyReason = true, "ready"
    if self.CanRunSyncProtocol then
        ready, readyReason = self:CanRunSyncProtocol("SUMMARY")
    end
    if not ready then
        Addon:Tracef("sync",
            "summary-suppressed peer=%s reason=%s",
            tostring(payload.sender or payload.key or "unknown"),
            tostring(readyReason or "not-ready")
        )
        return
    end
    local localSummary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "hello-response",
        allowDeferred = true,
    }) or nil
    local peerForSummary = payload.sender or payload.key
    local sterileServe = false
    if shouldSendSummaryForHello(self, payload, localSummary)
        and self._sterilePairs and self._sterilePairs.serve and self._sterilePairs.serve[peerForSummary]
        and self.IsSterilePair
    then
        -- l'ultima volta che ci ha chiesto, con questa sua impronta e con la
        -- nostra, non avevamo niente da dargli: un SUMMARY lo farebbe solo
        -- tornare a chiedere, vedi le coppie sterili in SyncRuntime
        local settled = self:GetSettledLocalFingerprint("hello-response")
        sterileServe = settled ~= nil
            and self:IsSterilePair("serve", peerForSummary, payload.globalFingerprint, settled)
    end
    if sterileServe then
        self.telemetry.summarySuppressedSterile = (self.telemetry.summarySuppressedSterile or 0) + 1
        Addon:Tracef("sync",
            "summary-suppressed peer=%s reason=sterile-pair remoteFp=%s",
            tostring(peerForSummary or "unknown"),
            tostring(payload.globalFingerprint or "nil")
        )
    elseif shouldSendSummaryForHello(self, payload, localSummary) then
        self:SendSummary(peerForSummary, payload.helloId)
    else
        local suppressReason = "unknown"
        if type(localSummary) ~= "table" then
            suppressReason = "local-summary-unavailable"
        elseif tostring(localSummary.indexStatus or "") ~= "ready" then
            suppressReason = "local-index-not-ready:" .. tostring(localSummary.indexStatus or "unknown")
        elseif tostring(payload.indexStatus or "") ~= "ready" then
            suppressReason = "remote-index-not-ready:" .. tostring(payload.indexStatus or "unknown")
        elseif Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("SUMMARY") then
            suppressReason = "paused"
        elseif self.IsSummarySaturated and self:IsSummarySaturated() then
            suppressReason = "saturated"
        elseif tostring(localSummary.globalFingerprint or "") == tostring(payload.globalFingerprint or "") then
            suppressReason = "fingerprints-match"
        end
        Addon:Tracef("sync",
            "summary-suppressed peer=%s reason=%s localFp=%s remoteFp=%s",
            tostring(payload.sender or payload.key or "unknown"),
            suppressReason,
            tostring(localSummary and localSummary.globalFingerprint or "nil"),
            tostring(payload.globalFingerprint or "nil")
        )
    end
    -- dopo la risposta, non prima: il SUMMARY parte con l'impronta che il
    -- mittente ha visto diversa, e la potatura la cambia di nuovo
    applyOwnerProfessionDeclaration(self, payload.key, payload.professions, commSender)
end

function Sync:SendSummary(targetKey, helloId)
    -- Never whisper a SUMMARY to ourselves. The HELLO self-filter in
    -- OnCommReceived should already prevent reaching this path with
    -- targetKey == self, but keep the check here as defense-in-depth: a
    -- self-loop here would burn a whisper, log a "summary-suppressed
    -- fingerprints-match" on the receive side, and waste a hello cycle.
    if targetKey == self:GetSelfKey() then
        return false
    end
    local allowed = true
    if self.CanRunSyncProtocol then
        allowed = self:CanRunSyncProtocol("SUMMARY")
    end
    if not allowed then
        return false
    end
    -- Don't advertise as a seed candidate when our inbound session table is
    -- already at the cap. The requester would just elect us, send
    -- INDEX_DIFF_REQUEST + BLOCK_PULL_REQUESTs, hit RegisterInboundSeedSession
    -- with a "global-cap" rejection, and burn a full cycle on both sides
    -- waiting for a snapshot that will never arrive. Stay silent until a
    -- slot frees; the requester's discoveryRetry timer (or its next natural
    -- HELLO) brings it back later when we can actually serve.
    if self.PruneInboundSeedSessions then
        self:PruneInboundSeedSessions()
    end
    local inboundCap = self.GetMaxInboundSeedSessions and self:GetMaxInboundSeedSessions() or 0
    local inboundActive = self.GetInboundSeedSessionCount and self:GetInboundSeedSessionCount() or 0
    if inboundCap > 0 and inboundActive >= inboundCap then
        self.telemetry.summarySuppressedAtCap = (self.telemetry.summarySuppressedAtCap or 0) + 1
        if self.RecordSyncEvent then
            self:RecordSyncEvent("summarySuppressed", {
                peer = targetKey,
                requestId = helloId,
                reason = "inbound-cap",
                extra = string.format("active=%d/%d", inboundActive, inboundCap),
            })
        end
        return false
    end
    local summary = Addon.Data and Addon.Data.BuildLocalSummary and Addon.Data:BuildLocalSummary({
        reason = "summary-send",
        allowDeferred = true,
    }) or nil
    if type(summary) ~= "table" or tostring(summary.indexStatus or "") ~= "ready" then
        return false
    end
    local sent = self:SendDirectEnvelope("SUMMARY", {
        helloId = helloId,
        activeOwnerCount = summary.activeOwnerCount or 0,
        activeBlockCount = summary.activeBlockCount or 0,
        activeContentCount = summary.activeContentCount or 0,
        globalFingerprint = summary.globalFingerprint,
        professions = localProfessionDeclaration(),
    }, targetKey, "ALERT")
    if sent then
        self.telemetry.summarySent = (self.telemetry.summarySent or 0) + 1
        self.telemetry.lastSummaryPeer = tostring(targetKey or "unknown")
        if self.RecordSyncEvent then
            self:RecordSyncEvent("summarySent", {
                peer = targetKey,
                requestId = helloId,
                extra = tostring(summary.globalFingerprint or "none"),
            })
        end
        Addon:Tracef("sync",
            "summary-sent peer=%s helloId=%s owners=%d blocks=%d content=%d fingerprint=%s",
            tostring(targetKey or "unknown"),
            tostring(helloId or "none"),
            tonumber(summary.activeOwnerCount or 0) or 0,
            tonumber(summary.activeBlockCount or 0) or 0,
            tonumber(summary.activeContentCount or 0) or 0,
            tostring(summary.globalFingerprint or "none")
        )
    end
    return sent
end

function Sync:HandleSummary(payload, _distribution, commSender)
    local peerKey = self:IsValidSyncMemberKey(payload.sender) and payload.sender or nil
    if not peerKey then
        return
    end
    if not self:GetPeerVersionInfo(peerKey) and self.ObservePeerVersion then
        -- SUMMARY is allowed to arrive as a direct reply to our active HELLO before
        -- that peer has emitted its own HELLO. Prime provisional peer metadata from
        -- the local build so the current handshake can continue without widening
        -- the wire payload.
        self:ObservePeerVersion(peerKey, {
            sender = peerKey,
            addonVersion = Addon.ADDON_VERSION or Addon.DISPLAY_VERSION,
            wireVersion = Addon.WIRE_VERSION,
            buildChannel = Addon.BUILD_CHANNEL,
            buildId = Addon.BUILD_ID,
            caps = self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil,
            _skipAddonPeerMemory = true,
        })
        if self.RecordPeerCaps then
            self:RecordPeerCaps(peerKey, self.GetLocalProtocolCaps and self:GetLocalProtocolCaps() or nil)
        end
    end
    if self.RecordSummary then
        self:RecordSummary(peerKey, payload)
    end
    applyOwnerProfessionDeclaration(self, peerKey, payload.professions, commSender)
end

function Sync:HandleIndexDiffRequest(payload)
    if not (payload and self:IsValidSyncMemberKey(payload.sender)) then
        return
    end
    self.telemetry.indexDiffRequestReceived = (self.telemetry.indexDiffRequestReceived or 0) + 1
    if self.RecordSyncEvent then
        self:RecordSyncEvent("indexDiffRequestReceived", {
            peer = payload.sender,
            requestId = payload.requestId,
            extra = string.format("blocks=%d", type(payload.blocks) == "table" and Private.countKeys(payload.blocks) or 0),
        })
    end
    Addon:Tracef("sync",
        "index-diff-request-received peer=%s requestId=%s blocks=%d",
        tostring(payload.sender or "unknown"),
        tostring(payload.requestId or "none"),
        type(payload.blocks) == "table" and Private.countKeys(payload.blocks) or 0
    )
    -- Ogni "no" qui sotto risponde con un busy e il suo motivo. Fino alla 0.1.5
    -- erano return muti: chi chiedeva aspettava 60 s, e il seed non ne
    -- scriveva nemmeno il motivo nel log.
    if self.CanServeInboundSeed then
        local allowed, serveReason = self:CanServeInboundSeed(payload.sender)
        if not allowed then
            local reason = "not-ready:" .. tostring(serveReason or "not-ready")
            Addon:Tracef("sync",
                "index-diff-refused peer=%s requestId=%s reason=%s",
                tostring(payload.sender or "unknown"),
                tostring(payload.requestId or "none"),
                reason
            )
            self:SendIndexDiffBusy(payload.sender, payload, reason)
            return
        end
    end

    local response = self.BuildIndexDiffResponseForRequest and self:BuildIndexDiffResponseForRequest(payload) or nil
    if type(response) ~= "table" or response.ready ~= true then
        local reason = "index-not-ready:" .. tostring(type(response) == "table" and response.indexStatus or "none")
        Addon:Tracef("sync",
            "index-diff-refused peer=%s requestId=%s reason=%s",
            tostring(payload.sender or "unknown"),
            tostring(payload.requestId or "none"),
            reason
        )
        self:SendIndexDiffBusy(payload.sender, payload, reason)
        return
    end

    local offeredBlocks = response.offeredBlocks or {}
    local reserved = false
    if #offeredBlocks > 0 and self.RegisterInboundSeedSession then
        local session, reserveReason = self:RegisterInboundSeedSession(payload.sender, payload.requestId, offeredBlocks)
        if not session then
            if self.SendIndexDiffBusy then
                self:SendIndexDiffBusy(payload.sender, payload, reserveReason or "seed-busy")
            end
            return
        end
        reserved = true
    end

    if self.SendPreparedIndexDiffResponse then
        local sent = self:SendPreparedIndexDiffResponse(payload.sender, payload, response)
        if not sent then
            if reserved and self.ClearInboundSeedSession then
                self:ClearInboundSeedSession(payload.sender, payload.requestId, "index-diff-send-failed")
            end
            self:SendIndexDiffBusy(payload.sender, payload, "response-not-sent")
        elseif #offeredBlocks == 0 and self.RecordSterilePair then
            -- niente da dargli: con queste due impronte non ci sara' mai, e il
            -- prossimo HELLO uguale non riceve il SUMMARY che lo farebbe tornare
            local requesterFp = self._peerHelloFingerprints and self._peerHelloFingerprints[payload.sender] or nil
            local settled = self:GetSettledLocalFingerprint("index-diff-serve")
            self:RecordSterilePair("serve", payload.sender, requesterFp, settled, "no-offer")
        end
    end
end

function Sync:HandleIndexDiffResponse(payload)
    if self.HandleReceivedIndexDiffResponse then
        self:HandleReceivedIndexDiffResponse(payload)
    end
end

function Sync:HandleBlockPullRequest(payload)
    local senderKey = payload and payload.sender
    local blockKey = payload and payload.blockKey
    local requestId = payload and payload.requestId
    local protoAllowed, protoReason = true, "ready"
    if self.CanRunSyncProtocol then
        protoAllowed, protoReason = self:CanRunSyncProtocol("BLOCK_SNAPSHOT")
    end
    if not protoAllowed then
        Addon:Tracef("sync",
            "block-pull-rejected peer=%s block=%s requestId=%s reason=protocol-gate:%s",
            tostring(senderKey or "unknown"),
            tostring(blockKey or "none"),
            tostring(requestId or "none"),
            tostring(protoReason or "not-ready")
        )
        -- da qui in giu' ogni rifiuto lo dice a chi chiede: vedi
        -- SendBlockPullRefused in SyncTransfer
        self:SendBlockPullRefused(senderKey, payload, "not-ready:" .. tostring(protoReason or "not-ready"))
        return
    end
    if self.CanServeInboundSeed then
        local serveAllowed, serveReason = self:CanServeInboundSeed(senderKey)
        if not serveAllowed then
            Addon:Tracef("sync",
                "block-pull-rejected peer=%s block=%s requestId=%s reason=serve-gate:%s",
                tostring(senderKey or "unknown"),
                tostring(blockKey or "none"),
                tostring(requestId or "none"),
                tostring(serveReason or "not-ready")
            )
            self:SendBlockPullRefused(senderKey, payload, "not-ready:" .. tostring(serveReason or "not-ready"))
            return
        end
    end
    local inboundSession = self.GetInboundSeedSession and self:GetInboundSeedSession(senderKey) or nil
    if not inboundSession then
        self.telemetry.inboundBlockPullRejectedUnknownRequest = (self.telemetry.inboundBlockPullRejectedUnknownRequest or 0) + 1
        if self.RecordSyncEvent then
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = senderKey,
                requestId = requestId,
                reason = "unknown-request",
                blockKey = blockKey,
            })
        end
        Addon:Tracef("sync",
            "block-pull-rejected peer=%s block=%s requestId=%s reason=unknown-request",
            tostring(senderKey or "unknown"),
            tostring(blockKey or "none"),
            tostring(requestId or "none")
        )
        -- la sessione non c'e' piu' -- scaduta, o chiusa da un warmup o da
        -- un'istanza: per chi chiede e' il seed a non potere, non il blocco
        self:SendBlockPullRefused(senderKey, payload, "unknown-request")
        return
    end
    if type(inboundSession.offeredBlocks) == "table" and inboundSession.offeredBlocks[blockKey] ~= true then
        self.telemetry.inboundBlockPullRejectedNotOffered = (self.telemetry.inboundBlockPullRejectedNotOffered or 0) + 1
        if self.RecordSyncEvent then
            self:RecordSyncEvent("inboundSeedSessionRejected", {
                peer = senderKey,
                requestId = requestId,
                reason = "block-not-offered",
                blockKey = blockKey,
            })
        end
        Addon:Tracef("sync",
            "block-pull-rejected peer=%s block=%s requestId=%s reason=block-not-offered offered=%d",
            tostring(senderKey or "unknown"),
            tostring(blockKey or "none"),
            tostring(requestId or "none"),
            tonumber(inboundSession.offeredBlockCount or 0) or 0
        )
        self:SendBlockPullRefused(senderKey, payload, "block-not-offered")
        return
    end
    inboundSession.lastActivity = time()
    inboundSession.servedBlocks = tonumber(inboundSession.servedBlocks or 0) or 0
    if self.SendBlockSnapshot then
        local sent, notSentReason = self:SendBlockSnapshot(payload and payload.sender, payload)
        if not sent then
            Addon:Tracef("sync",
                "block-pull-rejected peer=%s block=%s requestId=%s reason=%s",
                tostring(senderKey or "unknown"),
                tostring(blockKey or "none"),
                tostring(requestId or "none"),
                tostring(notSentReason or "send-failed")
            )
            self:SendBlockPullRefused(senderKey, payload, tostring(notSentReason or "send-failed"))
        end
        if sent then
            inboundSession.servedBlocks = inboundSession.servedBlocks + 1
            inboundSession.lastActivity = time()
            inboundSession.state = "serving"
            self.telemetry.lastInboundRequester = payload and payload.sender or self.telemetry.lastInboundRequester
            self.telemetry.lastInboundRequestId = payload and payload.requestId or self.telemetry.lastInboundRequestId
            self.telemetry.lastInboundServedBlockKey = payload and payload.blockKey or self.telemetry.lastInboundServedBlockKey
            -- The session has served every block it ever offered: it's
            -- finished. Free the cap slot immediately instead of waiting
            -- for the 60s inactivity prune. The natural session timeout
            -- stays in place as a safety net for requesters that abandon
            -- mid-pull (we never clear sessions whose servedBlocks is
            -- still short of offeredBlockCount).
            local offered = tonumber(inboundSession.offeredBlockCount or 0) or 0
            if offered > 0 and inboundSession.servedBlocks >= offered then
                inboundSession.state = "completed"
                inboundSession.completedAt = time()
                local sessions = self.inboundSeedSessions and self.inboundSeedSessions[senderKey] or nil
                if sessions then
                    sessions[inboundSession.requestId] = nil
                    if next(sessions) == nil then
                        self.inboundSeedSessions[senderKey] = nil
                    end
                end
                if self.GetInboundSeedSessionCount then
                    self.telemetry.inboundSeedSessionsActive = self:GetInboundSeedSessionCount()
                end
                self.telemetry.inboundSeedSessionsCompleted = (self.telemetry.inboundSeedSessionsCompleted or 0) + 1
                if self.RecordSyncEvent then
                    self:RecordSyncEvent("inboundSeedSessionCompleted", {
                        peer = senderKey,
                        requestId = inboundSession.requestId,
                        extra = string.format("served=%d/%d", inboundSession.servedBlocks, offered),
                    })
                end
            end
        end
    end
end

function Sync:HandleBlockSnapshot(payload)
    if self.HandleReceivedBlockSnapshot then
        self:HandleReceivedBlockSnapshot(payload)
    end
end
