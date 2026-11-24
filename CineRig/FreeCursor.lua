local addon, R = ...
local F = {enabled = false, active = false, wanted = false, suppressed = false}
R.FreeCursor = F

local texture = "Interface\\AddOns\\" .. addon .. "\\CursorBlank"
local cover, updating, shapeOwned, software, releasePending
local issuing, argument, observed
local hooks = {}
local pendingNotice = "Cursor restore pending. Press Restore to retry."

local function secret(value)
    return issecretvalue and issecretvalue(value)
end

-- Secure or occupied cursors belong to the game, including spell targeting.
-- A normal empty cursor and the legacy clear targeting state can both be nil.
local function cursorFree()
    local ok, item = pcall(GetCursorInfo)
    if not ok or secret(item) then return end
    if item ~= nil then return false end
    local checked, targeting = pcall(SpellIsTargeting)
    if not checked or secret(targeting) then return end
    return targeting == false or targeting == nil or targeting == 0
end

local function updateDriver()
    if R.UpdateFreeCursor then R.UpdateFreeCursor() end
end

local function remember(reason)
    if reason and reason ~= F.notice then
        F.notice = reason
        R.Engine:Log(reason)
    end
end

local function callShape(name, value)
    local previous, oldArgument, alreadyObserved = issuing, argument, observed
    issuing, argument, observed = name, value, false
    local ok, result
    if value == nil then ok, result = pcall(_G[name])
    else ok, result = pcall(_G[name], value) end
    issuing, argument, observed = previous, oldArgument, alreadyObserved
    return ok, result
end

local function release()
    F.active = false
    local hidden = true
    if cover then
        local ok, visible = pcall(cover.IsShown, cover)
        if not ok or secret(visible) or visible ~= false then
            pcall(cover.Hide, cover)
            ok, visible = pcall(cover.IsShown, cover)
        end
        hidden = ok and not secret(visible) and visible == false
        if not hidden then pcall(cover.SetMouseMotionEnabled, cover, false) end
    end
    if shapeOwned then
        local free = cursorFree()
        if free then
            local ok = callShape("ResetCursor")
            if ok then shapeOwned = false end
        elseif free == false then
            -- The engine's new item or target has already superseded our shape.
            shapeOwned = false
        end
    end
    if software then software = not R.Cursor:ReleaseSoftware() end
    releasePending = not hidden or software or shapeOwned
    if releasePending then
        remember(pendingNotice)
        return false
    end
    if F.notice == pendingNotice then F.notice = nil end
    return true
end

function F:RetryPendingRelease()
    if releasePending and not updating and not self.active and (not self.wanted or self.suppressed) then
        release()
    end
end

function F:Yield(reason)
    if not self.wanted and not self.active then return end
    self.suppressed = true
    remember(reason)
    release()
    if not updating then updateDriver() end
end

local function otherShape(name, value)
    if issuing == name and not observed and not secret(value) and value == argument then
        observed = true
        return
    end
    if not (F.active or shapeOwned) then return end
    shapeOwned = false
    F:Yield("Another cursor action took control. The pointer is free for this take.")
end

