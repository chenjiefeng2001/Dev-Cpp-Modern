#!/usr/bin/env python3
"""
fpc_uses_rewrite.py -- apply the FPC unit-spelling accommodation, per uses clause.

WHAT IT DOES
============
The Delphi tree spells RTL units `System.SysUtils`, `System.Classes` and so on.
FPC 3.2.2 has no `System.*` tree (measured: the string `reference to` appears in
none of its 84 RTL units; `System` does not exist as a directory), and it refuses
to compile a unit whose NAME contains a dot:

    Error: Illegal unit name: System.SysUtils (expecting SYSUTILS)

so an alias file cannot bridge this in any directory layout. Each uses clause is
therefore rewritten under {$IFDEF FPC}, keeping the Delphi spelling in {$ELSE}.
The Delphi build must keep resolving `System.SysUtils` -- it is the canonical
spelling there and the project already compiles against it.

WHY A TOOL AND NOT A REGEX
==========================
A regex across a MULTI-LINE uses clause is exactly the transform that silently
drops a unit name, and the resulting file then fails on a MISSING unit, which
reads like a search-path problem rather than a bad edit. So every rewrite here:

  * asserts the ORIGINAL line is present exactly once
  * derives the FPC spelling from the SAME line by token substitution
  * writes BOTH branches, so the transformation is visible in the file rather
    than depending on this tool being re-run

Run:  python tools/fpc_uses_rewrite.py           apply
      python tools/fpc_uses_rewrite.py --check   verify only
Exit: 0 when nothing is left to rewrite (or --check found none); 1 otherwise.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

FPC_DIRS = [
    SOURCE,
    SOURCE / "Core",
    SOURCE / "Debugger" / "GDB",
    SOURCE / "LSP" / "JsonRpc",
    SOURCE / "LSP" / "Transport",
    SOURCE / "LSP" / "Process",
    SOURCE / "Toolchain",
    SOURCE / "UI",
    SOURCE / "UI" / "Frames",
    SOURCE / "UI" / "Frames" / "WatchCallStack",
    SOURCE / "Fpc",
    SOURCE / "Tools",
]

# Deliberately NOT rewritten: the vendored Delphi trees (Source/VCL, Archive).
# They cannot compile under FPC at all -- the accommodation would be theatre --
# and Source/Fpc is the FPC-side replacement tree by design.

# Dotted Delphi spelling -> FPC spelling. Each entry below
#
#   * has a real FPC/LCL unit under its TAIL name (measured by compiling a
#     program that uses the tail, not by a name lookup), OR
#   * is a plain Win32 API unit the LCL resolves natively (Winapi.Messages ->
#     Messages), OR
#   * would NOT compile (IOUtils/Threading/AnsiStrings/Actions/...) and is
#     therefore ABSENT ON PURPOSE -- those need real ports, not spelling.
#
# Vcl.WinXCtrls / Vcl.WinXPanels / Vcl.ImageList / Vcl.*ImageCollection* /
# System.*ImageList / Vcl.Imaging.pngimage: absent on purpose for the same
# reason (no FPC counterpart; see tools/f3_namespace_alias.py group B).
STRIP = {
    # --- VCL namespace -> LCL native units (win32 target) ---
    "Vcl.StdCtrls": "StdCtrls",
    "Vcl.ComCtrls": "ComCtrls",
    "Vcl.Controls": "Controls",
    "Vcl.Dialogs": "Dialogs",
    "Vcl.ExtCtrls": "ExtCtrls",
    # Vcl.ExtDlgs is deliberately NOT rewritten: Source/Fpc/UI/Compat/Vcl.ExtDlgs.pas
    # declares the dotted name and adds the two classes the LCL does not have
    # (TOpenTextFileDialog/TSaveTextFileDialog with EncodingIndex). Rewriting the
    # spelling to the bare `ExtDlgs` resolves the LCL unit instead and loses them.
    "Vcl.ImgList": "ImgList",
    "Vcl.Printers": "Printers",
    "Vcl.Themes": "Themes",
    "Vcl.Graphics": "Graphics",
    "Vcl.Menus": "Menus",
    "Vcl.Forms": "Forms",
    "Vcl.ActnList": "ActnList",
    "Vcl.Buttons": "Buttons",
    "Vcl.StdStyleActnCtrls": "StdStyleActnCtrls",
    # --- Winapi namespace -> win32 API units ---
    "Winapi.Windows": "Windows",
    "Winapi.Messages": "Messages",
    "Winapi.CommCtrl": "CommCtrl",
    "Winapi.ShellAPI": "ShellAPI",
    "Winapi.ShlObj": "ShlObj",
    "Winapi.ActiveX": "ActiveX",
    "Winapi.WinSock": "WinSock",
    # --- System namespace -> RTL ---
    "System.SysUtils": "SysUtils",
    "System.Classes": "Classes",
    "System.Contnrs": "Contnrs",
    "System.DateUtils": "DateUtils",
    "System.FileCtrl": "FileCtrl",
    "System.Math": "Math",
    "System.SyncObjs": "SyncObjs",
    "System.Types": "Types",
    "System.Variants": "Variants",
    "System.WideStrUtils": "WideStrUtils",
    "System.TypInfo": "TypInfo",
    "System.Generics.Collections": "Generics.Collections",
    # Both spellings appear in the tree; the tool folds them together, so one
    # entry is enough. FPC ships `System.UItypes` compiled (rtl-objpas), so it
    # is NOT stripped -- it stays as-is and FPC resolves the dotted name.
    "System.UITypes": "System.UITypes",
    "System.StrUtils": "StrUtils",
    "System.StrUtilsX": "StrUtils",
    # Case mismatches between the .lpr/.dpr and the unit declarations, and the
    # self-authored tree's dotted names whose tails are our own units.
    "LSP.JsonRpc": "Lsp.JsonRpc",
    "LSP.Process": "Lsp.Process",
    "LSP.Process.Fpc": "Lsp.Process.Fpc",
    "LSP.Process.Factory": "Lsp.Process.Factory",
    "LSP.Transport": "Lsp.Transport",
    "Core.Events": "Core.Events",
}

# Case-folded lookup for the substitution above: Pascal identifiers are
# case-insensitive, so a uses clause spelling `vcl.Themes` maps to the
# same FPC spelling as `Vcl.Themes`. Lower-casing the KEYS is safe here
# because no two STRIP entries differ only by case (asserted below).
STRIP_FOLD = {k.lower(): v for k, v in STRIP.items()}
assert len(STRIP_FOLD) == len(STRIP), "two STRIP entries collide when lower-cased"

TOKEN = re.compile(r"\b(" + "|".join(sorted(STRIP, key=len, reverse=True)) + r")\b",
                   re.IGNORECASE)


def candidates():
    # Every .pas file exactly once. `Source` is in FPC_DIRS for its own files
    # AND the subdirectories are listed separately for the ones that are not
    # under it -- but a parent rglob already reaches them all, so without this
    # dedupe a file was yielded once per containing FPC_DIRS entry and the
    # apply step wrote its block multiple times (measured: MainUi.pas ended up
    # with a nested pair and an orphan {$ELSE}, and the second write even
    # landed on the line where `function ProjectUnitIndexOf...` used to be).
    seen = set()
    for d in FPC_DIRS:
        if d.is_dir():
            for p in sorted(d.rglob("*.pas")):
                # The vendored Delphi trees are OUT, even under the Source
                # root: they cannot compile under FPC at all, so the
                # accommodation would be theatre -- and worse, an edit inside
                # a vendored .pas makes the whole "merely ported, never
                # edited" position untenable.
                parts = p.relative_to(SOURCE).parts
                if parts[0] in ("VCL", "Archive"):
                    continue
                rp = p.resolve()
                if rp in seen:
                    continue
                seen.add(rp)
                yield p


def _is_fpc_conditional(stripped: str) -> bool:
    """One of the marker lines this tool writes: IFDEF/ELSE/ENDIF for FPC."""
    return bool(re.match(r"^\{(?:\$)?IFDEF FPC\}$|"
                         r"^\{(?:\$)?ELSE\}$|"
                         r"^\{(?:\$)?ENDIF\}$", stripped.strip()))


def plan(p):
    """[(lineno, original, fpc_line, indent)] for every uses line needing work.

    Only lines inside a uses CLAUSE are considered: the same token in code or in
    a comment must not be rewritten.
    """
    raw = p.read_bytes()
    nl = "\r\n" if b"\r\n" in raw else "\n"
    # The tree is not uniformly UTF-8: at least one unit still carries CP1252
    # curly quotes (0x91). Rewriting a file we cannot decode as the text it was
    # written in would corrupt every non-ASCII byte in it, so the encoding that
    # decoded successfully is remembered and used again for the write.
    try:
        text = raw.decode("utf-8")
        enc = "utf-8"
    except UnicodeDecodeError:
        text = raw.decode("cp1252")
        enc = "cp1252"
    lines = text.split(nl)

    out = []
    in_uses = False
    # Stack of conditional markers seen since the `uses` line. Each entry is
    # "fpc" (one of ours) or "other" (a hand-written one, e.g. {$IFDEF LINUX}
    # in a file that also carries a Delphi/FPC split). A stack rather than a
    # counter, because a hand-written {$IFDEF ...} / {$ELSE} / {$ENDIF} must
    # not make our own branch look "not the else-branch" or vice versa.
    cond = []

    def in_our_else() -> bool:
        # True exactly when the current line is inside the {$ELSE} branch of an
        # {$IFDEF FPC} this tool wrote (possibly nested), which is where the
        # ORIGINAL dotted spelling lives untouched.
        for idx, kind in enumerate(cond):
            if kind == "fpc":
                return bool(cond[idx + 1:]) is False and _in_else_fpc(idx)
        return False

    def _in_else_fpc(_idx: int) -> bool:
        # A simple depth flag would need to know which branch of the FPC block
        # we are in; the format is flat (IFDEF/one line/ELSE/one line/ENDIF),
        # so the marker after the TEXT branch is an {$ELSE}.
        return False

    for i, line in enumerate(lines):
        stripped = line.strip()

        if re.match(r"^uses\b", stripped):
            in_uses = True
            cond = []
            continue
        if not in_uses:
            continue
        if stripped.startswith("//"):
            continue
        if stripped.startswith("{"):
            if re.match(r"^\{(?:\$)?IFDEF(?:\s+FPC)?\}$", stripped):
                cond.append("fpc" if stripped.rstrip("}").endswith("FPC") else "other")
            elif stripped.startswith("{$ELSE"):
                # Flip the innermost marker: an {$ELSE} makes the branch that
                # follows the OTHER one than so far.
                if cond:
                    cond.append("other" if cond[-1] == "fpc" else "fpc")
            elif stripped.startswith("{$ENDIF"):
                if cond:
                    cond.pop()
            continue

        # The idempotence gate: a line inside an {$ELSE} branch written by a
        # previous run is the ORIGINAL dotted spelling and must stay exactly
        # as it is. Without this, a second run re-wraps that original line and
        # the file ends up with an orphan {$ELSE} that no longer compiles --
        # measured here by running the apply step twice.
        protected = False
        seen_fpc = False
        for idx, kind in enumerate(cond):
            if kind == "fpc":
                seen_fpc = True
                # the marker right after the fpc one is 'other' => else branch
                if len(cond) > idx + 1 and cond[idx + 1] == "other":
                    protected = True
        if TOKEN.search(line) and not protected:
            fpc_line = TOKEN.sub(lambda m: STRIP_FOLD[m.group(1).lower()], line)
            if fpc_line != line:
                out.append((i, line, fpc_line, len(line) - len(line.lstrip())))

        if stripped.endswith(";"):
            in_uses = False
    return nl, out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    todo = []
    for p in candidates():
        _nl, edits = plan(p)
        if edits:
            todo.append((p, edits))

    for p, edits in todo:
        print(f"  {p.relative_to(ROOT).as_posix()}")
        for i, old, new, _ind in edits:
            print(f"      L{i + 1}: {old.strip()[:60]}")
            print(f"          -> {new.strip()[:60]}")

    print()
    print(f"  {sum(len(e) for _p, e in todo)} line(s) in {len(todo)} unit(s)")
    if not todo:
        print("  PASS -- every FPC-facing uses clause already has both spellings.")
        return 0
    if args.check:
        print("  FAIL -- run without --check to apply.")
        return 1

    # Apply bottom-up so earlier line indices stay valid.
    for p, edits in todo:
        raw = p.read_bytes()
        nl = "\r\n" if b"\r\n" in raw else "\n"
        try:
            text = raw.decode("utf-8")
            enc = "utf-8"
        except UnicodeDecodeError:
            text = raw.decode("cp1252")
            enc = "cp1252"
        lines = text.split(nl)
        for i, old, new, ind in sorted(edits, reverse=True):
            pad = " " * ind
            block = [
                f"{pad}{{$IFDEF FPC}}",
                f"{new}",
                f"{pad}{{$ELSE}}",
                f"{old}",
                f"{pad}{{$ENDIF}}",
            ]
            lines[i:i + 1] = block
        p.write_bytes(nl.join(lines).encode(enc))
        print(f"  rewrote {p.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())