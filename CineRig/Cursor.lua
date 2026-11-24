local _, R = ...
local Cursor = {enabled = false}
R.Cursor = Cursor

local setting = "HardwareCursor"
local writing, watchedAPI, watchedGlobal
local eventFrame
local walkHardware, software, yieldedWalk = false, false, false
-- previous is the player's value before our first write. expected is the
-- setting in effect, including a software renderer that was already selected.
local expected, unconfirmedFrom

local function secret(v)
    return issecretvalue and issecretvalue(v)
end

local function read()
    if not C_CVar or type(C_CVar.GetCVar) ~= "function" then return end
    local ok, v = pcall(C_CVar.GetCVar, setting)
    if ok and not secret(v) and (v == "0" or v == "1") then return v end
end

local function writable()
    if not C_CVar or type(C_CVar.GetCVarInfo) ~= "function" or type(C_CVar.SetCVar) ~= "function" then return false end
    local ok, v, _, _, _, locked, secure, readOnly = pcall(C_CVar.GetCVarInfo, setting)
    return ok and not secret(v) and not secret(locked) and not secret(secure) and not secret(readOnly)
        and (v == "0" or v == "1") and locked == false and secure == false and readOnly == false
end

local function relinquish()
    local wasSoftware = software
    software, walkHardware, yieldedWalk = false, false, R.Walk.active
    Cursor.previous, expected, unconfirmedFrom = nil, nil, nil
    Cursor.notice = "Kept the pointer renderer selected during filming."
    if wasSoftware and R.FreeCursor then R.FreeCursor:Yield(Cursor.notice) end
end

local function observeWrite(source, name, value)
    if not expected or secret(name) or type(name) ~= "string" or name:lower() ~= "hardwarecursor" then return end
    -- Our API call can produce one synchronous CVAR_UPDATE and one API
    -- post-hook. A second write, even to the same value, has its own owner.
    if writing then
        if source ~= "global" and not writing[source] and not secret(value) and value == writing.value then
            writing[source] = true
            return
        end
        writing.external = true
    end
    relinquish()
end

local function observe()
    if type(hooksecurefunc) ~= "function" then return false end
    if not watchedAPI then
        watchedAPI = pcall(hooksecurefunc, C_CVar, "SetCVar", function(name, value)
            observeWrite("api", name, value)
        end)
        if not watchedAPI then return false end
    end
    if type(SetCVar) == "function" and not watchedGlobal then
        watchedGlobal = pcall(hooksecurefunc, "SetCVar", function(name, value)
            observeWrite("global", name, value)
        end)
        if not watchedGlobal then return false end
    end
    if not eventFrame then
        local created, f = pcall(CreateFrame, "Frame")
        if not created or not f then return false end
        local installed = pcall(f.SetScript, f, "OnEvent", function(frame, _, name, value)
            if frame == eventFrame then observeWrite("event", name, value) end
        end)
        if not installed then return false end
        local ok, registered = pcall(f.RegisterEvent, f, "CVAR_UPDATE")
        if not ok or secret(registered) or registered ~= true then
            pcall(f.UnregisterEvent, f, "CVAR_UPDATE")
            pcall(f.SetScript, f, "OnEvent", nil)
            return false
        end
        eventFrame = f
    end
    return true
end

local function write(value)
    local previous = writing
    local request = {value = value}
    writing = request
    local ok, success = pcall(C_CVar.SetCVar, setting, value)
    writing = previous
    return ok and not secret(success) and success == true, read(), request.external
end

local function problem(text)
    Cursor.notice = text
    R.Engine:Log(text)
    return nil, text
end

