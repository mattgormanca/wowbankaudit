-- Pure snapshot diffing. No WoW API calls so it can be unit tested outside the client.
local _, ns = ...

local Diff = {}
ns.Diff = Diff

-- Bank sort order used to make output deterministic and to prefer pairing
-- moves inside the same bank before pairing across banks.
local BANK_ORDER = { character = 1, warband = 2 }

local function SortLocations(a, b)
    local ba, bb = BANK_ORDER[a.bank] or 99, BANK_ORDER[b.bank] or 99
    if ba ~= bb then
        return ba < bb
    end
    return a.tab < b.tab
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- changes: array of { bank = "character"|"warband", tab = <index>, old = {[itemID] = count}, new = {[itemID] = count} }
-- Returns an array of movements:
--   { kind = "deposit",  itemID, count, bank, tab }                  -- came from outside the banks (bags, etc.)
--   { kind = "withdraw", itemID, count, bank, tab }                  -- left the banks
--   { kind = "move",     itemID, count, bank, tab, toBank, toTab }  -- moved between two bank tabs
function Diff.Compute(changes)
    local gains, losses = {}, {}

    for _, change in ipairs(changes) do
        local old, new = change.old or {}, change.new or {}
        local seen = {}
        for itemID in pairs(old) do
            seen[itemID] = true
        end
        for itemID in pairs(new) do
            seen[itemID] = true
        end
        for itemID in pairs(seen) do
            local delta = (new[itemID] or 0) - (old[itemID] or 0)
            if delta ~= 0 then
                local bucket = delta > 0 and gains or losses
                bucket[itemID] = bucket[itemID] or {}
                table.insert(bucket[itemID], { bank = change.bank, tab = change.tab, count = math.abs(delta) })
            end
        end
    end

    local results = {}

    for _, itemID in ipairs(SortedKeys(losses)) do
        local itemLosses = losses[itemID]
        local itemGains = gains[itemID]
        table.sort(itemLosses, SortLocations)
        if itemGains then
            table.sort(itemGains, SortLocations)
            for _, loss in ipairs(itemLosses) do
                -- Two passes: same bank first, then any bank.
                for pass = 1, 2 do
                    for _, gain in ipairs(itemGains) do
                        if loss.count == 0 then
                            break
                        end
                        if gain.count > 0 and (pass == 2 or gain.bank == loss.bank) then
                            local n = math.min(loss.count, gain.count)
                            table.insert(results, {
                                kind = "move",
                                itemID = itemID,
                                count = n,
                                bank = loss.bank,
                                tab = loss.tab,
                                toBank = gain.bank,
                                toTab = gain.tab,
                            })
                            loss.count = loss.count - n
                            gain.count = gain.count - n
                        end
                    end
                end
            end
        end
        for _, loss in ipairs(itemLosses) do
            if loss.count > 0 then
                table.insert(results, { kind = "withdraw", itemID = itemID, count = loss.count, bank = loss.bank, tab = loss.tab })
            end
        end
    end

    for _, itemID in ipairs(SortedKeys(gains)) do
        local itemGains = gains[itemID]
        table.sort(itemGains, SortLocations)
        for _, gain in ipairs(itemGains) do
            if gain.count > 0 then
                table.insert(results, { kind = "deposit", itemID = itemID, count = gain.count, bank = gain.bank, tab = gain.tab })
            end
        end
    end

    return results
end

-- Where an entry sits relative to a viewing scope (a bank, optionally narrowed to one tab).
-- Returns "in", "out", "internal", or nil when the entry does not touch the scope.
function Diff.Direction(entry, bank, tab)
    local function InScope(b, t)
        return b == bank and (tab == nil or t == tab)
    end

    local srcIn, dstIn
    if entry.kind == "deposit" then
        srcIn, dstIn = false, InScope(entry.bank, entry.tab)
    elseif entry.kind == "withdraw" then
        srcIn, dstIn = InScope(entry.bank, entry.tab), false
    else
        srcIn, dstIn = InScope(entry.bank, entry.tab), InScope(entry.toBank, entry.toTab)
    end

    if srcIn and dstIn then
        return "internal"
    elseif dstIn then
        return "in"
    elseif srcIn then
        return "out"
    end
    return nil
end
