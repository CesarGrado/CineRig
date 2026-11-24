local _, R = ...
local UI = R.UI
local M = {section = "Compose"}
R.Moves = M

-- A shortcut starts from a copy of a recipe. The console, timeline and library
-- continue to use the same ordinary shot, including after custom edits.
local presets = {
    {"Pan left to right", "Slow pan", 1},
    {"Pan right to left", "Slow pan", -1},
    {"Tilt up", "Tilt", 1},
    {"Tilt down", "Tilt", -1},
    {"Zoom in", "Slow push", 1},
    {"Zoom out", "Pull-back", 1},
    {"Orbit and push", "Orbit and push", 1},
    {"Rising reveal", "Rising reveal", 1},
    {"Descending push", "Descending push", 1},
}
local channels = {
    {axis = "yaw", label = "Pan", minus = "Left", plus = "Right", step = .025, limit = 1},
    {axis = "pitch", label = "Tilt", minus = "Down", plus = "Up", step = .025, limit = 1},
    {axis = "zoom", label = "Distance", minus = "In", plus = "Out", step = .25, limit = 8},
}

function M:BaseRecipe(caption)
    for _, preset in ipairs(presets) do
        if caption:lower() == preset[1]:lower() then
            return preset[2], preset[3], preset[1]
        end
    end
end

function M:Select(caption)
    local name, direction, label = self:BaseRecipe(caption)
    for i, recipe in ipairs(R.Recipes) do
        if recipe.name == name then
            UI:Build()
            UI:Choose(i)
            local s = R.selected
            s.name = label
            for _, ch in ipairs(channels) do s[ch.axis] = s[ch.axis] * direction end
            return true
        end
    end
    return nil, "Choose a preset on the Moves tab."
end

local function adjust(ch, direction)
    local s = R.selected
    local delta = R.ConvertViewRate(ch.axis, direction * ch.step)
    local value = direction == 0 and 0 or R.Clamp(s[ch.axis] + delta, -ch.limit, ch.limit)
    if math.abs(value) < .000001 then value = 0 end
    if s[ch.axis] ~= value then
        s[ch.axis], s.name = value, "Custom move"
        UI.rate, UI.reverse = 1, false
    end
end

function M:Build(parent)
    self.pages, self.tabs, self.readouts = {}, {}, {}
    for i, name in ipairs({"Compose", "Presets", "Nudges"}) do
        local key = name
        self.tabs[key] = UI.Button(parent, 16 + 125 * (i - 1), 0, 118, key, function()
            self.section, UI.playTarget = key, "Moves"
        end)
        local p = CreateFrame("Frame", nil, parent)
        p:SetPoint("TOPLEFT", 0, -36); p:SetSize(400, 308)
        self.pages[key] = p
    end
    local p = self.pages.Compose
    for i, preset in ipairs(presets) do
        local name = preset[1]
        UI.Button(p, 16 + 125 * ((i - 1) % 3), 30 * math.floor((i - 1) / 3), 118, name,
            function() self:Select(name) end)
    end
    self.title = UI.Label(p, 16, 101, 368, "GameFontNormal", "")
    self.title:SetWordWrap(false)
    for i, ch in ipairs(channels) do
        local row = ch
        local y = 124 + 32 * (i - 1)
        UI.Label(p, 16, y + 5, 67, nil, row.label)
        UI.Button(p, 86, y, 70, row.minus, function() adjust(row, -1) end)
        self.readouts[row.axis] = UI.Button(p, 164, y, 128, "", function() adjust(row, 0) end)
        UI.Button(p, 300, y, 84, row.plus, function() adjust(row, 1) end)
    end
    self.duration = UI.Label(p, 16, 235, 99, "GameFontHighlightSmall", "")
    UI.Button(p, 110, 228, 54, "- 1 s", function() R.selected.duration = R.Clamp(R.selected.duration - 1, .5, 120) end)
    UI.Button(p, 171, 228, 54, "+ 1 s", function() R.selected.duration = R.Clamp(R.selected.duration + 1, .5, 120) end)
    self.ease = UI.Button(p, 232, 228, 152, "", function()
        R.selected.ease = R.selected.ease == "soft" and "linear" or "soft"
    end)
    UI.Label(p, 16, 267, 368, "GameFontDisableSmall", "Click a center value to zero that axis. Press Play shot to roll.")
    UI.Label(p, 16, 286, 368, "GameFontDisableSmall", "To keep the move, use Director > Library > Save shot.")

    R.Patterns:Build(self.pages.Presets)
    p = self.pages.Nudges
    self.nudgeSize = UI.Button(p, 16, 0, 178, "", function() R.Nudges:CycleSize() end)
    self.nudgeTime = UI.Button(p, 202, 0, 182, "", function() R.Nudges:CycleDuration() end)
    local names = {{"Pan left", "left"}, {"Pan right", "right"}, {"Tilt down", "down"},
        {"Tilt up", "up"}, {"Zoom in", "in"}, {"Zoom out", "out"}}
    for i, item in ipairs(names) do
        local key = item[2]
        UI.Button(p, 16 + 186 * ((i - 1) % 2), 43 + 34 * math.floor((i - 1) / 2),
            180, item[1], function() R.Nudges:Tap(key) end)
    end
    UI.Label(p, 16, 160, 368, "GameFontHighlightSmall", "Tap once for a soft adjustment. Bind Nudge actions to use them with the UI hidden.")
    UI.Label(p, 16, 206, 368, "GameFontDisableSmall", "For a sustained or diagonal move, combine the hold controls in Operator.")
    self:Refresh()
end

function M:Refresh()
    if not self.pages then return end
    if self.section == "Presets" then R.Patterns:Refresh() end
    for key, page in pairs(self.pages) do
        page:SetShown(key == self.section)
        self.tabs[key]:GetFontString():SetTextColor(key == self.section and .48 or .93, .95, .86)
    end
    local s = R.selected
    self.title:SetText(s.name)
    for _, ch in ipairs(channels) do
        local v = R.ConvertViewRate(ch.axis, s[ch.axis])
        local value = "Off"
        if v ~= 0 then
            local units = ch.axis == "zoom" and string.format("%.2f/s", math.abs(v)) or string.format("%.1f%%", math.abs(v) * 100)
            value = (v > 0 and ch.plus or ch.minus) .. "  " .. units
        end
        self.readouts[ch.axis]:SetText(value)
    end
    self.duration:SetText(string.format("Duration   %g s", s.duration))
    self.ease:SetText(s.ease == "soft" and "Soft start / stop" or "Constant speed")
    local prefs = R.Nudges:Prefs()
    self.nudgeSize:SetText("Travel: " .. prefs.size)
    self.nudgeTime:SetText(string.format("Duration: %g s", prefs.duration))
end
