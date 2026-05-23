local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local addon = Loader.LoadMetadata()
local metadata = addon.RecipeMetadata

Test.it("ships generated metadata without unresolved records", function()
    local unresolved = metadata:GetUnresolvedRecords()
    local counts = metadata:GetRecordCounts()

    Test.eq(#unresolved, 0)
    Test.eq(counts.unresolved, 0)
    Test.eq(metadata:GetMetadataResolutionStatus(-28596), "resolved")
    Test.eq(metadata:GetMetadataResolutionStatus(21840), "ambiguous")
    Test.eq(metadata:GetMetadataResolutionStatus(123456789), "unresolved")
end)

Test.it("reports release-blocking and warning fields for incomplete records", function()
    metadata._recordsBySpellId[99999] = {
        spellId = 99999,
        profession = "",
        selfOnlyOutputless = false,
        reagents = {},
    }

    local all = metadata:GetUnresolvedRecords()
    local blocking = metadata:GetUnresolvedRecords("release-blocking")
    local warnings = metadata:GetUnresolvedRecords("warning")

    Test.eq(metadata:GetMetadataResolutionStatus(-99999), "unresolved")
    Test.eq(#all, 6)
    Test.eq(#blocking, 4)
    Test.eq(#warnings, 2)
    Test.eq(blocking[1].spellId, 99999)
    Test.eq(blocking[1].severity, "release-blocking")
    Test.eq(warnings[1].severity, "warning")
end)

Test.it("keeps outputless self-only records from requiring created output", function()
    metadata._recordsBySpellId[99999] = nil
    metadata._recordsBySpellId[99998] = {
        spellId = 99998,
        profession = "enchanting",
        expansion = "tbc",
        category = "enchanting",
        sortOrder = 99,
        selfOnlyOutputless = true,
        reagents = {},
    }

    local unresolved = metadata:GetUnresolvedRecords()
    Test.eq(#unresolved, 0)
    Test.eq(metadata:GetMetadataResolutionStatus(-99998), "resolved")
end)
