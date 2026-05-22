local ADDON_NAME = ...

local addon = {
    name = ADDON_NAME,
    version = "0.1.0-skeleton",
}
_G.RecipeRegistry_Orders = addon

local rr = _G.RecipeRegistry
if rr then
    addon._rrSeen = true
    addon._rrVersionAtLoad = rr.ADDON_VERSION or rr.DISPLAY_VERSION or "?"
    if type(rr.Print) == "function" then
        rr:Print(string.format(
            "Craft Orders skeleton loaded (RR=%s). Real plugin starts in Phase 1.",
            tostring(addon._rrVersionAtLoad)
        ))
    end
elseif DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffff5555RecipeRegistry_Orders error:|r RecipeRegistry not loaded — check TOC dependency."
    )
end
