-- I tooltip su Forever.
--
-- Il client beta risponde cosi', sondato in gioco il 2026-09-21:
--   TooltipDataProcessor -> table, TooltipUtil -> table,
--   GameTooltip.GetItem  -> function, ma lo script OnTooltipSetItem non c'e'.
-- Con i soli script legacy arrivati da TBC l'addon non si agganciava a niente e
-- i crafter non comparivano mai, senza un errore. Il GameTooltip finto qui sotto
-- e' quello: ha GetItem e non ha lo script. Se qualcuno rimettesse il percorso
-- legacy al posto di quello retail, questo spec lo direbbe.

local modules = {}
local function freshAddon()
  modules = {}
  _G.RecipeRegistry = {
    NewModule = function(_, name)
      local m = { RegisterEvent = function() end, CancelTimer = function() end }
      modules[name] = m
      return m
    end,
    Data = { GetMemberKeyName = function(_, key) return key end },
    db = { profile = {} },
  }
end

local function makeTooltip(name)
  local tt = { name = name, lines = {}, forbidden = false }
  function tt:AddLine(text) self.lines[#self.lines + 1] = text end
  function tt:Show() end
  function tt:IsForbidden() return self.forbidden end
  -- come sul client: l'accessore c'e', lo script no
  function tt:GetItem() return nil, nil end
  function tt:HasScript(script) return script == "OnTooltipCleared" end
  function tt:HookScript() error("nessuno deve agganciare script legacy su Forever") end
  return tt
end

local postCalls
local function installRetailPipeline()
  postCalls = {}
  _G.Enum = { TooltipDataType = { Item = 0, Spell = 1 } }
  _G.TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn) postCalls[dataType] = fn end,
  }
  _G.TooltipUtil = {
    GetDisplayedItem = function() return "Refined Scale of Onyxia", "|Hitem:17967::::::::|h[x]|h", nil end,
    GetDisplayedSpell = function() return "Elixir of Minor Defense", 7183 end,
  }
end

local function loadTooltip()
  _G.GameTooltip = makeTooltip("GameTooltip")
  _G.ItemRefTooltip = makeTooltip("ItemRefTooltip")
  dofile("UI/Tooltip.lua")
  local Tooltip = _G.RecipeRegistry.Tooltip
  Tooltip:OnEnable()
  return Tooltip
end

local fails = 0
local function t(label, got, want)
  local ok = (got == want)
  if not ok then fails = fails + 1 end
  print(string.format("%-4s %-52s %s", ok and "ok" or "FAIL", label, tostring(got)))
end

freshAddon()
installRetailPipeline()
local Tooltip = loadTooltip()

print("== si aggancia alla pipeline retail ==")
t("agganciato", Tooltip._tooltipHooksRegistered, true)
t("post-call sugli oggetti", type(postCalls[0]), "function")
t("post-call sugli incantesimi", type(postCalls[1]), "function")

print("\n== le righe tornano a ogni ricostruzione del tooltip ==")
-- Il caso che la chiave anti-doppione rompeva: il gioco svuota il tooltip e lo
-- ricostruisce, la post-call riparte, e le nostre righe devono ricomparire.
Tooltip.GetRowsForItemID = function()
  return { { memberKey = "Kaedros", profession = "Alchemy", online = true } }, "item:5997"
end
postCalls[0](GameTooltip, { id = 5997 })
local firstBuild = #GameTooltip.lines
GameTooltip.lines = {}                     -- il gioco svuota e ricostruisce
postCalls[0](GameTooltip, { id = 5997 })
t("righe alla prima costruzione", firstBuild > 0, true)
t("e di nuovo alla seconda", #GameTooltip.lines, firstBuild)

print("\n== chi riceve le righe, e chi no ==")
local seen
Tooltip.OnTooltipSetItem = function(_, tooltip, itemID) seen = { tooltip = tooltip, id = itemID } end
Tooltip.OnTooltipSetSpell = function(_, tooltip, spellID) seen = { tooltip = tooltip, id = spellID } end

seen = nil; postCalls[0](ItemRefTooltip, { id = 5997 })
t("il tooltip dei link cliccati", seen and seen.id, 5997)

seen = nil; postCalls[0](makeTooltip("ShoppingTooltip1"), { id = 5997 })
t("un tooltip che non guardiamo: niente", seen, nil)

GameTooltip.forbidden = true
seen = nil; postCalls[0](GameTooltip, { id = 5997 })
t("un tooltip protetto: niente", seen, nil)
GameTooltip.forbidden = false

print("\n== da dove prende l'ID ==")
seen = nil; postCalls[0](GameTooltip, nil)
t("oggetto senza dati: dal link di TooltipUtil", seen and seen.id, 17967)

seen = nil; postCalls[1](GameTooltip, { id = 7183 })
t("incantesimo dai dati", seen and seen.id, 7183)

seen = nil; postCalls[1](GameTooltip, nil)
t("incantesimo senza dati: da TooltipUtil", seen and seen.id, 7183)

print("\n== senza pipeline non si aggancia, e non esplode ==")
freshAddon()
_G.TooltipDataProcessor = nil
local bare = loadTooltip()
t("niente TooltipDataProcessor: non agganciato", bare._tooltipHooksRegistered, nil)

freshAddon()
installRetailPipeline()
_G.Enum = nil
bare = loadTooltip()
t("niente Enum.TooltipDataType: non agganciato", bare._tooltipHooksRegistered, nil)

print(fails == 0 and "\nTUTTO OK" or ("\n" .. fails .. " FALLITI"))
os.exit(fails == 0 and 0 or 1)
