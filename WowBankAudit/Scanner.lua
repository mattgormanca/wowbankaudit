-- Watches the Bank and Warband Bank while they are open, snapshots every tab,
-- and turns snapshot differences into audit log entries.
local _, ns = ...

local Scanner = {}
ns.Scanner = Scanner

-- Bank contents can arrive over several frames after the bank opens; wait this
-- long before comparing against the stored snapshot.
local SETTLE_DELAY = 1.5
-- Coalesce bag updates so a move between two tabs is seen as one change.
local COALESCE_DELAY = 0.2

local BANK_DEFS = {
    { key = ns.BANK_CHARACTER, enumKey = "Character", bagPrefix = "CharacterBankTab_" },
    { key = ns.BANK_WARBAND, enumKey = "Account", bagPrefix = "AccountBankTab_" },
}
local MAX_FALLBACK_TABS = 10

local BANK_INTERACTION_TYPES = { "Banker", "AccountBanker", "CharacterBanker" }

local function GetBankType(def)
    return Enum and Enum.BankType and Enum.BankType[def.enumKey]
end

local function CanView(def)
    local bankType = GetBankType(def)
    if bankType and C_Bank and C_Bank.CanViewBank then
        local ok, canView = pcall(C_Bank.CanViewBank, bankType)
        if ok and canView == false then
            return false
        end
    end
    return true
end

-- Returns { [tabIndex] = { bag = bagID, name = string|nil } } for purchased tabs.
function Scanner:GetTabs(def)
    local tabs, found = {}, false
    local bankType = GetBankType(def)
    if bankType and C_Bank and C_Bank.FetchPurchasedBankTabData then
        local ok, data = pcall(C_Bank.FetchPurchasedBankTabData, bankType)
        if ok and type(data) == "table" then
            for index, tabData in ipairs(data) do
                if tabData.ID then
                    tabs[index] = { bag = tabData.ID, name = tabData.name }
                    found = true
                end
            end
        end
    end
    if not found and Enum and Enum.BagIndex then
        for index = 1, MAX_FALLBACK_TABS do
            local bag = Enum.BagIndex[def.bagPrefix .. index]
            if not bag then
                break
            end
            if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                tabs[index] = { bag = bag }
            end
        end
    end
    return tabs
end

function Scanner:RebuildBagMap()
    self.bagToBank = {}
    for _, def in ipairs(BANK_DEFS) do
        if Enum and Enum.BagIndex then
            for index = 1, MAX_FALLBACK_TABS do
                local bag = Enum.BagIndex[def.bagPrefix .. index]
                if not bag then
                    break
                end
                self.bagToBank[bag] = def.key
            end
        end
        for _, tab in pairs(self:GetTabs(def)) do
            self.bagToBank[tab.bag] = def.key
        end
    end
end

-- Reads one bank. Returns { [tabIndex] = { name, slots, items = {[itemID] = count}, total } } or nil.
function Scanner:ScanBank(def)
    if not CanView(def) then
        return nil
    end
    local result, any = {}, false
    for index, tab in pairs(self:GetTabs(def)) do
        local slots = C_Container.GetContainerNumSlots(tab.bag) or 0
        if slots > 0 then
            local items, total = {}, 0
            for slot = 1, slots do
                local info = C_Container.GetContainerItemInfo(tab.bag, slot)
                if info and info.itemID then
                    local count = info.stackCount or 1
                    items[info.itemID] = (items[info.itemID] or 0) + count
                    total = total + count
                    ns:RememberLink(info.itemID, info.hyperlink)
                end
            end
            result[index] = { name = tab.name, slots = slots, items = items, total = total }
            any = true
        end
    end
    return any and result or nil
end

-- mode: "normal"  - live change while the bank is open
--       "reconcile" - first look after opening; differences happened while we weren't watching
--       "close"   - final flush as the bank closes
function Scanner:RunScan(mode)
    self.scanPending = false
    if not self.bankOpen or not ns.db then
        return
    end
    local charKey = ns:GetCharacterKey()
    if not charKey then
        return
    end

    local changes = {}
    local tabNames = {}
    for _, def in ipairs(BANK_DEFS) do
        local scan = self:ScanBank(def)
        if scan then
            local store = ns:GetBankStore(def.key, charKey)
            local hasBaseline = store.updated ~= nil
            tabNames[def.key] = {}
            for index, tab in pairs(scan) do
                local old = store.tabs[index]
                -- While closing, an empty read of a tab that had items is far more likely
                -- to be the client clearing the bank than a real withdrawal.
                local unreliable = mode == "close" and tab.total == 0 and old and next(old.items or {}) ~= nil
                if not unreliable then
                    if hasBaseline then
                        table.insert(changes, { bank = def.key, tab = index, old = old and old.items or {}, new = tab.items })
                    end
                    store.tabs[index] = { name = tab.name, slots = tab.slots, items = tab.items }
                end
                tabNames[def.key][index] = tab.name or (old and old.name)
            end
            store.updated = time()
            store.by = charKey
        end
    end

    local unrecorded = mode == "reconcile"
    if unrecorded and not ns.db.settings.logUnrecorded then
        return
    end

    local added = 0
    for _, m in ipairs(ns.Diff.Compute(changes)) do
        if ns:IsTrackedItem(m.itemID) then
            local touchesCharacterBank = m.bank == ns.BANK_CHARACTER or m.toBank == ns.BANK_CHARACTER
            local classID, subclassID = ns:GetItemClass(m.itemID)
            ns:AddEntry({
                kind = m.kind,
                bank = m.bank,
                tab = m.tab,
                tabName = tabNames[m.bank] and tabNames[m.bank][m.tab],
                toBank = m.toBank,
                toTab = m.toTab,
                toTabName = m.toBank and tabNames[m.toBank] and tabNames[m.toBank][m.toTab],
                itemID = m.itemID,
                link = ns:GetItemLink(m.itemID),
                classID = classID,
                subclassID = subclassID,
                count = m.count,
                -- Only this character can touch its own bank, so it is the actor even for
                -- unrecorded changes. For the warband bank, an unrecorded change could be anyone.
                who = (not unrecorded or touchesCharacterBank) and charKey or nil,
                detectedBy = unrecorded and charKey or nil,
                unrecorded = unrecorded or nil,
            }, true)
            added = added + 1
        end
    end
    if added > 0 then
        ns:Fire("LOG_UPDATED")
    end
