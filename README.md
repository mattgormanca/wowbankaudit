# Bank Audit (WowBankAudit)

A World of Warcraft (Retail) addon that keeps an audit log of **gold** and **trade goods**
deposited to and withdrawn from your **Bank** and **Warband Bank**. Each bank is tracked and
shown separately, and every entry records which tab it touched.

## Features

- **Separate Bank and Warband Bank views.** Each has its own tab at the bottom of the window.
- **Per-tab auditing.** Every entry records the tab (by name), and you can filter to a single tab.
- **Gold tracking** for the Warband Bank (the character bank cannot hold gold in Retail).
- **Transfers are recognised.** Moving a stack from one tab to another, or from your Bank to the
  Warband Bank, is logged as one transfer instead of a withdrawal plus a deposit. In the Warband
  Bank view a transfer from your Bank shows as "Transfer in"; in the Bank view it shows as
  "Transfer out".
- **Who did it.** Every entry records the character, so you can see which alt took what from the
  shared Warband Bank. Filter by character.
- **Crafting from the bank is attributed.** When a profession pulls reagents straight from your
  Bank or Warband Bank, the entry shows as "Crafting" under the character that crafted, not as an
  unrecorded change. Filter with *Used for crafting*.
- **Unrecorded change detection.** When a bank is opened it is compared with the last contents the
  addon saw. Differences (another PC, a character without the addon, the addon disabled) are
  logged and marked with `*`.
- **Log and Summary views.** Summary totals in / out / net per item (and gold) for the current
  filters - e.g. "how much Bismuth went into the Ore tab this month".
- **Search** by item or character name, filter by activity type.
- **CSV export** of the current view.
- Hover a row for the item tooltip and details; shift-click to link the item in chat.

By default only items in the *Trade Goods* category (plus items the game flags as crafting
reagents) are recorded. Turn on **Track all items** in the options to record everything.

## Installation

1. Download this repository.
2. Copy the `WowBankAudit` folder into `World of Warcraft/_retail_/Interface/AddOns/`
   so that the path is `.../Interface/AddOns/WowBankAudit/WowBankAudit.toc`.
3. Restart the game or `/reload`.

## Usage

Visit a banker once on each character to take a baseline - the first visit records the current
contents without logging anything. From then on, every change is logged.

| Command | Action |
| --- | --- |
| `/bankaudit` or `/baudit` | Toggle the audit window |
| `/bankaudit options` | Open settings |
| `/bankaudit export` | Export the current view as CSV |
| `/bankaudit purge <days>` | Delete entries older than `<days>` |
| `/bankaudit clear` | Delete the whole log |
| `/bankaudit reset` | Forget stored bank contents (re-baseline next visit) |
| `/bankaudit status` | Show what's being tracked |

The addon also appears in the addon compartment (the button by the minimap): left-click opens the
window, right-click opens settings.

## How it works

The addon only ever reads bank contents while you're at the bank. It snapshots every purchased tab
of both banks (`C_Bank.FetchPurchasedBankTabData`, `C_Container`) and the Warband Bank gold
(`C_Bank.FetchDepositedMoney`). When a bank tab changes (`BAG_UPDATE`) or the Warband gold changes
(`ACCOUNT_MONEY`), it takes a new snapshot, diffs it against the previous one and writes entries
for the differences. Item losses and gains in the same scan are paired up as transfers.

Professions can use reagents from both banks without visiting a banker. While a profession window
is open, the addon watches the bank share of each stored item's count (`C_Item.GetItemCount` with
the bank flags) and logs any drop as crafting use by the current character, taking it out of the
stored snapshot so the next bank visit doesn't report it again.

Data is stored account-wide in `WTF/Account/<account>/SavedVariables/WowBankAudit.lua`, so the
shared Warband Bank snapshot and log are the same on every character. Character bank snapshots are
kept per character.

### Limitations

- Bank contents are only visible to addons while the bank is open, so changes made on another PC or
  by a character without the addon can only be detected - not attributed - the next time a
  character with the addon opens the bank (these are the `*` entries).
- Changes made in the first ~1.5 seconds after opening the bank, while contents are still loading,
  are also logged as unrecorded.
- The client doesn't say which tab crafting reagents came from, so they are taken from the tabs
  holding the item in tab order. If the game used a different tab, the next bank visit shows the
  difference as an unrecorded move.
- Crafting is only attributed for items in a stored snapshot, so visit a banker once first.
- Guild banks are not tracked.

## Development

The diffing, logging and event handling are covered by tests that run outside the game against a
mocked client API, using Lua 5.1 (the WoW Lua dialect) via `lupa`:

```sh
pip install lupa
python3 tests/run_tests.py
```
