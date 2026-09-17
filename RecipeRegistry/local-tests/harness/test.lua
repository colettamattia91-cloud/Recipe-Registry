local Test = {
    count = 0,
}

local function fail(message, level)
    error(message or "assertion failed", (level or 1) + 1)
end

function Test.it(name, fn)
    io.write("  - " .. name .. " ... ")
    local ok, err = pcall(fn)
    if ok then
        Test.count = Test.count + 1
        io.write("ok\n")
        return
    end
    io.write("failed\n")
    fail(err, 0)
end

function Test.eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format(
            "%s expected %s, got %s",
            message or "values differ",
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

function Test.ne(actual, expected, message)
    if actual == expected then
        fail(string.format(
            "%s did not expect %s",
            message or "values should differ",
            tostring(expected)
        ), 2)
    end
end

function Test.gte(actual, expected, message)
    if not (actual >= expected) then
        fail(string.format(
            "%s expected %s >= %s",
            message or "value too small",
            tostring(actual),
            tostring(expected)
        ), 2)
    end
end

function Test.lte(actual, expected, message)
    if not (actual <= expected) then
        fail(string.format(
            "%s expected %s <= %s",
            message or "value too large",
            tostring(actual),
            tostring(expected)
        ), 2)
    end
end

function Test.truthy(value, message)
    if not value then
        fail(message or "expected truthy value", 2)
    end
end

function Test.falsy(value, message)
    if value then
        fail(message or "expected falsy value", 2)
    end
end

function Test.hasKey(tbl, key, message)
    if not (tbl and tbl[key]) then
        fail(message or ("expected key " .. tostring(key)), 2)
    end
end

function Test.noKey(tbl, key, message)
    if tbl and tbl[key] then
        fail(message or ("unexpected key " .. tostring(key)), 2)
    end
end

function Test.countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

return Test
