local _, R = ...
local V = {owned = false}
R.Viewfinder = V

local hooked, issuing, observed, held = {}, nil, false, false
local function looking()
    return R.Adapter:MouseLookActive()
end

local function watch()
    if type(IsMouselooking) ~= "function" or type(hooksecurefunc) ~= "function" then return false end
    for _, name in ipairs({"MouselookStart", "MouselookStop", "TurnOrActionStart", "CameraOrSelectOrMoveStart"}) do
        if type(_G[name]) ~= "function" then return false end
        if not hooked[name] then
            local entry = name
            hooked[name] = pcall(hooksecurefunc, entry, function()
                -- The stock world-click bindings and other addons can claim
                -- the cursor. Never issue a competing stop or reacquire it.
                if issuing == entry and not observed then
                    observed = true
                elseif entry ~= "MouselookStop" or looking() == false then
                    V.owned = false
                end
            end)
            if not hooked[name] then return false end
        end
    end
    return true
end

local function issue(name)
    local previous, alreadyObserved = issuing, observed
    issuing, observed = name, false
    local ok = pcall(_G[name])
    issuing, observed = previous, alreadyObserved
    return ok
end

function V:Release()
    if not self.owned or issuing == "MouselookStop" then return true end
    if looking() ~= false then
        issue("MouselookStop")
        if self.owned and looking() ~= false then
            return nil, "Mouse-look release unconfirmed. Press Restore to retry."
        end
    end
    self.owned = false
    return true
end

local function toggle()
    if V.owned then return V:Release() end
    if not R.Walk.active then return nil, "Start a walking session before using viewfinder mouse-look." end
    local ok, reason = R.Engine:Allowed(true)
    if not ok then return nil, reason end
    if not watch() then return nil, "Viewfinder mouse-look unavailable. Use the normal mouse-look binding." end
    local active = looking()
    if active == nil then return nil, "Cannot read native mouse-look state." end
    if active then return nil, "Another input already controls mouse-look." end
    local checked, pressed = pcall(IsMouseButtonDown)
    if not checked or (issecretvalue and issecretvalue(pressed)) or pressed ~= false then
        return nil, "Release the mouse buttons before enabling viewfinder mouse-look."
    end
    -- Untimed walking and a fully manual walkthrough can keep running.
    -- A user choosing mouse steering gives up any automated camera move.
    local e = R.Engine
    if e.state ~= "idle" and not (e.job and e.job.passive) then
        if not e:ReleaseMotion("Viewfinder mouse-look", true) then return nil, e.message end
    end
    V.owned = true
    ok = issue("MouselookStart")
    if ok and V.owned and looking() == true then return true end
    if not V.owned then return nil, "Mouse-look control changed during handoff." end
    -- A native call may change state before an exception is reported.
    -- Release a partially acquired mode unless another input already took it.
    local released, err = V:Release()
    if not released then return nil, err end
    return nil, "Native mouse-look did not engage. Use your normal mouse-look binding."
end

-- Only this actual keybinding starts mouse-look. No OnUpdate, timer, walk
-- start, chat command or recovery path invokes MouselookStart.
function CineRig_ViewfinderKey(down)
    if not down then held = false; return end
    if held then return end
    held = true
    local called, ok, reason = pcall(toggle)
    if not called then reason = tostring(ok); ok = false end
    if not ok then
        R.Engine:Log(reason)
        R.Engine.message = reason
        if not R.Walk.active and not R.captureSafe and R.Say then R.Say(reason) end
    end
    R.Engine:Notify()
end

BINDING_NAME_CINERIG_VIEWFINDER = "Toggle viewfinder mouse-look"
