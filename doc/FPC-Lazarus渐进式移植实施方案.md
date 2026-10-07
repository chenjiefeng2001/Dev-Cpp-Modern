# Dev-Cpp-Modern Lazarus/FPC 渐进式更换方案（Phase-F 路线图）

> 制定日期：2026-09-26
> 决策依据：《更换现代UI不依赖Delphi的合理性报告》（结论：去 Delphi 唯一现阶段合理路径 = 方案 A FPC/Lazarus 渐进移植）
> 当前分支：`phase4-lsp-modernize`（HEAD `a5922ec`）
> F0 状态：**已实现并通过本地结构校验**（编译验证由 `.github/workflows/fpc_ci.yml` 承担；开发机无 fpc/lazbuild）

---

## 1. 目标基线与原则

1. **脱困**：以 FPC 3.2.x+ / Lazarus LCL 替代 Delphi 专有编译器，实现 Linux/Windows 无头全自动 CI（GitHub Actions 免费构建与单测）。
2. **保资**：最大限度保护 62k 行自研 Object Pascal 资产，以及 Phase 4 沉淀的 LSP 管道、GDB-MI 协议引擎、工具链探测逻辑。
3. **视觉补偿**：放弃 VCL-Styles，改用 LCL OwnerDraw / BGRAControls + 现代 Fluent/Dark 调色板，逼近 VS Code 观感。
4. **双轨演进**：Delphi 分支与 FPC 分支并行；用 F0/F1 两个低成本里程碑设立"止损线"，杜绝推倒重来。

## 2. 架构分层（协议先行，控件滞后）

```
┌────────────────────────────────────────────────────────┐
│ UI 表现层 (F3/F4)                                      │
│ LCL Forms + Frames (LFM) + BGRAControls 现代暗色/高分屏 │
└───────────────────────────┬────────────────────────────┘
                            │ 仅依赖接口与事件
                            ▼
┌────────────────────────────────────────────────────────┐
│ 接口与服务层 (F1/F2: 纯 Pascal 抽象)                   │
│ Core.Events + Core.Services (IEditorService, ...)      │
└───────────────────────────┬────────────────────────────┘
                            │
       ┌────────────────────┼────────────────────┐
       ▼                    ▼                    ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  LSP 子系统  │     │ GDB-MI 引擎  │     │ 工具链与工程 │
│ Transport/   │     │ Token 队列/  │     │ Toolchain/   │
│ Protocol/Sync│     │ VarManager   │     │ Project/devCFG│
└──────────────┘     └──────────────┘     └──────────────┘
```

## 3. 分阶段里程碑

### F0：极速证伪与无头 CI（1–2 周）——**已交付（待 CI 首跑）**
不碰任何 UI 控件，只验证零 VCL 模块在 FPC 下可编译、可行为验证：

- FPC 测试工程 `Tests/FpcCoreTests/`（Lazarus console 项目，两个变体）：
  - `FpcCorePortable.lpi`：`Core.Events`、`Core.Services`、`GDB.MiTypes`、`GDB.MiParser`、`Lsp.JsonRpc`（纯跨平台，Linux/Windows 共用；F1-a 新增第五个单元）；
  - `FpcCoreWin.lpi`：额外含 `ToolchainConfig`（其实现依赖 Win32 管道/进程 API，仅 Windows 目标可编）。
- 冒烟测试 `FpcCoreTests.lpr`（FPC 专用，不进 Delphi 构建）：GDB/MI 记录解析（`^done`/`*stopped`/带 token 的 `^error`/流记录分片）、事件总线（去重订阅、异常隔离、按类型路由、退订）、事件载荷（断点事件、GDB 变量树）、服务定位器（泛型 `TryGetService`、`QueryService`）、工具链 Profile 切换。
- 门禁双模化 `tools/qa_check.py --profile {delphi,fpc,both}`：默认 `delphi` 行为完全不变；`fpc` profile 放行 `TProcess/LCLVersion` 等 FPC 合法写法，但仍禁止与方言无关的坏语法；FPC 子工程目录（`Tests/FpcCoreTests`、`Source/Fpc`）从 Delphi 编码/方言检查中豁免。
- CI `.github/workflows/fpc_ci.yml`：`gcarreno/setup-lazarus` + `lazbuild`，Linux/Windows 双平台构建并运行测试，另有双 profile 门禁与结构自检作业。
- 结构自检 `tools/fpc_artifact_check.py`：无需 Lazarus 即可校验 .lpr 的 ASCII/块平衡/无 VCL 依赖、.lpi 单元存在性。

**退出判据**：Linux 与 Windows 上 `lazbuild` 纯 FPC 无头编译通过，冒烟测试全绿。

### F1：无头核心解耦（3–4 周）——**F1-a 已完成（2026-09-26）**
已完成：
- **F1-a JSON-RPC 帧层抽取**：新增 `Source/LSP/JsonRpc/Lsp.JsonRpc.pas`（纯 Pascal，零 Win32/零 VCL），承载 `Content-Length` 帧的增量解码器 `TLspFrameDecoder`（分片累积、畸形头丢弃并重同步、超长头拒绝）与组帧函数 `BuildLspFrameBytes` / `BuildLspFrame`；`Lsp.Transport.pas` 改为调用该单元，`FReadBuf` 字段及其内联解析代码一并删除（约 −50 行）。
- **Transport 去 VCL**：`Lsp.Transport.pas` 的 `Vcl.Forms` 属未使用的空导入（实测全单元 `TApplication/TScreen/Synchronize` 零命中），已移除；跨线程派发本就使用 RTL 的 `TThread.Queue`，因此 **Transport 现在只依赖 `Winapi.Windows`（管道/进程）一处**，这是 F1-b 要替换的唯一剩余 Win32 面。
- 上述新单元已加入 `FpcCorePortable.lpi` / `FpcCoreWin.lpi`，并在冒烟测试中新增 **15 项帧编解码检查**（字节长度 vs 字符长度、分片到达、逐字节到达、单次读入多帧、畸形头在同一次调用内跳过并重同步、不完整头缓冲、`Reset`），portable 变体共 **42 项**检查、Windows 变体最多 **44 项**。
- **保真度说明**：抽取过程中发现原内联实现在畸形头上是 `Continue` 立即重扫（同一批字节里的后续完整帧仍会被解析）。解码器 `TryPopBody` 因此采用"调用内重扫循环"，与原行为逐字节一致（每次迭代必然返回或把缓冲区缩短 ≥4 字节，故终止性有保证），并有专门检查项锁定该语义——**重构不改变任何对外行为**。
- `devcpp.dproj` 的 `DCC_UnitSearchPath` 追加 `LSP\JsonRpc`（与既有 Phase-4 单元一致：只登记搜索路径，靠 uses 传递解析，不加 `DCCReference`）。

待完成：
- 消灭非 UI 单元的 `MainForm.*` 直调。**已完成 `Compiler.pas`（22 → 0）、`Project.pas`（27 → 0）、`Editor.pas`（68 → 0）、`Tests.pas`（153 → 0）**，棘轮门禁已就位（见 F1-c / F1-d / F1-e / F1-f），剩余 **177 处 / 27 个文件**（`ProfileAnalysisFrm` 22、`FindFrm` 20、`NewClassFrm` 15、`CPUFrm` 14、`FilePropertiesFrm` 13、`DebugReader` 12、`ViewToDoFrm` 12…）。
- 其余单元的 `uses main` 移除（`Compiler.pas`、`Project.pas`、`Editor.pas`、`Tests.pas` 已完成；`uses main` 单元数 **38 → 25**，其中 9 个为零引用僵尸，已由 `tools/uses_main_audit.py` 判定并清除）。
- 退出判据：CI 门禁统计 `uses ... main` 命中数为 0；F0 冒烟测试保持全绿。

### F1-c：解耦棘轮门禁 + 反腐层 ——**已完成（2026-09-27）**

把"解耦税单"变成**可执行指标**，再动刀：

| 产物 | 作用 |
|---|---|
| `tools/mainform_baseline.json` | 棘轮基线：每文件 `MainForm.*` 上限 + `uses main` 清单 + **facade 豁免名单** |
| `tools/mainform_baseline.py` | 重新生成基线 / `--check` 报告漂移；**上限只许下降** |
| `tools/qa_check.py::check_mainform_decoupling` | 超上限或出现基线外的新耦合即失败；CI 每次推送打印 `MainForm coupling: 177 refs (cap 177) across 27 files [+ 79 in 1 facade unit(s)]; `uses main`: 25 units (cap 25); owner-coupling: 2 (cap 2); facade entry points in use: 78` 形式的进度行（统计口径与检查口径一致：facade 不计入 `uses main`） |
| `tools/uses_main_audit.py` | 回答"这个单元能否摘除 `uses main`"：命名检查 + **传递可见性差集**；两问皆空才判 SAFE |
| `tools/ratchet_reinject.py` | 注入 1 处 `MainForm.*` → 断言门禁拒绝 → 字节级还原 → 断言复绿 |
| `Source/UI/MainUi.pas` | **反腐层**：唯一被豁免的 `MainForm.*` 宿主，暴露 **77 个**语义化入口（Compiler 8 + Project 21 + Editor 28 + 自测 20） |

要点与验证：
- 门禁**先抓错、后放行**：新建 `MainUi.pas` 时立刻报出 `directory 'ui' not declared in DCC_UnitSearchPath`（已修搜索路径），避免"进 IDE 才发现编译不过"。
- 棘轮自身经 4 例注入回归：新文件耦合必报 / 超上限必报 / 新 `uses main` 必报 / 仅注释字符串提及必放行。
- `Compiler.pas` 的 10 步替换**每步带次数断言**，因此拦下两个真实隐患：2 空格缩进的 `Position := 0` 是 4 空格那行的**子串**（会误替换）、`StepIt` 实为 5 处而非 6 处。
- 语义保真：原进度条有 **4 种**调用形态（Reset 三行 / 只设 Max / StepIt / 只设 Position），门面对应拆成 4 个入口，**刻意不合并**以免行为漂移；`MessageBox(MainForm.Handle, ...)` 收入 `ShowError`，caption 仍取 `Lang[ID_ERROR]`。
- 机械交叉校验：Compiler.pas 用到的 8 个门面入口与 `MainUi` 声明**完全一致**（missing: none）；`uses main` 移除后对 main 接口级 929 个符号交叉扫描，唯一命中 `fProject` 经确认为 Compiler 自身字段（粗筛误报）。

### F1-d：Project.pas 脱壳（工程管理域）——**已完成（2026-09-27）**

`Project.pas` 承担 `.dev` 工程描述的序列化、目标文件列表组织与多文件编译依赖图，是仅次于构建管线的核心资产。本次将其 **27 处 `MainForm.*` + 1 处裸 `MainForm` 全部切断**，`uses main` 摘除，全局指标 **425 → 398**，`uses main` 单元 **37 → 36**。

5 大语义切面的门面映射（`Source/UI/MainUi.pas` 早已预置、本次首次被消费）：

| 切面 | 原调用 | 门面入口 |
|---|---|---|
| 工程树 | `MainForm.ProjectView.Items.Add/AddChild/Select/Items[i]/FullExpand/BeginUpdate/EndUpdate` | `AddProjectRootNode` / `AddProjectChildNode` / `SelectProjectNode` / `ProjectViewItem` / `ExpandProjectView` / `ProjectViewBeginUpdate` / `ProjectViewEndUpdate` / `ProjectViewItemCount` |
| 编辑器列表 | `MainForm.EditorList.NewEditor/FileIsOpen/CloseEditor/ForceCloseEditor/PageCount/EditorList[i]/GetVisibleEditors` | `CreateEditor` / `FindOpenEditor` / `TryCloseEditor` / `ForceCloseEditor` / `EditorPageCount` / `EditorAt` / `VisibleEditors` |
| 输出面板 | `MainForm.CompilerOutput.Items.*` / `MainForm.LogOutput.*` | `CompilerOutputItemCount` / `CompilerOutputItemText` / `LogOutputText` |
| 文件监控 | `MainForm.FileMonitor.BeginUpdate/EndUpdate` | `FileMonitorBeginUpdate` / `FileMonitorEndUpdate` |
| 弹窗父句柄 | `TProjectOptionsFrm.Create(MainForm)` | `DialogOwner` |

新增工具与门禁（均为本次实证发现驱动，非预防性堆砌）：

- **`tools/main_symbols.py`**——`MainForm\s*\.` 这条正则**结构性地看不见裸 `MainForm`**。本批次实测：`Project.pas:1550` 的 `TProjectOptionsFrm.Create(MainForm)` 带着一条**活的 `uses main` 边**穿过了全绿的棘轮。该工具改为解析 main.pas **接口级单元作用域**的真实导出（带 `class/record` 嵌套深度跟踪，只取类型名/单元级 var/const/例程，**刻意排除类成员**以免与棘轮重复计数并制造误报），结果：`main.pas` 仅导出 2 个符号（`MainForm`、`TMainForm`）。用它**反向自证**：`Compiler.pas` 0 泄漏、`Project.pas` 改造后 0 泄漏。
- **棘轮 #2（owner-coupling）**——基线新增 `owner_refs` 维度，专门计量裸 `MainForm`；上报 `devCFG.pas` 2 处真实泄漏。上线首跑即报出 2 处**误报**：`Tools/PackMaker/main.pas` 与 `Tools/Packman/Main.pas` 是**同名独立单元、各自声明 `MainForm: TMainForm`**，因此判定改为"**自行声明该全局的单元即拥有它**"而非硬编码路径。
- **棘轮 #3（门面入口漂移）**——消费方调用门面未声明的入口 = 只有进 IDE 才暴露的编译错误。已注入回归：伪造 `MainUi.ThisEntryPointDoesNotExist` 立即报错；当前 **29 个入口在用 / 29 个已声明，missing: none**。
- `Source/UI/MainUi.pas` 的 **1 处裸 LF**（第 49 行注释尾部）被 `check_encoding_and_endings` 当场拦下并修复——说明 `MainUi.pas` 作为未跟踪新文件，此前从未真正跑过 `qa_check`。

其他实证要点：
- **29 vs 27 之谜**：`Project.pas` 文本里有 29 处 `MainForm.`，其中 `SaveLayout` / `SaveUnitLayout` 各 1 处在**注释掉的代码**里（`MainForm.EditorList.LeftPageControl`），按设计不计入基线，故实际可计量值为 27。**`uses main` 摘除后全局是 398 而非 396。**
- **`dmMain` 不在 main.pas**：`Project.pas` 的 `dmMain.GetNewFileNumber` / `GetHighlighter` 常被误判为对上帝窗体的依赖；实测该全局声明在 **`DataFrm.pas`**，而 `DataFrm` 早已在 uses 中——这正是"能摘除 `uses main`"的前提。
- **CRLF 陷阱**：`Project.pas` 是纯 CRLF（1966 CRLF / 0 裸 LF），基于 LF 的多行文本替换会整段失配。迁移脚本因此**按原行尾翻译模式**并对每条替换**断言命中次数**，`ForceCloseEditor` 的 4 空格与 6 空格两处（前者是后者的子串）按"深缩进优先"顺序消费。26 条替换**各命中 1 次**，任一不符则整体不落盘。
- **类型纪律**：`VisibleEditors` 的形参是 `out TObject`，不能直接传 `TEditor` 变量，故按 `MainUi` 接口注释的约定经 `LEditor/REditor: TObject` 中转再强转，保留原有类型检查强度。
- **顺带清理**：`uses` 中的 `EditorList` 仅经 `MainForm.EditorList` 使用，去壳后已无引用，一并移除（更小的传递可见性面）。

### F1-e：Editor.pas 脱壳（编辑器域 / F2 桥头堡）——**已完成（2026-09-27）**

`Editor.pas`（3080 行）决定 IDE 能否在不拖着上帝窗体一起动的前提下替换编辑器引擎（LCL SynEdit / Monaco / WebView2），因此是通往 F2 的决定性桥头堡。本次切断其 **68 处 `MainForm.*`**，全局指标 **398 → 330**，`uses main` 单元 **36 → 35**，含耦合文件 **29 → 28**。

**69 vs 68**：`Editor.pas` 文本命中 69 处，其中 `495: //fTabSheet.OnClose := MainForm.CloseTabProc;` 在注释里，按设计不计量，故基线值为 68。

7 大语义切面（`MainUi` 由 29 → **57 个入口**）：

| 切面 | 原调用 | 门面入口 |
|---|---|---|
| 调试器（17） | `MainForm.Debugger.{BreakPointList, Add/RemoveBreakPoint, DeleteBreakPointsOf, AddWatchVar, SendCommand, OnEvalReady, Executing}` | `BreakPoints`(TList) / `AddBreakPoint` / `RemoveBreakPoint` / `DeleteBreakPointsOf` / `AddWatchVar` / `SendDebuggerCommand` / `SetEvalReadyHandler` / `DebuggerExecuting` |
| 语法解析器（12） | `MainForm.CppParser.{ParseFile, FindAndScanBlockAt, GetHeaderFileName, FindStatementOf, PrettyPrintStatement, IsIncludeLine, InvalidateFile}` | `SharedCppParser: TObject`（调用点强转 `TCppParser`） |
| 当前工程（7） | `MainForm.Project.{Options.useGPP, Directory, Units.IndexOf, SaveUnitAs}` | `CurrentProject: TObject`（调用点强转 `TProject`） |
| 文件监控（4） | `MainForm.FileMonitor.{Monitor, UnMonitor, BeginUpdate, EndUpdate}` | `MonitorFile` / `UnMonitorFile` / 复用 `FileMonitorBeginUpdate` / `FileMonitorEndUpdate` |
| 类浏览器（4） | `MainForm.ClassBrowser.{CurrentFile, BeginUpdate, EndUpdate}` | `SetClassBrowserFile` / `ClassBrowserBeginUpdate` / `ClassBrowserEndUpdate` |
| 输出面板（6） | `MainForm.{Compiler,Resource,Find}Output.Items`（`TListView.Items` 即 `TListItems`） | `CompilerOutputItems` / `ResourceOutputItems` / `FindOutputItems` |
| 状态栏/菜单/动作/控件（18） | `Statusbar.Panels[1].Text`、`Togglebookmarks*.Items[i-1].Checked`、`actGotoImplDeclEditorExecute`、`SetStatusbarLineCol`、`CurrentPageHint`、`UpdateCompilerList`、`OpenFileList`、`EditorPopup`、`CodeCompletion`、`EditorList.GetEditorFromFileName` | `SetStatusbarEditMode` / `SetToggleBookmarksChecked` / `GotoImplDeclInEditor` / `SetStatusbarLineCol` / `SetCurrentPageHint` / `UpdateCompilerList` / `OpenFilesFromList` / `EditorPopupMenu` / `CodeCompletionBox` / `FindEditorByFileName` / 复用 `RefreshAppTitle` |

设计取舍（本批次的分水岭）：
- **领域服务按 `TObject` 交接，UI 状态按语义收敛**。`CppParser` / `CodeCompletion` / `Menus` / `ExtCtrls` 单元**本就在 `Editor.pas` 的 interface uses 中**，故 `TCppParser(MainUi.SharedCppParser).ParseFile(...)` 保留完整编译期类型检查；而 `with MainForm.Statusbar do ... Panels[1].Text := ...` 被压成 `MainUi.SetStatusbarEditMode(Lang[ID_INSERT])`——**泄漏一个 `TStatusBar` 只是给上帝窗体换了顶帽子**，真正的解耦必须让控件不出门面。
- **事件类型本地镜像**：`Debugger.OnEvalReady` 的类型 `TEvalReadyEvent` 声明在 `Debugger.pas`。若门面直接引用它，`Debugger` 就会污染门面接口。故在 `MainUi` 内**结构相同地重声明** `TCodeEvalReady`，转换只在实现段发生（`Debugger` 单元仅加入 `MainUi` 的 implementation uses）。
- **零新增 uses 依赖**：`PBreakPoint` 看似来自 `debugger`（会经 `main` 传递可见），实测它声明在 **`DebugReader.pas`**，而 `debugreader` **早已在** `Editor.pas` 的 implementation uses 中——否则摘除 `main` 就会编译失败。这是本批次最关键的一次"查定义而非猜归属"。
- **69 处压缩到 49 次编辑**：书签勾选的 4 处成对赋值合并为 2 次语义调用（并顺带去掉冗余的 `begin/end` 臂）；`TDebugGutter` 两处文本完全相同的 `bp := PBreakPoint(...)` 用 `count=2` 一次消费。

验证：
- **符号交叉扫描**：`main_symbols.py` 报 0 泄漏（`MainForm` 仅存 495 行注释）。
- **传递可达性差集**：经 `main` 可达、现已不在 `Editor.pas` uses 中的单元共 81 个（40 个可解析到真实 `.pas`），逐个扫描其单元级符号与 `Editor.pas` 的交集，**唯一命中是 `Editor.pas` 自身声明的 `TEditor` / `TSynEditEx` / `TCloseTabSheet` / `TCustomSynEditHelper` / `TSynEditPrintHelper`（自引用误报）**，真实丢失为零。
- **门面零漂移**：57 声明 / 57 在用，双向 `missing: none`（`TDebugGutter` 的 `MainUi.BreakPoints` 每次调用仍是一次属性读，与原先多次访问 `MainForm.Debugger.BreakPointList` 等价）。
- 49 条替换**逐条命中数断言通过**（`bp := ...` 计 2、`Debugger.Executing` 计 2），CRLF 3075 行 / 0 裸 LF，文件行数 3080 → 3075。

### F1-f：Tests.pas 脱壳（自测框架，单批最大）——**已完成（2026-09-27）**

`Tests.pas` 仅 565 行却独占剩余 330 处中的 153（46%），本批**一次击穿 200 大关：330 → 177**，含耦合文件 28 → 27，`uses main` 35 → 34。`MainUi` 由 57 → **77 个入口**。

**风险定性更正**（此前"不在用户路径"的判断有误）：`main.pas:539 actRunTests` 是**真实菜单动作**，`main.pas:7354` 直接 `TTestClass.Create`。它是编译进 `devcpp.exe` 且用户可触发的；真正的风险不是"行为漂移"（那只会表现为测试失败），而是**摘除 `uses main` 失败会让整个二进制编译不过**，爆炸半径比前几批更大。

分布极度集中，95% 压在两个成员上：

| 形态 | 数量 | 门面 |
|---|---|---|
| `SetStatusbarMessage` | 48 | `SetStatusbarMessage` |
| `EditorList.{Left,Right,Focused}PageControl` | 40 | `TObject` + 调用点 `TPageControl(...)` |
| `EditorList.PageCount` | 21 | 复用 `EditorPageCount` |
| `EditorList.Layout = lstXxx` | 20 | **4 个语义谓词**（见下） |
| `EditorList.{GetEditor,GetPreviousEditor,Editors[i],CloseEditor,NewEditor,SwapEditor,Select*Page}` | 17 | `EditorByIndex` / `PreviousEditor` / `EditorAt` / `TryCloseEditor` / `CreateEditorInPage` / `SwapEditor` / `SelectNext|PrevEditorPage` |
| `ToggleBookmarksItem` / `GotoBookmarksItem` | 5 | `ClickToggleBookmark` / `ToggleBookmarkChecked` / `ClickGotoBookmark` |
| `ActionList` / `actNewSource` / `UpdateCompilerList` | 4 | `ActionCount` / `ActionAt` / `ExecuteNewSource` / 复用 `UpdateCompilerList` |

