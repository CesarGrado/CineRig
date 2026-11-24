local _, R = ...
local A = R.Adapter
local ownWrite, watching
local watchingReveal = false

local function public(value)
    return not (issecretvalue and issecretvalue(value))
end

function A:DisplayShown()
    if not UIParent then return end
    local ok, result = pcall(UIParent.IsShown, UIParent)
    if ok and public(result) and type(result) == "boolean" then return result end
end

local function relinquish()
    if ownWrite then ownWrite.taken = true end
    R.displayOwned, R.displayRecoveryPending = false, false
end

function A:WatchReveal()
    if watchingReveal then return true end
    if not UIParent or type(UIParent.HookScript) ~= "function" then
        return nil, "Cannot observe the game interface."
    end
    local ok, hooked = pcall(UIParent.HookScript, UIParent, "OnShow", function()
        if not ownWrite or not ownWrite.visible or ownWrite.taken then
            relinquish()
            if R.Walk.active then R.Engine:Stop("Interface shown") end
        end
        if R.FreeCursor.enabled then R.UpdateFreeCursor() end
    end)
    if not ok or not public(hooked) or hooked ~= true then return nil, "Cannot watch for the game interface to return." end
    watchingReveal = true
    return true
end

function A:WatchDisplay()
    if watching then return true end
    if type(SetUIVisibility) ~= "function" or type(hooksecurefunc) ~= "function" then
        return nil, "This client has no supported UI visibility control."
    end
    -- A native toggle or another addon takes ownership, even if it requests
    -- the same state. Do not later undo that caller's choice.
    local ok, reason = self:WatchReveal()
    if not ok then return nil, reason end
    ok = pcall(hooksecurefunc, "SetUIVisibility", function(visible, ...)
        -- A nested post-hook can request the same state or reverse our call.
        -- Exactly one matching invocation belongs to this visibility write.
        if ownWrite and not ownWrite.observed and select("#", ...) == 0
            and public(visible) and ownWrite.visible == visible then
            ownWrite.observed = true
        else
            relinquish()
        end
    end)
    if not ok then return nil, "Could not observe UI ownership." end
    watching = true
    return true
end

local function setVisible(visible)
    local previous, request = ownWrite, {visible = visible}
    if previous then previous.taken = true end
    ownWrite = request
    local ok = pcall(SetUIVisibility, visible)
    local shown = A:DisplayShown()
    ownWrite = previous
    if request.taken then
        if visible then return true end  -- Release is complete under the new owner.
        return nil, "Interface control changed while hiding it.", true
    end
    if not ok or shown ~= visible then
        return nil, "UI change refused. Use the game's Toggle User Interface binding."
    end
    return true
end

function A:HideDisplay(forWalking)
    local current = self:DisplayShown()
    if current == false then return true end
    if current == nil then return nil, "Cannot read interface visibility." end
    local ok, reason = self:WatchDisplay()
    if not ok then return nil, reason end
    local bound = false
    for _, command in ipairs({"TOGGLEUI", "CINERIG_RESTORE", "CINERIG_STOP", forWalking and "CINERIG_WALK" or nil}) do
        local checked, key = pcall(GetBindingKey, command)
        if checked and public(key) and type(key) == "string" and key ~= "" then bound = true; break end
    end
    if not bound then
        return nil, forWalking and "Bind Toggle walking session, Stop, Restore or Toggle User Interface first."
            or "Bind Stop, Restore or Toggle User Interface before hiding the interface."
    end
    local checked, combat = pcall(InCombatLockdown)
    if not checked or not public(combat) or combat ~= false then
        return nil, "Hide the interface outside combat."
    end
    -- Do not switch UI layers while a cinematic, shop or another top-level
    -- UI is controlling the screen. The stock Toggle UI binding checks this.
    if type(GetAppropriateTopLevelParent) == "function" then
        local read, parent = pcall(GetAppropriateTopLevelParent)
        if not read or not public(parent) or parent ~= UIParent then return nil, "Return to the gameplay interface to hide it." end
    end
    local taken
    local generation = R.Engine.generation
    ok, reason, taken = setVisible(false)
    if not taken and (ok or self:DisplayShown() ~= true) then R.displayOwned = true end
    -- A frame's OnHide can synchronously stop filming before HideDisplay
    -- finishes claiming the change. Return the display to its prior state.
    if R.Engine.generation ~= generation and not taken then
        if R.displayOwned then R.RestoreDisplay() end
        return nil, "Interface hide interrupted."
    end
    return ok, reason
end

function A:RestoreDisplay()
    if not R.displayOwned then return true end
    local current = self:DisplayShown()
    if current == nil then return nil, "Cannot read interface visibility. Press Restore to retry." end
    if not current then
        local ok, reason = setVisible(true)
        if not ok then return nil, reason end
    end
    R.displayOwned = false
    return true
end

function R.RestoreDisplay()
    local ok, reason = A:RestoreDisplay()
    R.displayRecoveryPending = not ok
    if not ok then R.Engine:Log(reason); R.Engine.message = reason end
    return ok, reason
end

function R.ToggleDisplay()
    if R.Walk.active then return R.Walk:Toggle() end
    if R.displayOwned then return R.RestoreDisplay() end
    local current = A:DisplayShown()
    if current == nil then return nil, "Cannot read interface visibility." end
    if not current then return nil, "Use the native UI toggle to restore your own hidden interface." end
    return A:HideDisplay()
end
