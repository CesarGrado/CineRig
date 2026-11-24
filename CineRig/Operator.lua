local _, R = ...
local E = R.Engine
local Operator = {held = {}, blocked = {}, motion = {}}
R.Operator = Operator
R.operatorPrefs = {dial = 1, fine = true, rampUp = .6, rampDown = .35}

local axes = {
    {name = "yaw", negative = "left", positive = "right", peak = .22},
    {name = "pitch", negative = "down", positive = "up", peak = .18},
    {name = "zoom", negative = "in", positive = "out", peak = 3},
}
local byKey = {}
for i, axis in ipairs(axes) do
    byKey[axis.negative], byKey[axis.positive] = i, i
end

local function bounded(value, default, low, high)
    return R.Finite(value) and R.Clamp(value, low, high) or default
end

local function prefs()
    local p = R.operatorPrefs
    if type(p) ~= "table" then p = {}; R.operatorPrefs = p end
    p.dial = bounded(p.dial, 1, .25, 2)
    p.rampUp = bounded(p.rampUp, .6, 0, 3)
    p.rampDown = bounded(p.rampDown, .35, 0, 3)
    if type(p.fine) ~= "boolean" then p.fine = true end
    return p
end

-- Keep a cancelled physical press suppressed through key repeat, until its
-- matching release. The panel buttons and native bindings have distinct tokens.
function Operator:Clear(reason)
    for token in pairs(self.held) do self.blocked[token] = true end
    self.held, self.motion, self.nudge = {}, {}, nil
    R.RecordingSession:OnClear(reason)
    if R.LiveTake then R.LiveTake:Clear(reason) end
end

local function acquire(axis)
    local starting = E.state ~= "operator"
    if starting and not E:ReleaseMotion("Live operator", true) then return nil, E.message end
    local ok, reason = E:Allowed()
    local need = {0, 0, 0}
    need[axis] = 1
    if ok then ok, reason = R.Adapter:Check(need[1], need[2], need[3]) end
    if not ok then return nil, reason or "Operator control unavailable" end
    return true, starting
end

local function roll(starting)
    if not starting then return true end
    R.LiveTake:Begin()
    E.state, E.job, E.message = "operator", nil, "Live operator"
    return E:Arm()
end

function Operator:Key(key, down, source)
    local axis = byKey[key]
    if not axis then return end
    local token = (source or "binding") .. ":" .. key
    if not down then
        self.blocked[token], self.held[token] = nil, nil
        return
    end
    if self.blocked[token] or self.held[token] then return end
    local ok, starting = acquire(axis)
    if not ok then
        self.blocked[token] = true
        return E:Fail(starting)
    end
    self.held[token] = key
    return roll(starting)
end

function Operator:RecordNudge(key, move)
    local axis = byKey[key]
    local ok, starting = acquire(axis)
    if not ok then return E:Fail(starting) end
    self.nudge = {axis = axis, rate = move[axes[axis].name], duration = move.duration, elapsed = 0}
    return roll(starting)
end

local function blend(a, b, t)
    t = R.Clamp(t, 0, 1)
    return a + (b - a) * t * t * (3 - 2 * t)
end

local function slew(m, target, dt, p)
    if target ~= m.target then
        m.start, m.target, m.elapsed = m.value, target, 0
        m.reversing = m.start * target < 0
        m.brake = m.reversing and p.rampDown or 0
        if m.reversing or math.abs(target) > math.abs(m.start) then
            m.duration = m.brake + p.rampUp
        else
            m.duration = p.rampDown
        end
    end
    m.elapsed = m.elapsed + dt
    if m.elapsed >= m.duration then
        m.value = target
    elseif m.elapsed < m.brake then
        m.value = blend(m.start, 0, m.elapsed / m.brake)
    else
        local from = m.reversing and 0 or m.start
        m.value = blend(from, target, (m.elapsed - m.brake) / (m.duration - m.brake))
    end
    return m.value
end

function Operator:Advance(dt)
    local p = prefs()
    local gain = p.dial * (p.fine and .35 or 1)
    local values, moving = {}, false
    for i, axis in ipairs(axes) do
        local m = self.motion[i]
        if not m then
            m = {value = 0, target = 0, duration = 0, elapsed = 0, brake = 0}
            self.motion[i] = m
        end
        local negative = self.held["binding:" .. axis.negative] or self.held["button:" .. axis.negative]
        local positive = self.held["binding:" .. axis.positive] or self.held["button:" .. axis.positive]
        local sign = (positive and 1 or 0) - (negative and 1 or 0)
        values[i] = slew(m, R.ConvertViewRate(axis.name, sign * axis.peak * gain), dt, p)
        moving = moving or values[i] ~= 0
    end
    local n = self.nudge
    if n then
        n.elapsed = n.elapsed + dt
        if n.elapsed >= n.duration then
            self.nudge = nil
        else
            local limit = n.axis == 3 and 8 or 1
            values[n.axis] = R.Clamp(values[n.axis] + n.rate * R.Ease("soft", n.elapsed / n.duration), -limit, limit)
        end
    end
    local generation = E.generation
    local ok, reason, appliedZoom = R.Adapter:Apply(values[1], values[2], values[3], dt)
    if E.generation ~= generation then return end
    if not ok then return E:Fail(reason or "Operator camera command refused") end
    if R.LiveTake then
        -- A low native zoom-speed setting can cap even an ordinary hold.
        -- Save the rate the client could receive for replay at another setting.
        values[3] = appliedZoom
        R.LiveTake:Sample(dt, values)
    end
    R.RecordingSession:AfterSample()
    if not moving and not self.nudge and not next(self.held) and not R.RecordingSession.active then
        return E:ReleaseMotion("Control returned")
    end
