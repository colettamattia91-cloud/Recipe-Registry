local Addon = _G.RecipeRegistry
if not Addon then
    return
end

local Diagnostics = Addon:NewModule("RecipeMetadataDiagnostics")
Addon.RecipeMetadataDiagnostics = Diagnostics

function Diagnostics:PrintVersion()
    local metadata = Addon.RecipeMetadata or {}
    Addon:Print(string.format(
        "RecipeRegistry metadata %s; schema %s; flavor %s",
        tostring(metadata.metadataVersion or "unknown"),
        tostring(metadata.schemaVersion or "unknown"),
        tostring(metadata.flavor or "unknown")
    ))
end

function Diagnostics:PrintDiagnostics()
    local metadata = Addon.RecipeMetadata
    local counts = metadata and metadata:GetRecordCounts() or {}
    Addon:Print(string.format(
        "metadataVersion=%s schema=%s flavor=%s recipes=%d vanilla=%d tbc=%d unresolved=%d ambiguousCreatedItems=%d recipeItems=%d createdItems=%d overrides=%d",
        tostring(metadata and metadata.metadataVersion or "unknown"),
        tostring(metadata and metadata.schemaVersion or "unknown"),
        tostring(metadata and metadata.flavor or "unknown"),
        counts.recipes or 0,
        counts.vanilla or 0,
        counts.tbc or 0,
        counts.unresolved or 0,
        counts.ambiguousCreatedItems or 0,
        counts.recipeItems or 0,
        counts.createdItems or 0,
        counts.overrides or 0
    ))
end
