#!/usr/bin/env python3
"""
f3_dfm_to_lfm.py -- structural DFM -> LFM conversion for the batch-A forms.

WHY THIS EXISTS WITHOUT LAZARUS
===============================
Lazarus' own converter is the authority and is what CI uses, but it could not be
installed in the environment this was written in (see f3_lazarus_setup.ps1 for the
measured reason: SourceForge serves non-browser clients an HTML interstitial, and
ftp.freepascal.org refuses the TLS handshake). Leaving F3 blocked on a download
would have wasted a step that does not need one.

So this does the part that is mechanical and verifiable, and refuses to pretend
it did the rest:

  * parses the DFM text form (object/inherited/inline + properties)
  * rewrites the class names the LCL renames or the DFM spells differently
  * drops the Delphi-only properties the LCL has no counterpart for, and says
    which ones those were
  * emits an LFM skeleton with the same object tree and geometry

WHAT IT DELIBERATELY DOES NOT DO
================================
It does not claim a converted FORM loads. Only `lazbuild` against a real LCL can
answer that, and a text transform that implied otherwise would be worse than no
transform: it would move the F3 gate from "measured" back to "assumed" while
looking like progress.

The SVG list fragments it DOES emit are a different matter, and they are load
tested -- see Tests/FpcCoreTests/svg/SvgLfmProbe.lpr, which streams every
generated .svg-lists.lfm through the real LCL reader and counts the pixels.

NO HEADER COMMENTS, AND WHY THAT IS A HARD RULE
===============================================
Every .lfm this tool wrote used to start with `% ...` provenance lines. Measured
against the real loader (LRSObjectTextToBinary, lcl/lresources.pp), those lines
make the file UNREADABLE:

    { generated header }      -> EParserError: Symbol expected but { found   (1,164)
    (* generated header *)    -> EParserError: Symbol expected but ( found   (1,166)
    // generated header       -> EParserError: Symbol expected but / found   (1,163)
    % generated header        -> EParserError: Symbol expected but found     (1,162)

TParser does not skip comments -- it goes straight for `object`. All four
syntaxes were tried because assuming the standard ones would work is exactly
the kind of guess this project keeps having to undo. So the .lfm carries no
provenance at all, and the record of what produced it lives in
`<out>/_generated.json` instead, which f3_lfm_check.py asserts against.

Run:  python tools/f3_dfm_to_lfm.py [--out DIR] [--only ...] [--emit-svg-lists]
Exit: 0 when every requested form converted, 1 when any failed.
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

# Delphi-only properties with no LCL counterpart. Dropping them is what the
# official converter does too; the value here is that the list is explicit and
# reported rather than silent.
DROP_PROPS = {
    "OldCreateOrder", "PixelsPerInch", "PixelsPerInchX", "PixelsPerInchY",
    "UsePixelsPerInch", "ExplicitWidth", "ExplicitHeight",
    # CORRECTED: the first version of this list also dropped BorderStyle,
    # ParentColor, ParentFont, Default and TabOrder -- all of which are valid LCL
    # properties, and together they accounted for 453 of the 455 dropped values.
    # Silently discarding a real property is worse than leaving an unknown one in,
    # because the LCL loader reports what it dislikes and a dropped one reports
    # because the LCL loader complains about what it does not recognise, whereas a
    # property we removed early is invisible: it simply never gets checked.
    #
    # ADDED 2026-10-05, from MEASURING the 34 .lfm files this tool had already
    # produced rather than from reading the LCL docs. Residuals by frequency:
    #
    #   Font.Charset  86    VCL stores a Windows codepage here. LCL's TFont has
    #                       Charset but the value means nothing on GTK/Cocoa,
    #                       and the loader warns per control -- 86 warnings in
    #                       one project load is the dialog storm this list
    #                       exists to prevent.
    #   Ctl3D / ParentCtl3D  11 + 11
    #                       TControl3D behaviour; LCL draws flat, and these two
    #                       are the classic VCL-only leftovers.
    #   ExplicitTop 5 / ExplicitLeft 1
    #                       Alignment helpers. ExplicitWidth/ExplicitHeight were
    #                       already dropped, so leaving these two is an omission
    #                       in the original list, not a judgement.
    #   Font.Quality 1
    #                       cqClearType is a no-op off Windows and a font
    #                       mismatch at worst.
    #   TextHeight  a member of the PixelsPerInch family, stored on every
    #               streamed control carrying a Font block.
    #
    # This set is MEASURED, not exhaustive. A property that appears only in a
    # form not yet converted is still unlisted, which is exactly why
    # tools/f3_lfm_check.py asserts on the OUTPUT instead of trusting this set.
    "Font.Charset", "Ctl3D", "ParentCtl3D",
    "ExplicitTop", "ExplicitLeft", "Font.Quality", "TextHeight",
}

# Class-name fixes. These are the two the DFM gets wrong relative to LCL.
CLASS_RENAME = {
    "TToolButton": "TToolButton",  # identical; kept for documentation value
    "TSynMemo": "TSynMemo",
    # Step 3. The rename lives HERE rather than in the SVG rule below because
    # parse_dfm is what decides a node's type, and both the payload-dropping
    # branch in to_lfm and the unsupported-class refusal in main() read that
    # field. Writing the rename into to_lfm instead left the fragment emitting
    # `TSVGIconImageList` with all 116 SVG documents still inline -- i.e. the
    # header claimed the rule had been applied to a file it had not touched.
    "TSVGIconImageList": "TLclSvgImageList",
    # Sprint F3-3. `TVirtualImage` was recorded as "external, LCL has an
    # equivalent, so this is a field-level rename". Measurement said the class
    # was never the problem -- all three use sites are named-image FETCHERS over
    # a Vcl.TImageCollection whose 20 inline PNGs live in DataFrm.dfm, and LCL's
    # TImage has no ImageCollection at all. The rename only became honest once
    # tools/f3_image_extract.py had put those PNGs on disk and
    # Source/Fpc/UI/Controls/LclVirtualImage.pas existed to resolve an index
    # against them. See that unit for why the replacement needs almost no code.
    "TVirtualImage": "TLclVirtualImage",
}

# Properties dropped on a TLclVirtualImage node, and ONLY those.
#
# This started as a whitelist -- the shape SVG_KEEP_PROPS uses -- and that was
# wrong in a way the diff caught immediately: TVirtualImage is a TControl
# descendant, so Left / Top / Width / Height are ordinary geometry, and a
# whitelist over ALL properties swept them out too. EnviroFrm's preview arrived
# at 0x0. A drop-list keeps geometry on the normal path, where it is emitted
# like any other control's.
#
# `ImageHeight` is the one VirtualImage property LCL's TImage has no counterpart
# for. All three sites set it to 0, which the VCL reads as "use the source
# size", so dropping a 0 loses nothing. Dropping a REAL height would lose the
# size, so the dropped VALUES are recorded and tools/f3_imgcoll_check.py fails
# the build the day one is not 0.
VIMAGE_DROP_PROPS = {"ImageHeight"}

OBJ_RE = re.compile(r"^(\s*)(object|inherited|inline)\s+(\w+)\s*:\s*(\w+)\s*$")
PROP_RE = re.compile(r"^(\s*)(\w[\w.\[\]]*)\s*=\s*(.*)$")

# ---------------------------------------------------------------------------
# STEP 3: the SVG conversion rule.
# ---------------------------------------------------------------------------
# The only class in this family with an LCL counterpart so far. The other two
# vendored SVG classes (TSVGIconImageCollection, TSVGIconVirtualImageList,
# both used only by Tools/Packman/Main.dfm) have no counterpart, and a form
# carrying one is REFUSED below rather than converted into an LFM naming a
# class the loader has never heard of.
SVG_LIST_CLASS = "TSVGIconImageList"
SVG_TARGET_CLASS = "TLclSvgImageList"
SVG_UNSUPPORTED = {"TSVGIconImageCollection", "TSVGIconVirtualImageList"}

# A form that DECLARES one of the vendored SVG classes is a producer. The
# use-site regex in f3_form_survey cannot see these: DataFrm declares all five
# lists and references none of them, and NewProjectFrm's `LargeImages =
# SVGIconImageList` is a bare local name with no `dmMain.` prefix.
SVG_DECL_RE = re.compile(r"^\s*object\s+\w+\s*:\s*TSVGIcon\w*\s*$")

# The TVirtualImage half of step 3. Kept out of the SVG branch because the two
# have nothing in common except that both rename a class whose payload has to
# move somewhere else first.
VIMAGE_SOURCE_CLASS = "TVirtualImage"
VIMAGE_TARGET_CLASS = "TLclVirtualImage"

# What survives on a TLclSvgImageList node. This is a WHITELIST, not a list of
# things to drop, and the reason is a measured one: LCL's TCustomImageList
# descends from TLCLComponent, NOT from TControl (lcl/imglist.pp:266), so it has
# no Left and no Top at all. The vendored control was a TControl, so every one of
# its six lists carries `Left`/`Top` -- properties the LCL loader will reject.
#
# `Size`, `Width` and `Height` are dropped on the same grounds plus a worse one:
# they are geometry, `ListName`'s setter has already applied the edge that
# SvgData holds, and the reader assigns properties in file order -- so a
# surviving `Height = 18` (measured, on SVGImageListClassStyle) would land
# AFTER the load and rescale a 32 px list down to 18. `Size` would not have done
# that, being an unknown name, which is why only one of the two looked dangerous.
#
# The whitelist is appearance only: values a person set on purpose, as opposed
# to values the designer emitted.
SVG_KEEP_PROPS = {
    "Color", "BkColor", "TransparentColor", "BlendColor", "Masked", "AllocBy",
}

# The five lists SvgData actually holds, read from the extractor's own manifest
# so this cannot become a second hand-typed copy of the same fact. Loaded at
# import; an absent manifest is a hard error rather than an empty set, because
# "I could not check" and "everything is fine" must never print the same.
def _known_list_names():
    path = ROOT / "Source" / "Fpc" / "UI" / "Data" / "svg_manifest.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SystemExit("cannot read %s: %s" % (path, exc))
    return {row["list"] for row in data}


KNOWN_LIST_NAMES = _known_list_names()


# The TImageCollection names tools/f3_image_extract.py actually extracted, read
# from its manifest rather than hand-typed here. The same one-source-of-truth
# rule as KNOWN_LIST_NAMES above: a second hand-typed copy of "which
# collections exist" is a fact that drifts silently the day a fourth is added.
def _known_collection_names():
    path = ROOT / "Source" / "Fpc" / "UI" / "Data" / "img_manifest.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SystemExit("cannot read %s: %s" % (path, exc))
    return {row["collection"] for row in data}


KNOWN_COLLECTION_NAMES = _known_collection_names()

# `ImageCollection = dmMain.<Name>`. The owner prefix is dropped: dmMain is a
# Delphi data module this port does not have, and what a use site actually names
# is the collection.
VIMAGE_COLLECTION_RE = re.compile(r"^(\w+)\.(\w+)$")

# A collection property opens on its own line and is closed by `end>`, NOT by a
# bare `>`: the DFM writer terminates the LAST item with `end>` so that the same
# keyword closes both the item and the collection. Measured over every form in
# the tree: 28 openers and 28 `end>` in DataFrm, and ZERO bare `>` anywhere.
#
# `end>` also closes the collection and one nesting level at a time, so nesting
# is counted: `Images = <` contains `SourceImages = <` (max depth 2, measured).
COLL_START_RE = re.compile(r"^(\s*)([\w.\[\]]+)\s*=\s*<\s*$")
COLL_END_RE = re.compile(r"^\s*end>\s*$")
ITEM_RE = re.compile(r"^\s*item\s*$")


def parse_dfm(text):
    """Return (root_type, [ (depth, name, kind, type, [(prop, value)]) ]).

    A deliberately small reader: DFM is line-oriented and this only needs the
    object tree and simple properties. Binary property blocks (`object X: Y`
    followed by hex blobs) are captured as a single opaque value so they survive
    the round trip untouched.
    """
    lines = text.splitlines()
    i = 0
    root = None
    nodes = []
    stack = []  # (indent, node)
    while i < len(lines):
        line = lines[i]
        m = OBJ_RE.match(line)
        if not m:
            i += 1
            continue
        indent, kind, name, ctype = m.groups()
        if root is None and len(indent) == 0:
            root = ctype
        node = {
            "indent": len(indent),
            "name": name,
            "kind": kind,
            "type": CLASS_RENAME.get(ctype, ctype),
            "props": [],
        }
        # Collect properties until `end` at the same indent, or the next object.
        j = i + 1
        binary = []
        while j < len(lines):
            nxt = lines[j]
            if OBJ_RE.match(nxt):
                break
            if re.match(r"^\s*end\s*$", nxt) and len(nxt) - len(nxt.lstrip()) == len(indent):
                break
            pm = PROP_RE.match(nxt)
            cm = COLL_START_RE.match(nxt)
            if cm:
                # Consume the whole collection body. The old reader had no
                # branch for this, so `SVGIconItems = < ... end>` fell through
                # to the binary bucket: its 116 SVG documents were re-emitted
                # verbatim into the .lfm as text the loader rejects, AND the
                # item-level `end`s were counted as if they closed objects.
                coll = [nxt]
                items = 0
                depth = 1
                while j + 1 < len(lines):
                    nxt2 = lines[j + 1]
                    if COLL_START_RE.match(nxt2):
                        depth += 1
                    elif COLL_END_RE.match(nxt2):
                        depth -= 1
                    j += 1
                    coll.append(lines[j])
                    if ITEM_RE.match(lines[j]):
                        items += 1
                    if depth == 0:
                        break
                if depth != 0:
                    raise ValueError(
                        "unterminated collection %r (opened at line %d)"
                        % (cm.group(2), i + 1))
                node["props"].append(
                    ("__collection__", (cm.group(2), "\n".join(coll), items)))
            elif pm:
                node["props"].append((pm.group(2), pm.group(3)))
            elif nxt.strip():
                binary.append(nxt.strip())
                # A binary DFM property closes with a `}` at the END of the last
                # hex line -- `FFFF}`, `AE426082}`, `...FF0000}` -- not on a
                # line of its own. Measured in InstallWizards.dfm: 5 such blocks,
                # and the `}` is on lines 264, 982, 1477 and two more.
                #
                # The previous reader never captured those, so every binary
                # property lost one block terminator. That is why the .lfm for
                # InstallWizards had 50 `end`s where the DFM had 55: not a
                # layout accident, five `Picture.Data` blobs (three images, a
                # bitmap, a license memo) each short of their own `}`.
                #
                # Counting only lines that END with `}` is what matters here; a
                # line merely containing one is hex data.
                if nxt.rstrip().endswith("}"):
                    node["props"].append(("__end__", ""))
            j += 1
        if binary:
            node["props"].append(("__binary__", "\n".join(binary)))
        nodes.append(node)
        while stack and stack[-1][0] >= len(indent):
            stack.pop()
        stack.append((len(indent), node))
        i = j
    return root, nodes


def to_lfm(root_type, nodes, source_name, dropped):
    """Render the node list as LFM text.

    THE ROOT NODE'S PROPERTIES ARE EMITTED. This loop used to start at
    `nodes[1:]`, which silently discarded every property of the ROOT -- and the
    root of a DFM is the Form itself, so that threw away `Left`, `Top`, `Caption`,
    `BorderIcons`, `ClientHeight`, `OnCreate`, `OnClose` and the rest.

    The bug was invisible for two reasons at once. It only shows on forms whose
    root carries properties, and the earlier lfm_check compared `object`/`end`
    COUNTS against the source, which stayed balanced because the root's block was
    still opened and closed -- just with nothing inside it. Found by diffing
    InstallWizards: 50 objects in, 50 objects out, 50 `end`s in, 50 out, and yet
    13 root properties and a `Picture.Data` blob had evaporated.

    The root is now rendered by the same loop as everything else, at indent 0.

    STEP 3, THE SVG RULE
    ====================
    `TSVGIconImageList` becomes `TLclSvgImageList` and gains exactly one
    property:

        ListName = '<the component name>'

    Two properties are dropped, and dropping them is the point rather than a
    loss:

      * `SVGIconItems` -- the payload is already in Source/Fpc/UI/Data/SvgData.pas
        and `f3_svg_extract.py --verify` holds it byte-identical to this DFM.
        Emitting it here would give the same fact a second home, and the
        round-trip gate would then only be checking one of the two.
      * `Size` -- the pixel edge, likewise. LoadFrom reads it from the data
        record, so keeping the DFM's copy would be a second source that wins or
        loses depending on load order.

    What makes the rule work is that `ListName`'s setter loads the icons. A
    component reader only calls Create and assigns published properties, so a
    control that populates itself some other way streams as Count = 0 -- the
    "window opens, icons blank" failure this work exists to remove.
    """
    out = []
    for i, node in enumerate(nodes):
        prefix = "" if i == 0 else "  " * 1  # the reader keeps flat order
        out.append("%s%s %s: %s" % (prefix, node["kind"], node["name"], node["type"]))
        is_svg = node["type"] == SVG_TARGET_CLASS
        is_vimage = node["type"] == VIMAGE_TARGET_CLASS
        if is_svg:
            out.append("%s  ListName = '%s'" % (prefix, node["name"]))
        for k, v in node["props"]:
            if is_vimage:
                # Handled before DROP_PROPS, because the rewrite below has to
                # REFUSE on an unknown collection rather than let the generic
                # path quietly pass a `dmMain.X` value to a property that
                # expects a plain name.
                if k == "ImageCollection":
                    out.append("%s  ImageCollection = %s"
                               % (prefix, rewrite_collection_ref(v, node["name"])))
                    continue
                if k in VIMAGE_DROP_PROPS:
                    # Counted with its VALUE, not just its name: the whole claim
                    # that dropping this loses nothing rests on every dropped
                    # ImageHeight being 0, and a counter cannot show that.
                    dropped["%s (TVirtualImage) = %s" % (k, v)] += 1
                    continue
            if k in DROP_PROPS:
                dropped[k] += 1
                continue
            if is_svg and k not in SVG_KEEP_PROPS:
                # Counted, not silently swallowed: a rule that quietly discards
                # a property is indistinguishable from one that forgot to
                # convert it.
                label = k
                if k == "__collection__":
                    label = "%s (%d item(s); bytes live in SvgData)" % (v[0], v[2])
                dropped["%s (SVG list)" % label] += 1
                continue
            if k == "__collection__":
                # Any collection on a NON-SVG node is re-emitted verbatim -- its
                # lines already carry their own relative indentation from the
                # DFM, so adding `prefix` on top would double it. Dropping the
                # block instead would produce an .lfm that loads and is quietly
                # missing data, which is the failure mode this project has
                # already been bitten by twice; and there is no rule for one, so
                # the honest move is to keep the bytes and let the loader judge.
                out.extend(v[1].splitlines())
                continue
            if k == "__binary__":
                for bl in v.splitlines():
                    out.append("%s  %s" % (prefix, bl))
            elif k == "__end__":
                # The `}` that closed a binary property block on its hex line.
                out.append("%s  }" % prefix)
            else:
                out.append("%s  %s = %s" % (prefix, k, v))
        out.append("%send" % prefix)
    if not nodes:
        out.append("object %s: %s" % (source_name,
                                      CLASS_RENAME.get(root_type, root_type)))
        out.append("end")
    return "\n".join(out) + "\n"


def rewrite_collection_ref(value, node_name):
    """Turn `dmMain.<Collection>` into `'<Collection>'`, or refuse.

    REFUSING is the point. The first version of the SVG rule emitted whatever
    name the DFM carried and let the loader discover the problem; the second
    discovery of that shape (NewProjectFrm's list was not in SvgData while
    the extractor still read DataFrm.dfm only, so the fragment it pointed at
    did not exist) was a silent no-op that reported success. An unknown
    collection here means a preview that will never paint, so it stops the
    conversion instead.

    Returns the already-quoted literal, ready to write.
    """
    m = VIMAGE_COLLECTION_RE.match(value.strip())
    if not m:
        raise ValueError(
            "%s: ImageCollection is %r, expected `<owner>.<Collection>`"
            % (node_name, value))
    name = m.group(2)
    if name not in KNOWN_COLLECTION_NAMES:
        raise ValueError(
            "%s: ImageCollection names %r, which is not in img_manifest.json "
            "(known: %s)" % (node_name, name,
                             ", ".join(sorted(KNOWN_COLLECTION_NAMES))))
    return "'%s'" % name


def emit_svg_fragment(dfms, out_dir, dropped):
    """Write the SVG object subtrees of every producer DFM as one loadable .lfm.

    WHY A FRAGMENT AND NOT DataFrm.lfm
    ==================================
    DataFrm.dfm is 1.7 MB, and 1.26 MB of that is one `TImageCollection` holding
    base64 PNGs -- a control with no LCL counterpart, so the form cannot load
    whatever this tool emits. Converting it would put a megabyte of dead weight
    in the tree and produce a file that fails at the first unknown class.

    The five `TSVGIconImageList` components are a DATA SET, not a form: they are
    what the 15 consumer forms name in `Images = dmMain.<list>`. So step 3's
    rule is applied to exactly that subtree and wrapped in a carrier component.

    Refused rather than emitted when a producer also carries a vendored SVG
    class with no counterpart (Tools/Packman/Main.dfm): its `LargeImages`
    reference would then resolve to nothing, which is the blank-window failure
    wearing a success message.
    """
    written, refused = [], []
    for p in dfms:
        text = p.read_bytes().decode("utf-8-sig", errors="replace")
        root, nodes = parse_dfm(text)
        # Match on the RENAMED type. `parse_dfm` applies CLASS_RENAME, so a
        # node that read `TSVGIconImageList` in the DFM is already
        # `TLclSvgImageList` here. Selecting on the old name returned an empty
        # list for every producer, `if not svg_nodes` swallowed it, and the
        # stale fragment from the previous run stayed on disk looking current --
        # a silent no-op wearing the header of a successful conversion.
        svg_nodes = [n for n in nodes if n["type"] == SVG_TARGET_CLASS]
        other = sorted({n["type"] for n in nodes
                        if n["type"].startswith("TSVGIcon")})
        if not svg_nodes and not other:
            continue
        if other:
            refused.append((p.as_posix(),
                            "no LCL counterpart for " + ", ".join(other)))
            continue
        # A list whose name SvgData does not carry streams as Count = 0: a live
        # window with blank icons, discovered by whoever looks at it first.
        # Caught here rather than left to the probe's MissingData flag, because
        # this is a build-time fact and nothing about it is a runtime surprise.
        #
        # This check has caught a real gap, and that is why it exists.
        # NewProjectFrm declares its own single-item list called
        # `SVGIconImageList` (one icon, named 'Empty', 37 px), and for the
        # first weeks of F3 the extractor read DataFrm.dfm only -- so that
        # name was absent from the manifest and this check refused the
        # form's fragment until step 1's coverage was extended (doc §14.8).
        # It stays live for the next producer the extractor has not reached.
        missing = [n["name"] for n in svg_nodes
                   if n["name"] not in KNOWN_LIST_NAMES]
        if missing:
            refused.append((p.as_posix(),
                            "SvgData has no list named " + ", ".join(missing)
                            + " (not in svg_manifest.json -- f3_svg_extract.py"
                            + " has not covered that DFM yet)"))
            continue
        body = ["object SvgImageLists: TSvgImageLists"]
        for n in svg_nodes:
            # Re-render each subtree through the same writer the full-form path
            # uses, so the fragment and DataFrm.lfm cannot drift apart.
            sub = to_lfm(n["type"], [n], n["name"], dropped)
            for line in sub.splitlines():
                body.append("  " + line)
        body.append("end")
        rel = p.relative_to(SOURCE).with_suffix(".svg-lists.lfm")
        dest = out_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        # No header. See the module docstring: TParser accepts no comment syntax
        # at all, so a provenance banner here means a file the LCL cannot read.
        dest.write_text("\n".join(body) + "\n",
                        encoding="utf-8", newline="\r\n")
        written.append((p.as_posix(), rel.as_posix(), len(svg_nodes)))
    return written, refused


def emit_vimage_fragment(dfms, out_dir, dropped):
    """Write every TVirtualImage subtree as one loadable .lfm.

    WHY A FRAGMENT, AGAIN
    =====================
    Same reason as emit_svg_fragment, and the same reason it is worth repeating
    rather than pointing at the one above: EnviroFrm.lfm, LangFrm.lfm and
    main.lfm each carry ninety-odd controls whose classes must ALL be
    registered before a reader can stream the file. A probe that wants to check
    three TLclVirtualImage nodes would otherwise have to stand up the entire
    application to look at them, and would then be testing the registration of
    unrelated classes as much as the conversion.

    So the three subtrees are re-rendered through the SAME `to_lfm` the
    full-form path uses -- they cannot drift -- and wrapped in a carrier, which
    the probe registers by hand.

    The carrier is `TLclVirtualImages`, and it was originally called
    `TVirtualImageCarrier`. That name CONTAINS `TVirtualImage`, so the gate
    looking for surviving VCL declarations -- which is the one check that
    catches this conversion having been skipped -- fired on the probe's own
    fragment. Renaming the carrier removes a collision rather than teaching the
    check to look the other way.

    What the fragment deliberately does NOT do is carry the collection payload.
    That lives in Source/Fpc/UI/Data/Images/, byte-checked by
    `f3_image_extract.py --verify`, exactly as SvgData holds the SVG payload.
    """
    body = ["object VirtualImages: TLclVirtualImages"]
    written, refused, total = [], [], 0
    for p in dfms:
        text = p.read_bytes().decode("utf-8-sig", errors="replace")
        root, nodes = parse_dfm(text)
        vnodes = [n for n in nodes if n["type"] == VIMAGE_TARGET_CLASS]
        if not vnodes:
            continue
        try:
            for n in vnodes:
                sub = to_lfm(n["type"], [n], n["name"], dropped)
                for line in sub.splitlines():
                    body.append("  " + line)
        except Exception as exc:                       # noqa: BLE001
            refused.append((p.as_posix(), str(exc)))
            continue
        total += len(vnodes)
        written.append((p.as_posix(), [n["name"] for n in vnodes]))
    body.append("end")

    if not written:
        # No TVirtualImage anywhere: writing an empty carrier would produce a
        # probe that loads successfully and checks nothing.
        print("no TVirtualImage nodes found -- no fragment written")
        return [], []

    rel = pathlib.Path("ImageCollections.lfm")
    dest = out_dir / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(body) + "\n", encoding="utf-8", newline="\r\n")
    return [(rel.as_posix(), total, written)], refused


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "Source" / "Fpc" / "UI" / "Forms"))
    ap.add_argument("--only", default="batch-a",
                    choices=["batch-a", "batch-b", "batch-c", "svg", "svg-lists", "all"])
    ap.add_argument("--emit-svg-lists", action="store_true",
                    help="also write the SVG list subtrees of every producer DFM")
    ap.add_argument("--emit-vimage-fragment", action="store_true",
                    help="also write every TVirtualImage subtree as ImageCollections.lfm")
    args = ap.parse_args()

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "f3_form_survey", ROOT / "tools" / "f3_form_survey.py")
    survey = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(survey)

    dfms = sorted(p for p in survey.SOURCE.rglob("*.dfm") if "VCL" not in p.parts)
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    converted, skipped, failures = [], [], []
    dropped = collections.Counter()
    # MERGED, not replaced. The tool converts in subsets (`--only batch-a`,
    # then `--only svg --emit-svg-lists`), and a whole-file rewrite meant the
    # second run deleted the first run's 34 records -- so the provenance gate
    # reported "no entry in _generated.json" for exactly the files that were
    # converted first. Stale entries are caught the other way: f3_lfm_check.py
    # reports a record whose .lfm no longer exists.
    manifest_path = out_dir / "_generated.json"
    provenance = {}
    if manifest_path.is_file():
        try:
            provenance = json.loads(manifest_path.read_text(encoding="utf-8"))
        except ValueError:
            provenance = {}

    for p in dfms:
        text = p.read_bytes().decode("utf-8-sig", errors="replace")
        root, nodes = parse_dfm(text)
        if root is None:
            failures.append((p.name, "no root object"))
            continue
        # Reuse the survey's own verdict rather than recomputing it here.
        # The first version of this loop derived `custom` itself and omitted the
        # root-class exclusion that f3_form_survey.py applies, so it classified 38
        # forms as batch A where the survey says 34 -- and it never produced a batch
        # B at all. One source of truth, or the numbers drift.
        _, _, custom = survey.survey(p)
        # Bucket assignment mirrors f3_batch_plan.py exactly. Converting a form that
        # draws from an SVG icon list succeeds and produces a window that renders
        # nothing, so those forms are kept out of batch A: shipping a blank form
        # is a worse outcome than shipping an unconverted one.
        svg = bool(survey.SVG_USE_RE.search(text))
        # A form that DECLARES an SVG list is a producer, whether or not it also
        # consumes one. DataFrm declares all five and NewProjectFrm one, and
        # neither is detected by the use-site regex.
        declares_svg = any(SVG_DECL_RE.match(l) for l in text.splitlines())
        # SVG dependency OUTRANKS the batch letter. `LangFrm` and `EnviroFrm` are
        # batch B by the letter test -- their only blocker is TVirtualImage, which
        # has an LCL equivalent -- but that control draws from
        # `dmMain.SVGImageListMenuStyle`, so the converted window would render an
        # empty preview. They are therefore A-svg as well.
        # Three-way, matching f3_batch_plan.py: a form with a blocking control is C
        # regardless of SVG. The previous line assigned "A" to everything that
        # was not SVG-bound, so the four batch-C forms (CompOptionsFrame, DataFrm,
        # NewProjectFrm, Packman/Main) were converted as if they were clean.
        if custom:
            bucket = "C"
        else:
            bucket = "A-svg" if svg else "A"

        # REFUSE rather than convert. A form carrying one of these would produce
        # an .lfm naming a class the LCL loader has never heard of, and the only
        # symptom would be a window that fails to open -- reported as a conversion
        # success, because the text transform did succeed.
        blocking_svg = sorted({n["type"] for n in nodes} & SVG_UNSUPPORTED)
        if blocking_svg:
            failures.append((p.as_posix(),
                             "no LCL counterpart for " + ", ".join(blocking_svg)))
            continue
        if args.only == "batch-a" and bucket != "A":
            skipped.append(p.name)
            continue
        if args.only == "batch-c" and bucket != "C":
            skipped.append(p.name)
            continue
        if args.only == "batch-b" and bucket != "B":
            skipped.append(p.name)
            continue
        # Step 4. `--only svg` covers the CONSUMERS -- the forms whose `Images =
        # dmMain.<list>` becomes meaningful once the lists exist. The PRODUCERS
        # (DataFrm, NewProjectFrm) are handled by --emit-svg-lists instead: they
        # carry megabytes of unrelated payload, and what step 4 needs from them
        # is the five list components alone.
        if args.only == "svg" and not svg:
            skipped.append(p.name)
            continue
        if args.only == "svg-lists" and not declares_svg:
            skipped.append(p.name)
            continue

        rel = p.relative_to(survey.SOURCE).with_suffix(".lfm")
        dest = out_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            body = to_lfm(root, nodes, p.stem, dropped)
        except Exception as exc:                       # noqa: BLE001
            failures.append((p.name, str(exc)))
            continue
        # No header. See the module docstring: TParser accepts no comment syntax,
        # so a provenance banner here would make the file unreadable to the very
        # runtime this conversion exists for. Provenance goes to _generated.json.
        dest.write_text(body, encoding="utf-8", newline="\r\n")
        provenance[rel.as_posix()] = {
            "source": p.relative_to(survey.SOURCE).as_posix(),
            "rule": "dfm-to-lfm",
            "batch": bucket,
            "svg_lists": sum(1 for n in nodes if n["type"] == SVG_TARGET_CLASS),
        }
        converted.append((p.as_posix(), rel.as_posix()))

    print(f"converted: {len(converted)}   skipped: {len(skipped)}   failed: {len(failures)}")
    if args.emit_svg_lists:
        written, refused = emit_svg_fragment(dfms, out_dir, dropped)
        print("SVG list fragments:")
        for src, rel, n in written:
            print(f"  {rel}  ({n} list(s) from {src})")
            provenance[rel] = {
                "source": src,
                "rule": "svg-list-fragment",
                "svg_lists": n,
                "load_tested_by": "Tests/FpcCoreTests/svg/SvgLfmProbe.lpr",
            }
        for src, why in refused:
            print(f"  REFUSED {src}: {why}")
    if args.emit_vimage_fragment:
        written, refused = emit_vimage_fragment(dfms, out_dir, dropped)
        print("TVirtualImage fragments:")
        for rel, n, srcs in written:
            print(f"  {rel}  ({n} node(s) from {len(srcs)} form(s))")
            for src, names in srcs:
                print(f"    {src}: {', '.join(names)}")
            provenance[rel] = {
                "rule": "vimage-fragment",
                "nodes": n,
                "load_tested_by": "Tests/FpcCoreTests/imgcoll/ImgCollProbe.lpr",
            }
        for src, why in refused:
            print(f"  REFUSED {src}: {why}")
    if dropped:
        print("dropped Delphi-only properties:")
        for k, n in dropped.most_common():
            print(f"  {k}: {n}")
    if converted and args.only in ("svg", "all"):
        print("SVG rule applied (TSVGIconImageList -> TLclSvgImageList):")
        for src, rel in converted:
            print(f"  {rel}")
    # Written BEFORE the failure return. Provenance for a partial run is
    # exactly the provenance someone needs -- "which of these 50 files did this
    # invocation actually produce, and which refused?" -- and writing it only
    # on success meant one refused form (Tools/Packman/Main, refused for the
    # whole of 2026-10-06) silently suppressed the manifest for all 50 files.
    manifest_path.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8", newline="\r\n")
    if failures:
        print("FAILURES:")
        for name, why in failures:
            print(f"  {name}: {why}")
        return 1
    print(f"output: {out_dir}")
    print("NOTE: structural conversion only -- LCL deserialisation is verified")
    print("      separately by Tests/FpcCoreTests/svg/SvgLfmProbe.lpr for the")
    print("      SVG lists, which is the only part that has ever been run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
