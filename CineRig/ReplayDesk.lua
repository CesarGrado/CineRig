local _, R = ...
local UI, L = R.UI, R.Library
local Desk = {}
R.DeskReplay = Desk
local speeds = {.25, .5, .75, 1, 1.25, 1.5, 2}

local function source()
    local index = L:Find("recordings", L.selectedRecording)
    return index and L.recordings[index], index
end

local function options(entry)
    return entry.edit or {speed = 1, reverse = false, inMs = 0, outMs = entry.take.ms}
end

function Desk:ReadEdit(raw, duration)
    if type(raw) ~= "table" or raw.version ~= nil or type(raw.reverse) ~= "boolean" then return end
    local first, last = raw.inMs, raw.outMs
    if not R.Finite(first) or not R.Finite(last) or first ~= math.floor(first) or last ~= math.floor(last)
        or first < 0 or last > duration or last <= first then return end
    for _, speed in ipairs(speeds) do
        if raw.speed == speed then return {speed = speed, reverse = raw.reverse, inMs = first, outMs = last} end
    end
end

-- Read the exact rate at a cut boundary between two recorded samples.
-- This also handles an excerpt whose first and last sample intervals are short.
local function boundary(rows, time, relative)
    local lo, hi = 1, #rows
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if rows[mid][1] <= time then lo = mid else hi = mid end
    end
    local a, b = rows[lo], rows[hi]
    local fraction = (time - a[1]) / (b[1] - a[1])
    local row = {relative}
    for k = 2, 4 do row[k] = a[k] + fraction * (b[k] - a[k]) end
    return row
end

