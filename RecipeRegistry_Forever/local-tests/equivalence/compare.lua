-- Confronta due registri di run-equivalence.ps1.
--
--   lua compare.lua strict <a> <b>   esce con 1 alla prima riga diversa, e la
--                                    stampa con il contesto (l'ultimo controllo
--                                    dei database e il client in cui si trova)
--   lua compare.lua info <a> <b>     stampa le righe che stanno in uno solo dei
--                                    due file; esce sempre con 0

local mode, pathA, pathB = ...

local function short(line)
    if line == nil then return "<fine del file>" end
    if #line > 400 then return line:sub(1, 400) .. " ...(" .. #line .. " caratteri)" end
    return line
end

if mode == "strict" then
    local fa = assert(io.open(pathA, "rb"))
    local fb = assert(io.open(pathB, "rb"))
    local n, checkpoint, peer, lastWire = 0, nil, nil, nil
    while true do
        local la, lb = fa:read("*l"), fb:read("*l")
        n = n + 1
        if la ~= lb then
            print(string.format("  prima differenza alla riga %d", n))
            if checkpoint then print("  ultimo controllo dei database: " .. checkpoint) end
            if peer then print("  nel client: " .. peer) end
            if lastWire then print("  ultimo messaggio uguale: " .. short(lastWire)) end
            print("  prima : " .. short(la))
            print("  dopo  : " .. short(lb))
            os.exit(1)
        end
        if la == nil then break end
        local tag = la:sub(1, 2)
        if tag == "D " then checkpoint, peer = la, nil
        elseif tag == "P " then peer = la
        elseif tag == "W " then lastWire, peer = la, nil end
    end
    os.exit(0)
elseif mode == "info" then
    local function lines(path)
        local set, list = {}, {}
        local f = io.open(path, "rb")
        if not f then return set, list end
        for line in f:lines() do
            set[line] = (set[line] or 0) + 1
            list[#list + 1] = line
        end
        f:close()
        return set, list
    end
    local setA, listA = lines(pathA)
    local setB, listB = lines(pathB)
    local shown = 0
    for _, line in ipairs(listA) do
        if not setB[line] and shown < 40 then print("  - " .. short(line)); shown = shown + 1 end
    end
    for _, line in ipairs(listB) do
        if not setA[line] and shown < 40 then print("  + " .. short(line)); shown = shown + 1 end
    end
    os.exit(0)
else
    io.stderr:write("uso: lua compare.lua strict|info <a> <b>\n")
    os.exit(2)
end