设计要点：
- **枚举不出门面**：`EditorList.Layout` 的类型 `TLayoutShowType` 声明在 `EditorList.pas`。若让门面返回该枚举，`EditorList` 就会进入 `MainUi` 的 **interface**，直接摧毁本单元赖以成立的 `TObject` 纪律。改为 4 个谓词 `EditorLayoutIsNone|IsLeft|IsRight|IsBoth` 后，**调用点反而更好读**：`Assert(MainUi.EditorLayoutIsNone)` 表达的是不变量，而 `Assert(...Layout = lstNone)` 只是在复述属性。
- **控件句柄仍按 `TObject` 交接**：40 处 `TPageControl` 没有诚实的语义包装（"把页控件给我好让测试数它的页数"无法收敛成动作），因此沿用 `MainUi` 既有的 `TTreeNode`/`TListItems`/`TComponent` 纪律；`TPageControl` 来自 ComCtrls，本就在门面接口内。
- **6 处 `TEditor` 返回值必须显式强转**：`e := MainUi.EditorByIndex(...)` 赋给 `e: TEditor` 不会编译通过。因此这些站点按整行重写而非按 token 替换。`GetEditor` 的 5 种调用形态（`i/PC`、无参、`-1/PC`、`-1/内联PC`、嵌在 `SwapEditor` 内的那一处）逐一对应。

**本批次抓到的真实缺陷（工具链自证价值）**：
首次迁移后 `main_symbols.py` 报出 **1 处泄漏** —— `GetEditor` 实际有 5 处调用，而我只构造了覆盖 4 处的模式表，`-1/内联PageControl` 形态**从未被写进任何模式**。**次数断言无法报警**（没有模式 = 没有断言），抓住它的是泄漏检测器本身。这条教训已以注释形式留在 `Tests.pas` 中，并印证了"每个模式都带断言"之外的**第二道防线**（改造后必须重跑符号扫描）的必要性。

验证：
- `main_symbols.py`：0 泄漏（`MainForm` 仅存 324 行注释）。
- **传递可达性差集**：经 `main` 可达、现已不可达的单元 95 个（41 个可解析），符号交集唯一命中 `Tests.pas` 自身声明的 `TTestClass`（自引用），真实丢失为零。
- `EditorList` 亦可摘除：仅经它可达的 10 个单元与 `Tests.pas` 的符号交集为空，已从 uses 移除。
- 门面 77 声明 / 77 在用，双向零漂移；26 条替换逐条断言通过；CRLF 573 行 / 0 裸 LF。
- **`tools/ratchet_reinject.py`**（本批次新增，永久工具）——"每条模式带次数断言"之外的**第二道防线**。它向任一已脱壳单元注入 1 处 `MainForm.*`，断言门禁拒绝，再**字节级还原**并断言门禁复绿。四个已脱壳单元（Compiler / Project / Editor / Tests）当前均为 `ratchet armed`。理由很直接：**从未被复验过的棘轮，与已经不再咬人的棘轮无法区分**。

### F1-g：僵尸 `uses main` 闪击 ——**已完成（2026-09-27）**

`MainForm.*` 引用本批**未动**（仍为 177），但 `uses main` 单元 **34 → 25**，即编译依赖图一次收缩 26%。

新增 **`tools/uses_main_audit.py`**：对每个 `uses main` 单元回答两个**失败方式完全不同**的问题——
1. 它是否仍**命名** main.pas 的导出（`MainForm` / `TMainForm`）？
2. 它是否**隐式继承**了某个"只能经 main 才可达"的单元的符号？（Delphi 传递可见性意味着摘除 `main` 会连带摘除这些符号——这是离编辑点最远的失败模式。）

只有两问皆空才判定 SAFE。首轮结果：**34 个单元中 8 个 SAFE、26 个 BLOCKED**。

- **8 个零引用僵尸**（`AboutFrm` / `CompOptionsFrm` / `IncrementalFrm` / `LangFrm` / `TestsDUnitX` / `ToolFrm` / `Packman/InstallWizards` / `devExec`）—— 纯历史残留。`devExec` 的 implementation uses 子句**只含 `main` 一个名字**，因此整条子句删除。
- **`Instances.pas`** 是唯一的"半僵尸"：0 处 `MainForm.*`，但第 93 行 `WindowClassName = TMainForm.ClassName`（按类名识别已运行实例）。门面新增 `MainWindowClassName: string`——**返回字符串而非 `TClass`**，否则等于把这道门存在的理由（挡住上帝类）从后门又送了出去。

### 本批次抓到的两个真实缺陷（其一由我自己造成）
1. **半应用事故**：迁移脚本用了 `apply(...) and apply(...)` 的写法，`MainUi` 那半失败后 `Instances.pas` 那半**仍被改写**，结果它调用了一个尚未声明的门面入口。**由棘轮 #3（门面漂移）当场报出**：`MainUi.MainWindowClassName is called but not declared`。脚本已改为"前半失败即拒绝后半"的原子语义。*这是本会话工具链抓到的第三个真实缺陷，也是棘轮 #3 第一次在真实事故中生效。*
2. **门禁统计口径缺陷**：`MainUi` 现在合法地在 implementation uses 中声明了 `main`（见下），于是被计入 `uses_now`，而**失败检查正确地跳过了 facade，但进度行的计数没有**——报告的"26 units"里其实含 1 个 facade，真实值是 25。已修正为"报告口径 = 检查口径"。

### 顺带修正的一处隐性脆弱
`MainUi` 此前对 `main` 的 **79 处引用全部依赖 Delphi 传递可见性**（因为 `EditorList` 的 interface uses 了 `main`），**却从未显式声明过它**。这是单元排列顺序的巧合，不是被声明的依赖——恰恰是本轮改造要消除的那类隐性耦合。现已在 implementation uses 中显式写上 `main`（`main` 不会回指 `MainUi`，形成的是合法的 implementation 循环，与 `Project` / `Editor` 已依赖的形态同构）。一行代码，把脆弱的巧合变成事实。

验证：双 profile QA gate OK；棘轮 `violations: 0`；审计 25 个单元 **0 SAFE / 25 BLOCKED**（剩余全为真实耦合）；抽查 7 个新释放单元 `main_symbols.py` 全部 0 泄漏；四个脱壳单元 `ratchet armed`；F0 产物检查全过。

### F1-h：工具弹窗组脱壳（FindFrm + ProfileAnalysisFrm）——**已完成（2026-09-28）**

`MainForm.*` **177 → 135**（-42，-23.7%），含耦合文件 **27 → 25**，`uses main` **25 → 23**。`MainUi` 由 77 → **89 个入口**。

> **战前情报修正**：本批开工前曾把"僵尸 `uses main` 闪击"列为待办轨道，实测 `uses_main_audit.py --all` 报 **0 SAFE / 26 BLOCKED**——轨道 1 早在 F1-g 就已打完（34 → 25），剩下的 25 个全为真实耦合。**低果已被摘尽，故直接转入轨道 2**，避免重复劳动。

**42 处的真实分布**（与战报预估的"高度套路化"一致，但比预估更集中）：

| 单元 | 处数 | 门面形态 |
|---|---|---|
| `ProfileAnalysisFrm` | 22 | `ProjectExecutable` (8) / `ActiveEditorFileName` (6) / `CurrentProject` (5) / `SharedCppParser` (2) / `FindEditorByFileName` (1) |
| `FindFrm` | 20 | `EditorByIndex` (3) / `EditorPageCount`+`EditorAt` (2) / `ProjectUnit*` (3) / `CurrentProject` (2) / Find 输出 4 个动作 (4) / 其余 6 |

**设计要点（沿用并强化前几批的纪律）**：
- **动作优先于控件**：`ShowFindResults(AMatchCount)` 一次性吞掉原先横跨三个控件的三行——`MessageControl.ActivePageIndex := 4` + `FindSheet.Caption := ...` + `OpenCloseMessageSheet(TRUE)`。泄漏 `TPageControl` + `TTabSheet` 只是"戴帽子的上帝窗体"；一个动作名才说清用户到底要了什么。
- **`IndexOf` + `CloseUnit` 合并为 `CloseProjectUnitOfEditor`**：所有调用点都写的是这一对，且 `-1` 的隐患在每一处都相同。**一处需要推理，好过三处**。
- **枚举/类型一律不出门面**：`TProject` / `TUnitList` / `TProjUnit` 因 `Project.pas` 已 uses `MainUi`，若写进 interface 会构成 Delphi 拒绝的环，故只暴露 `Count` + 两个返回 `TObject` / `string` 的索引器，调用点显式强转。
- **如实保留缺陷，不顺手"修"**：`ActiveEditorFileName` **刻意不加 nil 编辑器保护**。原代码 4 处都在 `Assigned(CurrentProject)` 的 `else` 分支里直接解引用可能为 nil 的 `TEditor.FileName`；返回 `''` 会把一次崩溃变成一条**错误的 gprof 命令行**——那是更坏的失败，且属于行为变更，不该混进脱壳批次。此注已写进门面接口注释。

**工具链抓到的两个真实缺陷（均为本会话新暴露）**：
1. **`Path.read_text()` 的通用换行转换**：`read_text` 会把 CRLF 静默改写成 LF，导致"按原行尾翻译模式"这一既有纪律**在读入侧就已被破坏**——模式全部命中 0。修法是 `read_bytes().decode()` 直解字节，端到端保住真实行尾。**这条陷阱对后续所有 CRLF 纯文本迁移都成立**。
2. **缩进模式互为子串，命中断言会说谎**：`"      e := MainForm.EditorList.GetEditor;"`（6 空格）是 `"        e := ..."`（8 空格）的子串，未加锚定前计数为 3 而非 2。`ProfileAnalysisFrm` 的 4/6 空格 `addeditem.Data` 同理。**修法：所有按缩进区分的规则一律以 `\n` 前缀锚定**——次数断言一旦被子串污染，它就从"防线"退化成"装饰"。

**验证**：
- 双 profile QA gate OK；棘轮 `violations: 0`；基线已收紧至 **135 / 23**（不再容忍回弹）。
- `main_symbols.py`：两单元均 **0 泄漏**；`uses_main_audit.py`：**2 SAFE / 0 BLOCKED**（传递可达性差集为空——摘除 `uses main` 不丢任何符号）。
- 门面 **89 声明 / 89 实现，双向零漂移**。
- 23 条替换**逐条命中数断言通过**；CRLF 完整性：MainUi 927 / FindFrm 585 / ProfileAnalysisFrm 460，**0 裸 LF**，末尾 `end.` 完整。
- `ratchet_reinject.py`：**六个脱壳单元全部 `ratchet armed`**（本批新增 FindFrm、ProfileAnalysisFrm；后者需显式 `--anchor`，因其无默认锚点行），**字节级还原后 MD5 不变**。
- 新增 `tools/f1_struct_selfcheck.py`：本机无 Delphi/FPC，故以结构自检替代编译——`begin`/`end` **差值与迁移前逐文件比对**（`case` 分支与 `class` 体天然不配对，故断言"差值不变"而非"差值为零"，这是第一次把"编译验证"降级为"结构验证"并明确其边界）。

> **本批的诚实边界**：以上全部为**静态/结构验证**，`devcpp.exe` 的真实编译与 GUI 冒烟（`Find` 对话框四个页签、`Gprof` 平面/调用图两页）**仍需在装有 Delphi 10.2 的机器上执行**。

### F1-i：属性弹窗与 TODO 视图脱壳（FilePropertiesFrm + ViewToDoFrm）——**已完成（2026-09-28）**

`MainForm.*` **135 → 110**（-25），含耦合文件 **25 → 23**，`uses main` **23 → 21**。`MainUi` 由 89 → **94 个入口**。**与战前预估（110 / 23 / 21）逐项吻合。**

**边际成本确实极低**：25 处只新增 **4 个**门面入口，其余全部复用 F1-h 刚建的 `ProjectUnit*` / `EditorPageCount` / `EditorAt` / `CurrentProject` / `FindEditorByFileName`。

| 新入口 | 取代 | 设计理由 |
|---|---|---|
| `IsProjectFile(Name)` | `Project.Units.IndexOf(N) <> -1` | 是**谓词**不是索引器，原地搬运会泄漏 `TUnitList` |
| `ProjectRelativePath(N)` | `ExtractRelativePath(Project.Directory, N)` ×2 | 两处调用点做的都是"拿工程目录换算相对路径"这一个动作 |
| `ProjectName` / `ProjectFileName` | `Project.Name` / `.FileName` | 工程元数据的诚实读取者，无对应动作可收敛 |
| `NavigateToFileAndLine(F, L)` | `GetEditorFromFileName` + `SetCaretPosAndActivate` + `if Assigned` | **按"防腐红线"收敛的高层语义动作** |

**三个必须记录的判断**：
1. **`Editors[i]` 与 `[i]` 是同一个索引器**：战报提示的"防腐红线"处，实战遇到的是 `ViewToDoFrm:166` 写属性式 `Editors[i]` 而 `FindFrm` 写默认属性式 `[i]`。查证 `EditorList.pas:69`——`property Editors[Index: integer]: TEditor read GetForEachEditor; default;`，**两者同指 `GetForEachEditor`**。若未查证就按"不同写法 = 不同语义"处理，会静默换掉查找逻辑。**这是本批最值得记的一条：两种拼写 ≠ 两种实现。**
2. **`NavigateToFileAndLine` 刻意不用 `GotoLine`**：原代码用的是 `SetCaretPosAndActivate`，两者差异是**后者会同时激活/抬升页控件**。换成更"直白"的 `GotoLine` 会改变用户可见行为。
3. **`NavigateToFileAndLine` 返回 `Boolean` 而非静默**：`lvDblClick` 原本的 `if Assigned(e) then ... Close` 决定了"**只有真的跳过去了才关对话框**"。返回 False 保住了这个分支，折叠成 void 会让未打开的文件也关窗。

### 本批次抓到的缺陷：**F1-f 教训的完整复现，且比原版更危险**

首轮迁移 14 条规则全部命中断言、**但漏了 3 处 `MainForm.`**：抓出它们的是 `main_symbols.py`（不是任何次数断言）。两处根因不同：

1. **漏写规则**（`FilePropertiesFrm:332,335`）：`FillFiles` 里 `Assigned(Project)` 守卫与工程文件本体位于我写的循环规则**之上**。**没有模式 = 没有断言**，这条纪律在 F1-f 就已写下，本批原样重犯。
2. **差点造成静默的行为回归**（`ViewToDoFrm:333`）——**这是本批真正的价值所在**。我最初把 `lvMouseDown` 也读成"跳行导航"，准备一并折叠进 `NavigateToFileAndLine`。**实际它是要改写源码行**（`e.Text.Lines[..] := StringReplace(..., 'TODO', 'DONE', [])`）。若折叠：编译通过、门禁全绿、**TODO↔DONE 勾选功能静默变成空操作**，且只在 IDE 里手动点才看得见。**"引用数归零"不等于"迁移正确"——若没有泄漏检测器兜底，这就是一个会被记入战报的光鲜错误。**

**工具链增强**：`_f1h_selfcheck.py` 的目标清单已扩到 5 个单元；一次性迁移脚本新增 `--skip-mainui`，用于"门面已落盘、消费者需重驱动"的场景（避免为重跑而回滚一个含新入口的无害文件）。

**验证**：
- 双 profile QA gate OK；棘轮 `violations: 0`；基线已收紧至 **110 / 21**。
- `main_symbols.py`：两单元 **0 泄漏**；`uses_main_audit.py`：**2 SAFE / 0 BLOCKED**。
- 门面 **94 声明 / 94 实现，双向零漂移**。
- 14 条替换逐条命中数断言通过；CRLF：MainUi 1039 / FileProp 425 / ViewToDo 506，**0 裸 LF**；`begin`/`end` 差值逐文件与迁移前一致（-4 / -6 均未变）。
- `ratchet_reinject.py`：**八个脱壳单元全部 `ratchet armed`**（新增 FilePropertiesFrm / ViewToDoFrm），**字节级还原后指纹不变**。

> **验证边界（同前批，未变）**：以上为静态/结构验证。本批 GUI 冒烟需重点验：属性弹窗的"工程内/外"判定与相对路径显示、**TODO 列表双击跳转（页控件应被抬升）**、**TODO 勾选后源码行应真的被改写为 DONE**（这条正是差点被折叠掉的那个功能）。

### F1-j：新建类向导脱壳（NewClassFrm）——**已完成（2026-09-28）· 击穿 100 关，正式进入两位数时代**

`MainForm.*` **110 → 95**（-15），含耦合文件 **23 → 22**，`uses main` **21 → 20**。`MainUi` 由 94 → **100 个入口**。**三项指标与战前预估（95 / 22 / 20）逐项吻合。**

**15 处只新增 5 个入口**，其余复用既有门面（`FindEditorByFileName`）。`NewClassFrm` 是最后一个纯弹窗单元，外围对话框/向导至此收口。

| 新入口 | 取代 | 关键判断 |
|---|---|---|
| `ProjectDirectory` | `Project.Directory` ×2 | 诚实读取者，不做成 "ProjectFilePath" 之类的臆造原语 |
| `AddProjectUnit` + `OpenProjectUnit` | `NewUnit(False,nil,N)` + `OpenUnit(idx)` ×2 组 | **刻意不合并**，见下 |
| `ClassBrowserSelectedClass` | 三段 nil 检查 + `_Kind = skClass`（4 处） | 门面对 `TTreeNode` 的解释是它自己的事 |
| `ListClassNames` | `CppParser.GetClassesList` | — |
| `IsClassInCurrentProject` | **13 行语句遍历 + 单位表探测** | 本批最大的一处收敛 |

**三个必须记录的判断**：

1. **`AddProjectUnit` 与 `OpenProjectUnit` 坚决不合并**。原码是
   ```pascal
   idx := Project.NewUnit(False, nil, Name);
   e   := Project.OpenUnit(idx);        // <-- 在检查之前就执行
   if idx = -1 then begin Error; Exit; end;
   ```
   调用方**需要 `idx` 自己做判断**，且失败路径上 `OpenUnit(-1)` **本来就会被调用**。折成一个 "create-and-open" 动作会悄悄跳过这一次调用——**这正是 F1-i 那条教训的反向应用：调用方依赖中间值时，不得过度收敛。** 原有的古怪之处原样保留，行为变更不搭重构的便车。

2. **否决了一个看起来极合理的捷径**。`TStatement` 本身就有 `_InProject` 字段（`CBUtils.pas:87`），用它替代 `Project.Units.IndexOf(...) <> -1` 可以让整个遍历消失。**但 `_InProject` 是解析期快照**（唯一赋值点 `CppParser.pas:440`，来自解析时的 `fIsProjectFile`），而 `Units.IndexOf` 是**实时查询**——文件加入工程的瞬间起二者就会分叉。等价性看上去显然，实际为假。**已把这条写进门面注释，防止下一个人"优化"回去。**

3. **`ClassBrowser.Selected` 在全仓无声明**，但 `main.pas:4736` 已用 `ClassBrowser.Selected.Data` 同样方式访问。结论：这是**同一单元图内的既有合法访问**，把它搬进同样 uses `main` 的 `MainUi` 不引入任何新的可见性要求——**我没有"解决"这个问题，我只是没有制造新问题**，如实记录以免被误当成已验证的结论。

**顺手清掉的死代码**：13 行遍历消失后，`btnCreateClick` 的 `Node` / `Statement` / `InheritStatement` 三个局部变量成为孤儿。Delphi 只会给 warning 而非 error，但在一个刚被清理过的过程里留三个死声明不合适——一并删除。本批净减 **13 行**（18 增 / 31 删）。

**验证**：
- 双 profile QA gate OK；棘轮 `violations: 0`；基线已收紧至 **95 / 20**。
- `main_symbols.py`：**0 泄漏**；`uses_main_audit.py`：**1 SAFE / 0 BLOCKED**。
- 门面 **100 声明 / 100 实现，双向零漂移**。
- 14 条替换逐条命中数断言通过；CRLF：MainUi 1150 / NewClassFrm 352，**0 裸 LF**；`begin`/`end` 差值逐文件与迁移前一致。
- `ratchet_reinject.py`：**九个脱壳单元全部 `ratchet armed`**。

### 阶段小结：从"打散引用"转入"收缩核心域"

`444 → 95`（**-78.6%**），`uses main` `38 → 20`（-47.4%）。**"外围弹窗时代"正式结束。** 剩余 95 处不再分散在对话框里，而是集中在：

| 单元 | 处数 | 性质 |
|---|---|---|
| `CPUFrm` | 14 | 弹窗（**仅剩的弹窗型**） |
| `DebugReader.pas` | 12 | 调试器协议解析 |
| `EditorOptFrm` | 8 | 弹窗 |
| `Debugger.pas` | 7 | 调试器会话 |
| `Macros.pas` | 7 | 宏引擎 |
| `NewFunctionFrm` / `NewVarFrm` | 6 / 7 | 弹窗 |
| `EditorList.pas` | 6 | **编辑器容器内核** |
| `Utils.pas` | 5 | 工具层 |

**战术判据**：弹窗类还可再摘 3 个（`CPUFrm` + `NewVarFrm` + `NewFunctionFrm` = 27 处，95 → 68），复用成本极低；但 `Debugger` / `DebugReader` / `EditorList` / `Utils` 这 4 个共 30 处是**架构级依赖**（会话生命周期、协议状态、容器所有权），需先设计会话/容器边界的门面语义，不宜机械搬运。**建议：先把弹窗红利吃完，再单独开"核心域"议题。**

### F1-k：弹窗红利收割（CPUFrm + NewVarFrm + NewFunctionFrm）——**已完成（2026-09-28）**

`MainForm.*` **95 → 68**（-27），含耦合文件 **22 → 19**，`uses main` **20 → 17**。`MainUi` 由 100 → **106 个入口**。**三项指标与战前预估（68 / 19 / 17）逐项吻合。外围弹窗至此彻底清零。**

**27 处只新增 7 个入口**，其余全部复用（`DebuggerExecuting` / `SendDebuggerCommand` / `FindEditorByFileName` / `ListClassNames` / `ClassBrowserSelectedClass`）。

| 新入口 | 取代 | 关键判断 |
|---|---|---|
| `SetDebugOutputSinks` / `ClearDebugOutputSinks` | `Reader.{Registers,Disassembly,Backtrace} :=` ×6 | 三处赋值收敛为一个注册动作，**三者不可能再走散** |
| `SendDisassembly` / `SetDisassemblyFlavor` | `SendCommand('disas'/'set disassembly-flavor', …)` ×4 | GDB 方言收敛到门面一处 |
| `ClassSourcePair` | `GetSourcePair(F, var C, var H)` ×2 | 一对 out 参数 → 一条语义 |
| `SuggestMemberInsertionLine` | `SuggestMemberInsertionLine(st, Scope, var AddScopeStr)` ×3 | **枚举坚决不出门面**，见下 |

