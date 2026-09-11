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

import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

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
_FORBIDDEN = [
    (re.compile(r"\bTProcess\b"), "FreePascal 'TProcess' (use CreateProcess)"),
    (re.compile(r"\bpoNoConsole\b"), "FreePascal TProcess option 'poNoConsole'"),
    (re.compile(r"\bpoWaitOnExit\b"), "FreePascal TProcess option 'poWaitOnExit'"),
    (re.compile(r"\bLCLVersion\b"), "Lazarus LCL 标注"),
    (re.compile(r"\bWrite-Host\b"), "PowerShell 语法残留"),
    (re.compile(r"\bAdd\s+or\s+SetValue\b"), "疑似被拆分/误写的 AddOrSetValue"),
]

# 非法属性 getter: `property X: T read <expr> = ...;` (read 子句带 '=')
_ILLEGAL_PROPERTY = re.compile(
    r"\bproperty\s+\w+\s*:\s*[\w.]+\s+read\s+[^;=]+\s*=\s*[^;]+;", re.I)

# 保留字作为字段名: `type:` / `file:` (Object Pascal 保留字)
_RESERVED_FIELD = re.compile(r"(?m)^\s*(type|file)\s*:", re.I)


def _dialect_scan_files():
    for rel, p in active_pas_files():
        if p.suffix.lower() != ".pas":
            continue
        yield rel, p
    # 根目录自研 .pas (排除 VCL 子目录与 FastMM 等 vendored 根文件)
    for p in sorted(SOURCE.glob("*.pas")):
        rel = p.relative_to(ROOT).as_posix()
        if p.name.startswith(VENDORED_PREFIXES):
            continue
        yield rel, p


def check_dialect_anti_patterns():
    for rel, p in _dialect_scan_files():
        # 历史 ANSI 文件用 errors="replace" 读取: 禁止的模式均为 ASCII,
        # 编码回退不影响扫描 (编码合规由 checker 1 单独负责)
        text = p.read_text(encoding="utf-8-sig", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for pat, desc in _FORBIDDEN:
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
def main():
    check_encoding_and_endings()
    check_project_xml()
    check_dialect_anti_patterns()
    check_search_paths()
    check_win64_pointer_truncation()

    if errors:
        for msg in errors:
            print(msg, file=sys.stderr)
        print("QA gate: %d error(s)" % len(errors), file=sys.stderr)
        return 1
    print("QA gate: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())