local _, ns = ...

local UI = {}
ns.UI = UI

local FRAME_NAME = "WowBankAuditFrame"
local ROW_HEIGHT = 20

local COLOR_IN = "ff33dd33"
local COLOR_OUT = "ffff5555"
local COLOR_MOVE = "ff66bbff"
local COLOR_MUTED = "ff999999"

local LOG_COLUMNS = {
    { title = "Time", width = 115 },
    { title = "Character", width = 120 },
    { title = "Action", width = 125 },
    { title = "Tab", width = 175 },
    { title = "Item / Gold", width = 220 },
    { title = "Qty", width = 55, justify = "RIGHT" },
}

local SUMMARY_COLUMNS = {
    { title = "Item / Gold", width = 290 },
    { title = "In", width = 130, justify = "RIGHT" },
    { title = "Out", width = 130, justify = "RIGHT" },
    { title = "Net", width = 130, justify = "RIGHT" },
    { title = "Moved within", width = 120, justify = "RIGHT" },
}

local KIND_OPTIONS = {
    { value = "all", text = "All activity" },
    { value = "deposit", text = "Deposits / in" },
    { value = "withdraw", text = "Withdrawals / out" },
    { value = "move", text = "Tab transfers" },
    { value = "items", text = "Items only" },
    { value = "gold", text = "Gold only" },
    { value = "unrecorded", text = "Unrecorded changes" },
}

local VIEW_OPTIONS = {
    { value = "log", text = "Log" },
    { value = "summary", text = "Summary" },
}

local state = {
    bank = ns.BANK_CHARACTER,
    tab = nil,
    who = nil,
    kind = "all",
    view = "log",
    search = "",
}

local function Colorize(color, text)
    return "|c" .. color .. text .. "|r"
end

local function LayoutCells(frame, columns, fontObject)
    frame.cells = frame.cells or {}
    local x = 6
    for i, col in ipairs(columns) do
        local cell = frame.cells[i]
        if not cell then
            cell = frame:CreateFontString(nil, "ARTWORK", fontObject)
            cell:SetWordWrap(false)
            frame.cells[i] = cell
        end
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", frame, "LEFT", x, 0)
        cell:SetWidth(col.width - 6)
        cell:SetJustifyH(col.justify or "LEFT")
        cell:Show()
        x = x + col.width
    end
    for i = #columns + 1, #frame.cells do
        frame.cells[i]:Hide()
    end
end

local function ItemText(itemID, link)
    local icon = ns:GetItemIcon(itemID)
    local text = link or ns:GetItemLink(itemID) or ns:GetItemName(itemID)
    if icon then
        text = "|T" .. icon .. ":14:14|t " .. text
    end
    return text
end

local GOLD_TEXT = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t Gold"

-- Short label for a tab; drops the bank name when it is the bank being viewed.
local function ShortTab(bank, tab, tabName)
    if not tab then
        return bank == state.bank and "-" or ns.BANK_LABELS[bank]
    end
    local name = tabName and tabName ~= "" and tabName or ("Tab " .. tab)
    if bank == state.bank then
        return name
    end
    return ns.BANK_LABELS[bank] .. ": " .. name
end

local function DescribeEntry(e, dir)
    local action, tabText, color
    if e.kind == "move" then
        local from = ShortTab(e.bank, e.tab, e.tabName)
        local to = ShortTab(e.toBank, e.toTab, e.toTabName)
        if dir == "internal" then
            action, color = "Moved", COLOR_MOVE
        elseif dir == "in" then
            action, color = "Transfer in", COLOR_IN
        else
            action, color = "Transfer out", COLOR_OUT
        end
        tabText = from .. " > " .. to
    elseif e.kind == "deposit" then
        action, color = "Deposit", COLOR_IN
        tabText = ShortTab(e.bank, e.tab, e.tabName)
    else
        action, color = "Withdraw", COLOR_OUT
        tabText = ShortTab(e.bank, e.tab, e.tabName)
    end
    action = Colorize(color, action)
    if e.unrecorded then
        action = action .. Colorize(COLOR_MUTED, "*")
    end
    return action, tabText, color
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function Row_OnEnter(row)
    local data = row.data
    if not data then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local e = data.entry
    local link = e and e.link or data.link
    local itemID = e and e.itemID or data.itemID
    if itemID then
        if link then
            GameTooltip:SetHyperlink(link)
        else
            GameTooltip:SetItemByID(itemID)
        end
    else
        GameTooltip:SetText("Gold")
    end
    if e then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(ns:FormatEntryForChat(e), 1, 1, 1, true)
        GameTooltip:AddDoubleLine("When", date("%Y-%m-%d %H:%M:%S", e.t), nil, nil, nil, 1, 1, 1)
        GameTooltip:AddDoubleLine("Character", ns:ColorCharacter(e.who))
        if e.unrecorded then
            GameTooltip:AddLine("* Happened while Bank Audit was not watching (another PC, the addon disabled, or a character without it).", 0.6, 0.6, 0.6, true)
            if e.detectedBy then
                GameTooltip:AddDoubleLine("Detected by", ns:ColorCharacter(e.detectedBy))
            end
        end
    elseif data.last then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Last activity", date("%Y-%m-%d %H:%M", data.last), nil, nil, nil, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function Row_OnLeave()
    GameTooltip:Hide()
