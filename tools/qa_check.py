#!/usr/bin/env python3
"""
Dev-Cpp-Modern 静态质量门禁 (Static QA Gate)

纯 Python 标准库实现，无第三方依赖；在任意含 Python 3.8+ 的环境 (Linux/WSL2/
macOS/Windows) 与 GitHub Actions (ubuntu-latest) 下 1 秒级冷启动运行。

退出码约定:
  0  全部检查通过
  1  至少一项检查失败 (以 `path: error: ...` / `path:line: error: ...` 输出)

覆盖的 5 类检查 (详见 check_* 函数):
  1  check_encoding_and_endings   编码 / BOM / 行尾 (CRLF)
  2  check_project_xml            devcpp.dproj XML 合法性
  3  check_dialect_anti_patterns  FPC 遗毒 / 非法属性 Getter / 保留字字段
                                (受 --profile 控制: delphi 禁 FPC 痕迹,
                                 fpc / both 放行 FPC/LCL 专有写法)
  4  check_search_paths           单元目录与 DCC_UnitSearchPath 闭环
  5  check_win64_pointer_truncation  Win64 指针截断预警

扫描范围 (现代化改造面, 而非全仓 680 文件):
  - 活跃模块目录:        Source/Core, Source/Debugger, Source/LSP,
                         Source/UI, Source/Theme, Source/Toolchain
  - 触及的跟踪文件:      Source/main.pas / Editor.pas / Compiler.pas /
                         Debugger.pas / devcpp.dpr / devcpp.dproj
  - 根 manifest:          devcpp.exe.manifest
  - Vendored 第三方目录 Source/VCL 与根 FastMM*.pas 一律排除。
"""

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_scope  # noqa: E402
import mainform_baseline as _baseline_mod  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

# ---------------------------------------------------------------------------
# 方言门禁 profile（Phase-F / F0 平移期）
#   delphi : 默认。沿用现行策略 —— 禁止 FPC/LCL 痕迹，仓库只允许 Delphi 方言。
#   fpc    : 平移期 profile。放行 FPC/LCL 专有写法（TProcess / LCLVersion 等），
#            但仍禁止与编译器无关的坏语法（Write-Host 残留 / 非法属性 getter）。
#   both   : 等价于 fpc 的宽松 profile（仅执行与方言无关的检查）。
# 默认 delphi —— 保证 qa_gate.yml 现有行为与历史一致；显式传参才切换。
# ---------------------------------------------------------------------------
PROFILE = "delphi"

# 现代化改造面：活跃模块目录（递归 .pas 参与所有检查）
ACTIVE_DIRS = [
    "Source/Core",
    "Source/Debugger",
    "Source/LSP",
    "Source/UI",
    "Source/Theme",
    "Source/Toolchain",
]

# 触及的跟踪文件（参与编码/XML 检查）
TOUCHED_FILES = [
    "Source/main.pas",
    "Source/Editor.pas",
    "Source/Compiler.pas",
    "Source/Debugger.pas",
    "Source/devcpp.dpr",
    "Source/devcpp.dproj",
]

MANIFEST = "devcpp.exe.manifest"

# Vendored 第三方目录（绝对排除）
VENDORED_DIRS = {"Source/VCL"}

# FPC/Lazarus 平移子工程目录（Phase-F）。
# 这些目录遵循 Lazarus/FPC 社区惯例（LF 行尾、允许 TProcess 等 FPC 写法），
# 由 .github/workflows/fpc_ci.yml 单独验收，不受 Delphi 方言门禁约束。
FPC_DIRS = ("Source/Fpc", "Tests/FpcCoreTests")

# Vendored 第三方根文件（按文件名前缀排除）
VENDORED_PREFIXES = ("FastMM",)

errors = []


def fail(msg, *args):
    errors.append(msg % args)


# ---------------------------------------------------------------------------
# 文件收集
# ---------------------------------------------------------------------------
def active_pas_files():
    """返回 (repo-relative-posix, Path) 迭代器：活跃模块目录下的所有 .pas/.dfm"""
    for d in ACTIVE_DIRS:
        base = ROOT / d
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if p.is_file() and p.suffix.lower() in (".pas", ".dfm"):
                yield p.relative_to(ROOT).as_posix(), p


