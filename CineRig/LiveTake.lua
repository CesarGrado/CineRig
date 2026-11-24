local _, R = ...
local E = R.Engine
local Take = {}
R.LiveTake = Take

-- Samples are camera rates only. Rows contain milliseconds, yaw, pitch and
-- zoom. Integer rates use 1/10000 units; adjust the codec version if that changes.
local stepMs, maxMs, units = 50, 60000, 10000
local rateRounding = .5 / units
local maxRows = maxMs / stepMs + 1
local limits = {units, units, 8 * units}
local function integer(n, low, high)
    return R.Finite(n) and n >= low and n <= high and n == math.floor(n)
end

local function validate(raw, allowExcerpt)
    if type(raw) ~= "table" or not integer(raw.ms, 1, maxMs)
        or type(raw.samples) ~= "table" then return nil end
    local excerpt = allowExcerpt and raw.version == 2 and raw.format == "excerpt"
    if raw.version ~= 1 and not excerpt then return nil end
    local count = #raw.samples
    if excerpt then
        if count < 2 or count > math.ceil(raw.ms / stepMs) + 2 or count > maxRows + 1 then return nil end
    elseif count ~= math.ceil(raw.ms / stepMs) + 1 then return nil end
    for key in pairs(raw.samples) do
        if not integer(key, 1, count) then return nil end
    end
    local rows = {}
    for i = 1, count do
        local row = raw.samples[i]
        if type(row) ~= "table" or not integer(row[1], 0, raw.ms) then return nil end
        local time = row[1]
        if excerpt then
            if (i == 1 and time ~= 0) or (i == count and time ~= raw.ms) then return nil end
            if i > 1 then
                local gap = time - rows[i - 1][1]
                if gap <= 0 or gap > stepMs or (i > 2 and i < count and gap ~= stepMs) then return nil end
            end
        elseif time ~= math.min((i - 1) * stepMs, raw.ms) then return nil end
        for k = 1, 3 do
            if not integer(row[k + 1], -limits[k], limits[k]) then return nil end
        end
        rows[i] = {time, row[2], row[3], row[4]}
    end
    return {version = raw.version, format = excerpt and "excerpt" or nil, ms = raw.ms, samples = rows}
end

function Take:CopyRecording(raw)
    return validate(raw, true)
end

function Take:Load(raw)
    self.saved = validate(raw)
    if raw ~= nil and not self.saved then E:Log("Ignored invalid saved live take") end
end

function Take:Arm()
    if R.RecordingSession and R.RecordingSession.active then return end
    if E.state ~= "idle" then return end
    if not self.armed then
        local ok, reason = E:Allowed()
        if not ok then self.note = reason; E:Notify(); return nil, reason end
    end
    self.armed = not self.armed
    self.note = self.armed and "Armed. Hold a direction to roll." or nil
    E:Notify()
end

function Take:Begin()
    if not self.armed then return end
    self.armed, self.note = false, nil
    self.record = {ms = 0, last = {0, 0, 0}, samples = {{0, 0, 0, 0}}}
end

local function rounded(rate)
    return math.floor(rate * units + .5)
end

local function rowAt(time, a, b, fraction)
    local row = {time}
    for i = 1, 3 do row[i + 1] = rounded(a[i] + (b[i] - a[i]) * fraction) end
    return row
end

