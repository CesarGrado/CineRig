local _, R = ...
local L = {maxShots = 64, maxTakes = 32, maxRecordings = 24, maxSegments = 32, maxBytes = 16384}
R.Library = L

-- Copy only the fields that belong to the data format. Every loaded take owns
-- its segments so editing the working timeline cannot change a library entry.
local function plainShot(s, name)
    if not R.ValidShot(s) then return nil end
    return {name = name or s.name, duration = s.duration, yaw = s.yaw,
        pitch = s.pitch, zoom = s.zoom, ease = s.ease}
end

function L:ValidSegment(s) return R.ValidSegment(s) end

local function segment(s)
    if not L:ValidSegment(s) then return nil end
    local row = plainShot(s)
    row.trimIn, row.trimOut = s.trimIn or 0, s.trimOut or 0
    row.hold, row.join = s.hold or 0, s.join or "cut"
    return row
end

local function denseLength(rows, max)
    if type(rows) ~= "table" then return nil end
    local count, largest = 0, 0
    for key in pairs(rows) do
        if not R.Finite(key) or key < 1 or key > max or key ~= math.floor(key) then return nil end
        count = count + 1
        largest = math.max(key, largest)
    end
    if count == largest then return count end
end

local function timeline(rows, allowEmpty)
    local n = denseLength(rows, L.maxSegments)
    if not n or (n == 0 and not allowEmpty) then return nil, "Choose 1 to 32 segments." end
    local out = {}
    for i = 1, n do
        out[i] = segment(rows[i])
        if not out[i] then return nil, "Invalid settings in segment " .. i .. "." end
    end
    return out
end

local function take(name, rows)
    if not R.ValidName(name) then return nil, "Use a name of 1 to 64 bytes without controls or vertical bars." end
    local segments, err = timeline(rows)
    if not segments then return nil, err end
    return {name = name, segments = segments}
end

local function findName(rows, name)
    for i, row in ipairs(rows) do
        if row.name:lower() == name:lower() then return i end
    end
end

local function recordingName(name)
    if R.ValidName(name) then return name:match("^%s*(.-)%s*$") end
end

function L:Find(kind, name)
    if kind == "recordings" then
        local canonical = recordingName(name)
        if canonical then return findName(self.recordings, canonical) end
        return
    end
    if R.ValidName(name) and (kind == "shots" or kind == "takes") then
        return findName(self[kind], name)
    end
end

local function store(rows, entry, max, replace, duplicateMessage)
    if L.accountLocked then return nil, "Saved library format is newer or unknown. Using it read-only." end
    local i = findName(rows, entry.name)
    if i and not replace then return nil, duplicateMessage or "Name already in use. Choose another name or use Update." end
    if not i and #rows >= max then return nil, "Library full. Remove an entry first." end
    i = i or #rows + 1
    rows[i] = entry
    return i
end

function L:SaveShot(name, s, replace)
    if not R.ValidName(name) or not R.ValidShot(s) then return nil, "Check the shot name and settings." end
    return store(self.shots, plainShot(s, name), self.maxShots, replace)
end

function L:SaveTake(name, rows, replace)
    local entry, err = take(name, rows)
    if not entry then return nil, err end
    return store(self.takes, entry, self.maxTakes, replace)
end

function L:LoadTake(i)
    local s = self.takes[i]
    if not s then return nil, "Choose a saved take." end
    local copy, err = take(s.name, s.segments)
    if not copy then return nil, err end
    R.takeName, R.timeline = copy.name, copy.segments
    return true
end

local function selectRecording(name)
    L.selectedRecording = name
    if not L.characterLocked and type(CineRigCharDB) == "table" and CineRigCharDB.version == 2 then
        CineRigCharDB.selectedRecording = name
    end
end

function L:SelectRecording(index)
    local entry = self.recordings[index]
    if not entry then return nil, "Choose a saved recording." end
    selectRecording(entry.name)
    return true
end

function L:AvailableRecordingName(name)
    if self.accountLocked or self.recordingsLocked then return nil, "Saved recording library is read-only." end
    name = recordingName(name)
    if not name then return nil, "Use a name of 1 to 64 bytes without controls or vertical bars." end
    if findName(self.recordings, name) then return nil, "A recording with that name already exists." end
    if #self.recordings >= self.maxRecordings then return nil, "Library full. Remove an entry first." end
    return name
end

local function storeRecording(self, name, raw)
    local available, reason = self:AvailableRecordingName(name)
    if not available then return nil, reason end
    if not raw then return nil, "Record a movement first." end
    local copy = R.LiveTake:CopyRecording(raw)
    if not copy then return nil, "Invalid movement recording." end
    local index = #self.recordings + 1
    self.recordings[index] = {name = available, take = copy}
    -- Older CineRig versions preserve an unrecognized account schema intact.
    -- Promote only when we have actually saved a recording to protect.
    CineRigDB.version, CineRigDB.recordings = 3, self.recordings
    selectRecording(available)
    return index
