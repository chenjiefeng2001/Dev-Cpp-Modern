// Common compiler defines, FPC-side copy of the vendored SynEdit.inc.
//
// SynEditJedi.inc is deliberately NOT pulled in. The vendored include
// pulls it unconditionally, and it contains a MODE DELPHI switch that
// -Mdelphiunicode refuses ("Mode switch DELPHI not allowed here") -- and
// whose Delphi 7 semantics would break the Unicode behaviour this tree
// needs. That single missing include is the only difference between the
// vendored file and this one.
{$B-,H+}
