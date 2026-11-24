local _, R = ...
local Adapter = {}
R.Adapter = Adapter

-- These are camera motion commands. Nothing here sends movement, mouse or key input.
local axes = {
    {name = "yaw", negative = "Left", positive = "Right"},
    {name = "pitch", negative = "Down", positive = "Up"},
    {name = "zoom", negative = "In", positive = "Out"},
}
local owned, external, hooked, faults = {}, {}, {}, {}
local pendingStop = {}
local lastSpeed = {}
local permitted = {}
local onTakeover, issuing, armed
local controlSerial = 0
local dynamicCam
local interface = 120105

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function Adapter:MouseLookActive()
    local ok, value = pcall(IsMouselooking)
    if not ok or (issecretvalue and issecretvalue(value)) then return nil end
    if value == true or value == 1 then return true end
    if value == false or value == nil or value == 0 then return false end
end

local function inspect(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok or (issecretvalue and issecretvalue(value)) then return nil end
    return value
end

local function buildInfo()
    if type(GetBuildInfo) == "function" then
        local ok, version, build, _, toc = pcall(GetBuildInfo)
        if ok then return tostring(version) .. " (" .. tostring(build) .. ")", toc end
    end
    return "unknown", nil
end
local build, currentInterface = buildInfo()

local function zoomScale()
    local read = C_CVar and C_CVar.GetCVar or GetCVar
    local speed = tonumber(inspect(read, "cameraZoomSpeed"))
    if finite(speed) and speed > 0 then return speed end
end

function Adapter:Distance()
    local distance = inspect(GetCameraZoom)
    if finite(distance) and distance >= 0 then return distance end
end

function Adapter:MaxZoomRate()
    local speed = zoomScale()
    if speed then return math.min(8, speed) end
end

-- Use post-hooks so the player's command always runs. Never replace a binding
-- or hook an input handler using a pre-hook. CineRig's own calls are ignored.
local function observe(name, fn)
    if hooked[name] or type(_G[name]) ~= "function" or type(hooksecurefunc) ~= "function" then return end
    hooked[name] = pcall(hooksecurefunc, name, function(...)
        -- Another addon's post-hook can issue a distinct native camera command
        -- before our outer call returns. Ignore only our one matching post-hook.
        local arg = ...
        if issuing and not issuing.observed and issuing.name == name and issuing.count == select("#", ...)
            and not (issecretvalue and issecretvalue(arg)) and arg == issuing.arg then
            issuing.observed = true
            return
        end
        fn(...)
    end)
end

local function takeover(reason)
    if armed then
        controlSerial = controlSerial + 1
        if onTakeover then onTakeover(reason) end
    end
end

-- A successful Stop clears only that direction's previous release failure.
-- A fault in a Start command still disables its axis for this session.
local function stopped(axis, stem)
    if faults[axis] == stem .. "Stop failed" then faults[axis] = nil end
end

local function watchDirection(axis, dir)
    local stem = "MoveView" .. dir
    observe(stem .. "Start", function(speed)
        external[dir] = (issecretvalue and issecretvalue(speed)) or speed ~= 0 or nil
        -- The incoming command now owns this direction. Release the other
        -- directions normally, but never issue a Stop for its new owner.
        if owned[axis] == dir then owned[axis], pendingStop[axis] = nil, nil end
        takeover("Camera input took control")
    end)
    observe(stem .. "Stop", function()
        external[dir] = nil
        stopped(axis, stem)
        if owned[axis] == dir then owned[axis], pendingStop[axis] = nil, nil end
        takeover("Camera input took control")
    end)
end

local function watchWheel(name)
    observe(name, function()
        -- The stock camera binding finishes a held zoom with a relative zoom
        -- call instead of MoveViewIn/OutStop. Yield to its new distance target.
        stopped("zoom", "MoveViewIn")
        stopped("zoom", "MoveViewOut")
        external.In, external.Out, owned.zoom, pendingStop.zoom = nil, nil, nil, nil
        takeover("Manual zoom took control")
    end)
end

local function watchLook(stem)
    observe(stem .. "Start", function()
        external[stem] = true
        takeover("Player took camera control")
    end)
    observe(stem .. "Stop", function() external[stem] = nil end)
end

function Adapter:Watch(callback)
    onTakeover = callback
    dynamicCam = inspect(C_AddOns and C_AddOns.IsAddOnLoaded, "DynamicCam")
    for _, axis in ipairs(axes) do
        watchDirection(axis.name, axis.negative)
        watchDirection(axis.name, axis.positive)
    end
    watchWheel("CameraZoomIn")
    watchWheel("CameraZoomOut")
    watchLook("CameraOrSelectOrMove")
    watchLook("TurnOrAction")
    watchLook("Mouselook")
    for _, name in ipairs({"SetView", "NextView", "PrevView", "ResetView", "FlipCameraYaw", "CenterCamera"}) do
        observe(name, function() takeover("Player or another camera took control") end)
    end
end

function Adapter:AddonLoaded(name)
    if name == "DynamicCam" then
        dynamicCam = true
        takeover("DynamicCam loaded. Disable it and reload to film.")
    end
end

local function available(axis)
    if faults[axis.name] or currentInterface ~= interface or not WOW_PROJECT_MAINLINE
        or WOW_PROJECT_MAINLINE ~= WOW_PROJECT_ID then return false end
    for _, dir in ipairs({axis.negative, axis.positive}) do
        local stem = "MoveView" .. dir
        if type(_G[stem .. "Start"]) ~= "function" or type(_G[stem .. "Stop"]) ~= "function"
            or not hooked[stem .. "Start"] or not hooked[stem .. "Stop"] then return false end
    end
    if axis.name == "zoom" then return zoomScale() ~= nil and hooked.CameraZoomIn and hooked.CameraZoomOut end
    return true
end

function Adapter:Status()
    local result = {owner = next(owned) and "CineRig" or "Released", build = build}
    for _, axis in ipairs(axes) do result[axis.name] = not not available(axis) end
    return result
end

local function contextReason(passive)
    if WOW_PROJECT_MAINLINE == nil or WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE or currentInterface ~= interface then
        return "Camera adapter requires Retail interface 120105"
    end
    if inspect(IsPlayerInWorld) ~= true then return "Wait until the player is in the world" end
    if inspect(InCombatLockdown) ~= false then return "Camera unavailable during combat lockdown" end
    if inspect(InCinematic) ~= false then return "Camera unavailable during a cinematic" end
    if inspect(UnitInVehicle, "player") ~= false or inspect(UnitOnTaxi, "player") ~= false then
        return "Camera unavailable in a vehicle or on a taxi"
    end
    if C_HouseEditor and inspect(C_HouseEditor.IsHouseEditorActive) ~= false then return "Housing editor active or unavailable" end
    if MovieFrame and inspect(MovieFrame.IsShown, MovieFrame) ~= false then return "Movie active or unavailable" end
    if passive then
        for axis in pairs(owned) do
            if faults[axis] then return "Use Restore to release " .. axis end
        end
        return
    end
    if dynamicCam == nil then return "Camera addon state unavailable" end
    if dynamicCam then return "DynamicCam is loaded. Disable it and reload to run a camera move." end
    if not (hooked.CameraOrSelectOrMoveStart and hooked.CameraOrSelectOrMoveStop
        and hooked.TurnOrActionStart and hooked.TurnOrActionStop) then
        return "World-camera takeover detection unavailable"
    end
    -- A right-drag handoff may end mouse-look inside the native client without
    -- calling the global MouselookStop that our post-hook normally observes.
    local looking = Adapter:MouseLookActive()
    if looking == nil then return "Cannot read native mouse-look state" end
    if looking == false then external.Mouselook = nil end
    if looking or next(external) then return "Release the camera control before running a move" end
end

function Adapter:InterruptReason(passive)
    return contextReason(passive)
end

function Adapter:Check(yaw, pitch, zoom)
    local reason = contextReason()
    if reason then return nil, reason end
    local rates = {yaw, pitch, zoom}
    for i, axis in ipairs(axes) do
        if owned[axis.name] and faults[axis.name] then return nil, "Use Restore to release " .. axis.name end
        if not finite(rates[i]) then return nil, "Invalid " .. axis.name .. " speed" end
        if rates[i] ~= 0 and not available(axis) then
            return nil, faults[axis.name] or ("Camera " .. axis.name .. " unavailable")
        end
    end
    for i, axis in ipairs(axes) do
        if rates[i] ~= 0 then permitted[axis.name] = true end
    end
    armed = true
    return true
end

local function command(name, ...)
    local previous = issuing
    issuing = {name = name, count = select("#", ...), arg = (...)}
    local ok = pcall(_G[name], ...)
    issuing = previous
    if not ok then return nil, name .. " failed" end
    return true
end

local function releaseAxis(axis)
    local dir = owned[axis]
    if not dir then return true end
    -- Consume the request first so an event delivered by a native post-hook
    -- cannot re-enter the same retry. Another refusal puts it back below.
    pendingStop[axis] = nil
    local stem = "MoveView" .. dir
    -- Zero CineRig's continuous zoom before releasing it. Never issue a
    -- discrete zoom step, snap to a distance or clear a player's view slot.
    if axis == "zoom" then
        command(stem .. "Start", 0)
        if owned[axis] ~= dir then return true end
    end
    local ok, err = command(stem .. "Stop")
    if owned[axis] ~= dir then return true end
    if ok then
        owned[axis], lastSpeed[axis] = nil, nil
        stopped(axis, stem)
    else
        pendingStop[axis] = dir
        faults[axis] = faults[axis] or err
    end
    return ok, err
end

function Adapter:RetryPendingRelease()
    local attempted = false
    for _, axis in ipairs(axes) do
        local dir = pendingStop[axis.name]
        if dir and owned[axis.name] == dir then
            attempted = true
            releaseAxis(axis.name)
        end
    end
    return next(pendingStop) == nil, attempted
end

function Adapter:Release()
    controlSerial = controlSerial + 1
    armed = false
    permitted = {}
    local problem
    for _, axis in ipairs(axes) do
        local _, err = releaseAxis(axis.name)
        problem = problem or err
    end
    if problem then return false, problem end
    return true
end

local function drive(axis, rate, serial)
    local direction
    if rate > 0 then direction = axis.positive elseif rate < 0 then direction = axis.negative end
    if direction ~= owned[axis.name] then
        local ok, err = releaseAxis(axis.name)
        if not ok or controlSerial ~= serial then return nil, err end
    end
    if not direction then return true, nil, 0 end
    if not permitted[axis.name] then return nil, "Unarmed " .. axis.name .. " axis" end
    if faults[axis.name] then return nil, faults[axis.name] end
    local speed = math.abs(rate)
    if axis.name == "zoom" then
        local scale = zoomScale()
        if not scale then return nil, "Current zoom speed is unavailable" end
        if controlSerial ~= serial then return end
        rate = math.max(-scale, math.min(scale, rate))
        speed = math.abs(rate) / scale
    end
    -- Record ownership before asking the engine to start. Even a partial
    -- failure can then be unwound without touching unrelated directions.
    speed = math.min(1, speed)
    if owned[axis.name] == direction and lastSpeed[axis.name] == speed then return true, nil, rate end
    owned[axis.name], lastSpeed[axis.name] = direction, speed
    local ok, err = command("MoveView" .. direction .. "Start", speed)
    if not ok and controlSerial == serial then faults[axis.name] = err end
    return ok, err, rate
end

function Adapter:Apply(yaw, pitch, zoom, dt)
    if not armed then return nil, "Camera is not armed" end
    if not finite(dt) or dt < 0 or not finite(yaw) or not finite(pitch) or not finite(zoom) then
        self:Release()
        return nil, "Invalid camera sample"
    end
    local rates = {yaw, pitch, math.max(-8, math.min(8, zoom))}
    local serial = controlSerial
    for i, axis in ipairs(axes) do
        local ok, reason, applied = drive(axis, rates[i], serial)
        if controlSerial ~= serial then return true, nil, 0 end
        if not ok then
            self:Release()
            return nil, reason
        end
        rates[i] = applied
    end
    return true, nil, rates[3]
end