def touched_files():
    for f in TOUCHED_FILES:
        p = ROOT / f
        if p.exists():
            yield f, p
    m = ROOT / MANIFEST
    if m.exists():
        yield MANIFEST, m


def all_check_files():
    """编码检查覆盖的全部文件 (活跃模块 + 触及文件 + manifest)"""
    seen = set()
    for rel, p in active_pas_files():
        seen.add(rel)
        yield rel, p
    for rel, p in touched_files():
        if rel not in seen:
            yield rel, p


# ---------------------------------------------------------------------------
# 1. 编码 / BOM / 行尾
# ---------------------------------------------------------------------------
def check_encoding_and_endings():
    for rel, p in all_check_files():
        if _is_fpc_dir(p):
            continue  # FPC 子工程遵循 LF 行尾约定
        b = p.read_bytes()
        has_bom = b.startswith(b"\xef\xbb\xbf")
        body = b[3:] if has_bom else b
        suffix = p.suffix.lower()

        # 规则 1: 必须是 CRLF (禁止独立 LF)
        # 移除所有 CRLF 后仍残留的 LF 即为"裸 LF"
        bare = body.replace(b"\r\n", b"").replace(b"\r", b"")
        lone_lf = bare.count(b"\n")
        if lone_lf > 0:
            fail("%s: error: line endings must be CRLF (found %d bare LF)",
                 rel, lone_lf)

        non_ascii = any(x > 0x7F for x in body)

        # 规则 2: BOM
        if rel == "Source/devcpp.dproj":
            if not has_bom:
                fail("%s: error: devcpp.dproj must carry a UTF-8 BOM", rel)
        elif suffix in (".pas", ".dpr"):
            if non_ascii and not has_bom:
                fail("%s: error: file contains non-ASCII but lacks a UTF-8 BOM",
                     rel)
            if (not non_ascii) and has_bom:
                fail("%s: error: pure-ASCII source must NOT carry a UTF-8 BOM",
                     rel)


# ---------------------------------------------------------------------------
# 2. 工程文件 XML 合法性
# ---------------------------------------------------------------------------
def check_project_xml():
    p = SOURCE / "devcpp.dproj"
    if not p.exists():
        fail("Source/devcpp.dproj: error: missing project file")
        return
    try:
        ET.parse(str(p))
    except ET.ParseError as e:
        fail("Source/devcpp.dproj: error: invalid XML: %s", e)


# ---------------------------------------------------------------------------
# 3. 方言反模式 / 坏语法
# ---------------------------------------------------------------------------
# (pattern, 说明) —— 全部为"合法 Delphi 中绝不出现"的精确标记, 零误报
# 与编译器方言无关的坏语法：任何 profile 下都禁止
_FORBIDDEN_CORE = [
    (re.compile(r"\bWrite-Host\b"), "PowerShell 语法残留"),
    (re.compile(r"\bAdd\s+or\s+SetValue\b"), "疑似被拆分/误写的 AddOrSetValue"),
]

# 仅 delphi profile 下生效：FPC/Lazarus 遗毒标记。
# Phase-F 平移期由 --profile fpc / both 放行（这些写法在 FPC 侧是合法的）。
_FORBIDDEN_FPC_LEFTOVER = [
    (re.compile(r"\bTProcess\b"), "FreePascal 'TProcess' (use CreateProcess)"),
    (re.compile(r"\bpoNoConsole\b"), "FreePascal TProcess option 'poNoConsole'"),
    (re.compile(r"\bpoWaitOnExit\b"), "FreePascal TProcess option 'poWaitOnExit'"),
    (re.compile(r"\bLCLVersion\b"), "Lazarus LCL 标注"),
]


def _forbidden_patterns():
    if PROFILE == "delphi":
        return _FORBIDDEN_CORE + _FORBIDDEN_FPC_LEFTOVER
    return _FORBIDDEN_CORE

# 非法属性 getter: `property X: T read <expr> = ...;` (read 子句带 '=')
_ILLEGAL_PROPERTY = re.compile(
    r"\bproperty\s+\w+\s*:\s*[\w.]+\s+read\s+[^;=]+\s*=\s*[^;]+;", re.I)

