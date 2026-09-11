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

unit Debugger.Scheduler;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  GDB.MiParser, GDB.MiTypes;

// Command scheduler for GDB/MI.
// OWNS command token numbering and matches responses to the commands that
// requested them. The actual pipe I/O is injected through the OnSend hook so
// this unit stays free of any MainForm / debugger-window dependency.

type
  TSendCommandCallback = reference to procedure(const ARecord: TMiRecord);

  TCommandToken = Integer;

  TWaitingCommand = record
    Token: TCommandToken;
    Command: string;
    Callback: TSendCommandCallback;
    GdbRecord: TMiRecord;
    Handled: Boolean;
    Timeout: TDateTime;
  end;

  TSchedulerState = (ssIdle, ssSending, ssWaiting, ssError);
  TSchedulerStateEvent = procedure(const AState: TSchedulerState) of object;
  TCommandDoneEvent = procedure(const AToken: TCommandToken; const ASuccess: Boolean) of object;
  // Implemented by the owner: write the (already token-prefixed) command line.
  TCommandSendEvent = procedure(const AToken: TCommandToken; const ACommand: string) of object;

  TDebuggerScheduler = class
  private
    FState: TSchedulerState;
    FTokenCounter: Integer;
    FWaitingQueue: TList<TWaitingCommand>;
    FLock: TCriticalSection;
    FOnStateChange: TSchedulerStateEvent;
    FOnCommandDone: TCommandDoneEvent;
    FOnSend: TCommandSendEvent;
    FTimeoutSec: Integer;
    FGDBProcess: pointer;
    function GenerateToken: TCommandToken;
    procedure SetState(const AState: TSchedulerState);
  public
    constructor Create; overload;
    constructor Create(AGDBProcess: pointer); overload;
    destructor Destroy; override;

    function SendCommand(const ACommand: string; ACallback: TSendCommandCallback): TCommandToken;
    procedure ProcessResponse(const AResponse: string);
    procedure CheckTimeouts;
    procedure CancelCommand(const AToken: TCommandToken);
    procedure CancelAll;
    procedure ClearHandled;

    property State: TSchedulerState read FState;
    property OnStateChange: TSchedulerStateEvent read FOnStateChange write FOnStateChange;
    property OnCommandDone: TCommandDoneEvent read FOnCommandDone write FOnCommandDone;
    property OnSend: TCommandSendEvent read FOnSend write FOnSend;
  end;

var
  DebuggerScheduler: TDebuggerScheduler;

procedure InitializeDebuggerScheduler;
function SendGDBCommandWait(const ACommand: string; const ATimeoutSec: Integer = 5;
  out ARecord: TMiRecord): Boolean;

implementation

{ TDebuggerScheduler }

constructor TDebuggerScheduler.Create;
begin
  inherited Create;
  FTokenCounter := 0;
  FWaitingQueue := TList<TWaitingCommand>.Create;
  FLock := TCriticalSection.Create;
  FState := ssIdle;
  FTimeoutSec := 5;
end;

constructor TDebuggerScheduler.Create(AGDBProcess: pointer);
begin
  Create;
  FGDBProcess := AGDBProcess;
end;

destructor TDebuggerScheduler.Destroy;
begin
  try
    CancelAll;
  finally
    FLock.Free;
    FWaitingQueue.Free;
    inherited;
  end;
end;

function TDebuggerScheduler.GenerateToken: TCommandToken;
begin
  Inc(FTokenCounter);
  Result := FTokenCounter;
end;

procedure TDebuggerScheduler.SetState(const AState: TSchedulerState);
begin
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChange) then
    FOnStateChange(FState);
end;

function TDebuggerScheduler.SendCommand(const ACommand: string;
  ACallback: TSendCommandCallback): TCommandToken;
var
  Waiting: TWaitingCommand;
  FullCommand: string;
begin
  Result := 0;
  FLock.Enter;
  try
    Result := GenerateToken;
    FullCommand := Format('%d-%s', [Result, ACommand]);

    Waiting.Token := Result;
    Waiting.Command := ACommand;
    Waiting.Callback := ACallback;
    Waiting.Handled := False;
    Waiting.Timeout := Now + FTimeoutSec / SecsPerDay;
    FillChar(Waiting.GdbRecord, SizeOf(Waiting.GdbRecord), 0);

    FWaitingQueue.Add(Waiting);
    SetState(ssSending);
  finally
    FLock.Leave;
  end;

  // Write outside the lock so a slow pipe cannot stall the scheduler.
  if Assigned(FOnSend) then
    FOnSend(Result, FullCommand);
end;

procedure TDebuggerScheduler.ProcessResponse(const AResponse: string);
var
  Token: TCommandToken;
  TokenPos: Integer;
  TokenStr: string;
  I: Integer;
  Waiting: TWaitingCommand;
  Rec: TMiRecord;
  Found: Boolean;
