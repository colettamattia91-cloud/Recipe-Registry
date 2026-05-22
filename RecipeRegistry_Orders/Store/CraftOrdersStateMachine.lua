local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local StateMachine = {}
Addon.StateMachine = StateMachine

StateMachine.STATES = {
    DRAFT              = "Draft",
    MATERIALS_PARTIAL  = "MaterialsPartial",
    MATERIALS_SENT     = "MaterialsSent",
    MATERIALS_RECEIVED = "MaterialsReceived",
    MATERIALS_ASSUMED  = "MaterialsAssumed",
    MATERIALS_MISSING  = "MaterialsMissing",
    ACCEPTED           = "Accepted",
    DELIVERY_SENT      = "DeliverySent",
    COMPLETED          = "Completed",
    RETURN_PENDING     = "ReturnPending",
    CANCELLED          = "Cancelled",
    EXPIRED            = "Expired",
    FAILED             = "Failed",
}

StateMachine.ACTORS = {
    REQUESTER = "requester",
    CRAFTER   = "crafter",
    SYSTEM    = "system",
}

local R, C, S = "requester", "crafter", "system"

local TRANSITIONS = {
    Draft = {
        { to = "MaterialsPartial", actors = { [R] = true } },
        { to = "MaterialsSent",    actors = { [R] = true } },
        { to = "Cancelled",        actors = { [R] = true } },
    },
    MaterialsPartial = {
        { to = "MaterialsSent", actors = { [R] = true } },
        { to = "Cancelled",     actors = { [R] = true } },
    },
    MaterialsSent = {
        { to = "MaterialsReceived", actors = { [C] = true } },
        { to = "MaterialsAssumed",  actors = { [S] = true } },
        { to = "MaterialsMissing",  actors = { [C] = true } },
        { to = "Expired",           actors = { [S] = true } },
    },
    MaterialsReceived = {
        { to = "Accepted",      actors = { [C] = true } },
        { to = "ReturnPending", actors = { [C] = true } },
    },
    MaterialsAssumed = {
        { to = "Accepted",      actors = { [C] = true } },
        { to = "ReturnPending", actors = { [C] = true } },
    },
    MaterialsMissing = {
        { to = "MaterialsReceived", actors = { [C] = true } },
        { to = "Cancelled",         actors = { [C] = true, [R] = true } },
    },
    Accepted = {
        { to = "DeliverySent",  actors = { [C] = true } },
        { to = "ReturnPending", actors = { [C] = true } },
        { to = "Failed",        actors = { [C] = true } },
    },
    DeliverySent = {
        { to = "Completed", actors = { [R] = true, [S] = true } },
    },
    ReturnPending = {
        { to = "Cancelled", actors = { [C] = true } },
    },
    Completed = {},
    Cancelled = {},
    Expired   = {},
    Failed    = {},
}

local TERMINAL_STATES = {
    Completed = true,
    Cancelled = true,
    Expired   = true,
    Failed    = true,
}

StateMachine.TERMINAL_STATES = TERMINAL_STATES

local function buildStateSet()
    local set = {}
    for _, value in pairs(StateMachine.STATES) do
        set[value] = true
    end
    return set
end
local VALID_STATES = buildStateSet()

function StateMachine:IsValidState(state)
    return VALID_STATES[state] == true
end

function StateMachine:IsTerminal(state)
    return TERMINAL_STATES[state] == true
end

function StateMachine:CanTransition(fromState, toState, actor)
    local edges = TRANSITIONS[fromState]
    if not edges then
        return false, "unknown-from-state"
    end
    for index = 1, #edges do
        local edge = edges[index]
        if edge.to == toState then
            if edge.actors[actor] then
                return true
            end
            return false, "actor-not-authorized"
        end
    end
    return false, "invalid-transition"
end

function StateMachine:GetValidTransitions(fromState, actor)
    local out = {}
    local edges = TRANSITIONS[fromState]
    if not edges then return out end
    for index = 1, #edges do
        local edge = edges[index]
        if not actor or edge.actors[actor] then
            out[#out + 1] = edge.to
        end
    end
    return out
end
