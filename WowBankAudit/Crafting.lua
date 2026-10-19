-- Attributes reagents that professions pull straight from the Bank and Warband Bank
-- to the crafting character. Bank contents can't be read away from a banker, but
-- item counts including the banks can, so while a profession window is open we
-- watch the bank share of each stored item's count and log any drop as crafting use.
local _, ns = ...

local Crafting = {}
ns.Crafting = Crafting

-- Item counts can lag the craft by a frame or two; also coalesces bursts of events.
local CHECK_DELAY = 0.5

local function GetItemCount(itemID, includeBank, includeReagentBank, includeAccountBank)
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, includeBank, false, includeReagentBank, includeAccountBank) or 0
    end
    return _G.GetItemCount(itemID, includeBank, false, includeReagentBank, includeAccountBank) or 0
end

-- Returns how many of an item are in the character bank and in the warband bank.
local function GetBankCounts(itemID)
    local bags = GetItemCount(itemID)
    local bank = GetItemCount(itemID, true, true, false) - bags
    local warband = GetItemCount(itemID, false, false, true) - bags
    return math.max(bank, 0), math.max(warband, 0)
end

-- Reads current bank counts for every tracked item in the stored snapshots.
-- Returns { character = {[itemID] = count}, warband = {[itemID] = count} } or nil.
function Crafting:ReadCounts()
    local charKey = ns:GetCharacterKey()
    if not (charKey and ns.db) then
        return nil
    end
    local counts = { [ns.BANK_CHARACTER] = {}, [ns.BANK_WARBAND] = {} }
    local items = {}
    for bank in pairs(counts) do
        local store = ns:GetBankStore(bank, charKey)
        -- Without a baseline there is nothing to attribute against.
        if store and store.updated then
            for _, tab in pairs(store.tabs) do
                for itemID in pairs(tab.items or {}) do
                    items[itemID] = items[itemID] or {}
                    items[itemID][bank] = true
                end
            end
        end
    end
    for itemID, banks in pairs(items) do
        if ns:IsTrackedItem(itemID) then
            local bank, warband = GetBankCounts(itemID)
            if banks[ns.BANK_CHARACTER] then
                counts[ns.BANK_CHARACTER][itemID] = bank
            end
            if banks[ns.BANK_WARBAND] then
                counts[ns.BANK_WARBAND][itemID] = warband
            end
        end
    end
    return counts
end

-- Logs `used` of an item as taken from a bank for crafting, and takes it out of the
-- stored snapshot so the next bank visit doesn't report it again as unrecorded.
-- The client doesn't say which tab the reagents came from, so they are taken from
-- the tabs holding the item in tab order.
function Crafting:LogUsage(bank, itemID, used)
    local charKey = ns:GetCharacterKey()
    local store = ns:GetBankStore(bank, charKey)
    local classID, subclassID = ns:GetItemClass(itemID)
    local function Add(tab, tabName, count)
        ns:AddEntry({
            kind = "withdraw",
            craft = true,
            bank = bank,
            tab = tab,
            tabName = tabName,
            itemID = itemID,
            link = ns:GetItemLink(itemID),
            classID = classID,
            subclassID = subclassID,
            count = count,
            who = charKey,
        }, true)
    end

    local indexes = {}
    for index in pairs(store.tabs) do
        indexes[#indexes + 1] = index
    end
    table.sort(indexes)
    for _, index in ipairs(indexes) do
        if used == 0 then
            break
        end
        local tab = store.tabs[index]
        local have = tab.items and tab.items[itemID] or 0
        if have > 0 then
            local n = math.min(have, used)
            tab.items[itemID] = have - n > 0 and have - n or nil
            used = used - n
            Add(index, tab.name, n)
        end
    end
    -- The snapshot was stale and held less than was used.
    if used > 0 then
        Add(nil, nil, used)
    end
end

function Crafting:Check()
    if not self.counts then
        return
    end
    local current = self:ReadCounts()
    if not current then
        return
    end
    -- While the bank is open (and settled) the scanner sees these changes itself.
    local scanner = ns.Scanner
    local scannerLive = scanner and scanner.bankOpen and not scanner.settling
    local added = 0
    if not scannerLive then
        for bank, items in pairs(current) do
            local previous = self.counts[bank] or {}
            for itemID, count in pairs(items) do
                local before = previous[itemID]
                if before and count < before then
                    self:LogUsage(bank, itemID, before - count)
                    added = added + 1
                end
            end
        end
    end
    self.counts = current
    if added > 0 then
        ns:Fire("LOG_UPDATED")
    end
end

function Crafting:ScheduleCheck()
    if self.checkPending then
        return
    end
    self.checkPending = true
    C_Timer.After(CHECK_DELAY, function()
        self.checkPending = false
        self:Check()
        if self.closing then
            self.closing = false
            self.counts = nil
        end
    end)
end

function Crafting:IsActive()
    return self.counts ~= nil
end

function Crafting:OnProfessionOpened()
    self.closing = false
    -- Reopened before the final check ran: keep the existing counts.
    if not self.counts then
        self.counts = self:ReadCounts()
    end
end

function Crafting:OnProfessionClosed()
    if self.counts then
        self.closing = true
        self:ScheduleCheck()
    end
end

local EVENTS = {
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_CLOSE",
    "TRADE_SKILL_ITEM_CRAFTED_RESULT",
    "UNIT_SPELLCAST_SUCCEEDED",
    "BAG_UPDATE_DELAYED",
    "ITEM_COUNT_CHANGED",
}

function Crafting:Init()
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

function Crafting:OnEvent(event, arg1)
    if event == "TRADE_SKILL_SHOW" then
        self:OnProfessionOpened()
    elseif event == "TRADE_SKILL_CLOSE" then
        self:OnProfessionClosed()
    elseif not self.counts then
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            self:ScheduleCheck()
        end
    else
        self:ScheduleCheck()
    end
end

ns:RegisterCallback("READY", function()
    Crafting:Init()
end)
