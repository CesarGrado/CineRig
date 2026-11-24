local _, R = ...
local UI = R.UI
local M = {logs = {}, index = 0}
R.Markers = M
local maxLogs, maxMarks = 12, 64
local labels = {"Good take", "Cut here", "Retake", "Continuity"}
local maxTime = 365 * 86400000

local function validTime(value)
    return R.Finite(value) and value >= 0 and value <= maxTime and value == math.floor(value)
end

local function stamp(ms)
    return string.format("%02d:%02d:%02d.%03d", math.floor(ms / 3600000), math.floor(ms / 60000) % 60,
        math.floor(ms / 1000) % 60, ms % 1000)
end

function M:LoadSettings(raw)
    self.started, self.logs, self.index, self.label, self.message = nil, {}, 0, 1, nil
    if type(raw) ~= "table" then return end
    for i, label in ipairs(labels) do if raw.label == label then self.label = i end end
    if type(raw.logs) ~= "table" then return end
    for i = 1, maxLogs do
        local src = raw.logs[i]
        if type(src) == "table" and R.ValidName(src.name) and validTime(src.ms) and type(src.marks) == "table" then
            local row = {name = src.name, ms = src.ms, marks = {}}
            local last = 0
            for k = 1, maxMarks do
                local m = src.marks[k]
                if type(m) == "table" and validTime(m.ms) and m.ms >= last and m.ms <= src.ms and R.ValidName(m.label) then
                    row.marks[#row.marks + 1] = {ms = m.ms, label = m.label}
                    last = m.ms
                end
            end
            self.logs[#self.logs + 1] = row
        end
    end
    self.index = #self.logs
end

function M:SaveSettings()
    return {label = labels[self.label or 1], logs = self.logs}
end

local function clockTime()
    local ok, value = pcall(GetTime)
    if ok and not (issecretvalue and issecretvalue(value)) and R.Finite(value) then return value end
end

function M:Start(name)
    if self.started then return nil, "A marker log is already running." end
    if #self.logs >= maxLogs then return nil, "Marker logs are full. Copy and remove an old log first." end
    if not name or name == "" then
        local used = {}
        for _, row in ipairs(self.logs) do used[row.name:lower()] = true end
        local number = #self.logs + 1
        while used["roll " .. number] do number = number + 1 end
        name = "Roll " .. number
    end
    if not R.ValidName(name) then return nil, "Use a roll name of 1 to 64 bytes." end
    local now = clockTime()
    if not now then return nil, "Game clock unavailable." end
    local row = {name = name, ms = 0, marks = {}}
    self.logs[#self.logs + 1] = row
    self.started, self.index, self.confirmDelete, self.message = now, #self.logs, nil, nil
    if self.output then self.output:SetText("") end
    self:Refresh()
    return true
end

local function elapsed()
    local row = M.logs[#M.logs]
    local now = clockTime()
    if not now then return nil end
    return R.Clamp(math.max(row.ms, math.floor((now - M.started) * 1000 + .5)), 0, maxTime)
end

function M:Drop(label)
    if not self.started then return nil, "Start a marker log before dropping a marker." end
    local row = self.logs[#self.logs]
    if #row.marks >= maxMarks then return nil, "This roll already has 64 markers. Finish it and start another." end
    if not label or label == "" then label = labels[self.label] end
    if not R.ValidName(label) then return nil, "Use a marker label of 1 to 64 bytes." end
    local ms = elapsed()
    if not ms then return nil, "Game clock unavailable." end
    row.ms = ms
    row.marks[#row.marks + 1] = {ms = ms, label = label}
    self.message = nil
    self:Refresh()
    return true
end

function M:Finish()
    if not self.started then return nil, "Start a marker log first." end
    local row = self.logs[#self.logs]
    row.ms = elapsed() or row.ms
    self.started, self.message = nil, nil
    self:Refresh()
    return true
end

function M:Text()
    local row = self.logs[self.index]
    if not row then return "" end
    local lines = {row.name .. "   (elapsed from Start log)"}
    for _, mark in ipairs(row.marks) do
        lines[#lines + 1] = stamp(mark.ms) .. "   " .. mark.label
    end
    if not (self.started and self.index == #self.logs) then lines[#lines + 1] = stamp(row.ms) .. "   End" end
    return table.concat(lines, "\n")
end

local function result(ok, reason)
    M.message = reason
    if not ok and reason then R.Engine:Log(reason) end
    M:Refresh()
    return ok, reason
end

function M:Build(parent)
    self.nameBox = UI.EditBox(parent, 16, 24, 214, 64)
    UI.Label(parent, 16, 2, 368, "GameFontNormal", "Roll name")
    self.clockButton = UI.Button(parent, 239, 23, 145, "", function()
        self.nameBox:ClearFocus()
        if self.started then result(self:Finish()) else result(self:Start(self.nameBox:GetText())) end
    end, true)
    self.labelButton = UI.Button(parent, 16, 58, 214, "", function()
        self.label = self.label % #labels + 1
    end)
    self.dropButton = UI.Button(parent, 239, 58, 145, "Drop marker", function() result(self:Drop()) end)
    local function selectLog(by)
        self.index = R.Clamp(self.index + by, 1, #self.logs)
        self.confirmDelete, self.message = nil, nil
        self.output:SetText("")
    end
    self.previous = UI.Button(parent, 16, 99, 50, "Prev", function() selectLog(-1) end)
    self.next = UI.Button(parent, 72, 99, 50, "Next", function() selectLog(1) end)
    self.summary = UI.Label(parent, 130, 104, 254, "GameFontHighlightSmall", "")
    self.summary:SetWordWrap(false)
    self.recent = UI.Label(parent, 16, 137, 368, "GameFontHighlightSmall", "")
    self.recent:SetJustifyV("TOP"); self.recent:SetHeight(66)
    self.copy = UI.Button(parent, 16, 211, 172, "Select log to copy", function()
        self.output:SetText(self:Text())
        self.output:SetFocus(); self.output:HighlightText()
    end)
    self.delete = UI.Button(parent, 198, 211, 186, "Delete log", function()
        local row = self.logs[self.index]
        if not row or self.started then return end
        if self.confirmDelete == row then
            table.remove(self.logs, self.index)
            self.index, self.confirmDelete = math.min(self.index, #self.logs), nil
            self.output:SetText("")
        else self.confirmDelete = row end
    end)
    UI.Label(parent, 16, 248, 368, "GameFontDisableSmall", "Start the log when you roll in OBS. Bind Drop filming marker for hidden-UI notes. Copy the selected text with Ctrl+C or Cmd+C.")
    local outputArea = CreateFrame("Frame", nil, parent)
    outputArea:SetPoint("TOPLEFT", 16, -291)
    outputArea:SetSize(368, 37)
    outputArea:SetClipsChildren(true)
    self.output = UI.EditBox(outputArea, 0, 0, 368, 7000)
    self.output:SetMultiLine(true)
    self.output:SetHeight(37)
    self.status = UI.Label(parent, 16, 331, 368, "GameFontDisableSmall", "")
    parent:HookScript("OnHide", function() self.confirmDelete = nil end)
    self:Refresh()
end

function M:Refresh()
    if not self.clockButton then return end
    local row, count = self.logs[self.index], #self.logs
    self.clockButton:SetText(self.started and "Finish log" or "Start log")
    self.dropButton:SetEnabled(self.started ~= nil)
    self.labelButton:SetText("Marker: " .. labels[self.label or 1])
    self.previous:SetEnabled(not self.started and self.index > 1)
    self.next:SetEnabled(not self.started and self.index < count)
    self.summary:SetText(row and string.format("%d/%d   %s   ·   %d marks", self.index, count, row.name, #row.marks)
        or "No marker logs")
    self.copy:SetEnabled(row ~= nil)
    self.delete:SetEnabled(row ~= nil and not self.started)
    self.delete:SetText(self.confirmDelete and "Confirm delete" or "Delete log")
    local lines = {}
    if row then
        for i = math.max(1, #row.marks - 2), #row.marks do
            local mark = row.marks[i]
            lines[#lines + 1] = stamp(mark.ms) .. "    " .. mark.label
        end
    end
    self.recent:SetText(table.concat(lines, "\n"))
    self.status:SetText(self.message or (self.started and "Marker clock running" or ""))
end

local held = {}
function CineRig_MarkerKey(action, down)
    if not down then held[action] = nil; return end
    if held[action] then return end
    held[action] = true
    if action == "mark" then result(M:Drop())
    elseif M.started then result(M:Finish())
    else result(M:Start(M.nameBox and M.nameBox:GetText())) end
end
BINDING_NAME_CINERIG_MARKER_CLOCK = "Start or finish filming marker log"
BINDING_NAME_CINERIG_DROP_MARKER = "Drop filming marker"
