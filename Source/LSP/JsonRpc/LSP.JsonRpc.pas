unit LSP.JsonRpc;

interface

uses
  {$IFDEF FPC}
  Classes, SysUtils;
  {$ELSE}
  System.Classes, System.SysUtils;
  {$ENDIF}

// ---------------------------------------------------------------------------
// LSP base protocol framing (pure Pascal, no Win32, no VCL).
//
// Extracted from LSP.Transport (Phase-F / F1) so that the byte-level framing is
// verifiable on a headless Free Pascal build: this unit is part of
// Tests/FpcCoreTests/FpcCorePortable.lpi and is exercised by the F0 smoke
// tests on both Linux and Windows CI.
//
// Wire format (LSP 3.17 spec):
//   Content-Length: <n>\r\n
//   [Content-Type: ...\r\n]
//   \r\n
//   <n bytes of UTF-8 JSON>
// where <n> is the body length in *bytes*, not characters.
// ---------------------------------------------------------------------------

const
  // Maximum accepted Content-Length. Guards against a corrupted/hostile
  // header turning into a huge allocation (clangd payloads stay far below).
  LSP_MAX_CONTENT_LENGTH = 64 * 1024 * 1024;

// Incremental frame decoder: feed it raw bytes, pull complete JSON bodies out.
type
  TLspFrameDecoder = class
  private
    FBuffer: TBytes;
  public
    constructor Create;
    destructor Destroy; override;

    // Feed raw bytes read from the language server stdout pipe.
    procedure Feed(const AData: TBytes);

    // Pull the next complete message body (UTF-8 decoded) if one is buffered.
    // Returns False when no complete frame is available.
    function TryPopBody(out ABody: string): Boolean;

    // True when a partial frame is buffered (header or body still arriving).
    function HasPendingData: Boolean;

    // Number of buffered bytes not yet forming a complete frame.
    function PendingBytes: Integer;

    // Drop everything buffered (used on disconnect / re-initialise).
    procedure Reset;
  end;

// Build a complete framed message (header + body) as raw bytes.
// AJsonBody is converted to UTF-8; the Content-Length counts the encoded bytes.
function BuildLspFrameBytes(const AJsonBody: string): TBytes;

// REMOVED 2026-10-05: BuildLspFrame(const AJsonBody: string): string
//
// It built TBytes and then converted them to a string with
// TEncoding.Default.GetString. Under -Mdelphiunicode that encoding is UTF-16,
// so the byte sequence was reinterpreted as 16-bit units: a 23-byte frame came
// back with Length 28, and BytesOf on the result produced yet another byte
// sequence. Any caller feeding the result back into the decoder was feeding it
// corrupted data -- which is what the smoke test did, and the decoder
// correctly reported "no complete frame".
//
// The string-returning form cannot be made correct without knowing the
// intended encoding of its result, so callers use BuildLspFrameBytes, which is
// what the wire carries. The diagnostic use it was written for is served by
// TEncoding.UTF8.GetString(BuildLspFrameBytes(...)).

implementation

const
  CRLFCRLF: array[0..3] of Byte = (13, 10, 13, 10);

{ TLspFrameDecoder }

constructor TLspFrameDecoder.Create;
begin
  inherited Create;
  SetLength(FBuffer, 0);
end;

destructor TLspFrameDecoder.Destroy;
begin
  SetLength(FBuffer, 0);
  inherited;
end;

function TLspFrameDecoder.HasPendingData: Boolean;
begin
  Result := Length(FBuffer) > 0;
end;

function TLspFrameDecoder.PendingBytes: Integer;
begin
  Result := Length(FBuffer);
end;

procedure TLspFrameDecoder.Reset;
begin
  SetLength(FBuffer, 0);
end;

procedure TLspFrameDecoder.Feed(const AData: TBytes);
var
  OldLen: Integer;
begin
  OldLen := Length(FBuffer);
  if OldLen = 0 then
  begin
    FBuffer := AData;
    Exit;
  end;
  if Length(AData) = 0 then
    Exit;
  SetLength(FBuffer, OldLen + Length(AData));
  Move(AData[0], FBuffer[OldLen], Length(AData));
end;

// Decode UTF-8 bytes WITHOUT raising on invalid input.
//
// A framed JSON-RPC body is arbitrary content from a language server, and a
// truncated multi-byte sequence or a lone continuation byte is entirely legal
// on the wire. TEncoding.UTF8.GetString reports that as an EEncodingError, which
// killed the headless transport with an unhandled exception -- the first defect
// in this unit that compiled, linked and passed every static gate.
//
// The fallback is String(Bytes), which preserves each byte one-to-one in the
// low half of a code unit. That is a lossy view of non-UTF-8 text, and it is
// stated here rather than hidden: a caller needing exact bytes should read
// FBuffer. For the framing test the content is ASCII, so the fallback never
// fires and the error path is exercised only by malformed input, which is
// precisely when continuing is the right answer.
function DecodeUtf8Lenient(const ABytes: TBytes): string;
begin
  if Length(ABytes) = 0 then
    Exit('');
  try
    Result := TEncoding.UTF8.GetString(ABytes);
  except
    on E: EEncodingError do
      Result := String(ABytes);
  end;
end;

