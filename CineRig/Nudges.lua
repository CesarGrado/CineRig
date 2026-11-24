local _, R = ...
local E = R.Engine
local Nudges = {}
R.Nudges = Nudges

-- Turn amounts are speed-multiplier seconds, evaluated against the player's
-- own camera speed. Zoom amounts are distance increments before engine limits.
local amounts = {
    Micro = {turn = .012, zoom = .20},
    Small = {turn = .030, zoom = .50},
    Medium = {turn = .065, zoom = 1.25},
}
local nextSize = {Micro = "Small", Small = "Medium", Medium = "Micro"}
local nextDuration = {[.6] = 1, [1] = 1.6, [1.6] = .6}
local directions = {
    left  = {axis = "yaw",   sign = -1, label = "Pan left"},
    right = {axis = "yaw",   sign =  1, label = "Pan right"},
    up    = {axis = "pitch", sign =  1, label = "Tilt up"},
    down  = {axis = "pitch", sign = -1, label = "Tilt down"},
    ["in"] = {axis = "zoom", sign = -1, label = "Push in"},
    out    = {axis = "zoom", sign =  1, label = "Pull back"},
}

function Nudges:Normalize(raw)
    if type(raw) ~= "table" then raw = {} end
    return {
        size = amounts[raw.size] and raw.size or "Small",
        duration = nextDuration[raw.duration] and raw.duration or 1,
    }
end

R.nudgePrefs = Nudges:Normalize()

function Nudges:Prefs()
    return self:Normalize(R.nudgePrefs)
end

function Nudges:CycleSize()
    local p = self:Prefs()
    p.size = nextSize[p.size]
    R.nudgePrefs = p
    E:Notify()
end

function Nudges:CycleDuration()
    local p = self:Prefs()
    p.duration = nextDuration[p.duration]
    R.nudgePrefs = p
    E:Notify()
end

function Nudges:Tap(direction)
    local d = directions[direction]
    if not d then return nil, "Choose a pan, tilt or zoom direction." end
    -- Starting an authored move normally clears the live recorder. Preserve
    -- the operator's armed or rolling take when a trim key is pressed.
    local take = R.LiveTake
    if take and (take.armed or take.record) and not R.RecordingSession.active then
        local reason = "Finish or disarm the live take before using a nudge."
        if E.message ~= reason then
            E.message = reason
            if R.Say and not R.Walk.active and not R.captureSafe then R.Say(reason) end
            E:Notify()
        end
        return nil, reason
    end
    local p = self:Prefs()
    local amount = amounts[p.size]
    local travel = d.axis == "zoom" and amount.zoom or amount.turn
    local move = {name = d.label, duration = p.duration, yaw = 0, pitch = 0, zoom = 0, ease = "soft"}
    -- The mean of the soft velocity envelope is 1/2. Stretching its time
    -- changes the pace while keeping the commanded travel for this size.
    move[d.axis] = R.ConvertViewRate(d.axis, d.sign * 2 * travel / p.duration)
    if R.RecordingSession.active then return R.Operator:RecordNudge(direction, move) end
    return E:Play({move}, 0)
end

local held = {}
function CineRig_NudgeKey(direction, down)
    if not directions[direction] then return end
    if not down then held[direction] = nil; return end
    if held[direction] then return end
    held[direction] = true
    local ok, err = pcall(Nudges.Tap, Nudges, direction)
    if not ok then E:Fail(tostring(err)) end
end

for direction, d in pairs(directions) do
    _G["BINDING_NAME_CINERIG_NUDGE_" .. direction:upper()] = "Nudge: " .. d.label
end
