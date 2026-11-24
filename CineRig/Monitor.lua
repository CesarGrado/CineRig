local _, R = ...
local E, UI = R.Engine, R.UI
local M = {thirds = false, center = false, safe = false, aspect = 1, labels = true,
    number = 0, section = "Framing", checks = {}}
R.Monitor = M
R.captureSafe = false
local aspectNames = {"Full frame", "16:9", "2.39:1", "1:1", "4:5", "9:16"}
local aspectValues = {0, 16 / 9, 2.39, 1, 4 / 5, 9 / 16}

local function stroke(parent, alpha)
    local t = parent:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(.87, .97, .93, alpha)
    return t
end

local function place(t, parent, x, y, width, height, visible)
    t:SetShown(visible)
    if not visible then return end
    t:ClearAllPoints(); t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    t:SetSize(math.max(.5, width), math.max(.5, height))
end

function M:Layout()
    local g = self.overlay
    if not g then return end
    local w, h = g:GetWidth(), g:GetHeight()
    if w <= 0 or h <= 0 then return end
    local frame = R.DeskFrame
    local ratio = frame.preview and aspectValues[self.aspect] or 0
    local fw, fh = w, h
    if ratio > 0 then fw, fh = math.min(w, h * ratio), math.min(h, w / ratio) end
    local x, y = (w - fw) / 2, (h - fh) / 2
    local lines = self.lines
    for i = 1, 2 do
        place(lines[i], g, x + fw * i / 3, y, 1, fh, self.thirds)
        place(lines[i + 2], g, x, y + fh * i / 3, fw, 1, self.thirds)
    end
    place(lines[5], g, w / 2 - 7, h / 2, 15, 1, self.center)
    place(lines[6], g, w / 2, h / 2 - 7, 1, 15, self.center)
    local function box(i, bx, by, bw, bh, enabled)
        place(lines[i], g, bx, by, bw, 1, enabled)
        place(lines[i + 1], g, bx, by + bh - 1, bw, 1, enabled)
        place(lines[i + 2], g, bx, by, 1, bh, enabled)
        place(lines[i + 3], g, bx + bw - 1, by, 1, bh, enabled)
    end
    box(7, x, y, fw, fh, ratio > 0)
    local action, title = frame.actionInset / 100, frame.titleInset / 100
    box(11, x + fw * action, y + fh * action, fw * (1 - 2 * action), fh * (1 - 2 * action), frame.preview and self.safe)
    box(15, x + fw * title, y + fh * title, fw * (1 - 2 * title), fh * (1 - 2 * title), frame.preview and frame.titleSafe)
    place(lines[19], g, x, y + fh * frame.eyelineHeight / 100, fw, 1, frame.preview and frame.eyeline)

    local function matte(i, bx, by, width, height)
        local t = self.mattes[i]
        t:SetAlpha(frame.matte / 100)
        place(t, g, bx, by, width, height, frame.preview and frame.matte > 0 and width >= .5 and height >= .5)
    end
    matte(1, 0, 0, x, h)
    matte(2, x + fw, 0, x, h)
    matte(3, x, 0, fw, y)
    matte(4, x, y + fh, fw, y)
end

function M:Overlay()
    if self.overlay then return end
    local g = CreateFrame("Frame", nil, UIParent)
    self.overlay = g
    g:SetAllPoints(UIParent); g:SetFrameStrata("LOW"); g:EnableMouse(false)
    self.lines = {}
    for i = 1, 14 do self.lines[i] = stroke(g, i >= 11 and .35 or .59) end
    for i = 15, 18 do
        self.lines[i] = g:CreateTexture(nil, "OVERLAY")
        self.lines[i]:SetColorTexture(1, .78, .40, .8)
    end
    self.lines[19] = g:CreateTexture(nil, "OVERLAY")
    self.lines[19]:SetColorTexture(.28, .88, 1, .85)
    self.mattes = {}
    for i = 1, 4 do
        self.mattes[i] = g:CreateTexture(nil, "BACKGROUND")
        self.mattes[i]:SetColorTexture(0, 0, 0, 1)
    end
    self.slate = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    self.slate:SetPoint("TOP", g, "TOP", 0, -35)
    g:SetScript("OnSizeChanged", function() self:Layout() end)
    UIParent:HookScript("OnShow", function() self:Display() end)
    self:Layout()
