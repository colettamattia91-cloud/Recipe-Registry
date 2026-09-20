local Addon = _G.RecipeRegistry

-- Patch 2.5.6 moved the TBC Anniversary client onto the modern addon API
-- (Blizzard aligns it with Classic Era 1.15.9): the item/spell info globals
-- now live in the C_Item / C_Spell namespaces, and C_Spell.GetSpellInfo
-- returns a struct instead of the classic tuple. These wrappers expose the
-- classic positional signatures over whichever backend the client offers.
--
-- Dispatch is lazy (the backend is looked up on every call rather than
-- frozen at load) because load order matters both in game and in the
-- offline harness, where specs inject stub globals after the addon files
-- load. The extra lookup is trivial next to the API call itself.
local Compat = {}
Addon.Compat = Compat

function Compat.GetItemInfo(...)
    local api = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if not api then return nil end
    return api(...)
end

function Compat.GetItemInfoInstant(...)
    local api = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not api then return nil end
    return api(...)
end

function Compat.GetSpellTexture(spellID)
    local api = (C_Spell and C_Spell.GetSpellTexture) or _G.GetSpellTexture
    if not api then return nil end
    return api(spellID)
end

function Compat.GetSpellLink(spellID)
    local api = (C_Spell and C_Spell.GetSpellLink) or _G.GetSpellLink
    if not api then return nil end
    return api(spellID)
end

function Compat.GetSpellInfo(spellID)
    local structApi = C_Spell and C_Spell.GetSpellInfo
    if structApi then
        local info = structApi(spellID)
        if not info then return nil end
        -- Classic tuple: name, rank, icon, castTime, minRange, maxRange,
        -- spellID. Rank has no C_Spell equivalent and no call site reads it.
        return info.name, nil, info.iconID, info.castTime, info.minRange, info.maxRange, info.spellID
    end
    local api = _G.GetSpellInfo
    if not api then return nil end
    return api(spellID)
end