# 保留字作为字段名: `type:` / `file:` (Object Pascal 保留字)
_RESERVED_FIELD = re.compile(r"(?m)^\s*(type|file)\s*:", re.I)


def _is_fpc_dir(p):
    """判断文件是否位于 FPC/Lazarus 平移子工程目录（相对仓库根）。"""
    try:
        key = p.parent.relative_to(ROOT).as_posix()
    except ValueError:
        return False
    return any(key == d or key.startswith(d + "/") for d in FPC_DIRS)


def _dialect_scan_files():
    for rel, p in active_pas_files():
        if p.suffix.lower() != ".pas":
            continue
        if _is_fpc_dir(p):
            continue  # FPC 子工程有自己的门禁（fpc_ci.yml）
        yield rel, p
    # 根目录自研 .pas (排除 VCL 子目录与 FastMM 等 vendored 根文件)
    for p in sorted(SOURCE.glob("*.pas")):
        rel = p.relative_to(ROOT).as_posix()
        if p.name.startswith(VENDORED_PREFIXES):
            continue
        yield rel, p


# ---------------------------------------------------------------------------
# 方言 profile 与条件编译感知
#
# F1-b 引入了"同一份源码、Delphi 与 FPC 各走一支"的双编译器单元
# (Source/LSP/Process/*)。门禁不能靠目录豁免开洞, 也不能把 {$IFDEF FPC}
# 分支里的合法 FPC 写法误判为"遗毒", 因此这里做**行级感知**:
#   * FPC 遗毒模式只在非 FPC 守卫行上报错;
#   * 与方言无关的坏语法在任何行都报错。
# ---------------------------------------------------------------------------
# 匹配 {$IFDEF X} / {$IFNDEF X} / {$IF X} 与配对的 {$ENDIF}
_IF_DIRECTIVE = re.compile(r"\{\$(IF[A-Z]*|ENDIF)\s*([^}]*)\}", re.I)

# Comment/string stripping is shared with the ratchet (scan_scope). The copy
# that used to live here was the same wrong `\{[^}]*\}` regex: it stopped at
# the first closing brace, so a routine wrapped in `{ ... }` was only partly
# removed and the tail was scanned as live code. Line-at-a-time use here is
# still correct for the dialect scan, because an {$IF} block never nests a
# brace comment; the MainForm scan below uses the whole-file call.
_strip_noise = scan_scope.strip_pascal_code


def _fpc_guarded_lines(text):
    """返回处于 {$IF... FPC ...} 分支内的行号集合。"""
    depth = 0
    fpc_depth = None
    guarded = set()
    for i, line in enumerate(text.splitlines(), 1):
        m = _IF_DIRECTIVE.search(line)
        if m:
            kind = m.group(1).upper()
            cond = m.group(2)
            if kind == "ENDIF":
                if fpc_depth is not None and depth == fpc_depth:
                    fpc_depth = None
                depth = max(0, depth - 1)
            elif kind in ("IF", "IFDEF", "IFNDEF"):
                depth += 1
                # Only the "FPC is defined" direction counts as guarded.
                # {$IFNDEF FPC} / {$IF NOT Defined(FPC)} is the Delphi branch,
                # where FPC idioms remain forbidden.
                positive = (kind != "IFNDEF") and ("NOT" not in cond.upper())
                if fpc_depth is None and positive and \
                        re.search(r"\bFPC\b", cond, re.I):
                    fpc_depth = depth
        if fpc_depth is not None:
            guarded.add(i)
    return guarded


