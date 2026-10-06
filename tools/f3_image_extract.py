#!/usr/bin/env python3
"""Extract Vcl.ImageCollection payloads out of Source/DataFrm.dfm.

WHY THIS TOOL EXISTS
====================
`TVirtualImage` was recorded as "external, LCL has an equivalent, so this is a
field-level rename". Measurement said otherwise, at all three use sites:

    EnviroFrm.viThemePreview   ImageCollection = dmMain.AppearanceThemeCollection
    LangFrm.VirtualImageTheme  ImageCollection = dmMain.ImageThemeColection
    main.ImageEmbarcadero      ImageCollection = dmMain.EMBTImageCollection

Every one of them is a *named-image fetcher* over a collection that lives in
DataFrm.dfm. So the blocker is not a class, it is a payload: 32 inline
bitmaps, ~1.27 MB, which is 72% of a 1.74 MB DFM. Renaming the field without
carrying those bytes produces a control that compiles and draws nothing --
the same class of defect this project has already hit three times.

WHAT IS EXTRACTED, AND WHERE
============================
The bitmaps turned out to be PNG already: `Image.Data = { 89504E470D0A... }`
is a hex blob whose first eight bytes are the PNG signature. That makes
extraction a hex decode -- no image library, no re-encoding, and therefore no
resampling loss between what the DFM holds and what ships.

    Source/DataFrm.dfm
        --(this tool)-->
    Source/Fpc/UI/Data/Images/<Collection>/<NN>_<slug>.png   the bytes
    Source/Fpc/UI/Data/img_manifest.json                      sha256 + dims
    Source/Fpc/UI/Data/ImageCollectionData.pas               index unit

The manifest and the unit carry NO image data, only names, dimensions and file
names. That split is deliberate and it is the same split SvgData uses: the
generated Pascal carries what the control needs to resolve an index, the files
carry the payload.

WHY THE PAYLOAD IS FILES AND NOT A GENERATED UNIT
=================================================
It was tried. A 1.3 MB `const BIG: array[0..N] of Byte = (...)` does not
compile at all:

    BigData.pas(6,3) Error: Incompatible types: got "Constant String" expected "Byte"

FPC will not take string literals in a typed Byte array constant, and a typed
constant record cannot hold dynamic array fields either (SvgData works around
that by filling a `var` array from flat string consts in `initialization`).
There is no byte-for-byte const form, so the bytes go to disk and the unit
carries the index. Byte identity is enforced by sha256 in `--verify`, not by
the compiler.

HOW FAILURE IS MADE LOUD
========================
Every structural assumption below is an assertion, not a `re.search` that
returns None and gets ignored:

  * each TImageCollection item must have exactly `Name` then `SourceImages`,
    in that order, and nothing else;
  * `SourceImages` must hold exactly one item, carrying exactly `Image.Data`;
  * the decoded bytes must begin with the PNG signature;
  * the IHDR must be present so width/height can be read.

DataFrm.dfm is uniform today (verified: all three collections carry exactly
`{Name, SourceImages}` -> `{Image.Data}` and nothing else). The day it stops
being uniform this tool must fail rather than silently skip the part it did
not understand -- a skipped bitmap is a blank preview, which is precisely the
failure being fixed.

USAGE
    python tools/f3_image_extract.py            # write files, unit, manifest
    python tools/f3_image_extract.py --verify   # byte-compare, exit 1 on drift
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DFM = os.path.join(REPO, "Source", "DataFrm.dfm")
DATA_DIR = os.path.join(REPO, "Source", "Fpc", "UI", "Data")
IMAGES_DIR = os.path.join(DATA_DIR, "Images")
MANIFEST = os.path.join(DATA_DIR, "img_manifest.json")
UNIT = os.path.join(DATA_DIR, "ImageCollectionData.pas")

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class ExtractError(Exception):
    """Raised when the DFM does not have the shape this tool knows how to read."""


# ---------------------------------------------------------------------------
# PNG header
# ---------------------------------------------------------------------------
def png_geometry(blob: bytes) -> tuple[int, int, int]:
    """Return (width, height, colour_type) read from the IHDR chunk.

    Layout: 8 signature bytes, then a 4-byte big-endian length, the 4-byte type
    'IHDR', then width (4, BE), height (4, BE), bit depth (1), colour type (1).
    """
    if not blob.startswith(PNG_MAGIC):
        raise ExtractError("payload is not a PNG (bad signature)")
    if blob[12:16] != b"IHDR":
        raise ExtractError("first chunk is %r, expected IHDR" % blob[12:16])
    width = int.from_bytes(blob[16:20], "big")
    height = int.from_bytes(blob[20:24], "big")
    depth = blob[24]
    colour = blob[25]
    if width == 0 or height == 0:
        raise ExtractError("degenerate %dx%d image" % (width, height))
    # Depth is carried through the manifest for diagnostics only; nothing in
    # the control depends on it.
    _ = depth
    return width, height, colour


# ---------------------------------------------------------------------------
# DFM parsing
# ---------------------------------------------------------------------------
COLL_RE = re.compile(r"^  object (\w+): TImageCollection\s*$", re.M)


def parse_collections(text: str) -> list[dict]:
    """Parse every TImageCollection block out of a DFM.

    The block runs to the next sibling `  object ` at the same indent. Both the
    declaration and that terminator are matched with MULTILINE so the anchors
    are line starts, not 'anywhere in a line'.
    """
    out = []
    for m in COLL_RE.finditer(text):
        name = m.group(1)
        start = m.end()
        nxt = re.search(r"\n  object ", text[start:])
        end = start + nxt.start() if nxt else len(text)
        out.append({"name": name, "body": text[start:end]})
    if not out:
        raise ExtractError("no TImageCollection found in %s" % DFM)
    return out


def parse_items(coll: dict) -> list[dict]:
    """Parse the `Images = < ... >` item list of one collection.

    Hand-rolled rather than regex-over-the-whole-block on purpose: the payload
    is 1.27 MB of hex that a lazy pattern would happily half-match. Walking the
    block by line lets every unexpected line be reported by name.
    """
    body = coll["body"]
    lines = body.split("\n")

    # Locate `Images = <` at 4-space indent, then collect `      item` entries
    # until the matching `    end>` that closes the collection.
    try:
        open_at = next(
            i for i, l in enumerate(lines) if l == "    Images = <"
        )
    except StopIteration:
        raise ExtractError("%s: no `Images = <` collection" % coll["name"])

    items = []
    i = open_at + 1
    in_item = False
    while i < len(lines):
        line = lines[i]
        # `Images = <` is written at 4 spaces but its terminator comes back at
        # 6, level with the items. Measured, not assumed: reading the file
        # shows `      end>` between the last `      end` and the collection's
        # own Left/Top properties.
        if line == "      end>":  # closes the Images collection
            break
        if line == "      item":
            if in_item:
                raise ExtractError("%s: unterminated item" % coll["name"])
            in_item = True
            items.append(
                {
                    "_start": i,
                    "props": [],
                    "_name": None,
                    "_hex": [],
                    "_sub_items": 0,
                    "_blobs": 0,
                }
            )
        elif line == "      end":
            if not in_item:
                raise ExtractError("%s: `end` with no open item" % coll["name"])
            in_item = False
        elif in_item:
            items[-1]["_end"] = i
            # Indentation is the only discriminator between an outer-item
            # property and an inner-item line, and the levels are NESTED:
            # `            Image.Data = {` (12 spaces) also satisfies the
            # 8-space outer-property test. So the DEEPER levels are tested
            # first; testing outermost-first silently classifies the blob
            # header as a property name.
            if line == "          item":            # 10 sp: SourceImages sub-item
                items[-1]["_sub_items"] += 1
            elif line == "            Image.Data = {":   # 12 sp: blob opens
                items[-1]["_blobs"] += 1
                items[-1]["_inblob"] = True
            elif line == "            }":             # 12 sp: blob closes
                if not items[-1].get("_inblob"):
                    raise ExtractError(
                        "%s item %r: `}` with no open Image.Data"
                        % (coll["name"], items[-1]["_name"])
                    )
                items[-1]["_inblob"] = False
            elif line.startswith("              "):  # 14 sp: hex payload
                if not items[-1].get("_inblob"):
                    raise ExtractError(
                        "%s item %r: hex line outside a blob"
                        % (coll["name"], items[-1]["_name"])
                    )
                chunk = line.strip()
                # The DFM closes the blob on the SAME line as the last hex
                # chunk (`...44AE426082}`), not on a line of its own.
                if chunk.endswith("}"):
                    chunk = chunk[:-1].strip()
                    items[-1]["_inblob"] = False
                items[-1]["_hex"].append(chunk)
            elif line == "          end>":            # 10 sp: sub-item closes
                pass
            elif line.startswith("        ") and not line.startswith("          "):
                stripped = line[8:]
                m = re.match(r"^(\w[\w.]*) = (.*)$", stripped)
                if not m:
                    raise ExtractError(
                        "%s: unparsable property line %r" % (coll["name"], line)
                    )
                items[-1]["props"].append(m.group(1))
                if m.group(1) == "Name":
                    q = re.match(r"^'(.*)'$", m.group(2))
                    if not q:
                        raise ExtractError(
                            "%s: Name is not a quoted string: %r"
                            % (coll["name"], m.group(2))
                        )
                    items[-1]["_name"] = q.group(1)
                elif m.group(1) == "SourceImages":
                    if m.group(2) != "<":
                        raise ExtractError(
                            "%s: SourceImages is %r, expected <"
                            % (coll["name"], m.group(2))
                        )
                else:
                    raise ExtractError(
                        "%s: unexpected item property %r"
                        % (coll["name"], m.group(1))
                    )
            else:
                raise ExtractError(
                    "%s: unrecognised line inside item: %r" % (coll["name"], line)
                )
        else:
            raise ExtractError(
                "%s: unrecognised line inside Images: %r" % (coll["name"], line)
            )
        i += 1
    else:
        raise ExtractError("%s: `Images = <` never closed" % coll["name"])

    if in_item:
        # A DFM collection may omit the LAST item's `end` -- the `end>` that
        # terminates the collection closes it instead. That shorthand is real
        # (DataFrm.dfm uses it) and is accepted here without weakening the
        # gate: every assertion below still applies to this item, so it cannot
        # smuggle in a nameless or blobless entry.
        in_item = False

    for it in items:
        props = it["props"]
        if props != ["Name", "SourceImages"]:
            raise ExtractError(
                "%s item %r: properties are %r, expected exactly "
                "['Name', 'SourceImages']" % (coll["name"], it["_name"], props)
            )
        if it["_name"] is None:
            raise ExtractError("%s: an item has no Name" % coll["name"])
        # Exactly one inner item carrying exactly one Image.Data. A second
        # inner item would be a second image at the same index, and Delphi's
        # SourceImages is a multi-resolution set -- taking only the first
        # would silently drop every other scale. None at all means a blank.
        if it["_sub_items"] != 1:
            raise ExtractError(
                "%s item %r: SourceImages holds %d item(s), expected exactly 1"
                % (coll["name"], it["_name"], it["_sub_items"])
            )
        if it["_blobs"] != 1:
            raise ExtractError(
                "%s item %r: holds %d Image.Data blob(s), expected exactly 1"
                % (coll["name"], it["_name"], it["_blobs"])
            )
        hexed = "".join(it["_hex"])
        if len(hexed) % 2 != 0:
            raise ExtractError(
                "%s item %r: hex payload has odd length %d"
                % (coll["name"], it["_name"], len(hexed))
            )
        try:
            it["bytes"] = bytes.fromhex(hexed)
        except ValueError as exc:
            raise ExtractError(
                "%s item %r: hex payload is not hex: %s"
                % (coll["name"], it["_name"], exc)
            )
    return items


def slug(name: str, index: int) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower()
    return "%02d_%s" % (index, s or "item")


def extract() -> dict:
    with open(DFM, "rb") as fh:
        raw = fh.read()
    # Normalise CRLF before walking lines. The repo stores CRLF, so a raw
    # `split("\n")` leaves a trailing \r on every line and every equality test
    # below silently fails to match -- which reads as "no Images = < found".
    text = raw.decode("latin-1").replace("\r\n", "\n")

    collections = []
    total = 0
    for coll in parse_collections(text):
        items = parse_items(coll)
        rec = {"name": coll["name"], "items": []}
        for idx, it in enumerate(items):
            blob = it["bytes"]
            w, h, colour = png_geometry(blob)
            rec["items"].append(
                {
                    "index": idx,
                    "name": it["_name"],
                    "file": "%s/%s.png" % (coll["name"], slug(it["_name"], idx)),
                    "bytes": len(blob),
                    "width": w,
                    "height": h,
                    "colour_type": colour,
                    "sha256": hashlib.sha256(blob).hexdigest(),
                    "blob": blob,
                }
            )
        collections.append(rec)
        total += len(items)

    return {
        "dfm_bytes": len(raw),
        "payload_bytes": sum(
            it["bytes"] for c in collections for it in c["items"]
        ),
        "collections": collections,
        "total_items": total,
    }


# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------
def pascal_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def pascal_string_array(decl: str, values: list[str]) -> list[str]:
    """One typed string-array constant, comma-separated.

    No trailing comma: FPC rejects it in a typed constant declaration, which
    reads as a syntax error on the LAST element rather than as anything to do
    with trailing commas, so it is easy to lose an hour to.

        unit t1;  A: array[0..2] of string = ('a','b','c',);
        t1.pas(7,6) Fatal: Syntax error, ")" expected but "," found
    """
    lines = ["  %s: array[0..%d] of string = (" % (decl, len(values) - 1)]
    for i, v in enumerate(values):
        lines.append("    %s%s" % (pascal_str(v), "," if i < len(values) - 1 else ""))
    lines.append("  );")
    return lines


def pascal_int_array(decl: str, values: list[int]) -> list[str]:
    """One typed integer-array constant, same trailing-comma rule."""
    lines = ["  %s: array[0..%d] of Integer = (" % (decl, len(values) - 1)]
    for i, v in enumerate(values):
        lines.append("    %d%s" % (v, "," if i < len(values) - 1 else ""))
    lines.append("  );")
    return lines


def render_unit(data: dict) -> str:
    """Render ImageCollectionData.pas.

    Shape mirrors SvgData.pas: flat typed constants for what the compiler can
    hold, a `var` array of records filled in `initialization` for what it
    cannot. No image bytes -- see the module docstring.

    Widths and heights are two parallel Integer arrays rather than an array of
    TPoint. TPoint would mean depending on `Types` for a record that carries no
    information a pair of integers does not, and its `Point(x, y)` initialiser
    is a function call where FPC wants a constant.
    """
    out = []
    w = out.append
    w("{ Vcl.ImageCollection index extracted from Source/DataFrm.dfm.")
    w("  Generated by tools/f3_image_extract.py -- do not hand-edit; re-run the tool.")
    w("")
    w("  This unit carries NAMES and DIMENSIONS only. The images themselves are")
    w("  files under Source/Fpc/UI/Data/Images, byte-verified against the DFM by")
    w("  `f3_image_extract.py --verify`. FPC cannot express a multi-megabyte typed")
    w("  constant of bytes, so the payload lives on disk and this is the index.")
    w("}")
    w("unit ImageCollectionData;")
    w("")
    w("interface")
    w("")
    w("type")
    w("  /// One named image of one collection.")
    w("  TImageCollItem = record")
    w("    /// The DFM's `Name`. Kept because it is what a human reads, and it is")
    w("    /// what the combo boxes pair with -- but NEVER a lookup key: names")
    w("    /// repeat across a collection, so resolving by name would be ambiguous.")
    w("    Name: string;")
    w("    /// Path relative to the images root, using forward slashes so the")
    w("    /// manifest and the unit mean the same thing on every platform.")
    w("    FileName: string;")
    w("    Width: Integer;")
    w("    Height: Integer;")
    w("  end;")
    w("")
    w("  TImageCollectionRec = record")
    w("    Name: string;")
    w("    /// In index order. Index order IS the contract: every call site drives")
    w("    /// these controls by `ImageIndex`, never by name.")
    w("    Items: array of TImageCollItem;")
    w("  end;")
    w("")
    w("const")
    for c in data["collections"]:
        up = c["name"].upper()
        n = len(c["items"])
        w("  /// %s: %d item(s)." % (c["name"], n))
        out.extend(pascal_string_array("%s_NAMES" % up, [it["name"] for it in c["items"]]))
        out.extend(pascal_string_array("%s_FILES" % up, [it["file"] for it in c["items"]]))
        out.extend(pascal_int_array("%s_WIDTHS" % up, [it["width"] for it in c["items"]]))
        out.extend(pascal_int_array("%s_HEIGHTS" % up, [it["height"] for it in c["items"]]))
        w("")
    w("var")
    w("  /// Every collection found in DataFrm.dfm, in declaration order.")
    w("  IMAGE_COLLECTIONS: array[0..%d] of TImageCollectionRec;" % (len(data["collections"]) - 1))
    w("")
    w("/// Number of extracted collections.")
    w("function ImageCollectionCount: Integer;")
    w("/// Index of the collection called AName, or -1. The DFM spells the handle")
    w("/// `dmMain.<Name>`, so the collection name is what a use site names.")
    w("function FindImageCollectionIndex(const AName: string): Integer;")
    w("")
    w("implementation")
    w("")
    w("uses")
    w("  Classes;")
    w("")
    w("procedure FillCollection(var AColl: TImageCollectionRec; const AName: string;")
    w("  const ANames, AFiles: array of string;")
    w("  const AWidths, AHeights: array of Integer);")
    w("var")
    w("  I: Integer;")
    w("begin")
    w("  AColl.Name := AName;")
    w("  SetLength(AColl.Items, Length(ANames));")
    w("  for I := 0 to High(ANames) do")
    w("  begin")
    w("    AColl.Items[I].Name := ANames[I];")
    w("    AColl.Items[I].FileName := AFiles[I];")
    w("    AColl.Items[I].Width := AWidths[I];")
    w("    AColl.Items[I].Height := AHeights[I];")
    w("  end;")
    w("end;")
    w("")
    w("function ImageCollectionCount: Integer;")
    w("begin")
    w("  Result := High(IMAGE_COLLECTIONS) + 1;")
    w("end;")
    w("")
    w("function FindImageCollectionIndex(const AName: string): Integer;")
    w("var")
    w("  I: Integer;")
    w("begin")
    w("  for I := Low(IMAGE_COLLECTIONS) to High(IMAGE_COLLECTIONS) do")
    w("    if IMAGE_COLLECTIONS[I].Name = AName then")
    w("      Exit(I);")
    w("  Result := -1;")
    w("end;")
    w("")
    w("initialization")
    for i, c in enumerate(data["collections"]):
        up = c["name"].upper()
        w(
            "  FillCollection(IMAGE_COLLECTIONS[%d], %s, %s_NAMES, %s_FILES, "
            "%s_WIDTHS, %s_HEIGHTS);"
            % (i, pascal_str(c["name"]), up, up, up, up)
        )
    w("end.")
    return "\r\n".join(out) + "\r\n"


def render_manifest(data: dict) -> str:
    doc = []
    for c in data["collections"]:
        doc.append(
            {
                "collection": c["name"],
                "count": len(c["items"]),
                "items": [
                    {
                        "index": it["index"],
                        "name": it["name"],
                        "file": it["file"],
                        "bytes": it["bytes"],
                        "width": it["width"],
                        "height": it["height"],
                        "colour_type": it["colour_type"],
                        "sha256": it["sha256"],
                    }
                    for it in c["items"]
                ],
            }
        )
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
def write_all(data: dict) -> int:
    for c in data["collections"]:
        for it in c["items"]:
            path = os.path.join(IMAGES_DIR, *it["file"].split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(it["blob"])
    with open(MANIFEST, "wb") as fh:
        fh.write(render_manifest(data).replace("\n", "\r\n").encode("utf-8"))
    with open(UNIT, "wb") as fh:
        fh.write(render_unit(data).encode("utf-8"))
    print(
        "wrote %d images across %d collections (%s bytes of payload)"
        % (
            data["total_items"],
            len(data["collections"]),
            "{:,}".format(data["payload_bytes"]),
        )
    )
    print("  %s" % os.path.relpath(MANIFEST, REPO))
    print("  %s" % os.path.relpath(UNIT, REPO))
    return 0


def verify(data: dict) -> int:
    """Falsifiable gate: every claim is compared against a re-read of disk."""
    problems = []

    for c in data["collections"]:
        for it in c["items"]:
            path = os.path.join(IMAGES_DIR, *it["file"].split("/"))
            if not os.path.exists(path):
                problems.append("missing file %s" % it["file"])
                continue
            with open(path, "rb") as fh:
                disk = fh.read()
            if disk != it["blob"]:
                problems.append(
                    "BYTES DIFFER %s (disk %d bytes, dfm %d bytes)"
                    % (it["file"], len(disk), it["bytes"])
                )
                continue
            try:
                png_geometry(disk)
            except ExtractError as exc:
                problems.append("%s: %s" % (it["file"], exc))

    if not os.path.exists(MANIFEST):
        problems.append("missing %s" % os.path.relpath(MANIFEST, REPO))
    else:
        with open(MANIFEST, "rb") as fh:
            got = json.loads(fh.read().decode("utf-8"))
        want = json.loads(render_manifest(data))
        if got != want:
            problems.append("manifest does not match a fresh extraction")

    if not os.path.exists(UNIT):
        problems.append("missing %s" % os.path.relpath(UNIT, REPO))
    else:
        with open(UNIT, "rb") as fh:
            got = fh.read().decode("utf-8")
        if got != render_unit(data):
            problems.append("ImageCollectionData.pas does not match a fresh extraction")

    # Stray files: an image on disk that the DFM no longer names would keep a
    # stale preview reachable, so its presence is itself a defect.
    if os.path.isdir(IMAGES_DIR):
        expected = {
            it["file"] for c in data["collections"] for it in c["items"]
        }
        for root, _dirs, files in os.walk(IMAGES_DIR):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), IMAGES_DIR)
                if rel.replace("\\", "/") not in expected:
                    problems.append("stray file on disk: %s" % rel)

    if problems:
        print("FAIL: %d problem(s)" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1

    print(
        "OK: %d images / %d collections byte-identical to DataFrm.dfm"
        % (data["total_items"], len(data["collections"]))
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--verify",
        action="store_true",
        help="compare on-disk artefacts against a fresh extraction instead of writing",
    )
    args = ap.parse_args()
    try:
        data = extract()
    except ExtractError as exc:
        print("FAIL: %s" % exc)
        return 2
    try:
        if args.verify:
            return verify(data)
        return write_all(data)
    except Exception as exc:                            # noqa: BLE001
        # A traceback here would still exit 1, which is the right code for the
        # wrong reason: the gate would look like it had rejected the data when
        # in fact it had crashed before saying anything. An unexpected error is
        # reported as itself so it cannot be mistaken for a verdict.
        #
        # This is not hypothetical -- the first version of the byte-mismatch
        # message called len() on an int, so exactly this path fired during the
        # defect-injection run.
        print("FAIL: %s: %s" % (type(exc).__name__, exc))
        return 3


if __name__ == "__main__":
    sys.exit(main())