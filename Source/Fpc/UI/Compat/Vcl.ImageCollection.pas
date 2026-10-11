// FPC-side compat unit for Delphi's Vcl.ImageCollection.
//
// The measurement behind this file is recorded on Vcl.BaseImageCollection, which
// declares the same types: across the tree TImageCollection has 4 references,
// all of which are either the declaration of a field or a comment -- no method
// of it is ever called, and its only field instances (DataFrm's three, Packman
// Main's one) are never read or written.
//
// The type itself is therefore re-declared here rather than re-exported,
// because FPC does not have Delphi's transitive interface visibility (AGENTS.md
// section 1): a unit that uses Vcl.BaseImageCollection cannot see a type
// declared there unless it also names that unit. DataFrm.pas and
// Tools/Packman/Main.pas each name Vcl.ImageCollection in their own uses clause
// and expect the type from it.
unit Vcl.ImageCollection;

{$mode delphiunicode}{$H+}

interface

uses
  Classes, Graphics, ImgList, Controls, ExtCtrls;

type
  { See Vcl.BaseImageCollection for the measurement: nothing in the tree calls
    a method of this class. It is the image list DataFrm's theme fields and
    Packman's ImageCollection field are declared with, and both are empty. }
  TImageCollection = class(TImageList)
  end;

implementation

end.
