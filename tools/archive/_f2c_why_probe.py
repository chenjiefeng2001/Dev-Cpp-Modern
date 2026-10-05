import pathlib
import subprocess

FPC = r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"
TMP = pathlib.Path("C:/Windows/Temp")

# Both remaining JsonRpc failures assert `(not TryPopBody(Body)) and (Body =
# 'untouched') and <has-pending>`. Print each conjunct separately rather than
# guessing which one is false.
SRC = r"""program why;
{$mode delphiunicode}{$H+}
uses SysUtils, Classes, LSP.JsonRpc;
var
  D: TLspFrameDecoder;
  B: string;
  W: TBytes;
begin
  { partial frame }
  W := BuildLspFrameBytes('{"split":true}');
  D := TLspFrameDecoder.Create;
  try
    D.Feed(Copy(W, 0, 10));
    B := 'untouched';
    WriteLn('--- partial frame (fed 10 of ', Length(W), ') ---');
    WriteLn('  pop returned    = ', D.TryPopBody(B));
    WriteLn('  Body            = "', B, '"');
    WriteLn('  Body unchanged  = ', B = 'untouched');
    WriteLn('  HasPendingData  = ', D.HasPendingData);
    WriteLn('  PendingBytes    = ', D.PendingBytes);
  finally
    D.Free;
  end;

  { lone malformed header }
  D := TLspFrameDecoder.Create;
  try
    D.Feed(BytesOf('X-Bogus: 1'#13#10#13#10));
    B := 'untouched';
    WriteLn('--- lone malformed header ---');
    WriteLn('  pop returned    = ', D.TryPopBody(B));
    WriteLn('  Body            = "', B, '"');
    WriteLn('  Body unchanged  = ', B = 'untouched');
    WriteLn('  HasPendingData  = ', D.HasPendingData);
    WriteLn('  PendingBytes    = ', D.PendingBytes);
  finally
    D.Free;
  end;
end.
"""

f = TMP / "why.pas"
f.write_text(SRC, encoding="utf-8")
lib = pathlib.Path(r"D:\Git\Dev-Cpp-Modern\Tests\FpcCoreTests\lib\win64")
src = pathlib.Path(r"D:\Git\Dev-Cpp-Modern\Source\LSP\JsonRpc")
r = subprocess.run([FPC, f"-FU{lib}", f"-Fu{src}", f"-FE{TMP}", str(f)],
                   capture_output=True, text=True)
if r.returncode != 0:
    for l in (r.stdout + r.stderr).splitlines()[-5:]:
        print("   ", l[:84])
else:
    run = subprocess.run([str(TMP / "why.exe")], capture_output=True,
                         text=True, timeout=30)
    print(run.stdout.strip()[:900])