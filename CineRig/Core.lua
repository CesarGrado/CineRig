local _, R = ...
local Engine = { state = "idle", generation = 0, errors = {}, listeners = {}, blocks = {} }
local releaseWarning = "Camera release error. Use Restore."
R.Engine = Engine
-- An unparented frame keeps the transport alive when the player hides UIParent.
Engine.frame = CreateFrame("Frame")

function R.Finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function R.Clamp(n, low, high)
    return math.max(low, math.min(high, n))
end

function R.Ease(kind, t)
    if kind == "linear" then return 1 end
    t = R.Clamp(t, 0, 1)
    -- Raised-cosine velocity. Both speed and acceleration meet rest smoothly.
    return math.sin(math.pi * t) ^ 2
end

-- WoW's native turn directions describe movement of the rig around the player.
-- A pan/tilt label describes where the lens looks. Converting between the
-- two conventions uses the same sign in either direction. Storage stays native.
local viewSigns = {yaw = -1, pitch = -1, zoom = 1}
function R.ConvertViewRate(axis, rate)
    if rate == 0 then return 0 end
    return rate * viewSigns[axis]
end

local function shot(name, duration, yaw, pitch, zoom)
    return {name = name, duration = duration, yaw = R.ConvertViewRate("yaw", yaw),
        pitch = R.ConvertViewRate("pitch", pitch), zoom = zoom, ease = "soft"}
end
R.OpticalShot = shot

R.Recipes = {
    shot("Stormwind reveal", 8, .085, 0, -.85),
    shot("Slow pan", 8, .085, 0, 0),
    shot("Tilt", 6, 0, .09, 0),
    shot("Slow push", 8, 0, 0, -.85),
    shot("Pull-back", 8, 0, 0, .85),
    shot("Partial orbit", 12, .20, 0, 0),
    shot("Establishing sweep", 12, -.07, .018, 0),
    shot("Orbit reveal", 10, .18, 0, .4),
    shot("Over-the-shoulder", 7, .035, 0, -.25),
    shot("First-person walkthrough", 15, 0, 0, 0),
    shot("Third-person walkthrough", 15, 0, 0, 0),
    shot("Walking arc", 10, .045, 0, 0),
    shot("Rising reveal", 9, .06, .07, .8),
    shot("Descending push", 8, 0, -.055, -.75),
    shot("Orbit and push", 10, .13, 0, -.65),
}
R.RecipeNotes = {
    ["Stormwind reveal"] = "Frame the gate off-center. Leave room to push in.",
    ["Partial orbit"] = "Set rate and duration to change the arc around your character.",
    ["Orbit reveal"] = "Start with the landmark behind your character's shoulder.",
    ["Over-the-shoulder"] = "Set shoulder framing yourself first. This adds a small drift.",
    ["First-person walkthrough"] = "Zoom fully in. Walk and steer with your mouse.",
    ["Third-person walkthrough"] = "Frame your character. Walk, steer and zoom freely.",
    ["Walking arc"] = "Frame in third person. Walk with keys as the view pans. Mouse takes over.",
    ["Rising reveal"] = "Begin low. Pan right and tilt up while pulling back.",
    ["Descending push"] = "Begin above the subject. Tilt down as the camera moves closer.",
    ["Orbit and push"] = "Frame in third person. Sweep around the character while pushing in.",
}

function R.Copy(row)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    return copy
end

function R.ValidName(name)
    return type(name) == "string" and #name > 0 and #name <= 64
        and not name:find("[%c|]") and name:find("%S") ~= nil
end

function R.ValidShot(s)
    if type(s) ~= "table" or not R.ValidName(s.name) then return false end
    local function within(n, lo, hi) return R.Finite(n) and n >= lo and n <= hi end
    return within(s.duration, .5, 120) and within(s.yaw, -1, 1)
        and within(s.pitch, -1, 1) and within(s.zoom, -8, 8)
        and (s.ease == "soft" or s.ease == "linear")
end

R.selected = R.Copy(R.Recipes[1])
R.countdown = 3

