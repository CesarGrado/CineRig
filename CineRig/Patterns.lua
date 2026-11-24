local _, R = ...
local UI = R.UI
local P = {index = 1}
R.Patterns = P

local segment = R.OpticalShot

local presets = {}
local function add(name, direction, detail, rows)
    presets[#presets + 1] = {name = name, detail = detail, rows = rows}
    for _, row in ipairs(rows) do row.yaw = row.yaw * direction end
end

for i, side in ipairs({"left", "right"}) do
    local direction = i == 1 and -1 or 1
    local glance = segment("Glance " .. side, 2, .16, 0, 0)
    glance.hold = 1
    add("Glance " .. side, direction,
        "Look " .. side .. ", hold briefly, then swing back toward your opening view as you walk.",
        {glance, segment("Swing back", 2, -.16, 0, 0)})
end
for i, side in ipairs({"left", "right"}) do
    local direction = i == 1 and -1 or 1
    local opposite = i == 1 and "right" or "left"
    add("Sideways reveal " .. side, direction,
        "Strafe " .. side .. " past a foreground object while the camera pans " .. opposite .. ".",
        {segment("Pan " .. opposite .. " during strafe", 6, -.07, 0, 0)})
end
for i, side in ipairs({"left", "right"}) do
    local direction = i == 1 and -1 or 1
    -- Join the rising half of a short soft move to the falling half of a
    -- longer one at their shared peak. This gives the pan a longer stop.
    local sweep = segment("Whip " .. side, 1.2, .65, 0, 0)
    sweep.trimOut = .6
    local settle = segment("Feather the stop", 2, .65, 0, 0)
    settle.trimIn = 1
    add("Whip pan " .. side, direction,
        "Sweep " .. side .. " quickly, then ease into a slower stop. Rehearse the landing from your opening frame.",
        {sweep, settle})
end
add("Tower reveal", 1, "Frame the base of a tower in third person. Push closer, then tilt up its face.",
    {segment("Approach the base", 3, 0, 0, -.85), segment("Tilt up the tower", 4, 0, .11, 0)})
local lookUp = segment("Look up", 2, 0, .16, 0)
lookUp.hold = 1
add("Look up and return", 1, "Walk under an arch in first person. Look up, hold for a beat, then ease back toward your opening pitch.",
    {lookUp, segment("Return to walking view", 2, 0, -.16, 0)})
local widen = segment("Widen around the character", 5, .12, 0, 1.2)
widen.hold = 1
add("Widening arc", 1, "Start close in third person with clear space behind you. Swing right while pulling back, then hold the wide frame.",
    {widen})

function P:Open(name)
    if name and name ~= "" then
        local index
        for i, preset in ipairs(presets) do
            if name:lower() == preset.name:lower() then
                index = i
                break
            end
        end
        if not index then
            self.message = "Choose a listed name in Moves > Presets."
            return nil, self.message
        end
        self.index = index
    end
    self.message = nil
    R.Moves.section = "Presets"
    UI:Tab("Moves")
    UI.panel:Show()
    UI:Refresh()
    return true
end

function P:Play()
    if R.LiveTake.armed or R.LiveTake.record then
        self.message = "Finish or disarm the Operator recording before playing a preset."
        return nil, self.message
    end
    local preset = presets[self.index]
    local ok, reason = R.Engine:Play(preset.rows, R.countdown, false, preset.name)
    self.message = reason
    return ok, reason
end

function P:Append()
    local preset = presets[self.index]
    if #R.timeline + #preset.rows > R.Library.maxSegments then
        self.message = "This preset needs " .. #preset.rows .. " free timeline segments."
        return nil, self.message
    end
    local first = #R.timeline + 1
    for _, row in ipairs(preset.rows) do R.timeline[#R.timeline + 1] = R.Copy(row) end
    self.message = nil
    local director = R.Director
    director.index = first
    UI:Tab("Director")
    director:SelectView("Timeline")
    director:Message("Appended " .. preset.name .. ". Save the timeline in Library.")
    return true
end

function P:Build(parent)
    self.buttons = {}
    for i, preset in ipairs(presets) do
        local index = i
        self.buttons[i] = UI.Button(parent, 16 + 186 * ((i - 1) % 2), 30 * math.floor((i - 1) / 2),
            180, preset.name, function() self.index, self.message = index, nil end)
    end
    self.title = UI.Label(parent, 16, 155, 368, "GameFontNormal", "")
    self.detail = UI.Label(parent, 16, 180, 368, "GameFontHighlightSmall", "")
    UI.Button(parent, 16, 228, 180, "Append to timeline", function() self:Append() end)
    self.status = UI.Label(parent, 16, 264, 368, "GameFontDisableSmall", "")
end

function P:Refresh()
    local preset, seconds = presets[self.index], 0
    for _, row in ipairs(preset.rows) do seconds = seconds + R.Span(row) end
    self.title:SetText(string.format("%s   ·   %g s", preset.name, seconds))
    self.detail:SetText(preset.detail)
    self.status:SetText(self.message or "Use Play preset from your current frame, or append the move to edit its timing in Director.")
    for i, button in ipairs(self.buttons) do
        button:GetFontString():SetTextColor(i == self.index and .48 or .93, .95, .86)
    end
end