**四个必须记录的判断**：

1. **`SuggestMemberInsertionLine` 的枚举被我挡在门外**。真实签名是 `Scope: TStatementClassScope`（`CBUtils.pas:56` 的枚举）+ `var AddScopeStr: boolean` 出参。直接转发会把 `CBUtils` 拖进 `MainUi` 的 **interface**——正是"枚举坚决不出门面"这条纪律要防的事。解法：作用域以 **Integer** 过门，出参转为**第二个 Boolean 结果**。**代价我如实记下**：原码由编译器保证 `TStatementClassScope` 匹配，现在改由门面在运行时转换——**这是一处真实的类型安全削弱，已写进门面注释而非藏起来**。（两处调用点本就传的是本地算出的 `VarScope: Integer`。）

2. **CPUFrm 的三个 `Reader` 列表是"注册协议"而非"查询"**。窗体把自己的 `TList` / `TStringList` 交给 GDB 输出解析器去填，关闭时再交还 `nil`。所以我**逐字转发赋值**（`TObject` 中转），而没有发明"给我寄存器"的 API——那会是**调试器数据路径的重新设计，不是解耦**。六个赋值收敛为一次注册 + 一次清空，顺带消灭了"三处可能走散"的老问题。

3. **栈回溯跳转复用了 F1-i 的 `NavigateToFileAndLine`**，而不是再声明一个 `JumpToFrame`。少一个平行入口，是"门面自身不膨胀"这条纪律的直接兑现。

4. **一个被刻意"保留"的缺陷**。`NewVarFrm:97` 与 `NewFunctionFrm:90` 的类浏览器取选中项**完全没有 nil 保护**（F1-j 的 `NewClassFrm` 有三段判断）：
   ```pascal
   cmbClass.ItemIndex := cmbClass.Items.IndexOf(PStatement(MainForm.ClassBrowser.Selected.Data)^._Command);
   ```
   改走 `ClassBrowserSelectedClass` **本会顺手把它" hardened"**——因为该入口内部已经做了完整判空。**但那是行为变更**：原先无选中项时是 AV，改后会静默变 `ItemIndex = -1`。**原样保留缺陷，不把修复搭重构的便车**；已在迁移脚本注释与此处双重标注。**这是一个已知缺陷，建议单独发一票修复，不要混进本批。**

**顺手补齐的隐性依赖**：`NewFunctionFrm` 一直在调用 `TCppParser` 却**没把 `CppParser` 写进 uses**，靠 `main` 的传递可见性活着。摘除 `main` 后必须显式补上——**这正是 F1-g 那条"把脆弱的巧合变成事实"的纪律，本批第二次派上用场**。

**验证**：
- 双 profile QA gate OK；棘轮 `violations: 0`；基线已收紧至 **68 / 17**。
- `main_symbols.py`：三单元 **0 泄漏**；`uses_main_audit.py`：**3 SAFE / 0 BLOCKED**。
- 门面 **106 声明 / 106 实现，双向零漂移**。
- 27 条替换逐条命中数断言通过；CRLF：MainUi 1269 / CPU 335 / NewVar 310 / NewFunc 264，**0 裸 LF**；`begin`/`end` 差值逐文件与迁移前一致（-3 / -7 / -7 均未变）。
- `ratchet_reinject.py`：**十二个脱壳单元全部 `ratchet armed`**。
- **PowerShell 纪律已生效**：全程用 `2>&1 | Out-String` 取 `$LASTEXITCODE`，本批**未再出现假警报**（此前 F1-h/F1-j 复核时各撞过一次）。

### 里程碑：外围清零，核心域裸露

`444 → 68`（**-84.7%**），`uses main` `38 → 17`（-55.3%），耦合文件 `31 → 19`。**剩余 68 处已无任何弹窗**：

| 单元 | 处数 | 域 |
|---|---|---|
| `DebugReader.pas` | 12 | GDB 协议解析 |
| `EditorOptFrm` | 8 | 编辑器选项（**最后一个弹窗型**） |
| `Debugger.pas` | 7 | 调试会话 |
| `Macros.pas` | 7 | 宏引擎 |
| `NewTemplateFrm` / `EnviroFrm` / `ProjectOptionsFrm` / `devCFG` / `AddToDoFrm` 等 | 1–2 各 | 小弹窗 / 配置 |
| `main.pas` | 4 | 上帝窗体自身（`MessageBox(MainForm.Handle…)` 等） |
| `EditorList.pas` | 6 | 编辑器容器 |
| `Utils.pas` | 5 | 工具层 |

**注**：`EditorOptFrm`(8) 是残留的最后一个弹窗型，但它是**编辑器引擎配置**（LCL SynEdit 迁移的直接落点，见 §F2），**与 `Editor.pas` 的脱壳耦合**，不宜当纯弹窗处理。**真正的核心域战场是 `Debugger` / `DebugReader` / `EditorList` / `Utils`（30 处）**——下一议题应为"调试器会话模型 + 编辑器容器生命周期"两套门面设计。

### F1-l：残余弹窗收口（9 个单元）——**已完成（2026-09-28）**

`MainForm.*` **68 → 56**（-12），含耦合文件 **19 → 10**，`uses main` **17 → 9**。`MainUi` 由 106 → **110 个入口**。

**12 处只新增 4 个门面入口**，其余 8 处全是复用（`ProjectName` / `ProjectDirectory` / `CurrentProject` / `EditorByIndex`）。**九个单元一次性收口，耦合文件数近乎腰斩。**

| 新入口 | 取代 |
|---|---|
| `ApplyIdeFont` | `MainForm.Font.{Name,Size} :=`（环境设置改 IDE 字体） |
| `CopyProjectViewTo(AListView)` | `lvFiles.Images/Items := ProjectView.…`（**保留整体 `Items.Assign`**） |
| `RemoveProjectEditor` | `Project.RemoveEditor(i, true)` |
| `MainFormHandle` | `Application.MainForm.Handle` ×2（**两种拼写**） |

### 本批抓到的两个真实工具链缺陷

1. **棘轮在统计"从不编译的代码"的耦合**。新增 **`tools/build_membership.py`**：把基线与 `devcpp.dproj` 交叉比对，查出 **`Tools/PackMaker/filefrm.pas`(4 处) 与 `FormatterOptionsFrm.pas`(1 处) 根本不在 `devcpp.exe` 的编译单元里**。它们的耦合是**死重而非债务**——占了 56 处中的 5 处。本批**刻意没有去"清理"它们来让数字好看**，而是如实上报。**`filefrm.pas` 的 `MainForm.FileName` 在全仓无任何声明**——进一步佐证它已腐化，从未编译。**这是清理决策（删除 / 纳入构建 / 排除出指标），不该由重构顺手决定。**
2. **`_MAINFORM_REF` 与 `_MAINFORM_OWNER` 自相矛盾**。owner 正则明确写了 `(?<!Application\.)` 并注明"`Application.MainForm` is the VCL property, not our god form"，但 **refs 正则 `\bMainForm\s*\.` 没有同样的排除**，且**大小写敏感**——于是 `Templates.pas:111` 的 `Application.mainform.handle`（小写）**根本没被计入**，而 `:264` 的 `Application.MainForm.Handle` 被计入。**同一文件两处同义写法，一个算一个不算。** 本批已把两处都改走门面（`MainFormHandle`），但**正则本身的不一致尚未修复**——因为修它会改变头条数字（56 → 57），属于独立的度量决策，应单独发一票。**如实记录，不夹带。**

**`MainFormHandle` 刻意不加 nil 保护**：原 `Application.MainForm.Handle` 在窗体未创建时会 AV；返回 0 会把崩溃变成"父窗口为屏幕的消息框"——是行为变更。**与 F1-i 的 `ActiveEditorFileName` 同一纪律。**

**验证**：
- 双 profile QA gate OK；棘轮 `violations: 0`；基线已收紧至 **56 / 9**。
- `main_symbols.py`：九单元 **0 泄漏**；`uses_main_audit.py`：**8 SAFE / 0 BLOCKED**。
- 门面 **110 声明 / 110 实现，双向零漂移**。
- 27 条替换逐条命中数断言通过；CRLF 完整性 0 裸 LF；`begin`/`end` 差值逐文件与迁移前一致（18 单元全部核对）。
- `ratchet_reinject.py`：**二十一个脱壳单元全部 `ratchet armed`**。

> **一处工具箱自纠**：早期用 PowerShell `Select-String -Context` 读源码时，我给上下文行套了 `.Trim()`，把**2 空格缩进的 `e := MainForm.EditorList.GetEditor;` 看成 4 空格**，写出错误模式。是**次数断言当场报出**（hit 0）而非肉眼发现。**结论固化：读源码原文一律用 Python `read_bytes().decode()`，不经 PowerShell 文本管道。**

### 剩余 56 处的真实构成

**核心域（46 处）**：`DebugReader`(12) · `EditorOptFrm`(8) · `Debugger`(7) · `Macros`(7) · `EditorList`(6) · `Utils`(5) · `devCFG`(2 + 2 裸句柄) · `main.pas` 自身(4)
**不在构建内（5 处）**：`filefrm`(4) + `FormatterOptionsFrm`(1) —— 建议**单独决策**
**其余（5 处）**：见基线

**下一议题**：核心域 46 处需两套新设计——**调试器会话模型**（`Debugger`/`DebugReader`/`devCFG` 共 21 处）与**编辑器容器生命周期**（`EditorList`/`EditorOptFrm`/`Macros` 共 21 处）。二者都不是"把成员搬进门面"能解决的，需要先定义边界语义。**建议先出设计再动手，不要沿用弹窗批次的机械适配打法。**

### F1-m-0：死重清理 + 度量修正（核心域会战前锁定基线）——**已完成（2026-09-28）**

**`MainForm.*` 56 → 49**，耦合文件 10 → **8**，`uses main` 9 → **7**。`MainUi` 维持 110 入口。

**注：最终落点是 49，不是方案预估的 51–52。** 两项裁定我都执行了，但**实测数字与预估不同**，下面是证据。

#### 裁定一：死重归档 ✅（56 → 51，与预估一致）

新增 **`tools/dead_unit_check.py`** 后才敢动手。它不只看 `.dproj`，还构建**在编单元的 uses 闭包**——因为"不在工程文件里"只说明"大概死了"，而归档是单向门。两个单元均判定 `safe to archive`：不在 dproj，且无任何在编单元 uses 它们。

`git mv` 至新建的 **`Source/Archive/`**（`filefrm.pas` / `FormatterOptionsFrm.pas`）。

**归档当场被棘轮拦下**：`violations: 2`（`GREW Source/Archive/filefrm.pas: None -> 4`）。原因——所有扫描器都用 `SOURCE.rglob("*.pas")` **递归扫整棵树**，`Source/Archive/` 自然被扫入。**若非棘轮在场，这批死重会带着 5 处耦合继续活在指标里。**
修法：新增 **`tools/scan_scope.py`** 作为**单一扫描范围定义**（`EXCLUDED_PREFIXES = ("Source/VCL/", "Source/Archive/")`），由 `mainform_baseline` / `uses_main_audit` / `qa_check` 三处共同 import。**一处定义，杜绝"这个工具加了那个忘了"。**

#### 裁定二：正则修补 ✅（51 → **49**，非预估的 52）

先写 **`tools/regex_impact.py`** **实测**，再改代码。修正为 `(?<!Application\.)\bMainForm\s*\.` + `re.IGNORECASE`，并把理由写进注释。逐行证据：

| 行 | 现状 | 修正后 | 内容 |
|---|---|---|---|
| `Utils.pas:476` | 1 | **0** | `ShellExecute(Application.MainForm.Handle, …)` |
| `Utils.pas:483` | 1 | **0** | `ShellExecute(Application.MainForm.Handle, 'runas', …)` |
| `Utils.pas:1007/1008/1010` | 1 | 1 | 真正的 `MainForm.*`（保留） |

**净 −2，全部来自 `Utils.pas` 的两处 `Application.MainForm.Handle`。**

**为什么不是预估的 +1**：预估假设"大小写敏感会补进此前漏计的 `Application.mainform`"。但**那些小写站点在 F1-l 已全部改走 `MainUi.MainFormHandle`**，今天大小写不敏感单独贡献 **0**。两处修正中，排除规则贡献 −2、大小写贡献 0。

#### 执行中撞出的第三个真实缺陷（本次最关键的一条）

改完 `mainform_baseline.py` 的正则后，**`qa_check` 立刻失败**：
```
Source/Utils.pas: error: MainForm coupling grew 3 -> 5 (ratchet cap 3)
```
根因：**`qa_check.py:399` 与 `mainform_baseline.py:30` 各自维护一份手工复制的 `_MAINFORM_REF`**。我改了棘轮那份、没改门禁那份，于是**一个纯属副本漂移造成的幽灵回归**被门禁报了出来——如果反过来（只改门禁），数字会静默地对不上基线而无人察觉。

**修法：`qa_check` 直接 `import mainform_baseline` 并取其 `_MAINFORM_REF` / `_MAINFORM_OWNER`，删除本地副本。** 一个定义，物理上无法漂移。**这比修正则本身重要：它把"两处手工保持一致"变成了"只有一处"。**

#### 顺带修正的第四个口径缺陷

`uses_main_audit.py --all` 报 **8** 个单元，基线只有 **7**——差额是 `MainUi.pas` 自己。**门面合法保留 `uses main`**（那正是它作为反腐层的定义），却被 `--all` 当作候选列出。这与 F1-g 记录过的"报告口径 ≠ 检查口径"是同一类毛病。已修：`--all` 排除 facade 清单，且该清单**从基线 JSON 读取**而非重新声明。现在 `--all` 与默认模式**都报 7**。

**验证**：双 profile QA gate OK；棘轮 `violations: 0`，基线锁定 **49 / 7**；`build_membership` 报 **0/49 在构建外**（死重已彻底脱离度量）；F0 产物检查 OK；结构自检 OK（18 单元 delta 全未变）；21 个脱壳单元棘轮状态未受影响。

**剩余 49 处（8 文件 / 7 个 uses main 单元）**：

| 单元 | 处数 | 域 |
|---|---|---|
| `DebugReader.pas` | 12 | GDB 协议解析 |
| `EditorOptFrm.pas` | 8 | 编辑器引擎配置（§F2 落点） |
| `Debugger.pas` | 7 | 调试会话 |
| `Macros.pas` | 7 | 宏引擎 |
| `EditorList.pas` | 6 | 编辑器容器 |
| `main.pas` | 4 | 上帝窗体自身 |
| `Utils.pas` | 3 | 工具层 |
| `devCFG.pas` | 2 (+2 裸句柄) | 配置层 |

**这是纯核心域战场，零弹窗残留。** 调试管线（`Debugger`+`DebugReader`+`devCFG` = 21 处）与编辑器生命周期（`EditorList`+`EditorOptFrm`+`Macros` = 21 处）两大议题可以正式开题。

---

## F1-m 勘察报告：调试管线 21 处的物理事实

> **性质**：纯分析，**零代码改动**。目的不是"怎么搬"，而是"搬之前必须知道什么"。

### 维度二先说，因为它推翻了一个预设

**`DebugReader.pas` 的 12 处，没有一处在工作线程里。**

`TDebugReader = class(TThread)`（`DebugReader.pas:75`），确实是后台线程，`Debugger.pas:170-176` 以 `Create(true)` + `Start` 拉起。但 **12 处引用全部集中在一个过程内**——`SyncFinishedParsing`（158–242 行），而它**只有一个调用点**：

```
DebugReader.pas:930   TDebugReader.ProcessDebugOutput → Synchronize(SyncFinishedParsing)
```

`Synchronize` 会把方法体**调度到主线程执行**。因此这 12 处**当前全部运行在 UI 线程**。

> **这对方案是好消息**：跨线程调度语义**已经内建在 `Synchronize` 这一层**。解耦时只要保持"引擎侧只发意图、UI 侧执行"的边界，就**不需要新建 `TThread.Queue` 通道**。战报预判的"必须内建跨线程调度语义"——**现状已具备**，缺的是边界，不是机制。
>
> **唯一例外**：`DebugReader.pas:182-183` 的 `MainForm.Debugger.OnEvalReady(fEvalValue)` 虽在主线程，却是**经 `TDebugger` 字段的间接回调**——与 `MainUi.SetEvalReadyHandler` 同形状，F1-b 已处理过一次，**不要重复造**。

### 维度一 + 三：21 处逐条清单

**`Debugger.pas` — 7 处 / 3 个过程**

| 行 | 过程 | 代码 | 方向 |
|---|---|---|---|
| 178 | `Start` | `MainForm.UpdateAppTitle;` | Notification |
| 189 | `Stop` | `MainForm.LeftPageControl.ActivePageIndex := LeftPageIndexBackup;` | **Command** |
| 208 | `Stop` | `MainForm.RemoveActiveBreakpoints;` | **Command** |
| 210 | `Stop` | `MainForm.UpdateAppTitle;` | Notification |
| 229 | `SendCommand` | `if (not CommandChanged) or (MainForm.edGdbCommand.Text = '')` | **Query** |
| 232 | `SendCommand` | `MainForm.edGdbCommand.Text := …` | Notification |
| 234 | `SendCommand` | `MainForm.edGdbCommand.Text := Command;` | Notification |

**`DebugReader.pas` — 12 处 / 1 个过程（全部主线程）**

| 行 | 代码 | 方向 |
|---|---|---|
| 169 | `MainForm.Debugger.Stop;` | **Command** |
| 170 | `MainForm.actCompileExecute(nil);` | **Command** |
| 177 | `MainForm.Debugger.Stop;` | **Command** |
| 182 | `if doevalready and Assigned(MainForm.Debugger.OnEvalReady)` | **Query** |
| 183 | `MainForm.Debugger.OnEvalReady(fEvalValue);` | Notification |
| 187 | `MainForm.DebugOutput.Lines.Add(fOutput);` | Notification |
| 202 | `MainForm.GotoBreakpoint(fBreakPointFile, fBreakPointLine);` | **Command** |
| 203 | `MainForm.Debugger.RefreshWatchVars;` | **Command** |
| 228 | `MainForm.ViewCPUItemClick(nil);` | **Command** |
| 238 | `MainForm.Debugger.SendCommand('disas', '');` | **Command** |
| 239 | `MainForm.Debugger.SendCommand('info registers', '');` | **Command** |
| 240 | `MainForm.Debugger.SendCommand('backtrace', '');` | **Command** |

**`devCFG.pas` — 2 处（该文件是 **GBK 编码**，非 UTF-8）**

| 行 | 代码 | 方向 |
|---|---|---|
| 1942/1943/1949 | `if Assigned(MainForm) … case MainForm.GetCompileTarget … MainForm.Project.Options.CompilerSet` | **Query**（纯读） |
| 1985 | `with MainForm do begin CppParser.Reset; …` | Command——**位于注释块内**（`{` 始于 1967） |

> **维度三小结（本报告最重要的一张表）**：
>
> | 方向 | 数量 | 占比 |
> |---|---|---|
> | **Command**（引擎指挥 UI 做事） | **13** | 62% |
> | Notification | 6 | 28% |
> | **Query**（引擎反问 UI） | 3 | 14% |
>
> **纯 Listener 模型不成立。** 战报设计的 `IDebugSessionListener` 四个方法全是 Notification 形态，**只能覆盖 6/21 = 28%**。剩下 13 处 Command 是"引擎要求 UI 执行动作"，不是通知。强行塞进 Listener，会得到一个既不通知也不询问、只会发号施令的接口——**那正是"披着门面外衣的上帝对象"**。

### 维度四：与 `Core/Events.pas` 的重合度 —— **类型已备好，但从未接线**

`Core/Events.pas` 已有 8 个事件类型，其中 5 个与本批次语义高度重合：

| 已有事件 | 可对应的调用 | 现状 |
|---|---|---|
| `TBreakpointEvent` | 202 `GotoBreakpoint` | 定义 ✅ / **发布 ❌** |
| `TWatchUpdateEvent` | 203 `RefreshWatchVars` | 定义 ✅ / **发布 ❌** |
| `TCallStackUpdateEvent` | 240 `backtrace` | 定义 ✅ / **发布 ❌** |
| `TFormTitleEvent` | 178/210 `UpdateAppTitle` | 定义 ✅ / **发布 ❌** |
| `TProjectChangedEvent` | （本批次无） | 定义 ✅ / **发布 ❌** |

**核验结果**：全仓 `TBreakpointEvent.Create` 等**只出现在 `Events.pas` 自身的构造函数定义处**，**没有任何业务代码真正 Publish**。事件总线已实现（`TEventManager.Subscribe/Publish`，`Events.pas:197/273`），`main.pas:6317` 甚至**已经订阅了**：

```pascal
main.pas:6314  // Subscribe to breakpoint events from the event manager.
main.pas:6317  TEventManager.Instance.Subscribe(HandleBreakpointEvent);
```

> **这是本次勘察最有价值的发现**：**发布者与订阅者两端都已就位，唯独中间没人发事件。** Phase 1/2 建好了轨道，调试管线却还在直调 `MainForm.*` 走老路。
>
> **结论：F1-m 不需要新设计 `IDebugSessionListener`——已有 `TEventManager` + 5 个现成事件类型可直接接线。** 新造监听器等于在已有总线上再挂一套平行机制，**正是要避免的重复**。

### 三处必须警惕的陷阱

1. **`Debugger.pas:229` 的 Query 不可轻易事件化**。它读 `edGdbCommand.Text` 决定是否回显——**引擎在读 UI 输入框内容**。事件化前必须先把"回显策略"下沉到引擎侧（由引擎持有 `CommandChanged` 语义），否则引入时序竞态。
2. **`devCFG.pas:1985` 那处 `with MainForm do` 在注释块内**（`{` 始于 1967 行）。**它被棘轮计入但根本不会编译**——与 F1-l 的 `filefrm.pas` 同类。正确处理是**删除注释而非为它设计门面**。
3. **`devCFG.pas` 是 GBK 编码**。任何文本改动必须按 GBK 读写，否则整文件乱码。**这是本项目遇到的第一个非 UTF-8 目标文件**，迁移脚本需扩展 `read_raw()` 的编码探测。

### 对 `IDebugSessionListener` 设计的修正建议

不建议按原案实现四方法监听器。基于以上事实，建议改为**三段式**：

| 段 | 覆盖 | 载体 | 是否需新设计 |
|---|---|---|---|
| ① 事件通知 | 6 处 | **复用 `Core/Events.pas` 的 5 类现成事件** | ❌ 不需要 |
| ② 语义动作 | 13 处 | **复用 `MainUi`**（`NavigateToFileAndLine` / `RefreshAppTitle` / `SendDebuggerCommand` 等） | ❌ 大部分不需要 |
| ③ 状态读取 | **3 处** | 回显策略下沉 / 编译目标查询 | ✅ **唯一需真正设计的部分** |

> **把"新设计"从 21 处压缩到 3 处 Query，这才是本批的真实工作量。** ①②两段是"接线"（把已存在的机制接上），不是"造新东西"。

### 开工前又抓到一个工具缺陷（编号五）：`_BLOCK_COMMENT` 无法处理嵌套花括号

