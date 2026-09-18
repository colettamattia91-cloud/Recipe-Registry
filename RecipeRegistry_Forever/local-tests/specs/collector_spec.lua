-- The collector exports the complete catalog and never touches ownership.
local handler
CreateFrame = function()
    return {
        RegisterEvent = function() end,
        UnregisterEvent = function() end,
        SetScript = function(_, _, callback) handler = callback end,
    }
end
SlashCmdList = {}
date = os.date
GetBuildInfo = function() return "1.60.1", "69913" end
RecipeRegistryDB = { global = { members = { sentinel = true } } }
RecipeRegistryCharDB = { favorites = { [42] = true } }
local broken, ready = false, true
C_TradeSkillUI = {
    IsTradeSkillReady = function() return ready end,
    GetAllRecipeIDs = function() return { 7183, 22430 } end,
    GetBaseProfessionInfo = function() return { professionName = "Alchemy" } end,
    GetRecipeInfo = function(id)
        if broken and id == 22430 then return nil end
        return { name = "Recipe", learned = id == 7183, categoryID = 2450 }
    end,
    GetRecipeSchematic = function(id)
        return { outputItemID = id + 1, reagentSlotSchematics = {
            { quantityRequired = 2, required = true, reagents = { { itemID = 765 }, { itemID = 2447 } } },
        } }
    end,
    GetCategoryInfo = function(id) return { categoryID = id, name = "Elixirs" } end,
}
assert(loadfile("Tools/RecipeRegistry_Forever_Collector/Collector.lua"))("RecipeRegistry_Forever_Collector")
handler({ UnregisterEvent = function() end }, "ADDON_LOADED", "RecipeRegistry_Forever_Collector")
SlashCmdList.RRDUMP("")
local saved = RecipeRegistryDumpDB.dumps.Alchemy
assert(#saved.recipes == 2, "unlearned recipes must be included")
assert(#saved.recipes[1].reagentSlotSchematics[1].reagents == 2, "preserve reagent alternatives")
broken = true
SlashCmdList.RRDUMP("")
assert(RecipeRegistryDumpDB.dumps.Alchemy == saved, "partial captures must not replace a valid dump")
ready = false
SlashCmdList.RRDUMP("")
assert(RecipeRegistryDumpDB.dumps.Alchemy == saved, "closed sessions must not replace a valid dump")
assert(RecipeRegistryDB.global.members.sentinel == true)
assert(RecipeRegistryCharDB.favorites[42] == true)
assert(next(RecipeRegistryDB.global.members, "sentinel") == nil, "ownership must remain untouched")
print("PASS collector: complete catalog, partial rejection, ownership isolation")
