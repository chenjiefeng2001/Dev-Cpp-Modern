unit LSP.Client.UiQueue;

{ A FIFO of payloads waiting to run on the UI thread, for the LSP client
  managers.

  Why this exists
  ---------------
  These managers post their response handling to the UI thread with

      TThread.Queue(nil,
        procedure
        begin
          ProcessResponseOnUIThread(AMessage, ReqId);
        end);

  FPC 3.2.2 cannot express that at all -- not in objfpc mode, not in delphi
  mode, and not with the anonymousfunctions mode switch. `reference to` is
  simply absent from this compiler:

      Error: Identifier not found "reference"

  TThread.Queue needs a `procedure of object`, and there is no way to produce
  one inline. (TThread.CreateAnonymousThread has the mirror-image problem: it
  takes a TProcedure, a routine with no Self, and a plain method is rejected
  outright -- "Got ...procedure of object..., expected ...procedure...".)

  So the closure becomes a real method and the payload becomes an argument that
  is stored until the queued call runs. The Delphi branch of each call site
  keeps its original closure untouched; only the FPC branch changes.

  Why a LIST and not a single payload field
  -----------------------------------------
  Two responses can arrive before the queue drains. With one field pair the
  second post would overwrite the first and the first message would be sent
  twice. This is the same reasoning that put FPendingSends in TLspTransport.

  Why the payload cannot live in the queued call's frame
  ------------------------------------------------------
  The queued call runs after the posting frame has returned. A captured
  reference would dangle by then -- so the payload is copied into this queue
  at post time, not referenced from it.
}

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections
  {$ENDIF};

{ What a posted call means. Each manager maps these onto its own methods; the
  queue deliberately does not know what they do. }
type
  TLspUiCallKind = (lsucNoResult, lsucProcessResponse);

type
  TLspUiCall = record
    Kind: TLspUiCallKind;
    Message: string;
    ReqId: Integer;
  end;

type
  TLspUiQueue = class
  private
    FItems: TList<TLspUiCall>;
  public
    destructor Destroy; override;
    procedure Post(AKind: TLspUiCallKind; const AMessage: string; AReqId: Integer);
    { Takes the oldest pending call. Returns False when nothing is pending,
      which is the normal outcome of a queued call whose work a preceding
      queued call already drained. }
    function Take(out ACall: TLspUiCall): Boolean;
  end;

implementation

destructor TLspUiQueue.Destroy;
begin
  FreeAndNil(FItems);
  inherited Destroy;
end;

procedure TLspUiQueue.Post(AKind: TLspUiCallKind; const AMessage: string;
  AReqId: Integer);
var
  Call: TLspUiCall;
begin
  if not Assigned(FItems) then
    FItems := TList<TLspUiCall>.Create;
  Call.Kind := AKind;
  Call.Message := AMessage;
  Call.ReqId := AReqId;
  FItems.Add(Call);
end;

function TLspUiQueue.Take(out ACall: TLspUiCall): Boolean;
begin
  Result := False;
  if not Assigned(FItems) or (FItems.Count = 0) then
    Exit;
  ACall := FItems[0];
  FItems.Delete(0);
  Result := True;
end;

end.
