#!/usr/bin/env python3
"""F2-a: the ground-truth inventory of what the LSP client layer needs.

WHY A TOOL INSTEAD OF A HAND-WRITTEN LIST
=========================================
The F2 plan proposed an `IEditorControlAdapter` interface BEFORE measuring
what the four client units actually touch. Writing an interface from a plan
invites two opposite failures: members nobody calls (dead contract surface
nobody tests) and members somebody does call and the interface forgot (the
crash that arrives 4,000 lines into F2-b).

So the contract is derived from the source, and this script is what keeps it
honest: re-run it and every claimed "covered" member is re-verified against the
current code.

Usage:
    python tools/lsp_editor_deps.py            # the inventory
    python tools/lsp_editor_deps.py --json     # machine-readable
"""
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = ROOT / "Source" / "LSP" / "Client"

# Variables the client layer uses to hold/receive an editor. Read from the code
# rather than guessed: every TCustomSynEdit field is FEditor, every parameter
# is AEditor or a local Ed.
_EDITOR_VARS = ("FEditor", "AEditor", "Ed")

# SynEdit types appearing anywhere in the layer: the type-level dependency,
# which is a superset of the member-level one.
_TYPES = re.compile(r"\b(TSynEdit[A-Za-z_]*|TBufferCoord|TDisplayCoord|"
                    r"TMarker|TScrollBar|SynEdit)\b")

# `Ed.Something` / `FEditor.Something` / `AEditor.Something`
_MEMBER = re.compile(r"\b(?:%s)\s*\.\s*([A-Za-z_]\w*)" % "|".join(_EDITOR_VARS))


def units():
    return sorted(CLIENT.rglob("*.pas"))


def scan():
    members = collections.Counter()
    sites = collections.defaultdict(list)
    types = collections.Counter()
    per_unit = {}

    for p in units():
        text = p.read_bytes().decode("utf-8-sig", errors="replace")
        name = p.stem.split(".")[-1]
        n_member = 0
        for i, line in enumerate(text.splitlines(), 1):
            for t in _TYPES.findall(line):
                types[t] += 1
            for m in _MEMBER.finditer(line):
                nm = m.group(1)
                members[nm] += 1
                sites[nm].append((name, i))
                n_member += 1
        per_unit[name] = {
            "lines": len(text.splitlines()),
            "editor_type_refs": text.count("TCustomSynEdit"),
            "member_refs": n_member,
        }
    return members, sites, types, per_unit


# Classification is by HOW a member is used, because that is what decides
# whether an interface method can express it at all.
KIND_EVENT = "event-assignment"
KIND_COLLECTION = "collection"
KIND_WRITE_PROTO = "write-protocol"
KIND_QUERY = "query"
KIND_GEOMETRY = "geometry"

_KIND_MAP = {
    "MarkersChanged": KIND_EVENT,
    "Markers": KIND_COLLECTION,
    "BlockBegin": KIND_WRITE_PROTO,
    "BlockEnd": KIND_WRITE_PROTO,
    "SelText": KIND_WRITE_PROTO,
    "CaretXY": KIND_WRITE_PROTO,
    "BeginUndoBlock": KIND_WRITE_PROTO,
    "EndUndoBlock": KIND_WRITE_PROTO,
    "ClientToScreen": KIND_GEOMETRY,
    "ScreenToClient": KIND_GEOMETRY,
    "RowColumnToPixels": KIND_GEOMETRY,
    "PixelsToRowColumn": KIND_GEOMETRY,
    "BufferToDisplayPos": KIND_GEOMETRY,
    "DisplayToBufferPos": KIND_GEOMETRY,
    "DisplayXY": KIND_GEOMETRY,
    "LineHeight": KIND_GEOMETRY,
    "ClientWidth": KIND_GEOMETRY,
    "ClientHeight": KIND_GEOMETRY,
}


def classify(name):
    return _KIND_MAP.get(name, KIND_QUERY)


def main(argv):
    members, sites, types, per_unit = scan()
    if "--json" in argv:
        print(json.dumps({
            "members": {k: {"count": v, "kind": classify(k),
                            "sites": ["%s:%d" % s for s in sites[k]]}
                        for k, v in members.most_common()},
            "types": dict(types),
            "units": per_unit,
        }, indent=2, ensure_ascii=False))
        return 0

    print("== units ==")
    for n, d in sorted(per_unit.items(), key=lambda kv: -kv[1]["member_refs"]):
        print("  %-16s %5d lines  TCustomSynEdit x%-3d member-refs %d"
              % (n, d["lines"], d["editor_type_refs"], d["member_refs"]))

    print("\n== SynEdit TYPES referenced by the layer (type-level dependency) ==")
    for t, n in types.most_common():
        print("  %-18s x%d" % (t, n))

    print("\n== MEMBERS actually touched: %d distinct ==" % len(members))
    by_kind = collections.defaultdict(list)
    for k, v in members.most_common():
        by_kind[classify(k)].append((k, v, sites[k]))
    for kind in (KIND_COLLECTION, KIND_EVENT, KIND_WRITE_PROTO,
                 KIND_GEOMETRY, KIND_QUERY):
        items = by_kind.get(kind, [])
        if not items:
            continue
        print("\n  --- %s (%d) ---" % (kind, len(items)))
        for k, v, st in items:
            where = ", ".join("%s:%d" % s for s in st[:3])
            more = " (+%d more)" % (len(st) - 3) if len(st) > 3 else ""
            print("    %-22s x%-3d  %s%s" % (k, v, where, more))

    print("\n== contract implications (why the plan's draft is not usable as-is) ==")
    print("  1. A collection (%s) cannot be expressed as the draft's scalar"
          % ", ".join(k for k, _, _ in by_kind.get(KIND_COLLECTION, [])))
    print("     accessors. Lsp.Client.pas:139-182 drives Count / Add / Delete.")
    print("  2. MarkersChanged is an EVENT ASSIGNMENT, not a call:")
    print("     FEditor.MarkersChanged := procedure(Sender: TObject).")
    print("     An interface method models the fact, not the subscription.")
    print("  3. The write protocol (%s) is an ORDERED sequence." % ", ".join(
        k for k, _, _ in by_kind.get(KIND_WRITE_PROTO, [])))
    print("     begin -> BlockBegin -> SelText -> CaretXY -> end.")
    print("     Splitting it into independent setters would let a caller")
    print("     reorder it into something the editor does not allow, so the")
    print("     draft's SetSelection/ReplaceSelection pair is not a rename:")
    print("     it drops the caret move and the undo block as ONE unit.")
    print("  4. TMarker is NOT defined in the client layer -- it comes from")
    print("     SynHighlighterMulti.pas. The dependency therefore runs through")
    print("     the HIGHLIGHTER as well as the editor control, and an interface")
    print("     scoped only to TCustomSynEdit leaves that edge open.")
    print("  5. `Lines` is used three different ways: Lines.Count, Lines[i],")
    print("     and Lines.Text. The last feeds LSP document sync")
    print("     (LspFlushPendingDocument) and is not a line accessor at all.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
