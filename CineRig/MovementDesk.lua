local _, R = ...
local E, A, UI = R.Engine, R.Adapter, R.UI
local D = {}
R.DeskMotion = D

local pullRates = {2, 4, 8}
local glanceTimes = {.8, 1.4, 2}
local glanceNames = {"Small", "Medium", "Wide"}
local repeatCounts = {1, 2, 3, 4}
local holds = {0, .5, 1, 2, 4}
local pressed = {}

local function option(n, choices, fallback)
    return R.Finite(n) and n == math.floor(n) and choices[n] and n or fallback
end

local function validMark(value)
    if R.Finite(value) and value >= 0 and value <= 1000 then return value end
end

function D:LoadSettings(raw)
    if type(raw) ~= "table" then raw = {} end
    self.settings = {
        close = validMark(raw.close), wide = validMark(raw.wide), pace = option(raw.pace, pullRates, 2),
        glance = option(raw.glance, glanceTimes, 2), repeats = option(raw.repeats, repeatCounts, 1),
        hold = option(raw.hold, holds, 3),
    }
end

function D:SaveSettings()
    return R.Copy(self.settings)
end
D:LoadSettings()

local function failure(reason)
    D.note = reason
    E:Notify()
    return nil, reason
end

local function available()
    if R.LiveTake.armed or R.LiveTake.record or R.RecordingSession.active then
        return nil, "Finish or disarm the movement recording first."
    end
    return E:Allowed()
end

local function start(job, yaw, zoom)
    local ok, reason = available()
    if not ok then return failure(reason) end
    local caps = A:Status()
    if (yaw ~= 0 and not caps.yaw) or (zoom ~= 0 and not caps.zoom) then
        return failure("The camera axis for this move is unavailable.")
    end
    if not E:ReleaseMotion("Framing move", true) then return failure(E.message) end
    ok, reason = A:Check(yaw, 0, zoom)
    if not ok then return E:Fail(reason) end
    E.state, E.job, E.message = "desk-motion", job, job.name
    D.note = nil
    return E:Arm()
end

local function complete(reason)
    D.note = reason
    return E:ReleaseMotion(reason, true)
end

local function apply(yaw, zoom, dt)
    local ok, reason = A:Apply(yaw, 0, zoom, dt)
    if not ok then return E:Fail(reason or "Camera command refused.") end
    return true
end

function D:Mark(key)
    if key ~= "close" and key ~= "wide" then return failure("Choose Close or Wide.") end
    local ok, reason = E:Allowed(true)
    if not ok then return failure(reason) end
    local distance = validMark(A:Distance())
    if not distance then return failure("WoW could not read the current camera distance.") end
    local s = self.settings
    s[key] = distance
    self.note = string.format("Saved the %s mark at %.2f.", key, distance)
    E:Notify()
    return true
end

function D:Pull(key)
    if key ~= "close" and key ~= "wide" then return failure("Choose Close or Wide.") end
    local target = self.settings[key]
    if not target then return failure("Set the " .. key .. " distance before pulling to it.") end
    local current = validMark(A:Distance())
    if not current then return failure("WoW could not read the current camera distance.") end
    local error = target - current
    local limit = A:MaxZoomRate()
    if not limit then return failure("WoW could not read the current zoom speed.") end
    local rate = math.min(pullRates[self.settings.pace], limit)
    local job = {kind = "pull", name = "Pull to " .. key, elapsed = 0, target = target,
        sign = error < 0 and -1 or 1, rate = rate, closest = math.abs(error), stalled = 0,
        timeout = math.min(180, 8 + 4 * math.abs(error) / rate)}
    return start(job, 0, 1)
end

