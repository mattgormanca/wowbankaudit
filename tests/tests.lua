-- Run with: python3 tests/run_tests.py
local ADDON_DIR = ...

local tests, failures = {}, 0

local function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "value", tostring(expected), tostring(actual)), 2)
    end
end

-- Fresh addon + mock state per test.
local function Setup()
    dofile(ADDON_DIR .. "/../tests/mock_wow.lua")
    WowBankAuditDB = nil
    local ns = {}
    Mock.LoadAddon(ADDON_DIR, ns)
    Mock.Fire("ADDON_LOADED", "WowBankAudit")
    Mock.Fire("PLAYER_LOGIN")
    -- Character bank: two tabs. Warband: two tabs.
    Mock.SetTab(Enum.BankType.Character, 1, 6, "Mats")
    Mock.SetTab(Enum.BankType.Character, 2, 7, "Misc")
    Mock.SetTab(Enum.BankType.Account, 1, 12, "Herbs")
    Mock.SetTab(Enum.BankType.Account, 2, 13, "Ore")
    return ns
end

local function OpenBank()
    Mock.Fire("BANKFRAME_OPENED")
    Mock.Advance(2)
end

local function CloseBank()
    Mock.Fire("BANKFRAME_CLOSED")
end

local function Log(ns)
    return ns.db.log
end

--------------------------------------------------------------------------------