`devCFG.pas:1967` 有一个**独立成行的 `{`**，到 `2006` 的 `}` 结束——中间是**被整体注释掉的一整个过程**（`TdevCompilerSets.OnCompilerSetChanged`），其中 `1985` 行含 `with MainForm do begin CppParser.Reset; …`。

```
devCFG.pas:1967   {
devCFG.pas:1968   procedure TdevCompilerSets.OnCompilerSetChanged(...);
...
devCFG.pas:1985     with MainForm do begin          <-- 注释块内部
devCFG.pas:2006   }
```

**但 `mainform_baseline._BLOCK_COMMENT = re.compile(r"\{[^}]*\}")` 是非贪婪单次匹配，遇到嵌套 `{` 就提前截断。** 实测：
```python
strip_noise('x = 1; { a { b } c } y = 2;')  ->  'x = 1;  c } y = 2;'
```
残留的 `c }` 会被当作代码扫描——**于是 1985 这处注释内的耦合被棘轮计入了**（这正是基线里 devCFG 计 2 处、而真实活跃代码只有 1942–1949 的原因之一）。

**新增 `tools/comment_bleed.py`** 做了正确的事：按行携带花括号深度跨行跟踪，并区分"该行发射了真实代码"与"该行完全被注释清空"。

> **过程记录（值得留档）**：该工具首版我把 `started_outside=True` 误判为 `dead`，得出"49 处全在注释里"的荒谬结论。**我没有据此下判断，而是回头做了对照校验**（对一个明知有真实调用的文件跑单行探针），定位到变量语义颠倒后修正。**最终数据：注释内 0 处，49 处全部为真实代码** —— 也就是说 `1985` 是个**真缺陷（工具侧）**，不是"死引用（代码侧）"。
>
> **结论修正**：我上一条消息里"`devCFG.pas:1985` 在注释内，被棘轮计入但不会编译"的判断**是错的**。事实是——**它确实在注释内，但棘轮之所以计入它，是因为自己的注释剥离器有缺陷**。两件事要分开：**该修的是工具，不是给死代码设计门面。**

**修法（建议，但属独立决策）**：把 `_BLOCK_COMMENT` 换成 `comment_bleed` 的深度跟踪式剥离。预期效果：`devCFG` 从 2 → **1**（1985 那处消失），全局 49 → **48**。这是一次**让度量更准确**的修正，与 F1-m 的解耦工作正交。

### F1-m 的确切开工边界（勘察收口）

| 分类 | 处数 | 载体 | 本批是否需新设计 |
|---|---|---|---|
| ② Command | 13 | `MainUi` 现有入口（`NavigateToFileAndLine` / `RefreshAppTitle` / `SendDebuggerCommand` / `RunCompileAction`…） | ❌ 接线即可 |
| ① Notification | 6 | `Core/Events.pas` 5 类现成事件 + `TEventManager.Publish` | ❌ 接线即可 |
| ③ Query | **3** | `edGdbCommand` 回显策略 / `GetCompileTarget` 编译目标 | ✅ **需设计** |

**建议的推进顺序（先小步验证方向）**：
1. **先做 ② 的 13 处**——风险最低、复用最多，且能立刻验证"接线"路径是否走得通；
2. **再做 ① 的 6 处**——用现成事件类型，验证事件总线能否真正承载调试事件；
3. **③ 的 3 处最后单独做**——`Debugger.pas:229` 的回显策略是本批唯一有设计难度的点，值得在方向被验证之后再投入。

### F1-m 步骤 1：Command 半边接线（13 处）——**已完成（2026-09-28）**

`MainForm.*` **49 → 37**（-12），`uses main` **7 → 5**。`MainUi` 由 110 → **115 入口**。

**勘察的预测被验证**：12 处里 **9 处落在 `MainUi` 已有入口上**（`SendDebuggerCommand` / `NavigateToFileAndLine` / `RunCompileAction` / `RefreshAppTitle`），只需 **4 个新名字**。"接线为主、设计为辅"的判断成立。

| 新入口 | 取代 | 命名理由 |
|---|---|---|
| `StopDebugSession` | `MainForm.Debugger.Stop` ×2 | 调用方不该持有 `TDebugger`；被问的是**会话生命周期** |
| `ClearBreakpointMarks` | `MainForm.RemoveActiveBreakpoints` | 叫 "Breakpoints" 会**承诺删除断点本身**，而它只清 UI 标记 |
| `OpenCpuWindow` | `MainForm.ViewCPUItemClick(nil)` | 门面说"显示它"；`if not Assigned` 守卫**留在 main.pas**——能否开第二个窗是主窗体的决定 |
| `RestoreLeftPageIndex(i)` | `LeftPageControl.ActivePageIndex :=` | **传入备份值**而非让门面去取：备份归调试器所有，归属不被搬走 |
| `RefreshWatchVars` | `MainForm.Debugger.RefreshWatchVars` | 纯转发 |

**一个值得记录的观察**：`DebugReader.pas` 的 238–240 三处是 `MainForm.Debugger.SendCommand(...)`——**引擎经上帝窗体去调用它自己已经持有指针的调试器**。改后 `MainUi` 走同样的路，但重点不在路径，而在**引擎不再需要窗体与自己对话**。这正是"分布式上帝对象"的一个具体症状被拔掉。

**剩余 7 处（刻意保留，等步骤 2/3）**：
- `Debugger.pas:229/232/234` — `edGdbCommand` 回显（**Query**，需先设计回显策略）
- `Debugger.pas:210` — `UpdateAppTitle`（Notification，步骤 2 接线 `TFormTitleEvent`）
- `DebugReader.pas:182/183` — `OnEvalReady`（**已有 `SetEvalReadyHandler` 桥**，F1-b 处理过）
- `DebugReader.pas:187` — `DebugOutput.Lines.Add`（Notification，步骤 2）

因此 `main_symbols.py` 对这两个单元**仍报 1 处 `MainForm` 泄漏**——**这是预期状态，不是回归**：Query 半边尚未开工。

**验证**：双 profile QA gate OK；棘轮 `violations: 0`，基线收紧至 **37 / 5**；`Debugger.pas` 与 `DebugReader.pas` 棘轮**均 armed**（`grew 4→5` / `3→4` 正是当前残留 4 处/3 处的正确表现）；F0 产物检查 OK；结构自检 OK；CRLF 1414/436/971，0 裸 LF。

> **本步骤的验证边界**：静态/结构验证。GUI 冒烟须在 Delphi 10.2 上重点验 **调试会话的启停流程**（启动→标题刷新→停止→页面回滚→断点标记清除）与 **CPU 窗口的三条数据流**（反汇编/寄存器/调用栈）。

### 本步骤我自己制造并修复的一次事故（必须留档）

**`MainUi.pas` 一度出现两个 `implementation` 子句（第 513 与 515 行）——这会让整个文件编译失败。**

根因是接口锚点拼接缺陷：`MAINUI_IFACE_OLD` 本身以 `\n\nimplementation\n` 结尾，而 `MAINUI_IFACE_NEW` 又追加了一次。**"命中数为 1"的断言没能拦住它，因为两条模式各自都确实只命中一次**——是**两条规则拼接后产生了第三个 `implementation`**，没有任何单条断言覆盖这个组合结果。

**为什么没有更早发现**：
- `main_symbols.py` 只看符号泄漏——子句数量与它无关；
- 棘轮只看 `MainForm.*` 计数——文件没被改坏，计数正确；
- **`_f1h_selfcheck` 的 `begin/end` 差值检查完全无感**——损坏发生在**子句结构**而非**块结构**。

**已做两件事**：
1. 按字节精确删除重复行，复验 `implementation` 唯一（现为第 513 行单条）；
2. **给 `_f1h_selfcheck` 补上子句唯一性检查**（`interface` / `implementation` 各恰好一次，覆盖全部 18 个目标单元）——这正是本该拦住它的那道廉价防线。

> **教训**：**次数断言只保证"每条模式各命中一次"，不保证"多条模式拼接后的结果合法"。** 当锚点本身携带结构标记（`implementation`）时，拼接必须去重。这与 F1-i 那条"没有模式 = 没有断言"是同一族问题的另一面——**有断言，但断言覆盖不到组合爆炸**。

### `OnEvalReady` 链路查证结论：**完整闭环，不是半成品**

按发令要求溯源了生产者 / 消费者 / 生命周期三端，**结论与你担心的相反——链路是通的**：

| 环节 | 位置 | 状态 |
|---|---|---|
| **产生** | `DebugReader.pas:575-579` `HandleValueHistoryValue` → `fEvalValue := ProcessEvalOutput; doevalready := true;` | ✅ 收到 GDB `value` 注解即赋值 |
| **清除** | `DebugReader.pas:887` `doevalready := false;` | ✅ 消费后复位（**一次性单次响应**） |
| **派发** | `DebugReader.pas:182-183` `if doevalready and Assigned(MainForm.Debugger.OnEvalReady) then MainForm.Debugger.OnEvalReady(fEvalValue);` | ⚠️ **经上帝窗体中转** |
| **桥接（注册入口）** | `MainUi.pas:775-779` `SetEvalReadyHandler` → `MainForm.Debugger.OnEvalReady := TEvalReadyEvent(AHandler)` | ✅ F1-b 已建 |
| **消费侧①** | `Editor.pas:1988` `MainUi.SetEvalReadyHandler(OnMouseOverEvalReady);`（紧接 `SendDebuggerCommand('print', s)`） | ✅ 悬停求值 |
| **注销** | `Editor.pas:647` / `2013` `MainUi.SetEvalReadyHandler(nil);` | ✅ `CancelHint` 正确清理 |
| **消费侧②** | `main.pas:6639` `fDebugger.OnEvalReady := OnInputEvalReady;`（`6569` 处置 nil） | ✅ 命令行输入求值 |

**结论：生产者→派发→桥接→两个消费者→注销，全链路完整，悬停求值功能正常。F1-b 的桥接不是半成品。**

**但它确实还剩 2 处耦合**，且形态与步骤 1 拔掉的完全同构：

```pascal
DebugReader.pas:182   if doevalready and Assigned(MainForm.Debugger.OnEvalReady) then
DebugReader.pas:183     MainForm.Debugger.OnEvalReady(fEvalValue);
```

**引擎（`TDebugReader`）经上帝窗体，去调用一个挂在 `MainForm.Debugger` 上的处理器。** 步骤 1 里 `MainForm.Debugger.SendCommand` 的症状在此重现——**同一个错误模式在同一个单元里出现第二次**。

**修法（极小）**：门面加 `FireEvalReady(const AValue: string)`，`DebugReader` 改为 `if doevalready then MainUi.FireEvalReady(fEvalValue);`

> **为什么"桥接已存在"仍需这一步**：`SetEvalReadyHandler` 是**注册**入口（消费侧用），`FireEvalReady` 是**派发**入口（生产侧用）。F1-b 只做了前者，**缺口在派发侧仍在穿透上帝窗体**——桥接建了一半。
>
> **行为等价性核对**：原代码有 `Assigned(...)` 守卫。`FireEvalReady` 内部**必须保留该守卫**，否则未注册处理器时会 AV——**这是一处不能省的守卫**。

### F1-m 步骤 2：Notification 半边接线 + `OnEvalReady` 闭环 ——**已完成（2026-09-28）**

`MainForm.*` **37 → 33**（-4），耦合文件 **8 → 7**。`MainUi` 由 115 → **117 入口**。

**`DebugReader.pas` 至此完全归零**（12 → 0），符号泄漏检测报 `free of main.pas symbols`，`uses main` 一并摘除。

| 入口 | 取代 | 说明 |
|---|---|---|
| `FireEvalReady(AValue)` | `if doevalready and Assigned(MainForm.Debugger.OnEvalReady) then MainForm.Debugger.OnEvalReady(fEvalValue)` | **派发侧**补齐，F1-b 桥接闭环 |
| `AppendDebugOutput(ALine)` | `MainForm.DebugOutput.Lines.Add(fOutput)` | `#26 → '->'` 归一化**留在 reader**（协议细节，非展示细节） |
| `RefreshAppTitle`（复用） | `MainForm.UpdateAppTitle`（Stop 路径） | 步骤 1 已用它处理 Start 路径，**纯复用** |

**两处设计判断**：

1. **`doevalready` 测试留在 reader，`Assigned` 守卫移入门面**。"GDB 刚给了个值吗"是**协议流**的问题，只有 reader 知道；而"有没有人挂着处理器"是**投递**的问题。前者不出引擎，后者不出门面——分得干净。
2. **`Assigned` 守卫绝不能省**。editor 只在悬停提示期间注册处理器，`CancelHint` 即注销——**"无人监听"是常态**。若无条件派发，每个 value 块都会 AV。

**断言在本批再次救场**：`MAINUI_IFACE_OLD = "procedure RefreshWatchVars;\n"` 命中 **2** 次（声明 + 实现头），dry-run 当场中止。改用声明块（`ClearBreakpointMarks` 起）后才唯一。**同一单元里"声明文本"与"实现头文本"逐字相同，是本项目的固有陷阱**——凡是按裸行匹配的规则，都要先问"它会出现几次"。

**上一轮事故的防线已验证生效**：本次迁移**刻意让锚点不带结构标记**（接口锚点只取最后一条声明行，不含 `implementation`），迁移后子句检查立即确认 18 个目标单元 `interface`/`implementation` 各唯一。

**验证**：双 profile QA gate OK；棘轮 `violations: 0`，基线收紧至 **33 / 5**；门面 **117 声明 / 117 实现零漂移**；`Debugger.pas`（3 处残留）与 `DebugReader.pas`（0 处）棘轮**均 armed**；F0 产物检查 OK；结构自检 OK（含新增子句唯一性）；CRLF 1460/436/971，0 裸 LF。

**剩余 33 处**：`EditorOptFrm`(8) · `Macros`(7) · `EditorList`(6) · `main.pas`(4) · `Debugger`(3) · `Utils`(3) · `devCFG`(2)

> **调试管线已从 21 处降到 3 处**，且 3 处全部集中在 `Debugger.pas:229/232/234` 的 `edGdbCommand` 回显——**这正是勘察中标记为"唯一有设计难度"的 Query 点**。`DebugReader` 已完全干净，调试管线的解耦从此只剩这一个语义决策。
>
> **验证边界**：静态/结构验证。GUI 冒烟须重点验 **悬停求值**（鼠标悬停变量 → 是否仍弹出求值提示）、**调试输出窗口的原始 GDB 文本追加**、**停止调试后的标题刷新**。

### F1-m 步骤 3：GDB 命令回显（最后一个 Query）——**已完成（2026-09-28）· 调试管线 21 处全部清零**

`MainForm.*` **33 → 30**，`Debugger.pas` 12 → **0**，两单元符号泄漏全清，`uses main` 摘除。`MainUi` 117 → **120 入口**。

**勘察预判"这处需要真设计"，实测发现设计难度比预想低——但理由很有意思**：

> 原始逻辑是引擎读 `edGdbCommand.Text` 决定是否覆盖。但把**全部调用面**摊开后发现：**12 处传 `ViewInUI := true`**（`main.pas`×7、`ServicesImpl.pas`×4、`edGdbCommandKeyPress`×1），**却没有任何一处读取该控件的文本**。这个框是"最近一条命令的显示屏"，不是引擎解析的输入通道。
>
> **所以这不是"引擎依赖 UI 状态"，而是"引擎请 UI 显示一个字符串"——一件穿着 Query 外衣的 Command。** 勘察把它归入 Query 是对的（因为代码形状确实在读控件），但归因可以更准。

**真正需要建模的只有覆盖保护**：`CommandChanged` 仅在一处置位（`main.pas:5203`，用户敲键时），含义是"**框里现在是用户自己敲的字，别覆盖**"。没有它，step/continue 会抹掉用户敲了一半的命令。

**解法**：flag 留在调试器（它拥有它），**判断下沉到门面**（框在那里）：

| 原 | 新 |
|---|---|
| `if (not CommandChanged) or (MainForm.edGdbCommand.Text = '') then` | `if (not CommandChanged) or (not MainUi.GdbCommandIsUserOwned) then` |

**同一谓词、同一运算顺序、同一短路**——因为 `GdbCommandIsUserOwned` 就定义为"非空"，两者是德摩根等价而非近似。引擎不再读控件，门面不再替引擎猜。

`EchoGdbCommand` 一次完成"写入 + 清除 flag"，使"回显发生了"与"flag 已清"**不可能走散**。

> **`main.pas:5203` 刻意不动**（它写 `fDebugger.CommandChanged`，不是 MainForm 引用）。flag 归调试器所有、由窗体在用户敲键时置位——绕门面改它是为零耦合收益制造扰动。

**断言第三次救场**：`"procedure AppendDebugOutput(const ALine: string);"` 命中 **2** 次（声明 + 实现头），与步骤 2 完全相同的陷阱。**"声明文本与实现头逐字相同"是本项目固有陷阱，已连续两次验证。**

### 副线：注释剥离器修复（owner 维度 2 → 1）

**`strip_noise` 的三份副本全部换成 `scan_scope.strip_pascal_code`**（跨行跟踪花括号深度）。接入前**先写了 8 项单元测试**——而它立刻抓到新实现的 **3 个真 bug**：

1. `(* *)` 注释内的 `{` 被当成开启第二个未闭合花括号区，**吞掉了文件剩余全部内容**（最危险的方向：让棘轮变瞎）
2. 字符串结束引号未输出标记
3. 嵌套花括号判定错误

**这正是"先测后接"的回报**——若直接换进生产工具，第一个 bug 会让棘轮对某些单元完全失明，而且**症状是数字变小**，看起来像好消息。

**实测影响与我先前的预估不同**：

| 维度 | 修正前 | 修正后 | 说明 |
|---|---|---|---|
| headline refs | 30 | **30** | 不变 |
| owner_refs | 2 | **1** | 修正生效 |

`devCFG.pas` 的真实情况是 **refs 2 + owner 1 = 3**；旧工具误报为 **refs 2 + owner 2 = 4**（多算了注释内的 `1985` 行 `with MainForm`）。

> **我先前"30 → 29"的预估是错的**：我假设被剥离的注释会减少 headline refs，实际那行是 `with MainForm do`（**裸句柄形状**，属 owner 维度而非 refs 维度）。**基线把两个维度分开记录，所以 headline 不动，只有 owner 维度 -1。** 修正依然正确——**少算了一个不存在的耦合**——但它体现在另一个维度上。

**验证**：双 profile QA gate OK；棘轮 `violations: 0`（`30 / 5 / owner 1`）；门面 120/120 零漂移；`Debugger.pas` 与 `DebugReader.pas` 棘轮均 armed；F0 与结构自检 OK。

**剩余 30 处**：`EditorOptFrm`(8) · `Macros`(7) · `EditorList`(6) · `main.pas`(4) · `Utils`(3) · `devCFG`(2 + owner 1)

### F1-n 步骤 0：上帝窗体自引用豁免（方案 B）——**已完成（2026-09-28）**

`MainForm.*` **30 → 26**。`main.pas` 的 4 处自引用（`MainForm.Visible` / `Create(MainForm)` / `MainForm.fDebugger` / `MainForm.LeftPageControl`）从指标中豁免。

**理由与 `FACADES` 豁免严格同构**：`MainUi` 被豁免因为它**定义**反腐层的边界，`main.pas` 被豁免因为它**定义**耦合本身。**主体不该被自己定的规则考核。**

**两处实现细节值得记**：
1. **在文件枚举处排除，而非在 8 处统计逻辑里逐一加豁免**——后者可能漏改一处，前者不可能。
2. **判据是硬路径，不是"是否声明了 `MainForm`"**。`Tools/PackMaker/main.pas` 与 `Tools/Packman/Main.pas` **也各声明一个同名全局**且都是无关单元；用声明测试会**误豁免两个真实消费者**（`Tools/Packman/Main.pas` 正在用 `MainForm`）。单元测试专门锁了这一条。

### F1-n 步骤 1：Macros + Utils（10 处）——**已完成（2026-09-28）**

`MainForm.*` **26 → 16**，`uses main` **5 → 3**。`Macros.pas` 与 `Utils.pas` **双双归零**。`MainUi` 120 → **121 入口**。

**10 处只新增 1 个门面入口**（`ProjectUnitList`，供 `<SOURCESPCLIST>`），其余 9 处全是复用（`ProjectExecutable` / `ProjectName` / `ProjectFileName` / `ProjectDirectory` / `CurrentProject` / `EditorByIndex`）。**勘察"Query 组几乎全复用"的预判成立。**

`ProjectUnitList` 保留 `ListUnitStr` 的分隔符参数：**参数本身就是格式决策**，让调用方能传自己的分隔符，等于让宏引擎之外的人去重新定义"单元列表长什么样"。

**断言第四次救场**：`function ProjectRelativePath(...)` 单独一行仍命中 2 次。**这个陷阱已连续四次**（F1-m 步骤 2、3，F1-n 步骤 1 两次）。规则已固定为：**锚点永不用裸声明行，一律用声明块**。

**一处口径不一致（新发现，待决）**：`main_symbols.py` 报 `Utils.pas` 仍有 `MainForm` 泄漏，`uses_main_audit` 因此判它 BLOCKED。**但那 2 处都是 `Application.MainForm`（VCL 属性）**，棘轮的 `_MAINFORM_REF` 已正确排除，而 `main_symbols` 未做同样排除。**这是继"owner/refs 正则不一致"之后的第三处口径分歧**，修法同样是加 `(?<!Application\.)`——**但它会让 Utils 的审计从 BLOCKED 变 SAFE，属独立度量决策，未擅自执行。**

**验证**：双 profile QA gate OK；棘轮 `violations: 0`，基线收紧至 **16 / 3**；门面 121/121 零漂移；F0 与结构自检 OK（含子句唯一性）。

**剩余 16 处**：`EditorOptFrm`(8) · `EditorList`(6) · `devCFG`(2 + owner 1) —— **`uses main` 仅剩 3 个单元**

### F1-n 步骤 1.5：Utils 走门面 + 口径同构（补刀修 A）——**已完成（2026-10-01）**

上节留下的"待决"三处口径分歧，在此**连同真实解耦一并处理**。`MainForm.*` 与 `uses main` 指标**本步不变**（16 / 3）——因为这一步的价值不在数字。

**分叉裁定：方案 B（改 `Utils.pas` 走门面）而非方案 A（只改工具）。**

理由：`Utils.pas` 之所以还挂着 `uses main`，**唯一目的**是借道 `Application.MainForm.Handle` 访问一个 Win32 句柄。若为迎合工具而选 A，它就会变成"语法上仍挂着 `uses main` 锁链、语义上只为蹭一个句柄"的怪胎。既然 `MainUi.MainFormHandle` 自 F1-l 已建好且身经百战，两处直接改走门面，`uses main` 便可**物理摘除**——这是真实解耦，不是让工具闭嘴。

```pascal
Result := ShellExecute(MainUi.MainFormHandle, nil, ...);      // 476
Result := ShellExecute(MainUi.MainFormHandle, 'runas', ...);  // 483
```

**工具侧同步补刀**：`main_symbols.py` 的 `referenced()` 补上 `(?<!Application\.)` 负向断言，与棘轮 `_MAINFORM_REF` / `_MAINFORM_OWNER` **字面同构**。