local function advancePull(j, dt)
    local current = validMark(A:Distance())
    if not current then return complete("Pull ended. Camera distance became unavailable.") end
    local remaining = j.sign * (j.target - current)
    if remaining <= .045 then
        return complete(string.format("Pull finished at %.2f (mark %.2f).", current, j.target))
    end
    if remaining < j.closest - .008 then
        j.closest, j.stalled = remaining, 0
    else
        j.stalled = j.stalled + dt
    end
    if j.stalled >= 1.6 or j.elapsed >= j.timeout then
        return complete(string.format("Pull stopped at %.2f before mark %.2f. Check camera clearance.", current, j.target))
    end
    -- Ramp up, then brake against the measured gap. Stop on crossing; a
    -- camera displaced by collision must never oscillate to chase the mark.
    local ramp = R.Clamp(j.elapsed / .45, 0, 1)
    local speed = math.min(j.rate * ramp * (2 - ramp), math.sqrt(2 * j.rate * remaining),
        remaining / math.max(dt, 1 / 60))
    return apply(0, j.sign * speed, dt)
end

function D:Glance(side, down, source)
    if side ~= "left" and side ~= "right" then return failure("Choose a glance direction.") end
    local token = (source or "binding") .. ":" .. side
    local j = E.job
    if not down then
        pressed[token] = nil
        if E.state == "desk-motion" and j.kind == "glance" and j.token == token and not j.returning then
            j.returning, j.returnTime = true, 0
        end
        return true
    end
    if pressed[token] then return true end
    pressed[token] = true
    if E.state == "desk-motion" and j.kind == "glance" and not j.returning then
        return failure("Release the current glance before starting another.")
    end
    return start({kind = "glance", name = "Glance " .. side, token = token,
        sign = R.ConvertViewRate("yaw", side == "left" and -1 or 1), sweep = glanceTimes[self.settings.glance],
        elapsed = 0, balance = 0, lastRate = 0}, 1, 0)
end

local function advanceGlance(j, dt)
    -- Each command is held by the client until this update. Accumulate the
    -- previous rate through the elapsed interval, including key release
    -- between updates. The matched return is relative to the player's view.
    j.balance = j.balance + j.lastRate * dt
    local peak = .23
    local nextRate = 0
    if j.returning then
        if j.balance <= .0005 then return complete("Glance returned. Check your framing.") end
        j.returnTime = j.returnTime + dt
        local ramp = math.min(1, j.returnTime / .2)
        nextRate = -math.min(peak * ramp, math.sqrt(1.4 * j.balance), j.balance / math.max(dt, 1 / 60))
    elseif j.elapsed < j.sweep then
        nextRate = peak * R.Ease("soft", j.elapsed / j.sweep)
    elseif j.elapsed >= 30 then
        -- A missed key-up still returns the view and releases the transport.
        j.returning, j.returnTime = true, 0
    end
    j.lastRate = nextRate
    return apply(j.sign * nextRate, 0, dt)
end

function D:Advance(dt)
    local j = E.job
    j.elapsed = j.elapsed + dt
    if j.kind == "glance" then return advanceGlance(j, dt) end
    return advancePull(j, dt)
end

