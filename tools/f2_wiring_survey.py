#!/usr/bin/env python3
"""Measure what the four LSP client units actually need from the editor.

Two facts here reshape the wiring plan, and both were found by reading the
call sites rather than by counting type references:

  1. `InitializeLsp*` has ZERO external callers. The four entry points are
     declared and implemented in their own units and never invoked from
     anywhere. Wiring is therefore not "someone has to start passing an
     adapter" -- there is no existing call site to change. Whoever wires this
     also decides WHO creates the adapter and WHEN, which is a design decision
     the contract does not answer.

  2. `Editor.pas` holds the live references (`LspHoverManager.SetEditor(fText)`
     at :1604, `LspHoverManager.EditorDestroyed(fText)` at :602), so the
     TCustomSynEdit objects do reach the managers at runtime -- through
     Editor.pas, not through InitializeLsp*.

  3. `Definition.pas:466` is dead defence code:
         if TMethod(FOnNoResult).Data = Pointer(AEditor) then
     FOnNoResult is this manager's OWN method (invoked as FOnNoResult(Self) at
     :646), so its TMethod.Data is the manager, never the editor. The
     comparison can never be true. It compiles today only because AEditor is a
     pointer-sized object reference. Under an interface adapter this line has
     no meaning at all and must be redesigned rather than translated.

Run:  python tools/f2_wiring_survey.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = ROOT / "Source" / "LSP" / "Client"


def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def main():
    units = {
        "Definition": list(CLIENT.rglob("Lsp.Client.Definition.pas"))[0],
        "Hover": list(CLIENT.rglob("Lsp.Client.Hover.pas"))[0],
        "SignatureHelp": list(CLIENT.rglob("Lsp.Client.SignatureHelp.pas"))[0],
        "Completion": list(CLIENT.rglob("Lsp.Client.Completion.pas"))[0],
    }

    print("== per-unit FEditor usage ==")
    for name, p in sorted(units.items()):
        t = read(p)
        uses = []
        for i, line in enumerate(t.splitlines(), 1):
            if "FEditor" in line:
                uses.append((i, line.strip()[:78]))
        print("\n  %-14s %d use(s)" % (name, len(uses)))
        for i, l in uses:
            print("      %5d: %s" % (i, l))

    print("\n\n== external callers of InitializeLsp* / Manager.Create ==")
    found = False
    for p in sorted(ROOT.rglob("*.pas")):
        if "VCL" in p.parts or "Archive" in p.parts:
            continue
        if p.parent == CLIENT:
            continue
        t = p.read_bytes().decode("latin-1", errors="replace")
        for m in re.finditer(r"(?i)\bInitializeLsp\w+\s*\(", t):
            ln = t[:m.start()].count("\n") + 1
            print("  %-24s %5d: %s" % (p.name, ln, m.group(0)))
            found = True
    if not found:
        print("  (NONE -- the four entry points have no callers anywhere)")

    print("\n== live references held OUTSIDE the client layer ==")
    for p in sorted(ROOT.rglob("*.pas")):
        if "VCL" in p.parts or p.parent == CLIENT:
            continue
        t = p.read_bytes().decode("latin-1", errors="replace")
        for m in re.finditer(r"(?i)\bLsp\w*Manager\s*\.\s*\w+", t):
            ln = t[:m.start()].count("\n") + 1
            print("  %-20s %5d: %s"
                  % (p.name, ln, m.group(0)[:56]))

    print("\n== the dead defence line ==")
    d = read(units["Definition"])
    for i, line in enumerate(d.splitlines(), 1):
        if "TMethod(FOnNoResult)" in line:
            print("  Definition.pas:%d  %s" % (i, line.strip()))
            print("    FOnNoResult is invoked at :646 as FOnNoResult(Self), so its")
            print("    TMethod.Data is the MANAGER. Comparing it to the editor can")
            print("    never be true -- this branch has never fired.")

    print("\n== an AV hazard noticed in passing (NOT fixed here) ==")
    e = (ROOT / "Source" / "Editor.pas").read_bytes().decode("latin-1")
    lines = e.splitlines()
    for i in range(1546, 1570):
        if i < len(lines) and "LspDefinitionManager" in lines[i]:
            print("  Editor.pas:%d: %s" % (i + 1, lines[i].strip()[:80]))
    print("  (Assigned is only checked at :1565; recorded, not touched --")
    print("   it predates this migration and is out of scope.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