end

local function Row_OnClick(row)
    local data = row.data
    local link = data and (data.entry and data.entry.link or data.link)
    -- Shift-click links the item in chat, ctrl-click opens the dressing room, etc.
    if link and HandleModifiedItemClick then
        HandleModifiedItemClick(link)
    end
end

local function InitLogRow(row, data)
    LayoutCells(row, LOG_COLUMNS, "GameFontHighlightSmall")
    local e = data.entry
    local action, tabText, color = DescribeEntry(e, data.dir)
    local c = row.cells
    c[1]:SetText(date("%Y-%m-%d %H:%M", e.t))
    c[2]:SetText(ns:ColorCharacter(e.who))
    c[3]:SetText(action)
    c[4]:SetText(tabText)
    if e.money then
        c[5]:SetText(GOLD_TEXT .. "  " .. Colorize(color, ns:FormatMoney(e.money)))
        c[6]:SetText("")
    else
        c[5]:SetText(ItemText(e.itemID, e.link))
        local sign = data.dir == "in" and "+" or data.dir == "out" and "-" or ""
        c[6]:SetText(Colorize(color, sign .. e.count))
    end
end

local function InitSummaryRow(row, data)
    LayoutCells(row, SUMMARY_COLUMNS, "GameFontHighlightSmall")
    local c = row.cells
    local net = data.inCount - data.outCount
    local fmt = data.isGold and function(v) return ns:FormatMoney(v) end or tostring
    c[1]:SetText(data.isGold and GOLD_TEXT or ItemText(data.itemID, data.link))
    c[2]:SetText(data.inCount > 0 and Colorize(COLOR_IN, fmt(data.inCount)) or "-")
    c[3]:SetText(data.outCount > 0 and Colorize(COLOR_OUT, fmt(data.outCount)) or "-")
    if net > 0 then
        c[4]:SetText(Colorize(COLOR_IN, "+" .. fmt(net)))
    elseif net < 0 then
        c[4]:SetText(Colorize(COLOR_OUT, "-" .. fmt(-net)))
    else
        c[4]:SetText("0")
    end
    c[5]:SetText(data.moved > 0 and Colorize(COLOR_MOVE, fmt(data.moved)) or "-")
end

local function InitRow(row, data)
    if not row.initialized then
        row.initialized = true
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.08)
        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnClick", Row_OnClick)
    end
    row.data = data
    if data.entry then
        InitLogRow(row, data)
    else
        InitSummaryRow(row, data)
    end
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

local function CreateDropdown(parent, width, setup)
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(width)
    dropdown:SetupMenu(setup)
    return dropdown
end

local function AddRadio(root, text, key, value)
    root:CreateRadio(text, function()
        return state[key] == value
    end, function()
        state[key] = value
        UI:Refresh()
    end)
end

