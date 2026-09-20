local Addon = _G.RecipeRegistry
local BootstrapSync = Addon:NewModule("BootstrapSync")
Addon.BootstrapSync = BootstrapSync

local pairs = pairs

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

-- Quel che resta del bootstrap: dice alla UI se servirebbe, non lo esegue.
-- La scoperta del seed, la richiesta e i chunk erano un macchinario che nessuno
-- chiamava -- il sync additivo di Wire v3 arriva allo stesso risultato da solo,
-- un blocco per volta -- quindi di quello stato restano i campi che GetUiState
-- legge davvero.
function BootstrapSync:OnInitialize()
    self.discovery = { candidates = {} }
    self.session = {
        activeSeed = nil,
        inProgress = false,
        completedAt = 0,
    }
end

function BootstrapSync:CanBootstrap()
    if not IsInGuild() then return false end
    if not Addon.Data or not Addon.Data.IsBootstrapNeeded then return false end
    if self.session.inProgress then return false end
    local completedAt = self.session.completedAt
    if Addon.Data and Addon.Data.GetGlobalMeta then
        completedAt = Addon.Data:GetGlobalMeta().bootstrapCompletedAt or completedAt
    end
    if completedAt and completedAt > 0 then return false end
    return Addon.Data:IsBootstrapNeeded()
end

function BootstrapSync:GetUiState()
    return {
        canBootstrap = self:CanBootstrap(),
        inProgress = self.session.inProgress,
        completed = self.session.completedAt and self.session.completedAt > 0 or false,
        activeSeed = self.session.activeSeed,
        candidateCount = countKeys(self.discovery.candidates),
    }
end
