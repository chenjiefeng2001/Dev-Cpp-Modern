#!/usr/bin/env python3
"""Verify the F2 editor contract is actually toolkit-free, and actually covers.

Two failure modes are checked, both of which are invisible in review:

  A. LEAK -- a VCL/LCL symbol creeps into the contract's interface section
     (TPoint, TRect, TColor, TNotifyEvent, TBufferCoord, ...). One slip and the
     contract is no longer implementable under LCL, which is the ONLY reason
     it exists. This is checked mechanically because "no VCL types" is a
     property of the file over time, not a fact about today's text.

  B. UNDER-COVERAGE -- a member the client layer actually calls has no home in
     the contract. Cross-checked against tools/lsp_editor_deps.py's inventory,
     so the contract cannot quietly fall behind the code it was derived from.

Deliberately NOT checked: whether the contract is "complete" in some absolute
sense. It is complete relative to today's call sites, which is the only
completeness that can be established without a running IDE.

Usage:
    python tools/f2_contract_check.py
    python tools/f2_contract_check.py --verbose
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT_DIR = ROOT / "Source" / "LSP" / "Editor"
TYPES_UNIT = CONTRACT_DIR / "Lsp.Editor.Types.pas"
IFACE_UNIT = CONTRACT_DIR / "Lsp.Editor.Interfaces.pas"

sys.path.insert(0, str(ROOT / "tools"))
import lsp_editor_deps  # noqa: E402

# Toolkit symbols that must never appear in the contract. Each is VCL today;
# the whole point is that an LCL implementation must not need them.
VCL_LEAKS = (
    "TPoint", "TRect", "TColor", "TNotifyEvent", "TBufferCoord",
    "TDisplayCoord", "TSynEdit", "TSynEditMarker", "TCustomSynEdit",
    "TMarker", "TWndMethod", "TScreen", "clRed", "clYellow", "msBar",
)

# Members -> the contract member that absorbs them. This is the A-side of the
# audit: if the client layer calls Markers, something here must accept it.
COVERAGE = {
    "Lines": "GetTotalLines / GetLineText / GetAllText",
    # `GetAllText` appears as its own entry once a unit is actually migrated:
    # Definition.pas:557 replaced `FEditor.Lines.Text` with it. The linter
    # sees the CONTRACT's member name, not the SynEdit member it replaced, so
    # without this entry a correct migration reports FAIL -- which is the
    # failure mode that teaches people to ignore the check.
    "GetAllText": "GetAllText",
    "LineText": "GetLineText",
    "CaretX": "GetCaretPosition",
    "CaretY": "GetCaretPosition",
    "CaretXY": "ReplaceRange",
    "BlockBegin": "ReplaceRange",
    "BlockEnd": "ReplaceRange",
    "SelText": "ReplaceRange",
    "BeginUndoBlock": "ReplaceRange",
    "EndUndoBlock": "ReplaceRange",
    "Markers": "IEditorMarkerList",
    "MarkersChanged": "SetOnMarkersChanged",
    "ClientToScreen": "BufferToScreenPixels / CaretToScreenPixels",
    "RowColumnToPixels": "BufferToScreenPixels / CaretToScreenPixels",
    "BufferToDisplayPos": "BufferToScreenPixels",
    "ScreenToClient": "ScreenPixelsToBuffer",
    "PixelsToRowColumn": "ScreenPixelsToBuffer",
    "DisplayToBufferPos": "ScreenPixelsToBuffer",
    "DisplayXY": "CaretToScreenPixels",
    "LineHeight": "GetLineHeight",
    "ClientWidth": "GetClientWidth",
    "ClientHeight": "GetClientHeight",
}


def interface_section(text):
    """Interface part only: the implementation section is ours, not the
    contract's, and VCL names there would not leak to consumers."""
    m = re.search(r"(?mi)^\s*interface\s*$", text)
    if not m:
        return text
    impl = re.search(r"(?mi)^\s*implementation\s*$", text[m.end():])
    return text[m.end(): m.end() + impl.start()] if impl else text[m.end():]