function D:PingPong()
    local ok, reason = available()
    if not ok then return failure(reason) end
    local s = R.selected
    if not R.ValidShot(s) or (s.yaw == 0 and s.pitch == 0 and s.zoom == 0) then
        return failure("Choose a Shot with a pan, tilt or distance change.")
    end
    local rows = {}
    for i = 1, repeatCounts[self.settings.repeats] do
        local out, back = R.Copy(s), R.Copy(s)
        out.name, back.name = "Outward " .. i, "Return " .. i
        out.hold = holds[self.settings.hold]
        back.hold = i < repeatCounts[self.settings.repeats] and out.hold or 0
        back.yaw, back.pitch, back.zoom = -s.yaw, -s.pitch, -s.zoom
        rows[#rows + 1] = out
        rows[#rows + 1] = back
    end
    self.note = nil
    ok, reason = E:Play(rows, R.countdown, false, "Out and back")
    if not ok then return failure(reason) end
    return true
end

function D:Status()
    local j = E.job
    if j.kind == "pull" then return string.format("%s   ·   mark %.2f", j.name, j.target) end
    if j.returning then return "Glance   ·   returning" end
    if j.elapsed >= j.sweep then return "Glance   ·   release to swing back" end
    return j.name
end

local function cycle(field, choices)
    D.settings[field] = D.settings[field] % #choices + 1
    D.note = nil
end

function D:Build(parent)
    self.distanceLabel = UI.Label(parent, 16, 0, 368, "GameFontNormal", "")
    for i, key in ipairs({"close", "wide"}) do
        local slot, x = key, 16 + 186 * (i - 1)
        self[slot .. "Button"] = UI.Button(parent, x, 20, 182, "", function() self:Mark(slot) end)
        self[slot .. "Pull"] = UI.Button(parent, x, 49, 182, "Pull to " .. slot, function() self:Pull(slot) end)
    end
    self.pace = UI.Button(parent, 16, 78, 368, "", function() cycle("pace", pullRates) end)
    UI.Label(parent, 16, 119, 368, "GameFontNormal", "Glance and return")
    for i, side in ipairs({"left", "right"}) do
        local dir = side
        local b = UI.Button(parent, 16 + (i - 1) * 186, 140, 182, "Hold " .. side, function() end)
        b:SetScript("OnClick", nil)
        b:SetScript("OnMouseDown", function(_, key)
            if key == "LeftButton" then self:Glance(dir, true, "panel") end
        end)
        local function release() self:Glance(dir, false, "panel") end
        b:SetScript("OnMouseUp", release)
        b:SetScript("OnLeave", release)
        b:SetScript("OnHide", release)
    end
    self.glance = UI.Button(parent, 16, 169, 368, "", function() cycle("glance", glanceTimes) end)
    self.shot = UI.Label(parent, 16, 209, 368, "GameFontNormal", "")
    self.shot:SetWordWrap(false)
    self.repeats = UI.Button(parent, 16, 230, 182, "", function() cycle("repeats", repeatCounts) end)
    self.hold = UI.Button(parent, 202, 230, 182, "", function() cycle("hold", holds) end)
    local function chooseShot(step)
        UI:BrowseRecipe(step)
        R.Rig:SetTransport()
    end
    UI.Button(parent, 16, 259, 182, "Previous source shot", function() chooseShot(-1) end)
    UI.Button(parent, 202, 259, 182, "Next source shot", function() chooseShot(1) end)
    self.status = UI.Label(parent, 16, 301, 368, "GameFontDisableSmall", "")
    self:Refresh()
end

function D:Refresh()
    if not self.distanceLabel then return end
    local s, distance = self.settings, validMark(A:Distance())
    self.distanceLabel:SetText(distance and string.format("Last camera distance read   ·   %.2f", distance) or "Camera distance unavailable")
    for _, slot in ipairs({"close", "wide"}) do
        local value = s[slot] and string.format("%.2f", s[slot]) or "unset"
        self[slot .. "Button"]:SetText("Set " .. slot .. "   ·   " .. value)
        self[slot .. "Button"]:SetEnabled(distance ~= nil)
        self[slot .. "Pull"]:SetEnabled(s[slot] ~= nil and distance ~= nil)
    end
    self.pace:SetText(string.format("Pull speed   ·   up to %d units/sec", pullRates[s.pace]))
    self.glance:SetText("Glance travel   ·   " .. glanceNames[s.glance])
    self.shot:SetText("Out and back   ·   " .. R.selected.name)
    self.repeats:SetText("Cycles   ·   " .. repeatCounts[s.repeats])
    self.hold:SetText(string.format("Hold at each turn   ·   %g s", holds[s.hold]))
    self.status:SetText(self.note or "Bind Pull and Glance for hidden-UI use. A glance returns on release or after 30 seconds.")
end

function CineRig_GlanceKey(side, down) D:Glance(side, down) end
function CineRig_PullMark(slot) D:Pull(slot) end
BINDING_NAME_CINERIG_GLANCE_LEFT = "Hold to glance left and return"
BINDING_NAME_CINERIG_GLANCE_RIGHT = "Hold to glance right and return"
BINDING_NAME_CINERIG_PULL_CLOSE = "Pull to close distance mark"
BINDING_NAME_CINERIG_PULL_WIDE = "Pull to wide distance mark"