local function prepare()
    local ok, _, _, _, interface = pcall(GetBuildInfo)
    if not ok or secret(interface) or interface ~= 120105 or not WOW_PROJECT_MAINLINE
        or WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
        return nil, "Free-cursor hiding requires Retail interface 120105."
    end
    if type(SetCursor) ~= "function" or type(ResetCursor) ~= "function" or type(GetCursorInfo) ~= "function"
        or type(SpellIsTargeting) ~= "function" or type(IsMouselooking) ~= "function"
        or type(hooksecurefunc) ~= "function" or not WorldFrame then
        return nil, "This client does not expose the required gameplay cursor controls."
    end
    for _, name in ipairs({"SetCursor", "ResetCursor", "SetCursorByMode"}) do
        if type(_G[name]) == "function" and not hooks[name] then
            local native = name
            hooks[native] = pcall(hooksecurefunc, native, function(value) otherShape(native, value) end)
            if not hooks[name] then return nil, "Cannot observe other gameplay cursor actions." end
        end
    end
    if cover then return true end
    local frame
    ok = pcall(function()
        frame = CreateFrame("Frame", nil, WorldFrame)
        frame:Hide()
        local shown = frame:IsShown()
        if secret(shown) or shown ~= false then error("Cursor surface did not hide") end
        frame:SetMouseMotionEnabled(false)
        frame:SetAllPoints(WorldFrame)
        frame:SetFrameStrata("FULLSCREEN_DIALOG")
        frame:SetMouseClickEnabled(false)
        frame:EnableMouseWheel(false)
        frame:SetPropagateMouseClicks(true)
        local function changed()
            -- CURSOR_CHANGED is synchronous and may precede an external
            -- SetCursor post-hook. Let the clock refresh after its writer
            -- returns, so a nested write cannot erase the incoming shape.
            if F.active and not updating and not issuing then
                local free = cursorFree()
                if free ~= true then
                    if free == false then shapeOwned = false end
                    F:Yield("Cursor occupied or unavailable. Free-cursor hiding paused.")
                end
            end
        end
        frame:SetScript("OnEnter", changed)
        frame:SetScript("OnEvent", changed)
        for _, event in ipairs({"CURSOR_CHANGED", "UPDATE_MOUSEOVER_UNIT"}) do
            local registered = frame:RegisterEvent(event)
            if secret(registered) or registered ~= true then error(event) end
        end
    end)
    if not ok then
        if frame then
            pcall(frame.SetMouseMotionEnabled, frame, false)
            pcall(frame.Hide, frame)
            pcall(frame.UnregisterAllEvents, frame)
        end
        return nil, "Click-through cursor support is unavailable on this client."
    end
    cover = frame
    return true
end

function F:SetEnabled(enabled)
    if type(enabled) ~= "boolean" then return nil, "Choose On or Off for free-cursor hiding." end
    if enabled then
        local checked, combat = pcall(InCombatLockdown)
        if not checked or secret(combat) or combat ~= false then
            local reason = "Wait until combat ends to enable free-cursor hiding."
            remember(reason)
            return nil, reason
        end
        local ok, reason = prepare()
        if not ok then remember(reason); return nil, reason end
    end
    self.enabled, self.suppressed, self.notice = enabled, false, nil
    if not enabled then release() end
    updateDriver()
    return true
end

function F:NeedsTick()
    return self.enabled and self.wanted and not self.suppressed
end

local function refresh()
    local free = cursorFree()
    if free ~= true then
        if free == false then shapeOwned = false end
        return F:Yield("Cursor occupied or unavailable. Free-cursor hiding paused.")
    end
    local look = R.Adapter:MouseLookActive()
    if look == nil then return F:Yield("Cannot read mouse-look state. The pointer is free for this take.") end
    if look then
        if not release() then F.suppressed = true end
        return
    end
    if F.active and not R.Cursor:SoftwareActive() then
        return F:Yield("The pointer renderer changed. The pointer is free for this take.")
    end
    if not F.active then
        local ok, reason = R.Cursor:AcquireSoftware()
        if not ok then return F:Yield(reason or "Software cursor unavailable.") end
        software = true
        cover:SetMouseMotionEnabled(true)
        cover:Show()
        local shown = cover:IsShown()
        if secret(shown) or shown ~= true then return F:Yield("Could not show the cursor surface.") end
    end
    -- The native world cursor can refresh as a unit or object passes under
    -- the moving camera. Refresh on the transport's existing clock as well.
    shapeOwned = true
    local ok, changed = callShape("SetCursor", texture)
    if not shapeOwned or not F:NeedsTick() then return end
    -- Some cursor implementations acknowledge a texture only on a repeated
    -- selection. A second false still releases the experiment immediately.
    if ok and not secret(changed) and changed == false then
        ok, changed = callShape("SetCursor", texture)
        if not shapeOwned or not F:NeedsTick() then return end
    end
    if not ok or secret(changed) or changed ~= true then
        return F:Yield("WoW declined the free cursor texture. The pointer is free for this take.")
    end
    F.active = true
    releasePending = false
end

function F:Tick()
    if updating or not self:NeedsTick() then return end
    updating = true
    local ok = pcall(refresh)
    if not ok then self:Yield("Cursor hide failed. The pointer is free for this take.") end
    updating = false
    if self.suppressed then updateDriver() end
end

function F:Sync(wanted)
    self.wanted = wanted == true
    if not self.wanted then
        self.suppressed = false
        return release()
    end
    if self:NeedsTick() and not self.active then self:Tick() end
end
