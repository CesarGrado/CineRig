local _, R = ...
local E = R.Engine
local Walk = {active = false}
R.Walk = Walk

-- Manual walking owns only a request to hide the interface. The transport
-- stays idle until the player explicitly starts a timed shot or an operator move.
function Walk:Toggle()
    if self.active then return E:Stop("Walking session ended") end
    local ok, reason = E:Allowed(true)
    if not ok then return E:Fail(reason) end
    if E.state ~= "idle" and not E:ReleaseMotion("Starting walking session", true) then
        return nil, E.message
    end
    -- Observe native reveal even when the player hid the interface before
    -- starting. That hidden state remains theirs on every exit path.
    ok, reason = R.Adapter:WatchReveal()
    if ok then ok, reason = R.Adapter:HideDisplay(true) end
    if not ok then return E:Fail(reason) end
    self.active = true
    R.Cursor:BeginWalk()
    E:Notify()
    return true
end

local keyHeld = false
function CineRig_WalkKey(down)
    if not down then keyHeld = false; return end
    if keyHeld then return end
    keyHeld = true
    Walk:Toggle()
end

BINDING_NAME_CINERIG_WALK = "Toggle walking session"