function Take:Finish()
    local r = self.record
    self.record = nil
    if not r then return end
    local ms = math.floor(r.ms + .5)
    if ms < 1 or not r.moved then self.note = "No movement sampled."; return end
    local rows = r.samples
    if rows[#rows][1] < ms then rows[#rows + 1] = rowAt(ms, r.last, r.last, 0) end
    self.draft = {version = 1, ms = ms, samples = rows}
    self.note = string.format("Take ready   %.1f s", ms / 1000)
end

function Take:Sample(dt, rates)
    local r = self.record
    if not r then return end
    local elapsed = dt * 1000
    r.moved = r.moved or rates[1] ~= 0 or rates[2] ~= 0 or rates[3] ~= 0
    local finish = math.min(maxMs, r.ms + elapsed)
    local tick = #r.samples * stepMs
    while tick <= finish do
        local fraction = (tick - r.ms) / elapsed
        r.samples[#r.samples + 1] = rowAt(tick, r.last, rates, fraction)
        tick = tick + stepMs
    end
    r.ms, r.last = finish, rates
    if finish >= maxMs then self:Finish() end
end

function Take:Clear(reason)
    self.replay = nil
    if self.armed and reason ~= "Live operator" then self.armed, self.note = false, nil end
    if self.record then
        if reason == nil or reason == "Control returned" or reason == "Stopped" then self:Finish()
        else self.record, self.note = nil, "Recording interrupted." end
    end
end

function Take:Save()
    if self.record then E:ReleaseMotion("Control returned") end
    if not self.draft then return nil, "Record a live take first" end
    local candidate = validate(self.draft)
    if not candidate then return nil, "Invalid live take" end
    if type(R.PersistLiveTake) ~= "function" then return nil, "Character profile is unavailable" end
    local ok, reason = R.PersistLiveTake(candidate)
    if not ok then self.note = reason or "Character profile is read-only"; E:Notify(); return nil, self.note end
    self.saved, self.draft = candidate, nil
    self.note = string.format("Saved on this character   %.1f s", candidate.ms / 1000)
    E:Notify()
    return true
end

local function play(take, name)
    if Take.armed or Take.record then return nil, "Finish or disarm the current recording first." end
    if not take then return nil, "Save a live take first" end
    local need = {0, 0, 0}
    for _, row in ipairs(take.samples) do
        for i = 1, 3 do
            need[i] = math.max(need[i], math.abs(row[i + 1]) / units)
        end
    end
    if need[3] > 0 then
        local limit = R.Adapter:MaxZoomRate()
        if not limit or need[3] > limit + rateRounding then return nil, "Recording exceeds the available zoom speed. Choose a slower replay." end
    end
    if not E:ReleaseMotion("Ready", true) then return nil, E.message end
    local ok, reason = E:Allowed()
    if not ok then return E:Fail(reason) end
    ok, reason = R.Adapter:Check(need[1], need[2], need[3])
    if not ok then return E:Fail(reason) end
    local replay = {take = take, name = name, ms = 0, index = 1}
    Take.replay = replay
    E.job, E.state, E.message = nil, "live-replay", name and ("Replaying " .. name) or "Replaying saved live take"
    ok, reason = E:Arm()
    if not ok or Take.replay ~= replay or not name then return ok, reason end
    -- An in point can land in the middle of a move. Apply that boundary
    -- immediately so the first rendered frame has the requested direction.
    local first = take.samples[1]
    if not take.edited and first[2] == 0 and first[3] == 0 and first[4] == 0 then return true end
    ok, reason = R.Adapter:Apply(first[2] / units, first[3] / units, first[4] / units, 0)
    if not ok then return E:Fail(reason) end
    return true
end

function Take:Play()
    return play(self.saved)
end

function Take:PlayRecording(raw, name, edit)
    if self.armed or self.record then return nil, "Finish or disarm the current recording first." end
    local copy = self:CopyRecording(raw)
    if not copy or not R.ValidName(name) then return nil, "Invalid movement recording." end
    if edit then
        local problem
        copy, problem = R.DeskReplay:Prepare(copy, edit)
        if not copy then return nil, problem end
    end
    return play(copy, name)
end

function R.Operator:AdvanceReplay(dt)
    local j = Take.replay
    local take = j.take
    j.ms = j.ms + dt * 1000
    if j.ms >= take.ms then return E:ReleaseMotion("Take complete", true) end
    local rows = take.samples
    while rows[j.index + 1][1] <= j.ms do j.index = j.index + 1 end
    local a, b = rows[j.index], rows[j.index + 1]
    local t = (j.ms - a[1]) / (b[1] - a[1])
    local function rate(k) return (a[k] + (b[k] - a[k]) * t) / units end
    local zoom = rate(4)
    if zoom ~= 0 then
        local limit = R.Adapter:MaxZoomRate()
        if not limit or math.abs(zoom) > limit + rateRounding then return E:Fail("Zoom speed changed. Reframe and choose a slower replay.") end
    end
    local ok, reason = R.Adapter:Apply(rate(2), rate(3), zoom, dt)
    if not ok then return E:Fail(reason) end
end

function Take:Caption()
    if self.record then return string.format("Recording live rates   %.1f / 60 s", self.record.ms / 1000) end
    if self.note then return self.note end
    if self.saved then return string.format("Saved live take   %.1f s", self.saved.ms / 1000) end
    return "Arm, hold to film, then save. Replay from your framing."
end

function CineRig_LiveArm() Take:Arm() end
function CineRig_LiveSave() Take:Save() end
function CineRig_LiveReplay() Take:Play() end
BINDING_NAME_CINERIG_LIVE_ARM = "Arm or disarm a live take"
BINDING_NAME_CINERIG_LIVE_SAVE = "Save or replace this character's live take"
BINDING_NAME_CINERIG_LIVE_REPLAY = "Replay saved live take"
