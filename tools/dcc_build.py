#!/usr/bin/env python3
"""Compile the Delphi project WITHOUT the IDE, and report honestly if blocked.

Front-line A on the roadmap ("compile in a real Delphi environment") assumed a
separate host machine with an IDE. This box already has Embarcadero Studio
37.0, so front-line A is runnable HERE -- once the command-line route works.

MEASURED ON THIS MACHINE (Studio 37.0, Windows)
================================================
Four attempts, each fixing the previous blocker:

  1. `dcc32` directly
     -> "This version of the product does not support command line compiling."

  2. `dotnet msbuild devcpp.dproj`
     -> MSB4057: target "Build" does not exist. The .dproj never imports
        CodeGear's targets; the IDE (bds.exe) injects them.

  3. `dotnet msbuild` + Source/DelphiBuild.proj (added by this repo)
     -> targets DO load, then MSB4062: the DependencyCheck task needs
        Microsoft.Build.Utilities.v4.0, which .NET Core MSBuild cannot load.
        Fixed by using a real .NET Framework MSBuild (VS 2022).

  4. Framework MSBuild with %BDS% / %FrameworkDir% set
     -> **the build pipeline is fully wired**: CodeGear targets loaded,
        DependencyCheck passed, the resource compiler (cgrc.exe) ran... and
        then dcc32 refused command-line compilation again.

So the pipeline is CORRECT and the block sits in the FORWARDER.

Measured, not guessed -- tools/dcc_refusal_probe.py scans the whole Studio
tree, narrow AND utf-16:

    full sentence found in: bin/dcc32.exe, bin/dcc64.exe,
                            bin64/dcc32.exe, bin64/dcc64.exe
    2254 files scanned; the 3.4 MB dcc32370.dll compiler does NOT contain it

So `dcc32.exe` is a 23 KB shim that refuses BEFORE the real compiler is
reached, and `dcc32370.dll` sits there intact. That is why this machine can
never compile from the command line as installed -- and why the shim is NOT
worked around here: driving an unlicensed compiler directly is a licence
question first and a support question second. Recorded, not circumvented.

CORRECTION to an earlier note in this file: the refusal text was first reported
as "not present in the exe either". That was a search bug, not a fact -- the
string is stored UTF-16 and the first pass compared latin-1 bytes only. It IS
in the exe, which is what makes the forwarder the gate.

EXIT CODES
==========
  0  compiled, no errors
  3  BLOCKED -- the compiler's own words are echoed, so a reader can tell
     "your build is broken" from "your compiler may not run". Deliberately
     distinct from 1: reporting a licence wall as a compile failure sends
     people hunting for errors in code that is perfectly fine.
  1  real compile errors

Usage:
    python tools/dcc_build.py
    python tools/dcc_build.py --dry-run     # show the command, run nothing
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Source"
WRAPPER = SRC / "DelphiBuild.proj"

# Framework MSBuild, newest first. `dotnet msbuild` is deliberately absent: it
# is .NET Core and cannot load CodeGear's .NET Framework 4.x task assemblies
# (that is attempt 3 above).
_MSBUILD_CANDIDATES = (
    r"C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
    r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
    r"C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
    r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe",
    r"C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe",
)

_STUDIO_GLOBS = (
    r"C:\Program Files (x86)\Embarcadero\Studio",
    r"C:\Program Files\Embarcadero\Studio",
)

_LICENCE_TEXT = "does not support command line compiling"


def find_msbuild():
    for p in _MSBUILD_CANDIDATES:
        if pathlib.Path(p).exists():
            return p
    return None


def find_studio():
    for base in _STUDIO_GLOBS:
        root = pathlib.Path(base)
        if not root.exists():
            continue
        for v in sorted(root.glob("*")):
            if (v / "bin" / "CodeGear.Delphi.Targets").exists():
                return v
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="print the command and environment, run nothing")
    args = ap.parse_args()

    msbuild = find_msbuild()
    studio = find_studio()
    print("msbuild :", msbuild or "NOT FOUND")
    print("studio  :", studio or "NOT FOUND")
    if not msbuild or not studio:
        print("\nfront-line A cannot run here: need a licensed Delphi + MSBuild")
        return 3

    env = dict(os.environ)
    env["BDS"] = str(studio)
    env["FrameworkDir"] = str(studio / "framework")
    env["FrameworkVersion"] = "v4.0.30319"

    cmd = [msbuild, str(WRAPPER), "-t:Build", "-p:Config=Debug",
           "-p:Platform=Win32", "-v:m", "-nologo",
           "-p:StudioBin=%s" % (studio / "bin")]

    if args.dry_run:
        print("\nwould run (cwd=%s):" % SRC)
        print("  " + " ".join(cmd))
        print("\nenv: BDS=%s" % env["BDS"])
        print("     FrameworkDir=%s" % env["FrameworkDir"])
        return 0

    print("\nrunning build...\n")
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=str(SRC), env=env)
    out = (p.stdout or "") + (p.stderr or "")

    licence = [l for l in out.splitlines() if _LICENCE_TEXT in l]
    # MSB4011 ("cannot be imported again") is a known, harmless consequence of
    # DelphiBuild.proj importing targets the .dproj imports again. It is not a
    # compile error and must never be counted as one.
    errors = [l for l in out.splitlines()
              if re.search(r"\berror\b", l, re.I) and "MSB4011" not in l]

    for l in [x for x in out.splitlines() if x.strip()][-6:]:
        print("  |", l[:150])

    if licence:
        print("\n" + "=" * 64)
        print("FRONT-LINE A BLOCKED BY LICENCE, NOT BY CODE")
        print("=" * 64)
        print("The MSBuild pipeline is fully wired: CodeGear targets loaded,")
        print("DependencyCheck passed, cgrc.exe ran. dcc32 then refused:")
        print("    " + licence[0].strip())
        print("\nThis Studio install does not permit command-line compilation.")
        print("Needed: an activated Studio / licensed seat, or a build from the")
        print("IDE itself. No further configuration on this machine will change")
        print("it -- so the interactive smoke test (EditorList Tab/file sync,")
        print("devCFG cp1252 code page) remains genuinely OUTSTANDING.")
        return 3

    print("\n%d error line(s); exit=%d" % (len(errors), p.returncode))
    return 0 if p.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())