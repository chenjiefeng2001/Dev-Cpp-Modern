unit LSP.Process.Factory;

interface

uses
  {$IFDEF FPC}
  Lsp.Process;
  {$ELSE}
  LSP.Process;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Selects the process implementation for the current compiler.
//
//   Delphi (Windows) : LSP.Process.Win32 -- the original CreateProcess +
//                      anonymous pipe implementation, moved verbatim.
//   Free Pascal       : LSP.Process.Fpc   -- RTL TProcess, so the same code
//                      path runs headless on Linux and Windows in CI.
//
// Because the Win32 unit is only referenced in the non-FPC branch, this
// selector itself stays free of Winapi/VCL and may be compiled by FPC.
// tools/fpc_artifact_check.py enforces the same rule on the project files.
// ---------------------------------------------------------------------------

function CreateDefaultLspProcessFactory: ILspProcessFactory;

implementation

uses
{$IFDEF FPC}
  {$IFDEF FPC}
  Lsp.Process.Fpc;
  {$ELSE}
  LSP.Process.Fpc;
  {$ENDIF}
{$ELSE}
  LSP.Process.Win32;
{$ENDIF}

function CreateDefaultLspProcessFactory: ILspProcessFactory;
begin
{$IFDEF FPC}
  Result := TFpcLspProcessFactory.Create;
{$ELSE}
  Result := TWin32LspProcessFactory.Create;
{$ENDIF}
end;

end.