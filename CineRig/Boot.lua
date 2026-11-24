local addon, R = ...
local E = R.Engine
BINDING_HEADER_CINERIG = "CineRig"
BINDING_NAME_CINERIG_PLAY = "Play selected shot or Director timeline"
BINDING_NAME_CINERIG_STOP = "Stop camera and return control"
BINDING_NAME_CINERIG_RESTORE = "Restore camera and interface"
BINDING_NAME_CINERIG_UI = "Hide or restore filming interface"
BINDING_NAME_CINERIG_RECORD_MOVEMENT = "Start or finish movement recording"
BINDING_NAME_CINERIG_REPLAY_RECORDING = "Replay selected movement recording"

function R.TransportCaption()
    if R.UI.playTarget == "DeskMotion" then return "Play out and back" end
    if R.UI.playTarget == "Recordings" then return "Replay recording" end
    if R.UI.playTarget == "Director" then return "Play timeline" end
    if R.UI.playTarget == "Moves" and R.Moves.section == "Presets" then return "Play preset" end
    return "Play shot"
end
function R.PlayTransport()
    if R.UI.playTarget == "DeskMotion" then return R.DeskMotion:PingPong() end
    if R.UI.playTarget == "Recordings" then return R.Library:PlayRecording() end
    if R.UI.playTarget == "Director" then return R.Director:PlayTimeline(false) end
    if R.UI.playTarget == "Moves" and R.Moves.section == "Presets" then return R.Patterns:Play() end
    return R.PlaySelected()
