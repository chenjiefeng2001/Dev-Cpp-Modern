unit Vcl.VirtualImage;

// ---------------------------------------------------------------------------
// FPC compatibility shim: `uses Vcl.VirtualImage` resolves HERE, on the FPC side
// only.
//
// WHY THIS FILE EXISTS
// ===================
// Four Delphi-tree units say `uses Vcl.VirtualImage` (DataFrm, EnviroFrm,
// LangFrm, main) and two of them declare fields of that type. The obvious fix is
// to rewrite those clauses to `uses LclVirtualImage` -- and that would break the
// Delphi build, because all four live in the Delphi tree and LclVirtualImage.pas
// does not exist there. `main.pas` is in devcpp.dpr. tools/qa_check.py
// --profile delphi exists to keep exactly that contamination out.
//
// So the source-visible unit name stays, and the FPC SEARCH PATH supplies the
// FPC-side implementation. This is the mechanism Sprint F3-6 already used for
// TSynRCSyn: Source/DataFrm.pas still says `uses SynHighlighterRC`, and
// Source/Fpc/UI/Controls/SynHighlighterRc.pas declares a unit of that same name,
// so -Fu order decides which one the compiler sees. The Delphi tree was never
// edited there, and it is not edited here.
//
// WHY IT MUST BE A TYPE ALIAS, NOT A SUBCLASS
// ============================================
// This is the one detail that decides whether the mechanism works, and it was
// settled by compiling both shapes rather than by reading them:
//
//   type TVirtualImage = class(TLclVirtualImage) end;   -> Error: Incompatible
//                                                             types: got
//                                                             "TLclVirtualImage"
//                                                             expected
//                                                             "TVirtualImage"
//   type TVirtualImage = TLclVirtualImage;              -> compiles and runs
//
// A subclass is a DIFFERENT type. DFM streaming assigns the LCL-based component
// into a field the Delphi tree declares as `TVirtualImage`
// (EnviroFrm.viThemePreview, LangFrm.VirtualImageTheme,
// main.ImageEmbarcadero), so a subclass makes that assignment a type error. An
// alias makes the two names denote one type, which is what streaming requires.
//
// NO IMPLEMENTATION IS COPIED. TLclVirtualImage lives in LclVirtualImage.pas and
// carries the ImageCollection/ImageIndex/Proportional surface that LCL's TImage
// lacks; this file adds no class and no property. It is a name binding.
//
// MEASURED, NOT ASSUMED
// =====================
// tools/f3_namespace_alias.py classified `Vcl.VirtualImage` as group R --
// "we already ship this class, only the uses clause is wrong" -- which is why
// this shim was 0 new classes rather than a port. The shim makes that
// classification observable: the tool reports the resolution mechanism, and the
// underlying classification is left as measured. See that tool's
// `shim_for()` and doc/F3-SVG section 21.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

interface

uses
  LclVirtualImage;

type
  // Alias, deliberately. See the header: a subclass does not compile.
  TVirtualImage = TLclVirtualImage;

implementation

end.