local _, R = ...
local UI = {}
R.UI = UI

local function fill(frame, r, g, b, a)
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function label(parent, x, y, width, font, value)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    f:SetPoint("TOPLEFT", x, -y)
    f:SetWidth(width)
    f:SetJustifyH("LEFT")
    f:SetText(value)
    return f
end

local function button(parent, x, y, w, caption, action, accent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 25)
    b:SetPoint("TOPLEFT", x, -y)
    fill(b, accent and .10 or .13, accent and .38 or .16, accent and .34 or .19)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(.75, .96, .89, .18)
    b:SetFontString(b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    b:GetFontString():SetPoint("CENTER")
    b:SetText(caption)
    b:SetScript("OnClick", function()
        local ok, err = pcall(action)
        if not ok then R.Engine:Fail("Control error: " .. tostring(err)) end
        UI:Refresh()
    end)
    return b
end

UI.Button, UI.Label, UI.Fill = button, label, fill

function UI.EditBox(parent, x, y, width, limit)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetPoint("TOPLEFT", x, -y)
    box:SetSize(width, 24)
    box:SetFontObject("GameFontHighlight")
    box:SetTextInsets(6, 6, 0, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(limit)
    fill(box, .11, .13, .16)
    box:SetScript("OnEscapePressed", function(b) b:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(b) b:ClearFocus() end)
    box:SetScript("OnHide", function(b) b:ClearFocus() end)
    return box
end

function UI:Choose(index)
    self.playTarget = "Shot"
    self.index = ((index - 1) % #R.Recipes) + 1
    R.selected = R.Copy(R.Recipes[self.index])
    self.rate, self.reverse = 1, false
    self:Refresh()
end

local function directions(s)
    local parts = {}
    if s.yaw ~= 0 then parts[#parts + 1] = R.ConvertViewRate("yaw", s.yaw) > 0 and "right" or "left" end
    if s.pitch ~= 0 then parts[#parts + 1] = R.ConvertViewRate("pitch", s.pitch) > 0 and "up" or "down" end
    if s.zoom ~= 0 then parts[#parts + 1] = s.zoom > 0 and "out" or "in" end
    return #parts == 0 and "Hold position" or ("Reverse: " .. table.concat(parts, " + "))
end

local function matchesDirections(a, b)
    return a * b > 0 or (a == 0 and b == 0)
end

local recipeIndices = {}
for index, recipe in ipairs(R.Recipes) do recipeIndices[recipe.name:lower()] = index end

local function selectedRecipeIndex()
    local name = R.selected.name
    local index = recipeIndices[name:lower()]
    if index then return index end
    local base = R.Moves:BaseRecipe(name)
    return base and recipeIndices[base:lower()]
end

function UI:BrowseRecipe(step)
    local index = selectedRecipeIndex()
    -- A custom shot is outside the recipe list. Enter it from either end.
    self:Choose(index and index + step or (step > 0 and 1 or #R.Recipes))
end

local function shotHint(s)
    local recipe = R.Recipes[recipeIndices[s.name:lower()]]
    if recipe and R.RecipeNotes[s.name] and matchesDirections(s.yaw, recipe.yaw)
        and matchesDirections(s.pitch, recipe.pitch) and matchesDirections(s.zoom, recipe.zoom) then
        return R.RecipeNotes[s.name]
    end
    return "Frame the start with your mouse. Play from this view."
end

function UI:Scale(factor)
    local s = R.selected
    local target = R.Clamp(self.rate * factor, .05, 8)
    factor = target / self.rate
    -- Preserve the ratio of axes when the first one reaches its safety cap.
    for _, axis in ipairs({"yaw", "pitch", "zoom"}) do
        if s[axis] ~= 0 then
            factor = math.min(factor, (axis == "zoom" and 8 or 1) / math.abs(s[axis]))
        end
    end
    for _, axis in ipairs({"yaw", "pitch", "zoom"}) do
        local limit = axis == "zoom" and 8 or 1
        s[axis] = R.Clamp(s[axis] * factor, -limit, limit)
    end
    self.rate = self.rate * factor
end

function UI:Build()
    if self.panel then return end
    local p = CreateFrame("Frame", "CineRigConsole", UIParent)
    self.panel, self.index, self.rate, self.reverse = p, selectedRecipeIndex(), 1, false
    p:SetSize(400, 377)
    p:SetPoint("RIGHT", UIParent, "RIGHT", -38, 15)
    p:SetFrameStrata("DIALOG")
    p:SetClampedToScreen(true)
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function() p:StartMoving() end)
    p:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)
    fill(p, .055, .071, .085, .97)
    local rule = p:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT"); rule:SetPoint("TOPRIGHT"); rule:SetHeight(3)
    rule:SetColorTexture(.33, .84, .68, 1)
    label(p, 16, 14, 280, "GameFontNormalLarge", "CineRig")
    button(p, 344, 9, 40, "Close", function() p:Hide() end)
    self.status = label(p, 16, 41, 368, "GameFontHighlightSmall", "Ready to frame")
    self.status:SetWordWrap(false)
    self.pages, self.tabs = {}, {}
    for i, name in ipairs({"Shot", "Moves", "Operator", "Director", "Monitor", "Rig"}) do
        local tabName = name
        self.tabs[name] = button(p, 16 + (i - 1) * 62, 64, 58, name, function() self:Tab(tabName) end)
    end
    self.page = CreateFrame("Frame", nil, p)
    self.page:SetPoint("TOPLEFT", 0, -102); self.page:SetSize(400, 188)
    self.pages.Shot, self.tab = self.page, "Shot"
    local page = self.page
    self.name = label(page, 16, 5, 286, "GameFontHighlightLarge", "")
    self.name:SetWordWrap(false)
    button(page, 300, 0, 38, "<", function() self:BrowseRecipe(-1) end)
    button(page, 346, 0, 38, ">", function() self:BrowseRecipe(1) end)
    self.duration = label(page, 16, 40, 190, nil, "")
    button(page, 220, 32, 78, "- 1 sec", function()
        R.selected.duration = R.Clamp(R.selected.duration - 1, .5, 120)
    end)
    button(page, 306, 32, 78, "+ 1 sec", function()
        R.selected.duration = R.Clamp(R.selected.duration + 1, .5, 120)
    end)
    self.speed = label(page, 16, 72, 195, nil, "")
    self.slower = button(page, 220, 64, 78, "Slower", function() self:Scale(.8) end)
    self.faster = button(page, 306, 64, 78, "Faster", function() self:Scale(1.25) end)
    self.direction = button(page, 16, 99, 176, "Reverse", function()
        for _, a in ipairs({"yaw", "pitch", "zoom"}) do R.selected[a] = -R.selected[a] end
        self.reverse = not self.reverse
    end)
    self.ease = button(page, 202, 99, 182, "Ease", function()
        R.selected.ease = R.selected.ease == "soft" and "linear" or "soft"
    end)
    self.count = button(page, 16, 131, 176, "", function()
        R.countdown = (math.floor(R.countdown) + 1) % 11
    end)
    self.walkButton = button(page, 202, 131, 182, "Walk with UI hidden", function() R.Walk:Toggle() end, true)
    self.hint = label(page, 16, 167, 368, "GameFontDisableSmall", "Frame the start with your mouse. Play from this view.")
    self.transport = CreateFrame("Frame", nil, p)
    self.transport:SetPoint("BOTTOMLEFT", 0, 44); self.transport:SetSize(400, 25)
    self.playButton = button(self.transport, 16, 0, 154, "Play shot", function() R.PlayTransport() end, true)
    button(self.transport, 178, 0, 98, "Stop", function() CineRig_Stop() end)
    button(self.transport, 284, 0, 100, "Restore", function() R.Engine:Restore() end)
    self.footer = label(p, 16, 0, 368, "GameFontDisableSmall", "")
    self.footer:ClearAllPoints(); self.footer:SetPoint("BOTTOMLEFT", 16, 15)
    p:SetScript("OnShow", function() self:Refresh() end)
    p:Hide()
    self:Refresh()
end

function UI:Tab(name)
    self:Build()
    local controller = R[name]
    if name ~= "Shot" and (not controller or not controller.Build) then return end
    local heights = {Director = 364, Moves = 347, Monitor = 330, Operator = 241, Rig = 385}
    local height = heights[name] or 208
    if not self.pages[name] then
        local page = CreateFrame("Frame", nil, self.panel)
        page:SetPoint("TOPLEFT", 0, -102)
        page:SetSize(400, height)
        self.pages[name] = page
        controller:Build(page)
    end
    for key, page in pairs(self.pages) do page:SetShown(key == name) end
    self.tab = name
    if name == "Rig" then
        R.Rig:SetTransport()
    elseif name ~= "Monitor" then
        self.playTarget = name == "Director" and R.Director.view == "Recordings" and "Recordings" or name
    end
    self.panel:SetHeight(height + 186)
    self:Refresh()
end

function UI:Refresh()
    if not self.panel or not self.panel:IsVisible() then return end
    self.status:SetText(R.StatusLine())
    self.name:SetText(R.selected.name)
    self.duration:SetText(string.format("Duration   %.1f s", R.selected.duration))
    local driven = R.selected.yaw ~= 0 or R.selected.pitch ~= 0 or R.selected.zoom ~= 0
    self.slower:SetEnabled(driven); self.faster:SetEnabled(driven)
    self.direction:SetEnabled(driven); self.ease:SetEnabled(driven)
    self.speed:SetText(driven and string.format("Peak rate   %.0f%%", self.rate * 100) or "Camera   manual")
    self.direction:SetText(driven and directions(R.selected) or "Look with mouse")
    self.ease:SetText(driven and (R.selected.ease == "soft" and "Ease: soft in / out" or "Ease: constant") or "Zoom with wheel")
    self.count:SetText("Countdown: " .. R.countdown .. " sec")
    self.hint:SetText(shotHint(R.selected))
    self.footer:SetText("Set Play, Stop and Restore in Options > Keybindings.")
    self.playButton:SetText(R.TransportCaption())
    self.playButton:SetEnabled(self.playTarget ~= "Recordings" or R.Recordings:CanReplay())
    for name, b in pairs(self.tabs) do
        if name == self.tab then b:GetFontString():SetTextColor(.48, .97, .81)
        else b:GetFontString():SetTextColor(.93, .94, .95) end
    end
    local view = R[self.tab]
    if self.tab ~= "Shot" and view and view.Refresh then view:Refresh() end
end

function UI:Toggle()
    self:Build()
    if self.panel:IsShown() then self.panel:Hide() else self.panel:Show(); self:Refresh() end
end

table.insert(R.Engine.listeners, function() UI:Refresh() end)