def check_dialect_anti_patterns():
    for rel, p in _dialect_scan_files():
        # 历史 ANSI 文件用 errors="replace" 读取: 禁止的模式均为 ASCII,
        # 编码回退不影响扫描 (编码合规由 checker 1 单独负责)
        text = p.read_text(encoding="utf-8-sig", errors="replace")
        lines = text.splitlines()
        guarded = _fpc_guarded_lines(text)
        for lineno, raw in enumerate(lines, 1):
            line = _strip_noise(raw)
            if not line.strip():
                continue
            # 与方言无关的坏语法: 任何行都检查
            for pat, desc in _FORBIDDEN_CORE:
                if pat.search(line):
                    fail("%s:%d: error: %s", rel, lineno, desc)
            # FPC 遗毒: 仅在非 FPC 守卫行检查
            if PROFILE == "delphi" and lineno not in guarded:
                for pat, desc in _FORBIDDEN_FPC_LEFTOVER:
                    if pat.search(line):
                        fail("%s:%d: error: %s", rel, lineno, desc)
            if _ILLEGAL_PROPERTY.search(line):
                fail("%s:%d: error: illegal property getter (read <expr> = ...)",
                     rel, lineno)
            if _RESERVED_FIELD.search(line):
                fail("%s:%d: error: reserved word used as field name", rel, lineno)


# ---------------------------------------------------------------------------
# 4. 单元搜索路径闭环
# ---------------------------------------------------------------------------
def _unit_search_path():
    p = SOURCE / "devcpp.dproj"
    try:
        root = ET.parse(str(p)).getroot()
    except Exception:
        return []
    for e in root.iter():
        local = e.tag.split("}")[-1] if "}" in e.tag else e.tag
        if local == "DCC_UnitSearchPath" and e.text:
            entries = []
            for seg in e.text.split(";"):
                seg = seg.strip()
                if not seg:
                    continue
                if seg.startswith("$("):
                    continue  # 忽略 $(DCC_UnitSearchPath) 之类的宏
                entries.append(seg.replace("/", "\\").rstrip("\\").lower())
            return entries
    return []


def check_search_paths():
    path_entries = _unit_search_path()
    if not path_entries:
        fail("Source/devcpp.dproj: error: DCC_UnitSearchPath not found or empty")
        return
    for rel, p in active_pas_files():
        if p.suffix.lower() != ".pas":
            continue
        try:
            rel_dir = p.parent.relative_to(SOURCE)
        except ValueError:
            continue  # 不在 Source 下, 跳过
        key = str(rel_dir).replace("/", "\\").rstrip("\\").lower()
        if key == ".":
            continue  # 项目根目录默认在搜索路径中
        if key not in path_entries:
            fail("%s: error: directory '%s' not declared in DCC_UnitSearchPath",
                 rel, key)


# ---------------------------------------------------------------------------
# 5. Win64 指针截断预警
# ---------------------------------------------------------------------------
# 仅匹配"明显指针/句柄/对象引用"的截断: self / 取址 @x / 解引用 x^ /
# 树节点 Data 字段。避免把 `Integer(ByteCount)`、`Integer(Something)` 之类
# 合法的取值转换误判为指针截断。
_POINTER_CAST = re.compile(
    r"\b(Integer|Cardinal|Longint|LongInt|DWORD)\s*\(\s*"
    r"(?:self\b|@\w+|\w+\^|\w+\.(?:Data|Item|Items)\b)",
    re.I)


def check_win64_pointer_truncation():
    for rel, p in active_pas_files():
        if p.suffix.lower() != ".pas":
            continue
        try:
            text = p.read_text(encoding="utf-8-sig")
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if _POINTER_CAST.search(line):
                fail("%s:%d: error: suspicious pointer/handle truncation "
                     "(use NativeInt/NativeUInt)", rel, lineno)


