#!/usr/bin/env python3
"""Gate the TVirtualImage -> TLclVirtualImage conversion.

WHY A SEPARATE GATE AND NOT MORE OF f3_lfm_check.py
==================================================
f3_lfm_check.py answers "does this .lfm look like the .dfm it came from".
This one answers "was the conversion CORRECT", and it needs the .dfm, the .lfm,
img_manifest.json and the generated Pascal unit at once. Folding that into the
existing gate would have meant giving it a second job and a second set of
failure messages, and the messages are the whole point.

WHAT IS ASSERTED
================
Each of these was a real way for this conversion to go quietly wrong, and each
is checked against the SOURCE .dfm rather than against the .lfm's own claims --
an .lfm that dropped a control looks perfect to a check that only reads .lfms.

  1. Every `TVirtualImage` in every .dfm has a `TLclVirtualImage` in its .lfm,
     under the same component name. A rename that silently skipped a node
     leaves a form with no preview and a conversion that reported success.
  2. No .lfm anywhere still names `TVirtualImage`. This is the check that would
     have caught the original roadmap item being wrong: the class is a Delphi
     VCL class, and an .lfm carrying it cannot stream.
  3. `ImageCollection` is a bare quoted name that EXISTS in img_manifest.json.
     A surviving `dmMain.X` is the pre-rewrite form; an unknown X is a
     reference to a collection nobody extracted, which paints nothing.
  4. Every `ImageHeight` the converter dropped was 0.
     `ImageHeight` has no LCL counterpart, so the converter drops it -- and
     dropping it is only safe while it means "use the source size". The first
     run of that rule recorded the dropped VALUES for exactly this check; a
     counter cannot answer it, so the values are read from the .dfm here.
  5. img_manifest.json, ImageCollectionData.pas and the PNG files on disk all
     still match DataFrm.dfm, delegated to `f3_image_extract.py --verify`
     rather than re-implemented. One implementation of "does the extracted
     payload still equal the source" is worth more than two.
  6. Each collection has at least one item and every item has a distinct file
     name. A duplicate file name would make two indices load the same picture
     while both reports say nothing is wrong.

WHAT IS DELIBERATELY NOT ASSERTED
=================================
That the images LOOK right. The probe
(Tests/FpcCoreTests/imgcoll/ImgCollProbe.lpr) decodes every PNG and checks it
has content; a static gate that also claimed to know what a theme preview
should look like would be a second opinion nobody could act on.

Run:  python tools/f3_imgcoll_check.py
Exit: 0 when every assertion holds; 1 otherwise, with each failure named.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "Source"
FORMS = REPO / "Source" / "Fpc" / "UI" / "Forms"
MANIFEST = REPO / "Source" / "Fpc" / "UI" / "Data" / "img_manifest.json"

# The VCL class name that must not survive anywhere in the generated output.
VCL_CLASS = "TVirtualImage"
LCL_CLASS = "TLclVirtualImage"

OBJ_RE = re.compile(r"^(\s*)(?:object|inherited|inline)\s+(\w+)\s*:\s*(\w+)\s*$")
PROP_RE = re.compile(r"^(\s*)(\w[\w.\[\]]*)\s*=\s*(.*)$")


def text_of(path: pathlib.Path) -> str:
    """Read a text artefact with CRLF normalised.

    The tree is CRLF by policy and the .lfm writer emits `newline="\r\n"`, so
    anchoring a regex at `$` without normalising first silently fails to match
    every line. f3_lfm_check.text_of does the same thing for the same reason.
    """
    return path.read_bytes().decode("utf-8", errors="replace").replace("\r\n", "\n")


def dfms() -> list[pathlib.Path]:
    return sorted(
        p for p in SOURCE.rglob("*.dfm") if "VCL" not in p.parts
    )


def nodes_with_class(path: pathlib.Path, cls: str) -> dict[str, dict[str, str]]:
    """Every `object <name>: <cls>` node in a DFM, with its simple properties.

    Returns component name -> {property: value}. Collection bodies are not
    followed: a TVirtualImage carries none, and walking into one is how the
    earlier fragment emitter ended up matching on the OLD class name and
    silently producing an empty list.
    """
    out: dict[str, dict[str, str]] = {}
    lines = text_of(path).split("\n")
    for i, line in enumerate(lines):
        m = OBJ_RE.match(line)
        if not m or m.group(3) != cls:
            continue
        props: dict[str, str] = {}
        for nxt in lines[i + 1:]:
            pm = PROP_RE.match(nxt)
            if pm:
                props[pm.group(2)] = pm.group(3).strip()
            elif nxt.strip() == "end" and len(nxt) - len(nxt.lstrip()) == len(m.group(1)):
                break
        out[m.group(2)] = props
    return out


def main() -> int:
    problems: list[str] = []

    if not MANIFEST.is_file():
        print("FAIL: %s is missing; run tools/f3_image_extract.py" % MANIFEST)
        return 1
    collections = {
        row["collection"]: row for row in json.loads(MANIFEST.read_text(encoding="utf-8"))
    }
    print("collections in img_manifest.json: %d" % len(collections))
    for name, row in sorted(collections.items()):
        print("  %-26s %d item(s)" % (name, row["count"]))

    converted = 0
    dropped_heights: list[tuple[str, str]] = []

    for dfm in dfms():
        src_nodes = nodes_with_class(dfm, VCL_CLASS)
        if not src_nodes:
            continue
        rel = dfm.relative_to(SOURCE).as_posix()
        lfm = FORMS / rel.replace(".dfm", ".lfm")
        if not lfm.is_file():
            # Not necessarily a defect: a form can be batch C and never
            # converted. What matters is that it is not converted PARTIALLY,
            # so the check below only runs when the .lfm exists.
            print("  %s: %d VCL node(s), no .lfm (form not converted yet)"
                  % (rel, len(src_nodes)))
            continue
        dst_nodes = nodes_with_class(lfm, LCL_CLASS)
        lcl_names = {n for n in dst_nodes}
        for name, props in src_nodes.items():
            converted += 1
            if name not in lcl_names:
                problems.append(
                    "%s: %s is a %s in the .dfm but is not a %s in the .lfm"
                    % (rel, name, VCL_CLASS, LCL_CLASS))
                continue
            got = dst_nodes[name]
            coll = props.get("ImageCollection")
            if coll is None:
                problems.append("%s: %s declares no ImageCollection" % (rel, name))
                continue
            m = re.match(r"^(\w+)\.(\w+)$", coll)
            if not m:
                problems.append(
                    "%s: %s .dfm ImageCollection is %r, expected `<owner>.<Name>`"
                    % (rel, name, coll))
                continue
            emitted = got.get("ImageCollection", "")
            if emitted != "'%s'" % m.group(2):
                problems.append(
                    "%s: %s .lfm ImageCollection is %r, expected %r"
                    % (rel, name, emitted, "'%s'" % m.group(2)))
            elif m.group(2) not in collections:
                problems.append(
                    "%s: %s names collection %r, absent from img_manifest.json"
                    % (rel, name, m.group(2)))
            # Index and name must survive untouched -- they are what every call
            # site assigns to, and the reader applies them in file order.
            for prop in ("ImageIndex", "ImageName", "ImageWidth"):
                if prop in props and got.get(prop) != props[prop]:
                    problems.append(
                        "%s: %s %s changed %r -> %r"
                        % (rel, name, prop, props[prop], got.get(prop)))
            if "ImageHeight" in props:
                dropped_heights.append(("%s:%s" % (rel, name), props["ImageHeight"]))

    print()
    print("converted TVirtualImage nodes checked: %d" % converted)
    print("dropped ImageHeight values: %d" % len(dropped_heights))
    for where, val in dropped_heights:
        # The whole justification for dropping this property is that it has
        # always meant "use the source size". A non-zero value would silently
        # resize the preview.
        if val.strip() != "0":
            problems.append(
                "%s: ImageHeight was %r, and dropping it would lose the size "
                "(only 0 == 'use the source size' is safe to drop)" % (where, val))

    # 2. Nothing anywhere still DECLARES the VCL class.
    #
    # Matched in class position (`: TVirtualImage` at end of line), not as a
    # substring. The first version used `VCL_CLASS in text` and fired on this
    # repository's own probe fragment, whose carrier class was named
    # `TVirtualImageCarrier` -- a name that CONTAINS the class it is meant to
    # have replaced. The carrier was renamed too: a substring collision here is
    # a trap for the next reader even after the check is corrected.
    stragglers = []
    decl_re = re.compile(r":\s*%s\s*$" % re.escape(VCL_CLASS))
    for lfm in sorted(FORMS.rglob("*.lfm")):
        for line in text_of(lfm).split("\n"):
            if decl_re.search(line):
                stragglers.append("%s: %s" % (lfm.relative_to(FORMS).as_posix(),
                                              line.strip()))
    if stragglers:
        problems.append(
            "%d .lfm still declare %s: %s"
            % (len(stragglers), VCL_CLASS, "; ".join(stragglers)))

    # 6. Distinct file names within each collection.
    for name, row in sorted(collections.items()):
        if row["count"] == 0:
            problems.append("collection %s has no items" % name)
        seen: dict[str, str] = {}
        for it in row["items"]:
            if it["file"] in seen:
                problems.append(
                    "collection %s: %r and %r share the file %s"
                    % (name, seen[it["file"]], it["name"], it["file"]))
            seen[it["file"]] = it["name"]
            if (it["width"] <= 0) or (it["height"] <= 0):
                problems.append(
                    "collection %s item %r has size %dx%d"
                    % (name, it["name"], it["width"], it["height"]))

    # 5. Byte identity with the DFM, delegated rather than reimplemented.
    print()
    print("delegating byte identity to f3_image_extract.py --verify ...")
    sys.stdout.flush()
    rc = subprocess.run(
        [sys.executable, str(REPO / "tools" / "f3_image_extract.py"), "--verify"],
        cwd=str(REPO)).returncode
    if rc != 0:
        problems.append("f3_image_extract.py --verify exited %d" % rc)

    print()
    if problems:
        print("FAIL: %d problem(s)" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1
    print("OK: %d TVirtualImage node(s) converted, payload byte-identical, "
          "no %s left in any .lfm" % (converted, VCL_CLASS))
    return 0


if __name__ == "__main__":
    sys.exit(main())