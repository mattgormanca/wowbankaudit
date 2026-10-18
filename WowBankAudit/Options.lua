local _, ns = ...

StaticPopupDialogs["WOWBANKAUDIT_CLEAR_LOG"] = {
    text = "Delete the entire Bank Audit log? This cannot be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        ns:ClearLog()
        ns:Print("audit log cleared.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWBANKAUDIT_RESET_SNAPSHOTS"] = {
    text = "Forget the stored contents of every bank? The next bank visit takes a fresh baseline and nothing that changed in between is logged.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        ns:ResetSnapshots()
        ns:Print("bank snapshots reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local CHECKBOXES = {
    {
        key = "trackAllItems",
        label = "Track all items",
        tooltip = "Record every item moved in or out of the banks, not only trade goods.",
    },
    {
        key = "includeCraftingReagents",
        label = "Count crafting reagents as trade goods",
        tooltip = "Also record items the game flags as crafting reagents even if they are not in the Trade Goods category.",
    },
    {
        key = "logUnrecorded",
        label = "Log unrecorded changes",
        tooltip = "When a bank is opened, compare it to the last known contents and log any difference (for example, a character on another PC or without this addon used the Warband Bank). These entries are marked with *.",
    },
    {
        key = "chatNotify",
        label = "Print each logged change to chat",
    },
}

local function CreatePanel()
    local panel = CreateFrame("Frame")
    panel:Hide()

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ns.TITLE)

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Audits gold and trade goods deposited to and withdrawn from your Bank and Warband Bank, tab by tab. Type /bankaudit to open the log.")

    local checks = {}
    local anchor = subtitle
    for _, def in ipairs(CHECKBOXES) do
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == subtitle and -2 or 0, anchor == subtitle and -16 or -4)
        local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        label:SetText(def.label)
        cb:SetScript("OnClick", function(self)
            ns.db.settings[def.key] = self:GetChecked() and true or false
            ns:Fire("SETTINGS_CHANGED")
        end)
        if def.tooltip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(def.label)
                GameTooltip:AddLine(def.tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", GameTooltip_Hide)
        end
        cb.key = def.key
        checks[#checks + 1] = cb
        anchor = cb
    end

    local maxLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    maxLabel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -16)
    maxLabel:SetText("Maximum log entries (oldest are removed first):")

    local maxBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    maxBox:SetSize(80, 20)
    maxBox:SetPoint("LEFT", maxLabel, "RIGHT", 12, 0)
    maxBox:SetAutoFocus(false)
    maxBox:SetNumeric(true)
    local function CommitMax(self)
        local value = tonumber(self:GetText())
        if value and value >= 100 then
            ns.db.settings.maxEntries = value
        end
        self:SetText(tostring(ns.db.settings.maxEntries))
        self:ClearFocus()
    end
    maxBox:SetScript("OnEnterPressed", CommitMax)
    maxBox:SetScript("OnEditFocusLost", CommitMax)
    maxBox:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(ns.db.settings.maxEntries))
        self:ClearFocus()
    end)

    local openButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openButton:SetSize(160, 24)
    openButton:SetPoint("TOPLEFT", maxLabel, "BOTTOMLEFT", -4, -24)
    openButton:SetText("Open audit log")
    openButton:SetScript("OnClick", function() ns.UI:Show() end)

    local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetButton:SetSize(160, 24)
    resetButton:SetPoint("LEFT", openButton, "RIGHT", 8, 0)
    resetButton:SetText("Reset bank snapshots")
    resetButton:SetScript("OnClick", function() StaticPopup_Show("WOWBANKAUDIT_RESET_SNAPSHOTS") end)

    local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(160, 24)
    clearButton:SetPoint("LEFT", resetButton, "RIGHT", 8, 0)
    clearButton:SetText("Clear audit log")
    clearButton:SetScript("OnClick", function() StaticPopup_Show("WOWBANKAUDIT_CLEAR_LOG") end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", openButton, "BOTTOMLEFT", 4, -16)
    note:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Gold can only be stored in the Warband Bank, so gold activity appears on the Warband Bank tab. Tab-to-tab moves (including Bank <-> Warband Bank) are logged as transfers rather than a withdrawal plus a deposit.")

    panel:SetScript("OnShow", function()
        for _, cb in ipairs(checks) do
            cb:SetChecked(ns.db.settings[cb.key])
        end
        maxBox:SetText(tostring(ns.db.settings.maxEntries))
    end)

    return panel
end

ns:RegisterCallback("READY", function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then
        return
    end
    local panel = CreatePanel()
    local category = Settings.RegisterCanvasLayoutCategory(panel, ns.TITLE)
    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end)

function ns:OpenOptions()
    if self.settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(self.settingsCategory:GetID())
    end
end