# ---------------------------------------------------------------------------
# 6. MainForm 解耦棘轮门禁 (Phase-F / F1)
#
# main.pas 是上帝窗体, 业务单元直接访问 MainForm.* 会让"去 Delphi"永远
# 无法收敛。本门禁把这项债变成可执行指标:
#   * 基线在 tools/mainform_baseline.json, 任一文件**超过上限即失败**;
#   * 出现基线之外的新文件引用 MainForm. 即失败;
#   * uses 子句引用 main 的单元同样受棘轮约束 (F1 的清零目标);
#   * 某个单元解耦完成时, 在同一提交里把它的上限改成实际值 (含 0)。
# 棘轮只许下降, 不许上升 —— 这是 F1 "解耦债是所有方案的共同税单"的执行形态。
# ---------------------------------------------------------------------------
MAINFORM_BASELINE = ROOT / "tools" / "mainform_baseline.json"
# The ratchet and the gate MUST agree on what a reference is. They used to keep
# two hand-maintained copies of these patterns, and when _MAINFORM_REF was
# corrected (Application. exclusion + case-insensitivity) the gate kept the old
# one and failed on Utils.pas with "grew 3 -> 5" -- a phantom regression
# invented entirely by the drift. One definition, imported, cannot drift.
_MAINFORM_REF = _baseline_mod._MAINFORM_REF
# Bare `MainForm` (no member access) is a second, independent coupling shape:
# it is the window handle handed over as a dialog owner, e.g.
#   with TProjectOptionsFrm.Create(MainForm) do try
# _MAINFORM_REF cannot see it, which is exactly how Project.pas carried a live
# `uses main` edge through a fully green ratchet. It gets its own baseline
# dimension (`owner_refs`) so tightening it never distorts the headline
# `MainForm.` number. `Application.MainForm` is the VCL property rather than our
# god form, so it is excluded.
_MAINFORM_OWNER = _baseline_mod._MAINFORM_OWNER
_USES_MAIN = re.compile(r"(?ims)^\s*uses\b[^;]*?\bmain\b[^;]*;")


def _load_mainform_baseline():
    import json
    try:
        with MAINFORM_BASELINE.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("tools/mainform_baseline.json: error: unreadable: %s", exc)
        return None, None, (), None
    return (data.get("refs", {}), data.get("uses_main", {}),
            tuple(data.get("facade", ())), data.get("owner_refs", {}))


def _source_pas_files():
    for p in sorted(SOURCE.rglob("*.pas")):
        if _is_vendored(p):
            continue
        rel = p.relative_to(ROOT).as_posix()
        # The god form's own `MainForm.` uses are Self references, so the gate
        # must not score it as a consumer of itself. Excluded at the file
        # source (not in each statistic below) so no counter can drift out of
        # sync with the exemption. See scan_scope.GOD_FORM.
        if scan_scope.is_god_form(rel):
            continue
        yield rel, p


def _is_vendored(p):
    try:
        rel = p.relative_to(ROOT).as_posix()
    except ValueError:
        return False
    return (scan_scope.is_excluded(rel)
            or p.name.startswith(VENDORED_PREFIXES))


# A unit that declares the global itself owns it -- that includes the real
# main.pas and the same-named-but-unrelated Tools/PackMaker/main.pas and
# Tools/Packman/Main.pas, so the owner ratchet keys off the declaration instead
# of a hardcoded path.
_MAINFORM_DECL = re.compile(r"(?mi)^\s*MainForm\s*:\s*\w")


def _declares_mainform_global(text):
    head = re.split(r"(?mi)^\s*implementation\s*$", text)[0]
    return bool(_MAINFORM_DECL.search(head))


def _facade_entry_points(unit_name, text):
    """Entry points a facade publishes in its *interface* section."""
    head = re.split(r"(?mi)^\s*implementation\s*$", text)[0]
    return set(re.findall(r"(?mi)^\s*(?:function|procedure)\s+(\w+)", head))


