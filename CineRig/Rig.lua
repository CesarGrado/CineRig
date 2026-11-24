local _, R = ...
local UI = R.UI
local Rig = {section = "Motion"}
R.Rig = Rig
local sections = {"Motion", "Playback", "Framing", "Markers"}
local views = {Motion = R.DeskMotion, Playback = R.DeskReplay, Framing = R.DeskFrame, Markers = R.Markers}
local aliases = {motion = "Motion", movement = "Motion", replay = "Playback", playback = "Playback",
    frame = "Framing", framing = "Framing", markers = "Markers"}

function Rig:SetTransport()
    if self.section == "Playback" then UI.playTarget = "Recordings"
    elseif self.section == "Motion" then UI.playTarget = "DeskMotion" end
end

function Rig:LoadSettings(raw)
    self.newerSettings = nil
    if type(raw) == "table" and raw.version ~= 1 then
        self.newerSettings = raw
        R.Engine:Log("Unrecognized Rig settings preserved. This session uses defaults.")
        raw = nil
    end
    if type(raw) ~= "table" then raw = {} end
    views.Motion:LoadSettings(raw.motion)
    views.Framing:LoadSettings(raw.framing)
    views.Markers:LoadSettings(raw.markers)
end

function Rig:SaveSettings()
    if self.newerSettings then return self.newerSettings end
    return {version = 1, motion = views.Motion:SaveSettings(), framing = views.Framing:SaveSettings(),
        markers = views.Markers:SaveSettings()}
end

function Rig:Select(name)
    self.section = name
    local view = views[name]
    if not self.pages[name] then
        local page = CreateFrame("Frame", nil, self.parent)
        page:Hide()
        page:SetPoint("TOPLEFT", 0, -38)
        page:SetSize(400, 345)
        self.pages[name] = page
        view:Build(page)
    end
    for key, p in pairs(self.pages) do p:SetShown(key == name) end
    self:SetTransport()
    if view.OnOpen then view:OnOpen() end
    self:Refresh()
end

function Rig:Open(alias)
    local name = (not alias or alias == "") and self.section or aliases[alias:lower()]
    if not name then return nil, "Choose motion, playback, framing or markers." end
    self.section = name
    UI:Tab("Rig")
    UI.panel:Show()
    self:Select(name)
    UI:Refresh()
    return true
end

function Rig:Build(parent)
    self.parent, self.pages, self.tabs = parent, {}, {}
    for i, name in ipairs(sections) do
        local section = name
        self.tabs[name] = UI.Button(parent, 16 + 93 * (i - 1), 0, 87, section, function() self:Select(section) end)
    end
    self:Select(self.section)
end

function Rig:Refresh()
    if not self.pages or not self.pages[self.section] then return end
    for name, button in pairs(self.tabs) do
        button:GetFontString():SetTextColor(name == self.section and .48 or .93, .95, .86)
    end
    views[self.section]:Refresh()
end