function TLspFrameDecoder.TryPopBody(out ABody: string): Boolean;
var
  I: Integer;
  HeaderEnd: Integer;
  ContentLength: Integer;
  HeaderStr: string;
  ClPos: Integer;
  ClValue: string;
  BodyStart: Integer;
  Remaining: Integer;
begin
  Result := False;
  // ABody is NOT cleared on the failure path. Two smoke checks seed
  // `Body := 'untouched'` and assert it survives a failed pop, which is
  // how a caller proves the `out` parameter is only written on success.
  // Clearing it unconditionally defeats exactly that, and only a RUN
  // could reveal it: the value written is valid and the type is right.

  // Rescan loop: a malformed header is dropped and scanning continues inside
  // this very call, which is exactly what the previous inline implementation
  // did (`Continue` inside `repeat ... until False`). Termination is guaranteed
  // because every iteration either returns or shrinks the buffer by >= 4 bytes.
  while True do
  begin
    // 1) locate the CRLFCRLF that terminates the header block
    HeaderEnd := -1;
    I := 0;
    // 0-based: FBuffer[I] is element I. The previous scan compared FBuffer[I]
    // against CRLFCRLF[0] and then FBuffer[I+1] against [1], which is a MIX of
    // the two conventions -- it matched only by accident on some inputs and
    // started one byte late on others, so a frame this same unit had built was
    // reported as incomplete.
    while I + 3 < Length(FBuffer) do
    begin
      if (FBuffer[I] = CRLFCRLF[0]) and (FBuffer[I + 1] = CRLFCRLF[1]) and
         (FBuffer[I + 2] = CRLFCRLF[2]) and (FBuffer[I + 3] = CRLFCRLF[3]) then
      begin
        HeaderEnd := I;
        Break;
      end;
      Inc(I);
    end;
    if HeaderEnd < 0 then
      Exit; // header still incomplete

    // 2) read Content-Length (the header is ASCII, so the scan below is safe;
    //    the original implementation used a case-sensitive Pos()).
    // FPC's GetString takes no Length: slice the bytes first.
    HeaderStr := DecodeUtf8Lenient(Copy(FBuffer, 0, HeaderEnd));
    ContentLength := 0;
    ClPos := Pos('Content-Length:', HeaderStr);
    if ClPos > 0 then
    begin
      ClValue := Trim(Copy(HeaderStr, ClPos + Length('Content-Length:'), MaxInt));
      if ClValue <> '' then
        ContentLength := StrToIntDef(ClValue, 0);
    end;
    if ContentLength <= 0 then
    begin
      // Malformed header: discard the header block and rescan.
      Remaining := Length(FBuffer) - (HeaderEnd + 4);
      if Remaining > 0 then
        Move(FBuffer[HeaderEnd + 4], FBuffer[0], Remaining);
      SetLength(FBuffer, Remaining);
      continue;
    end;
    if ContentLength > LSP_MAX_CONTENT_LENGTH then
    begin
      // Refuse absurd sizes: drop everything rather than allocating blindly.
      Reset;
      Exit;
    end;

    // 3) body complete yet?
    BodyStart := HeaderEnd + 4;
    if Length(FBuffer) < BodyStart + ContentLength then
      Exit; // wait for more bytes

    ABody := DecodeUtf8Lenient(Copy(FBuffer, BodyStart, ContentLength));
    Remaining := Length(FBuffer) - (BodyStart + ContentLength);
    if Remaining > 0 then
      Move(FBuffer[BodyStart + ContentLength], FBuffer[0], Remaining);
    SetLength(FBuffer, Remaining);
    Result := True;
    Exit;
  end;
end;

{ Framing helpers }

function BuildLspFrameBytes(const AJsonBody: string): TBytes;
var
  Utf8Body: TBytes;
  Header: string;
  Framed: TBytes;
  ByteCount: Integer;
begin
  // Content-Length counts UTF-8 *bytes*, not characters.
  ByteCount := TEncoding.UTF8.GetByteCount(AJsonBody);
  // FPC's TEncoding.GetBytes takes ONE argument and RETURNS the array
  // (rtl/.../sysencoding.inc). The Delphi form used here filled a
  // caller-supplied buffer at an offset, and does not exist in this RTL.
  Utf8Body := TEncoding.UTF8.GetBytes(AJsonBody);

  Header := 'Content-Length: ' + IntToStr(ByteCount) + #13#10#13#10;

  // Build the header as BYTES. The old
  //     Move(Header[1], Framed[0], Length(Header));
  // copied string ELEMENTS into a byte buffer: 1 byte each under AnsiString,
  // 2 under UnicodeString, and wrong in both cases. It compiled cleanly and
  // failed only at RUN time, as EEncodingError from the decoder.
  Framed := TEncoding.UTF8.GetBytes(Header);

  // The header must be COPIED, not merely counted. Sizing Result and writing
  // only the body past it produces a correctly-sized frame whose header is all
  // zeros -- which is exactly what a byte-level comparison showed:
  //     want: 67 111 110 116 ... 13 10 13 10
  //     got:   0   0   0   0 ...  0  0  0  0
  SetLength(Result, Length(Framed) + ByteCount);
  if Length(Framed) > 0 then
    Move(Framed[0], Result[0], Length(Framed));
  if ByteCount > 0 then
    Move(Utf8Body[0], Result[Length(Framed)], ByteCount);
end;

end.