begin
  FLock.Enter;
  try
    FillChar(Rec, SizeOf(Rec), 0);
    Rec.RawLine := AResponse;

    // Extract token id: digits immediately before '^'.
    TokenPos := Pos('^', AResponse);
    if TokenPos > 0 then
    begin
      TokenStr := Copy(AResponse, 1, TokenPos - 1);
      Token := StrToIntDef(TokenStr, 0);
      Rec.TokenId := Token;

      // Class keywords.
      if Pos('^done', AResponse) = 1 then
        Rec.ResultClass := 'done'
      else if Pos('^error', AResponse) = 1 then
      begin
        Rec.ResultClass := 'error';
        Rec.Success := False;
      end
      else if Pos('^running', AResponse) = 1 then
        Rec.ResultClass := 'running';
      Rec.Success := Rec.ResultClass <> 'error';
    end
    else
    begin
      // Out-of-band / async record: not associated with a command token.
      if (AResponse <> '') and (AResponse[1] = '*') then
        Rec.AsyncClass := Copy(AResponse, 2, MaxInt);
      if Assigned(FOnCommandDone) then
        FOnCommandDone(0, True);
      if FWaitingQueue.Count = 0 then
        SetState(ssIdle);
      Exit;
    end;

    Found := False;
    for I := 0 to FWaitingQueue.Count - 1 do
    begin
      Waiting := FWaitingQueue[I];
      if Waiting.Token = Token then
      begin
        Waiting.GdbRecord := Rec;
        Waiting.Handled := True;
        FWaitingQueue[I] := Waiting;
        if Assigned(Waiting.Callback) then
          Waiting.Callback(Rec);
        FWaitingQueue.Delete(I);
        Found := True;
        Break;
      end;
    end;

    if Assigned(FOnCommandDone) then
      FOnCommandDone(Token, Found and Rec.Success);

    if FWaitingQueue.Count = 0 then
      SetState(ssIdle);
  finally
    FLock.Leave;
  end;
end;

procedure TDebuggerScheduler.CheckTimeouts;
var
  I: Integer;
  Waiting: TWaitingCommand;
  TimedOut: Boolean;
begin
  FLock.Enter;
  try
    TimedOut := False;
    for I := FWaitingQueue.Count - 1 downto 0 do
    begin
      Waiting := FWaitingQueue[I];
      if (Now > Waiting.Timeout) and not Waiting.Handled then
      begin
        FWaitingQueue.Delete(I);
        TimedOut := True;
        if Assigned(FOnCommandDone) then
          FOnCommandDone(Waiting.Token, False);
      end;
    end;
    if TimedOut and (FWaitingQueue.Count = 0) then
      SetState(ssIdle);
  finally
    FLock.Leave;
  end;
end;

procedure TDebuggerScheduler.CancelCommand(const AToken: TCommandToken);
var
  I: Integer;
  Waiting: TWaitingCommand;
  Done: Boolean;
begin
  FLock.Enter;
  try
    Done := False;
    for I := 0 to FWaitingQueue.Count - 1 do
    begin
      Waiting := FWaitingQueue[I];
      if Waiting.Token = AToken then
      begin
        FWaitingQueue.Delete(I);
        Done := True;
        Break;
      end;
    end;
    if Done then
    begin
      if Assigned(FOnCommandDone) then
        FOnCommandDone(AToken, False);
      if FWaitingQueue.Count = 0 then
        SetState(ssIdle);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TDebuggerScheduler.CancelAll;
var
  Waiting: TWaitingCommand;
begin
  FLock.Enter;
  try
    while FWaitingQueue.Count > 0 do
    begin
      Waiting := FWaitingQueue[0];
      FWaitingQueue.Delete(0);
      if Assigned(FOnCommandDone) then
        FOnCommandDone(Waiting.Token, False);
    end;
    SetState(ssIdle);
  finally
    FLock.Leave;
  end;
end;

procedure TDebuggerScheduler.ClearHandled;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := FWaitingQueue.Count - 1 downto 0 do
      if FWaitingQueue[I].Handled then
        FWaitingQueue.Delete(I);
  finally
    FLock.Leave;
  end;
end;

procedure InitializeDebuggerScheduler;
begin
  if not Assigned(DebuggerScheduler) then
    DebuggerScheduler := TDebuggerScheduler.Create;
end;

function SendGDBCommandWait(const ACommand: string; const ATimeoutSec: Integer;
  out ARecord: TMiRecord): Boolean;
var
  Scheduler: TDebuggerScheduler;
  Token: TCommandToken;
  Captured: Boolean;
begin
  Result := False;
  FillChar(ARecord, SizeOf(ARecord), 0);
  Captured := False;

  Scheduler := TDebuggerScheduler.Create;
  try
    Token := Scheduler.SendCommand(ACommand,
      procedure(const AREc: TMiRecord)
      begin
        ARecord := AREc;
        Captured := True;
      end);
    // Without a real message pump/pipe this cannot actually wait; the caller
    // is expected to drive ProcessResponse externally. Return success only if
    // a synchronous response was somehow already delivered.
    Result := Captured;
  finally
    Scheduler.Free;
  end;
end;

initialization
  DebuggerScheduler := nil;

finalization
  if Assigned(DebuggerScheduler) then
    FreeAndNil(DebuggerScheduler);

end.