def check_mainform_decoupling():
    refs_cap, uses_cap, facades, owner_cap = _load_mainform_baseline()
    if refs_cap is None:
        return

    refs_now, uses_now, owner_now = {}, {}, {}
    facade_uses = {}
    for rel, p in _source_pas_files():
        try:
            text = p.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            continue
        # only real code counts: comments and strings may mention MainForm.
        # ONE whole-file call: comment depth must carry across line boundaries,
        # or a `{` on its own line never closes and the remainder of the unit is
        # scanned as if it were live code.
        code = _strip_noise(text)
        n = len(_MAINFORM_REF.findall(code))
        if n:
            refs_now[rel] = n
        if _USES_MAIN.search(text):
            uses_now[rel] = True
        # a unit that declares the global owns it (main.pas, and the
        # same-named Tools/PackMaker|Packman units) -- not a leak
        if not _declares_mainform_global(text):
            o = len(_MAINFORM_OWNER.findall(code))
            if o:
                owner_now[rel] = o
        for f in facades:
            stem = f.rsplit("/", 1)[-1][:-4]
            if rel != f:
                hit = set(re.findall(r"\b%s\s*\.\s*(\w+)" % stem, code))
                if hit:
                    facade_uses.setdefault(f, set()).update(hit)

    facade_set = set(facades)
    for rel, n in sorted(refs_now.items()):
        if rel in facade_set:
            continue  # sanctioned anti-corruption layer
        cap = refs_cap.get(rel)
        if cap is None:
            fail("%s: error: new MainForm coupling (%d refs) -- business units "
                 "must go through the UI facade, not the god form", rel, n)
        elif n > cap:
            fail("%s: error: MainForm coupling grew %d -> %d (ratchet cap %d)",
                 rel, cap, n, cap)

    # Ratchet #2: the god form handed over as a dialog owner. Invisible to
    # _MAINFORM_REF, fatal to the build the day `main` leaves the uses clause.
    for rel, n in sorted(owner_now.items()):
        if rel in facade_set:
            continue
        cap = owner_cap.get(rel)
        if cap is None:
            fail("%s: error: new bare-MainForm owner coupling (%d) -- a dialog "
                 "owner must come from the facade (e.g. MainUi.DialogOwner)",
                 rel, n)
        elif n > cap:
            fail("%s: error: bare-MainForm owner coupling grew %d -> %d "
                 "(ratchet cap %d)", rel, cap, n, cap)

    for rel in sorted(uses_now):
        if rel in facade_set:
            continue
        if rel not in uses_cap:
            fail("%s: error: new `uses main` (F1 exit criterion is zero)",
                 rel)

    # Ratchet #3: facade entry-point drift. A consumer calling a facade routine
    # that the facade does not publish is a compile error that only surfaces
    # inside the IDE, so it is worth catching statically.
    for f in sorted(facade_uses):
        p = ROOT / f
        if not p.exists():
            fail("%s: error: sanctioned facade listed in the baseline is missing",
                 f)
            continue
        published = _facade_entry_points(
            f.rsplit("/", 1)[-1][:-4],
            p.read_text(encoding="utf-8-sig", errors="replace"))
        for name in sorted(facade_uses[f] - published):
            fail("error: facade entry point `%s.%s` is called but not declared "
                 "in %s's interface", f.rsplit("/", 1)[-1][:-4], name, f)

    # progress report (only when nothing failed).
    # Count the same population the checks above enforce: facades are exempt
    # from the `uses main` rule (MainUi legitimately *names* main in its
    # implementation uses -- that is the whole point of the anti-corruption
    # layer), so they must not inflate the number reported as "still coupled".
    if not errors:
        facade_refs = sum(refs_now.get(f, 0) for f in facades)
        owner_total = sum(v for k, v in owner_now.items() if k not in facade_set)
        used_facade = sum(len(v) for v in facade_uses.values())
        coupled_uses = sum(1 for r in uses_now if r not in facade_set)
        print("MainForm coupling: %d refs (cap %d) across %d files "
              "[+ %d in %d facade unit(s)]; `uses main`: %d units (cap %d); "
              "owner-coupling: %d (cap %d); facade entry points in use: %d"
              % (sum(refs_now.values()) - facade_refs, sum(refs_cap.values()),
                 len(refs_now) - len(facades), facade_refs, len(facades),
                 coupled_uses, sum(1 for r in uses_cap if r not in facade_set),
                 owner_total, sum(owner_cap.values()), used_facade))


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Dev-Cpp-Modern static QA gate")
    ap.add_argument(
        "--profile", choices=("delphi", "fpc", "both"), default="delphi",
        help="dialect profile: delphi (default; no FPC/LCL traces allowed) / "
             "fpc (allow FPC/LCL idioms) / both (alias of fpc)")
    args = ap.parse_args(argv)

    global PROFILE
    PROFILE = args.profile

    check_encoding_and_endings()
    check_project_xml()
    check_dialect_anti_patterns()
    check_search_paths()
    check_win64_pointer_truncation()
    check_mainform_decoupling()

    if errors:
        for msg in errors:
            print(msg, file=sys.stderr)
        print("QA gate: %d error(s)" % len(errors), file=sys.stderr)
        return 1
    print("QA gate: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())