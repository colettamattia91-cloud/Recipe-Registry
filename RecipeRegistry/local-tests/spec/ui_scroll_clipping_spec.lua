-- Guards the shape of the fix for the missing central scrollbar.
--
-- UIPanelScrollFrameTemplate builds its ScrollBar as a CHILD of the
-- ScrollFrame, anchored just OUTSIDE the ScrollFrame's right edge. So
-- calling SetClipsChildren on the ScrollFrame itself clips the scrollbar
-- away along with the row overflow it was meant to hide. Overflow must be
-- clipped by a container frame that spans the viewport AND the scrollbar
-- lane, with the ScrollFrame inset from its right edge by that lane.
local Test = dofile("local-tests/harness/test.lua")

local MAIN_FRAME = "UI/MainFrame.lua"

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local source = readFile(MAIN_FRAME)

-- name -> parent frame name, for every UIPanelScrollFrameTemplate scroll.
local function collectTemplateScrolls()
    local scrolls = {}
    local pattern = 'local%s+([%w_]+)%s*=%s*CreateFrame%(%s*"ScrollFrame"%s*,%s*[^,]+,%s*([%w_]+)%s*,%s*"UIPanelScrollFrameTemplate"%s*%)'
    for name, parent in source:gmatch(pattern) do
        scrolls[name] = parent
    end
    return scrolls
end

io.write("UI scroll clipping\n")

Test.it("clips scroll overflow on a container, never on the ScrollFrame itself", function()
    local scrolls = collectTemplateScrolls()
    Test.truthy(next(scrolls) ~= nil, "expected at least one UIPanelScrollFrameTemplate scroll frame")

    local violations = {}
    for name in pairs(scrolls) do
        if source:find(name .. ":SetClipsChildren", 1, true) then
            violations[#violations + 1] = string.format(
                "%s calls SetClipsChildren on itself, which clips its own ScrollBar away",
                name
            )
        end
    end

    Test.eq(#violations, 0, table.concat(violations, "\n"))
end)

Test.it("reserves a scrollbar lane wide enough for the template bar", function()
    local lane = source:match("local%s+SCROLLBAR_LANE%s*=%s*(%d+)")
    Test.truthy(lane ~= nil, "SCROLLBAR_LANE constant should exist")
    Test.gte(tonumber(lane), 16, "scrollbar lane must fit the 16px template ScrollBar")
end)

Test.it("parents the recipe and detail scrolls to a clipping container inset by the lane", function()
    local scrolls = collectTemplateScrolls()

    for _, scrollName in ipairs({ "recipeScroll", "detailScroll" }) do
        local parent = scrolls[scrollName]
        Test.truthy(parent ~= nil, scrollName .. " should be built from UIPanelScrollFrameTemplate")
        Test.truthy(
            source:find(parent .. ":SetClipsChildren(true)", 1, true) ~= nil,
            string.format("%s's parent %s should clip its children", scrollName, parent)
        )
        Test.truthy(
            source:find(scrollName .. ':SetPoint("BOTTOMRIGHT", -SCROLLBAR_LANE, 0)', 1, true) ~= nil,
            string.format("%s should be inset from %s's right edge by SCROLLBAR_LANE", scrollName, parent)
        )
    end
end)

io.write(string.format("UI scroll clipping: %d test(s) passed\n", Test.count))
