#!/usr/bin/env python3
"""
_rewrite_fpc_process.py -- port Lsp.Process.Fpc to FPC's real TProcess API.

WHY A REWRITE AND NOT A PATCH
=============================
The unit was written against Delphi's System.Process.TProcess and has never been
compiled by anything. The first real build (FPC 3.2.2, 2026-10-05) reported:

    Lsp.Process.Fpc.pas(51,52) Wrong number of parameters specified for "Create"
    Lsp.Process.Fpc.pas(53,11) no member "ExeName"
    Lsp.Process.Fpc.pas(60,11) no member "CreatePipes"
    Lsp.Process.Fpc.pas(156,15) no member "Kill"

and a probe confirmed the members are genuinely ABSENT rather than misnamed. The
authority is fcl-process/src/process.txt, shipped with this RTL:

    Constructor Create(AOwner: TComponent)        -- NOT (parent, cmd, env)
    property  Executable       : string
    property  Parameters       : TStringList
    property  Options          : TProcessOptions   -- poUsePipes, poStderrToOutPut
    property  CurrentDirectory : string
    property  Input            : TOutPutPipeStream -- WRITE to the child
    property  Output           : TOutPutPipeStream -- READ from the child
    procedure Execute;                             -- NOT Run / Start
    function  WaitOnExit : Boolean;                -- takes NO timeout
    function  Terminate(AExitCode: Integer): Boolean;

THE DIRECTION INVERSION, WHICH IS THE SUBTLE ONE
=================================================
Delphi names the streams from the PARENT's side: `Input` is what the parent
reads (the child's stdout) and `Output` is what it writes (the child's stdin).
FPC names them from the CHILD's side, which is the opposite.

Keeping Delphi's names in an FPC build therefore does NOT fail to compile in the
read and write paths -- it compiles and drives both pipes BACKWARDS. The
transport would read its own writes and block forever waiting for output that
never arrives. A compiler cannot catch that; a smoke test hangs on it rather
than reporting it. This is the one edit here that would have survived review.

Run: python _rewrite_fpc_process.py
"""
import pathlib
import sys

TARGET = pathlib.Path("Source/LSP/Process/Lsp.Process.Fpc.pas")

EDITS = [
    (
        "  FProc := TProcess.Create(nil, PChar(AParams), []);\n"
        "  try\n"
        "    FProc.ExeName := AExe;\n"
        "    if (AWorkDir <> '') and DirectoryExists(AWorkDir) then\n"
        "      FProc.CurrentDirectory := AWorkDir;\n",

        "  // FPC's TProcess takes only an OWNER. The Delphi three-argument form\n"
        "  // (parent, command line, environment) does not exist in this RTL.\n"
        "  FProc := TProcess.Create(nil);\n"
        "  try\n"
        "    FProc.Executable := AExe;\n"
        "    if AParams <> '' then\n"
        "      FProc.Parameters.Add(AParams);\n"
        "    if (AWorkDir <> '') and DirectoryExists(AWorkDir) then\n"
        "      FProc.CurrentDirectory := AWorkDir;\n",
    ),
    (
        "    FProc.Options := [poUsePipes, poStderrToOutPut];\n"
        "    FProc.CreatePipes;\n"
        "    FProc.Execute;",

        "    // Execute creates the pipes itself when poUsePipes is set: there is no\n"
        "    // CreatePipes in this RTL, and the pipe streams exist only once\n"
        "    // Execute has returned. poNoConsole keeps a console window from\n"
        "    // flashing for a background language server.\n"
        "    FProc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];\n"
        "    FProc.Execute;",
    ),
    (
        "  if not Assigned(FProc.Input) then\n"
        "    Exit; // no pipe: nothing to read\n",

        "  // FPC names the streams from the CHILD's side: Output is its stdout,\n"
        "  // which is what the parent READS. The old code read `Input`, which here\n"
        "  // is the child's stdin -- so the transport would have been reading its\n"
        "  // own writes and blocking forever.\n"
        "  if not Assigned(FProc.Output) then\n"
        "    Exit; // no pipe: nothing to read\n",
    ),
    (
        "    N := FProc.Input.Read(Chunk[0], Length(Chunk));",
        "    N := FProc.Output.Read(Chunk[0], Length(Chunk));",
    ),
    (
        "  if (not Assigned(FProc)) or (not Assigned(FProc.Input)) then\n"
        "    Exit;",

        "  // Input is the child's stdin here: the mirror image of the Read fix.\n"
        "  if (not Assigned(FProc)) or (not Assigned(FProc.Input)) then\n"
        "    Exit;",
    ),
    (
        "      FProc.Terminate;\n"
        "      // Give the child a short grace period, then insist.\n"
        "      FProc.WaitOnExit(1000);\n"
        "      if FProc.Running then\n"
        "        FProc.Kill;\n",

        "      // This RTL has no Kill: Terminate(AExitCode) IS the forceful stop.\n"
        "      // WaitOnExit takes no timeout here, so no grace period is\n"
        "      // requestable -- the port is told to exit and then reaped.\n"
        "      FProc.Terminate(0);\n"
        "      FProc.WaitOnExit;\n",
    ),
]


def main() -> int:
    raw = TARGET.read_bytes()
    crlf = b"\r\n" in raw
    text = raw.decode("utf-8")

    # Normalise to LF before matching. An earlier rewrite of this same file
    # changed its line ending, so a \r\n anchor stopped matching; matching on
    # normalised content is what makes the script idempotent.
    norm = text.replace("\r\n", "\n")
    applied = 0
    for old, new in EDITS:
        c = norm.count(old)
        if c != 1:
            print(f"REFUSING: anchor matched {c} times: "
                  f"{old.splitlines()[0][:64]!r}")
            return 1
        norm = norm.replace(old, new)
        applied += 1

    out = norm.replace("\n", "\r\n") if crlf else norm
    TARGET.write_bytes(out.encode("utf-8"))
    print(f"rewrote {TARGET} ({applied} edit(s)), CRLF preserved={crlf}")
    return 0


if __name__ == "__main__":
    sys.exit(main())