function UI:Create()
    local f = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    ButtonFrameTemplate_HidePortrait(f)
    f:SetSize(880, 540)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetTitle(ns.TITLE)
    f:Hide()
    tinsert(UISpecialFrames, FRAME_NAME)
    self.frame = f

    -- Filters --------------------------------------------------------------
    f.whoDropdown = CreateDropdown(f, 170, function(_, root)
        AddRadio(root, "All characters", "who", nil)
        for _, key in ipairs(ns:GetKnownCharacters()) do
            AddRadio(root, ns:ColorCharacter(key), "who", key)
        end
    end)
    f.whoDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)

    f.tabDropdown = CreateDropdown(f, 170, function(_, root)
        AddRadio(root, "All tabs", "tab", nil)
        local charKey = state.bank == ns.BANK_CHARACTER and (state.who or ns:GetCharacterKey()) or nil
        for _, tab in ipairs(ns:GetTabList(state.bank, charKey)) do
            AddRadio(root, tab.name and tab.name ~= "" and tab.name or ("Tab " .. tab.index), "tab", tab.index)
        end
    end)
    f.tabDropdown:SetPoint("LEFT", f.whoDropdown, "RIGHT", 8, 0)

    f.kindDropdown = CreateDropdown(f, 160, function(_, root)
        for _, opt in ipairs(KIND_OPTIONS) do
            AddRadio(root, opt.text, "kind", opt.value)
        end
    end)
    f.kindDropdown:SetPoint("LEFT", f.tabDropdown, "RIGHT", 8, 0)

    f.viewDropdown = CreateDropdown(f, 110, function(_, root)
        for _, opt in ipairs(VIEW_OPTIONS) do
            AddRadio(root, opt.text, "view", opt.value)
        end
    end)
    f.viewDropdown:SetPoint("LEFT", f.kindDropdown, "RIGHT", 8, 0)

    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("LEFT", f.viewDropdown, "RIGHT", 14, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(box)
        state.search = box:GetText() or ""
        UI:Refresh()
    end)
    f.search = search

    -- Column header ----------------------------------------------------------
    local inset = f.Inset
    inset:ClearAllPoints()
    inset:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -60)
    inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 26)

    local header = CreateFrame("Frame", nil, inset)
    header:SetPoint("TOPLEFT", inset, "TOPLEFT", 4, -4)
    header:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -24, -4)
    header:SetHeight(18)
    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(1, 1, 1, 0.06)
    f.header = header

    -- List -------------------------------------------------------------------
    local scrollBox = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scrollBox:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -24, 4)

    local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    f.scrollBox = scrollBox

    f.emptyText = inset:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    f.emptyText:SetPoint("CENTER", scrollBox, "CENTER")
    f.emptyText:SetWidth(500)

    -- Footer -----------------------------------------------------------------
    f.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 8)
    f.status:SetPoint("RIGHT", f, "RIGHT", -200, 0)
    f.status:SetJustifyH("LEFT")

    local optionsButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    optionsButton:SetSize(90, 22)
    optionsButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 3)
    optionsButton:SetText("Options")
    optionsButton:SetScript("OnClick", function() ns:OpenOptions() end)

    local exportButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportButton:SetSize(90, 22)
    exportButton:SetPoint("RIGHT", optionsButton, "LEFT", -4, 0)
    exportButton:SetText("Export")
    exportButton:SetScript("OnClick", function() UI:Export() end)

    -- Bank tabs along the bottom edge ---------------------------------------
    f.Tabs = {}
    for i, bank in ipairs({ ns.BANK_CHARACTER, ns.BANK_WARBAND }) do
        local tab = CreateFrame("Button", FRAME_NAME .. "Tab" .. i, f, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab.bank = bank
        tab:SetText(ns.BANK_LABELS[bank])
        if i == 1 then
            tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
        else
            tab:SetPoint("LEFT", f.Tabs[i - 1], "RIGHT", 4, 0)
        end
        tab:SetScript("OnClick", function(self)
            UI:SetBank(self.bank)
        end)
        f.Tabs[i] = tab
        if PanelTemplates_TabResize then
            PanelTemplates_TabResize(tab, 0)
        end
    end
    PanelTemplates_SetNumTabs(f, #f.Tabs)
    PanelTemplates_SetTab(f, 1)

    f:SetScript("OnShow", function() UI:Refresh() end)
end

--------------------------------------------------------------------------------
-- Behaviour
--------------------------------------------------------------------------------

function UI:SetBank(bank)
    state.bank = bank
    state.tab = nil
    if self.frame then
        PanelTemplates_SetTab(self.frame, bank == ns.BANK_WARBAND and 2 or 1)
    end
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    self:Refresh()
end

function UI:GetFilter()
    return {
        bank = state.bank,
        tab = state.tab,
        who = state.who,
        kind = state.kind,
        search = state.search,
    }
end

function UI:UpdateHeader(columns)
    local header = self.frame.header
    LayoutCells(header, columns, "GameFontNormalSmall")
    for i, col in ipairs(columns) do
        header.cells[i]:SetText(col.title)
    end
end

function UI:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then
        return
    end

    f.whoDropdown:GenerateMenu()
    f.tabDropdown:GenerateMenu()
    f.kindDropdown:GenerateMenu()
    f.viewDropdown:GenerateMenu()

    local results = ns:QueryLog(self:GetFilter())
    local data
    if state.view == "summary" then
        self:UpdateHeader(SUMMARY_COLUMNS)
        data = ns:Summarize(results)
    else
        self:UpdateHeader(LOG_COLUMNS)
        data = results
    end
    f.scrollBox:SetDataProvider(CreateDataProvider(data), ScrollBoxConstants.RetainScrollPosition)

    if #data == 0 then
        local store = ns:GetBankStore(state.bank, state.bank == ns.BANK_CHARACTER and (state.who or ns:GetCharacterKey()) or nil)
        if not store or not store.updated then
            f.emptyText:SetText("No baseline yet. Visit a banker to start auditing the " .. ns.BANK_LABELS[state.bank] .. ".")
        else
            f.emptyText:SetText("No matching activity.")
        end
        f.emptyText:Show()
    else
        f.emptyText:Hide()
    end

    -- Footer totals
    local goldIn, goldOut, itemIn, itemOut = 0, 0, 0, 0
    for _, r in ipairs(results) do
        local e = r.entry
        if e.money then
            if r.dir == "in" then goldIn = goldIn + e.money elseif r.dir == "out" then goldOut = goldOut + e.money end
        else
            if r.dir == "in" then itemIn = itemIn + e.count elseif r.dir == "out" then itemOut = itemOut + e.count end
        end
    end
    local status = string.format("%d entries   Items in %s / out %s", #results, Colorize(COLOR_IN, itemIn), Colorize(COLOR_OUT, itemOut))
    if state.bank == ns.BANK_WARBAND then
        status = status .. string.format("   Gold in %s / out %s", Colorize(COLOR_IN, ns:FormatMoney(goldIn)), Colorize(COLOR_OUT, ns:FormatMoney(goldOut)))
        if ns.db.warband.money then
            status = status .. "   Balance " .. ns:FormatMoney(ns.db.warband.money)
        end
    end
    f.status:SetText(status)
end

function UI:Show()
    if not self.frame then
        self:Create()
    end
    self.frame:Show()
end

function UI:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Show()
    end
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

local function CsvField(value)
    value = tostring(value == nil and "" or value)
    if value:find('[,"\n]') then
        value = '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

function UI:BuildCsv()
    local lines = { "time,character,bank,tab,action,item,itemID,count,copper,gold,to_bank,to_tab,unrecorded" }
    for _, r in ipairs(ns:QueryLog(self:GetFilter())) do
        local e = r.entry
        local action = e.kind
        if e.kind == "move" then
            action = r.dir == "internal" and "move" or (r.dir == "in" and "transfer_in" or "transfer_out")
        end
        local fields = {
            date("%Y-%m-%d %H:%M:%S", e.t),
            e.who or "unknown",
            ns.BANK_LABELS[e.bank],
            e.tab and (e.tabName or ("Tab " .. e.tab)) or "",
            action,
            e.money and "Gold" or ns:GetItemName(e.itemID, e.link),
            e.itemID or "",
            e.count or "",
            e.money or "",
            e.money and ns:FormatMoneyPlain(e.money) or "",
            e.toBank and ns.BANK_LABELS[e.toBank] or "",
            e.toTab and (e.toTabName or ("Tab " .. e.toTab)) or "",
            e.unrecorded and "yes" or "",
        }
        for i, v in ipairs(fields) do
            fields[i] = CsvField(v)
        end
        lines[#lines + 1] = table.concat(fields, ",")
    end
    return table.concat(lines, "\n"), #lines - 1
end

function UI:Export()
    local text, count = self:BuildCsv()
    local e = self.exportFrame
    if not e then
        e = CreateFrame("Frame", "WowBankAuditExportFrame", UIParent, "ButtonFrameTemplate")
        ButtonFrameTemplate_HidePortrait(e)
        ButtonFrameTemplate_HideButtonBar(e)
        e:SetSize(720, 460)
        e:SetPoint("CENTER")
        e:SetFrameStrata("DIALOG")
        e:SetMovable(true)
        e:EnableMouse(true)
        e:RegisterForDrag("LeftButton")
        e:SetScript("OnDragStart", e.StartMoving)
        e:SetScript("OnDragStop", e.StopMovingOrSizing)
        tinsert(UISpecialFrames, "WowBankAuditExportFrame")

        local scroll = CreateFrame("ScrollFrame", nil, e.Inset, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", e.Inset, "TOPLEFT", 8, -8)
        scroll:SetPoint("BOTTOMRIGHT", e.Inset, "BOTTOMRIGHT", -28, 8)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(660)
        edit:SetScript("OnEscapePressed", function() e:Hide() end)
        scroll:SetScrollChild(edit)
        e.edit = edit
        self.exportFrame = e
    end
    e:SetTitle(string.format("%s export - %d entries (Ctrl+C to copy)", ns.TITLE, count))
    e.edit:SetText(text)
    e:Show()
    e.edit:SetFocus()
    e.edit:HighlightText()
end

ns:RegisterCallback("LOG_UPDATED", function()
    UI:Refresh()
end)

ns:RegisterCallback("SETTINGS_CHANGED", function()
    UI:Refresh()
end)