local function applyRenderer()
    local requested
    if software then requested = "0"
    elseif walkHardware and R.Walk.active then requested = "1" end
    local target = requested or Cursor.previous
    if not target then expected, unconfirmedFrom = nil, nil; return true end

    local before = read()
    if not before then return problem("Cannot read the pointer renderer. Try Restore again.") end
    if expected and before ~= expected and before ~= unconfirmedFrom then
        relinquish()
        return nil, Cursor.notice
    end
    -- Readback can disappear during loading. A later read of the old value
    -- means the attempted transition did not stick and is safe to retry.
    if unconfirmedFrom then expected, unconfirmedFrom = before, nil end
    if requested and not observe() then return problem("Cannot monitor changes to the pointer renderer.") end
    if target ~= before then
        if not writable() then return problem("WoW currently blocks cursor setting changes. Try Restore again.") end
        local oldPrevious, oldExpected = Cursor.previous, expected
        Cursor.previous, expected = Cursor.previous or before, target
        local ok, after, external = write(target)
        if external then
            if requested then return nil, Cursor.notice end
            return true
        end
        if not after then unconfirmedFrom = before end
        if after == before then Cursor.previous, expected = oldPrevious, oldExpected end
        if after ~= target or (requested and not ok) then
            return problem("WoW did not confirm the cursor setting. Use Restore to retry a pending change.")
        end
    end
    expected = requested
    if not requested then Cursor.previous = nil end
    Cursor.notice = nil
    return true
end

function Cursor:BeginWalk()
    yieldedWalk, walkHardware = false, self.enabled
    local ok, reason = applyRenderer()
    if not ok then
        walkHardware = false
        if self.previous then applyRenderer() end
        self.notice = reason
    end
    return ok, reason
end

function Cursor:EndWalk()
    walkHardware, yieldedWalk = false, false
    if not R.Walk.active then software = false end
    return applyRenderer()
end

function Cursor:AcquireSoftware()
    if yieldedWalk then return nil, self.notice or "The player selected a different pointer renderer." end
    software = true
    local ok, reason = applyRenderer()
    if not ok then
        software = false
        if self.previous then applyRenderer() end
        return nil, reason
    end
    return true
end

function Cursor:SoftwareActive()
    if not software then return false end
    local current = read()
    if current == "0" then return true end
    if current then relinquish() end
    return false
end

function Cursor:ReleaseSoftware()
    software = false
    return applyRenderer()
end

function Cursor:Refresh()
    if not self.button then return end
    local renderer = read()
    self.state:SetText("WoW pointer: " .. (renderer == "1" and "hardware" or renderer == "0" and "software" or "unknown"))
    self.button:SetText("Hardware pointer on walks: " .. (self.enabled and "on" or "off"))
    self.button:SetEnabled(self.enabled or renderer == "1" or writable())
    local free = R.FreeCursor
    self.freeButton:SetText("Hide free cursor (experimental): " .. (free and free.enabled and "on" or "off"))
    self.freeButton:SetEnabled(free ~= nil)
    self.status:SetText((free and free.notice) or self.notice or "Record a short test and move the pointer across the scene.")
end

function Cursor:Build(parent)
    if self.button then return end
    local ui = R.UI
    ui.Label(parent, 16, 3, 368, "GameFontNormal", "Cursor in your recording")
    self.state = ui.Label(parent, 16, 23, 368, "GameFontHighlightSmall", "")
    self.button = ui.Button(parent, 16, 41, 368, "", function()
        self.enabled = not self.enabled
        self.notice = nil
        if not self.enabled then
            walkHardware = false
            applyRenderer()
        elseif R.Walk.active then self:BeginWalk() end
    end)
    self.freeButton = ui.Button(parent, 16, 75, 368, "", function()
        if R.FreeCursor then R.FreeCursor:SetEnabled(not R.FreeCursor.enabled) end
    end)
    ui.Label(parent, 16, 108, 368, "GameFontHighlightSmall", "Steer with right mouse or Toggle viewfinder mouse-look on a walk. Tap the key again to free the pointer.")
    self.status = ui.Label(parent, 16, 146, 368, "GameFontDisableSmall", "")
    self:Refresh()
end
