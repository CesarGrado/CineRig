local _, R = ...
local UI, L, D = R.UI, R.Library, R.Director
local Shelf = {}
R.Recordings = Shelf
local rowsPerPage = 3

local function selected()
    local index = L:Find("recordings", L.selectedRecording)
    return index, index and L.recordings[index]
end

function Shelf:CanReplay()
    local _, row = selected()
    return row ~= nil and not (R.RecordingSession.active or R.LiveTake.armed or R.LiveTake.record)
end

function Shelf:Open()
    UI:Tab("Director")
    D:SelectView("Recordings")
    UI.panel:Show()
    UI:Refresh()
end

function Shelf:Select(index)
    self.pendingDelete = nil
    local ok, why = L:SelectRecording(index)
    D:Message(ok and "" or why)
end

function Shelf:Save()
    self.pendingDelete = nil
    local index, why = L:SaveRecording(self.saveName:GetText())
    if index then
        self.saveName:SetText("")
        self.saveName:ClearFocus()
        D:Message("Saved “" .. L.recordings[index].name .. "”.")
    else D:Message(why) end
end

function Shelf:Rename()
    self.pendingDelete = nil
    local index, row = selected()
    if not row then return end
    local ok, why = L:RenameRecording(index, self.renameName:GetText())
    if ok then self.renameName:ClearFocus() end
    D:Message(ok and ("Renamed to “" .. L.recordings[index].name .. "”.") or why)
end

function Shelf:Delete()
    local index, row = selected()
    if not row then return end
    if self.pendingDelete == row and self.deleteName == row.name then
        self.pendingDelete = nil
        local ok, why = L:Remove("recordings", index)
        D:Message(ok and ("Deleted “" .. row.name .. "”.") or why)
    else
        self.pendingDelete, self.deleteName = row, row.name
        D:Message("Click Confirm delete to remove “" .. row.name .. "”.")
    end
end

function Shelf:Build(p)
    self.record = UI.Button(p, 16, 0, 136, "Record movement", function()
        self.saveName:ClearFocus()
        self.renameName:ClearFocus()
        self.pendingDelete = nil
        local starting = not R.RecordingSession.active
        local name = starting and self.saveName:GetText() or nil
        local ok, why = R.RecordingSession:Toggle(name)
        if ok and starting and name and name ~= "" then self.saveName:SetText("") end
        D:Message(ok and "" or why)
    end, true)
    self.status = UI.Label(p, 160, 3, 224, "GameFontHighlightSmall", "")
    self.status:SetWordWrap(false)
    self.nameHelp = UI.Label(p, 16, 31, 368, "GameFontDisableSmall", "")
    self.saveLabel = UI.Label(p, 16, 62, 368, "GameFontHighlightSmall", "")
    self.saveName = UI.EditBox(p, 16, 79, 224, 64)
    self.save = UI.Button(p, 248, 79, 136, "Save recording", function() self:Save() end)
    self.count = UI.Label(p, 16, 118, 216, "GameFontNormal", "")
    self.prev = UI.Button(p, 245, 112, 66, "Prev page", function() self:Select(self.first - rowsPerPage) end)
    self.next = UI.Button(p, 318, 112, 66, "Next page", function() self:Select(self.first + rowsPerPage) end)
    self.rows = {}
    for i = 1, rowsPerPage do
        local offset = i - 1
        local row = UI.Button(p, 16, 141 + offset * 27, 368, "", function() self:Select(self.first + offset) end)
        local font = row:GetFontString()
        font:SetWidth(352)
        font:SetWordWrap(false)
        font:SetJustifyH("LEFT")
        self.rows[i] = row
    end
    self.editLabel = UI.Label(p, 16, 229, 368, "GameFontHighlightSmall", "Selected recording name")
    self.renameName = UI.EditBox(p, 16, 246, 191, 64)
    self.rename = UI.Button(p, 214, 246, 69, "Rename", function() self:Rename() end)
    self.delete = UI.Button(p, 290, 246, 94, "Delete", function() self:Delete() end)
    local function enter(box, action, button)
        box:SetScript("OnEnterPressed", function(b)
            if button:IsEnabled() then action(self) else b:ClearFocus() end
            UI:Refresh()
        end)
    end
    enter(self.saveName, self.Save, self.save)
    enter(self.renameName, self.Rename, self.rename)
    self.saveName:SetScript("OnTabPressed", function(b)
        b:ClearFocus()
        if self.renameName:IsVisible() then self.renameName:SetFocus(); self.renameName:HighlightText() end
    end)
    self.renameName:SetScript("OnTabPressed", function(b)
        b:ClearFocus(); self.saveName:SetFocus()
    end)
    p:HookScript("OnHide", function() self.pendingDelete = nil end)
end

function Shelf:Refresh()
    local take = R.LiveTake
    local running = R.RecordingSession.active
    local readOnly = L.accountLocked or L.recordingsLocked
    self.record:SetText(running and "Finish recording" or "Record movement")
    self.record:SetEnabled(running or (R.Engine.state == "idle" and not take.armed))
    if running and not take.record then self.status:SetText("Ready for your first move")
    else self.status:SetText((take.record or take.armed or take.draft or take.saved or take.note) and take:Caption() or "") end
    self.save:SetEnabled(not (readOnly or take.record or take.armed or running) and (take.draft or take.saved) ~= nil)
    local source = take.draft or take.saved
    if running then
        self.nameHelp:SetText("Use an Operator key or Nudge to record up to 60 seconds.\nClick Finish recording or press the recording binding to finish.")
        local name = R.RecordingSession.name
        self.saveLabel:SetText(name and ("Saving on finish: " .. name) or "Name this take after you finish recording.")
    elseif source then
        self.nameHelp:SetText("For a new take, type a name and click Record movement.\nTo name the previous take, click Save recording or press Enter.")
        local label = take.draft and "Latest completed move" or "Character quick save"
        self.saveLabel:SetText(string.format("%s (%.1f s)   ·   Save as", label, source.ms / 1000))
    else
        self.nameHelp:SetText("Type a name and click Record movement to save on finish.\nAn Operator key or Nudge starts the 60-second clock.")
        self.saveLabel:SetText("Movement name (optional before recording)")
    end
    local total = #L.recordings
    local index, entry = selected()
    local page = math.floor(((index or 1) - 1) / rowsPerPage)
    self.first = page * rowsPerPage + 1
    self.count:SetText(total == 0 and "No saved recordings" or ("Saved recordings   " .. total .. " / " .. L.maxRecordings))
    self.prev:SetEnabled(self.first > 1)
    self.next:SetEnabled(self.first + rowsPerPage <= total)
    for i, b in ipairs(self.rows) do
        local pos = self.first + i - 1
        local row = L.recordings[pos]
        b:SetShown(row ~= nil)
        if row then
            b:SetText(string.format("%s  %.1f s    %s", pos == index and ">" or " ", row.take.ms / 1000, row.name))
        end
    end
    if self.pendingDelete ~= entry or (entry and self.deleteName ~= entry.name) then self.pendingDelete = nil end
    self.delete:SetText(self.pendingDelete and "Confirm delete" or "Delete")
    self.rename:SetEnabled(not readOnly and entry ~= nil)
    self.delete:SetEnabled(not readOnly and entry ~= nil)
    for _, control in ipairs({self.editLabel, self.renameName, self.rename, self.delete}) do control:SetShown(entry ~= nil) end
    local name = entry and entry.name
    if self.lastName ~= name then self.renameName:SetText(name or ""); self.lastName = name end
end
