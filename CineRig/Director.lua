local _, R = ...
local L, UI = R.Library, R.UI
local D = {index = 1, shot = 1, take = 1, view = "Timeline"}
R.Director = D
local button, label, input = UI.Button, UI.Label, UI.EditBox

local function shortLine(p, x, y, w, font, value)
    local f = label(p, x, y, w, font, value)
    f:SetWordWrap(false)
    return f
end

local function cycle(current, delta, size)
    return size > 0 and (current - 1 + delta) % size + 1 or 1
end

local function tabOrder(boxes)
    for i, box in ipairs(boxes) do
        local current = i
        box:SetScript("OnTabPressed", function(b)
            local nextBox = boxes[cycle(current, IsShiftKeyDown() and -1 or 1, #boxes)]
            b:ClearFocus()
            nextBox:SetFocus()
            nextBox:HighlightText()
        end)
    end
end

function D:Message(text)
    self.message = text
    if self.notice then self.notice:SetText(text or "") end
end

function D:PlayTimeline(loop)
    self:FinishEditing()
    local ok, err = R.Engine:Play(R.timeline, R.countdown, loop == true)
    if not ok then self:Message(err) end
    return ok, err
end

function D:Preview()
    self:FinishEditing()
    local s = R.timeline[self.index]
    if not s then self:Message("Select a segment to preview."); return nil, self.message end
    local ok, err = R.Engine:Play({s}, R.countdown, false)
    if not ok then self:Message(err) end
    return ok, err
end

function D:FinishEditing()
    if not self.page then return end
    for _, b in ipairs({self.startBox, self.endBox, self.holdBox, self.shotBox, self.takeBox, self.wire}) do
        if b:HasFocus() then b:ClearFocus() end
    end
end

function D:SelectView(view)
    self.view = view
    self.pendingDelete = nil
    self.overwrite = nil
    self:Message("")
    if UI.tab == "Director" then
        UI.playTarget = view == "Recordings" and "Recordings" or "Director"
        UI:Refresh()
    else self:Refresh() end
end

function D:AddShot(s)
    if #R.timeline >= L.maxSegments then self:Message("A take can hold up to 32 segments."); return end
    local i = math.min(self.index + 1, #R.timeline + 1)
    table.insert(R.timeline, i, R.Copy(s))
    self.index = i
    self:Message("Added " .. s.name)
end

function D:Move(by)
    local i, j = self.index, self.index + by
    if not R.timeline[i] or not R.timeline[j] then return end
    R.timeline[i], R.timeline[j] = R.timeline[j], R.timeline[i]
    self.index = j
end

function D:ApplyTrim()
    local s = R.timeline[self.index]
    if not s then return end
    local edited = R.Copy(s)
    edited.trimIn, edited.trimOut, edited.hold = tonumber(self.startBox:GetText()),
        tonumber(self.endBox:GetText()), tonumber(self.holdBox:GetText())
    if not edited.trimIn or not edited.trimOut or not edited.hold or not L:ValidSegment(edited) then
        self:Message("Keep at least 0.5 s of motion. Use a hold of 0 to 60 s.")
        return
    end
    R.timeline[self.index] = edited
    self.startBox:ClearFocus()
    self.endBox:ClearFocus()
    self.holdBox:ClearFocus()
    self:Message("Trims and hold applied.")
end

function D:BuildTimeline(p)
    self.title = shortLine(p, 16, 5, 275, "GameFontNormal", "")
    button(p, 300, 0, 38, "<", function() self.index = cycle(self.index, -1, #R.timeline) end)
    button(p, 346, 0, 38, ">", function() self.index = cycle(self.index, 1, #R.timeline) end)
    self.rows = {}
    for i = 1, 3 do
        local n = i
        local b = button(p, 16, 30 + 28 * (i - 1), 368, "", function()
            self.index = self.first + n - 1
        end)
        b:GetFontString():SetWidth(350)
        b:GetFontString():SetWordWrap(false)
        b:GetFontString():SetJustifyH("LEFT")
        self.rows[i] = b
    end
    button(p, 16, 117, 100, "Add shot", function() self:AddShot(R.selected) end)
    button(p, 120, 117, 80, "Duplicate", function()
        if R.timeline[self.index] then self:AddShot(R.timeline[self.index]) end
    end)
    button(p, 204, 117, 64, "Remove", function()
        if R.timeline[self.index] then table.remove(R.timeline, self.index) end
        self.index = math.max(1, math.min(self.index, #R.timeline))
    end)
    button(p, 272, 117, 52, "Earlier", function() self:Move(-1) end)
    button(p, 328, 117, 56, "Later", function() self:Move(1) end)
    label(p, 16, 157, 95, "GameFontHighlightSmall", "Trim start (s)")
    label(p, 114, 157, 95, "GameFontHighlightSmall", "Trim end (s)")
    label(p, 212, 157, 95, "GameFontHighlightSmall", "Hold after (s)")
    self.startBox, self.endBox, self.holdBox = input(p, 16, 175, 90, 10),
        input(p, 114, 175, 90, 10), input(p, 212, 175, 88, 10)
    tabOrder({self.startBox, self.endBox, self.holdBox})
    button(p, 308, 175, 76, "Apply", function() self:ApplyTrim() end)
    self.join = button(p, 16, 210, 165, "Cut", function()
        local s = R.timeline[self.index]
        if s then s.join = s.join == "ease" and "cut" or "ease" end
    end)
    button(p, 188, 210, 196, "Preview / restart segment", function() self:Preview() end)
    button(p, 16, 246, 165, "Loop rehearsal", function() self:PlayTimeline(true) end)
    label(p, 188, 250, 195, "GameFontDisableSmall", "Each pass starts from the current view.")
end

function D:Save(kind)
    self.pendingDelete = nil
    local isShot = kind == "shots"
    local name = (isShot and self.shotBox or self.takeBox):GetText()
    local existing = L:Find(kind, name)
    local entry = existing and L[kind][existing]
    if entry and not L.accountLocked and self.overwrite ~= entry then
        self.overwrite = entry
        self:Message("Click Save again to update “" .. name .. "”.")
        return
    end
    self.overwrite = nil
    local i, err
    if isShot then
        i, err = L:SaveShot(name, R.selected, existing ~= nil)
        if i then self.shot = i end
    else
        i, err = L:SaveTake(name, R.timeline, existing ~= nil)
        if i then self.take, R.takeName = i, L.takes[i].name end
    end
    self:Message(i and ("Saved “" .. L[kind][i].name .. "”.") or err)
end

function D:Delete(kind)
    self.overwrite = nil
    local index = kind == "shots" and self.shot or self.take
    local entry = L[kind][index]
    if not entry then return end
    if self.pendingDelete == entry then
        local ok, err = L:Remove(kind, index)
        self.pendingDelete = nil
        self:Message(ok and "Removed from library." or err)
    else
        self.pendingDelete = entry
        self:Message("Click Delete again to remove “" .. entry.name .. "”.")
    end
end

function D:BuildLibrary(p)
    local function cancelConfirmation()
        if self.pendingDelete or self.overwrite then
            self.pendingDelete, self.overwrite = nil, nil
            self:Message("")
        end
    end
    local function browse(field, rows, by)
        cancelConfirmation()
        self[field] = cycle(self[field], by, #rows)
    end
    p:HookScript("OnHide", cancelConfirmation)
    self.shelfShot = shortLine(p, 16, 6, 278, "GameFontNormal", "")
    button(p, 300, 1, 38, "<", function() browse("shot", L.shots, -1) end)
    button(p, 346, 1, 38, ">", function() browse("shot", L.shots, 1) end)
    button(p, 16, 33, 115, "Load into Shot", function()
        local s = L.shots[self.shot]
        if s then
            R.selected, UI.rate, UI.reverse = R.Copy(s), 1, false
            UI:Tab("Shot")
        end
    end)
    button(p, 138, 33, 135, "Add to timeline", function()
        cancelConfirmation()
        if L.shots[self.shot] then self:AddShot(L.shots[self.shot]) end
    end)
    button(p, 280, 33, 104, "Delete shot", function() self:Delete("shots") end)
    label(p, 16, 68, 368, "GameFontHighlightSmall", "Save the shot selected in the Shot tab as")
    self.shotBox = input(p, 16, 86, 239, 64)
    button(p, 262, 86, 122, "Save shot", function() self:Save("shots") end)
    self.shelfTake = shortLine(p, 16, 135, 278, "GameFontNormal", "")
    button(p, 300, 130, 38, "<", function() browse("take", L.takes, -1) end)
    button(p, 346, 130, 38, ">", function() browse("take", L.takes, 1) end)
    button(p, 16, 162, 190, "Load as working timeline", function()
        local ok, err = L:LoadTake(self.take)
        if ok then self.index = 1; self:SelectView("Timeline") else self:Message(err) end
    end)
    button(p, 214, 162, 170, "Delete saved take", function() self:Delete("takes") end)
    label(p, 16, 197, 368, "GameFontHighlightSmall", "Save the working timeline as")
    self.takeBox = input(p, 16, 215, 239, 64)
    for _, box in ipairs({self.shotBox, self.takeBox}) do
        box:HookScript("OnTextChanged", function(_, userInput)
            if userInput then cancelConfirmation() end
        end)
    end
    tabOrder({self.shotBox, self.takeBox})
    button(p, 262, 215, 122, "Save take", function() self:Save("takes") end)
    label(p, 16, 258, 368, "GameFontDisableSmall",
        "Saved shots and takes are available to your characters on this account.")
end

function D:BuildTransfer(p)
    label(p, 16, 8, 368, "GameFontNormal", "Transfer a take")
    label(p, 16, 37, 367, "GameFontHighlightSmall",
        "Export the working timeline, then copy the selected text. To import, paste a CineRig take into the field.")
    self.wire = input(p, 16, 82, 368, L.maxBytes + 1)
    button(p, 16, 116, 180, "Export working take", function()
        local wire, err = L:Export(R.takeName, R.timeline)
        if not wire then return self:Message(err) end
        self.wire:SetText(wire)
        self.wire:SetFocus()
        self.wire:HighlightText()
        self:Message("Take selected. Use the system copy shortcut.")
    end)
    button(p, 204, 116, 180, "Import to library", function()
        local t, err = L:Import(self.wire:GetText())
        if not t then return self:Message(err) end
        local name = t.name
        for suffix = 2, L.maxTakes + 1 do
            if not L:Find("takes", name) then break end
            local tag = " (" .. suffix .. ")"
            name = (#t.name + #tag <= 64 and t.name or "Imported take") .. tag
        end
        local i, why = L:SaveTake(name, t.segments)
        if not i then return self:Message(why) end
        self.take = i
        self.wire:ClearFocus()
        self:SelectView("Library")
        self:Message("Imported “" .. L.takes[i].name .. "”. Choose Load to use it.")
    end)
    label(p, 16, 165, 365, "GameFontDisableSmall",
        "Import adds a saved take. Load it from the library when you are ready to replace the working timeline.")
end

function D:Build(page)
    if self.page then return end
    self.page, self.pages, self.tabs = page, {}, {}
    local names = {"Timeline", "Library", "Recordings", "Transfer"}
    for i, name in ipairs(names) do
        local which = name
        self.tabs[name] = button(page, 16 + (i - 1) * 94, 0, 86, name,
            function() self:SelectView(which) end)
        local p = CreateFrame("Frame", nil, page)
        p:SetPoint("TOPLEFT", 0, -35)
        p:SetSize(400, 285)
        self.pages[name] = p
    end
    self:BuildTimeline(self.pages.Timeline)
    self:BuildLibrary(self.pages.Library)
    self:BuildTransfer(self.pages.Transfer)
    R.Recordings:Build(self.pages.Recordings)
    self.notice = label(page, 16, 319, 368, "GameFontHighlightSmall", "")
    self:Refresh()
end

function D:Refresh()
    if not self.page then return end
    for name, p in pairs(self.pages) do
        p:SetShown(self.view == name)
        self.tabs[name]:GetFontString():SetTextColor(self.view == name and .48 or .93, .95, .86)
    end
    self.index = R.Clamp(self.index, 1, math.max(1, #R.timeline))
    if self.view == "Timeline" then
        local total = 0
        for _, s in ipairs(R.timeline) do total = total + R.Span(s) end
        self.title:SetText(string.format("%.1f s   %d segments   %s", total, #R.timeline, R.takeName))
        self.first = self.index - ((self.index - 1) % 3)
        for i, b in ipairs(self.rows) do
            local pos = self.first + i - 1
            local s = R.timeline[pos]
            b:SetShown(s ~= nil)
            if s then b:SetText(string.format("%s  %02d    %.1fs    %s",
                pos == self.index and ">" or " ", pos, R.Span(s), s.name)) end
        end
        local s = R.timeline[self.index]
        self.join:SetText(s and s.join == "ease" and "Join   ease 0.5 s" or "Join   cut")
        if self.form ~= s then
            self.form = s
            self.startBox:SetText(s and tostring(s.trimIn or 0) or "")
            self.endBox:SetText(s and tostring(s.trimOut or 0) or "")
            self.holdBox:SetText(s and tostring(s.hold or 0) or "")
        end
    elseif self.view == "Library" then
        self.shot = R.Clamp(self.shot, 1, math.max(1, #L.shots))
        self.take = R.Clamp(self.take, 1, math.max(1, #L.takes))
        local s, t = L.shots[self.shot], L.takes[self.take]
        self.shelfShot:SetText(s and ("Shot  " .. self.shot .. "/" .. #L.shots .. "    " .. s.name) or "No saved shots")
        self.shelfTake:SetText(t and ("Take  " .. self.take .. "/" .. #L.takes .. "    " .. t.name) or "No saved takes")
        if self.lastShot ~= R.selected then
            self.shotBox:SetText(R.selected.name)
            self.lastShot = R.selected
        end
        if self.lastName ~= R.takeName then
            self.takeBox:SetText(R.takeName)
            self.lastName = R.takeName
        end
    elseif self.view == "Recordings" then R.Recordings:Refresh() end
    self.notice:SetText((self.message and self.message ~= "" and self.message)
        or (self.view == "Recordings" and L.recordingsLocked and "Unknown recording format preserved. This shelf is read-only.")
        or ((L.accountLocked or L.characterLocked) and "Unknown saved-data version preserved. Affected storage is read-only." or ""))
end

function D:Command(cmd)
    if cmd == "director" or cmd == "library" or cmd == "transfer" then
        UI:Tab("Director")
        self:SelectView(cmd == "director" and "Timeline" or cmd == "library" and "Library" or "Transfer")
        UI.panel:Show()
    elseif cmd == "take" then self:PlayTimeline(false)
    elseif cmd == "loop" then self:PlayTimeline(true)
    elseif cmd == "preview" then self:Preview()
    else return false end
    return true
end
