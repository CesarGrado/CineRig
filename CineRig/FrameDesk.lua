local _, R = ...
local UI, M = R.UI, R.Monitor
local F = {preview = false, matte = 0, actionInset = 5, titleInset = 10, eyelineHeight = 33,
    titleSafe = false, eyeline = false}
R.DeskFrame = F

local formats = {"Full frame", "16:9", "2.39:1", "Square 1:1", "Portrait 4:5", "Vertical 9:16"}

local function integer(n, low, high)
    return R.Finite(n) and n >= low and n <= high and n == math.floor(n)
end

local function setFields()
    if F.actionBox then
        F.actionBox:SetText(tostring(F.actionInset))
        F.titleBox:SetText(tostring(F.titleInset))
        F.heightBox:SetText(tostring(F.eyelineHeight))
    end
end

function F:LoadSettings(raw)
    raw = type(raw) == "table" and raw or {}
    M.aspect = integer(raw.aspect, 1, #formats) and raw.aspect or 1
    self.matte = integer(raw.matte, 0, 100) and raw.matte % 25 == 0 and raw.matte or 0
    self.actionInset, self.titleInset = 5, 10
    if integer(raw.actionInset, 1, 48) and integer(raw.titleInset, raw.actionInset + 1, 49) then
        self.actionInset, self.titleInset = raw.actionInset, raw.titleInset
    end
    self.eyelineHeight = integer(raw.eyelineHeight, 1, 99) and raw.eyelineHeight or 33
    M.safe, self.titleSafe, self.eyeline = raw.actionSafe == true, raw.titleSafe == true, raw.eyeline == true
    self.preview = false
    self.notice = nil
    setFields()
end

function F:SaveSettings()
    return {aspect = M.aspect, matte = self.matte, actionInset = self.actionInset, titleInset = self.titleInset,
        eyelineHeight = self.eyelineHeight, actionSafe = M.safe, titleSafe = self.titleSafe, eyeline = self.eyeline}
end

local function display()
    F.notice = nil
    M:Display()
    M:Layout()
end

local function changed()
    F.preview = true
    display()
end

function F:Apply()
    local action = tonumber(self.actionBox:GetText())
    local title = tonumber(self.titleBox:GetText())
    local height = tonumber(self.heightBox:GetText())
    if not integer(action, 1, 48) or not integer(title, 2, 49) or title <= action then
        self.notice = "Use whole-number insets from 1–49%. Title must sit inside action."
        return
    end
    if not integer(height, 1, 99) then
        self.notice = "Set the eyeline from 1–99% down the frame."
        return
    end
    self.actionInset, self.titleInset, self.eyelineHeight = action, title, height
    self.actionBox:ClearFocus(); self.titleBox:ClearFocus(); self.heightBox:ClearFocus()
    changed()
    self.notice = "Guide positions applied."
end

function F:Build(parent)
    if self.previewButton then return end
    UI.Label(parent, 16, 6, 156, "GameFontNormal", "Delivery frame")
    self.previewButton = UI.Button(parent, 200, 0, 184, "", function()
        self.preview = not self.preview
        display()
    end)
    self.formats = {}
    for i, name in ipairs(formats) do
        local index = i
        self.formats[i] = UI.Button(parent, 16 + ((i - 1) % 3) * 124, 33 + math.floor((i - 1) / 3) * 30,
            120, name, function() M.aspect = index; changed() end)
    end
    self.matteButton = UI.Button(parent, 16, 96, 177, "", function()
        self.matte = (self.matte + 25) % 125
        changed()
    end)
    UI.Label(parent, 202, 99, 182, "GameFontDisableSmall", "Darkens the area outside the crop.")
    UI.Label(parent, 16, 138, 200, "GameFontNormal", "Safe areas")
    UI.Label(parent, 230, 138, 154, "GameFontHighlightSmall", "Inset from each edge")
    self.actionButton = UI.Button(parent, 16, 157, 190, "", function() M.safe = not M.safe; changed() end)
    self.titleButton = UI.Button(parent, 16, 187, 190, "", function() self.titleSafe = not self.titleSafe; changed() end)
    self.actionBox = UI.EditBox(parent, 230, 157, 58, 2)
    self.titleBox = UI.EditBox(parent, 230, 187, 58, 2)
    UI.Label(parent, 297, 162, 48, "GameFontHighlightSmall", "%")
    UI.Label(parent, 297, 192, 48, "GameFontHighlightSmall", "%")
    self.eyelineButton = UI.Button(parent, 16, 227, 190, "", function() self.eyeline = not self.eyeline; changed() end)
    self.heightBox = UI.EditBox(parent, 230, 227, 58, 2)
    UI.Label(parent, 297, 232, 87, "GameFontHighlightSmall", "% from top")
    self.applyButton = UI.Button(parent, 16, 266, 140, "Apply positions", function() self:Apply() end)
    self.status = UI.Label(parent, 166, 267, 218, "GameFontHighlightSmall", "")
    UI.Label(parent, 16, 313, 368, "GameFontDisableSmall", "Guides appear in rehearsal. Capture-safe and hiding the UI remove them.")
    local fields = {self.actionBox, self.titleBox, self.heightBox}
    for i, box in ipairs(fields) do
        local index = i
        box:SetScript("OnEnterPressed", function() self:Apply(); self:Refresh() end)
        box:SetScript("OnTabPressed", function(b)
            b:ClearFocus()
            local step = IsShiftKeyDown() and -1 or 1
            local nextBox = fields[(index - 1 + step) % #fields + 1]
            nextBox:SetFocus(); nextBox:HighlightText()
        end)
    end
    setFields()
    self:Refresh()
end

function F:Refresh()
    if not self.previewButton then return end
    self.previewButton:SetText(self.preview and "Hide framing preview" or "Show framing preview")
    for i, b in ipairs(self.formats) do
        b:GetFontString():SetTextColor(i == M.aspect and .48 or .93, .97, .85)
    end
    self.matteButton:SetText("Outside matte   " .. self.matte .. "%")
    self.actionButton:SetText("Action safe   " .. (M.safe and "on" or "off"))
    self.titleButton:SetText("Title safe   " .. (self.titleSafe and "on" or "off"))
    self.eyelineButton:SetText("Eyeline   " .. (self.eyeline and "on" or "off"))
    self.status:SetText(self.notice or (R.captureSafe and "Capture-safe is hiding the preview." or ""))
end
