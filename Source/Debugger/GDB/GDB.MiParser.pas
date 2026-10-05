{
    This file is part of Dev-C++
    Copyright (c) 2004 Bloodshed Software

    Dev-C++ is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Dev-C++ is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Dev-C++; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
}

unit GDB.MiParser;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes,
  {$ELSE}
  System.SysUtils, System.Classes,
  {$ENDIF}
  Core.Events, GDB.MiTypes;

// GDB Machine Interface (MI) parser.
// Feeds raw GDB/MI output and dispatches whole records to a callback.
// This is intentionally low-level: it performs tokenisation (token id,
// result/async class, message) and leaves field-level parsing to the
// consumers (scheduler / variable manager).

type
  TMiTokenType = (mtAsync, mtResult, mtStop, mtBreakpoint, mtVariable, mtUnknown);
  TMiParserState = (psIdle, psInRecord);

  // Low-level "raw token" callback (type + text payload).
  TMiParseEvent = procedure(const TokenType: TMiTokenType; const Data: string) of object;

  // Structured record callback (whole record, already tokenised).
  TMiRecordEvent = procedure(const ARecord: TMiRecord) of object;

  TMiParser = class
  private
    FOnParse: TMiParseEvent;
    FOnRecord: TMiRecordEvent;
    FBuffer: string;
    FState: TMiParserState;
    FTokenIdCounter: Integer;
    procedure DispatchRecord(const ALine: string);
  public
    constructor Create;
    destructor Destroy; override;

    // Feed raw bytes/text and dispatch complete records.
    procedure Feed(const Data: string);
    function NextTokenId: Integer;

    property OnParse: TMiParseEvent read FOnParse write FOnParse;
    property OnRecord: TMiRecordEvent read FOnRecord write FOnRecord;
  end;

function CreateMiParser: TMiParser;

implementation

{ TMiParser }

constructor TMiParser.Create;
begin
  inherited Create;
  FBuffer := '';
  FState := psIdle;
  FTokenIdCounter := 0;
end;

destructor TMiParser.Destroy;
begin
  inherited;
end;

function TMiParser.NextTokenId: Integer;
begin
  Inc(FTokenIdCounter);
  Result := FTokenIdCounter;
end;

procedure TMiParser.Feed(const Data: string);
var
  Line: string;
  I: Integer;
begin
  FBuffer := FBuffer + Data;
  // GDB/MI records are newline-terminated.
  I := Pos(#10, FBuffer);
  while I > 0 do
  begin
    Line := Copy(FBuffer, 1, I - 1);
    // Strip a trailing carriage return.
    if (Line <> '') and (Line[Length(Line)] = #13) then
      Line := Copy(Line, 1, Length(Line) - 1);
    Delete(FBuffer, 1, I);
    if Line <> '' then
      DispatchRecord(Line);
    I := Pos(#10, FBuffer);
  end;
end;

procedure TMiParser.DispatchRecord(const ALine: string);
var
  Rec: TMiRecord;
  TokenType: TMiTokenType;
  P: Integer;
  TokenStr: string;
  Rest: string;
begin
  FillChar(Rec, SizeOf(Rec), 0);
  Rec.RawLine := ALine;
  Rec.Success := True;

  Rest := ALine;
  TokenType := mtUnknown;

  // Detect the leading character: digit = token id (result record),
  // '^' = result, '*' = async, '~'/'@'/'&' = stream.
  P := 1;
  if (Rest <> '') and (Rest[1] in ['0'..'9']) then
  begin
    TokenStr := '';
    while (P <= Length(Rest)) and (Rest[P] in ['0'..'9']) do
    begin
      TokenStr := TokenStr + Rest[P];
      Inc(P);
    end;
    Rec.TokenId := StrToIntDef(TokenStr, 0);
    Rest := Copy(Rest, P, MaxInt);
  end;

  if Rest <> '' then
  begin
    case Rest[1] of
      '^':
        begin
          TokenType := mtResult;
          Delete(Rest, 1, 1);
          // Extract result class ("done" / "error" / "running").
          P := 1;
          while (P <= Length(Rest)) and (Rest[P] <> ',') do
            Inc(P);
          Rec.ResultClass := LowerCase(Copy(Rest, 1, P - 1));
          Rec.Message := Copy(Rest, P + 1, MaxInt);
          Rec.Success := Rec.ResultClass <> 'error';
        end;
      '*':
        begin
          TokenType := mtStop; // async out-of-band (most commonly *stopped)
          Delete(Rest, 1, 1);
          P := 1;
          while (P <= Length(Rest)) and (Rest[P] <> ',') do
            Inc(P);
          Rec.AsyncClass := LowerCase(Copy(Rest, 1, P - 1));
          Rec.Message := Copy(Rest, P + 1, MaxInt);
          if Rec.AsyncClass = 'breakpoint-modified' then
            TokenType := mtBreakpoint;
        end;
      '~', '@', '&':
        begin
          TokenType := mtAsync;
          Rec.Message := Rest;
        end;
    else
      TokenType := mtUnknown;
      Rec.Message := Rest;
    end;
  end;

  if Assigned(FOnParse) then
    FOnParse(TokenType, ALine);

  if Assigned(FOnRecord) then
    FOnRecord(Rec);
end;

function CreateMiParser: TMiParser;
begin
  Result := TMiParser.Create;
end;

end.