end

function Operator:Status()
    local p = prefs()
    local replay = R.LiveTake and R.LiveTake.replay
    if replay then
        return string.format("Live take   %.1f s elapsed   %.1f s left",
            replay.ms / 1000, (replay.take.ms - replay.ms) / 1000)
    end
    return string.format("Live operator   %s   %.0f%%", p.fine and "Fine" or "Coarse", p.dial * 100)
end

local rampSteps = {0, .15, .35, .6, 1, 1.5, 2, 3}
local function cycleRamp(field)
    local p = prefs()
    local value = p[field]
    p[field] = 0
    for _, step in ipairs(rampSteps) do
        if step > value then p[field] = step; break end
    end
end

function CineRig_Hold(key, down)
    local ok, reason = pcall(Operator.Key, Operator, key, down)
    if not ok then E:Fail(tostring(reason)) end
end

function CineRig_ToggleFine()
    local p = prefs()
    p.fine = not p.fine
    E:Notify()
end

function CineRig_SpeedStep(direction)
    local p = prefs()
    p.dial = R.Clamp(p.dial + (direction > 0 and .125 or -.125), .25, 2)
    E:Notify()
end

BINDING_NAME_CINERIG_LEFT = "Hold to pan left"
BINDING_NAME_CINERIG_RIGHT = "Hold to pan right"
BINDING_NAME_CINERIG_UP = "Hold to tilt up"
BINDING_NAME_CINERIG_DOWN = "Hold to tilt down"
BINDING_NAME_CINERIG_IN = "Hold to push in"
BINDING_NAME_CINERIG_OUT = "Hold to pull back"
BINDING_NAME_CINERIG_PRECISION = "Toggle fine or coarse speed"
BINDING_NAME_CINERIG_SLOWER = "Decrease live speed"
BINDING_NAME_CINERIG_FASTER = "Increase live speed"
BINDING_NAME_CINERIG_PAUSE = "Pause or resume authored move"

function Operator:Build(parent)
    if self.dialLabel then return end
    local ui = R.UI
    ui.Label(parent, 16, 4, 368, "GameFontHighlight", "Hold to move")
    local controls = {{"left", "Pan L"}, {"right", "Pan R"}, {"up", "Tilt up"},
        {"down", "Tilt down"}, {"in", "Push in"}, {"out", "Pull back"}}
    for i, item in ipairs(controls) do
        local key, caption = item[1], item[2]
        local b = ui.Button(parent, 16 + (i - 1) * 62, 26, 58, caption, function() end)
        b:SetScript("OnClick", nil)
        b:SetScript("OnMouseDown", function(_, mouse)
            if mouse == "LeftButton" then self:Key(key, true, "button") end
        end)
        local function release() self:Key(key, false, "button") end
        b:SetScript("OnMouseUp", release)
        b:SetScript("OnLeave", release)
        b:SetScript("OnHide", release)
    end
    self.dialLabel = ui.Label(parent, 16, 72, 127, nil, "")
    ui.Button(parent, 144, 65, 46, "Slower", function() CineRig_SpeedStep(-1) end)
    ui.Button(parent, 196, 65, 46, "Faster", function() CineRig_SpeedStep(1) end)
    self.precision = ui.Button(parent, 252, 65, 132, "", CineRig_ToggleFine)
    self.rampUp = ui.Button(parent, 16, 101, 178, "", function() cycleRamp("rampUp") end)
    self.rampDown = ui.Button(parent, 202, 101, 182, "", function() cycleRamp("rampDown") end)
    self.recordButton = ui.Button(parent, 16, 140, 112, "Arm take", function() R.LiveTake:Arm() end)
    self.saveButton = ui.Button(parent, 135, 140, 121, "Save take", function() R.LiveTake:Save() end)
    self.replayButton = ui.Button(parent, 263, 140, 121, "Replay saved", function() R.LiveTake:Play() end)
    self.takeLabel = ui.Label(parent, 16, 179, 368, "GameFontDisableSmall", "")
    ui.Button(parent, 16, 208, 368, "Named recordings", function() R.Recordings:Open() end)
    self:Refresh()
end

function Operator:Refresh()
    if not self.dialLabel then return end
    local p = prefs()
    self.dialLabel:SetText(string.format("Live speed   %.0f%%", p.dial * 100))
    self.precision:SetText(p.fine and "Fine speed" or "Coarse speed")
    self.rampUp:SetText(string.format("Ramp up   %g s", p.rampUp))
    self.rampDown:SetText(string.format("Ramp down   %g s", p.rampDown))
    local take = R.LiveTake
    if take then
        self.recordButton:SetEnabled(E.state == "idle" and not R.RecordingSession.active)
        self.recordButton:SetText(take.armed and "Disarm take" or "Arm take")
        self.saveButton:SetEnabled((take.record or take.draft) ~= nil)
        self.saveButton:SetText(take.saved and "Replace save" or "Save take")
        self.replayButton:SetEnabled(take.saved ~= nil and not take.armed and not take.record)
        self.takeLabel:SetText(take:Caption())
    end
end