function Engine:Log(msg)
    msg = tostring(msg):sub(1, 240)
    if self.errors[#self.errors] ~= msg then
        self.errors[#self.errors + 1] = msg
        if #self.errors > 8 then table.remove(self.errors, 1) end
    end
end

function Engine:Notify()
    for _, listener in ipairs(self.listeners) do
        local ok, err = pcall(listener)
        if not ok then self:Log(err) end
    end
end

function Engine:State() return self.state end

function Engine:RetryCameraRelease()
    local released, retried = R.Adapter:RetryPendingRelease()
    if retried and released and self.state == "idle" and self.message == releaseWarning then
        self.message = "Camera control released"
        self:Notify()
    end
end

-- A take or operator move can finish while the player continues walking.
-- keepDisplay also preserves the existing capture-safe post-roll outside a walk.
function Engine:ReleaseMotion(reason, keepDisplay)
    local wasRolling = self.state ~= "idle"
    self.generation = self.generation + 1
    self.frame:SetScript("OnUpdate", nil)
    if R.Operator then
        local ok, err = pcall(R.Operator.Clear, R.Operator, reason)
        if not ok then self:Log(err) end
    end
    self.state, self.job = "idle", nil
    local ok, result, problem = pcall(R.Adapter.Release, R.Adapter)
    self.message = reason or "Stopped"
    if not ok or result == false or problem then
        self:Log(problem or result or "Camera release failed")
        self.message = releaseWarning
        R.Walk.active, keepDisplay = false, false
        R.Viewfinder:Release()
        R.Cursor:EndWalk()
    end
    if R.displayOwned and not R.Walk.active and not keepDisplay then
        R.RestoreDisplay()
    end
    self.cursorPostroll = keepDisplay and R.captureSafe and R.displayOwned and (wasRolling or self.cursorPostroll)
    self:Notify()
    return ok and result == true
end

function Engine:Stop(reason)
    R.Walk.active = false
    local released, why = R.Viewfinder:Release()
    local ok = self:ReleaseMotion(reason)
    R.Cursor:EndWalk()
    if not released then
        self.message = why or "Viewfinder release pending. Press Restore."
        self:Log(self.message); self:Notify()
    end
    return ok
end

function Engine:Pause()
    if self.state ~= "playing" and self.state ~= "paused" then return end
    local generation = self.generation
    if self.state == "playing" then
        if not self.job.passive then
            local ok, reason = R.Adapter:Apply(0, 0, 0, 0)
            if self.generation ~= generation then return end
            if not ok then return self:Fail(reason) end
        end
        self.state = "paused"
    else
        local ok, reason = self:Allowed(self.job.passive)
        if self.generation ~= generation then return end
        if not ok then return self:Fail(reason) end
        self.state = "playing"
    end
    self:Notify()
end

function Engine:Restore()
    self:Stop("Control returned")
    if R.RestoreDisplay then R.RestoreDisplay() end
end

function Engine:Fail(reason)
    local repeatMessage = self.lastWarning == reason
    self:Log(reason)
    local walking = R.Walk.active and self:Allowed(true)
    if walking then self:ReleaseMotion(reason) else self:Stop(reason) end
    self.lastWarning = reason
    if not repeatMessage and R.Say and not R.captureSafe and not walking then R.Say(reason) end
    return nil, reason
end

function Engine:Allowed(passive)
    local _, reason = next(self.blocks)
    if reason then return nil, reason end
    reason = R.Adapter:InterruptReason(passive)
    if reason then return nil, reason end
    return true
end

function R.ValidSegment(s)
    if not R.ValidShot(s) then return false end
    for _, field in ipairs({"trimIn", "trimOut", "hold"}) do
        local v = s[field]
        if v ~= nil and (not R.Finite(v) or v < 0) then return false end
    end
    return (s.hold or 0) <= 60 and s.duration - (s.trimIn or 0) - (s.trimOut or 0) >= .5
        and (s.join == nil or s.join == "cut" or s.join == "ease")
end

local function movingTime(s)
    return s.duration - (s.trimIn or 0) - (s.trimOut or 0)
end
local function span(s) return movingTime(s) + (s.hold or 0) end
R.Span = span

local function sample(s, t)
    local w = R.Ease(s.ease, ((s.trimIn or 0) + t) / s.duration)
    return s.yaw * w, s.pitch * w, s.zoom * w
end

local function velocity(j)
    local s = j.list[j.index]
    if j.time >= movingTime(s) then return 0, 0, 0 end
    local y, p, z = sample(s, j.time)
    -- Blend the outgoing and incoming rates; the handoff occupies the
    -- first half-second of the destination segment's authored running time.
    if s.join == "ease" and j.time < .5 then
        local previous = j.list[j.index - 1] or (j.cycled and j.list[#j.list])
        local py, pp, pz = 0, 0, 0
        if previous and (previous.hold or 0) == 0 then
            py, pp, pz = sample(previous, movingTime(previous))
        end
        local t = j.time * 2
        local mix = t * t * (3 - 2 * t)
        y, p, z = py + (y - py) * mix, pp + (p - pp) * mix, pz + (z - pz) * mix
    end
    return y, p, z
end

function Engine:Advance(dt)
    if not R.Finite(dt) or dt < 0 or dt > .5 then
        return self:Fail("Frame stall. Reframe and restart.")
    end
    local j = self.job
    local ok, reason = self:Allowed(j and j.passive)
    if not ok then return self:Fail(reason) end
    if self.state == "paused" then return end
    if self.state == "desk-motion" then return R.DeskMotion:Advance(dt) end
    if self.state == "operator" then return R.Operator:Advance(dt) end
    if self.state == "live-replay" then return R.Operator:AdvanceReplay(dt) end
    if self.state == "countdown" then
        j.wait = j.wait - dt
        if j.wait > 0 then return end
        dt, j.wait, self.state = -j.wait, 0, "playing"
        self:Notify()
        if self.job ~= j or self.state ~= "playing" then return end
    end
    j.time, j.elapsed = j.time + dt, j.elapsed + dt
    while j.time >= span(j.list[j.index]) do
        j.time = j.time - span(j.list[j.index])
        j.index = j.index + 1
        if j.index > #j.list then
            if not j.loop then return self:ReleaseMotion("Take complete", true) end
            j.index, j.elapsed, j.cycled = 1, j.time, true
        end
    end
    if j.passive then return end
    local yaw, pitch, zoom = velocity(j)
    ok, reason = R.Adapter:Apply(yaw, pitch, zoom, dt)
    if not ok then return self:Fail(reason or "Camera command refused") end
end

function Engine:Arm()
    self.lastWarning = nil
    local token = self.generation
    if R.PrepareTake then
        local called, ok, reason = pcall(R.PrepareTake)
        if not called then return self:Fail(tostring(ok)) end
        if not ok then return self:Fail(reason or "Filming setup unavailable") end
    end
    if self.generation ~= token or self.state == "idle" then return nil, "Start interrupted" end
    local redraw = 0
    self.frame:SetScript("OnUpdate", function(_, dt)
        if self.generation ~= token then return end
        if R.FreeCursor.enabled then R.TickFreeCursor() end
        if self.generation ~= token then return end
        local ok, err = pcall(self.Advance, self, dt)
        if not ok then self:Fail("Camera error: " .. tostring(err)) end
        if self.generation ~= token then return end
        redraw = redraw + dt
        if redraw >= .1 then redraw = 0; self:Notify() end
    end)
    self:Notify()
    if self.generation ~= token then return nil, "Start interrupted" end
    return true
end

function Engine:Play(list, countdown, loop, name)
    if not self:ReleaseMotion("Ready", true) then return nil, self.message end
    if type(list) ~= "table" or #list < 1 or #list > 32 then
        return self:Fail("Choose 1 to 32 segments")
    end
    local queue, total = {}, 0
    local yaw, pitch, zoom = 0, 0, 0
    for i = 1, #list do
        local s = list[i]
        if not R.ValidSegment(s) then return self:Fail("Invalid segment " .. i) end
        yaw = math.max(yaw, math.abs(s.yaw))
        pitch = math.max(pitch, math.abs(s.pitch))
        zoom = math.max(zoom, math.abs(s.zoom))
        queue[i], total = R.Copy(s), total + span(s)
    end
    -- Check the whole queue before countdown. A later pan or eased join
    -- needs camera ownership even if the first segment is a manual walk.
    local passive = yaw == 0 and pitch == 0 and zoom == 0
    local ok, reason = self:Allowed(passive)
    if not ok then return self:Fail(reason) end
    if not passive then
        ok, reason = R.Adapter:Check(yaw, pitch, zoom)
        if not ok then return self:Fail(reason or "Move unavailable") end
    end
    local wait = R.Finite(countdown) and R.Clamp(countdown, 0, 10) or 0
    self.job = {list = queue, name = R.ValidName(name) and name or nil, index = 1, time = 0, elapsed = 0, total = total, wait = wait,
        loop = loop == true, passive = passive}
    self.state = wait > 0 and "countdown" or "playing"
    self.message = queue[1].name
    return self:Arm()
end

function R.PlaySelected()
    return Engine:Play({R.selected}, R.countdown)
end

function R.StatusLine()
    if Engine.state == "desk-motion" then return R.DeskMotion:Status() end
    if Engine.state == "operator" or Engine.state == "live-replay" then return R.Operator:Status() end
    local j = Engine.job
    if not j then
        if R.Walk.active then return "Walking session   ·   manual camera" end
        return Engine.message or "Ready to frame"
    end
    if Engine.state == "countdown" then return "Rolling in " .. math.ceil(j.wait) end
    local mode = Engine.state == "paused" and "Paused   " or ""
    return string.format("%s%s   %.1fs elapsed   %.1fs left", mode, j.list[j.index].name,
        j.elapsed, math.max(0, j.total - j.elapsed))
end
