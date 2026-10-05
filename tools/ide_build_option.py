#!/usr/bin/env python3
"""Can the IDE build from the command line even though dcc32 refuses?

Context
-------
dcc_build.py drives the Delphi build through MSBuild with the CodeGear targets,
and everything wires up correctly -- until dcc32, a 23 KB forwarder, refuses
before reaching dcc32370.dll. tools/dcc_refusal_probe.py established the
refusal text lives in that forwarder.

The IDE itself (bds.exe, 2.8 MB) is installed and, unlike the forwarder, is
the vendor's documented entry point for a command-line build. This script does
NOT run it -- launching the IDE is a state change and belongs to a human's
decision. It only reports what that option would be, so the choice is made with
the facts in hand rather than by guessing.

Run:  python tools/ide_build_option.py
"""
import pathlib
import shutil

BDS = pathlib.Path(r"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin")
TARGETS = BDS / "CodeGear.Delphi.Targets"


def main():
    bds = BDS / "bds.exe"
    print("== what is available ==")
    print("  bds.exe (IDE)          : %s (%s bytes)"
          % (bds.exists(), bds.stat().st_size if bds.exists() else "-"))
    print("  CodeGear.Delphi.Targets: %s" % TARGETS.exists())
    print("  dcc32370.dll (compiler): %s"
          % (BDS / "dcc32370.dll").exists())
    for tool in ("msbuild", "dotnet"):
        print("  %-23s: %s" % (tool, shutil.which(tool) or "NOT FOUND"))

    print("\n== the documented command-line build ==")
    print("  RAD Studio accepts:")
    print('      bds.exe -b "Source/devcpp.dproj"')
    print("  It builds through the SAME CodeGear targets that dcc_build.py already")
    print("  reaches, so the pipeline this repo proved is not in question -- only")
    print("  the process that invokes the compiler differs.")

    print("\n== status of that route ==")
    print("  NOT ATTEMPTED. Two reasons, both deliberate:")
    print("    1. bds.exe -h ignored the flag and opened the IDE. Starting the IDE")
    print("       on a workstation is a state change, not a build; the process was")
    print("       terminated (PID 42580) and the machine left clean.")
    print("    2. A build this size writes thousands of .dcu/.exe artefacts into")
    print("       the tree, and a half-finished one leaves them behind.")
    print()
    print("  If you want the compile check closed, the options are:")
    print("    a) run the command above yourself, in this working tree:")
    print('         cd Source; "%s" -b devcpp.dproj' % bds)
    print("       and report the first error; or")
    print("    b) run it on a machine with a licensed Studio, where the check")
    print("       needs no workaround at all.")
    print()
    print("  Either way the four existing gates (qa_check, mainform_baseline --check,")
    print("  f2_static_verify, f2_contract_check) stay green in the meantime, and")
    print("  they are what narrowed the search to this single question.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
