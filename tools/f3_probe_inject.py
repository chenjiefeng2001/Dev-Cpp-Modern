#!/usr/bin/env python3
"""
f3_probe_inject.py -- prove the F3 form gates can FAIL, by breaking them on purpose.

WHY THIS EXISTS
===============
Sprint F3-6 fixed three defects in `PropRttiProbe.lpr` that had all been
reporting healthy numbers:

  * the collection-block guard compared a TWO-character substring against the
    FOUR-character literal ' = <', so `CollectionBlocks` was structurally
    incapable of incrementing and printed 0 over a corpus holding five;
  * `ValueLastLine` modelled '(', '{' and '+' but not '<', so a
    collection-valued property was put to the reader as a single unterminated
    line -- which reads as SUCCESS, not refusal, because the property never
    reaches the reader as a property at all;
  * with only the opener line skipped, item rows were attributed to the
    ENCLOSING object, so the probe reported `TSynEdit.Command` and
    `TSynEdit.ShortCut` as genuine refusals on a class that has neither.

Every one of those produced a GREEN result over input it had never examined.
That is this project's fourth occurrence of that failure shape, and the first
three were found only because something downstream disagreed. This tool is the
generalisation: it re-introduces each defect, and requires the probe to notice.

THE RULE THAT MATTERS MOST IN HERE
=================================
A build failure ABORTS the injection. The first run of this file measured a
green probe that had never been rebuilt: `build_form_probe.ps1` failed to
compile the injected unit, and the harness went on to run the PREVIOUS
executable, which passed -- so a defective gate was recorded as a passing
gate. That is the "did not rebuild before re-running" trap the F3-SVG plan
records as its fourth instance, and it is why the build's exit status is
checked here rather than trusted. A restore is likewise verified by MD5, not
by assuming the write worked.

WHAT EACH INJECTION PROVES
==========================
  1. collection guard reverted   -> CollectionBlocks drops to 0 and the
                                    false "reader accepts" returns for a
                                    property LCL has no declaration for.
  2. ValueLastLine collection    -> AddedKeystrokes stops being REFUSED.
     branch removed
  3. AngleDelta end-of-line `<`  -> the collection state is never armed, so
     guard removed                 item props are misattributed again.
  4. one skip entry removed      -> FormLfmProbe fails to stream the form
                                    that entry covered.
  5. TSynCppSyn removed from     -> the survey calls EditorOptFrm blocked
     LCL_SUPPLIED                  again, i.e. the roadmap instrument moves.

Run:  python tools/f3_probe_inject.py
Exit: 0 = every injection was detected and every file restored byte-exactly.
      1 = an injection went UNDETECTED (a gate that cannot fail), or a
          restore left the tree dirty.
"""
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIPS = ROOT / "Source" / "Fpc" / "UI" / "Compat" / "VclPropertySkips.pas"
PROBE = ROOT / "Tests" / "FpcCoreTests" / "forms" / "PropRttiProbe.lpr"
PROBE_EXE = ROOT / "Tests" / "FpcCoreTests" / "forms" / "PropRttiProbe.exe"
LFM_EXE = ROOT / "Tests" / "FpcCoreTests" / "forms" / "FormLfmProbe.exe"
SURVEY = ROOT / "tools" / "f3_form_survey.py"

POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


def md5(path: pathlib.Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def read(path: pathlib.Path) -> str:
    """Bytes in, str out -- never pathlib.read_text, which rewrites CRLF to LF
    and would make every restore comparison a lie. The F1-h lesson, still live:
    `Path.read_text()` silently destroyed the line endings the migration
    discipline depends on."""
    return path.read_bytes().decode("utf-8")


def write(path: pathlib.Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))


