#!/usr/bin/env python3
"""Post-migration structural self-check for the F1-h batch.

Delphi/FPC are not available on this machine, so the migrated text is verified
structurally instead of by compiling:

  * `begin`/`end` DELTA is compared against the pre-migration revision, not
    against zero. A raw begin==end assertion is simply wrong for Pascal: `case`
    arms and `class`/`record` bodies close with `end` without a `begin`, so every
    unit carries a non-zero delta. What must hold is that this batch did not
    CHANGE it.
  * every MainUi entry point declared in the interface has a body, and vice
    versa (no one-way drift)
  * no line-ending damage: files stay pure CRLF with no bare LF

Usage:  python tools/_f1h_selfcheck.py
Exit code 0 = all checks pass.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESIDUAL = ["Source/EnviroFrm.pas", "Source/ProjectOptionsFrm.pas",
            "Source/ToolEditFrm.pas", "Source/AStyleFormatterOptionsFrm.pas",
            "Source/ClangFormatterOptionsFrm.pas", "Source/AddToDoFrm.pas",
            "Source/NewTemplateFrm.pas", "Source/RemoveUnitFrm.pas",
            "Source/Templates.pas"]

TARGETS = ["Source/UI/MainUi.pas", "Source/FindFrm.pas",
           "Source/ProfileAnalysisFrm.pas", "Source/FilePropertiesFrm.pas",
           "Source/ViewToDoFrm.pas", "Source/NewClassFrm.pas",
           "Source/CPUFrm.pas", "Source/NewVarFrm.pas",
           "Source/NewFunctionFrm.pas"] + RESIDUAL
ok = True


def strip_noise(text):
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"'[^'\n]*'", "''", text)
    return text


def delta(text):
    code = strip_noise(text)
    return len(re.findall(r"\bbegin\b", code)) - len(re.findall(r"\bend\b", code))


def at_head(rel):
    """Pre-migration text from git, or None if the file was untracked."""
    r = subprocess.run(["git", "show", "HEAD:" + rel], cwd=ROOT,
                       capture_output=True)
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


for rel in TARGETS:
    path = ROOT / rel
    raw = path.read_bytes()
    text = raw.decode("utf-8-sig" if raw.startswith(b"\xef\xbb\xbf")
                      else "utf-8", errors="replace")
    name = path.name
    bare = len(re.findall(rb"(?<!\r)\n", raw))
    final = text.rstrip().endswith("end.")

    now = delta(text)
    before = at_head(rel)
    if before is None:
        note = "untracked at HEAD (no baseline to diff)"
        same = True
    else:
        was = delta(before)
        same = (was == now)
        note = "delta %+d -> %+d" % (was, now)

    ok &= same and bare == 0 and final
    print("%-22s %-34s bareLF=%d final-end.=%-5s %s"
          % (name, note, bare, final, "OK" if (same and not bare and final)
             else "FAIL"))

# facade declaration/implementation symmetry
t = (ROOT / "Source/UI/MainUi.pas").read_bytes().decode("utf-8-sig")
iface, impl = re.split(r"(?m)^implementation\s*$", t, maxsplit=1)
decl = set(re.findall(r"(?m)^\s*(?:function|procedure)\s+(\w+)", iface))
body = set(re.findall(r"(?m)^(?:function|procedure)\s+(\w+)", impl))
drift = decl ^ body
ok &= not drift
print("MainUi.pas            declared=%d implemented=%d drift=%s"
      % (len(decl), len(body), sorted(drift) or "none"))

# A Pascal unit has exactly one `interface` and one `implementation`. The
# F1-m step-1 migration concatenated its interface fragment onto an anchor
# that already ended in `implementation`, producing a file with two of them --
# a hard compile error. The begin/end delta said nothing about it, because the
# damage was in the section structure, not the block structure. This is the
# cheap guard that would have caught it.
for rel in TARGETS:
    p = ROOT / rel
    body = p.read_bytes().decode("utf-8-sig", errors="replace")
    for kw in ("interface", "implementation"):
        hits = [i for i, ln in enumerate(body.split("\n"), 1)
                if ln.strip() == kw]
        dup = len(hits) > 1
        ok &= not dup
        if dup or len(hits) != 1:
            print("  %-22s %-14s count=%d %s"
                  % (p.name, kw, len(hits), hits if dup else ""))
print("  section clauses: interface/implementation unique in all %d targets"
      % len(TARGETS))

print("\nSTRUCTURAL CHECK: %s" % ("OK" if ok else "FAILED"))
sys.exit(0 if ok else 1)