end

function L:SaveRecording(name)
    local live = R.LiveTake
    if live.record or live.armed then return nil, "Finish or disarm the current recording first." end
    return storeRecording(self, name, live.draft or live.saved)
end

function L:SaveExcerpt(name, raw)
    return storeRecording(self, name, raw)
end

function L:RenameRecording(index, name)
    if self.accountLocked or self.recordingsLocked then return nil, "Saved recording library is read-only." end
    local entry = self.recordings[index]
    if not entry then return nil, "Choose a saved recording." end
    name = recordingName(name)
    if not name then return nil, "Use a name of 1 to 64 bytes without controls or vertical bars." end
    local existing = self:Find("recordings", name)
    if existing and existing ~= index then return nil, "A recording with that name already exists." end
    if self.selectedRecording == entry.name then selectRecording(name) end
    entry.name = name
    return true
end

function L:PlayRecording(index)
    if index == nil then index = self:Find("recordings", self.selectedRecording) end
    local entry = self.recordings[index]
    if not entry then return nil, "Choose a saved recording." end
    local ok, why = R.LiveTake:PlayRecording(entry.take, entry.name, entry.edit)
    if ok then selectRecording(entry.name) end
    return ok, why
end

function L:Remove(kind, index)
    if self.accountLocked then return nil, "Saved library is read-only." end
    if kind == "recordings" and self.recordingsLocked then return nil, "Saved recording library is read-only." end
    local records = (kind == "recordings" or kind == "shots" or kind == "takes") and self[kind]
    if not records or not records[index] then return nil, "Choose a saved entry." end
    if kind == "recordings" and self.selectedRecording == records[index].name then selectRecording(nil) end
    table.remove(records, index)
    return true
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

local function unhex(s)
    if #s == 0 or #s > 128 or #s % 2 ~= 0 or s:find("[^%x]") then return nil end
    local name = s:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
    if R.ValidName(name) then return name end
end

local function num(n) return string.format("%.17g", n) end

function L:Export(name, rows)
    local t, err = take(name, rows)
    if not t then return nil, err end
    local lines = {"CR1", hex(t.name)}
    for _, s in ipairs(t.segments) do
        lines[#lines + 1] = table.concat({hex(s.name), num(s.duration), num(s.yaw),
            num(s.pitch), num(s.zoom), s.ease, num(s.trimIn), num(s.trimOut), num(s.hold), s.join}, ",")
    end
    local wire = table.concat(lines, ";")
    if #wire > self.maxBytes then return nil, "Take exceeds the 16 KiB transfer limit." end
    return wire
end