> **为什么是"复制"而非"独立推导"**：两个工具回答的是同一个问题——"这个单元是否点名了 main.pas 拥有的东西"。定义若不一致，缺陷就属于**这一对工具**，而唯一持久的修法是让定义字面相同。**独立推导正是第三处分歧的成因**；棘轮定义处已有散文说明理由，直接沿用其字面。

`IGNORECASE` 同时补上大小写一侧的洞：`Application.mainform` 是同一属性的另一种拼写。

**鉴别力测试（防止"把工具改哑巴"）**：裸 `MainForm`（成员访问 / owner 传参 / `Assigned` 检查）**仍全部报泄漏**；`Application.MainForm` 三种大小写**均正确排除**；`TMainForm` 类型名**仍报泄漏**。真阳性未被削弱。

**过程中修掉的两个真实缺陷**：
1. docstring 中的 `\.` 触发 `SyntaxWarning`（非 raw string）→ 改写措辞，`-W error::SyntaxWarning` 导入干净。
2. 我最初的测试用例**自身写错两处**（误以为 `uses main` 本身即泄漏；误用双引号当 Pascal 字符串定界符）。逐一核实为用例错误而非工具缺陷——**如实记录，不掩盖**。

**验证**：`Utils.pas` 零泄漏；`uses_main_audit --all` 由 3 降至 2（`EditorOptFrm` 仍 BLOCKED，真耦合未误伤）。

### F1-n 步骤 2：EditorOptFrm（8 处 → 1 动作）——**已完成（2026-10-01）**

`MainForm.*` **16 → 8**，`uses main` **3 → 2**。`MainUi` 121 → **122 入口**。

**勘察第一预判成立**：8 处全在 `btnOkClick` 的**单动作同质群**，收敛为**单个语义门面**，未制造 8 个细碎转发。

```pascal
procedure ApplyEditorAutoSave(const AEnabled: Boolean; AIntervalMinutes: Integer);
```

**刻意不作为参数的东西**：定时器本身与 `OnTimer` 回调。能让调用方交出自己 `TTimer` 或自己回调的接口，等于把门面本该隐藏的控件重新发出去——**而且那个回调根本不是调用方该选的**，它是上帝窗体自己的方法，这正是定时器归门面所有的理由。

`*60*1000` 单位换算**下沉到门面**：`main.pas:6365`（FormCreate）与 `btnOkClick` 是**同一逻辑的两个副本**，此前各自在调用点换算；现在两份不可能再对单位产生分歧。

**传递性复核**（摘 `uses main` 会连带失去 83 个单元）：`transitive lost: {}`——无一声明被 `EditorOptFrm` 引用。**循环依赖排查**：`MainUi` 不依赖 `EditorOptFrm`，单向。

**断言第五次救场**（"锚点永不用裸声明行"纪律的又一次实证）：声明块 `procedure RestoreLeftPageIndex(...); procedure RefreshWatchVars;` 在 `MainUi.pas` 中**出现 2 次**——interface 段一次，`implementation` 前的前置声明又一次。"命中数 == 1"断言当场拦截。若用裸 `text.replace`，新入口会被**同时注入 implementation 的前置声明**：那**仍能编译**，但设计说明注释会静默落进错误段落。规则已改为锚定 `\r\n\r\nimplementation` 作上下文。

**验证**：QA gate OK（8/8、2/2、owner 1/1）；`EditorOptFrm` `main_symbols` 零泄漏、`uses_main_audit` 判 **SAFE**；结构自检 OK（122/122）；`TTimer` 的 `Vcl.ExtCtrls` 已在 MainUi interface uses 中显式存在，依赖非隐式。

### F1-n 步骤 3：devCFG（2 + 1 处，突破编码限制）——**已完成（2026-10-01）**

`MainForm.*` **8 → 6**，`uses main` **2 → 1**，owner **1 → 0**。`MainUi` 122 → **123 入口**。

#### 本步撞出的真实障碍：devCFG 既非 UTF-8 也非 GBK

这正是步骤 3 预设的编码障碍，实测**比预期更棘手**：文件里藏着 **cp1252 弯引号 `0x91` / `0x92`**，位于 GCC 编译参数字符串内：

```
...it has the same meaning as \x91generic\x92.=i686');
```

`utf-8`、`gbk`、`gb18030`、`big5`、`shift_jis` **全部解码失败**；仅 cp1252 系列可解。

> **既有迁移脚本的统一 `read_raw()` 对这个文件是破坏性的。** 它用 `utf-8` + `errors="replace"`：`0x91` 被替换为 U+FFFD，写回时变成 3 字节 `\xef\xbf\xbd`。实测 **116699 字节进、116705 出**，两个引号字节**永久消失**。
>
> **这类破坏不是语法错误，而是要传给编译器的开关字符串被静默篡改**——仓库里任何现有测试都抓不到它。

**修法**：`read_raw()` 改用 **latin-1**——字节与码点 `0..255` **严格双射**，任何字节序列都能逐字节原样写回；ASCII 仍按 ASCII 比较，迁移规则照常写成普通字符串。文本**从不被解释，只被搬移**。

**无损性已用数据证明**：`0x91`×1、`0x92`×2 前后**完全一致**；U+FFFD 计数 **0**；diff 精确收敛到两处预期编辑，别无他物。

#### 设计决策：`TTarget` 刻意不过界面

`TdevCompilerSets.GetCompilationSetIndex` 回答的是**一个**语义问题——"当前生效的编译器集索引"。2 处 `MainForm` 收敛为单个 Query 门面：

```pascal
function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;
```

**枚举不过界**：调用方传自己的默认索引、拿回可能的覆盖值；`ctProject` 的比较**留在门面内部**——枚举声明在 main.pas，把它塞进接口等于**为一个比较运算**就把上帝窗体的类型拖进每个消费方的 uses 子句。

**两处死代码被剔除并说明理由**：原 `Result := -1` 在**每条路径上都会被覆盖**（case 各分支都赋值、else 也赋值），从来不可观测；`else Result := fDefaultIndex` 同样不可达。保留死赋值会暗示一个该函数根本无法返回的默认值。

**注释内的第 3 处 `MainForm`（~1985 行 `with MainForm do`）刻意不动**：它位于 `{ }` 禁用块内、**根本不参与编译**，无需门面入口；`uses main` 一摘除，这条依赖自动消失。**重写死代码来"看起来已解耦"正是本项目此前已两次拒绝的度量化妆**——不夹带。

**验证**：QA gate OK（6/6、1/1、owner 0/0）；传递性零丢失；**无循环依赖**（`MainUi` 不依赖 `devcfg`，单向）；`devCFG` 零泄漏。

### F1-n 步骤 4：EditorList（最后 6 处，方案甲）——**已完成（2026-10-01）**

`MainForm.*` **6 → 0**，`uses main` **1 → 0**，owner 保持 **0**。`MainUi` 123 → **124 入口**。

**勘察推翻了原定性质（如实上报）。** 原计划把本步定性为"容器反向依赖工程的世纪难题，需专题架构讨论"。**实测证据不支持该定性**：

- **6 处引用 100% 是 `MainForm.Project`**，零处触碰窗体自身；
- 依赖方向 `EditorList → Project` **单向**（`Project` 不依赖 `EditorList`）；
- 所以 `EditorList` 对上帝窗体的依赖**完全退化为"当前项目是谁"这一个查询**——恰恰是门面架构最擅长的情形，**不需要架构改造**。

**分叉裁定：方案甲**（只摘 `uses main`，`uses project` 保留）。容器降级为纯数据结构容器作为独立议题另排——理由是证据表明原定定性来自对 `MainForm.Project` 的**误读**，而非代码的真实耦合强度。

**唯一新增入口**（其余全是复用）：

| 新入口 | 取代 | 性质 |
|---|---|---|
| `ProjectUnitIndexOf(const AFileName: string): Integer` | `MainForm.Project.GetUnitFromString(...)` | `GetUnitFromString` 重命名并下移；其体 `fUnits.IndexOf(ExpandFileTo(s, Directory))` **只碰项目自身字段，本就是纯查询** |

复用：`CloseProjectUnitOfEditor`、`OpenProjectUnit`、`CurrentProject`。

#### 一处"顺手复用即引入静默行为变更"的真实风险

`CloseProjectUnitOfEditor` **看似**与原代码等价，实测**不等价**：

```pascal
原代码：  projindex := Units.IndexOf(Editor);
          if projindex <> -1 then CloseUnit(projindex);   // 有防护
门面版：  CloseUnit(Units.IndexOf(e));                   // 无防护
```

若 `IndexOf` 返回 `-1`，门面会把 `-1` 传进 `TProject.CloseUnit`，而它执行 `with fUnits[-1]`——**越界访问**。**`-1` 防护保留在调用点**，只把无防护的尾巴委派出去。

#### 等价性证明（而非近似）

改写用 `ProjectUnitIndexOf(Editor.FileName)` 替代 `Units.IndexOf(Editor)`，看似换了匹配方式，实测**严格等价**：

```pascal
function TUnitList.IndexOf(Editor: TEditor): integer;
begin
  result := IndexOf(editor.FileName);   // 直接委托给文件名重载
end;
```

与 `GetUnitFromString` 走**同一个 `IndexOf(const FileName)` 重载**，同为 `GetRealPath` + `SameText` 规范化匹配。

#### 本步骤我自己制造并当场修正的一次错误（必须留档）

**迁移脚本的三条规则只覆盖了 `MainForm.Project.*` 成员访问，遗漏了两处 `Assigned(MainForm.Project)` 裸访问。** 裸 `MainForm` 来自 main.pas——**摘除 `uses main` 后这两行会直接编译失败**。

校验时发现残留 2 处 `MainForm`，已改用 `Assigned(MainUi.CurrentProject)`。顺带核实：`CurrentProject` 实现为 `Result := MainForm.Project`（**无 nil 保护**），但 `Assigned(...)` 是在**调用方**做保护，语义等价。

> **教训**：断言"迁移已完成"必须复查**裸标识符**，而不只是成员访问——**这正是 `main_symbols.py` 这类工具存在的理由**。若当时只看 ratchet 的 `refs` 归零就收工，会把编译失败留给 IDE。

**验证**：QA gate OK（**0/0、0/0、owner 0/0**）；棘轮基线 `refs` / `owner_refs` / `uses_main` **三个字典全空**；`uses_main_audit --all` 报 **0 个单元**；结构自检 OK（124/124，18 单元子句唯一）；四个原耦合单元 `main_symbols` **全部零泄漏**；CRLF 零裸 LF。

### F1-n 全阶段战果：耦合归零

| 阶段 | `MainForm.*` | `uses main` | owner | 门面入口 |
|---|---|---|---|---|
| 步骤 1 后（F1-n 步骤 1 结束） | 16 | 3 | 1 | 121 |
| 步骤 1.5（补刀修 A） | 16 | 3 | 1 | 121 |
| 步骤 2（EditorOptFrm） | 8 | 2 | 1 | 122 |
| 步骤 3（devCFG） | 6 | 1 | 0 | 123 |
| **步骤 4（EditorList）** | **0** | **0** | **0** | **124** |

**16 处仅用 3 个新入口关闭**（`ApplyEditorAutoSave` / `ProjectCompilerSetIndex` / `ProjectUnitIndexOf`），其余全部复用既有入口——"接线为主、设计为辅"在收尾阶段依然成立。

**遗留（明确不在本阶段范围）**：`EditorList` **仍 uses `project`**。容器对 `TProject` 的类型依赖原样保留，这是方案甲的**定义**而非遗漏。是否推进方案乙（降级为纯数据结构容器），应基于归零后的真实状态另行评估。

> **本阶段的验证边界**：静态 / 结构 / 门禁层面。本环境无法编译 Delphi 单元，**最终编译确认仍需在 IDE 中执行**，建议重点关注 `EditorList.pas`（两处改写 + uses 子句变更）与 `devCFG.pas`（非 UTF-8 编码，需确认 IDE 以正确代码页打开）。

## 4.x 阶段交接：战线 A / B 的实测勘察（2026-10-01）

F1 归零后按路线图开启下一阶段。两条战线的**可执行性差异极大**，以下均为本机实测，不是规划假设。

### 战线 A：IDE 实机编译——**本机有 Studio，但被许可阻断**

路线图假设"在方便时接入装有 IDE 的宿主机"。实测发现**本机已装有 Embarcadero Studio 37.0**（`dcc32.exe` / `dcc64.exe` 均存在），战线 A 无需外部宿主机。但命令行路线被许可挡住，四次尝试逐个排除配置问题：

| # | 尝试 | 结果 |
|---|---|---|
| 1 | 直接 `dcc32` | **"This version of the product does not support command line compiling."** |
| 2 | `dotnet msbuild devcpp.dproj` | `MSB4057`：目标 "Build" 不存在——`.dproj` 从不导入 CodeGear targets，那是 IDE（bds.exe）注入的 |
| 3 | 加 `Source/DelphiBuild.proj` 包装 | targets **成功加载**，转而 `MSB4062`：`DependencyCheck` 任务需要 `Microsoft.Build.Utilities.v4.0`，**.NET Core 版 MSBuild 加载不了 .NET Framework 任务程序集** |
| 4 | 改用 VS 2022 的 .NET Framework MSBuild + `%BDS%`/`%FrameworkDir%` | **管线全线打通**：targets 加载、DependencyCheck 通过、资源编译器 `cgrc.exe` 已运行——**然后 dcc32 再次拒绝命令行编译** |

**结论：管线是正确的，阻断是许可，不是配置。** 本机再无任何配置可改变这一点。

已固化两个交付物，避免后人重复踩坑：

- **`Source/DelphiBuild.proj`**——显式导入 `CodeGear.Delphi.Targets` 后委派给 `devcpp.dproj`。**它不携带任何自己的编译设置**：一旦需要，就是 `devcpp.dproj` 旁边的第二真相源，正是整套工具链要避免的失败模式。
- **`tools/dcc_build.py`**——自动探测 MSBuild/Studio 并运行管线，且**以 exit 3 专门报告"许可阻断"**，与 exit 1（真实编译错误）区分。理由：把许可墙报成编译失败，会让人去改本来完全正确的代码；诚实的信号是"战线 A 仍需已激活的 Studio 或授权席位"。

```powershell
python tools\dcc_build.py --dry-run   # 只显示命令与环境
python tools\dcc_build.py             # 实跑；当前返回 3 = 许可阻断
```

**因此战线 A 状态：管线就绪，执行待授权。** 交互式冒烟（`EditorList` 的 Tab/文件同步、`devCFG` 的 cp1252 代码页）**仍为未完成项**，不因"本机有 IDE"而误判为已完成。

### 战线 B：LCL SynEdit 对赌——**本机无 FPC，只能设计与脚手架**

实测：`fpc` / `lazbuild` / `ppcx64` **全部 NOT FOUND**。**战线 B 在本机无法编译任何一行**，其交付形态只能是设计 + 脚手架。

关键规模数据（`tools/_f2_survey.py`，可复跑）：

| 指标 | 实测值 | 对 F2 的含义 |
|---|---|---|
| 已引用 LCL 的自研单元 | **0** | LCL 是全新引入面，不存在"半成品"清理负担 |
| vendored SynEdit 单元 / 行数 | **130 个 / 119,228 行** | 替换面远大于"53 个 DFM"的直觉 |
| LSP Client 单元 | 4,755 行，**3 个以 `TCustomSynEdit` 为核心签名** | 这是 F2 的真正硬骨头 |

**最重要的发现是最后一行。** 路线图把 F2 描述为"编辑器控件替换"，但真正绑死 VCL 的是 **LSP 客户端层**：`Completion`(1110) / `SignatureHelp`(1407) / `Definition`(805) / `Hover`(1219) 全部以 `TCustomSynEdit` 为签名核心。**换掉编辑器控件本身不解决这 4,755 行**——LCL 的 `TSynEdit` 与 vendored SynEdit 的 `TCustomSynEdit` 并非同一继承树，签名不会自动兼容。

> **这修正了 F2 的问题定义**：真正的赌注不是"SynEdit 能不能画好高亮"，而是"**`TCustomSynEdit` 这套签名能否被一层适配层吸收**"。F1-n 步骤 2 的 `ApplyIdeFont` 已有同类适配先例（`UI/` 下的兼容层思路），但覆盖面远小于此处。
>
> **建议**：F2 启动时，第一步应是**先写适配层接口并让 LSP 客户端层在其上编译通过**，而不是先搭 LCL 工程跑高亮。后者若先做，可能在几千行签名不兼容时才撞墙——那时已经投入了 GUI 工程搭建成本。

**F2 待办（按此顺序）**：① `TCustomSynEdit` 适配层接口设计 → ② 4 个 LSP Client 单元在其上编译通过 → ③ LCL SynEdit 工程 + C++ 高亮基线 → ④ 补全弹窗 / 波浪线绘制能力边界摸底 → ⑤ 53 个 DFM 淘汰评估。

## 4.y F2-a：LSP 客户端对 SynEdit 的依赖实测清单（2026-10-01）

「接口抽象先行」的战略方向**采纳**，但 F2-a 的首要产出**不是接口，而是清单**——因为先写接口会同时踩两个坑：写进去没人调的死契约成员，和漏掉、直到 F2-b 四千行之后才炸的成员。

工具：`tools/lsp_editor_deps.py`（可复跑，`--json` 输出机读格式）。

#### 实测规模

| 单元 | 行数 | `TCustomSynEdit` 标注 | 真实成员访问 |
|---|---|---|---|
| `Lsp.Client.Completion.pas` | 1110 | 11 | **46** |
| `Lsp.Client.SignatureHelp.pas` | 1407 | 14 | 14 |
| `Lsp.Client.Hover.pas` | 1219 | 13 | 12 |
| `Lsp.Client.pas` | 214 | 0 | 5 |
| `Lsp.Client.Definition.pas` | 805 | 9 | 1 |

**47 处 `TCustomSynEdit` 全部是类型标注与参数传递，没有一处直接成员访问。** 真实依赖面是 **22 个成员**——比"4,755 行"的观感小一个数量级，**适配层是可行且可控的**。

类型层依赖另含 `TBufferCoord`(10) / `TDisplayCoord`(1) / `TSynEdit`(5) / `TMarker`(2)。

#### 五项与契约草案的实测冲突

**① `Markers` 是集合，不是标量。** `Lsp.Client.pas:139-182` 驱动 `Count` / `Add` / `Delete`。草案的标量访问器无法表达。

**② `MarkersChanged` 是事件赋值，不是调用。** `FEditor.MarkersChanged := procedure(Sender: TObject)`。接口方法只能表达"发生过这件事"，**表达不了订阅**——这条边界的处理方式需专门裁定。

**③ 写入是一个有序协议，不是独立 setter。** 真实顺序：
```
BeginUndoBlock → BlockBegin → SelText → CaretXY → EndUndoBlock
```
（`Completion:841-859`、`890-917`）。拆成独立 setter 会让调用方把它重排成编辑器不允许的次序。**因此草案的 `SetSelection` + `ReplaceSelection` 不是改名，是错误**——它把"移光标"和"撤销块"当两件事，丢掉了它们作为**一个原子动作**的约束。

**④ `TMarker` 不在客户端层。** 它定义在 `SynHighlighterMulti.pas`——**依赖同时穿过高亮器**，只覆盖 `TCustomSynEdit` 的接口会留下这条边。**这是草案完全没考虑的一层。**

**⑤ `Lines` 有三种用法**：`Lines.Count`、`Lines[i]`、以及 `Lines.Text`。第三种喂给 LSP 文档同步（`LspFlushPendingDocument`），**根本不是行访问器**。

#### 据此的契约设计约束（待 F2-a 第二步定稿）

- 写入侧必须是**单个原子方法**（如 `ReplaceRange(Start, End, const NewText)`），不暴露 begin/end/block/seltext 分离接口；
- 集合与事件订阅**需要独立裁定**（前者可能需引入 `IEditorMarkerList` 协作者，后者可能要提升为回调注册）；
- 接口应覆盖**编辑器 + 高亮器**两侧，而非仅 `TCustomSynEdit`。

> **方法论留档**：本步骤再次验证了本项目的既有纪律——F1 阶段"勘察预判被推翻"出现过多次（步骤 4 的"架构决战"、8 处"单动作群"）。若直接照草案写接口，这五项冲突会在 F2-b 的重构中逐条暴露，届时改接口的成本远高于现在。**契约必须由测量产出，而不是由规划产出。**

门禁复核：QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · 结构自检 OK

## 4.z F2-a 第二步：契约落盘（`Source/LSP/Editor/`）——**已完成（2026-10-01）**

三项裁定全部执行。**但草案逐条核对后发现 6 处需修正**，均已处理并留档。

#### 交付物

| 文件 | 行数 | 依赖 |
|---|---|---|
| `Source/LSP/Editor/Lsp.Editor.Types.pas` | 76 | **零依赖** |
| `Source/LSP/Editor/Lsp.Editor.Interfaces.pas` | 181 | 仅 `Lsp.Editor.Types` |
| `tools/f2_contract_check.py` | — | 契约的机械门禁 |

#### 裁定执行情况

**裁定 1（写入原子化）已执行**，但签名微调为 `ReplaceRange(const AStart, AEnd: TLspBufferCoord; ...)` 而非草案的四个 `Integer`——用坐标记录而非散装整数，避免调用方传错 `(Char, Line)` 顺序。**光标落点与选区坍缩写进了契约注释**，因为它不是实现细节而是正确性要求（`Completion:846-858`）。

**裁定 2（集合与事件接口化）已执行**，但 `IEditorMarkerList` 的签名**与草案不同**：

```pascal
procedure Add(const AMarker: TLspMarkerSpec);   // 草案为 AddLineMarker(Line, Char, MarkerId)
```

原因见下。

**裁定 3（落点 `Source/LSP/Editor/`）已执行**，`Core/` 未受任何污染，其"零 VCL 可直接直迁"评级保持。

#### 六处与草案的偏离及理由

**① `TLspMarkerSpec` 值类型取代 `(Line, Char, MarkerId)` 三元组（设计错误）**
`Lsp.Client.pas:169-179` 实际设置 6 个属性：`Style := msBar`、`Color`、`TopLine`、`BottomLine`、`EndColumn`、`ToolDescription`。**三元组无法承载样式、颜色、工具提示与结束列**——强行套用会迫使客户端层重新依赖具体 Marker 类，恰好重开契约要关的那道门。

**② 颜色用 `R/G/B: Byte` 而非 `TColor`**——`TColor` 属 `Vcl.Graphics`。

**③ `TLspNotifyEvent` 本地声明而非 `TNotifyEvent`**——后者是 `Vcl.Controls` 的符号，契约提及它就无法在 LCL 下实现而不引入 `LCL.Controls` 依赖。

**④ 6 个草案成员因实测零调用而剔除**：`SetCaretPosition` / `GetWordAtPosition` / `SetSelection` / `InvalidateView` / `IsFocused` / `GetWindowHandle` / `ScrollToCaret`。全部记入契约末尾的"刻意省略"清单，**留档而非静默删除**，日后需要时可作为有意识的动作重新加入。

