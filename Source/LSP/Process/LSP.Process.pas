unit LSP.Process;

interface

uses
  {$IFDEF FPC}
  Classes, SysUtils;
  {$ELSE}
  System.Classes, System.SysUtils;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Process abstraction for the LSP transport (Phase-F / F1-b).
//
// Purpose: remove the last Win32 dependency (CreateProcess + anonymous pipes)
// from LSP.Transport so the whole transport can be compiled and exercised by
// the headless Free Pascal CI on Linux *and* Windows.
//
// Contract notes:
//   * Read is BLOCKING (like ReadFile on a pipe): it returns as soon as at
//     least one byte is available, 0 on end-of-stream (child exited / pipe
//     closed) and -1 on a hard error. Blocking semantics are exactly what the
//     transport read thread needs, and they are the only semantics that are
//     portable without a platform-specific "is data ready" probe.
//   * Unblocking a reader is done by Terminate: the child dies, the pipe
//     reaches EOF and Read returns 0. This mirrors the pre-abstraction
//     behaviour of closing the read handle.
//   * Neither the stdin nor stdout of the child is a TTY; stderr is folded
//     into stdout so clangd diagnostics surface in the same stream.
// ---------------------------------------------------------------------------

type
  ILspProcess = interface
    ['{7C1B0A62-9E4D-4C2E-9C3B-1F0A5D7E4B21}']
    // Read at most Length(ABuf) bytes. Returns bytes read, 0 at EOF, -1 error.
    function Read(out ABuf: TBytes): Integer;
    // Write the whole buffer; returns False on a broken pipe.
    function Write(const ABuf: TBytes): Boolean;
    // Convenience: UTF-8 encode and write.
    function WriteText(const AText: string): Boolean;
    // Ask the child to stop; must unblock a pending Read.
    procedure Terminate;
    function Running: Boolean;
    // Human-readable reason of the last failure (empty when there was none).
    function LastError: string;
  end;

  ILspProcessFactory = interface
    ['{2D8C4F17-5A6B-4E8D-9F10-3C7A2B6D9E44}']
    // Start AExe with AParams in AWorkDir. Returns nil on failure.
    function Start(const AExe, AParams, AWorkDir: string): ILspProcess;
  end;

implementation

end.