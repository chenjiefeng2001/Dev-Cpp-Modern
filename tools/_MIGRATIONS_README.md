# tools/_f*_*.py -- one-shot migration scripts

These are the scripts that performed the F1 / F2 decoupling migrations. They are
kept as an **audit trail**: each one records the exact anchors, the expected hit
counts, and the reasoning behind every deviation, so a future change can be
checked against what was actually done instead of against memory.

## They are NOT re-runnable

Every script asserts the number of times each pattern must match
(`pattern hit N, expected M`) and **aborts the whole batch** on any mismatch.
That is deliberate -- it is what caught a dozen wrong assumptions during the
migrations -- but it also means:

> Running one of these against the current tree will abort, almost immediately,
> because its edits have already been applied.

That is the expected outcome, not a broken script. Do not "fix" the counts to
make a script run again; you would be re-applying a migration to code that has
moved on.

## What to read instead

| To learn... | Read |
|---|---|
| which units are still coupled | `mainform_baseline.py --check` |
| whether a unit can drop `uses main` | `uses_main_audit.py --all` |
| whether the LSP contract is intact | `f2_contract_check.py`, `f2_static_verify.py` |
| what the LSP layer needs from an editor | `lsp_editor_deps.py` |
| whether the Delphi build can run here | `dcc_build.py` |

The live gates are the non-underscore scripts. The `_` prefix here means
"historical", and `_scan_scope_test.py` is the one exception -- it is a live
unit test for `scan_scope.py`, not a migration.

## Naming

| script | migration |
|---|---|
| `_f1n2_migrate.py` | Utils: Application.MainForm -> MainUi.MainFormHandle |
| `_f1o_editoropt_migrate.py` | EditorOptFrm: 8 timer refs -> ApplyEditorAutoSave |
| `_f1p_devcfg_migrate.py` | devCFG: GetCompilationSetIndex -> facade (latin-1 safe) |
| `_f1q_editorlist_migrate.py` | EditorList: last 6 refs -> facade |
| `_f2b_definition_migrate.py` | LSP Definition -> IEditorControlAdapter |
| `_f2b_geometry_migrate.py` | LSP Hover -> IEditorControlAdapter |
| `_f2b_signature_migrate.py` | LSP SignatureHelp -> IEditorControlAdapter |
| `_f2b_editor_side.py` | Editor.pas call sites for the above |
| `_f2_survey.py` | one-off survey of what F2 needed |
| `_f1h_selfcheck.py` | F1 structural self-check |

Two of them encode a lesson worth keeping even as history:

- **`_f1p_devcfg_migrate.py`** -- `devCFG.pas` is latin-1 with cp1252 bytes.
  Reading it as utf-8 with `errors="replace"` silently destroys GCC command-line
  switches. Every later script reads per-file encoding.
- **`_f2b_geometry_migrate.py`** -- the post-condition asserts that no SynEdit
  TYPE survives in code, not merely that `uses` is clean. A unit can drop a unit
  from its uses clause and still name its types in private signatures; those
  compile until the day the adapter is swapped.
