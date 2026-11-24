local _, R = ...
local E, T = R.Engine, R.LiveTake
local Session = {active = false}
R.RecordingSession = Session

-- A named recording may contain several gestures with quiet intervals.
-- The first Operator or Nudge command starts its clock. Legacy quick takes
-- still finish automatically when a single performance eases to rest.
local function saveFinished(name, previousDraft)
    if not name or not T.draft or T.draft == previousDraft then return true end
    local index, reason = R.Library:SaveRecording(name)
    if index then
        T.note = "Saved movement: " .. R.Library.recordings[index].name
    else
        T.note = (reason or "Save failed.") .. " Your move is still available in Recordings."
        E:Log(T.note)
    end
    E:Notify()
    return index ~= nil, index == nil and T.note or nil
end

function Session:Toggle(name)
    if name == "" then name = nil end
    if self.active then
        if name then return nil, "Finish this recording before starting another." end
        if T.record then
            local pendingName, previousDraft = self.name, self.previousDraft
            if not E:ReleaseMotion("Control returned", true) then return nil, E.message end
            return saveFinished(pendingName, previousDraft)
        end
        self.active, self.name, self.previousDraft, T.armed = false, nil, nil, false
        T.note = "Recording cancelled before the first move."
        E:Notify()
        return true
    end
    if E.state ~= "idle" or T.armed or T.record then
        return nil, "Finish the current movement or disarm the quick take first."
    end
    local ok, reason = E:Allowed()
    if not ok then return nil, reason end
    if name then
        name, reason = R.Library:AvailableRecordingName(name)
        if not name then return nil, reason end
    end
    self.name, self.previousDraft = name, name and T.draft or nil
    self.active, T.armed = true, true
    T.note = "Ready. Hold an Operator key or tap a Nudge to start recording."
    E:Notify()
    return true
end

function Session:OnClear(reason)
    if not self.active or reason == "Live operator" then return end
    self.active, self.name, self.previousDraft = false, nil, nil
    if T.record then
        T:Finish()
    elseif T.armed then
        T.armed, T.note = false, "Recording ended before the first move."
    end
end

function Session:AfterSample()
    if self.active and not T.record then
        -- The recorder reached its duration limit. A held manual control
        -- can continue past this point without changing the finished take.
        local name, previousDraft = self.name, self.previousDraft
        self.active, self.name, self.previousDraft = false, nil, nil
        saveFinished(name, previousDraft)
    end
end