end
function CineRig_Play() R.PlayTransport() end
function CineRig_Stop() E:Stop("Control returned") end
function CineRig_Restore() E:Restore() end
-- A detached diagnostic snapshot is also available through the game's /dump.
function CineRig_GetStatus()
    return {state = E.state, generation = E.generation, walking = R.Walk.active == true,
        recording = R.LiveTake.record ~= nil, armed = R.LiveTake.armed == true,
        selectedRecording = R.Library.selectedRecording, message = E.message,
        lastIssue = E.errors[#E.errors]}
end
function CineRig_Pause() E:Pause() end
function CineRig_ToggleUI()
    local ok, reason = R.ToggleDisplay()
    if not ok then E:Fail(reason) end
end

local function say(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff67ddbcCineRig|r  " .. tostring(message)) end
end
R.Say = say

local function report(ok, reason)
    if not ok and reason then
        E:Log(reason)
        E.message = reason
        if not R.Walk.active and not R.captureSafe then say(reason) end
        E:Notify()
    end
    return ok, reason
end

local recordHeld, replayHeld = false, false
function CineRig_RecordKey(down)
    if down and not recordHeld then report(R.RecordingSession:Toggle()) end
    recordHeld = down
end
function CineRig_ReplayRecordingKey(down)
    if down and not replayHeld then report(R.Library:PlayRecording()) end
    replayHeld = down
end

-- During an ordinary walk the transport sleeps. An opted-in free cursor
-- borrows that same frame until the game returns to its normal pointer.
-- A cursor failure must leave the shot clock and the camera controls usable.
local syncingCursor = false
local function cursorError(reason)
    E:Log(reason)
    pcall(R.FreeCursor.Yield, R.FreeCursor, "Cursor unavailable. Press Restore.")
end

local function idleCursorTick()
    R.TickFreeCursor()
end

function R.UpdateFreeCursor()
    if syncingCursor then return end
    syncingCursor = true
    local f = R.FreeCursor
    local hidden = R.Adapter:DisplayShown() == false
    if not hidden then E.cursorPostroll = nil end
    local wanted = f.enabled and hidden and
        (R.Walk.active or E.state ~= "idle" or (E.cursorPostroll and R.displayOwned))
    local ok, err = pcall(f.Sync, f, wanted == true)
    if not ok then cursorError(err) end
    if E.state == "idle" then
        if f:NeedsTick() then
            if E.frame:GetScript("OnUpdate") ~= idleCursorTick then E.frame:SetScript("OnUpdate", idleCursorTick) end
        elseif E.frame:GetScript("OnUpdate") == idleCursorTick then
            E.frame:SetScript("OnUpdate", nil)
        end
    end
    syncingCursor = false
end

function R.TickFreeCursor()
    if R.Adapter:DisplayShown() ~= false then
        if R.FreeCursor:NeedsTick() then R.UpdateFreeCursor() end
        return
    end
    local ok, err = pcall(R.FreeCursor.Tick, R.FreeCursor)
    if not ok then cursorError(err) end
end
table.insert(E.listeners, R.UpdateFreeCursor)

local function slash(line)
    local cmd, args = (line or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then R.UI:Toggle()
    elseif cmd == "walk" then R.Walk:Toggle()
    elseif cmd == "rig" then report(R.Rig:Open(args))
    elseif cmd == "mark" then report(R.Markers:Drop(args))
    elseif cmd == "recordings" then R.Recordings:Open()
    elseif cmd == "record" then report(R.RecordingSession:Toggle(args))
    elseif cmd == "save" then
        local index, reason = R.Library:SaveRecording(args)
        if index then
            E:Notify()
            say("Saved movement recording: " .. R.Library.recordings[index].name)
        else report(nil, reason) end
    elseif cmd == "replay" then
        if args == "" then report(R.Library:PlayRecording())
        else
            local index = R.Library:Find("recordings", args)
            if index then report(R.Library:PlayRecording(index))
            else report(nil, "No saved movement has that name. Open /cine recordings to choose one.") end
        end
    elseif cmd == "presets" or cmd == "preset" then report(R.Patterns:Open(args))
    elseif cmd == "move" or cmd == "moves" or cmd == "nudges" then
        if args ~= "" and cmd ~= "nudges" then
            local chosen, reason = R.Moves:Select(args)
            if not chosen then say(reason); return end
        end
        R.Moves.section = cmd == "nudges" and "Nudges" or "Compose"
        R.UI:Tab("Moves")
        R.UI.panel:Show(); R.UI:Refresh()
    elseif cmd == "nudge" then
        local ok, reason = R.Nudges:Tap(args:lower())
        if not ok and reason and E.message ~= reason and not R.Walk.active and not R.captureSafe then say(reason) end
    elseif cmd == "cursor" or cmd == "subject" or cmd == "capture" then
        R.Monitor.section = "Capture"; R.UI:Tab("Monitor"); R.UI.panel:Show()
    elseif cmd == "play" then
        R.PlayTransport()
    elseif cmd == "stop" then CineRig_Stop()
    elseif cmd == "restore" or cmd == "reset" then E:Restore(); say(E.message)
    elseif cmd == "status" then say(R.StatusLine())
    elseif cmd == "pause" then E:Pause()
    elseif cmd == "ui" then CineRig_ToggleUI()
    elseif cmd == "diag" then
        R.Monitor.section = "Diagnostics"; R.UI:Tab("Monitor"); R.UI.panel:Show()
    elseif cmd == "operator" or cmd == "monitor" then
        R.UI:Tab(cmd:sub(1,1):upper() .. cmd:sub(2)); R.UI.panel:Show()
    elseif cmd == "shot" then
        for i, s in ipairs(R.Recipes) do
            if s.name:lower() == args:lower() or i == tonumber(args) then
                R.UI:Build(); R.UI:Choose(i); return
            end
        end
        say("Use /cine shot 1 to " .. #R.Recipes .. " or a recipe name.")
    elseif R.Director and R.Director.Command and R.Director:Command(cmd, args) then return
    else say("/cine rig opens Motion, Playback, Framing and Markers. Use walk, presets, record, save <name>, replay [name], recordings, moves, nudges, cursor, subject, play, stop, reset, shot, pause, operator, director, library, transfer, take, loop, preview, monitor, ui, diag or status.") end
end

SLASH_CINERIG1 = "/cine"
SlashCmdList.CINERIG = function(msg)
    local ok, err = pcall(slash, msg)
    if not ok then E:Fail(err); say(err) end
end

local startBlocks = {
    PLAYER_LEAVING_WORLD = {"world", "Changing world"},
    LOADING_SCREEN_ENABLED = {"loading", "Loading screen"},
    CINEMATIC_START = {"cinematic", "Cinematic active"},
    PLAY_MOVIE = {"movie", "Movie active"},
    PLAYER_REGEN_DISABLED = {"combat", "Combat active"},
    UNIT_ENTERED_VEHICLE = {"vehicle", "Vehicle camera active"},
}
local endBlocks = {
    PLAYER_ENTERING_WORLD = "world", LOADING_SCREEN_DISABLED = "loading",
    CINEMATIC_STOP = "cinematic", STOP_MOVIE = "movie",
    PLAYER_REGEN_ENABLED = "combat", UNIT_EXITED_VEHICLE = "vehicle",
}
local interrupts = {
    PLAYER_MOUNT_DISPLAY_CHANGED = "Mount changed", ZONE_CHANGED_NEW_AREA = "Zone changed",
    PLAYER_LOGOUT = "Logging out", PLAYER_DEAD = "Player died",
}
local events = CreateFrame("Frame")
local function initialize()
    if R.LoadData then R.LoadData() end
    R.Adapter:Watch(function(reason)
        if E.state ~= "idle" then E:ReleaseMotion(reason or "Manual control") end
    end)
end

local function onEvent(_, event, unit)
    if event == "PLAYER_LOGOUT" then
        if R.Markers.started then R.Markers:Finish() end
        R.SaveProfile()
    end
    if event == "ADDON_LOADED" then
        if unit == addon then initialize()
        elseif R.Adapter.AddonLoaded then R.Adapter:AddonLoaded(unit) end
        return
    end
    if (event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE") and unit ~= "player" then return end
    local block, clear = startBlocks[event], endBlocks[event]
    local recovering = event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD"
    if block then E.blocks[block[1]] = block[2] end
    if clear then E.blocks[clear] = nil end
    if R.displayRecoveryPending and recovering then
        R.RestoreDisplay()
    end
    if R.Cursor.previous and not R.Walk.active and recovering then
        R.Cursor:EndWalk()
    end
    if R.Viewfinder.owned and not R.Walk.active and event == "PLAYER_REGEN_ENABLED" then
        R.Viewfinder:Release()
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- Releases from the previous world can be missed while loading.
        E.blocks.vehicle, E.blocks.combat, E.blocks.cinematic, E.blocks.movie = nil, nil, nil, nil
    end
    if block or interrupts[event] or event == "PLAYER_ENTERING_WORLD" then
        if E.state ~= "idle" or R.displayOwned or R.Walk.active or R.Cursor.previous or R.Viewfinder.owned or R.RecordingSession.active or R.LiveTake.armed then
            E:Stop(block and block[2] or interrupts[event] or "Entered world")
            if R.RestoreDisplay then R.RestoreDisplay() end
        end
    end
    if recovering then
        E:RetryCameraRelease()
        R.FreeCursor:RetryPendingRelease()
    end
end
events:SetScript("OnEvent", function(...)
    local ok, err = pcall(onEvent, ...)
    if not ok then E:Fail("Event error: " .. tostring(err)) end
end)
local function register(event)
    local ok, registered = pcall(events.RegisterEvent, events, event)
    if not ok or (issecretvalue and issecretvalue(registered)) or registered ~= true then
        E.blocks.events = "Required safety event unavailable: " .. event
        E:Log(E.blocks.events)
    end
end
register("ADDON_LOADED")
for event in pairs(startBlocks) do register(event) end
for event in pairs(endBlocks) do register(event) end
for event in pairs(interrupts) do register(event) end