end

function Scanner:CheckMoney(mode)
    if not (self.bankOpen and ns.db and C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType) then
        return
    end
    local bankType = Enum.BankType.Account
    if not bankType or not CanView(BANK_DEFS[2]) then
        return
    end
    local ok, money = pcall(C_Bank.FetchDepositedMoney, bankType)
    if not ok or type(money) ~= "number" then
        return
    end
    local store = ns.db.warband
    local old = store.money
    store.money = money
    if old == nil or old == money then
        return
    end
    local unrecorded = mode == "reconcile"
    if unrecorded and not ns.db.settings.logUnrecorded then
        return
    end
    local charKey = ns:GetCharacterKey()
    local delta = money - old
    ns:AddEntry({
        kind = delta > 0 and "deposit" or "withdraw",
        bank = ns.BANK_WARBAND,
        money = math.abs(delta),
        who = not unrecorded and charKey or nil,
        detectedBy = unrecorded and charKey or nil,
        unrecorded = unrecorded or nil,
    })
end

function Scanner:ScheduleScan()
    if self.scanPending or self.settling then
        return
    end
    self.scanPending = true
    local session = self.session
    C_Timer.After(COALESCE_DELAY, function()
        if self.session == session and self.scanPending then
            self:RunScan("normal")
        end
    end)
end

function Scanner:OnBankOpened()
    if self.bankOpen then
        return
    end
    self.bankOpen = true
    self.settling = true
    self.scanPending = false
    self.session = (self.session or 0) + 1
    self:RebuildBagMap()
    local session = self.session
    C_Timer.After(SETTLE_DELAY, function()
        if self.session == session and self.bankOpen then
            self.settling = false
            self:RunScan("reconcile")
            self:CheckMoney("reconcile")
        end
    end)
end

function Scanner:OnBankClosed()
    if not self.bankOpen then
        return
    end
    if self.scanPending and not self.settling then
        self:RunScan("close")
    end
    self.bankOpen = false
    self.settling = false
    self.scanPending = false
    self.session = (self.session or 0) + 1
end

function Scanner:IsBankInteraction(interactionType)
    return self.bankInteractions and self.bankInteractions[interactionType] or false
end

function Scanner:PrintStatus()
    local db = ns.db
    ns:Print(string.format("bank %s, %d log entries.", self.bankOpen and "open" or "closed", #db.log))
    local function Describe(label, store)
        if not store or not store.updated then
            print(string.format("  %s: not seen yet - visit a banker to take a baseline.", label))
            return
        end
        local tabs = 0
        for _ in pairs(store.tabs) do
            tabs = tabs + 1
        end
        print(string.format("  %s: %d tabs, last seen %s by %s", label, tabs, date("%Y-%m-%d %H:%M", store.updated), store.by or "?"))
    end
    Describe(ns.BANK_LABELS.character, ns:GetCharacterDB())
    Describe(ns.BANK_LABELS.warband, db.warband)
    if db.warband.money then
        print("  Warband gold: " .. ns:FormatMoney(db.warband.money))
    end
    print("  Tracking: " .. (db.settings.trackAllItems and "all items" or "trade goods"))
end

local EVENTS = {
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    "BAG_UPDATE",
    "BAG_UPDATE_DELAYED",
    "ACCOUNT_MONEY",
    "BANK_TABS_CHANGED",
    "BANK_TAB_SETTINGS_UPDATED",
    "PLAYERBANKSLOTS_CHANGED",
}

function Scanner:Init()
    self.bankInteractions = {}
    if Enum and Enum.PlayerInteractionType then
        for _, name in ipairs(BANK_INTERACTION_TYPES) do
            local value = Enum.PlayerInteractionType[name]
            if value then
                self.bankInteractions[value] = true
            end
        end
    end
    self.bagToBank = {}

    local frame = CreateFrame("Frame")
    for _, event in ipairs(EVENTS) do
        -- Not every event exists on every client version.
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
    self.frame = frame
end

function Scanner:OnEvent(event, arg1)
    if event == "BANKFRAME_OPENED" then
        self:OnBankOpened()
    elseif event == "BANKFRAME_CLOSED" then
        self:OnBankClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if self:IsBankInteraction(arg1) then
            self:OnBankOpened()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if self:IsBankInteraction(arg1) then
            self:OnBankClosed()
        end
    elseif not self.bankOpen then
        return
    elseif event == "BAG_UPDATE" then
        if arg1 and self.bagToBank[arg1] then
            self.dirty = true
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if self.dirty then
            self.dirty = false
            self:ScheduleScan()
        end
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        self:ScheduleScan()
    elseif event == "ACCOUNT_MONEY" then
        if not self.settling then
            self:CheckMoney("normal")
        end
    elseif event == "BANK_TABS_CHANGED" or event == "BANK_TAB_SETTINGS_UPDATED" then
        self:RebuildBagMap()
        self:ScheduleScan()
    end
end

ns:RegisterCallback("READY", function()
    Scanner:Init()
end)
