#!/usr/bin/env python3
"""Does the LSP client's marker code compile against the vendored SynEdit?

FOUND WHILE STARTING F2-b -- a real defect, not a hypothetical one.
======================================================================
`Lsp.Client.pas:150-186` (TLspDiagnosticsManager.ApplyDiagnostic) does:

    Marker := TMarker.Create(FEditor);
    Marker.Style           := msBar;
    Marker.Color           := LineCtrl;
    Marker.TopLine         := ADiag.Range.Top;
    Marker.BottomLine      := ADiag.Range.Bottom;
    Marker.EndColumn       := ADiag.Range.Right;
    Marker.ToolDescription := ...;
    FEditor.Markers.Add(Marker);

None of that API exists in the vendored SynEdit. Measured, not assumed:

  * `TMarker` is declared ONCE in the whole repository, in
    Source/VCL/SynEdit/Source/SynHighlighterMulti.pas. It has five fields
    (fScheme, fStartPos, fMarkerLen, fMarkerText, fIsOpenMarker) and a
    constructor (aScheme, aStartPos, aMarkerLen, aIsOpenMarker, text).
    No Style / Color / TopLine / BottomLine / EndColumn / ToolDescription.
  * `TMarker.Create(FEditor)` hands a TSynEdit to a first parameter that is
    declared `aScheme: Integer`.
  * `Markers` exists once, in SynHighlighterMulti.pas, as
    `Markers[Index: Integer]: TMarker` -- an INDEXED property, so it has no
    `.Add(...)` and no `.Count`.
  * `ToolDescription` appears in exactly three files tree-wide: this caller,
    and the two F2 contract files whose COMMENTS mention it.

Conclusion: this routine cannot compile against the SynEdit that is vendored.
So either the project does not currently build, or this unit is not reached.
`--who-uses` answers the second half.

Why this matters for F2 rather than just for tidiness: the F2 contract was
derived from what this code CALLS, which is the right basis. But a contract
whose only marker consumer cannot compile has nothing to be validated
against -- so F2-b must begin by fixing or retiring this routine, not by
writing a VCL adapter for it.

Usage:
    python tools/lsp_marker_api_check.py
    python tools/lsp_marker_api_check.py --who-uses
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SYNEDIT = ROOT / "Source" / "VCL" / "SynEdit"

MARKER_PROPS = ("Style", "Color", "TopLine", "BottomLine", "EndColumn",
                "ToolDescription")
COLLECTION_METHODS = ("Add", "Delete", "Clear")


def pas_files(root):
    for p in sorted(root.rglob("*.pas")):
        yield p, p.read_bytes().decode("latin-1", errors="replace")


def find_tmarker():
    # `[ \t]*` rather than `\s*` for the same CRLF reason documented in
    # class_body_members: the whitespace class here matches the line break too
    # and can drag the anchor across a boundary, which silently finds the wrong
    # declaration or none.
    for p, t in pas_files(ROOT / "Source"):
        m = re.search(r"(?m)^[ \t]*TMarker[ \t]*=[ \t]*class", t)
        if m:
            return p, t, m.start()
    return None, None, None


def class_body_members(t, start):
    r"""Members declared inside ONE class body, ending at its `end;`.

    Two things this gets right that the first drafts did not:

    * Bounded by the class terminator. An unbounded window pulls in whatever
      classes follow and reports THEIR members as this one's -- the first draft
      claimed TMarker had 41 members including `Schemes` and `UserRangeProc`,
      which are TSynMultiSyn's. A check that over-reports is worse than no
      check: it argues for itself.

    * Line-anchored WITHOUT a leading whitespace-star. These vendored files are
      CRLF, and that class matches the line break, so a `*` suffix after `^` can
      span into the next line and mis-anchor every following match. Hence
      `[ \t]*` -- horizontal whitespace only, which is what indentation is.

    The measured truth is small and worth stating: TMarker has five fields and
    one constructor, and nothing else.
    """
    seg = t[start:]
    m = re.search(r"(?m)^[ \t]*end[ \t]*;", seg)
    if m:
        seg = seg[:m.start()]
    out = {}
    for mm in re.finditer(r"(?m)^[ \t]*(?:property[ \t]+(\w+)|function[ \t]+(\w+)|"
                          r"procedure[ \t]+(\w+)|constructor[ \t]+(\w+))", seg):
        name = (mm.group(1) or mm.group(2) or mm.group(3) or mm.group(4))
        out[name.lower()] = mm.group(0).strip()[:60]
    # Fields count as members too: their absence is part of the verdict.
    for mm in re.finditer(r"(?m)^[ \t]+(f\w+)\s*:", seg):
        out.setdefault(mm.group(1).lower(), "field " + mm.group(1))
    return out


def main(argv):
    who = "--who-uses" in argv
    print("== TMarker: the ONE declaration in the tree ==")
    p, t, off = find_tmarker()
    if p is None:
        print("  (not found)")
        return 1
    print("  declared in: %s" % p.relative_to(ROOT).as_posix())
    members = class_body_members(t, off)
    print("  members declared in that class body: %d" % len(members))
    for k in sorted(members):
        print("      %s" % members[k])

    print("\n== does it provide what ApplyDiagnostic calls? ==")
    bad = []
    for prop in MARKER_PROPS:
        hit = members.get(prop.lower())
        print("  %-18s %s" % (prop, hit or "*** ABSENT ***"))
        if not hit:
            bad.append(prop)

    print("\n== the shape of `Markers` in the vendored SynEdit ==")
    # The declaration wraps onto a second line, so match up to the terminating
    # semicolon rather than a single line. The first draft used a one-line
    # pattern and printed an EMPTY section for a property that demonstrably
    # exists -- a silent no-output section reads like "nothing to report"
    # instead of "my regex missed it", which is the worse failure.
    for pp, tt in pas_files(SYNEDIT):
        # The declaration is
        #     property Markers[Index: Integer]: TMarker read GetMarkers;
        # so the property NAME is followed by an index list containing its own
        # colons before the type colon. Matching `\s*:` right after the name
        # consumes the wrong colon and finds nothing -- which the first two
        # drafts did, printing an empty section for a property that plainly
        # exists. An empty section reads as "nothing to report" rather than
        # "my regex missed it", so this one now matches to the semicolon and
        # reports whatever shape it actually finds.
        for m in re.finditer(r"(?is)property[ \t]+Markers\b[^;]*;", tt):
            shape = " ".join(m.group(0).split())
            print("  %s: %s" % (pp.name, shape[:88]))
            if "[" in shape.split(":", 1)[0] or re.search(r"Markers\s*\[", shape):
                print("      -> INDEXED property: no Count, no Add, no Delete")
                for meth in ("Count", "Add", "Delete"):
                    if not re.search(r"\b%s\b" % meth, shape):
                        bad.append("Markers." + meth)
            for meth in COLLECTION_METHODS:
                if not re.search(r"\b%s\b" % meth, shape):
                    print("      %-7s absent -> `.%s(...)` cannot compile"
                          % (meth, meth))
                    if "Markers." + meth not in bad:
                        bad.append("Markers." + meth)

    print("\n== ToolDescription across the whole tree ==")
    for pp, tt in pas_files(ROOT / "Source"):
        if "ToolDescription" in tt:
            print("  %s x%d" % (pp.relative_to(ROOT).as_posix(),
                                tt.count("ToolDescription")))

    print("\n== VERDICT ==")
    if bad:
        print("  Lsp.Client.pas:150-186 calls %d API item(s) the vendored" % len(bad))
        print("  SynEdit does not provide: %s" % ", ".join(bad))
        print("  This routine CANNOT compile against the vendored SynEdit.")
    else:
        print("  all required API present")

    if who:
        print("\n== who uses the LSP client units? ==")
        for name in ("Lsp.Client", "Lsp.Client.Completion", "Lsp.Client.Hover",
                     "Lsp.Client.SignatureHelp", "Lsp.Client.Definition"):
            users = []
            for pp, tt in pas_files(ROOT / "Source"):
                if "VCL" in pp.parts:
                    continue
                for m in re.finditer(r"(?ims)^\s*uses\b(.*?);", tt):
                    for x in m.group(1).split(","):
                        if x.strip().lower().startswith(name.lower()):
                            users.append(pp.name)
            print("  %-24s used by: %s"
                  % (name, ", ".join(sorted(set(users))) or "(NOBODY)"))

    print("\n== does the VCL adapter avoid the missing API? ==")
    ad = ROOT / "Source" / "LSP" / "Editor" / "Lsp.Editor.VclAdapter.pas"
    if not ad.exists():
        print("  (adapter not created yet)")
        return 0
    raw = ad.read_bytes()
    txt = raw.decode("utf-8-sig" if raw[:3] == b"\xef\xbb\xbf" else "utf-8")

    # BOM rule: the QA gate requires one for any non-ASCII file, and this
    # adapter carries non-ASCII punctuation in its comments. Asserted here so
    # file and gate cannot drift.
    non_ascii = any(b > 127 for b in raw)
    has_bom = raw[:3] == b"\xef\xbb\xbf"
    crlf = raw.count(b"\r\n")
    bare = raw.count(b"\n") - crlf
    print("  BOM=%s (non-ASCII: %s -> %s)"
          % (has_bom, non_ascii,
             "OK" if (has_bom or not non_ascii) else "MISSING"))
    print("  line endings: CRLF=%d bareLF=%d %s"
          % (crlf, bare, "OK" if bare == 0 else "*** MIXED ***"))
    if bare != 0 or (non_ascii and not has_bom):
        bad.append("adapter file hygiene")

    # An assignment to a missing member does not compile, so the adapter must
    # not contain one. Comments are stripped first: prose explaining WHY the
    # assignment is absent reads exactly like the assignment itself, and the
    # first pass of this check reported that prose as the crime.
    code = re.sub(r"\{[^}]*\}", " ", txt)
    code = re.sub(r"//[^\n]*", " ", code)
    offenders = re.findall(r"FEditor\s*\.\s*Markers\w*\s*:=", code)
    print("  assignments to missing Markers* API in CODE: %s"
          % (offenders or "(none)"))
    if offenders:
        bad.append("adapter assigns a non-existent member")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