def strip_comments(text):
    text = re.sub(r"\{[^}]*\}", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


# Members the contract itself defines. Once a unit is migrated the code stops
# naming the SynEdit member and starts naming the contract member, so the
# inventory below -- which is derived from the SOURCE -- produces contract names
# the mapping table has never heard of.
#
# This happened twice in a row (GetAllText after Definition, then five geometry
# members after Hover), which is the definition of a rule rather than a
# one-off: any contract member that a migrated unit now calls is self-evidently
# covered, because it IS the contract. So instead of adding a row per symptom,
# the whole contract surface is accepted as mapped, and the check keeps its
# teeth for the case it exists for -- a SynEdit member with no contract home.
CONTRACT_MEMBERS = {
    "GetLineText", "GetTotalLines", "GetAllText", "GetCaretPosition",
    "ReplaceRange", "BufferToScreenPixels", "CaretToScreenPixels",
    "ScreenPixelsToBuffer", "GetLineHeight", "GetClientWidth",
    "GetClientHeight", "GetMarkers", "SetOnMarkersChanged",
    "GetCount", "Add", "Delete", "Clear",
    "MakePixelPoint", "MakeHintPoint",
}


def mapped(name):
    if name in COVERAGE:
        return COVERAGE[name]
    if name in CONTRACT_MEMBERS:
        return "(contract member)"
    return None


def main(argv):
    verbose = "--verbose" in argv
    ok = True

    print("== A. toolkit leaks in the contract's interface section ==")
    for unit in (TYPES_UNIT, IFACE_UNIT):
        if not unit.exists():
            print("  FAIL missing unit: %s" % unit.relative_to(ROOT).as_posix())
            ok = False
            continue
        raw = unit.read_bytes()
        text = strip_comments(interface_section(
            raw.decode("utf-8-sig", errors="replace")))
        hits = []
        for sym in VCL_LEAKS:
            for m in re.finditer(r"\b%s\b" % re.escape(sym), text):
                line = text[:m.start()].count("\n") + 1
                hits.append("%s@iface+%d" % (sym, line))
        name = unit.name
        if hits:
            ok = False
            print("  FAIL %-28s leaks: %s" % (name, ", ".join(hits)))
        else:
            print("  OK   %-28s clean (BOM=%s, %s)"
                  % (name, raw[:3] == b"\xef\xbb\xbf",
                     "CRLF" if b"\r\n" in raw else "LF"))

    print("\n== B. every measured member has a home in the contract ==")
    members, sites, types, per_unit = lsp_editor_deps.scan()
    contract = IFACE_UNIT.read_text(encoding="utf-8", errors="replace")
    contract_names = set(re.findall(r"\b([A-Z]\w*)\s*[(:=]", contract))
    missing = [m for m in members if not mapped(m)]
    for m in sorted(members):
        target = mapped(m)
        status = "OK  " if target else "FAIL"
        if not target:
            ok = False
        if verbose or not target:
            print("  %s %-22s -> %s" % (status, m, target or "NO MAPPING"))

    print("  %d/%d measured members mapped; %d unmapped"
          % (len(members) - len(missing), len(members), len(missing)))

    print("\n== C. type-level dependencies that must not reach the contract ==")
    print("  client layer references these SynEdit types:")
    # Strip comments here too. Without it the prose in the contract's header
    # ("VCL SynEdit today, LCL TSynEdit tomorrow") reads as a code reference and
    # the section reports IN CONTRACT for a file that is demonstrably clean --
    # which is exactly the kind of false positive that makes a check stop being
    # read. Section A already does this correctly; C must agree with it.
    contract_code = strip_comments(contract)
    for t, n in types.most_common():
        inside = bool(re.search(r"\b%s\b" % re.escape(t), contract_code))
        print("    %-16s x%-3d %s" % (t, n,
                                     "IN CONTRACT" if inside else "absent"))
    # Assert the two sections agree, so this specific bug cannot come back.
    for t in types:
        a_says_leak = bool(re.search(r"\b%s\b" % re.escape(t),
                                     strip_comments(interface_section(
                                         IFACE_UNIT.read_text(
                                             encoding="utf-8",
                                             errors="replace")))))
        if a_says_leak:
            ok = False
            print("  FAIL %s leaks into the interface (section A agrees)" % t)

    print("\nCONTRACT CHECK: %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))