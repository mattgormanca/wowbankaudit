local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "Bank Audit"

ns.BANK_CHARACTER = "character"
ns.BANK_WARBAND = "warband"
ns.BANK_LABELS = {
    character = "Bank",
    warband = "Warband Bank",
}

local DEFAULT_SETTINGS = {
    trackAllItems = false,          -- record every item, not just trade goods
    includeCraftingReagents = true, -- also count items flagged as crafting reagents
    logUnrecorded = true,           -- record changes made while the addon was not watching
    chatNotify = false,             -- print each new entry to chat
    maxEntries = 20000,
}

--------------------------------------------------------------------------------
-- Callbacks
--------------------------------------------------------------------------------

local callbacks = {}

function ns:RegisterCallback(event, fn)
    callbacks[event] = callbacks[event] or {}
    table.insert(callbacks[event], fn)
end

function ns:Fire(event, ...)
    for _, fn in ipairs(callbacks[event] or {}) do
        fn(...)
    end
end

function ns:Print(...)
    print("|cff33ccff" .. ns.TITLE .. "|r:", ...)
end

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

function ns:InitDB()
    WowBankAuditDB = WowBankAuditDB or {}
    local db = WowBankAuditDB
    db.schema = db.schema or 1
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if db.settings[k] == nil then
            db.settings[k] = v
        end
    end
    db.warband = db.warband or {}
    db.warband.tabs = db.warband.tabs or {}
    db.characters = db.characters or {}
    db.links = db.links or {}
    db.log = db.log or {}
    db.nextID = db.nextID or (#db.log + 1)
    self.db = db
end

function ns:GetCharacterKey()
    if not self.charKey then
        local name = UnitName("player")
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        if not name or not realm or realm == "" then
            return nil
        end
        self.charKey = name .. "-" .. realm
    end
    return self.charKey
end

function ns:GetCharacterDB(key)
    key = key or self:GetCharacterKey()
    if not key then
        return nil
    end
    local chars = self.db.characters
    if not chars[key] then
        chars[key] = { tabs = {} }
    end
    chars[key].tabs = chars[key].tabs or {}
    return chars[key]
end

-- Snapshot storage for a bank. Character banks are per character; the warband bank is shared.
function ns:GetBankStore(bank, charKey)
    if bank == ns.BANK_WARBAND then
        return self.db.warband
    end
    return self:GetCharacterDB(charKey)
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

local function GetItemInfoInstant(itemID)
    if C_Item and C_Item.GetItemInfoInstant then
        return C_Item.GetItemInfoInstant(itemID)
    end
    return _G.GetItemInfoInstant(itemID)
end

local function GetItemInfo(itemID)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(itemID)
    end
    return _G.GetItemInfo(itemID)
end

function ns:GetItemClass(itemID)
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemID)
    return classID, subclassID
end

function ns:IsTrackedItem(itemID)
    local settings = self.db.settings
    if settings.trackAllItems then
        return true
    end
    local classID = self:GetItemClass(itemID)
    local tradegoods = Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods or 7
    if classID == tradegoods then
        return true
    end
    if settings.includeCraftingReagents then
        local isCraftingReagent = select(17, GetItemInfo(itemID))
        if isCraftingReagent then
            return true
        end
    end
    return false
end

function ns:RememberLink(itemID, link)
    if itemID and link then
        self.db.links[itemID] = link
    end
end

function ns:GetItemLink(itemID)
    local link = self.db.links[itemID]
    if link then
        return link
    end
    local _, infoLink = GetItemInfo(itemID)
    if infoLink then
        self.db.links[itemID] = infoLink
    end
    return infoLink
end

function ns:GetItemName(itemID, link)
    link = link or self:GetItemLink(itemID)
    local name = link and link:match("%[(.-)%]")
    if not name then
        name = GetItemInfo(itemID)
    end
    return name or ("item:" .. tostring(itemID))
end

function ns:GetItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    return select(5, GetItemInfoInstant(itemID))
end

function ns:FormatMoney(copper)
    copper = copper or 0
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    end
    return GetMoneyString(copper, true)
end

-- Plain-text money for exports, e.g. "12g 34s 56c".
function ns:FormatMoneyPlain(copper)
    copper = copper or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("%dg %ds %dc", g, s, c)
end

--------------------------------------------------------------------------------
-- Log
--------------------------------------------------------------------------------

