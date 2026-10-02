#!/usr/bin/env python3
"""Compile-time checks that CAN be made without a Delphi compiler.

WHY THIS EXISTS
===============
Two units have now been migrated onto IEditorControlAdapter (Definition, Hover)
and the compiler cannot be run here. The cause was measured, not assumed:
this Studio install ships no `dcc32.dll` at all, so the 23 KB `dcc32.exe`
forwarder refuses command-line work with "This version of the product does not
support command line compiling". tools/dcc_build.py reports that as exit 3.

The usual answer to "cannot compile" is to be careful. This file is the better
answer: check the class of mistakes a compiler WOULD catch, by asserting the
property rather than reviewing it -- the same discipline as every other tool
here.

WHAT IS CHECKED
===============
  1. Every method the contract declares is implemented by the VCL adapter. A
     missing one fails at the first call site, i.e. it is the first thing a
     build would say.
  2. Neither migrated client unit names a SynEdit type in CODE. Comments are
     stripped first -- this is the `uses clause is not enough` finding from the
     Hover step, turned into a standing rule.
  3. Every adapter call a migrated unit makes names a member the contract
     actually declares. A typo such as GetClientWitdh compiles nowhere.
  4. The lifecycle ordering the rulings made load-bearing: managers are notified
     while FEditorAdapter is still non-nil, and the adapter is cleared BEFORE
     FreeAndNil(fText).

What is NOT checked, stated plainly: nothing here replaces the compiler. It
cannot check types, overload resolution, or whether a body is correct. A green
run means "the shape is right", not "it builds".

Usage:
    python tools/f2_static_verify.py [--verbose]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IFACE = ROOT / "Source" / "LSP" / "Editor" / "Lsp.Editor.Interfaces.pas"
ADAPTER = ROOT / "Source" / "LSP" / "Editor" / "Lsp.Editor.VclAdapter.pas"
EDITOR = ROOT / "Source" / "Editor.pas"
CLIENT = ROOT / "Source" / "LSP" / "Client"

# Migrated units, in the order they were converted. Keep this list in step with
# the migration scripts: an un-migrated unit listed here fails the "no SynEdit
# types in code" check, which is the intended failure, and a MIGRATED unit left
# out of this list is never checked at all -- which is the failure that does not
# announce itself.
MIGRATED = ("Definition", "Hover", "SignatureHelp")
PENDING = ("Completion",)

SYNEDIT_TYPES = ("TCustomSynEdit", "TBufferCoord", "TDisplayCoord", "TSynEdit",
                 "TMarker", "TSynEditMarker")


def read(p):
    raw = p.read_bytes()
    return raw.decode("utf-8-sig" if raw[:3] == b"\xef\xbb\xbf" else "utf-8")


def read_latin(p):
    return p.read_bytes().decode("latin-1")


def strip_comments(t):
    t = re.sub(r"\{[^}]*\}", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", " ", t)


def contract_methods(path):
    """Names declared in the contract's INTERFACE section.

    Two things this has to get right, both learned by watching it get them
    wrong:

    * `implementation` is matched case-insensitively on its own line. A
      case-sensitive split found nothing at all and reported "contract declares
      0" -- which then made every adapter call look unmapped, i.e. the check
      failed loudly for the wrong reason and would have sent someone hunting
      for a missing contract method that was there all along.

    * Method declarations are matched on the NAME, not by scanning for `(` or
      `:`. The interface also contains `TLspNotifyEvent = procedure(Sender:
      TObject) of object;` -- a type, not a method -- and a looser pattern
      collects it as one.
    """
    raw = read(path)
    m = re.search(r"(?mi)^\s*implementation\s*$", raw)
    if m:
        raw = raw[:m.start()]
    raw = strip_comments(raw)
    out = {}
    for mm in re.finditer(
            r"(?mi)^\s*(function|procedure)\s+(\w+)\s*(?=[(:;]|\r?\n|$)", raw):
        out[mm.group(2)] = mm.group(1)
    return out


def adapter_methods(path):
    body = read(path).split("implementation", 1)[1]
    return set(m.group(1) for m in
               re.finditer(r"(?m)^\s*(?:function|procedure)\s+(?:T\w+\.)?(\w+)",
                           body))


def find_unit(name):
    hits = list(CLIENT.rglob("Lsp.Client.%s.pas" % name))
    return hits[0] if hits else None


def main(argv):
    verbose = "--verbose" in argv
    ok = True

    print("== 1. contract vs adapter: every declared method is implemented ==")
    cm = contract_methods(IFACE)
    am = adapter_methods(ADAPTER)
    missing = sorted(set(cm) - am)
    print("   contract declares %d, adapter implements %d"
          % (len(cm), len(am)))
    for name in sorted(cm):
        hit = name in am
        if not hit:
            ok = False
        if verbose or not hit:
            print("   %s %s" % ("OK  " if hit else "FAIL", name))
    print("   missing: %s" % (missing or "(none)"))

    print("\n== 2. migrated units name no SynEdit type in CODE ==")
    for name in MIGRATED:
        p = find_unit(name)
        if p is None:
            print("   FAIL %s: unit not found" % name)
            ok = False
            continue
        code = strip_comments(read(p))
        hits = [s for s in SYNEDIT_TYPES if re.search(r"\b%s\b" % s, code)]
        if hits:
            ok = False
            print("   FAIL %-14s still names: %s" % (name, ", ".join(hits)))
        else:
            print("   OK   %-14s clean" % name)
    for name in PENDING:
        p = find_unit(name)
        if p is None:
            continue
        code = strip_comments(read(p))
        n = sum(len(re.findall(r"\b%s\b" % s, code)) for s in SYNEDIT_TYPES)
        print("   --   %-14s NOT migrated yet (%d SynEdit refs, expected)"
              % (name, n))

    print("\n== 3. adapter calls in migrated units exist on the contract ==")
    for name in MIGRATED:
        p = find_unit(name)
        if p is None:
            continue
        code = strip_comments(read(p))
        called = set(re.findall(r"\bFEditor\s*\.\s*(\w+)", code))
        bad = sorted(c for c in called if c not in cm)
        print("   %-14s calls %d: %s"
              % (name, len(called), ", ".join(sorted(called))))
        if bad:
            ok = False
            print("   FAIL   not on the contract: %s" % ", ".join(bad))

    print("\n== 4. teardown order in Editor.pas ==")
    e = read_latin(EDITOR)
    destroy = e.split("destructor TEditor.Destroy;", 1)[1].split("\nend;", 1)[0]
    # Strip comments before locating the calls. TEditor.Destroy's own F2 note
    # spells out the order in prose and mentions FreeAndNil(fText) by name, so a
    # naive find() landed on the COMMENT at offset 1368 rather than the real call
    # near the end -- and reported the ordering as broken when it is correct.
    code = strip_comments(destroy)
    if "FreeAndNil(fText)" in code:
        i_notify = code.find("EditorDestroyed(FEditorAdapter)")
        i_clear = code.find("FEditorAdapter := nil")
        i_free = code.find("FreeAndNil(fText)")
        good = 0 <= i_notify < i_clear < i_free
        print("   notify@%-6d clear@%-6d FreeAndNil(fText)@%-6d -> %s"
              % (i_notify, i_clear, i_free, "OK" if good else "FAIL"))
        if not good:
            ok = False
            print("   (expected: notify < clear < free)")
    else:
        print("   FAIL could not locate FreeAndNil(fText) in TEditor.Destroy")
        ok = False

    mgrs = sorted(set(re.findall(
        r"Lsp\w*Manager\.EditorDestroyed\(FEditorAdapter\)", code)))
    names = [m.split(".EditorDestroyed")[0] for m in mgrs]
    print("   managers notified through the adapter: %d %s"
          % (len(names), ", ".join(names)))
    # A manager that ACCEPTS the adapter must be routed through it. Hover and
    # Definition now take IEditorControlAdapter; if they were still being handed
    # fText the tree would not compile, so this is the check that catches a
    # half-migrated teardown.
    for mgr in ("LspHoverManager", "LspDefinitionManager", "LspSignatureHelpManager"):
        via_adapter = any(m.startswith(mgr) for m in mgrs)
        via_raw = bool(re.search(
            r"%s\.EditorDestroyed\(fText\)" % re.escape(mgr), code))
        if via_raw and not via_adapter:
            ok = False
            print("   FAIL %s is migrated but still notified with fText" % mgr)
        elif via_adapter:
            print("   OK   %-20s routed through the adapter" % mgr)

    print("\n== 5. deferred units are still RAW, and still wired RAW ==")
    # Completion is deliberately NOT migrated (decision of 2026-10-01): its write
    # protocol has no verified home, because TVclSynEditAdapter.ReplaceRange
    # raises on purpose until SynEdit's write API can be checked against a real
    # compiler. Migrating it anyway would mean shipping code that edits the user's
    # document along a path nobody can run.
    #
    # Both halves of that state are asserted. "Still raw" alone would be satisfied
    # by a half-finished migration; "still wired raw" alone would be satisfied by
    # a unit nobody calls. Together they say: this is a coherent, complete,
    # deliberately unmigrated unit -- not a broken one.
    for name in PENDING:
        p = find_unit(name)
        if p is None:
            print("   FAIL %s: unit not found" % name)
            ok = False
            continue
        code_u = strip_comments(read(p))
        raw_refs = sum(len(re.findall(r"\b%s\b" % s, code_u))
                       for s in SYNEDIT_TYPES)
        if raw_refs == 0:
            print("   NOTE %-14s has NO SynEdit refs -- if it was migrated, move it"
                  % name)
            print("        from PENDING to MIGRATED here, or check 2 stops covering it")
        else:
            print("   OK   %-14s still raw (%d SynEdit refs) -- as decided" % (name, raw_refs))
    # Editor.pas must still hand Completion the raw control.
    if PENDING:
        still_raw = bool(re.search(r"LspCompletionManager\.\w+\(fText", code))
        if still_raw:
            print("   OK   %-14s still receives fText in Editor.pas" % "Completion")
        else:
            ok = False
            print("   FAIL Completion is not migrated but Editor.pas passes an adapter")

    print("\nSTATIC VERIFY: %s" % ("OK" if ok else "FAILED"))
    print("(green here means the SHAPE is right; it is not a compile)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
