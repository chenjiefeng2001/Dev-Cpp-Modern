#!/usr/bin/env python3
"""F1 step 3: route devCFG's two live MainForm refs through the facade.

WHY THIS FILE NEEDS A DIFFERENT READER THAN THE EARLIER MIGRATIONS
--------------------------------------------------------------------
`Source/devCFG.pas` is not UTF-8 and not GBK. It is mostly ASCII, with a few
cp1252 curly quotes (0x91/0x92) buried inside GCC command-line switches:

    ...it has the same meaning as \x91generic\x92.=i686');

Those bytes are LIVE SOURCE -- they end up inside compiler argument strings.
The reader every earlier migration script used is

    raw.decode('utf-8', errors='replace')   ...then write back with .encode('utf-8')

and it is DESTRUCTIVE here. `errors='replace'` turns 0x91 into U+FFFD, which
encodes back as THREE bytes, so a read/write round trip would silently rewrite
    '\x91generic\x92'   ->   '\xef\xbf\xbdgeneric\xef\xbf\xbd'
in a string that is handed to the compiler. Measured on the real file:
116699 bytes in, 116705 out, the two quote bytes gone for good. No test in
this repo would have caught it -- it is not a syntax error, it is a compiler
flag silently mangled.

So read_raw() below decodes latin-1, which is a strict bijection between bytes
and code points 0..255. Every byte sequence round-trips to itself EXACTLY,
and ASCII still compares as ASCII, so the migration rules can be written as
ordinary ASCII strings. The text is never interpreted, only relocated.

WHAT IS ACTUALLY BEING MIGRATED
-------------------------------
TdevCompilerSets.GetCompilationSetIndex answers one question -- "which
compiler set is in effect?" -- and devCFG reached into the god form to answer
it twice:

    if Assigned(MainForm) then
      case MainForm.GetCompileTarget of
        ctProject: Result := MainForm.Project.Options.CompilerSet;
        ...else   : Result := fDefaultIndex;
      end;

`ProjectCompilerSetIndex` moves that decision to the facade. The TTarget
enum does NOT cross the interface (it is declared in main.pas, and leaking it
would put a god-form type into every consumer's uses clause for the privilege
of one comparison); the facade takes and returns plain integers instead, so
the enum test stays where the enum lives.

`GetCompilationSetIndex` also keeps its `Assigned(MainForm)` guard's meaning:
when there is no form, or no project, the answer is the caller's own default.

The third `MainForm` in this unit (line ~1985, `with MainForm do`) sits inside
a `{ ... }` block that disables the whole OnCompilerSetChanged routine. It is
NOT compiled, so it needs no facade entry -- but it still has to stop being a
live `uses main` dependency, which happens automatically once `uses main` is
dropped. Left as-is, deliberately: rewriting dead code to look decoupled is
the mirror image of the metric cosmetics this project has refused before.

Usage:  python tools/_f1p_devcfg_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAINUI = ROOT / "Source" / "UI" / "MainUi.pas"
DEVCFG = ROOT / "Source" / "devCFG.pas"
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    """Decode losslessly.

    latin-1 maps bytes 0x00-0xFF to the identical code points, so encode() is
    the exact inverse. This is the whole point of not using utf-8 here: the
    replacement character is lossy and this file is not valid utf-8.
    """
    return path.read_bytes().decode("latin-1")


def write_raw(path, text):
    path.write_bytes(text.encode("latin-1"))
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


# --- MainUi: the new Query entry point -------------------------------------
# Anchored on the `implementation` keyword for the same reason as step 2: the
# trailing declaration block is not unique in this file, and a bare
# `procedure RefreshWatchVars;` also matches its own implementation.
MAINUI_IFACE_OLD = (
    "procedure ApplyEditorAutoSave(const AEnabled: Boolean;\n"
    "  AIntervalMinutes: Integer);\n"
    "\n"
    "implementation\n"
)

MAINUI_IFACE_NEW = (
    "procedure ApplyEditorAutoSave(const AEnabled: Boolean;\n"
    "  AIntervalMinutes: Integer);\n"
    "\n"
    "// ---------------------------------------------------------------\n"
    "// Compiler-set selection slice (TdevCompilerSets) -- F1, step 3.\n"
    "//\n"
    "// devCFG asked the god form one question -- \"which compiler set is\n"
    "// in effect?\" -- and paid for it with two MainForm reads: the compile\n"
    "// target, then the project's chosen set. Both belong to the same\n"
    "// decision, so they come back as ONE integer.\n"
    "//\n"
    "// The integers are ctNone/ctFile/ctProject as declared in main.pas,\n"
    "// and that declaration deliberately does NOT cross this interface.\n"
    "// Exposing TTarget would drag a god-form type into the uses clause\n"
    "// of every consumer for the privilege of one comparison. The caller\n"
    "// passes its default index and gets back an override; the enum test\n"
    "// itself stays beside the enum, the only place it can be maintained\n"
    "// without touching a consumer.\n"
    "//\n"
    "// Returns ADefaultIndex unchanged when there is no form, no project,\n"
    "// or the compile target is not ctProject -- exactly what the original\n"
    "// `case` fell through to, so no branch was invented here.\n"
    "// ---------------------------------------------------------------\n"
    "\n"
    "function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;\n"
    "\n"
    "implementation\n"
)

MAINUI_IMPL_OLD = (
    "  end else begin\n"
    "    MainForm.AutoSaveTimer.Free;\n"
    "    MainForm.AutoSaveTimer := nil;\n"
    "  end;\n"
    "end;\n"
)

MAINUI_IMPL_NEW = (
    "  end else begin\n"
    "    MainForm.AutoSaveTimer.Free;\n"
    "    MainForm.AutoSaveTimer := nil;\n"
    "  end;\n"
    "end;\n"
    "\n"
    "function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;\n"
    "begin\n"
    "  Result := ADefaultIndex;\n"
    "  if not Assigned(MainForm) then\n"
    "    Exit;\n"
    "  if not Assigned(MainForm.Project) then\n"
    "    Exit;\n"
    "  // ctProject is the only branch that ever overrode the default; ctNone\n"
    "  // and ctFile both assigned fDefaultIndex on the caller's side.\n"
    "  if MainForm.GetCompileTarget = ctProject then\n"
    "    Result := MainForm.Project.Options.CompilerSet;\n"
    "end;\n"
)

# --- devCFG: the two live refs become one call -----------------------------
DEVCFG_OLD = (
    "function TdevCompilerSets.GetCompilationSetIndex: Integer;\n"
    "begin\n"
    "  Result := -1;\n"
    "  if Assigned(MainForm) then begin\n"
    "    case MainForm.GetCompileTarget of\n"
    "      ctNone:\n"
    "        Result := fDefaultIndex;\n"
    "      ctFile:\n"
    "        Result := fDefaultIndex;\n"
    "      ctProject:\n"
    "        Result := MainForm.Project.Options.CompilerSet;\n"
    "    end;\n"
    "  end else\n"
    "    Result := fDefaultIndex;\n"
    "end;\n"
)

# `Result := -1` is overwritten on EVERY path of the original (each branch of
# the case assigns, and the else assigns), so it was never observable. It is
# dropped rather than preserved: keeping a dead assignment would suggest a
# default the function cannot actually return. The `else Result := fDefaultIndex`
# arm is likewise unreachable -- it can only be taken when Assigned(MainForm)
# is false, which the first arm already handles by assigning the default.
DEVCFG_NEW = (
    "function TdevCompilerSets.GetCompilationSetIndex: Integer;\n"
    "begin\n"
    "  Result := MainUi.ProjectCompilerSetIndex(fDefaultIndex);\n"
    "end;\n"
)


DEVCFG_USES_OLD = (
    "  MultiLangSupport, DataFrm, StrUtils, Forms, main, compiler, Controls, "
    "version, utils, SynEditMiscClasses,\n"
)

DEVCFG_USES_NEW = (
    "  MultiLangSupport, DataFrm, StrUtils, Forms, MainUi, compiler, Controls, "
    "version, utils, SynEditMiscClasses,\n"
)


def main():
    print("F1 step 3 migration %s" % ("(dry run)" if DRY else ""))
    if not edit(MAINUI, [(MAINUI_IFACE_OLD, MAINUI_IFACE_NEW, 1),
                         (MAINUI_IMPL_OLD, MAINUI_IMPL_NEW, 1)]):
        print("BATCH ABORTED -- MainUi.pas untouched.")
        return 1
    if not edit(DEVCFG, [(DEVCFG_OLD, DEVCFG_NEW, 1),
                         (DEVCFG_USES_OLD, DEVCFG_USES_NEW, 1)]):
        print("BATCH ABORTED -- devCFG.pas untouched.")
        return 1
    print("all 2 file(s) written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
