# Dev-Cpp-Modern 更换现代 UI（不依赖 Delphi）合理性评估报告

> 生成日期：2026-09-26（UTC+8）
> 评估对象：分支 `phase4-lsp-modernize`（HEAD `a5922ec`，Phase 0–4 基线已完成）
> 关联文档：《项目实现与架构分析报告》《现代化实施方案》

---

## 1. 结论摘要（TL;DR）

| 命题 | 判定 | 置信度 |
|---|---|---|
| 以 **Lazarus/FPC + LCL** 替换 Delphi/VCL，保留 Object Pascal 代码资产 | **有条件合理**（成本最低的非 Delphi 路径，但受 VCL 生态绑定拖累） | 中高 |
| 以 **Qt6/C++、Avalonia、Tauri 等异构栈重写 UI**，Delphi 核心退居后端 | **当前不合理**（业务层尚未与 UI 解耦，"无头核心"抽取成本 ≈ 重写成本） | 高 |
| 彻底 **绿地重写**（新栈同时重写全部逻辑） | 与"维护 Dev-C++"的目标错位，等价于放弃 62k 行自研资产做新产品 | 中 |
| 维持 **Delphi + VCL Styles 现代主题** 现路线 | 短期最优，但 Embarcadero 许可/CI 授权依赖无法消除 | 高 |

**一句话结论**：在"去 Delphi 化"的所有方案中，唯一现阶段有合理性价比的是 **FPC/Lazarus 移植**；"换现代 UI 框架 + 保留 Delphi 逻辑"看似折中，实则因 `ServicesImpl → Compiler/EditorList/Project` 等仍绑定 VCL 具体类而**不成立**，需先完成 Phase 2 未竟的解耦才可讨论。

---

## 2. 现状事实基线（全部为实测值）

### 2.1 代码规模

| 维度 | 实测值 | 说明 |
|---|---|---|
| 自研 .pas 文件 | **112 个**（不含 `Source/VCL`） | 排除 vendored |
| 自研 .pas 总行数 | **约 62,123 行** | 含 Phase 4 新增约 8k 行 |
| 自研 .dfm 窗体 | **53 个** | 全部为 VCL 流式窗体 |
| Vendored VCL 生态 | **365 个 .pas**（`Source/VCL`） | SynEdit、ClassBrowsing、SVGIconImageList、vcl-styles-utils、Abbrevia、DDetours |
| 上帝窗体 | main.pas **7,814 行** / main.dfm 6,702 行 | Phase 2 目标"<3,000 行"**未达成**，反而增长 |
| 编辑器 | Editor.pas 3,080 行，直接持有 SynEdit | LSP 全部渲染挂在 TCustomSynEdit 上 |
| 国际化 | Lang/ 61 文件、40+ 语言，自研 MultiLangSupport | 换框架需整套重建 |

### 2.2 Phase 0–4 已落地的"可迁移资产"分层

按对 VCL 的实际依赖度（逐文件核查 uses 子句）：

| 模块 | VCL 依赖 | 可迁移性 |
|---|---|---|
| `Core/Events.pas`、`Core/Services.pas`（事件总线+服务定位器） | **零 VCL**（仅 SysUtils/Classes/SyncObjs/TypInfo） | ★★★★★ 近乎原样保留（FPC 兼容度高；泛型 `class var`/RTTI 需微调） |
| `Debugger/GDB/GdbMiParser.pas` 等 GDB-MI 套件（约 860 行） | **零 VCL** | ★★★★★ 纯协议逻辑，可直迁 |
| `Toolchain/ToolchainConfig.pas`（460 行，JSON Profile） | 仅 `Winapi.Windows` | ★★★★★ 直迁 |
| `LSP/Transport`、JsonRpc、DocumentSync（约 1,200 行） | `Winapi.Windows + Vcl.Forms`（仅 Synchronize 级别引用） | ★★★★ 小改 |
| `LSP/Client/*`（Completion/Hover/SignatureHelp/Definition/Diagnostics，约 5,300 行） | **深绑 SynEdit**（构造器/事件签名均为 TCustomSynEdit）；Hover/SignatureHelp 用 VCL HintWindow | ★★ 换 UI 框架即须重写渲染层，仅协议逻辑与 LSP 语义知识可复用 |
| `Theme/Theme.pas`、`UI/Theme/Theme.Manager.pas` | **全量 Vcl.Themes / Vcl.Styles / Vcl.Styles.Hooks** | ★ VCL Styles 独有价值，LCL 无对应物，整层作废 |
| `UI/Frames/*`（3 个 Frame，纯代码建控件无 DFM） | VCL TFrame/StdCtrls/ComCtrls | ★★ 结构可参考，控件映射需重写 |
| `Core/ServicesImpl.pas`（416 行） | uses `Compiler, Debugger, EditorList, Project, editor` —— **全部是 VCL 时代的具体业务类** | ★ 证明"逻辑层"实际仍未离开 VCL 世界 |

