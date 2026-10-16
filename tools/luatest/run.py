# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline Lua checks for the mod (no game needed).

1. Compiles every Lua file under the mod's ScriptExtender/Lua with Lua 5.4
   (the Script Extender's version), so a syntax error never reaches a playtest.
2. Runs the pure-logic self-tests with a small stand-in for the Script
   Extender's Ext table (tests.lua next to this file): the Meta-Points curves
   against the signed-off table, the config merge, cooldown / swing rate.

Needs Python 3 and lupa (pip install lupa). Run through scripts/test-lua.ps1.
Exit code 0 = everything passed.
"""
import pathlib
import sys

try:
    from lupa import lua54
except ImportError:
    print("lupa is not installed: pip install lupa")
    sys.exit(2)

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
LUA_ROOT = REPO / "mod" / "DarkAndGate" / "Mods" / "DarkAndGate" / "ScriptExtender" / "Lua"


def read(p):
    s = p.read_bytes().decode("utf-8", errors="replace")
    return s[1:] if s.startswith("﻿") else s


def compile_all(rt):
    check = rt.eval("function(src, name) local f, err = load(src, '=' .. name, 't') return f ~= nil, err end")
    bad = 0
    files = sorted(LUA_ROOT.rglob("*.lua"))
    for p in files:
        ok, err = check(read(p), str(p.relative_to(LUA_ROOT)))
        if not ok:
            bad += 1
            print("SYNTAX", err)
    print(f"compile: {len(files)} files, {bad} with syntax errors")
    return bad == 0


def run_tests(rt):
    # Ext.Require(path) loads a mod file (cached, like SE).
    loader = rt.eval("""
        function(readfile)
            local cache = {}
            return function(path)
                if cache[path] ~= nil then return cache[path] end
                local src = readfile(path)
                if not src then error("no such mod file: " .. path) end
                local f, err = load(src, "=" .. path, "t")
                if not f then error(err) end
                local v = f()
                cache[path] = v == nil and true or v
                return cache[path]
            end
        end""")

    def readfile(path):
        p = LUA_ROOT / path
        return read(p) if p.is_file() else None

    require = loader(readfile)
    tests = rt.execute(read(HERE / "tests.lua"))
    ok, report = tests(require)
    for line in str(report).splitlines():
        print(line)
    return bool(ok)


def main():
    rt = lua54.LuaRuntime(unpack_returned_tuples=True)
    ok = compile_all(rt)
    if ok:
        ok = run_tests(rt) and ok
    print("ALL PASSED" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