**⑤ 三步坐标链收敛为单方法**：`BufferToDisplayPos → RowColumnToPixels → ClientToScreen` 三步在 `Hover:781-783` 与 `SignatureHelp:910-912` 中**从不被单独使用**，故收敛为 `BufferToScreenPixels`。反向同理。

**⑥ `MouseStillOnRequest` 的边界检查留在调用方**：`Hover:1015-1024` 除坐标换算外还做 `Pt < 0` 与 `ClientWidth/ClientHeight` 越界判定——那是"鼠标是否还在原请求位置"的**策略**，不是坐标换算，移入适配层会越权。

#### 契约门禁（`tools/f2_contract_check.py`）

```
A. 契约 interface 段的 VCL 符号泄漏检查 ...... OK（剥离注释后）
B. 22 个实测成员是否都有归宿 ................. 22/22 mapped, 0 unmapped
C. 类型级依赖是否渗入契约 ..................... 全部 absent
```

**A 段的存在理由**：「契约不含任何 VCL 类型」是**随时间变化的文件属性**，不是关于今天文本的静态事实——一次手滑就会让它失效且不易在评审中察觉。故用机械检查守住。

> **本次修复的一个工具缺陷（如实留档）**：C 段初版未剥离注释，把契约头注释里的散文 "VCL SynEdit today, LCL TSynEdit tomorrow" 判为代码引用，导致**与 A 段结论矛盾**（A 说 clean，C 说 IN CONTRACT）。这类自相矛盾的检查最容易被忽略而从此失效。已修正，并加了**断言两段结论必须一致**的互检，防止复发。

#### 状态

契约已就位。**但 F2-b 开工前发现一个阻断性缺陷，见下节。**

## 4.zz F2-b 开工前的阻断性发现：`Lsp.Client.pas` 的标记代码调用了不存在的 API（2026-10-01）

准备写 `TVclSynEditAdapter` 时，必须先确认契约所描述的调用**在 vendored SynEdit 上真的存在**。结果：**不存在。**

`Lsp.Client.pas:150-186`（`TLspDiagnosticsManager.ApplyDiagnostic`）：

```pascal
Marker := TMarker.Create(FEditor);
Marker.Style := msBar;              // ← 不存在
Marker.Color := LineCtrl;           // ← 不存在
Marker.TopLine := ADiag.Range.Top;  // ← 不存在
Marker.BottomLine := ...;           // ← 不存在
Marker.EndColumn := ...;            // ← 不存在
Marker.ToolDescription := ...;      // ← 不存在
FEditor.Markers.Add(Marker);        // ← Markers 是数组属性，无 Add
```

实测（工具 `tools/lsp_marker_api_check.py`，可复跑）：

| 事实 | 证据 |
|---|---|
| 全仓**仅一处** `TMarker` 声明 | `SynHighlighterMulti.pas:119`，共 **6 个成员**：5 字段（`fScheme`/`fStartPos`/`fMarkerLen`/`fMarkerText`/`fIsOpenMarker`）+ 1 构造函数 |
| 构造函数首参是 `aScheme: Integer` | `TMarker.Create(FEditor)` 传入的是 `TSynEdit` |
| `Markers` 是**索引属性** | `property Markers[Index: Integer]: TMarker read GetMarkers;` → 无 `Count` / `Add` / `Delete` |
| `ToolDescription` 全仓仅 3 处 | 调用方 1 处 + F2 契约注释 2 处；**VCL 侧完全不存在** |

**结论：该例程无法对 vendored SynEdit 编译**，缺失 API 共 10 项。

#### 我的一处判断错误（如实纠正）

勘察中途我曾断言"`Lsp.Client.pas` 无任何调用方、是死代码"。**这是错的**——`--who-uses` 实测：它被 `Editor.pas`、`Lsp.Bootstrap.pas`、`main.pas` 三处 uses，**确实在编译路径上**。

错误的根源是我先搜了标识符出现位置、看到只有自身定义就下了结论，没有去查 uses 关系。**"看起来没人调用"和"确实没人调用"是两件事**，前者必须用后者验证。

#### 这对 F2 意味着什么

- F2 契约**仍然正确**：它是从"这段代码调用什么"推导的，而调用点确实存在。
- 但**契约唯一的标记消费者无法编译**，因此**没有任何东西可以用来验证适配器**。
- 故 **F2-b 必须以修复或退役 `ApplyDiagnostic` 开始**，而不是直接写 VCL 适配器。

这与 F1-l 记录的 `filefrm.pas` 属同类问题（从未真正编译的腐化单元），只是这次藏在**在编译路径上**的单元里，因而更危险。

> **工具自身的两处缺陷（如实留档）**：`lsp_marker_api_check.py` 初版**多报**（窗口无界，把后续 `TSynMultiSyn` 的 41 个成员算进 `TMarker`），又**漏报**（`property Markers[Index: ...]` 的索引列表里有冒号，正则消费了错误的冒号导致整节空输出）。**空输出比错报更危险**——它读起来像"没问题"。两处均已修正并加了注释说明，另修正了 CRLF 下 `\s*` 跨行错锚的问题。

#### 待裁定

`ApplyDiagnostic` 的处置需要决策：**修复**（补齐 `TMarker` 的标记 API 与集合能力，工作量不小）还是**退役**（该诊断渲染功能从未真正工作过）。这属于功能范围决策，不应由移植任务顺手决定。

## 4.zzz F2-b 第一步：VCL 适配器（只读部分）——**已完成（2026-10-01）**

上一节的裁定尚未给出，但**并非全部工作都被阻塞**。实测确认边界干净：

| 事实 | 数据 |
|---|---|
| 78 处成员访问中涉及 Markers 的 | **4 处**（全在 `Lsp.Client.pas`）|
| **完全不涉及 Markers 的** | **74 处（95%）** |
| 四条线的关注点彼此正交 | Completion=光标+写入 · Hover/SignatureHelp=几何 · Definition≈无 |

故 `Source/LSP/Editor/Lsp.Editor.VclAdapter.pas`（**322 行**）先行交付，**契约的读侧与几何侧已实现并经门禁验证**。

#### 边界得到机械验证

```
适配器含 VCL 类型 (允许): True    ← TPoint / TCustomSynEdit / TBufferCoord
契约  含 VCL 类型 (禁止): False   ← CONTRACT CHECK OK
```

**两者同时成立，正是反腐层成立的定义**，而非人工断言。

#### 三处刻意的"不实现"，并说明理由

**① `ReplaceRange` 抛异常而非实现。** 它的行为由 `Completion:841-859` 固定（含撤销括号、选区写入、光标落点、**选区坍缩**——后者是正确性要求，缺失会导致外层 Validate 处理器二次应用）。但同一份 SynEdit 已证明与 LSP 层的假设不符（标记 API 全缺）。**在一个已证实不匹配的 API 面上写写入路径，会产出"看起来对、无法验证"的代码**——这是最坏的结果。

**② `TVclMarkerList` 全部方法抛异常。** vendored `Markers` 是索引属性，无 `Count`/`Add`/`Delete`，**没有诚实的实现可给**。返回 0 或空列表会让调用方循环零次、得出"没有诊断"的结论——**一个错误答案伪装成正确答案**。响亮失败是唯一诚实选项。

**③ `SetOnMarkersChanged` 只存不挂。** 实测该 SynEdit **根本没有 `MarkersChanged` 事件**（整个 `Source/VCL/SynEdit` 零命中）。写入赋值会编译不过；"顺手写上以防万一"则会在未来 SynEdit 升级时静默改变行为。**故明写：经此适配器，标记变更通知不会到达 LSP 层。**

#### 过程中修掉的两处自身失误（如实留档）

**① 适配器初稿引用了不存在的 `MarkersChanged`。** 我按"契约要能注册回调"就写了赋值，**没验证该事件是否存在**——这正是发现 `Lsp.Client.pas` 缺陷时犯的同一个错误，只是这次发生在自己身上。已删除，并补注释说明为何不写。

**② 我的验证脚本误报了 `BufferCoord`。** 它声明在 `SynEditTypes.pas`，而我只 grep 了 `SynEdit.pas`——**反向的假警报**。已改为对照整个 vendored SynEdit。

> **教训**：验证必须覆盖"我以为存在的东西"，而不只是"我改动过的东西"。`lsp_marker_api_check.py` 现已固化对适配器的两项断言（文件规范 + 代码中不得出现对缺失 API 的赋值），**且先剥离注释**——注释里解释"为何不写这行"的散文与那行代码本身长得一模一样，初版检查把散文当成了罪证。

#### 门禁

QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · CONTRACT CHECK OK（22/22）· 适配器：CRLF 322 / 裸 LF 0 / BOM 已加 / 缺失 API 赋值 0

#### 剩余工作

- **写入侧**（`ReplaceRange`）：待该 SynEdit 的写入 API 得到验证后实现
- **标记侧**（`IEditorMarkerList`）：待 `ApplyDiagnostic` 的功能存亡裁定
- **接线**：4 个 LSP Client 单元从 `TCustomSynEdit` 改走契约（这是 4,755 行的主体工作量）

## 4.zzzz F2-b 接线第一步：`Definition.pas` 样板落地——**已完成（2026-10-01）**

三项裁定全部执行。**第一个彻底脱离具体编辑器控件的 LSP 客户端模块已交付。**

| 文件 | 净改动 |
|---|---|
| `Source/LSP/Client/Definition/Lsp.Client.Definition.pas` | **+25 / −19** |
| `Source/Editor.pas` | **+34 / −3** |

#### `Definition.pas` 已彻底脱离 SynEdit（机械验证）

```
TCustomSynEdit x0   SynEdit x0   TBufferCoord x0
TPoint x0           BufferCoord x0           TMethod x0
uses: System.SysUtils, System.Classes, System.Generics.Collections,
      System.SyncObjs, LSP.Transport, Lsp.DocumentSync,
      Lsp.Editor.Types, Lsp.Editor.Interfaces
```

**`SynEdit` 已从 uses 子句移除**——这不是"不再使用"，是**编译层面不再可达**。

#### 两处技术修正已按裁定固化

**① 接口比较的缓存依赖写进了代码注释**（`GetAdapter` 声明处 + `EditorDestroyed` 实现处）。措辞直白到不留误解余地：

> `CACHING IS LOAD-BEARING, NOT AN OPTIMISATION` … `Never change this to build a new adapter per call.`

**② 析构时序已按裁定固化**，注释标明三步各自的理由：
1. 通知 manager（此时适配器仍存活，接口比对才能成立）
2. 置空适配器（**`fText` 仍存活**，否则适配器析构会触碰已释放内存）
3. 之后才 `FreeAndNil(fText)`

#### 死代码处置（裁定 B）

`Definition.pas:466` 的 `TMethod(FOnNoResult).Data = Pointer(AEditor)` 已删除。`FOnNoResult` 改为**无条件置 nil**——一个正在被摘钩的 manager 本就不该持有回调。**该分支本就永不触发，故删除不改变任何运行时行为。**

#### 过程中拦下的四个错误（如实留档）

**① 编码陷阱。** `Editor.pas` **不是 UTF-8**（中文注释在 utf-8 下是乱码，实为 latin-1/cp1252 族）。若按 utf-8 读写往返，**中文注释会被永久损坏**——正是 F1-n 步骤 3 记录过的陷阱。脚本全程 latin-1，验证：**BOM 保留、U+FFFD 计数 0、零裸 LF**。

**② 行尾双重化。** 迁移脚本的 `edit()` 初版对已含 `\r\n` 的字面量再调 `.replace("\n", eol)`，会产出 `\r\r\n`。**dry-run 当场拦截**——这正是"锚点断言"的价值。已改为先归一 LF 再转 EOL。

**③ uses 锚点选错位置。** 我锚在 `Editor.pas` uses 子句的**首行**，命中 0——该子句跨四行续行，续行点是"加一个单元就会变"的实现细节。已改锚**子句末尾**（单行、唯一）。

**④ 门禁自身过期（最值得记的一条）。** 改造完成后 `CONTRACT CHECK` **FAILED**：

```
FAIL GetAllText -> NO MAPPING
```

这不是代码缺陷——`GetAllText` 正是契约为 `Lines.Text` 准备的成员，是**改造的正确产物**。根因：门禁的 `COVERAGE` 映射表只登记"被替换掉的 SynEdit 成员"，而改造后代码里出现的是**契约成员名**。

> **一个只在"正确改造"时才触发的门禁缺陷，比一个错报更危险**：它会教会人忽略这条检查。已补映射并加注释说明来历。**这类门禁必须随契约一起维护，否则第一次成功迁移就会把它变成噪音。**

#### 类型链验证

`fText` 实际类型是 `TSynEditEx`（本项目自定义子类），而非 `TCustomSynEdit`。已核实继承链完整：`TSynEditEx` → `TSynEdit` → `TCustomSynEdit`，故 `TVclSynEditAdapter.Create(fText)` 合法。

#### 门禁

QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · CONTRACT CHECK OK · 结构自检 OK

#### 下一步

样板已验证可行且无语法裂痕，`Hover`(12 处) + `SignatureHelp`(14 处) 可按同一模式推广；`Completion`(46 处) 含写入协议，需等 `ReplaceRange` 可实现。

## 4.zzzzz F2-b 接线第二步：`Hover.pas` + `Editor.pas` 配套——**已完成（2026-10-01）**

| 文件 | 规则数 | 结果 |
|---|---|---|
| `Source/LSP/Client/Hover/Lsp.Client.Hover.pas` | 24 | **代码中 SynEdit 类型零残留** |
| `Source/Editor.pas` | 7 | 调用点与坐标类型同步 |

#### 脱离验证（剥离注释后扫描代码）

```
TCustomSynEdit 0   TBufferCoord 0   TDisplayCoord 0
TSynEdit 0         BufferCoord 0
```

#### 本步最有价值的一条发现：`uses` 干净 ≠ 迁移完成

第一遍迁移后，`uses` 子句已无 `SynEdit`，**看起来完工**。但残留扫描发现 **4 处 `TBufferCoord` 仍在内部签名里**（`PosInLastRange` 声明+实现、`DismissIfOutside` 参数、`FillHintAndShow` 的局部变量）。

> **Delphi 只在使用时解析名字**。私有签名里残留一个 `TBufferCoord` 完全能编译，**直到换 LCL 适配器那天才炸**，而报错指向的是一行没人记得改过的代码。**从 `uses` 移除 `SynEdit` 是必要的，但不充分。**

已据此给迁移脚本加**强制后置断言**（剥离注释后扫描残留类型），并在本次执行中**真的抓到了 4 处漏网**。

#### 过程中拦下的六个错误（如实留档）

**① 臆造例程名。** 我写了 `ShowAt(const ABufferPos: TBufferCoord)`——**该例程不存在**。命中数断言当场拦截。

**② 接口声明与实现的缩进不同。** `DismissIfOutside` 在 class 内缩进 6 空格、实现处 2 空格。我按统一缩进写，断言报"声明不存在"。

**③ 跨单元调用私有函数。** 我让 `Editor.pas` 调用我在 `Hover.pas` **implementation 段**定义的 `MakePixelPoint`——**编译器看不见它**。改为在 `Editor.pas` 自身定义 `MakePixelCoord`。

**④ 顺序语义被我差点改掉。** `MouseStillOnRequest` 原代码是"**先转客户端坐标 → 做边界检查 → 再转缓冲区**"。若直接塌缩成一次 `ScreenPixelsToBuffer`，鼠标在编辑器外时会拿无意义坐标再做边界判定——**语义变了**。已保留原顺序，边界检查改用契约的 `GetClientWidth/GetClientHeight`。

**⑤ 后置断言在 dry-run 阶段误报。** `--dry-run` 不写文件，却去检查残留——逻辑错误。已改为仅在真实执行后检查。

**⑥ 注释提及被当成残留。** Hover 有两处合法注释提及 `BufferCoord`，初版断言报失败。**先剥离注释再扫描**——这与 `f2_contract_check` 当初犯的是同一个错。

#### 门禁缺陷第二次触发，已改为通用规则

改造后 `CONTRACT CHECK` 报 5 个 `NO MAPPING`（`BufferToScreenPixels`/`ScreenPixelsToBuffer`/`GetLineHeight`/`GetClientWidth`/`GetClientHeight`）。

这与 `Definition` 后的 `GetAllText` **完全同类**，**连续两次**即构成规律：**单元改造后代码里出现的是契约成员名，而映射表只登记 SynEdit 成员名**。

> 已改为通用规则：`CONTRACT_MEMBERS` 列出契约自身定义的全部成员，命中即视为已覆盖。检查的牙齿保留给真正该报的情形——**某个 SynEdit 成员在契约里没有归宿**。

#### 两处指引与真实代码不符（按代码改写）

- 指引写 `fText.PixelsToRowColumn(Point(X, Y))`，真实是 `FEditor.ScreenToClient(Mouse.CursorPos)`（起点是**屏幕**坐标）
- 指引写 `fText.RowColToPixels`，真实成员是 `RowColumnToPixels`（大写 C）

#### 门禁

QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · CONTRACT CHECK OK · 结构自检 OK · 编码完好（BOM 保留、U+FFFD 计数 0、零裸 LF）

#### 状态

- **已脱离 SynEdit**：`Definition.pas`、`Hover.pas`
- **尚未改造**：`SignatureHelp.pas`（14 处，几何侧，契约已就位，**无阻塞**）、`Completion.pas`（46 处，含写入协议，需等 `ReplaceRange`）
- `Editor.pas` 中 `SignatureHelp` / `Completion` 的调用点仍传 `fText`——**与迁移前一致，未引入新的不一致**

## 4.zzzzzz 编译阻断的最终定性 + 静态验证器——**已完成（2026-10-01）**

按建议先做"编译验证准备"。结论分两部分。

### 一、许可阻断的**最终定性**：阻断在转发器

四轮管线排查（targets 加载 → DependencyCheck 通过 → `cgrc.exe` 运行 → dcc32 拒绝）后，用 `tools/dcc_refusal_probe.py` 对整个 Studio 树做字节级定位（**同时搜窄字符与 UTF-16**）：

```
扫描 2254 个文件
完整句子命中：bin/dcc32.exe · bin/dcc64.exe · bin64/dcc32.exe · bin64/dcc64.exe
3.4 MB 的 dcc32370.dll（真实编译器）—— 不含该文本
```

> **`dcc32.exe` 是一个 23 KB 的转发器，它在触及真实编译器之前就决定拒绝。** `dcc32370.dll` 完好躺在 `bin/` 与 `bin64/`。编译器在，只是命令行走不到它。

**因此本机永远无法从命令行编译**，而绕过转发器**不被采纳**：直接驱动未授权的编译器首先是许可问题，其次是支持问题。**如实记录，不予规避。**

> **一处自我纠正（如实留档）**：我此前判定"那句拒绝字符串在 exe 和 dll 里都不存在"。**那是搜索缺陷，不是事实**——该字符串以 **UTF-16** 存储，而我首轮只按 latin-1 字节比对。它确实在 exe 里，**这正是转发器成为关口的原因**。

管线本身已验证正确，四个环节逐个排除。
### 二、既然编译不可用，就把"编译器会抓的错"变成可断言的检查

新增 **`tools/f2_static_verify.py`**，检查四类**编译器一定会抓**的错误：

```
1. 契约 vs 适配器：每个声明的方法都已实现
   contract declares 17, adapter implements 19   missing: (none)
2. 已迁移单元的代码中无 SynEdit 类型（含 Hover 步发现的 4 处内部签名）
   Definition OK clean / Hover OK clean
3. 已迁移单元调用的适配器成员都在契约上
   Definition: GetAllText
   Hover: GetAllText, GetClientHeight, GetClientWidth, ScreenPixelsToBuffer
4. 析构时序：notify@567 < clear@714 < FreeAndNil(fText)@1019  -> OK
   且已迁移的 manager 必须走适配器、不得再传 fText
```

**当前状态：STATIC VERIFY: OK。**

> **工具自己明写了自己的边界**：`green here means the SHAPE is right; it is not a compile`。它查不出类型错误、重载解析、方法体是否正确。**这是替代品，不是等价物**——把它当编译通过的证据，就是本项目反复拒绝的那种自欺。

### 三、验证器自身的两处缺陷（都被它自己的第一轮 FAIL 暴露）

**① 契约方法解析失败。** 报 `contract declares 0`，进而把所有适配器调用判为"不在契约上"。根因：按小写 `implementation` 分割，而文件里是大写——**检查器因为自己的 bug 大声报错，报的却是完全错误的原因**。这最危险：会让人去查一个根本不存在的"契约方法缺失"。

**② 析构顺序误报 FAIL。** 报 `FreeAndNil(fText)@1368` 早于 `clear@1489`——**顺序明明是对的**。根因：命中的 `FreeAndNil(fText)` 是**注释里**的字样（`TEditor.Destroy` 的 F2 说明文字提到了它），而非真实调用。

> **这是同一个错误的第三次出现**：不剥离注释就做基于名字的扫描。三次分别是 `f2_contract_check`（C 段）、Hover 迁移后置断言、本验证器第 4 项。**已把"先剥离注释"确立为本仓库扫描类工具的固定前置步骤。**

#### 门禁

QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · CONTRACT CHECK OK · STRUCTURAL CHECK OK · **STATIC VERIFY OK**

#### 状态与建议

- **已脱离 SynEdit**：`Definition.pas`、`Hover.pas`（静态验证全绿）
- **待改造**：`SignatureHelp.pas`（14 处，**无阻塞**）、`Completion.pas`（13 处 SynEdit 引用 + 46 处成员访问，含写入协议）

**建议**：编译阻断是**环境级、不可在本机解除**的。已把可静态化的风险用 `f2_static_verify.py` 固化到与编译同等的门禁地位。**在有 IDE 的机器上做一次编译即可闭环**；在此之前继续推进 `SignatureHelp` 的边际风险已大幅降低。

## 4.zzzzzzz F2-b 接线第三步：`SignatureHelp.pas` + `Editor.pas`——**已完成（2026-10-01）**

| 文件 | 规则数 | 结果 |
|---|---|---|
| `Source/LSP/Client/SignatureHelp/Lsp.Client.SignatureHelp.pas` | 23 | **代码中 SynEdit 类型零残留** |
| `Source/Editor.pas` | 3 | 三处调用点 + 析构块重写 |

**三个单元现已全部脱离 SynEdit**：Definition ✓ Hover ✓ SignatureHelp ✓

#### 本步抓到一个**真实缺陷**（非工具问题）

改造 `Editor.pas` 时发现 `TEditor.Destroy` 中 **Hover 被通知了两次**：

```pascal
LspHoverManager.EditorDestroyed(fText);      // :614  原始块
...
LspHoverManager.EditorDestroyed(FEditorAdapter);  // :634  适配器块（上一轮加的）
```

第一次调用会把 `TCustomSynEdit` 传给已改为接口的形参——**这是编译错误**；即使能编译，也是重复摘钩。

> **这类缺陷只有把两侧放在一起看才会暴露**：单独看"Hover 已迁移"和"`Editor.pas` 已加适配器"，两者都成立；合起来才看出中间多了一次通知。**已把原始块收窄到只剩 Completion**（唯一未迁移者），三个已迁移 manager 统一走适配器块。