local function crop(take, first, last)
    local rows = {boundary(take.samples, first, 0)}
    for _, row in ipairs(take.samples) do
        if row[1] > first and row[1] < last then
            rows[#rows + 1] = {row[1] - first, row[2], row[3], row[4]}
        end
    end
    rows[#rows + 1] = boundary(take.samples, last, last - first)
    return rows
end

-- The time substitution is t/speed and the new velocity is speed*v.
-- Reversing traverses the clipped knots in reverse order with the opposite
-- velocity on all three axes. The recorded source always keeps its own rows.
function Desk:Prepare(take, raw)
    local edit = self:ReadEdit(raw, take.ms)
    if not edit then return nil, "Choose valid in and out times within this recording." end
    local rows = crop(take, edit.inMs, edit.outMs)
    local span = edit.outMs - edit.inMs
    local duration = span / edit.speed
    local sign = edit.reverse and -1 or 1
    local zoomLimit = R.Adapter:MaxZoomRate()
    local result, zoomUsed = {}, false
    for i = 1, #rows do
        local row = rows[edit.reverse and (#rows - i + 1) or i]
        local time = edit.reverse and (span - row[1]) or row[1]
        local yaw = sign * row[2] * edit.speed
        local pitch = sign * row[3] * edit.speed
        local zoom = sign * row[4] * edit.speed
        if math.abs(yaw) > 10000 or math.abs(pitch) > 10000 then
            return nil, "This speed exceeds the turn limit in this range. Choose a slower speed."
        end
        if zoom ~= 0 then
            if not zoomLimit or math.abs(zoom) > zoomLimit * 10000 then
                return nil, "This range exceeds the available zoom speed. Choose a slower speed or a different range."
            end
            zoomUsed = true
        end
        result[i] = {time / edit.speed, yaw, pitch, zoom}
    end
    return {ms = duration, samples = result, edited = true, zoomUsed = zoomUsed}
end

function Desk:SetEdit(speed, reverse, first, last)
    local entry = source()
    if not entry then return nil, "Choose a saved recording first." end
    if L.accountLocked or L.recordingsLocked then return nil, "The recording library is read-only." end
    local edit = self:ReadEdit({speed = speed, reverse = reverse, inMs = first, outMs = last}, entry.take.ms)
    if not edit then return nil, "Use in and out times inside the recording, with Out after In." end
    if speed == 1 and not reverse and first == 0 and last == entry.take.ms then
        entry.edit = nil
    else
        local prepared, reason = self:Prepare(entry.take, edit)
        if not prepared then return nil, reason end
        entry.edit = edit
    end
    return true
end

function Desk:SaveExcerpt(name)
    local entry = source()
    if not entry then return nil, "Choose a saved recording first." end
    local edit = options(entry)
    local rows = crop(entry.take, edit.inMs, edit.outMs)
    local duration = edit.outMs - edit.inMs
    local regular = #rows == math.ceil(duration / 50) + 1
    for i, row in ipairs(rows) do
        regular = regular and row[1] == math.min((i - 1) * 50, duration)
        for k = 2, 4 do row[k] = math.floor(row[k] + .5) end
    end
    -- An off-grid start keeps every original interior knot; resampling it on
    -- the 50 ms grid would erase a short acceleration or reverse its timing.
    local cut = {version = regular and 1 or 2, format = not regular and "excerpt" or nil,
        ms = duration, samples = rows}
    local index, reason = L:SaveExcerpt(name, cut)
    if not index then return nil, reason end
    if edit.speed ~= 1 or edit.reverse then
        L.recordings[index].edit = {speed = edit.speed, reverse = edit.reverse, inMs = 0, outMs = duration}
    end
    return index
end

local function seconds(ms)
    return string.format("%.3f", ms / 1000):gsub("0+$", ""):gsub("%.$", "")
end

local function readMs(box)
    local value = tonumber(box:GetText())
    if R.Finite(value) and value >= 0 and value <= 60 then return math.floor(value * 1000 + .5) end
end

function Desk:Build(parent)
    if self.name then return end
    self.name = UI.Label(parent, 16, 4, 260, "GameFontNormal", "")
    self.name:SetWordWrap(false)
    local function choose(delta)
        local _, index = source()
        if not index then index = 0 end
        local ok, why = L:SelectRecording(index + delta)
        self.message = ok and nil or why
    end
    self.prev = UI.Button(parent, 284, 0, 46, "Prev", function() choose(-1) end)
    self.next = UI.Button(parent, 337, 0, 47, "Next", function() choose(1) end)
    self.slower = UI.Button(parent, 16, 39, 72, "Slower", function() self:StepSpeed(-1) end)
    self.rate = UI.Label(parent, 96, 44, 100, "GameFontHighlight", "")
    self.faster = UI.Button(parent, 182, 39, 72, "Faster", function() self:StepSpeed(1) end)
    self.direction = UI.Button(parent, 261, 39, 123, "", function()
        local entry = source()
        if entry then
            local e = options(entry)
            local ok, why = self:SetEdit(e.speed, not e.reverse, e.inMs, e.outMs)
            self.message = ok and nil or why
        end
    end)
    UI.Label(parent, 16, 82, 71, "GameFontNormal", "In (sec)")
    UI.Label(parent, 130, 82, 76, "GameFontNormal", "Out (sec)")
    self.from = UI.EditBox(parent, 16, 101, 102, 8)
    self.to = UI.EditBox(parent, 130, 101, 102, 8)
    self.apply = UI.Button(parent, 241, 101, 143, "Apply range", function() self:ApplyRange() end)
    self.range = UI.Label(parent, 16, 138, 368, "GameFontHighlightSmall", "")
    self.preview = UI.Button(parent, 16, 167, 178, "Replay edit", function()
        local ok, why = L:PlayRecording()
        self.message = ok and nil or why
    end, true)
    self.reset = UI.Button(parent, 202, 167, 182, "Reset playback", function()
        local entry = source()
        if entry then
            local ok, why = self:SetEdit(1, false, 0, entry.take.ms)
            self.message = ok and "Full recording restored." or why
            if ok then self.lastEntry = nil end
        end
    end)
    UI.Label(parent, 16, 216, 368, "GameFontNormal", "Save the applied edit as a new recording")
    self.copyName = UI.EditBox(parent, 16, 236, 205, 64)
    local function save()
        local index, why = self:SaveExcerpt(self.copyName:GetText())
        if index then
            self.copyName:ClearFocus()
            self.copyName:SetText("")
            self.message = "Saved excerpt."
        else self.message = why end
    end
    self.save = UI.Button(parent, 231, 236, 153, "Save excerpt", save)
    self.status = UI.Label(parent, 16, 275, 368, "GameFontDisableSmall", "")
    self.openLibrary = UI.Button(parent, 16, 313, 158, "Open recordings", function() R.Recordings:Open() end)
    for _, box in ipairs({self.from, self.to}) do
        box:SetScript("OnEnterPressed", function(b) self:ApplyRange(); b:ClearFocus(); UI:Refresh() end)
    end
    self.copyName:SetScript("OnEnterPressed", function() save(); UI:Refresh() end)
    self:Refresh()
end

function Desk:StepSpeed(delta)
    local entry = source()
    if not entry then return end
    local e = options(entry)
    for i, speed in ipairs(speeds) do
        if speed == e.speed and speeds[i + delta] then
            local ok, why = self:SetEdit(speeds[i + delta], e.reverse, e.inMs, e.outMs)
            self.message = ok and nil or why
            return
        end
    end
end

function Desk:ApplyRange()
    local entry = source()
    if not entry then return end
    local e = options(entry)
    local ok, why = self:SetEdit(e.speed, e.reverse, readMs(self.from), readMs(self.to))
    self.message = ok and "Range applied." or why
    if ok then
        self.from:ClearFocus()
        self.to:ClearFocus()
        self.lastEntry = nil
    end
end

function Desk:Refresh()
    if not self.name then return end
    local entry, index = source()
    local e = entry and options(entry)
    local editable = entry and not L.accountLocked and not L.recordingsLocked
    self.prev:SetEnabled(index and index > 1 or false)
    self.next:SetEnabled((index or 0) < #L.recordings)
    self.slower:SetEnabled(editable and e.speed > speeds[1] or false)
    self.faster:SetEnabled(editable and e.speed < speeds[#speeds] or false)
    self.direction:SetEnabled(editable and true or false)
    self.apply:SetEnabled(editable and true or false)
    self.save:SetEnabled(editable and true or false)
    self.reset:SetEnabled(editable and true or false)
    self.preview:SetEnabled(entry ~= nil and not R.LiveTake.armed and not R.LiveTake.record)
    self.name:SetText(entry and entry.name or "Choose a named recording")
    self.rate:SetText(e and string.format("%g× speed", e.speed) or "")
    self.direction:SetText(e and e.reverse and "Reverse" or "Forward")
    self.range:SetText(e and string.format("Applied %s–%s s   ·   playback %.2f s",
        seconds(e.inMs), seconds(e.outMs), (e.outMs - e.inMs) / (1000 * e.speed)) or "")
    if self.lastEntry ~= entry then
        self.lastEntry = entry
        self.from:SetText(e and seconds(e.inMs) or "")
        self.to:SetText(e and seconds(e.outMs) or "")
    end
    self.status:SetText(self.message or (#L.recordings == 0 and "Save a movement in Director > Recordings to edit its playback."
        or "Playback choices follow this recording, including its replay binding."))
end
