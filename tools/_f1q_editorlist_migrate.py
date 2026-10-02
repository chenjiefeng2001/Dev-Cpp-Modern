#!/usr/bin/env python3
"""F1 step 4: the last `uses main` unit -- EditorList.pas drops the god form.

SCOPE (plan A, explicitly approved)
-----------------------------------
This removes the `uses main` edge and nothing else. EditorList keeps its
`uses project` dependency on TProject: demoting the container to a pure data
structure is a separate architecture project, and the survey showed the
original "reverse dependency" framing was a misreading -- all six references
were `MainForm.Project`, i.e. one query ("which project is current?"), not the
structural coupling that was assumed. Fixing the number first is what makes
the remaining question worth asking on real evidence.

WHY NOT JUST CALL THE EXISTING ENTRY POINTS
-------------------------------------------
Two of the three sites do line up with existing facade entry points, and using
them is exactly right:

    345  MainForm.Project.Units.IndexOf(Editor)  -> ProjectUnitIndexOf(...)
    348  MainForm.Project.CloseUnit(projindex)  -> CloseProjectUnitOfEditor(...)
    460  MainForm.Project.OpenUnit(I)           -> OpenProjectUnit(...)

CloseProjectUnitOfEditor already wraps `CloseUnit(Units.IndexOf(e))`, which is
what line 348 wants -- BUT it drops a guard the original had:

    original:  projindex := Units.IndexOf(Editor);
               if projindex <> -1 then CloseUnit(projindex);
    facade:    CloseUnit(Units.IndexOf(e));        // no -1 check

If IndexOf returns -1 the facade passes -1 into TProject.CloseUnit, which does
`with fUnits[-1]` -- an out-of-bounds access. The original explicitly guarded
against it. Reusing the entry point here would be a silent behaviour change
smuggled in as a convenience, so the -1 test is preserved at the call site and
only the unguarded tail is delegated. ProjectUnitIndexOf is added for the same
reason: the lookup has to happen before the guard can be applied.

`GetUnitFromString` becomes ProjectUnitIndexOf, which is the one genuinely new
entry point. It is already a pure query -- its body only touches the project's
own fUnits and Directory -- so the facade adds indirection, not logic.

ENCODING
--------
Pure ASCII/UTF-8 (unlike devCFG.pas in step 3), so the plain utf-8 reader with
`errors='replace'` is safe here. Asserted rather than assumed: read_raw()
raises if the round-trip is not byte-exact, so this file can never silently
acquire the corruption step 3 had to fix.

Usage:  python tools/_f1q_editorlist_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAINUI = ROOT / "Source" / "UI" / "MainUi.pas"
EDLIST = ROOT / "Source" / "EditorList.pas"
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    """Decode losslessly, refusing to continue if the round-trip is lossy.

    Step 3 had to switch devCFG.pas to latin-1 because utf-8 + errors='replace'
    destroys its cp1252 bytes. This file is pure ASCII, so utf-8 is exact --
    but "is exact" is a property of the file's bytes, not of the decoder, so it
    is checked on every read instead of being remembered.
    """
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        text = raw.decode("utf-8-sig")
    else:
        text = raw.decode("utf-8")
    if text.encode("utf-8") != raw and not raw.startswith(b"\xef\xbb\xbf"):
        raise SystemExit("read_raw: %s is not byte-exact under utf-8; "
                         "use latin-1 as step 3 did" % path.name)
    return text


def write_raw(path, text):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))


def edit(path, rules):
    eol = eol_of(path)
    text = read_raw(path)
    plan = []
    for old, new, want in rules:
        o, n = old.replace("\n", eol), new.replace("\n", eol)
        got = text.count(o)
        if got != want:
            print("  ABORT %s: pattern hit %d, expected %d\n    %r"
                  % (path.name, got, want, old.strip()[:90]))
            return False
        plan.append((o, n))
    for o, n in plan:
        text = text.replace(o, n)
    if DRY:
        print("  DRY  %s: %d rule(s) ok" % (path.name, len(plan)))
        return True
    write_raw(path, text)
    print("  OK   %s: %d rule(s) applied" % (path.name, len(plan)))
    return True


# --- MainUi: one new Query entry point --------------------------------------
# Anchored on `implementation` (step 2/3 lesson: the trailing declaration block
# is not unique in this file).
MAINUI_IFACE_OLD = (
    "function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;\n"
    "\n"
    "implementation\n"
)

MAINUI_IFACE_NEW = (
    "function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;\n"
    "\n"
    "// ---------------------------------------------------------------\n"
    "// Project unit lookup slice (TProject.fUnits) -- F1, step 4.\n"
    "//\n"
    "// ProjectUnitIndexOf is GetUnitFromString, renamed and moved. The body\n"
    "// is already a pure query -- `fUnits.IndexOf(ExpandFileTo(s, Directory))`\n"
    "// touches nothing but the project's own fields -- so this adds\n"
    "// indirection, not logic, and the name now says what the caller means\n"
    "// (\"which unit is this file?\") rather than which string form it takes.\n"
    "//\n"
    "// It returns -1 when absent, exactly as IndexOf did, so the caller's\n"
    "// existing -1 test keeps working unchanged.\n"
    "//\n"
    "// Note the guard asymmetry with CloseProjectUnitOfEditor: THAT entry\n"
    "// point forwards IndexOf's result into CloseUnit without re-checking it,\n"
    "// while here the caller must still test -1 before acting. See the step 4\n"
    "// notes in tools/_f1q_editorlist_migrate.py -- the caller keeps the\n"
    "// guard, because TProject.CloseUnit indexes fUnits[index] unguarded.\n"
    "// ---------------------------------------------------------------\n"
    "\n"
    "function ProjectUnitIndexOf(const AFileName: string): Integer;\n"
    "\n"
    "implementation\n"
)

MAINUI_IMPL_OLD = (
    "  if MainForm.GetCompileTarget = ctProject then\n"
    "    Result := MainForm.Project.Options.CompilerSet;\n"
    "end;\n"
)

MAINUI_IMPL_NEW = (
    "  if MainForm.GetCompileTarget = ctProject then\n"
    "    Result := MainForm.Project.Options.CompilerSet;\n"
    "end;\n"
    "\n"
    "function ProjectUnitIndexOf(const AFileName: string): Integer;\n"
    "begin\n"
    "  Result := -1;\n"
    "  if not Assigned(MainForm) or not Assigned(MainForm.Project) then\n"
    "    Exit;\n"
    "  Result := MainForm.Project.GetUnitFromString(AFileName);\n"
    "end;\n"
)


# --- EditorList: the six references become three facade calls ---------------
# Site 1 (lines 344-349): lookup + guarded close. The `-1` test is KEPT at the
# call site -- CloseProjectUnitOfEditor does not re-check it, and
# TProject.CloseUnit would index fUnits[-1] unguarded.
SITE1_OLD = (
    "    if Editor.InProject and Assigned(MainForm.Project) then begin\n"
    "      projindex := MainForm.Project.Units.IndexOf(Editor);\n"
    "      if projindex <> -1 then\n"
    "      begin\n"
    "        MainForm.Project.CloseUnit(projindex); // calls ForceCloseEditor\n"
    "      end;\n"
)

SITE1_NEW = (
    "    if Editor.InProject and Assigned(MainForm.Project) then begin\n"
    "      projindex := MainUi.ProjectUnitIndexOf(Editor.FileName);\n"
    "      if projindex <> -1 then\n"
    "      begin\n"
    "        MainUi.CloseProjectUnitOfEditor(Editor); // calls ForceCloseEditor\n"
    "      end;\n"
)

# Site 2 (lines 457-461): index lookup + open. `OpenProjectUnit` is an exact
# match for the old `Project.OpenUnit(I)`.
SITE2_OLD = (
    "  if Assigned(MainForm.Project) then begin\n"
    "    I := MainForm.Project.GetUnitFromString(FullFileName);\n"
    "    if I <> -1 then begin\n"
    "      result := MainForm.Project.OpenUnit(I);\n"
)

SITE2_NEW = (
    "  if Assigned(MainForm.Project) then begin\n"
    "    I := MainUi.ProjectUnitIndexOf(FullFileName);\n"
    "    if I <> -1 then begin\n"
    "      result := MainUi.OpenProjectUnit(I);\n"
)

# Site 3: the uses clause. `main` -> `MainUi`; `project` STAYS (plan A).
USES_OLD = (
    "uses\n"
    "  System.UItypes, main, MultiLangSupport, DataFrm;\n"
)

USES_NEW = (
    "uses\n"
    "  System.UItypes, MainUi, MultiLangSupport, DataFrm;\n"
)


def main():
    print("F1 step 4 migration %s" % ("(dry run)" if DRY else ""))
    if not edit(MAINUI, [(MAINUI_IFACE_OLD, MAINUI_IFACE_NEW, 1),
                         (MAINUI_IMPL_OLD, MAINUI_IMPL_NEW, 1)]):
        print("BATCH ABORTED -- MainUi.pas untouched.")
        return 1
    if not edit(EDLIST, [(SITE1_OLD, SITE1_NEW, 1),
                         (SITE2_OLD, SITE2_NEW, 1),
                         (USES_OLD, USES_NEW, 1)]):
        print("BATCH ABORTED -- EditorList.pas untouched.")
        return 1
    print("all 2 file(s) written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())