### 2.3 尚未偿还的耦合债（决定去 Delphi 成本的关键）

- `MainForm.*` 直接调用密度（不含 vendored）：Tests.pas **147** 处、Editor.pas **69**、Project.pas **28**、Compiler.pas **22**、ProfileAnalysisFrm 22、FindFrm 19……
- 53 个 .dfm + 主菜单/快捷键系统（devShortcuts）+ 停靠布局均为 VCL 流格式，异构 UI 框架下**无一可平移**。
- SynEdit 是最大单点资产：编辑器高亮、代码折叠、LSP 装饰（波浪线/补全弹窗）全部长在其上；换 UI 框架时它和它的替代品（Qt Scintilla、AvaloniaEdit、Monaco/CodeMirror）之间是一次**能力对赌**。

### 2.4 当前基础设施对 Delphi 的"制度性锁定"

- `tools/qa_check.py` 的方言门禁**主动禁止** FPC/LCL 标记（`TProcess`、`poWaitOnExit`、`LCLVersion` 等）——现行 QA 政策在制度上把仓库钉死在 Delphi 方言；改道 FPC 必须**反转**该门禁策略。
- `.github/workflows/phase0_baseline.yml` 构建依赖 RAD Studio（"Execute DUnitX Tests (If Delphi Available)"），CI 上 Delphi 属"有则跑"——即**目前 CI 并不能无头自动构建主程序**，这既是现路线的软肋，也是"去 Delphi"论点的核心论据（Embarcadero 社区版许可不允许企业级 CI 商用构建）。
- **本机实证（2026-09-26）**：开发机上确实装有 Delphi 12 Athens（`Studio\37.0\bin\dcc32.exe`），但 **`dcc32` 与 `MSBuild` 调用均直接返回 "This version of the product does not support command line compiling."`**。即现有许可下 Delphi 主程序**只能在 IDE 里交互式构建**，命令行无头构建被封锁。由此：
  1. "保住 Delphi + 保住 CI"在当前许可下不可行，CI 绿灯只能来自 FPC 侧；
  2. 任何新增逻辑若要获得自动化验证，必须落在**能被 FPC 工程编译的单元**内（见 `Tests/FpcCoreTests/*.lpi` 覆盖的单元集合），否则将永久停留在"只能人工点 IDE 验证"的状态；
  3. 这条实证把方案 A（FPC 渐进移植）的必要性从"成本更低"升级为"唯一可持续的免授权自动化路径"。

---

## 3. 候选方案逐项评估

### 方案 A：Lazarus/FPC + LCL 移植（"同语言去授权"）

**思路**：保留 Object Pascal 全部代码资产，编译器换 FPC 3.2.x（免费、可无头 CI），控件层 VCL→LCL，编辑器换 Lazarus 自带 SynEdit，主题走 LCL 自建方案。

**合理性依据**：
1. Phase 4 新建的 Core/GDB-MI/Toolchain/LSP-Transport 约 3k 行**近零成本直迁**（§2.2 实测零 VCL 依赖）；
2. FPC 能编译绝大多数旧 Delphi 代码，devCFG/Project/Compiler 等逻辑层的语法摩擦远小于跨语言重写；
3. 彻底消除 Embarcadero 许可与 Win32-only 工具链依赖，CI 可全自动 headless 构建——正中现状最大痛点（§2.4）；
4. 社区已有 FPC 版 Dev-C++ 移植先例（FPC DevStudio、grdev_cpp 等），路径被验证过。

**主要代价**：
1. **53 个 DFM → LFM 转换/重铺**：main.dfm（6,702 行）级别的复杂窗体实际须手工重做，约占 UI 工作量 70%；
2. `Theme.Manager`（VCL Styles + Styles.Hooks 钩子）**整层作废**，深色模式须在 LCL 上重做（LCL 无全局样式引擎，只能逐控件 OwnerDraw 或等 Lazarus Themes 框架成熟）——"现代 UI"观感上限反而**低于**现状 VCL Styles；
3. SynEdit：Lazarus 的 SynEdit 与 vendored Delphi SynEdit **API 不同源**（高亮器接口、Paint 定制点差异），Editor.pas 3,080 行 + LSP Client 约 5,300 行渲染层需适配重写；
4. SVGIconImageList / vcl-styles-utils / ClassBrowsing 需换 LCL 生态对应物（SVG 改 Bgrabitmap 等）；FastMM5 直接删除（FPC 自带内存管理）；
5. `qa_check.py` 方言门禁须**反转**（改为禁 `Vcl.` 前缀、`System.AnsiStrings` 等 Delphi-only 写法）；Tests.pas 的 147 处 `MainForm.*` 冒烟测试随窗体重建。

**量级估算**：1–2 名熟练 Pascal 开发者 **6–12 个月**到"功能对齐 Alpha"；现代观感另计。

**判定**：**有条件合理**——前提是把目标定为"去授权化 + 跨平台地基"，而非"更现代的视觉 UI"。若目标是后者，A 方案反而倒退。

### 方案 B：异构 UI 壳（Qt6 / Avalonia / wxWidgets）+ Delphi 逻辑层后端化

**思路**：新 UI 框架只做壳，编译/调试/工程逻辑留在 Delphi 核心，经 IPC（JSON-RPC，复用已写的 JsonRpc 通道经验）驱动。

**表面吸引力**：UI 现代化天花板最高；Phase 4 的 LSP/GDB-MI/Toolchain 协议逻辑"看起来"可原地复用。

**致命障碍（实测）**：
1. 逻辑层并不独立——`ServicesImpl` 直接 uses `Compiler, EditorList, Project, editor`，这些类内部持有 VCL 控件与 MainForm 引用（Editor.pas 69 处 `MainForm.*` 直调）；
2. 要得到"无头核心"，须先把 Editor/Project/Compiler 与控件剥离——这恰是 Phase 2 立项、至今 main.pas 反增至 7,814 行而**未完成**的工作；
3. 编辑器（IDE 的心脏）无论如何都要在新 UI 侧重做，LSP Client 的 5,300 行 SynEdit 渲染代码沉没；
4. 交付物变成"两个进程 + 一门新语言"，对志愿者社区是长期运维负担。

**量级估算**：先补完解耦（≈ Phase 2 全部遗留量）再开发新壳，合计 **12 个月以上**，且中途无法发布功能对齐版本。

**判定**：**当前不合理**。唯一翻盘条件：先以独立里程碑完成 Phase 2 解耦、抽出可单测 headless core（约 15–20k 行去 VCL 化），届时 B 才从"不合理"升级为"可讨论"。

### 方案 C：绿地重写（如 Tauri + Monaco/CodeMirror 前端，Rust/Go 后端）

**思路**：承认 Dev-C++ 的价值在"协议 + 工具链集成 + 工作流"而非代码本身，新栈重写。

**合理性依据**：编辑器难题直接消解（Monaco/CodeMirror 即得现代 LSP 前端，Phase 4 的 clangd 集成语义经验全部平移）；天然现代 UI、深色主题、高 DPI；GDB-MI、LSP、Toolchain JSON 可按 spec 重写，而这些 spec 正是 Phase 3/4 已趟平的坑——复用的是**知识资产**而非代码资产。

**代价**：62k 行自研与 Lang/ 61 文件本地化体系全部重做；53 个对话框逐一重设计；老用户行为回归风险最大化。

**判定**：作为"下一代产品"合理，作为"本仓库的改造方案"**不合理**——那是另一个立项。

### 方案 D：维持 Delphi，VCL Styles 现代化（现行 Phase 4 路线）

**合理性**：Phase 4 已投入的 Theme.Manager / LSP / Frames / manifest DPI 全部即时生效；零迁移成本。
**不可消除的约束**：Delphi 商业授权（CI 与企业使用受限）、Win32 主进程锁死、VCL 无跨平台前景、贡献者池萎缩。
**判定**：作为**过渡基线**合理，作为终局则与"去 Delphi"诉求直接冲突。

---

## 4. 横向对比

| 维度 | A. FPC/Lazarus | B. 异构壳 | C. 绿地重写 | D. VCL 现状 |
|---|---|---|---|---|
| 自研代码资产保留率 | **~70%**（逻辑层） | <30%（且须先偿还解耦债） | ~0%（仅知识/协议复用） | 100% |
| 消除 Delphi 依赖 | ✅ | ❌（核心仍是 Delphi） | ✅ | ❌ |
| 无头 CI 全自动构建 | ✅ | 部分（壳可、核不可） | ✅ | ❌ |
| "现代 UI"观感上限 | 低–中（LCL 主题弱） | 高 | **最高** | 中（VCL Styles 已到顶） |
| Win64 / 跨平台前景 | Win64 ✅，跨平台可达 | 取决于壳 | 取决于栈 | Win64 可行，跨平台无 |
| 到"功能对齐 Alpha"量级 | 6–12 人月 | 12 个月+，被解耦债阻塞 | 18 个月+ | 0 |
| 中途可发布性 | 可（双栈并行分支） | 不可 | 不可 | — |
| 志愿者社区适配度 | **高**（工具链全免费） | 低（多语言多栈） | 中 | 衰减中（授权门槛） |
| Phase 4 资产处置 | Core/GDB-MI/Toolchain 直迁；Theme/LSP 渲染重写 | 协议层可留，UI 层弃 | 全弃，按 spec 重写 | 全留 |
| qa_check/CI 治理改动 | 方言门禁**反转** | 维持 | 重建 | 维持 |

---

## 5. 关键风险与前置条件

1. **解耦债是所有替代方案的共同税单。** Phase 2 遗留（main.pas 7,814 行、Editor/Project 对 `MainForm.*` 的 69/28 处直调、ServicesImpl 反向引用具体 VCL 类）不偿还，任何"保留逻辑、替换 UI"的方案都会退化为重写。建议在决策前先完成两项与 UI 栈无关的止损工作：
   - 将 Services 接口覆盖面扩至 Editor/Project/Compiler，清零非 UI 单元的 `MainForm.*` 直调；
   - 为事件总线/服务定位器补 DUnitX 单测（TestsDUnitX.pas 已有雏形），把"可测试性"变成解耦进度的客观指标。
2. **编辑器能力对赌。** 无论 A/B/C，SynEdit → 替代编辑器（LCL SynEdit / QScintilla / AvaloniaEdit / Monaco）都是最大单点技术风险：现有 60+ 高亮配置、代码折叠、LSP 波浪线/补全弹窗都要在新控件上逐一验证。建议先做 1–2 周编辑器 PoC 再立项全量迁移。
3. **Phase 4 投资的沉没成本要显式入账。** 选 A：Theme.Manager 与 LSP Client 渲染层（约 5.4k 行）作废；选 B/C：再加 LSP Transport/DocumentSync 也大概率重写。报告中 §2.2 的迁移性分级即为此设。
4. **治理与门禁冲突。** `tools/qa_check.py` 现主动封杀 FPC/LCL 方言（`TProcess`/`LCLVersion` 等），且 CI 无法无头构建 Delphi 主程序。若决策"去 Delphi"，需同步改写 QA 门禁规则与 `phase0_baseline.yml`，否则新分支会被自家 CI 拦住——这是低成本但必须做的前置项。
5. **本地化与用户资产迁移。** Lang/ 61 文件、40+ 语言由自研 MultiLangSupport 驱动（其 codepage 逻辑与 Delphi 字符串模型耦合）；devcpp.cfg/ini、.dev 工程格式属对外契约，任何方案下都必须字节级兼容，应纳入迁移验收标准。
6. **许可证检查。** 项目为 GPLv2：方案 B（Delphi 核 + 新壳进程）经 IPC 边界通信可保持壳的许可独立性；方案 A/C 中 FPC RTL/LCL 有运行库例外（exception）、Qt 需选 LGPL 动态链接、Tauri/Avalonia 为 MIT——均无阻断，但需在打包脚本中固化声明。

---

## 6. 结论与建议路线

### 6.1 对"更换现代 UI 而不依赖 Delphi"命题的直接回答

**该命题在当前代码库上有内在张力**："不依赖 Delphi"要求逻辑层脱离 VCL，而实测逻辑层尚未脱离（§2.3、方案 B 论证）；"现代 UI"要求的视觉能力（全局深色、DPI 矢量、动效）恰恰是 LCL 弱项。因此：

- 若诉求排序是 **①摆脱 Embarcadero 授权/CI 锁定 → ②顺带改善观感**：方案 **A（FPC/Lazarus）** 是唯一现阶段合理的去 Delphi 路径，观感目标降级为"整洁可用"而非"现代炫酷"。
- 若诉求排序是 **①现代 UI 体验优先 → ②顺便去 Delphi**：诚实的答案是**现有仓库不适合作为改造对象**，应走方案 C（绿地，复用 Phase 3/4 的 LSP/GDB-MI/Toolchain 协议知识）；方案 B 只在解耦债清偿完毕后才有讨论价值。
- 两种排序下，"换 Qt/Avalonia 壳但保留 Delphi 逻辑"的中间态**不成立**（Delphi 依赖没去掉，解耦成本照付）。

### 6.2 建议执行序列（若选 A，渐进止血式）

| 里程碑 | 内容 | 退出判据 |
|---|---|---|
| M0（2 周） | 决策实验：将 `Core/*、GdbMiParser、ToolchainConfig` 抽为独立 FPC 包，在 CI 上用 fpc 编译 + DUnitX/FPCU 跑测 | FPC 下 100% 通过现有 TestsDUnitX 用例 |
| M1（1 个月） | LSP Transport/JsonRpc/DocumentSync 去 Vcl.Forms 化（Synchronize 抽象为同步接口）；qa_check 方言门禁改双模（Delphi/FPC profile 各一套） | 双栈（dcc32/fpc）CI 同时绿 |
| M2（2–3 个月） | LCL 版编辑器 PoC：Lazarus SynEdit + 本仓库 LSP Transport 打通补全/诊断显示 | 一个 .dev 工程可打开、高亮、clangd 补全、编译 |
| M3（6–12 个月） | 逐窗体 DFM→LFM 迁移（先高频：Editor/Project/Find/选项页），Lang 目录格式沿用；保留 Delphi 分支做回归对照 | 高频功能对齐 v6.3 冒烟清单 |
| M4 | 深色主题（LCL OwnerDraw/Bgrabitmap 方案）、NSIS+WinGet 迁移、发布 Dev-Cpp 7.0-FPC | Win64 安装包 + 便携版可下载 |

每个里程碑均可发布、可回退（双栈并行），避免"大爆炸切换"。

### 6.3 最终判定

> **更换现代 UI 而不依赖 Delphi：作为方向合理，作为一次性改造不合理。** 合理性的唯一现实载体是 FPC/Lazarus 渐进移植（方案 A），且必须先以 M0/M1 两个低成本里程碑证伪/证实 FPC 兼容性与解耦可行性；在此之前，任何全量切换决议都缺乏当前实现状态的支持。异构现代 UI（Qt/Tauri/Avalonia）与本仓库的正确关系是"下一代产品参考"，而非"本代码库的改造路径"。

---

## 7. 实现进展复核（2026-09-27，结论不变且更强）

报告出具后，方案 A 的 **F0、F1-a、F1-b** 已全部实际落地。仓库现状如下：

| 维度 | 报告出具时 | 现在的实现情况 |
|---|---|---|
| 免授权 CI 通道 | 不存在 | `.github/workflows/fpc_ci.yml` 已就位（3 作业：ubuntu/windows portable、windows toolchain、双 profile 门禁 + 产物自检） |
| QA 门禁 | 单模，禁 FPC 痕迹 | `qa_check.py --profile delphi\|fpc\|both` 双模，**默认行为零变化**；并升级为**条件编译行级感知**：`{$IFDEF FPC}` 分支内放行 FPC 写法、分支外仍禁止，注释/字符串不参与匹配；8 例注入矩阵回归全过（裸 `TProcess` 必报 / 守卫内放行 / 守卫内 `Write-Host` 仍报 / `{$ENDIF}` 之后必报 / `{$IFNDEF FPC}` 必报…） |
| 可免授权验证的单元 | 4 个（Events/Services/MiTypes/MiParser） | **9 个**——新增 `LSP/JsonRpc`（帧层，15 项检查）、`LSP/Process` 三件套（接口/FPC 实现/编译器选择器）、以及 `LSP/Transport` 本身 |
| 免授权测试规模 | 26 项 | **portable 48 项 / Windows 变体最多 50 项**（含真实子进程管道往返：测试二进制以 `--child-echo` 模式自启动，零外部工具依赖） |
| LSP Transport 的 VCL 耦合 | `uses Vcl.Forms`（判定为"仅 Synchronize 级别引用"） | **实测为空导入并已移除**；跨线程派发本就用 RTL `TThread.Queue` |
| LSP Transport 的 Win32 耦合 | 直接持有 `CreateProcess` + 4 个管道句柄（632 行） | **已抽象为 `ILspProcess`**：632→**530 行**，`Winapi/CreateProcess/CreatePipe/ReadFile/WriteFile/CloseHandle/TerminateProcess/GetLastError` 引用**全部归零**；Delphi 走原样搬迁的 Win32 实现，FPC 走 RTL `TProcess`，**同一代码路径在 Windows/Linux CI 双跑** |
| 验证能力 | 仅结构校验 | `tools/fpc_artifact_check.py` 19 项断言（含"Win32-only 单元不得进入 FPC 工程"的强制检查），无需 Lazarus 即可跑 |
| Delphi 侧可否命令行构建 | 推测"受许可限制" | **已实证**：`dcc32` 与 `MSBuild` 均返回 "does not support command line compiling"（§2.4） |

对结论的影响：

1. **方案 A 由"性价比最优"升级为"唯一具备可持续免授权自动化验证的路径"**——Delphi 侧的 CLI 构建封锁已从推测变为事实；同时本轮证明了这条路径**确实能持续产出被验证的新代码**（9 个单元 / 48 项检查）。
2. **方案 B（异构壳 + Delphi 后端）的否定结论进一步强化**：其前提"保留 Delphi 逻辑"意味着保留"只能人工点 IDE 验证"的状态；而 F1-b 恰好展示了反面代价——为让 Transport 可验证，必须额外维护 Win32/FPC 两份实现与一个门禁行级感知层。
3. **可迁移性分级的实测修正**：`LSP/Transport` 从"★★ 深绑 VCL"上调为"**已可直迁**"（帧层 + 进程层均已抽出纯 Pascal 抽象）；而 `LSP/Client/*`（约 5,300 行，签名以 `TCustomSynEdit` 为核心）评级**不变**——这印证了原报告的方法论：**按 UI 依赖度分级，再决定投入顺序**，而不是按"看起来像底层"的直觉排序。
4. **未变的部分仍是原报告的核心判断**：编辑器（SynEdit → 替代品）是最大单点风险；`MainForm.*` 直调已从 447 降至 **425**（30 个文件；`Compiler.pas` 已 22→0，并新增唯一豁免的 UI 反腐层 `Source/UI/MainUi.pas`），但 53 个 DFM 与 `main.pas`（7,814 行）的解耦债仍是 F1/F3 的主要成本。
5. **新增的一条工程约束（本轮付出代价换来的）**：凡是无头 CI 编译不到的 Delphi 改动，其正确性只能靠人工 IDE 验证。因此**改造面被强制收敛为"能被 FPC 工程编译的单元优先"**，这与原报告 §5 的"解耦债是所有替代方案的共同税单"判断一致，只是把代价显性化了。
6. **解耦债已被改造成可执行指标（不再靠"记得做"）**：新增 `tools/mainform_baseline.json` 棘轮基线 + `qa_check.py::check_mainform_decoupling`（上限只许下降、注释/字符串不计数、facade 单点豁免），CI 每次推送都会打印 `MainForm coupling: 425 refs (cap 425) ...` 形式的进度行；配套 `tools/mainform_baseline.py --check` 可本地报告漂移。这一机制的副作用是**门禁在开发过程中真的抓出了错误**（漏配 `DCC_UnitSearchPath`、子串误替换、次数误记），说明它不是装饰。

---

## 附录 A：本报告实测数据来源
|---|---|
| 自研 112 pas / 62,123 行 / 53 dfm | `Get-ChildItem Source -Recurse` 排除 `\VCL\` 后统计 |
| vendored 365 pas | `Source\VCL` 递归计数 |
| main.pas 7,814 行 / Editor.pas 3,080 行 | `Get-Content | Measure` |
| `MainForm.*` 调用密度 | `Select-String '\bMainForm\.'` 按文件分组计数 |
| 各新模块 VCL 依赖 | 逐文件 uses 子句核查（Core/LSP/Debugger/Toolchain/Theme/UI） |
| FPC 方言禁令 | `tools/qa_check.py` `_FORBIDDEN` 列表 L158–165 |
| CI Delphi 依赖 | `.github/workflows/phase0_baseline.yml`（"If Delphi Available" 步骤） |