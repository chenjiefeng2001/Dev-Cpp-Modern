#!/usr/bin/env python3
"""One-off structural sanity checks for the Phase-F / F0 FPC artifacts.

Not part of the permanent QA gate: it approximates what `lazbuild` will do
without a Lazarus installation. The authoritative check is the CI job in
.github/workflows/fpc_ci.yml.
"""
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LPR = ROOT / "Tests" / "FpcCoreTests" / "FpcCoreTests.lpr"
fail = 0


def check(cond, msg):
    global fail
    print(("  [PASS] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fail += 1


src = LPR.read_text(encoding="utf-8")

# 1. ASCII only (Lazarus/FPC side files stay ASCII so the Delphi-side
#    encoding gate and the FPC side never disagree about the file).
check(all(ord(c) < 128 for c in src), "FpcCoreTests.lpr is pure ASCII")

# 2. Crude begin/end balance with comments and string literals removed.
#    `class`/`record`/`case` and `try` also close with `end`, so count them.
s = re.sub(r"//[^\n]*", "", src)
s = re.sub(r"'[^'\n]*'", "''", s)
words = re.findall(r"\b[A-Za-z_]+\b", s)
b = sum(1 for w in words if w.lower() == "begin")
e = sum(1 for w in words if w.lower() == "end")
kinds = sum(1 for w in words
            if w.lower() in ("class", "record", "case", "object", "try"))
check(b + kinds == e,
      "begin/end balanced (%d begin + %d class/record/case/try = %d end)"
      % (b, kinds, e))

# 3. Conditional compilation blocks are closed.
ifdef = len(re.findall(r"\{\$IF", src, re.I))
endif = len(re.findall(r"\{\$ENDIF", src, re.I))
check(ifdef == endif, "{$IF*} / {$ENDIF} balanced (%d/%d)" % (ifdef, endif))
check(src.rstrip().endswith("end."), "program ends with 'end.'")

# 4. The runner must not drag VCL/LCL in: only portable units are used.
uses_block = src.split("uses", 1)[1].split(";", 1)[0]
banned = [u for u in ("Vcl", "Forms", "Controls", "SynEdit", "Windows", "LCL")
          if re.search(r"\b%s\b" % u, uses_block)]
check(not banned, "portable runner uses no VCL/LCL/Win32 units")

# 5. Every unit referenced by the .lpi files must exist, and the portable
#    project must carry the Phase-F portable set (headless FPC coverage).
PORTABLE_SET = ("Core/Core.Events.pas", "Core/Core.Services.pas",
                "Debugger/GDB/GDB.MiTypes.pas", "Debugger/GDB/GDB.MiParser.pas",
                "LSP/JsonRpc/Lsp.JsonRpc.pas",
                "LSP/Process/Lsp.Process.pas",
                "LSP/Process/Lsp.Process.Fpc.pas",
                "LSP/Process/Lsp.Process.Factory.pas",
                "LSP/Transport/Lsp.Transport.pas")
# Windows-only implementation: must never enter an FPC project.
WIN32_ONLY = ("LSP/Process/Lsp.Process.Win32.pas",)
for lpi in ("FpcCorePortable.lpi", "FpcCoreWin.lpi"):
    p = ROOT / "Tests" / "FpcCoreTests" / lpi
    root = ET.parse(str(p)).getroot()
    units = []
    for u in root.iter():
        if not re.fullmatch(r"Unit\d+", u.tag):
            continue
        fn = u.find("Filename")
        if fn is not None and fn.get("Value"):
            units.append(fn.get("Value").replace("\\", "/"))
    missing = [u for u in units if not (p.parent / u).resolve().exists()]
    check(not missing, "%s: all %d unit files exist" % (lpi, len(units)))
    # .lpi entries are project-relative (../../Source/...); compare the
    # part after "Source/" against the canonical portable set.
    normalized = [u.split("Source/", 1)[-1] for u in units if "Source/" in u]
    absent = [u for u in PORTABLE_SET if u not in normalized]
    check(not absent, "%s: carries the portable Phase-F unit set (%s)"
          % (lpi, ", ".join(absent) or "complete"))
    leaked = [u for u in WIN32_ONLY if u in normalized]
    check(not leaked, "%s: excludes Windows-only units (%s)"
          % (lpi, ", ".join(leaked) or "clean"))

# 6. Units shared with the FPC build must stay free of Win32/VCL imports.
for rel in PORTABLE_SET:
    text = (ROOT / "Source" / rel).read_text(encoding="utf-8-sig")
    head = text.split("implementation", 1)[0]
    bad = [u for u in ("Vcl.", "Winapi.", "Windows,", "Forms", "LCL", "SynEdit")
           if re.search(re.escape(u) if not u.endswith(",") else r"\b%s" % u,
                        head)]
    check(not bad, "%s stays UI-free (%s)" % (rel, ", ".join(bad) or "ok"))

if __name__ == "__main__":
    if "--debug" in sys.argv:
        out = []
        for i, ln in enumerate(src.splitlines(), 1):
            t = re.sub(r"//.*$", "", ln)
            t = re.sub(r"'[^']*'", "''", t)
            if re.search(r"\bend\b", t, re.I):
                out.append("%4d: %s" % (i, ln.strip()))
        with open(os.path.join(tempfile.gettempdir(), "fpc_end_debug.txt"),
                  "w", encoding="utf-8") as fh:
            fh.write("\n".join(out))
    print("F0 artifact check: %s" % ("OK" if fail == 0 else "%d error(s)" % fail))
    sys.exit(1 if fail else 0)
else:
    print("F0 artifact check: %s" % ("OK" if fail == 0 else "%d error(s)" % fail))
    sys.exit(1 if fail else 0)
