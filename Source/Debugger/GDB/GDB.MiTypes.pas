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

unit GDB.MiTypes;

interface

// Shared record types for the GDB/MI subsystem.
// Kept in a dedicated unit to avoid circular dependencies between the
// parser (GDB.MiParser), the command scheduler (Debugger.Scheduler) and the
// variable manager (Debugger.VariableManager).

type
  // Variable object data (from -var-create / -var-update / -var-evaluate)
  TMiVariableData = record
    Name: string;
    TypeName: string;
    Value: string;
    NumberOfChildren: Integer;
    IsConstant: Boolean;
    Format: string;
  end;

  // Breakpoint data (from ^done,bkpt={...})
  TMiBreakpointData = record
    Number: Integer;
    TypeName: string;
    Enabled: Boolean;
    Address: string;
    FileName: string;
    Line: Integer;
  end;

  // Unified MI record passed to command callbacks.
  TMiRecord = record
    TokenId: Integer;
    ResultClass: string;  // 'done' / 'error' / 'running' (^ records)
    AsyncClass: string;   // 'stopped' / 'breakpoint-modified' / ... (* records)
    Message: string;
    Success: Boolean;
    RawLine: string;
    Variable: TMiVariableData;
    Breakpoint: TMiBreakpointData;
  end;

  // Legacy alias kept for compatibility with older references.
  TParserRecord = TMiRecord;

implementation

end.