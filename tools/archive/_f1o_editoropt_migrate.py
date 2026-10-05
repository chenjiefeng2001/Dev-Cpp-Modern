#!/usr/bin/env python3
"""F1 step 2: collapse EditorOptFrm's 8 auto-save timer refs into ONE facade call.

The eight `MainForm.AutoSaveTimer` / `MainForm.EditorSaveTimer` references in
btnOkClick are a single action written out statement by statement, so they
become a single semantic entry point rather than eight forwarders -- the
ratchet's 16 -> 8 and `uses main` 3 -> 2 both fall out of that one decision.

Usage:  python tools/_f1o_editoropt_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAINUI = ROOT / "Source" / "UI" / "MainUi.pas"
OPTFRM = ROOT / "Source" / "EditorOptFrm.pas"
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    raw = path.read_bytes()
    return raw.decode("utf-8-sig" if raw.startswith(b"\xef\xbb\xbf")
                      else "utf-8", errors="replace")


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
    path.write_bytes(text.encode("utf-8"))
    print("  OK   %s: %d rule(s) applied" % (path.name, len(plan)))
    return True


# --- MainUi: the new entry point ------------------------------------------
# Anchored on a DECLARATION BLOCK, never a bare declaration line: a bare
# `procedure RefreshWatchVars;` also matches its own implementation, and a
# per-rule "hit count == 1" assertion cannot catch that -- each pattern
# matches once on its own, and only their COMBINATION creates a duplicate.
#
# The trailing `\n\nimplementation` is load-bearing, not decoration. This
# declaration block appears TWICE in the file (the interface list at 527, and
# again immediately before `implementation` at 594), so the block alone hit 2
# and the dry run aborted. A blind text replace would have injected the entry
# point into the implementation's forward declarations as well, where it would
# still compile -- and silently put the rationale comment in the wrong section.
MAINUI_IFACE_OLD = (
    "procedure RestoreLeftPageIndex(AIndex: Integer);\n"
    "procedure RefreshWatchVars;\n"
    "\n"
    "implementation\n"
)

MAINUI_IFACE_NEW = (
    "procedure RestoreLeftPageIndex(AIndex: Integer);\n"
    "procedure RefreshWatchVars;\n"
    "\n"
    "// ---------------------------------------------------------------\n"
    "// Auto-save timer slice (TMainForm.AutoSaveTimer) -- F1, step 2.\n"
    "//\n"
    "// The eight `MainForm.AutoSaveTimer` / `MainForm.EditorSaveTimer`\n"
    "// references EditorOptFrm.pas held in btnOkClick were not eight\n"
    "// couplings. They were ONE -- \"apply the editor auto-save settings to\n"
    "// the running timer\" -- written out statement by statement, which is\n"
    "// exactly the shape that tempts a migration into eight thin forwarders.\n"
    "// The one-call rule earned its keep here.\n"
    "//\n"
    "// Note what is deliberately NOT a parameter: the timer itself and the\n"
    "// OnTimer handler. A caller that could hand over its own TTimer or its\n"
    "// own callback would be re-coupling the very widget the facade exists to\n"
    "// hide -- and the handler is not the caller's to choose, it is the god\n"
    "// form's own method, which is the whole reason the timer lives here.\n"
    "//\n"
    "// AIntervalMinutes is in MINUTES, matching devEditor.Interval. Both\n"
    "// copies of this logic (main.pas FormCreate and btnOkClick) did the\n"
    "// *60*1000 conversion at the call site; doing it here instead means the\n"
    "// two can no longer disagree about units.\n"
    "// ---------------------------------------------------------------\n"
    "\n"
    "procedure ApplyEditorAutoSave(const AEnabled: Boolean;\n"
    "  AIntervalMinutes: Integer);\n"
    "\n"
    "implementation\n"
)


# Implementation: appended just after EchoGdbCommand, the last existing body,
# so the new code cannot land inside an unrelated routine.
MAINUI_IMPL_OLD = (
    "  // The echo consumed the right to overwrite: the box now holds an engine\n"
    "  // command, not the user's word.\n"
    "  MainForm.fDebugger.CommandChanged := False;\n"
    "end;\n"
)

MAINUI_IMPL_NEW = (
    "  // The echo consumed the right to overwrite: the box now holds an engine\n"
    "  // command, not the user's word.\n"
    "  MainForm.fDebugger.CommandChanged := False;\n"
    "end;\n"
    "\n"
    "procedure ApplyEditorAutoSave(const AEnabled: Boolean;\n"
    "  AIntervalMinutes: Integer);\n"
    "begin\n"
    "  if not Assigned(MainForm) then\n"
    "    Exit;\n"
    "  // Behaviour carried over unchanged from btnOkClick, including the\n"
    "  // `.Free` + `:= nil` pair rather than FreeAndNil: same order, same\n"
    "  // visible result, so this migration cannot be blamed for a difference\n"
    "  // nobody asked for.\n"
    "  if AEnabled then begin\n"
    "    if not Assigned(MainForm.AutoSaveTimer) then\n"
    "      MainForm.AutoSaveTimer := TTimer.Create(nil);\n"
    "    MainForm.AutoSaveTimer.Interval := AIntervalMinutes * 60 * 1000;\n"
    "    // miliseconds to minutes\n"
    "    MainForm.AutoSaveTimer.Enabled := AEnabled;\n"
    "    MainForm.AutoSaveTimer.OnTimer := MainForm.EditorSaveTimer;\n"
    "  end else begin\n"
    "    MainForm.AutoSaveTimer.Free;\n"
    "    MainForm.AutoSaveTimer := nil;\n"
    "  end;\n"
    "end;\n"
)

# --- EditorOptFrm: the eight refs become one call --------------------------
OPTFRM_OLD = (
    "  // Only create the timer if autosaving is enabled\n"
    "  if devEditor.EnableAutoSave then begin\n"
    "    if not Assigned(MainForm.AutoSaveTimer) then\n"
    "      MainForm.AutoSaveTimer := TTimer.Create(nil);\n"
    "    MainForm.AutoSaveTimer.Interval := devEditor.Interval * 60 * 1000; "
    "// miliseconds to minutes\n"
    "    MainForm.AutoSaveTimer.Enabled := devEditor.EnableAutoSave;\n"
    "    MainForm.AutoSaveTimer.OnTimer := MainForm.EditorSaveTimer;\n"
    "  end else begin\n"
    "    MainForm.AutoSaveTimer.Free;\n"
    "    MainForm.AutoSaveTimer := nil;\n"
    "  end;\n"
)

OPTFRM_NEW = (
    "  // Only create the timer if autosaving is enabled. Create, reconfigure and\n"
    "  // tear down are one decision, so they are one call: devEditor still\n"
    "  // supplies the settings, the facade still owns the timer.\n"
    "  MainUi.ApplyEditorAutoSave(devEditor.EnableAutoSave, devEditor.Interval);\n"
)


def main():
    print("F1 step 2 migration %s" % ("(dry run)" if DRY else ""))
    if not edit(MAINUI, [(MAINUI_IFACE_OLD, MAINUI_IFACE_NEW, 1),
                         (MAINUI_IMPL_OLD, MAINUI_IMPL_NEW, 1)]):
        print("BATCH ABORTED -- MainUi.pas untouched.")
        return 1
    if not edit(OPTFRM, [(OPTFRM_OLD, OPTFRM_NEW, 1)]):
        print("BATCH ABORTED -- EditorOptFrm.pas untouched.")
        return 1
    print("all 2 file(s) written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