function ns:FormatEntryForChat(e)
    local what
    if e.money then
        what = self:FormatMoney(e.money)
    else
        what = (e.link or self:GetItemName(e.itemID)) .. " x" .. e.count
    end
    local where = self:TabLabel(e.bank, e.tab, e.tabName)
    local verb
    if e.kind == "deposit" then
        verb = "Deposited"
    elseif e.kind == "withdraw" then
        verb = e.craft and "Used for crafting" or "Withdrew"
    else
        verb = "Moved"
        where = where .. " -> " .. self:TabLabel(e.toBank, e.toTab, e.toTabName)
    end
    if e.unrecorded then
        verb = "Detected unrecorded change: " .. verb:lower()
    end
    return string.format("%s %s (%s)", verb, what, where)
end

-- Adds an entry to the audit log. Pass silent = true when adding a batch and
-- fire LOG_UPDATED yourself afterwards.
function ns:AddEntry(entry, silent)
    local db = self.db
    entry.id = db.nextID
    db.nextID = db.nextID + 1
    entry.t = entry.t or time()
    table.insert(db.log, entry)

    local overflow = #db.log - (db.settings.maxEntries or DEFAULT_SETTINGS.maxEntries)
    if overflow > 0 then
        local trimmed = {}
        for i = overflow + 1, #db.log do
            trimmed[#trimmed + 1] = db.log[i]
        end
        db.log = trimmed
    end

    if db.settings.chatNotify then
        self:Print(self:FormatEntryForChat(entry))
    end
    if not silent then
        self:Fire("LOG_UPDATED")
    end
end

function ns:ClearLog()
    wipe(self.db.log)
    self:Fire("LOG_UPDATED")
end

-- Forget stored bank contents so the next bank visit takes a fresh baseline
-- without logging differences.
function ns:ResetSnapshots()
    self.db.warband = { tabs = {} }
    for _, char in pairs(self.db.characters) do
        char.tabs = {}
        char.updated = nil
    end
    self:Fire("LOG_UPDATED")
end

function ns:PurgeOlderThan(days)
    local cutoff = time() - days * 86400
    local kept, removed = {}, 0
    for _, e in ipairs(self.db.log) do
        if e.t >= cutoff then
            kept[#kept + 1] = e
        else
            removed = removed + 1
        end
    end
    self.db.log = kept
    self:Fire("LOG_UPDATED")
    return removed
end

function ns:TabLabel(bank, tab, tabName)
    local bankLabel = ns.BANK_LABELS[bank] or tostring(bank)
    if not tab then
        return bankLabel
    end
    return bankLabel .. ": " .. (tabName and tabName ~= "" and tabName or ("Tab " .. tab))
end

function ns:Direction(entry, bank, tab)
    return ns.Diff.Direction(entry, bank, tab)
end

-- filter = { bank = <required>, tab = <index|nil>, who = <charKey|nil>,
--            kind = "all"|"deposit"|"withdraw"|"move"|"craft"|"gold"|"items"|"unrecorded", search = <string|nil> }
-- Returns matching entries, newest first. Each result is { entry = e, dir = "in"|"out"|"internal" }.
function ns:QueryLog(filter)
    local results = {}
    local search = filter.search and filter.search ~= "" and filter.search:lower() or nil
    local kind = filter.kind or "all"
    local log = self.db.log
    for i = #log, 1, -1 do
        local e = log[i]
        local dir = self:Direction(e, filter.bank, filter.tab)
        local ok = dir ~= nil
        if ok and filter.who and e.who ~= filter.who then
            ok = false
        end
        if ok and kind ~= "all" then
            if kind == "deposit" then
                ok = dir == "in"
            elseif kind == "withdraw" then
                ok = dir == "out"
            elseif kind == "move" then
                ok = e.kind == "move"
            elseif kind == "craft" then
                ok = e.craft == true
            elseif kind == "gold" then
                ok = e.money ~= nil
            elseif kind == "items" then
                ok = e.itemID ~= nil
            elseif kind == "unrecorded" then
                ok = e.unrecorded == true
            end
        end
        if ok and search then
            local haystack
            if e.money then
                haystack = "gold"
            else
                haystack = self:GetItemName(e.itemID, e.link):lower()
            end
            haystack = haystack .. " " .. (e.who or ""):lower()
            ok = haystack:find(search, 1, true) ~= nil
        end
        if ok then
            results[#results + 1] = { entry = e, dir = dir }
        end
    end
    return results
end

-- Totals per item (and gold) for a QueryLog result.
-- Returns an array sorted by name with gold first: { itemID|nil, isGold, inCount, outCount, moved }
function ns:Summarize(results)
    local byKey, rows = {}, {}
    for _, r in ipairs(results) do
        local e = r.entry
        local key = e.money and "gold" or e.itemID
        local row = byKey[key]
        if not row then
            row = { itemID = e.itemID, isGold = e.money ~= nil, link = e.link, inCount = 0, outCount = 0, moved = 0, last = e.t }
            byKey[key] = row
            rows[#rows + 1] = row
        end
        local amount = e.money or e.count or 0
        if r.dir == "in" then
            row.inCount = row.inCount + amount
        elseif r.dir == "out" then
            row.outCount = row.outCount + amount
        else
            row.moved = row.moved + amount
        end
        if e.t > row.last then
            row.last = e.t
        end
    end
    for _, row in ipairs(rows) do
        row.name = row.isGold and "" or self:GetItemName(row.itemID, row.link):lower()
    end
    table.sort(rows, function(a, b)
        if a.isGold ~= b.isGold then
            return a.isGold
        end
        return a.name < b.name
    end)
    return rows
end

function ns:GetKnownCharacters()
    local seen, list = {}, {}
    for key in pairs(self.db.characters) do
        seen[key] = true
    end
    for _, e in ipairs(self.db.log) do
        if e.who then
            seen[e.who] = true
        end
    end
    for key in pairs(seen) do
        list[#list + 1] = key
    end
    table.sort(list)
    return list
end

-- Known tabs for a bank as an array of { index, name }.
function ns:GetTabList(bank, charKey)
    local store = self:GetBankStore(bank, charKey)
    local list = {}
    if store and store.tabs then
        for index, tab in pairs(store.tabs) do
            list[#list + 1] = { index = index, name = tab.name }
        end
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    return list
end

function ns:ColorCharacter(key)
    if not key then
        return "|cff999999Unknown|r"
    end
    local char = self.db.characters[key]
    local name = key
    local myRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    if myRealm then
        name = name:gsub("%-" .. myRealm:gsub("%p", "%%%0") .. "$", "")
    end
    if char and char.class and C_ClassColor and C_ClassColor.GetClassColor then
        local color = C_ClassColor.GetClassColor(char.class)
        if color then
            return color:WrapTextInColorCode(name)
        end
    end
    return name
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ns:InitDB()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        local key = ns:GetCharacterKey()
        if key then
            local char = ns:GetCharacterDB(key)
            char.class = select(2, UnitClass("player"))
        end
        ns:Fire("READY")
    end
end)

--------------------------------------------------------------------------------
-- Slash commands and addon compartment
--------------------------------------------------------------------------------

local function PrintHelp()
    ns:Print("commands:")
    print("  /bankaudit - toggle the audit window")
    print("  /bankaudit options - open settings")
    print("  /bankaudit export - export the current view as CSV")
    print("  /bankaudit purge <days> - delete entries older than <days>")
    print("  /bankaudit clear - delete the entire audit log")
    print("  /bankaudit reset - forget stored bank contents (re-baseline next visit)")
    print("  /bankaudit status - show tracking status")
end

SLASH_WOWBANKAUDIT1 = "/bankaudit"
SLASH_WOWBANKAUDIT2 = "/baudit"
SlashCmdList.WOWBANKAUDIT = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        ns.UI:Toggle()
    elseif cmd == "options" or cmd == "config" then
        ns:OpenOptions()
    elseif cmd == "export" then
        ns.UI:Show()
        ns.UI:Export()
    elseif cmd == "purge" then
        local days = tonumber(rest)
        if not days or days < 0 then
            ns:Print("usage: /bankaudit purge <days>")
            return
        end
        ns:Print(string.format("removed %d entries older than %d days.", ns:PurgeOlderThan(days), days))
    elseif cmd == "clear" then
        StaticPopup_Show("WOWBANKAUDIT_CLEAR_LOG")
    elseif cmd == "reset" then
        StaticPopup_Show("WOWBANKAUDIT_RESET_SNAPSHOTS")
    elseif cmd == "status" then
        ns.Scanner:PrintStatus()
    else
        PrintHelp()
    end
end

function WowBankAudit_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then
        ns:OpenOptions()
    else
        ns.UI:Toggle()
    end
end

function WowBankAudit_OnAddonCompartmentEnter(_, frame)
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    GameTooltip:SetText(ns.TITLE)
    GameTooltip:AddLine("Left-click: toggle window", 1, 1, 1)
    GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
    GameTooltip:Show()
end

function WowBankAudit_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
