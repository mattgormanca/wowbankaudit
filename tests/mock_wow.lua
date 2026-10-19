-- Minimal stand-ins for the WoW client API used by Core.lua, Diff.lua, Scanner.lua and Crafting.lua.
Mock = { frames = {}, timers = {}, now = 0, bags = {}, tabData = {}, money = 0, printed = {} }

date = os.date
time = os.time
tinsert = table.insert
SlashCmdList = {}
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(Mock.printed, table.concat(parts, " "))
end

Enum = {
    BankType = { Character = 0, Guild = 1, Account = 2 },
    BagIndex = {
        CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8,
        CharacterBankTab_4 = 9, CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
        AccountBankTab_1 = 12, AccountBankTab_2 = 13, AccountBankTab_3 = 14,
        AccountBankTab_4 = 15, AccountBankTab_5 = 16,
    },
    ItemClass = { Tradegoods = 7, Weapon = 2 },
    PlayerInteractionType = { Banker = 8, AccountBanker = 68 },
}

-- itemID -> classID; 7 = trade goods
Mock.itemClass = { [1001] = 7, [1002] = 7, [1003] = 7, [2001] = 2 }

local frameMethods = {}
frameMethods.__index = frameMethods
function frameMethods:RegisterEvent(e) self.events[e] = true end
function frameMethods:UnregisterEvent(e) self.events[e] = nil end
function frameMethods:SetScript(name, fn) self.scripts[name] = fn end

function CreateFrame()
    local f = setmetatable({ events = {}, scripts = {} }, frameMethods)
    table.insert(Mock.frames, f)
    return f
end

function Mock.Fire(event, ...)
    for _, f in ipairs(Mock.frames) do
        if f.events[event] and f.scripts.OnEvent then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end

C_Timer = {}
function C_Timer.After(delay, fn)
    table.insert(Mock.timers, { at = Mock.now + delay, fn = fn })
end
function Mock.Advance(seconds)
    Mock.now = Mock.now + seconds
    local ran = true
    while ran do
        ran = false
        for i, t in ipairs(Mock.timers) do
            if t.at <= Mock.now then
                table.remove(Mock.timers, i)
                t.fn()
                ran = true
                break
            end
        end
    end
end

function UnitName() return "Tester" end
function UnitClass() return "Mage", "MAGE" end
function GetNormalizedRealmName() return "Realm" end

C_Item = {}
function C_Item.GetItemInfoInstant(itemID)
    return itemID, "type", "subtype", "", 134400, Mock.itemClass[itemID] or 0, 0
end
-- Counts from Mock.bags: 0-5 are bags, 6-11 the character bank, 12-16 the warband bank.
function C_Item.GetItemCount(itemID, includeBank, _, includeReagentBank, includeAccountBank)
    local total = 0
    for bag, b in pairs(Mock.bags) do
        local inScope = bag <= 5
            or (bag <= 11 and includeBank)
            or (bag >= 12 and includeAccountBank)
        if inScope then
            for _, item in pairs(b.items) do
                if item[1] == itemID then
                    total = total + item[2]
                end
            end
        end
    end
    return total
end
function C_Item.GetItemInfo(itemID)
    return "Item" .. itemID, "|cffffffff|Hitem:" .. itemID .. "|h[Item" .. itemID .. "]|h|r"
end

C_Container = {}
function C_Container.GetContainerNumSlots(bag)
    return Mock.bags[bag] and Mock.bags[bag].slots or 0
end
function C_Container.GetContainerItemInfo(bag, slot)
    local b = Mock.bags[bag]
    local item = b and b.items[slot]
    if not item then return nil end
    return { itemID = item[1], stackCount = item[2], hyperlink = "|cffffffff|Hitem:" .. item[1] .. "|h[Item" .. item[1] .. "]|h|r" }
end

C_Bank = {}
function C_Bank.FetchPurchasedBankTabData(bankType)
    return Mock.tabData[bankType] or {}
end
function C_Bank.CanViewBank() return true end
function C_Bank.FetchDepositedMoney() return Mock.money end

-- Test helpers ---------------------------------------------------------------

function Mock.SetTab(bankType, index, bag, name)
    Mock.tabData[bankType] = Mock.tabData[bankType] or {}
    Mock.tabData[bankType][index] = { ID = bag, name = name, bankType = bankType }
    Mock.bags[bag] = Mock.bags[bag] or { slots = 98, items = {} }
end

function Mock.Put(bag, slot, itemID, count)
    Mock.bags[bag].items[slot] = itemID and { itemID, count } or nil
end

function Mock.ChangeBags(...)
    for _, bag in ipairs({ ... }) do
        Mock.Fire("BAG_UPDATE", bag)
    end
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.Advance(0.5)
end

function Mock.LoadAddon(dir, ns)
    for _, file in ipairs({ "Core.lua", "Diff.lua", "Scanner.lua", "Crafting.lua" }) do
        local chunk = assert(loadfile(dir .. "/" .. file))
        chunk("WowBankAudit", ns)
    end
end