#### 迁移脚本需要手工维护的教训（如实留档）

`_f2b_editor_side.py` 第二次运行时，**上一轮已应用的规则命中 0** 并中止。这是正确的行为——**一条悄悄失配的规则什么都不会改，而大声中止不会**。

已在脚本中注明取舍：需要按轮次手工裁剪规则列表是个气味，**但断言让这个手工动作是"响的"**，而这才是关键部分。

#### 顺带修正：验证器的单元清单

`f2_static_verify.py` 的 `MIGRATED` 若漏列一个已迁移单元，它**根本不会被检查**——**这个失败不会自己出声**。已更新并加注释说明双向后果（多列会正确地失败、漏列则静默）。

#### 本步其余细节

- **`CaretX`/`CaretY` 成对读取**：原代码分两次读，改造后先 `CaretPos := FEditor.GetCaretPosition` 存进局部变量——契约把"成对"这件事显式化了
- **弹窗定位**：`DisplayXY` 链塌缩为 `CaretToScreenPixels`（与 Hover 的 `BufferToScreenPixels` 不同——SignatureHelp 定位的是**光标**，不是任意缓冲区位置）
- **接口比较处的缓存依赖注释**已加在 `EditorCaretMoved` 的 `AEditor <> FEditor` 处，措辞与 Definition 一致

#### 门禁

QA gate OK · 棘轮 violations 0 · CONTRACT CHECK OK · STRUCTURAL CHECK OK · **STATIC VERIFY OK**

```
2. Definition clean / Hover clean / SignatureHelp clean
3. SignatureHelp 调用: GetAllText, GetCaretPosition
4. 三个 manager 全部走适配器；notify@357 < clear@615 < FreeAndNil(fText)@920
```

#### 剩余

**仅 `Completion.pas`**（13 处 SynEdit 引用、46 处成员访问）。它含**写入事务**（`BeginUndoBlock`/`BlockBegin`/`SelText`/`CaretXY` 协议），而适配器的 `ReplaceRange` **当前故意抛异常**（F2-a 第二步的决定：SynEdit 的写入 API 未经验证前不实现）。

故 `Completion` 的迁移**阻塞在一个尚未做的决定上**：是先验证 SynEdit 写入 API 并实现 `ReplaceRange`，还是接受 `Completion` 无法在本步迁移。

## 4.zzzzzzzz F2-b 收官：`Completion` 暂缓裁定 + 边界固化——**已完成（2026-10-01）**

**裁定：选项 2 —— `Completion.pas` 本轮不迁移。**

三个选项的权衡：
1. 先验证 SynEdit 写入 API 再实现 —— **本机无编译器，验证不了**
2. **采纳**：接受 `Completion` 不迁移，写入路径留作独立议题
3. 实现但标注未验证 —— **风险：无法验证的写入路径可能引入静默行为变更**

采纳 2 的理由：`ReplaceRange` 会**修改用户正在编辑的文档**。在一个无法运行的 API 上写这样的代码，风险与收益不成比例。这与 F2-a 第二步"标记方法抛异常而非返回假值"是同一个判断：**宁可响亮地不做，不可静默地做错**。

#### 关键：这条边界被固化进门禁，不靠记忆维持

`f2_static_verify.py` 新增**第 5 项检查——双向断言**：

```
== 5. deferred units are still RAW, and still wired RAW ==
   OK   Completion     still raw (13 SynEdit refs) -- as decided
   OK   Completion     still receives fText in Editor.pas
```

> **两个方向都必须断言，缺一不可**：
> - 只断言"仍是 raw" → 一次半途而废的迁移也能通过（改了一半，SynEdit 引用恰好清零或未清零都不报）
> - 只断言"仍传 fText" → 一个没人调用的单元也能通过
>
> 合起来才表达：**这是一个完整、自洽、有意未迁移的单元，不是一个坏掉的单元。**

并且：**若有人把 `Completion` 迁移了却忘了把它移出 `PENDING` 列表，检查器会打印 NOTE 提示**——因为"已完成却仍在待办列表"是另一种静默失效。

#### F2-b 阶段最终状态

| 单元 | 状态 | 说明 |
|---|---|---|
| `Definition.pas` | ✅ 已迁移 | 1 处成员访问 |
| `Hover.pas` | ✅ 已迁移 | 12 处，几何 + 边界检查 |
| `SignatureHelp.pas` | ✅ 已迁移 | 14 处，光标定位 |
| `Completion.pas` | ⏸ **有意暂缓** | 46 处成员访问 + 写入事务 |

**读侧 100% 完成，写入侧有意留白。**

```
STATIC VERIFY: OK
  1. 契约 17 个方法全部已实现，missing: none
  2. 三个已迁移单元代码中 SynEdit 类型零残留
  3. 调用的适配器成员均在契约上
  4. notify@357 < clear@615 < FreeAndNil(fText)@920；三个 manager 走适配器
  5. Completion 仍 raw 且仍传 fText（有意为之，双向断言）
```

#### 门禁

QA gate OK（0/0、0/0、owner 0/0）· 棘轮 violations 0 · CONTRACT CHECK OK · STRUCTURAL CHECK OK · **STATIC VERIFY OK**

#### 解除暂缓的前置条件（写清楚，避免将来含糊）

`Completion` 可迁移的**充要条件**是：`ReplaceRange` 的实现被真实编译并运行验证过。具体需要：

1. 一台有 IDE 的机器，编译本工程（当前受 Community Edition 缺 `dcc32.dll` 阻断）
2. 验证 SynEdit 写入 API 语义与 `Completion:841-859` 一致，特别是**选区坍缩**（注释明确说缺失会导致外层 Validate 处理器二次应用）
3. 实现 `ReplaceRange` 后，把 `Completion` 加入 `f2_static_verify.MIGRATED` 并从 `PENDING` 移除——**检查器会提示这一步**

**在满足这三步之前，不应实现 `ReplaceRange`。**

### F1-b：进程抽象 / Transport 去 Win32 化 ——**已完成（2026-09-27）**

`Lsp.Transport` 原先直接持有 `CreateProcess` + 4 个匿名管道句柄。F1-b 把它降级为**纯接口消费方**：

| 单元 | 职责 | 依赖 | 编入 |
|---|---|---|---|
| `LSP/Process/Lsp.Process.pas` | `ILspProcess`（阻塞读/写/终止/存活/LastError）+ `ILspProcessFactory`；契约明确"读为阻塞语义、靠 Terminate 解除阻塞" | 仅 RTL | portable |
| `LSP/Process/Lsp.Process.Fpc.pas` | 基于 RTL `TProcess`（`poUsePipes`+`poStderrToOutPut`），Windows/Linux 同一代码路径 | `Classes`（整单元 `{$IFDEF FPC}` 包裹） | portable |
| `LSP/Process/Lsp.Process.Factory.pas` | 编译器选择器：`FPC→Lsp.Process.Fpc`，`Delphi→Lsp.Process.Win32` | 仅 LSP.Process | portable |
| `LSP/Process/Lsp.Process.Win32.pas` | **原实现逐行搬迁**：`CreateProcess`+双管道、`ReadFile/WriteFile`、`TerminateProcess` | `Winapi.Windows` | 仅 Delphi（门禁禁止进入 FPC 工程） |

结果：
- `Lsp.Transport.pas` 从 632 行降到 **530 行**，`Winapi/CreateProcess/CreatePipe/ReadFile/WriteFile/CloseHandle/TerminateProcess/GetLastError/TStartupInfo/TSecurityAttributes` 引用**全部归零**（`CloseHandle` 仅剩注释提及）→ **LSP 传输层已具备 100% 跨平台条件**。
- 语义等价性保持：clangd 启动参数逐字不变（`--background-index --clang-tidy --completion-style=detailed --header-insertion=iwyu --pch-storage=memory --compile-commands-dir=... --log-level=error`）、stderr 仍并入 stdout、跨线程派发仍为 RTL `TThread.Queue`。
- 新增冒烟检查 6 项（工厂可用、子进程启动、stdout 经抽象可读、终止后非存活、Transport 无连接构造/析构、状态正确）：portable 变体 **48 项**、Windows 变体最多 **50 项**。子进程用**测试二进制自身**以 `--child-echo` 模式自启动，因此不依赖任何外部工具，Windows/Linux 行为一致。
- 门禁同步升级为**条件编译感知**（见 §5 表），并用 8 例注入矩阵回归（裸 `TProcess` 必报、`{$IFDEF FPC}` 内放行、注释/字符串提及放行、守卫内 `Write-Host` 仍报、`{$ENDIF}` 之后必报、嵌套块之后必报、`{$IFNDEF FPC}` 分支必报）。

### F2：Lazarus SynEdit 适配与 LSP 渲染层迁移（4–6 周）
- 用 Lazarus 官方 SynEdit 替换 vendored Delphi SynEdit，写 `Editor.LclAdapter.pas` 吸收 `OnPaint/Gutter/Marks/BufferCoord` 差异。
- `TLspHoverHintWindow` / `TLspSignatureHintWindow` 改基类为 LCL `THintWindow`；波浪线诊断走 LCL SynEdit 的 markup/插件机制；补全结果绑定 `TSynCompletion`。
- 退出判据：Lazarus 窗口可打开 C++ 文件、语法高亮、输入 `.` 触发 clangd 真实补全、F12 跳转定义。

### F3：窗体体系重塑 DFM→LFM（8–10 周）
- 第一批（骨架）：主窗体不直接转换 `main.dfm`（6,702 行），以 LCL 停靠体系重建，把 `OutputConsoleFrame` / `ProjectTreeFrame` / `WatchCallStackFrame` 以代码方式挂载；同时把 `main.pas`（7,814 行）物理拆解为编辑器/工程/工具链控制器。
- 第二批（高频弹窗）：FindFrm、CompOptionsFrm、ProjectOptionsFrm 等，先用 Lazarus "Convert Delphi Unit/Form" 转换，再人工修锚点。
- 第三批（低频）：关于页、格式化配置、图标选择器。
- 国际化：保留 `Lang/*.lng` 文本格式；`MultiLangSupport.pas` 改为 UTF-8 原生读取（去掉 Delphi codepage 转换层）。


### F3 实测基线（2026-10-04，53 个 DFM 的可转换性）

原方案用一句话给出 F3「8–10 周」，但没有任何东西测量过 DFM 转换器实际能否读懂这些窗体。现已建立基线（工具：`tools/f3_form_survey.py` + `tools/f3_form_ratchet.py`，纯文本分析，无需 Lazarus）。

**53 个自研 DFM 中 43 个可直接转换，10 个需人工介入。**

| 阻塞来源 | 窗体实例数 | 含义 |
|---|---|---|
| **vendored**（`Source/VCL` 第三方 Pascal） | 18 | `ClassBrowsing`、`devShortcuts`、`SynEdit` 高亮器、`SVGIconImageList`、`CompOptionsList` —— 窗体本身可转换，但这些类需要 LCL 等价物 |
| **external**（仓库内**无声明**，来自 Delphi RTL / 二进制包） | 9 | `TVirtualImage`(3)、`TImageCollection`(4)、`TVirtualImageList`(1)、`TControlBar`(1)、`TAnimate`(1)、`TDdeServerConv`(1) |
| **own**（自研） | 2 | `TCompOptionsFrame` |

**这组数字改写了 F3 的成本结构**，原因有三点：

1. **12 个阻塞窗体中，只有 2 个卡在自研代码上。** 方案原本按「53 个窗体都要重做」估算，实际绝大多数窗体的 DFM 转换是机械工作。
2. **external 类被误当成「要转换的控件」会高估工作量。** `TVirtualImage` 等只作为字段类型出现（`viThemePreview: TVirtualImage;`），窗体本身照常转换，需要替换的只是那个字段。
   **实测印证**：`TToolButton` 曾被漏入 widgetset 清单，误判阻塞了 **50 个字段**（占 external 的 82%）。补入后基线由 41 升至 **42**，external 由 12 类降至 6 类 ——「一个清单条目」换来了「五成的 external 工作量归零」。
3. **main.dfm（566 控件，11 个自有/外部类）是唯一的重灾区**，印证了方案「第一批不直接转换 main.dfm，改用 LCL 停靠体系重建」的判断。

**据此修正 F3 批次划分**（原方案第一批为骨架重建，第二批高频弹窗）：

| 批次 | 范围 | 依据 |
|---|---|---|
| 批量转换 | **41 个无阻塞 DFM** | 已实测可直接转换，无需人工 |
| 字段替换 | 涉及 external 类的窗体 | 窗体转换 + 替换 1–2 个字段 |
| 重建 | `main.dfm` + `ProjectOptionsFrm` + `EditorOptFrm` | 控件数与自有类密度最高 |

**门禁**：`f3_form_ratchet.py` 以 43 为基线，任何使可转换数下降的改动都会失败；上升需显式 `--write-baseline` 确认，不会自动接受。已接入 `fpc_ci.yml` 的第 4 个作业 `f3-form-ratchet`。
#### External 控件平替矩阵（2026-10-04 实测，`tools/f3_external_matrix.py`）

「external」= 仓库内**无声明**、来自 Delphi RTL 或二进制包的控件。工具逐个读取其**真实用法**（字段声明 + 代码中每一处读写），再给出可执行的处置判定。

| 类型 | 字段数 | 出现窗体 | 代码使用 | LCL 平替 | 判定 |
|---|---|---|---|---|---|
| `TToolButton` | **50** | `main.dfm`, `Main.dfm` | Caption/ImageIndex/Enabled | `TToolButton`（LCL 原生） | **已修正为可转换**（曾误列） |
| `TImageCollection` | 4 | `DataFrm.dfm`, `Main.dfm` | 声明后未驱动 | `TImageList` 或仓库已有的 `TSVGIconImageList` | REPLACE |
| `TVirtualImage` | 3 | `EnviroFrm`, `LangFrm`, `main` | `ImageIndex`/`Visible` | `TImage` + `TImageList` | REPLACE |
| `TVirtualImageList` | 1 | `Main.dfm` | `ToolBar1.Images`、`MainMenu1.Images` | `TImageList` | REPLACE |
| `TControlBar` | 1 | `main.dfm` | 仅 `Visible` | `TToolBar`/`TPanel` 停靠（LCL 停靠语义不同，需设计） | REPLACE |
| `TAnimate` | 1 | `RemoveForms.dfm` | 仅 `Active := False` | **无等价物**（AVI 播放控件） | **需决策** |
| `TDdeServerConv` | 1 | `main.dfm` | `DDETopic := ...Name` | **LCL 无**（Windows 专属 IPC） | **需决策** |

**结论与两个决策点**：

1. **`TAnimate`** 仅用于 `RemoveForms.dfm` 的 AVI 装饰动画，代码只做 `Active := False`。LCL 无等价控件。**建议直接删除该控件与其 DFM 组件**（纯装饰，不影响功能）。
2. **`TDdeServerConv`** 用于 Dev-C++ 经典的「DDE 把文件交给已运行实例打开」。现代做法是命名管道或 `CreateMutex` 单实例。**建议按 F3 范围先删除 DDE 单实例通道**，改由 M2 的单实例实现承接；跨平台目标本就要求移除 Windows 专属 IPC。

**判定纪律**：工具只在字段「声明后从未被驱动」时才建议 DELETE；凡有属性读写或方法调用一律判 REPLACE，因为删除会改变行为。上表 4 个 `TImageCollection` 字段正属此类 —— 声明后无使用，但它们是 `uses` 里的运行时组件，删除需连带清理 `uses`。

#### 批次执行清单（2026-10-04 实测，`tools/f3_batch_plan.py`）

**45 / 53 个窗体无需重写任何组件**，仅 8 个需要。这是可执行的批次划分：

| 批次 | 窗体数 | 组件数 | 处置 |
|---|---|---|---|
| **A 机械转换** | **42** | 744 | 无阻塞控件，直接转换。含 `FindFrm`、`FilePropertiesFrm`、`CPUFrm`、`ProfileAnalysisFrm`、`ToolEditFrm`、`ExceptionsAnalyzer`、`InstallWizards` 等绝大多数窗体 |
| **B 字段级** | **3** | 109 | 仅被 external 类阻塞且均有 LCL 等价：`RemoveForms`(TAnimate)、`LangFrm` + `EnviroFrm`(TVirtualImage) |
| **C 需重建** | **8** | 950 | 被 vendored / 自研类阻塞，须先写 LCL 对应物 |

**C 批的 8 个窗体**（真正的排期风险，且高度集中）：

| 窗体 | 组件 | 阻塞类来源 |
|---|---|---|
| `Source/main.dfm` | 566 | `ClassBrowsing`(4) + `devShortcuts` + `devFileMonitor` + `TControlBar` + `TDdeServerConv` + `TVirtualImage` |
| `EditorOptFrm.dfm` | 124 | `TSynCppSyn`（SynEdit 高亮器） |
| `ProjectOptionsFrm.dfm` | 112 | `TCompOptionsList` + `TCompOptionsFrame` |
| `Tools/Packman/Main.dfm` | 58 | `SVGIconImageList`(3) + `TImageCollection` + `TVirtualImageList` |
| `CompOptionsFrm.dfm` | 54 | `TCompOptionsList` + `TCompOptionsFrame` |
| `DataFrm.dfm` | 19 | `TSynCppSyn` + `TSynRCSyn` + `SVGIconImageList` + `TImageCollection` |
| `NewProjectFrm.dfm` | 14 | `TSVGIconImageList` |
| `CompOptionsFrame.dfm` | 3 | `TCompOptionsList` |

**由此得出的执行顺序**：

1. **先做 A 批 42 个** —— 它们不依赖任何新代码，可立即批量转换并验证，是 F3 的主体工作量。
2. **B 批 3 个** —— 随 A 批顺带完成，只需换字段类型。
3. **C 批 8 个** —— 集中在 4 个 vendored 库（`ClassBrowsing` / `devShortcuts` / `devFileMonitor` / `SynEdit` 高亮器）与 1 个自研（`CompOptionsList`）。**其中 `SynEdit` 高亮器最关键**：`TSynCppSyn` / `TSynRCSyn` 是 C++/RC 语法高亮，LCL 的 `TSynCPPSyn` 已有等价物，优先替换。

> 注意 `Source/main.dfm`、`Tools/PackMaker/main.dfm`、`Tools/Packman/Main.dfm` **三者是不同文件**（333KB / 90KB / 129KB），但 Windows 大小写不敏感，列表里极易混淆 —— 清单工具已改为输出相对 `Source/` 的完整路径。
#### Sprint F3-2 执行结果（2026-10-04）

**① 外部类物理清除（按裁定）**

| 目标 | 文件 | 实际删除 |
|---|---|---|
| `TAnimate` | `Tools/Packman/RemoveForms.pas/.dfm` | 字段 1 + 调用 3 + DFM 组件块 9 行 |
| `TDdeServerConv` | `main.pas/.dfm` | 字段 1 + 接口声明 1 + 宏处理器实现 26 行 + `DDETopic` 赋值 1 + `uses` 中 `DdeMan` |

**直接效果**：F3 基线 **42 → 43**，external 类型 **6 类 → 4 类**，A 批 42 → 43、B 批 3 → 2（`RemoveForms` 升入 A 批）。

> **遗留能力（诚实记录）**：DDE 的 `[Open(...)]` 宏实现了「Dev-C++ 已运行时，双击文件交给已有实例打开」。该能力随 DDE 一并移除，**须由 M2 的跨平台单实例服务（命名管道 / `CreateMutex` + IPC）重新承接**。这不是遗漏，是跨平台目标的必然取舍。
>
> `DDE1117906...` 一类十六进制行**未删除** —— 它们是二进制属性流中的巧合字节序列，不是 DDE 组件属性。

**② Lazarus 安装：受阻，原因已实测记录**

| 尝试 | 结果 |
|---|---|
| `sourceforge.net/.../download` | HTTP 200，但返回 `text/html` 引导页 |
| 10 个 `*.dl.sourceforge.net` 镜像 | 同上，均为 HTML |
| `curl.exe` 同一 URL | 同上（首字节 `3C 68` = `<h`） |
| `ftp.freepascal.org` | TLS 握手被代理拒绝 |
| GitHub `FPCSource/releases` | 可达，但无 Windows 安装包 |

SourceForge 对非浏览器客户端强制 HTML 中转，**这是网络策略而非失效链接，重试无用**。交付 `tools/f3_lazarus_setup.ps1`：内置上述实测原因、成功后校验 `lazbuild --version`，并在拿到安装包后拒绝继续（检测 PE magic `MZ`，HTML 页直接报错并给出替代方案）。

> **版本一致性**：CI 固定 `LAZ_VERSION: "4.4"`，本地必须同版本。否则会出现「本地能转、CI 不能」或反之的假信号。

**③ 在无 Lazarus 条件下推进转换**

`tools/f3_dfm_to_lfm.py` 完成 **43 个 A 批窗体的结构转换，零失败**，输出至 `Tests/FpcCoreTests/lfm/`。每个文件带显式头部声明「仅结构转换，未经 LCL 运行时加载验证」。

**该工具自身修正一次**：`DROP_PROPS` 首版误将 `TabOrder`(339)、`ParentFont`(102)、`Default`(9)、`BorderStyle`、`ParentColor` 当作 Delphi-only 删除 —— 它们**都是 LCL 有效属性**，合计占 455 处删除中的 453。修正后仅剩 `ExplicitHeight`(2) 真正删除。

> 教训：**静默删除一个真实属性，比留下一个未知属性更糟** —— LCL 加载器会抱怨它不认识的属性，而被提前删掉的属性则永远不会被检查到。

**④ 当前状态**

| 批次 | 窗体 | 组件 | 状态 |
|---|---|---|---|
| A 机械转换 | **43** | 757 | ✅ 已生成 LFM，**待 lazbuild 验证** |
| B 字段级 | 2 | 95 | 待处理（`TVirtualImage` × 2 窗体） |
| C 需重建 | 8 | 949 | 待处理（集中在 4 个 vendored 库） |

**F3 的最后未知项已收敛为单一问题**：这 43 个 LFM 能否被真实 LCL 反序列化。答案只能在有 Lazarus 的环境（CI 或可下载的机器）获得。
#### C 批 vendored 阻塞类等价性分析（2026-10-04，`tools/f3_vendored_equivalence.py`）

C 批 8 个窗体被 14 个 vendored 类阻塞。工具读取每个类的**自身声明**（基类、行数、位置）后判定，**不按类名猜测**：

| 判定 | 数量 | 含义 |
|---|---|---|
| **REPLACE** | 2 | LCL 已有同类件，删掉 vendored 单元换 LCL 即可 |
| **ADAPT** | 8 | 基类是 LCL 核心类，子类可原样对 LCL 重编译，无需适配层 |
| **PORT** | **4** | 基类无 LCL 对应，**需先写适配层** —— 唯一形态的真工作 |

**REPLACE（2）**：`TSynCppSyn`(211 行)、`TSynRCSyn`(62 行) —— 基类 `TSynCustomHighlighter`，而 **LCL SynEdit 自带 `TSynCPPSyn` / `TSynRCSyn`**，覆盖同样语言。**直接换用 LCL 版本即可，211 行代码可弃用。**

