# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the DLL's byte patterns against an exe (multiplayer MP-0).

Static only: reads files, never runs or modifies anything.

    python tools/mp/plb_check.py <vanilla exe>                  # every pattern resolves, unique?
    python tools/mp/plb_check.py <vanilla exe> <patched exe>    # + PLB's changed ranges vs our patterns

The patched exe is a COPY patched outside the game folder (Party Limit
Begone's multiplayer patch; docs/design/multiplayer.md). With two files it
lists every changed byte range, and for each DLL pattern: resolves in both?
unique? overlaps a change? The DLL runs the same check at startup
(SelfCheck.cpp, SELFCHECK lines in native.log).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "tools", "native", "src")
HEX = re.compile(r"^(?:(?:[0-9A-Fa-f]{2}|\?\?)\s+){3,}(?:[0-9A-Fa-f]{2}|\?\?)$")


def patterns():
    """(file, name, pattern) for every IDA-style pattern literal in the DLL source."""
    out = []
    for dirpath, _, files in os.walk(SRC):
        for fn in files:
            if not fn.endswith((".cpp", ".h")):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8", errors="replace").read()
            # constexpr ... kName = "..." "..." ;  (adjacent literals joined)
            for m in re.finditer(r"(k\w+)\s*=\s*((?:\"[^\"\n]*\"\s*)+);", text):
                lit = "".join(re.findall(r"\"([^\"\n]*)\"", m.group(2))).strip()
                if HEX.match(lit):
                    out.append((os.path.relpath(path, SRC), m.group(1), lit))
            # literal passed straight to Find(...)
            for m in re.finditer(r"Find\([^,]+,\s*\"([^\"]+)\"", text):
                lit = m.group(1).strip()
                if HEX.match(lit):
                    out.append((os.path.relpath(path, SRC), "(inline)", lit))
    return out


def compile_pat(p):
    toks = p.split()
    return [None if t == "??" else int(t, 16) for t in toks]


def text_section(data):
    e = int.from_bytes(data[0x3C:0x40], "little")
    nsec = int.from_bytes(data[e + 6:e + 8], "little")
    opt = int.from_bytes(data[e + 20:e + 22], "little")
    sec = e + 24 + opt
    for i in range(nsec):
        s = sec + i * 40
        name = data[s:s + 8].rstrip(b"\0")
        va, vsz = int.from_bytes(data[s + 12:s + 16], "little"), int.from_bytes(data[s + 8:s + 12], "little")
        raw, rsz = int.from_bytes(data[s + 20:s + 24], "little"), int.from_bytes(data[s + 16:s + 20], "little")
        if name == b".text":
            return va, raw, min(rsz, vsz)
    raise SystemExit("no .text section")


def find_all(code, pat, limit=3):
    anchor = next(i for i, b in enumerate(pat) if b is not None)
    hits, pos = [], 0
    first = bytes([pat[anchor]])
    while len(hits) < limit:
        i = code.find(first, pos + anchor)
        if i < 0:
            break
        start = i - anchor
        if start >= 0 and start + len(pat) <= len(code) and all(b is None or code[start + j] == b for j, b in enumerate(pat)):
            hits.append(start)
        pos = start + 1
    return hits


def changed_ranges(a, b):
    n = min(len(a), len(b))
    out, i = [], 0
    while i < n:
        if a[i] != b[i]:
            j = i
            while j < n and a[j] != b[j]:
                j += 1
            out.append((i, j - i))
            i = j
        else:
            i += 1
    if len(a) != len(b):
        out.append((n, abs(len(a) - len(b))))
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    van = open(sys.argv[1], "rb").read()
    pat = open(sys.argv[2], "rb").read() if len(sys.argv) > 2 else None
    va, raw, size = text_section(van)
    code = van[raw:raw + size]
    pcode = None
    if pat:
        pva, praw, psize = text_section(pat)
        pcode = pat[praw:praw + psize]
    changes = []
    if pat:
        for off, ln in changed_ranges(van, pat):
            rva = va + (off - raw) if raw <= off < raw + size else None
            changes.append((off, ln, rva))
        print(f"{len(changes)} changed range(s) between the files:")
        for off, ln, rva in changes:
            where = f"code rva 0x{rva:X}" if rva is not None else "outside .text"
            print(f"  file 0x{off:X} +{ln}: {where}: {van[off:off + min(ln, 16)].hex(' ')} -> {pat[off:off + min(ln, 16)].hex(' ')}")
    pats = patterns()
    bad = 0
    print(f"\n{len(pats)} DLL pattern(s):")
    for f, name, p in pats:
        cp = compile_pat(p)
        hv = find_all(code, cp)
        line = f"  {f}:{name}: vanilla {len(hv)} hit(s)" + (f" at rva 0x{va + hv[0]:X}" if hv else "")
        ok = len(hv) == 1
        if pat:
            hp = find_all(pcode, cp)
            line += f", patched {len(hp)} hit(s)"
            ok = ok and len(hp) == 1
            if hv:
                s0, s1 = raw + hv[0], raw + hv[0] + len(cp)
                hit = [c for c in changes if c[0] < s1 and s0 < c[0] + c[1]]
                if hit:
                    ok = False
                    line += f", OVERLAPS {len(hit)} change(s)"
        if not ok:
            bad += 1
            line += "  <-- CHECK"
        print(line)
    print(f"\n{len(pats) - bad} of {len(pats)} pattern(s) OK" + (" (resolve once in both files, no overlap)" if pat else " (resolve once)"))


if __name__ == "__main__":
    main()