-- Split with a bound on both record count and field count. Empty fields,
-- including a trailing delimiter, remain visible to validation.
local function fields(text, sep, max)
    local out, pos = {}, 1
    while #out < max do
        local i = text:find(sep, pos, true)
        out[#out + 1] = text:sub(pos, i and i - 1 or #text)
        if not i then return out end
        pos = i + 1
    end
end

local function number(s)
    if #s > 25 or not s:match("^%-?%d+%.?%d*[eE]?[+-]?%d*$") then return nil end
    local n = tonumber(s)
    if R.Finite(n) then return n end
end

function L:Import(wire)
    if type(wire) ~= "string" or #wire == 0 or #wire > self.maxBytes then
        return nil, "Paste one take of up to 16 KiB."
    end
    local records = fields(wire, ";", self.maxSegments + 2)
    if not records or #records < 3 then return nil, "Expected 1 to 32 segments." end
    if records[1] ~= "CR1" then return nil, "Unrecognized transfer format or version." end
    local name, rows = unhex(records[2]), {}
    for i = 3, #records do
        local f = fields(records[i], ",", 10)
        if not f or #f ~= 10 then return nil, "Malformed segment " .. (i - 2) .. "." end
        local s = {name = unhex(f[1]), duration = number(f[2]), yaw = number(f[3]),
            pitch = number(f[4]), zoom = number(f[5]), ease = f[6], trimIn = number(f[7]),
            trimOut = number(f[8]), hold = number(f[9]), join = f[10]}
        if s.trimIn == nil or s.trimOut == nil or s.hold == nil or not self:ValidSegment(s) then
            return nil, "Invalid settings in segment " .. (i - 2) .. "."
        end
        rows[#rows + 1] = s
    end
    return take(name, rows)
end

local function inRange(value, low, high, fallback)
    if R.Finite(value) and value >= low and value <= high then return value end
    return fallback
end

local function operator(p)
    if type(p) ~= "table" then p = {} end
    return {dial = inRange(p.dial, .25, 2, 1), fine = p.fine ~= false,
        rampUp = inRange(p.rampUp, 0, 3, .6), rampDown = inRange(p.rampDown, 0, 3, .35)}
end

local function loadVersion(db, latest)
    if db == nil then return {}, false end
    if type(db) == "table" and R.Finite(db.version) and db.version >= 1 and db.version <= latest
        and db.version == math.floor(db.version) then return db, false end
    return {}, true
end

function R.LoadData()
    local db, locked = loadVersion(CineRigDB, 3)
    L.shots, L.takes, L.accountLocked = {}, {}, locked
    L.recordings, L.recordingsLocked, L.selectedRecording = {}, false, nil
    local shots = db.version == 1 and db.presets or db.shots
    if type(shots) == "table" then
        for i = 1, L.maxShots do
            local s = plainShot(shots[i])
            if s and not findName(L.shots, s.name) then L.shots[#L.shots + 1] = s end
        end
    end
    if type(db.takes) == "table" then
        for i = 1, L.maxTakes do
            local old = db.takes[i]
            local t = type(old) == "table" and take(old.name, old.segments)
            if t and not findName(L.takes, t.name) then L.takes[#L.takes + 1] = t end
        end
    end
    if db.version == 3 and type(db.recordings) == "table" then
        -- A newer writer may keep the same account version and grow or reshape
        -- the shelf. Keep the original table when its keys outgrow this reader.
        for key in pairs(db.recordings) do
            if not R.Finite(key) or key ~= math.floor(key) or key < 1 or key > L.maxRecordings then
                L.recordingsLocked = true
                break
            end
        end
        for i = 1, L.maxRecordings do
            local old = db.recordings[i]
            if type(old) == "table" and type(old.take) == "table" then
                if R.Finite(old.take.version) and old.take.version > 1
                    and not (old.take.version == 2 and old.take.format == "excerpt") then L.recordingsLocked = true end
                local unknownEdit = type(old.edit) == "table" and old.edit.version ~= nil
                if unknownEdit then L.recordingsLocked = true end
                local name = recordingName(old.name)
                if name and not unknownEdit and not findName(L.recordings, name) then
                    local copy = R.LiveTake:CopyRecording(old.take)
                    if copy then
                        local edit = old.edit and R.DeskReplay:ReadEdit(old.edit, copy.ms)
                        L.recordings[#L.recordings + 1] = {name = name, take = copy, edit = edit}
                    end
                end
            end
        end
    end
    if not locked then
        CineRigDB = {version = db.version == 3 and 3 or 2, shots = L.shots, takes = L.takes}
        if db.version == 3 then CineRigDB.recordings = L.recordingsLocked and db.recordings or L.recordings end
    end
    local p, protected = loadVersion(CineRigCharDB, 2)
    L.characterLocked = protected
    R.selected = plainShot(p.selected or p.shot) or plainShot(R.Recipes[1])
    R.countdown = inRange(p.countdown, 0, 10, 3)
    R.operatorPrefs = operator(p.operator)
    R.nudgePrefs = R.Nudges:Normalize(p.nudges)
    R.Rig:LoadSettings(p.rig)
    R.takeName = R.ValidName(p.name) and p.name or "Stormwind reveal"
    local selected = L:Find("recordings", p.selectedRecording)
    if selected then L.selectedRecording = L.recordings[selected].name end
    R.timeline = timeline(p.timeline, true) or {segment(R.Recipes[1])}
    L.futureLiveTake = type(p.liveTake) == "table" and R.Finite(p.liveTake.version)
        and p.liveTake.version > 1 and p.liveTake or nil
    if R.LiveTake then
        if L.futureLiveTake then
            R.LiveTake:Load(nil)
            R.Engine:Log("Newer live take preserved. Its recording slot is read-only.")
        else R.LiveTake:Load(p.liveTake) end
    end
    R.SaveProfile()
    if locked or protected then R.Engine:Log("Unrecognized saved-data version preserved. See Director.") end
end

function R.SaveProfile()
    if L.characterLocked then return nil, "Saved character profile is read-only." end
    local rows, err = timeline(R.timeline, true)
    if not rows then return nil, err end
    CineRigCharDB = {version = 2, name = R.takeName, timeline = rows,
        selected = plainShot(R.selected), countdown = R.countdown, operator = operator(R.operatorPrefs),
        nudges = R.Nudges:Normalize(R.nudgePrefs), rig = R.Rig:SaveSettings(),
        selectedRecording = L.selectedRecording,
        liveTake = L.futureLiveTake or (R.LiveTake and R.LiveTake.saved)}
    return true
end

function R.PersistLiveTake(t)
    if L.futureLiveTake then return nil, "Newer live take preserved. Its recording slot is read-only." end
    if L.characterLocked or type(CineRigCharDB) ~= "table" or CineRigCharDB.version ~= 2 then
        return nil, "Saved character profile is read-only."
    end
    CineRigCharDB.liveTake = t
    return true
end