end

function M:Display()
    if R.Walk.active or R.Adapter:DisplayShown() ~= true then
        if self.overlay and self.overlay:IsShown() then self.overlay:Hide() end
        return
    end
    local running = E.state ~= "idle"
    local frame = R.DeskFrame
    local guides = self.thirds or self.center or (frame.preview and
        (self.safe or self.aspect ~= 1 or frame.titleSafe or frame.eyeline))
    local slate = self.labels and running
    if not R.captureSafe and (guides or slate) then
        self:Overlay()
        self.overlay:Show()
        self.slate:SetShown(slate)
        if slate then
            local title = self.title or R.selected.name
            local detail = R.StatusLine()
            if E.job and E.state == "playing" and #E.job.list == 1 then
                detail = string.format("%.1fs elapsed   %.1fs left", E.job.elapsed, math.max(0, E.job.total - E.job.elapsed))
            end
            self.slate:SetText(string.format("Take %02d  ·  %s\n%s", self.number, title, detail))
        end
    elseif self.overlay then self.overlay:Hide() end
end

function R.PrepareTake()
    if R.captureSafe then
        M:Display()
        local ok, reason = R.Adapter:HideDisplay()
        if not ok then return nil, reason end
    end
    M.number = M.number + 1
    M.title = E.job and (E.job.name or (#E.job.list > 1 and R.takeName or E.job.list[1].name))
        or (E.state == "live-replay" and (R.LiveTake.replay.name or "Saved live take") or "Live operator")
    return true
end

local checklist = {"Starting view framed", "Clearance and zoom checked", "Stop key within reach", "OBS source and recording checked"}
local function toggle(value) return value and "on" or "off" end

function M:Build(parent)
    self.views = {}
    for i, key in ipairs({"Framing", "Capture", "Checklist", "Diagnostics"}) do
        local name = key
        UI.Button(parent, 16 + (i - 1) * 94, 0, 86, name, function() self.section = name end)
        local area = CreateFrame("Frame", nil, parent)
        area:SetPoint("TOPLEFT", 0, -37); area:SetSize(400, 291)
        self.views[name] = area
    end
    local g = self.views.Framing
    self.mode = UI.Button(g, 16, 0, 178, "", function()
        R.captureSafe = not R.captureSafe
        if R.captureSafe and E.state ~= "idle" then
            local ok, reason = R.Adapter:HideDisplay()
            if not ok then return E:Fail(reason) end
        elseif not R.captureSafe then R.RestoreDisplay() end
        self:Display()
    end)
    UI.Button(g, 202, 0, 182, "Hide / restore game UI", function()
        local ok, reason = R.ToggleDisplay()
        if not ok then E:Fail(reason) end
    end)
    local function switch(field)
        self[field] = not self[field]; self:Display(); self:Layout()
    end
    self.third = UI.Button(g, 16, 34, 178, "", function() switch("thirds") end)
    self.cross = UI.Button(g, 202, 34, 182, "", function() switch("center") end)
    self.ratio = UI.Button(g, 16, 68, 178, "", function()
        local current = R.DeskFrame.preview and self.aspect or 1
        R.DeskFrame.preview = true
        self.aspect = current % #aspectNames + 1; self:Display(); self:Layout()
    end)
    self.safeButton = UI.Button(g, 202, 68, 182, "", function()
        if not R.DeskFrame.preview then self.safe = false end
        R.DeskFrame.preview = true
        switch("safe")
    end)
    self.hud = UI.Button(g, 16, 102, 178, "", function() switch("labels") end)
    UI.Label(g, 16, 139, 368, "GameFontDisableSmall", "Guides are visible in OBS during rehearsal. Safe mode hides them.")
    local capture = self.views.Capture
    R.Cursor:Build(capture)
    self.pov = UI.Label(capture, 16, 178, 368, "GameFontNormal", "")
    local function prepare(visible)
        local ok, reason = R.Framing:Prepare(visible)
        self.modelMessage = reason
        if not ok then E:Log(reason) end
    end
    self.hideModel = UI.Button(capture, 16, 200, 178, "Hide character", function() prepare(false) end)
    self.showModel = UI.Button(capture, 202, 200, 182, "Show character", function() prepare(true) end)
    self.modelHint = UI.Label(capture, 16, 236, 368, "GameFontHighlightSmall", "")
    UI.Label(capture, 16, 267, 368, "GameFontDisableSmall", "To restore your model after filming: /console showPlayer 1")
    self.checkButtons = {}
    for i = 1, #checklist do
        local index = i
        self.checkButtons[i] = UI.Button(self.views.Checklist, 16, (i - 1) * 33, 368, "", function()
            self.checks[index] = not self.checks[index]
        end)
    end
    self.diag = UI.Label(self.views.Diagnostics, 16, 0, 368, "GameFontHighlightSmall", "")
    self.diag:SetJustifyV("TOP"); self.diag:SetHeight(168)
    self:Refresh()
end

function M:Refresh()
    if not self.views then return end
    for key, view in pairs(self.views) do view:SetShown(key == self.section) end
    self.mode:SetText(R.captureSafe and "Mode: capture-safe" or "Mode: rehearsal")
    self.third:SetText("Thirds: " .. toggle(self.thirds))
    self.cross:SetText("Center mark: " .. toggle(self.center))
    local frame = R.DeskFrame
    self.ratio:SetText("Aspect: " .. aspectNames[frame.preview and self.aspect or 1])
    self.safeButton:SetText((100 - 2 * frame.actionInset) .. "% safe area: " .. toggle(frame.preview and self.safe))
    self.hud:SetText("Take labels: " .. toggle(self.labels))
    for i, name in ipairs(checklist) do self.checkButtons[i]:SetText((self.checks[i] and "[x]  " or "[  ]  ") .. name) end
    if self.section == "Capture" then
        R.Cursor:Refresh()
        self.pov:SetText("Character   ·   " .. R.Framing:ViewLabel())
        local ok, reason = R.Framing:Available()
        self.hideModel:SetEnabled(ok == true); self.showModel:SetEnabled(ok == true)
        self.modelHint:SetText(reason or self.modelMessage or "Choose an action, then press Enter in chat to apply it.")
    end
    if self.section == "Diagnostics" then
        local status = R.Adapter:Status()
        local d = R.Adapter:Distance()
        local info = {"Retail " .. status.build .. "    |    Camera: " .. status.owner,
            "Pan " .. toggle(status.yaw) .. "    Tilt " .. toggle(status.pitch) .. "    Distance zoom " .. toggle(status.zoom),
            "Distance: " .. (d and string.format("%.1f", d) or "unavailable") .. "    FOV: manual in Graphics",
            "State: " .. E.state .. "    UI: " .. (R.displayOwned and "hidden by CineRig" or "player controlled")}
        local blocked = R.Adapter:InterruptReason()
        if blocked then info[#info + 1] = blocked end
        info[#info + 1] = "Recent errors"
        if #E.errors == 0 then info[#info + 1] = "None this session" end
        for i = #E.errors, math.max(1, #E.errors - 2), -1 do info[#info + 1] = E.errors[i]:sub(1, 110) end
        self.diag:SetText(table.concat(info, "\n"))
    end
end

table.insert(E.listeners, function() M:Display() end)
