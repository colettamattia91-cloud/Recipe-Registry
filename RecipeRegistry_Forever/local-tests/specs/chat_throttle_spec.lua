-- ChatThrottleLib davanti a un valore segreto.
--
-- La libreria aggancia SendChatMessage e SendAddonMessage per contare i byte
-- che passano: non spedisce niente, conta. Gli agganci pero' sono nostri, e un
-- errore dentro di loro lo prende il nostro addon. Su questo client il testo di
-- una riga di chat scritta dal giocatore e' un "secret value", misurarlo o
-- convertirlo e' un errore, e chi scriveva in chat vedeva
-- "execution tainted by 'RecipeRegistry_Forever'" a ogni riga.
--
-- La v32 della libreria lo gestisce a monte: se il client espone issecretvalue,
-- gli agganci lasciano perdere il messaggio invece di misurarlo. Noi avevamo la
-- v31. Questo spec sta qui perche' la libreria e' un file copiato: il giorno in
-- cui qualcuno la riporta indietro, o la sostituisce con una copia vecchia
-- presa altrove, il test cade prima che lo faccia un giocatore.
--
-- Un valore segreto, qui, e' una tabella che esplode se la si misura o la si
-- converte: e' cio' che il client fa con i suoi.

local frames = {}
_G.CreateFrame = function()
  local f = {}
  function f:SetScript() end
  function f:RegisterEvent() end
  function f:UnregisterEvent() end
  function f:Show() end
  function f:Hide() end
  function f:IsShown() return false end
  frames[#frames + 1] = f
  return f
end
_G.hooksecurefunc = function() end
_G.GetTime = function() return 1000 end
_G.GetFramerate = function() return 60 end
_G.SendChatMessage = function() end
_G.SendAddonMessage = function() end
_G.IsLoggedIn = function() return true end
_G.C_ChatInfo = { SendAddonMessage = function() end }
_G.Enum = { SendAddonMessageResult = { Success = 0 } }
table.wipe = table.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local secret = setmetatable({}, {
  __tostring = function() error("attempt to perform string conversion on a secret string value", 0) end,
  __len = function() error("attempt to get length of a secret string value", 0) end,
})
-- come il client: risponde true solo per i suoi valori segreti
_G.issecretvalue = function(value) return value == secret end

dofile("Libs/AceComm-3.0/ChatThrottleLib.lua")
local CTL = _G.ChatThrottleLib

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-52s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

print("== la libreria e' quella che sa dei valori segreti ==")
t("versione", CTL.version >= 32, true)

print("\n== una riga di chat normale: si conta davvero ==")
local before = CTL.avail
local ok = pcall(CTL.Hook_SendChatMessage, "ciao", "WHISPER", nil, "Kaedros Davian")
t("l'aggancio non solleva", ok, true)
t("byte contati", before - CTL.avail, 4 + 14 + CTL.MSG_OVERHEAD)

print("\n== testo segreto: si lascia perdere, non si esplode ==")
before = CTL.avail
ok = pcall(CTL.Hook_SendChatMessage, secret, "SAY", nil, nil)
t("l'aggancio non solleva", ok, true)
t("niente contato", before - CTL.avail, 0)

print("\n== destinatario segreto ==")
before = CTL.avail
ok = pcall(CTL.Hook_SendChatMessage, "ciao", "WHISPER", nil, secret)
t("l'aggancio non solleva", ok, true)
t("niente contato", before - CTL.avail, 0)

print("\n== lo stesso per i messaggi fra addon ==")
before = CTL.avail
ok = pcall(CTL.Hook_SendAddonMessage, "RRDEV", secret, "GUILD", nil)
t("l'aggancio non solleva", ok, true)
t("niente contato", before - CTL.avail, 0)

print("\n== i nostri messaggi si contano come prima ==")
before = CTL.avail
ok = pcall(CTL.Hook_SendAddonMessage, "RRDEV", "HELLO", "GUILD", nil)
t("l'aggancio non solleva", ok, true)
t("byte contati", before - CTL.avail, 5 + 5 + CTL.MSG_OVERHEAD)

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