test("Diff pairs moves within a bank before crossing banks", function()
    local ns = {}
    assert(loadfile(ADDON_DIR .. "/Diff.lua"))("WowBankAudit", ns)
    local out = ns.Diff.Compute({
        { bank = "character", tab = 1, old = { [1] = 10 }, new = { [1] = 2 } },
        { bank = "character", tab = 2, old = {}, new = { [1] = 5 } },
        { bank = "warband", tab = 1, old = {}, new = { [1] = 5 } },
    })
    eq(#out, 3, "result count")
    eq(out[1].kind, "move"); eq(out[1].toBank, "character"); eq(out[1].count, 5)
    eq(out[2].kind, "move"); eq(out[2].toBank, "warband"); eq(out[2].count, 3)
    eq(out[3].kind, "deposit"); eq(out[3].bank, "warband"); eq(out[3].count, 2)
end)

test("Direction relative to bank and tab", function()
    local ns = {}
    assert(loadfile(ADDON_DIR .. "/Diff.lua"))("WowBankAudit", ns)
    local move = { kind = "move", bank = "character", tab = 1, toBank = "warband", toTab = 2 }
    eq(ns.Diff.Direction(move, "character"), "out")
    eq(ns.Diff.Direction(move, "warband"), "in")
    eq(ns.Diff.Direction(move, "warband", 1), nil)
    local internal = { kind = "move", bank = "warband", tab = 1, toBank = "warband", toTab = 2 }
    eq(ns.Diff.Direction(internal, "warband"), "internal")
    eq(ns.Diff.Direction(internal, "warband", 2), "in")
end)

test("first visit takes a baseline without logging", function()
    local ns = Setup()
    Mock.Put(6, 1, 1001, 20)
    Mock.Put(12, 1, 1002, 50)
    OpenBank()
    eq(#Log(ns), 0, "entries")
    eq(ns.db.characters["Tester-Realm"].tabs[1].items[1001], 20)
    eq(ns.db.warband.tabs[1].items[1002], 50)
end)

test("deposit and withdraw in the character bank", function()
    local ns = Setup()
    OpenBank()
    Mock.Put(6, 1, 1001, 20)
    Mock.ChangeBags(6)
    eq(#Log(ns), 1)
    local e = Log(ns)[1]
    eq(e.kind, "deposit"); eq(e.bank, "character"); eq(e.tab, 1); eq(e.tabName, "Mats"); eq(e.count, 20); eq(e.who, "Tester-Realm")
    Mock.Put(6, 1, 1001, 15)
    Mock.ChangeBags(6)
    eq(#Log(ns), 2)
    eq(Log(ns)[2].kind, "withdraw"); eq(Log(ns)[2].count, 5)
end)

test("non trade goods are ignored unless tracking all items", function()
    local ns = Setup()
    OpenBank()
    Mock.Put(12, 1, 2001, 1)
    Mock.ChangeBags(12)
    eq(#Log(ns), 0, "untracked")
    ns.db.settings.trackAllItems = true
    Mock.Put(12, 2, 2001, 1)
    Mock.ChangeBags(12)
    eq(#Log(ns), 1, "tracked")
end)

test("move from character bank to warband is one transfer", function()
    local ns = Setup()
    Mock.Put(6, 1, 1001, 20)
    OpenBank()
    Mock.Put(6, 1, nil)
    Mock.Put(13, 4, 1001, 20)
    Mock.ChangeBags(6, 13)
    eq(#Log(ns), 1)
    local e = Log(ns)[1]
    eq(e.kind, "move"); eq(e.bank, "character"); eq(e.tab, 1); eq(e.toBank, "warband"); eq(e.toTab, 2); eq(e.toTabName, "Ore")

    local warband = ns:QueryLog({ bank = "warband", kind = "deposit" })
    eq(#warband, 1, "shows as deposit in warband view"); eq(warband[1].dir, "in")
    local char = ns:QueryLog({ bank = "character", kind = "withdraw" })
    eq(#char, 1, "shows as withdraw in bank view"); eq(char[1].dir, "out")
    eq(#ns:QueryLog({ bank = "warband", tab = 1 }), 0, "other warband tab unaffected")
end)

test("warband gold deposits and withdrawals", function()
    local ns = Setup()
    Mock.money = 1000000
    OpenBank()
    eq(#Log(ns), 0, "baseline")
    Mock.money = 1500000
    Mock.Fire("ACCOUNT_MONEY")
    Mock.money = 1200000
    Mock.Fire("ACCOUNT_MONEY")
    eq(#Log(ns), 2)
    eq(Log(ns)[1].kind, "deposit"); eq(Log(ns)[1].money, 500000); eq(Log(ns)[1].bank, "warband")
    eq(Log(ns)[2].kind, "withdraw"); eq(Log(ns)[2].money, 300000)
    local summary = ns:Summarize(ns:QueryLog({ bank = "warband" }))
    eq(summary[1].isGold, true); eq(summary[1].inCount, 500000); eq(summary[1].outCount, 300000)
end)

test("changes while away are logged as unrecorded", function()
    local ns = Setup()
    Mock.Put(12, 1, 1002, 50)
    Mock.money = 100
    OpenBank()
    CloseBank()
    -- Someone else used the warband bank
    Mock.Put(12, 1, 1002, 30)
    Mock.money = 50
    -- Changes while closed must be ignored
    Mock.Fire("BAG_UPDATE", 12); Mock.Fire("BAG_UPDATE_DELAYED"); Mock.Fire("ACCOUNT_MONEY"); Mock.Advance(1)
    eq(#Log(ns), 0, "closed")
    OpenBank()
    eq(#Log(ns), 2, "reconciled")
    eq(Log(ns)[1].unrecorded, true); eq(Log(ns)[1].who, nil); eq(Log(ns)[1].count, 20); eq(Log(ns)[1].detectedBy, "Tester-Realm")
    eq(Log(ns)[2].money, 50); eq(Log(ns)[2].unrecorded, true)
    eq(#ns:QueryLog({ bank = "warband", kind = "unrecorded" }), 2)
end)

test("bag updates during the settle window are not double counted", function()
    local ns = Setup()
    Mock.Put(6, 1, 1001, 10)
    OpenBank()
    CloseBank()
    Mock.Fire("BANKFRAME_OPENED")
    -- contents still arriving
    Mock.Put(6, 2, 1003, 5)
    Mock.ChangeBags(6)
    Mock.Advance(2)
    eq(#Log(ns), 1)
    eq(Log(ns)[1].itemID, 1003); eq(Log(ns)[1].unrecorded, true)
end)

test("empty read while closing does not log a withdrawal", function()
    local ns = Setup()
    Mock.Put(12, 1, 1002, 50)
    OpenBank()
    Mock.Put(12, 1, nil)
    Mock.Fire("BAG_UPDATE", 12); Mock.Fire("BAG_UPDATE_DELAYED")
    CloseBank()
    Mock.Advance(1)
    eq(#Log(ns), 0)
end)

test("log is trimmed to maxEntries and purge works", function()
    local ns = Setup()
    ns.db.settings.maxEntries = 3
    for i = 1, 5 do
        ns:AddEntry({ kind = "deposit", bank = "warband", money = i, t = 1000 + i })
    end
    eq(#Log(ns), 3); eq(Log(ns)[1].money, 3)
    eq(ns:PurgeOlderThan(1), 3)
end)

test("search and character filters", function()
    local ns = Setup()
    ns:AddEntry({ kind = "deposit", bank = "warband", tab = 1, itemID = 1001, count = 1, who = "A-Realm", link = "[Iron Ore]" })
    ns:AddEntry({ kind = "deposit", bank = "warband", tab = 1, itemID = 1002, count = 1, who = "B-Realm", link = "[Peacebloom]" })
    eq(#ns:QueryLog({ bank = "warband", search = "ore" }), 1)
    eq(#ns:QueryLog({ bank = "warband", who = "B-Realm" }), 1)
    eq(#ns:QueryLog({ bank = "character" }), 0)
end)

--------------------------------------------------------------------------------

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        io.write("ok   ", t.name, "\n")
    else
        failures = failures + 1
        io.write("FAIL ", t.name, "\n     ", tostring(err), "\n")
    end
end
io.write(string.format("\n%d tests, %d failures\n", #tests, failures))
return failures