**ADAPT（8）**：`TCompOptionsList`(9 行, base `TValueListEditor`)、`TCompOptionsFrame`(9 行, base `TFrame`)、`TCppPreprocessor`(62 行)、`TCppTokenizer`(53 行)、`TCodeCompletion`(55 行)、`TCppParser`、`TClassBrowser`(62 行, base `TCustomTreeView`)、`TdevShortcuts` —— 基类全部是 LCL 核心类。

**PORT（4）—— 全部集中在矢量图标系统**：

| 类 | 行数 | 基类 |
|---|---|---|
| `TSVGIconImageList` | 43 | `TCustomImageList` |
| `TSVGIconImageCollection` | 64 | `TCustomImageCollection` |
| `TSVGIconVirtualImageList` | 36 | `TSVGIconImageListBase` |
| `TdevFileMonitor` | 20 | `TWinControl` |

> **`TSVGIconImageList` 的 base 判定需修正**：它的 base `TCustomImageList` **是** LCL 核心类，工具首版因此误判「无 LCL 对应」。真正无对应的是它的**两个派生类**（`TCustomImageCollection`、`TSVGIconImageListBase`）。
>
> **结论**：SVG 图标系统是 C 批唯一的真工作项，且它同时是 **F4「矢量图标」阶段的核心目标**。因此 C 批不应单独排期 —— 它与 F4 是同一件事的两面：**F4 要做 LCL 原生 SVG 支持，C 批就依赖它**。

**这重新定义了 F3/F4 的关系**（原方案视为两个独立阶段）：

> C 批 8 个窗体中，4 个因 SVG 图标阻塞。若 F4 先完成 SVG 支持，这 4 个窗体随即降为 ADAPT；反之 C 批必然等待。**建议将 SVG 图标能力提前，作为 F3-C 的前置。**
>
> 另 4 个 C 批窗体（`EditorOptFrm` 的 `TSynCppSyn`、`ProjectOptionsFrm` / `CompOptionsFrm` / `CompOptionsFrame` 的 `TCompOptionsList`+`TCompOptionsFrame`、`DataFrm` 的 Syn 高亮器）**不含 SVG 依赖，可先行处理** —— 其中 Syn 高亮器还是 REPLACE 级（改用 LCL 自带版本）。

**合计阻塞代码 862 行**，其中 530 行（`TSynCppSyn` 211 + `TSynRCSyn` 62 + ClassBrowsing 系列）属可直接弃用或机械适配。
#### 关键修正：43 个「可转换」中，9 个转换后仍不可用（2026-10-04）

在推进 B 批时发现的事实，它修正了此前所有结论中的一个**实质性错误**：

**一个 DFM 可以「转换器读得懂」，却在运行时空白。** 形如 `Images = dmMain.SVGImageListMenuStyle` 的属性行转换后完全合法，但 `dmMain.SVGImageListMenuStyle` 的类型是 `TSVGIconImageList` —— 正是 C 批的 PORT 阻塞项。转换产物能编译，窗口能打开，**图标全是空的**。

**实测影响面**：15 个窗体从 SVG 图像列表取图，其中 **9 个落在 A 批**（此前被计为「已完成」）。

| 口径 | 数量 | 含义 |
|---|---|---|
| 结构可转换 | 43 | 转换器能读（**不能据此认为可用**） |
| **可转换且 SVG 无关** | **34** | 转换后即可用 —— 这才是真正的 A 批 |

**工具已同步修正**（三处口径不一致，均已对齐并交叉验证 34/34/34）：

- `f3_form_survey.py` 新增独立的 **RUNTIME VALIDITY** 维度，不并入「可转换」总数——并进去这 9 个就被藏起来了
- `f3_batch_plan.py` 拆出 **`A-svg` 批次**（9 个），标签明写「转换后空白，排在 SVG 工作之后做：**转换后空白的窗体比不转换更糟**」
- `f3_dfm_to_lfm.py` 改用 `survey.survey()` 单一事实源。首版自行推导 `custom` 漏了 root 类排除，且把 C 批误归 A，多产出 4 个 LFM

**SVG 依赖优先级高于批次分类**：`LangFrm` / `EnviroFrm` 按字母测试属 B 批（唯一阻塞是 `TVirtualImage`，有 LCL 等价物），但该控件的图源是 `dmMain.SVGImageListMenuStyle` —— 因此它们同样归入 SVG 依赖，**B 批归零**。

**最终批次划分**

| 批次 | 窗体 | 组件 | 说明 |
|---|---|---|---|
| **A** | **34** | 567 | 无阻塞控件 + 无 SVG 依赖。转换即可用，已生成 LFM |
| **A-svg** | **9** | 190 | 转换后空白，**须排在 SVG 工作之后** |
| B | 0 | — | 原 2 个窗体经核实均依赖 SVG，已并入 A-svg |
| C | 10 | — | 需 vendored/own 类重建 |

> **B 批归零是一次有价值的负面结果**：它说明「字段级替换即可」的乐观估计不成立 —— 那两个窗体表面上只需换 `TVirtualImage`，实际图源在 SVG 链路上。**若按原计划先做 B 批，会得到两个看起来转好了、实际预览区空白的窗体。**### F4：现代视觉补偿（3–4 周）
- 矢量图标：LCL 原生 SVG 或 BGRAControls 替代 `SVGIconImageList`，工具栏 200%/4K 清晰。
- 深色主题：全局调色板映射 + 主控 OwnerDraw，落地 One Dark / VS Code Dark+ 预设，编辑器与外壳一体化（无 3D 边框、无白边）。
- 标题栏：Windows 10/11 调 `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` 保持沉浸式深色标题栏。

## 4. 风险熔断机制（Kill Switches）

| 节点 | 熔断触发条件 | 熔断后动作 |
|---|---|---|
| F0 评估点（第 2 周） | `Core/*`、`GdbMiParser` 在 FPC 下出现无法绕过的方言死锁（泛型接口约束、RTTI 致命缺陷） | 中止 FPC 计划，退回 Delphi 路线（专攻社区版打包） |
| F2 评估点（第 8 周） | LCL SynEdit 无法承载 LSP 装饰（补全闪烁、波浪线不可用） | 转为异构前端变体：仅把编辑器换成 WebView2 内嵌 Monaco，其余 UI 留在 LCL |
| F3 评估点（第 14 周） | 主窗体重构导致核心功能倒退，回归缺陷 > 30 | 放弃全量窗体现代化，退回"新主窗体壳 + 旧核心宿主"的保守策略 |

## 5. F0 已交付清单（本次实现）

| 文件 | 作用 |
|---|---|
| `Source/LSP/Process/Lsp.Process.pas` | `ILspProcess` / `ILspProcessFactory` 接口与契约（阻塞读、Terminate 解除阻塞）；F1-b 新增 |
| `Source/LSP/Process/Lsp.Process.Fpc.pas` | FPC 实现（RTL `TProcess`），整单元 `{$IFDEF FPC}` 包裹；F1-b 新增 |
| `Source/LSP/Process/Lsp.Process.Factory.pas` | 编译器选择器（FPC→Fpc 实现，Delphi→Win32 实现）；F1-b 新增 |
| `Source/LSP/Process/Lsp.Process.Win32.pas` | Delphi/Win32 实现（原 Transport 代码逐行搬迁）；F1-b 新增 |
| `tools/qa_check.py` | `--profile delphi/fpc/both` + FPC 目录豁免 + **条件编译行级感知**（`{$IFDEF FPC}` 分支内放行 FPC 写法，注释/字符串不参与匹配）；默认行为不变 |
| `Tests/FpcCoreTests/FpcCoreTests.lpr` | FPC 专用冒烟测试运行器：portable 变体 **42 项**检查（F1-a 后），Windows 变体最多 **44 项**（另含 4 项工具链检查与 2 项匿名方法 opt-in 检查）；任一失败即以非 0 退出码失败 |
| `Tests/FpcCoreTests/FpcCorePortable.lpi` | 跨平台核心工程（Events / Services / MiTypes / MiParser） |
| `Tests/FpcCoreTests/FpcCoreWin.lpi` | Windows 变体（+ ToolchainConfig，定义 `TEST_TOOLCHAIN`、`FPC_ANON_HOOK`） |
| `tools/qa_check.py` | 新增 `--profile delphi/fpc/both` 与 FPC 目录豁免；默认行为不变 |
| `tools/fpc_artifact_check.py` | 无需 Lazarus 的 F0 产物结构自检（已接入 CI） |
| `.github/workflows/fpc_ci.yml` | 3 个作业：`fpc-core`(ubuntu+windows)、`fpc-toolchain`(windows)、`qa-gate-profiles` |
| `.gitignore` | 忽略 `**/lib/`、`*.o` / `*.ppu` / `*.lps` / `*.rst` 等 Lazarus/FPC 产物 |

本地可复现的自检（无需 Lazarus）：

```powershell
python tools\qa_check.py              # Delphi 门禁（必须绿）
python tools\qa_check.py --profile fpc
python tools\fpc_artifact_check.py    # F0 产物结构自检
```

首次推送后，CI 首跑即是 F0 的"证伪"环节：Linux/Windows 两个 `fpc-core` 作业 + 一个 `fpc-toolchain` 作业同时验证方言兼容性与行为一致性。

## 6. 对原方案的实测校对（勘误）

| # | 原方案表述 | 实测结论 | 处理 |
|---|---|---|---|
| 1 | F0 纳入 `Source/LSP/Transport/Lsp.JsonRpc.pas` | 该文件**不存在**：`Source/LSP/JsonRpc/` 是空目录，JSON-RPC 帧逻辑在 `Lsp.Transport.pas` 内，而后者 uses `Vcl.Forms` | F0 先不纳入 Transport；拆分为独立 JsonRpc 单元列入 **F1** |
| 2 | `MainForm.*` 全局 419 处 | 实测（排除 vendored）**444 处** | 基准数字修正为 444，F1"下降 ≥60%"按此计算 |
| 3 | 单元名 `GdbMiTypes` / `GdbMiParser` | 实际单元名为 `GDB.MiTypes` / `GDB.MiParser`（文件名保持 GdbMiTypes.pas / GdbMiParser.pas） | .lpi 依赖 lazbuild 的单元索引解析，文件名与单元名不一致无碍；已在工程中配置 |
| 4 | F0"在 Ubuntu 和 Windows 上编译同一组单元" | `ToolchainConfig.pas` 的实现使用 `CreatePipe/CreateProcess/WaitForSingleObject`，**Windows 专属**，无法在 Linux 目标编译 | 拆为 Portable / Win 两个工程，Windows 专属单元只在 Windows 作业中编译 |
| 5 | 以 `TProcess` 作为 F1 的 FPC 平移手段 | 与仓库 Delphi 门禁（`qa_check.py` 禁 `TProcess`）直接冲突 | 门禁双模化：FPC 子工程目录豁免 + `--profile fpc` 放行，Delphi 侧保持零 FPC 痕迹 |

## 7. F0 首次 CI 需重点观察的三个方言风险点

1. **泛型接口约束**：`Core.Services.pas` 的 `class function TryGetService<T: IInterface>`。FPC 对接口约束支持有限，若报错，F1 修复预案为 `{$IFDEF FPC}` 增加无约束重载（内部仍用 `Supports` + `TypeInfo` 判定）。
2. **点号单元名**：`Core.Events/Services`、`GdbMiParser` 使用 `System.Classes`、`System.SyncObjs`、`System.TypInfo` 等 Delphi 命名空间单元。FPC 3.2 起提供命名空间兼容；若个别单元解析失败，修复预案为在 .lpi 增加别名搜索路径或一次性去前缀。
3. **匿名方法**：`Core.Events` 的 `OnCompilerProgress` 是 `reference to procedure`（Delphi 匿名方法）。单元本身只做类型声明，不影响编译；其运行期行为验证放在 `FPC_ANON_HOOK` 开关内由 Windows 变体 opt-in，若 FPC delphi 模式不支持则关闭该开关，并在 F1 改为显式类级订阅。

## 8. 附录：与 F0 相关的既有资产实测

- 自研 .pas 112 个 / 62,123 行 / .dfm 53 个（排除 `Source/VCL`）；vendored VCL 365 个 .pas。
- 零 VCL 可直迁模块：`Core/Events.pas`(431 行)、`Core/Services.pas`(197)、`GdbMiParser.pas`(190)、`GdbMiTypes.pas`(67)、`ToolchainConfig.pas`(460，实现为 Windows 专属)。
- 深绑 VCL 不可直迁模块：`LSP/Client/*`（约 5,300 行，签名均以 `TCustomSynEdit` 为核心）、`Theme/Theme.pas`、`UI/Theme/Theme.Manager.pas`。
- 治理现状：`tools/qa_check.py` 默认 profile 仍禁止 FPC/LCL 痕迹；`.github/workflows/phase0_baseline.yml` 的 Delphi 构建为"有则跑"，无法无头自动构建主程序——这正是 F0 之后要逐步消除的锁定点。

---

## 9. F2-c：首次真实构建的证伪结果（2026-10-05）

> 本节记录的是**接上 FPC 3.2.2 之后**发生的事。此前 F0 的"已交付"只经过结构校验；
> 本节是第一次**真正把编译器跑起来**，结论与 §7 的三个风险点预测对照。

### 9.1 起点：4 项失败，且其中一项是真缺陷

首次完整编译（FPC 3.2.2，`tools/build_fpc_core.ps1`）通过，但冒烟测试 **46 项中 4 项失败**。逐项定位后，**只有 1 项是产品缺陷**：

| # | 失败检查 | 性质 | 根因 |
|---|---|---|---|
| 1 | `partial frame is not emitted` | **测试缺陷** | `out ABody: string` 由**编译器**在进入被调方前清空，`'untouched'` 哨兵对**任何实现**都不可满足 |
| 2 | `a lone malformed header yields nothing` | **测试缺陷** | 同上（同一个 `out` 误解） |
| 3 | `child stdout is readable` | **产品缺陷** | `Parameters.Add(AParams)` 把整串当作**一个** argv 元素传入 |
| 4 | `unsubscribed handler stops…` | **测试缺陷** | 通用订阅表**不按类型过滤**，绝对计数 `(1,2)` 是错的算术 |

**#1/#2 的教训**：`out` 对**托管类型**（string）的语义是编译器行为，不是被调方可以拒绝的。所以这条断言测的是**语言**，不是解码器——它永远不可能通过。

**#3 才是最严重的一条，因为它影响真实产品**：`Lsp.Transport.Connect` 给 clangd 传的是**七个** flag：

```
'--background-index --clang-tidy --completion-style=detailed ' +
'--header-insertion=iwyu --pch-storage=memory ' +
'--compile-commands-dir="' + FWorkDir + '" --log-level=error'
```

`Parameters.Add(AParams)` 会让这**七个 flag 变成一个** argv 元素。冒烟测试以
`n=72 text=usage: …FpcCoreTests.exe [run]` 暴露它——子进程看不懂参数，直接打印了用法横幅。
**若不修，FPC 版 clangd 根本起不来。** 修复用 RTL 自带的 `CommandToList`
（`fcl-process/src/processbody.inc:171`，`process` 单元公开，RTL 自己也在用）。

> **验证没有停在"测试变绿"**：冒烟测试只传了两个不含空格的 token，因此额外用**真实
> clangd 字符串**跑了一遍 `CommandToList`，实测得到 **7 个独立参数**，顺序正确，
> 且含空格的引号路径 `--compile-commands-dir="C:\work dir"` 仍是**一个** token。
> **一个 2-token 的绿灯，不足以证明 7-flag 的产品是对的。**

### 9.2 我自己制造并修复的一次事故（必须留档）

修 #3 时我一度把 `PChar(CmdLine)` **无条件**改成 `PAnsiChar(CmdLine)`。这修好了 FPC，
却会**打断 Delphi 构建**：`Lsp.Process.Win32.pas:124` 用的是同一个
`PChar(CmdLine)` 调同一个 Win32 API 且**今天能编译**——Delphi 的 `Winapi.Windows.CreateProcess`
取**宽字符**入口，`PChar` 正是正确实参；只有 FPC 把这个名字绑到 **ANSI** 入口
（`rtl/win/ascdef.inc:359` → `LPCSTR/LPSTR`）。

> **根因**：转换的**宽度是编译器的属性**，不是 API 的属性。我把"某个编译器下正确"当成了
> "普遍正确"。**判据不是"能不能编过"，而是"另一棵树原本是什么写法"**——
> `Lsp.Process.Win32.pas:124` 这个**既有**调用点就是现成的反证。
> 现改为 `{$IFDEF FPC}` 分支，`{$ELSE}` 分支保持 `PChar` 原样。

### 9.3 一个从未被编译过的变体：`-Win`

此前只跑过 **portable** 变体。`-Win` 变体（定义 `TEST_TOOLCHAIN`，额外含 `ToolchainConfig`）
**在本机首次编译**，一次性暴露 4 处全新缺陷，**没有一处与 #3 相关**：

| 缺陷 | 编译器原话 |
|---|---|
| 一个 program 只能有**一个** `uses` 子句（`{$IFDEF TEST_TOOLCHAIN}` 另起了一个） | `Fatal: Syntax error, "BEGIN" expected but "USES" found` |
| `Winapi.Windows` 在 FPC 不存在（无 `Winapi` 目录，且带点单元名不被接受） | `Fatal: Can't find unit Winapi.Windows` |
| `SplitString` 需要显式 `StrUtils`；`TStringDynArray` 在 **`Types`** 而非 `StrUtils` | `Error: Identifier not found "SplitString"` |
| `-Mdelphiunicode` 下 `PChar`=`PWideChar`，与 FPC 的 ANSI `CreateProcess` 不匹配 | `Incompatible type for arg no. 2: Got "PWideChar"` |
| `SplitString` 返回 `TStringDynArray`，与局部变量声明的 `TArray<string>` **是两个类型** | `Incompatible types: got "TStringDynArray"` |

> **这 4 处此前"全部通过"是因为它们从未被编译过。** 门禁、结构自检、双 profile QA 全绿
> ——**因为它们检查的是"文件存在且没有 VCL 依赖"，而不是"能编译"**。
> 这与本项目已记录两次的问题同族：**断言覆盖不到未走的路径**。
> **一个只有开关打开时才编译的分支，等于没有门禁。**

`Windows` 单元里的 `GetEnvironmentVariable(PChar;PChar;LongWord)` 与
`SysUtils.GetEnvironmentVariable(const Name: string): string` **同名**，前者按
"最后一个单元优先"胜出，导致 4 处调用全部失配。用 `SysUtils.` 限定即可**一行同时服务两棵树**，
不必为 4 个调用点各复制一份 `{$IFDEF}`（复制就会漂移）。

### 9.4 一条被实测纠正的诊断

失败信息里的 `pending=14` 一度让我判断"解码器没丢弃畸形头"。**实测推翻了它**：用一个
带副作用的探针测出 FPC 的**实参求值顺序**——

```
order-probe cond=TRUE detail=value=0
```

即 `ADetail` 在**条件参数之前**求值，所以那个 `14` 是 **调用前**的状态；先 pop 再读
`PendingBytes` 得到 **0**，解码器行为本来就是对的。

> **教训**：诊断字符串里的数字不一定是"事情发生之后"的状态。把它当作事实写进注释，
> 等于把一条**猜测**固化成**文档**。本项目日志里已记过两次"测量结果被重新推导"，
> 这是第三次，形态不同：**被污染的是诊断信息，不是被诊断的代码**。

### 9.5 当前状态

| 项 | 状态 |
|---|---|
| portable 变体 | ✅ 编译通过，**46/46** 检查全绿（此前 42/46） |
| Windows 变体（`-Win`） | ✅ **首次编译通过**，**51/51** 检查全绿 |
| 双 profile QA gate | ✅ OK |
| `fpc_artifact_check` | ✅ OK |
| `lcl_svg_struct_check --self-test` | ✅ OK |
| Delphi 构建 | ⚠️ **本机无 Delphi，未编译验证**；改动均以 `{$IFDEF}` 隔离，`{$ELSE}` 分支保持原写法 |

> **`§7` 三个风险点的实测结论**：① 泛型接口约束——`TryGetService<T>` 调用点确实编不过
> （FPC 编译器崩溃 `Internal error 2010122901`），已按预案改走 `QueryService`；
> ② 点号单元名——**风险成立**，需逐单元改写（`tools/fpc_uses_rewrite.py`）；
> ③ 匿名方法——**风险成立且更严重**：`reference to` 在**所有**模式（`-Mdelphi` /
> `-Mdelphiunicode` / `-Mfpc` / `-Mobjfpc`，含 `{$modeswitch anonymousfunctions}`）
> 一律报 `Error: Identifier not found "reference"`，已按预案降级为 `of object`。

---

## 10. F3 当前状态：13 个窗体已被真实加载验证（2026-10-06）

| 项 | 状态 |
|---|---|
| 转换产物可加载性 | ✅ **`FormLfmProbe` 13/13 全绿**（真实 LCL 读取器，非结构对比） |
| 属性层可赋值性 | ✅ **`PropRttiProbe` 0 条被拒**（14 文件 / 3457 条属性赋值逐条过读取器） |
| Delphi 构建 | ⚠️ **本机无 Delphi，未编译验证**；改动以 `{$IFDEF}` 隔离，`.dfm` 的 `TCompOptionsList` → `TValueListEditor` 是 VCL 与 LCL **都成立**的写法（`valedit.pas:17` 两侧同名） |
| 剩余阻断 | `EditorOptFrm`（`TSynCppSyn`）、`main.dfm`（8 类，按 §13.3 排除出近期排期）、`Tools/Packman/Main`（无 LCL 对应控件，转换器**明确拒绝**） |

本轮（F3-4/F3-5）落地的四件事：

1. **`TCompOptionsList` 退役、`TCompOptionsFrame` 移植**（§15 的方案，`Source/CompOptionsFrame.pas` 的 `vle` 改为 `TValueListEditor`，两个窗体随之解锁）；
2. **转换器三处修复**：根 `end` 位置（平铺输出会让读取器丢弃全部子控件）、属性值整体读取（否则十六进制块错位）、**任何读不懂的行都必须报错**（此前是静默跳过）；
3. **两个新探针 + 共享单元**（`Tests/FpcCoreTests/forms/`），其中一个的**提问器带自测**，因为“只会说不”的提问器和正确结果长得一样；
4. **`Source/Fpc/UI/Compat/VclPropertySkips.pas`**：17 条实测被拒的属性用 LCL 自己的 `RegisterPropertyToSkip` 按类登记，而不是在转换器里删掉——详见 SVG 方案 §16.3，其中 `OnInfoTip`（功能缺失）与 `TSynGutter.Font`（视觉差异）是两条**明确记录而非默认吞掉**的损失。

> **下一步的最便宜证据已经做完**：§13.2 说“把这 9 个窗体加载出来”，本节给出 13 个中的 13 个。剩余的排期不再是“能不能加载”，而是“处理器的 Pascal 侧是否可编译”——那是 F2/F3 的 SynEdit 与 frame 移植工作量，不再是转换问题。