def run_probe(exe: pathlib.Path) -> tuple[int, str]:
    proc = subprocess.run([str(exe)], cwd=str(exe.parent),
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def build(what: str) -> None:
    """Build the form probes. Raises on failure -- and MUST, because running an
    un-rebuilt binary is how a broken gate gets recorded as a working one."""
    if POWERSHELL is None:
        raise SystemExit("no pwsh/powershell on PATH; cannot build the probes")
    proc = subprocess.run(
        [POWERSHELL, "-NoProfile", "-File",
         str(ROOT / "tools" / "build_form_probe.ps1"), "-Target", what],
        cwd=str(ROOT), capture_output=True, text=True)
    if proc.returncode != 0:
        out = (proc.stdout + proc.stderr)
        raise SystemExit(
            "build of the %s probe(s) FAILED -- aborting rather than running a\n"
            "stale executable, which is the trap this file exists partly to catch:\n%s"
            % (what, out[-2500:]))


def survey_convertible() -> int:
    spec = ROOT / "tools" / "f3_form_survey.py"
    proc = subprocess.run([sys.executable, str(spec)],
                          cwd=str(ROOT), capture_output=True, text=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        if line.startswith("convertible as-is"):
            return int(line.split(":")[1].split("/")[0].strip())
    raise SystemExit("could not read the convertible count from the survey")


# ---------------------------------------------------------------------------
# The injections. `find` must occur EXACTLY the number of times `count` says,
# or the injection is itself reported as broken -- a migration script that
# applies zero of its own edits and reports success is a known failure mode in
# this project.
# ---------------------------------------------------------------------------
INJECTIONS = [
    {
        "name": "collection guard reverted to the 2-character span",
        "why": "The original defect. A 2-character substring can never equal "
               "the 4-character literal ' = <', so the counter could not "
               "increment and printed 0 over five real collection blocks.",
        "target": PROBE,
        "find": "if (Length(Trimmed) > 4) and\n"
                "         (Copy(Trimmed, Length(Trimmed) - 3, 4) = ' = <') then",
        "replace": "if (Length(Trimmed) > 2) and\n"
                   "         (Copy(Trimmed, Length(Trimmed) - 1, 2) = ' = <') then",
        "count": 1,
        "expect_probe": lambda out: "collection blocks : 0" in out,
        "expect_desc": "CollectionBlocks reports 0 over a corpus holding five",
        "build": "props",
        "probe": PROBE_EXE,
    },
    {
        "name": "AngleDelta loses the end-of-line '<' opener",
        "why": "The guard `(I + 1 <= Length(S)) and not (...)` is FALSE when "
               "'<' is the last character, so the collection state was armed "
               "to 0 and item rows fell through to the enclosing object again.",
        "target": PROBE,
        "find": "if I = Length(S) then\n"
                "          Inc(Result)\n"
                "        else if not (S[I + 1] in ['>', '=', '<']) then\n"
                "          Inc(Result);",
        "replace": "if (I + 1 <= Length(S)) and not (S[I + 1] in ['>', '=', '<']) then\n"
                   "          Inc(Result);",
        "count": 1,
        "expect_probe": lambda out: "TSynEdit.Command" in out or "TSynEdit.ShortCut" in out,
        "expect_desc": "item properties are misattributed to TSynEdit again",
        "build": "props",
        "probe": PROBE_EXE,
    },
    {
        "name": "one property-skip entry removed (TSynCppSyn.Options)",
        "why": "Proves the skip registry is load-bearing rather than "
               "decorative: without it the real reader refuses EditorOptFrm.",
        "target": SKIPS,
        "find": "    (Class_: TSynCppSyn; PropertyName: 'Options';\n"
                "     Note: 'Codehunter-patch TSynEditHighlighterOptions; "
                "LCL highlighter has no Options'),\n",
        "replace": "",
        "count": 1,
        "fixups": [("ENTRIES: array[0..18]", "ENTRIES: array[0..17]")],
        "expect_probe": lambda out: "FAIL" in out and "14 of 14" not in out,
        "expect_desc": "FormLfmProbe no longer streams 14 of 14",
        "build": "lfm",
        "probe": LFM_EXE,
    },
]

SURVEY_INJECTION = {
    "name": "TSynCppSyn removed from LCL_SUPPLIED",
    "why": "Proves the roadmap instrument still moves: without the retirement "
           "the survey calls EditorOptFrm blocked again. Asserted against a "
           "count, not a string, because the count is the thing the ratchet "
           "and the schedule depend on.",
    "target": SURVEY,
    # Match the class NAME on its own line rather than the whole set literal.
    #
    # The original pattern pinned `LCL_SUPPLIED = {\r\n    "TSynCppSyn",\r\n}`,
    # which stopped matching the moment F3-7 added TSynRCSyn below TSynCppSyn
    # with an explanatory comment: the injection refused to run and reported the
    # pattern occurring 0 times. That guard did its job -- a stale injection
    # must not silently apply nothing -- but the cost was a failing matrix for a
    # reason that had nothing to do with the property under test.
    #
    # The REPLACE matters just as much, and two wrong versions of it are worth
    # recording because both failed in ways that looked like findings:
    #
    #   * rewriting the set to a single `LCL_SUPPLIED = {\r\n}` DELETED the
    #     TSynRCSyn entry and every comment explaining it, so the survey stopped
    #     printing "convertible as-is" at all and the harness died with "could not
    #     read the convertible count" -- indistinguishable from a real detection.
    #   * commenting the line out (`"TSynCppSyn",  # injected away`) kept it a
    #     live set member, so the count stayed 45 and the gate reported MISSED.
    #
    # Deleting the single line is the only mutation that both removes exactly one
    # entry and leaves the rest of the file intact and valid.
    "find": '    "TSynCppSyn",\r\n',
    "replace": "",
    "count": 1,
    "expect_count_drop": 1,
}


# Pure-Python gate injections: no compiler, no rebuild, so they run as a separate
# matrix from the probe injections above. The one that matters is the FORK --
# reintroducing a second retirement set is exactly how f3_load_routes.py and
# f3_batch_plan.py came to disagree about the same tree, and the gate that
# prevents it has to be shown to prevent it, not merely asserted to.
GATE_INJECTIONS = [
    {
        "name": "a SECOND retirement set is declared in f3_load_routes.py",
        "why": "The drift F3-7 fixed, restored: f3_load_routes.py grows its own "
               "RETIRED literal while the survey keeps one too. Before the fix "
               "this was invisible -- nothing failed, the two tools just "
               "answered differently about the same tree.",
        "target": ROOT / "tools" / "f3_load_routes.py",
        # Anchored on a line that is present exactly once; the injected literal
        # is APPENDED to it, so this is an insertion rather than a replacement
        # and the surrounding file stays syntactically loadable -- the gate has
        # to fail on the FORK, not on a syntax error, or it would be proving the
        # wrong thing.
        "find": "def retired_names(survey):",
        "replace": "F33_RETIRED = {\"TVirtualImage\"}\n\ndef retired_names(survey):",
        "count": 1,
        "expect_gate_fail": "forked retirement set",
        "expect_desc": "f3_retirement_check reports a forked retirement set",
        "gate": ROOT / "tools" / "f3_retirement_check.py",
    },
    {
        "name": "a converter rename with no retirement entry",
        "why": "The other half: if the converter renames a class away and no "
               "tool records it, the roadmap instruments silently stop knowing "
               "what the converter does.",
        "target": ROOT / "tools" / "f3_dfm_to_lfm.py",
        "find": '    "TVirtualImage": "TLclVirtualImage",\r\n}',
        "replace": '    "TVirtualImage": "TLclVirtualImage",\r\n'
                   '    "TProbeOnlyForInjection": "TProbeOnlyForInjection2",\r\n}',
        "count": 1,
        "expect_gate_fail": "no retirement entry",
        "expect_desc": "f3_retirement_check reports an unrecorded rename",
        "gate": ROOT / "tools" / "f3_retirement_check.py",
    },
    {
        "name": "a namespace-spelling unit is deleted from the LCL unit dirs",
        "why": "The F3-8 namespace audit classifies main.pas's blocked units as "
               "SPELLING (drop the prefix, the unit exists) or REAL MISSING. "
               "That classification is a claim about what FPC can compile, so it "
               "must fail when a spelling unit stops being compilable -- "
               "otherwise '60% of main.pas is just renames' silently becomes "
               "'60% of main.pas must be ported', which is the exact opposite "
               "conclusion drawn from the same run.",
        "target": ROOT / "tools" / "f3_namespace_alias.py",
        # Point the audit at an empty unit tree. `Controls` is in group A, so
        # every group-A unit becomes group B and both counts move.
        #
        # Anchored on UNIT_DIRS, not on the bare path string: that path also
        # appears in FU_ORDER, so the pattern matched twice and apply() stopped
        # the whole matrix with "occurs 2 time(s), expected 1". The stale-pattern
        # guard behaved correctly -- but it fired on a pattern that was never
        # stale, only ambiguous, and the result was a matrix that died with no
        # explanation instead of one DETECTED line.
        "find": ('UNIT_DIRS = [\n'
                 '    r"C:\\lazarus\\lcl\\units\\x86_64-win64",'),
        "replace": ('UNIT_DIRS = [\n'
                    '    r"C:\\lazarus\\no-such-unit-tree",'),
        "count": 1,
        "expect_gate_fail": "GREW",
        "expect_desc": "f3_namespace_alias --ratchet reports the set grew",
        "gate": ROOT / "tools" / "f3_namespace_alias.py",
        "gate_args": ["--ratchet"],
    },
    {
        "name": "one form grows a uses-closure (compile surface expands)",
        "why": "The F3-7 ratchet. A form's transitive self-authored closure is "
               "what compiling it costs, and the whole finding of doc F3-SVG "
               "section 18 is that this number is currently 64 units for every "
               "form because of main.pas. Adding one uses clause to a unit the "
               "forms already reach must be caught, or the floor grows silently "
               "and the estimate every later decision rests on becomes fiction.",
        "target": ROOT / "Source" / "ProjectTypes.pas",
        # The WHOLE clause, not the bare word `uses`: ProjectTypes.pas has
        # `uses` twice (interface and implementation), and an earlier version
        # anchored on it -- apply() then refused the injection instead of
        # silently picking one. That refusal is the behaviour to keep: a stale
        # pattern is a hard stop, not a no-op.
        #
        # `Theme` is chosen because it is genuinely OUTSIDE the closure and the
        # dependency is a plausible mistake: a PROJECT-TYPES unit has no business
        # pulling in UI theming, and if it ever did, every form would inherit it
        # through devCFG.
        #
        # Two earlier choices were wrong and both were caught by the harness
        # reporting a MISS rather than by reading the table:
        #   FileAssocs  -- already in the closure, so adding it changed nothing
        #   Core.Events -- ALSO already in the closure (the "outside" list that
        #                  suggested otherwise had been computed with a
        #                  tokeniser that split `Core.Events` into two halves).
        # A ratchet that had passed either would have been passing for the
        # wrong reason: the closure is saturated enough that most additions are
        # invisible, and only additions from genuinely outside can test it.
        "find": "  Classes, editor, ComCtrls, Windows;",
        "replace": "  Classes, editor, ComCtrls, Windows, Theme;",
        "count": 1,
        "expect_gate_fail": "grew",
        "expect_desc": "f3_compile_cost --ratchet reports the closure grew",
        "gate": ROOT / "tools" / "f3_compile_cost.py",
        "gate_args": ["--ratchet"],
    },
]


def apply(entry) -> tuple[str, str]:
    original = read(entry["target"])
    find, replace = entry["find"], entry["replace"]
    # NEWLINE-AGNOSTIC ON PURPOSE.
    # The tree is mixed: f3_form_survey.py is CRLF and VclPropertySkips.pas is
    # LF (measured against HEAD, so this is pre-existing, not something an
    # editor introduced). A pattern written with '\n' therefore matches nothing
    # in a CRLF file, and an injection that silently applies zero edits is the
    # exact failure this file guards against in the OTHER direction -- so the
    # pattern is retried in the file's own line-ending style, and if it still
    # does not match the injection is refused loudly rather than reported green.
    if find not in original and "\n" in find:
        for nl in ("\r\n", "\r"):
            if find.replace("\n", nl) in original:
                find = find.replace("\n", nl)
                replace = replace.replace("\n", nl)
                break
    n = original.count(find)
    if n != entry["count"]:
        raise SystemExit(
            "INJECTION %r: pattern occurs %d time(s), expected %d -- the tree "
            "has moved and this injection is stale. Refusing to run it rather "
            "than silently applying nothing." % (entry["name"], n, entry["count"]))
    mutated = original.replace(find, replace)
    for a, b in entry.get("fixups", []):
        if mutated.count(a) != 1:
            raise SystemExit("fixup %r does not apply once" % a)
        mutated = mutated.replace(a, b)
    write(entry["target"], mutated)
    return original, mutated


def main() -> int:
    failures = []
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="f3inject-"))
    print("F3 PROBE INJECTION -- each gate is broken on purpose and must notice")
    print("=" * 78)
    print()
    print("  A BUILD FAILURE ABORTS. Running an un-rebuilt probe is the trap")
    print("  this file exists partly to catch, so a failed build is never")
    print("  followed by a run.")
    print()

    for entry in INJECTIONS:
        target = entry["target"]
        before = md5(target)
        backup = tmpdir / (target.name + ".orig")
        shutil.copy2(target, backup)
        print("INJECT: %s" % entry["name"])
        print("        %s" % entry["why"])
        print("        into %s" % target.relative_to(ROOT))
        try:
            apply(entry)
            build(entry["build"])
            code, out = run_probe(entry["probe"])
            detected = entry["expect_probe"](out)
            if detected:
                print("  DETECTED -- %s (exit %d)" % (entry["expect_desc"], code))
            else:
                print("  MISSED   -- the probe did not report: %s" % entry["expect_desc"])
                failures.append(entry["name"])
                for line in out.splitlines():
                    if any(k in line for k in
                           ("collection blocks", "REFUSED", "RESULT", "Streamed",
                            "FAIL", "accepted by", "refused by")):
                        print("      | %s" % line.strip())
        finally:
            shutil.copy2(backup, target)
            after = md5(target)
            if after == before:
                print("  RESTORED -- md5 %s unchanged" % before[:12])
            else:
                print("  RESTORE FAILED -- md5 %s -> %s" % (before[:12], after[:12]))
                failures.append(entry["name"] + " (restore)")

    # Pure-Python gate injections: no compiler, no rebuild.
    for entry in GATE_INJECTIONS:
        target = entry["target"]
        before = md5(target)
        backup = tmpdir / (target.name + ".orig")
        shutil.copy2(target, backup)
        print()
        print("INJECT: %s" % entry["name"])
        print("        %s" % entry["why"])
        print("        into %s" % target.relative_to(ROOT))
        try:
            apply(entry)
            proc = subprocess.run(
                [sys.executable, "-W", "ignore", str(entry["gate"])]
                + entry.get("gate_args", []),
                cwd=str(ROOT), capture_output=True, text=True)
            out = proc.stdout + proc.stderr
            if proc.returncode != 0 and entry["expect_gate_fail"] in out:
                print("  DETECTED -- %s (exit %d)"
                      % (entry["expect_desc"], proc.returncode))
            else:
                print("  MISSED   -- the gate did not report: %s"
                      % entry["expect_desc"])
                failures.append(entry["name"])
                # The interesting line is whatever the gate called GREW, not a
                # fixed set of words. The first version of this injection
                # printed only lines containing FORK / HOLE / RESULT, so when the
                # namespace ratchet failed there was nothing to show and the
                # MISSED report was a bare assertion -- which is exactly the
                # shape of bug this matrix exists to make visible.
                shown = [ln for ln in out.splitlines()
                         if "GREW" in ln or "RESULT" in ln or "grew" in ln]
                for line in (shown[:6] or out.splitlines()[-4:]):
                    print("      | %s" % line.strip())
        finally:
            shutil.copy2(backup, target)
            if md5(target) == before:
                print("  RESTORED -- md5 %s unchanged" % before[:12])
            else:
                print("  RESTORE FAILED -- md5 %s -> %s" % (before[:12],
                                                           md5(target)[:12]))
                failures.append(entry["name"] + " (restore)")

    # The survey injection is a pure-Python gate: no build, no probe.
    entry = SURVEY_INJECTION
    target = entry["target"]
    before = md5(target)
    backup = tmpdir / (target.name + ".orig")
    shutil.copy2(target, backup)
    print()
    print("INJECT: %s" % entry["name"])
    print("        %s" % entry["why"])
    try:
        baseline = survey_convertible()
        apply(entry)
        injected = survey_convertible()
        if injected == baseline - entry["expect_count_drop"]:
            print("  DETECTED -- convertible %d -> %d (the roadmap moved back)"
                  % (baseline, injected))
        else:
            print("  MISSED   -- convertible %d -> %d, expected %d"
                  % (baseline, injected, baseline - entry["expect_count_drop"]))
            failures.append(entry["name"])
    finally:
        shutil.copy2(backup, target)
        if md5(target) == before:
            print("  RESTORED -- md5 %s unchanged" % before[:12])
        else:
            print("  RESTORE FAILED")
            failures.append(entry["name"] + " (restore)")

    shutil.rmtree(tmpdir, ignore_errors=True)

    # REBUILD BEFORE REPORTING, OR THE NEXT RUN READS THE LAST INJECTION.
    # ---------------------------------------------------------------------
    # Found by being bitten: the injections rebuild the probes (they have to,
    # a source edit with no rebuild measures the previous binary), but nothing
    # rebuilt them AFTER the restore. So the harness exited 0 -- "every
    # injection detected, every file restored" -- and left FormLfmProbe.exe
    # and PropRttiProbe.exe built from injected source. The probes then failed
    # on a clean tree, which reads exactly like a regression this tool caused.
    #
    # This is the same trap as the build-failure abort above, from the other
    # end: there, a stale binary was run after a failed build; here, one was
    # left behind after a successful build of the wrong source. A tool whose
    # purpose is anti-idle must not be the one that leaves the tree lying.
    print()
    print("REBUILD -- the injected builds are discarded, so the probes must be")
    print("          rebuilt from restored source before this exits.")
    try:
        build("all")
        print("  rebuilt both probes from the restored sources")
    except SystemExit as exc:
        print("  REBUILD FAILED -- the tree on disk is correct but the binaries")
        print("  are stale. Run: ./tools/build_form_probe.ps1 -Target all")
        print(str(exc))
        failures.append("final rebuild")

    print()
    if failures:
        print("RESULT: %d injection(s) went UNDETECTED:" % len(failures))
        for f in failures:
            print("  - %s" % f)
        print()
        print("A gate that cannot fail is indistinguishable from a gate that is")
        print("no longer checking. Do not record these as working.")
        return 1
    print("RESULT: every injection was DETECTED and every file was restored")
    print("        byte-exactly (%d injections)"
          % (len(INJECTIONS) + len(GATE_INJECTIONS) + 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())