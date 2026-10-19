"""Runs the addon's Lua tests under Lua 5.1 (the WoW client's dialect).

Requires: pip install lupa
Usage:    python3 tests/run_tests.py
"""
import os
import sys

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON_DIR = os.path.join(ROOT, "WowBankAudit")


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)

    # Syntax-check every addon file, including UI code that needs the real client.
    compile_errors = 0
    for name in sorted(os.listdir(ADDON_DIR)):
        if name.endswith(".lua"):
            result = lua.globals().loadfile(os.path.join(ADDON_DIR, name))
            if isinstance(result, tuple) and result[0] is None:
                err = result[1]
                print("SYNTAX", err)
                compile_errors += 1

    chunk = lua.globals().loadfile(os.path.join(ROOT, "tests", "tests.lua"))
    if isinstance(chunk, tuple):
        print(chunk[1])
        return 1
    failures = chunk(ADDON_DIR)
    return 1 if (failures or compile_errors) else 0


if __name__ == "__main__":
    sys.exit(main())
