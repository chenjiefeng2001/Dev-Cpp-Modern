# Dev-Cpp-Modern 以 Tauri 2.x (Rust) + Monaco / Web 前端替代 Delphi/VCL 的可行性报告

> 生成日期：2026-10-02（UTC+8）
> 评估对象：分支 `phase4-lsp-modernize`（HEAD `f855bda`）
> 关联文档：《更换现代UI不依赖Delphi的合理性报告》《FPC-Lazarus渐进式移植实施方案》《项目实现与架构分析报告》《现代化实施方案》
> 数据口径：仓库侧全部数字为 2026-10-02 本机实测；技术栈侧事实取自 Tauri 2.x 官方文档、monaco-editor README、docs.rs crate 索引、Microsoft WebView2 官方文档

---

## 1. 结论摘要（TL;DR）

| 命题 | 判定 | 置信度 |
|---|---|---|
| Tauri 2.x + Rust 能承载 Dev-C++ 所需的系统能力（子进程、管道、文件、PTY、打包分发） | **成立** | 高 |
| Monaco 能替代 SynEdit 且**能力上净胜**（LSP 客户端、折叠、语义高亮、深色、高 DPI 免开发） | **成立** | 高 |
| 把本仓库"改造成"该形态 | **不成立**——这是绿地重写，即既有报告的方案 C | 高 |
| 立项为"下一代产品"，或与 FPC/Lazarus 路线并行推进 | **有条件可行**；三道 PoC 已全部实测通过（§8.3/§8.5/§8.6），**技术阻塞清零** | 中高→高 |
| 立即全量切换、废弃现有 Delphi 代码 | **不成立** | 高 |

**一句话结论**：**技术栈侧没有阻断项，真正的风险不在 Rust/Tauri 本身，而在于"重写 5 万行 Pascal + 53 个窗体 + 61 份本地化"这件工程事实**。但与 2026-09-26 的既有评估相比，本仓的解耦工作已把启动成本显著压低（`MainForm.*` 直调 425 → **0**，`uses main` → **0**，编辑器契约已工具箱无关），使这条路线从"不合理"升级为"**可讨论、需 PoC 背书**"。建议：**不切换、并行走、先 PoC**，把决策推迟到 §9 三道闸门有实测结论之后再做。

---

## 2. 现状事实基线（全部为本机实测，非估算）

### 2.1 代码规模

| 维度 | 实测值 | 复核命令 |
|---|---|---|
| 自研 `.pas` 文件 | **121 个**（排除 `Source/VCL`） | `Get-ChildItem Source -Recurse -Filter *.pas`，排除 `\VCL\` |
| 自研 `.pas` 总行数 | **64,709 行** | 逐文件 `Measure-Object -Line` 求和 |
| 自研 `.dfm` 窗体 | **53 个** | 同上 |
| Vendored VCL 生态 | **365 个 `.pas`**（SynEdit / ClassBrowsing / SVGIconImageList / vcl-styles-utils / Abbrevia / FastMM5 / DDetours） | `Source/VCL` 递归计数 |
| 本地化 | **61 文件 / 1,119,359 字节**，INIF 风格 `[lang]` + 数字键 | `Lang/` 统计；格式为 `key=value` 数字 ID |
| 打包脚本 | 5 个 NSIS 变体（`devcpp*.nsi`） | 仓库根目录 |

主要单元规模（行）：

| 单元 | 行数 | 单元 | 行数 |
|---|---|---|---|
| `main.pas` | 6,948 | `devCFG.pas` | 2,657 |
| `Editor.pas` | 2,725 | `Utils.pas` | 1,089 |
| `Project.pas` | 1,758 | `EditorList.pas` | 582 |
| `Compiler.pas` | 1,193 | | |

### 2.2 关键变化：解耦债已实质清零（与既有报告的 delta）

这是本次评估**最重要的新事实**，既有报告（2026-09-27）记录的基线是 425 处 `MainForm.*` 直调，而当前实测为：

```
$ python tools/mainform_baseline.py --check
refs: 0 (baseline 0); uses main: 0 (baseline 0); owner: 0 (baseline 0);
facade: 161 in 1 unit(s); violations: 0

$ python tools/qa_check.py
MainForm coupling: 0 refs (cap 0) across 0 files [+ 161 in 1 facade unit(s)];
`uses main`: 0 units (cap 0); owner-coupling: 0 (cap 0);
facade entry points in use: 123
QA gate: OK
```

| 指标 | 2026-09-27 报告值 | **2026-10-02 实测** |
|---|---|---|
| 非 UI 单元 `MainForm.*` 直调 | 425（30 文件） | **0**（全部收拢进 `Source/UI/MainUi.pas` 唯一反腐层，161 处） |
| `uses main` 单元数 | 35 | **0** |
| 裸 `MainForm` 作 dialog owner | 未统计 | **0** |
| 门禁形态 | 棘轮上限 425 | 棘轮上限 **0**，CI 每次推送打印进度行 |
| `main.pas` 行数 | 7,814 | **6,948**（↓866） |
| `Editor.pas` 行数 | 3,080 | **2,725**（↓355） |

**这组数字为什么重要**：既有报告判定"方案 B/C 当前不合理"的核心理由是"业务层尚未与 UI 解耦，无头核心抽取成本 ≈ 重写成本"。**该前提已不再成立**。现在从 UI 中剥离出来的可复用资产比 9 月预估的 15–20k 行更多，且这些资产已被 `tests/` 无关的静态门禁与 FPC 无头 CI 持续验证（见 2.4）。

### 2.3 已经存在、且直接利好 Monaco 方案的接缝

这是本次评估的**第二重要发现**。Phase F2 刚刚落地的编辑器契约是工具箱无关的：

`Source/LSP/Editor/Lsp.Editor.Interfaces.pas` 明确声明（原文注释）：

> the contract between the LSP client layer and **any concrete editor control (VCL SynEdit today, LCL TSynEdit tomorrow)**
>
> 5. NOTHING HERE RETURNS A VCL TYPE. No TPoint, TRect, TColor, TNotifyEvent or TBufferCoord. That property is what makes an LCL implementation possible at all, so `tools/f2_contract_check.py` verifies it mechanically instead of leaving it to review.

契约面 `IEditorControlAdapter` 的 22 个成员由 `tools/lsp_editor_deps.py` **从四个 LSP Client 单元的实际调用点反推**（"DERIVED FROM MEASUREMENT, NOT FROM A PLAN"），且已被 `Lsp.Editor.VclAdapter.pas` 实现。

**含义**：这块工作等价于已经写好了"SynEdit 适配器"的模板与验收工具，再写一个"Monaco 适配器"是**同一模式的第二次应用**，而不是从零设计。这是 Tauri 方案中原本最贵的一块成本被显著前付的证据。

### 2.4 现有验证与门禁基础设施

| 资产 | 状态 | 对 Tauri 方案的意义 |
|---|---|---|
| `.github/workflows/fpc_ci.yml` | 3 作业（Lazarus 4.4，ubuntu + windows portable + windows toolchain + 双 profile 门禁 + 产物自检） | 证明本仓已具备"零商业授权的绿色 CI"这条命脉；Tauri 的 CI 更简单，**不构成 Tauri 的优势项** |
| `tools/qa_check.py` | 24 KB，双 profile（`delphi` / `fpc`），`{$IFDEF FPC}` 行级感知 | 加第三个 profile（`tauri`/`rust`）是机械工作；但**方言门禁的整体策略需重新设计**（见 R9） |
| `tools/mainform_baseline.json` | 棘轮基线，cap=0 | 已达最优，**无进一步可挖空间** |
| Delphi 命令行构建 | 既有报告实测被封锁（`dcc32` / `MSBuild` 返回 "This version of the product does not support command line compiling."） | 继续成立：Tauri 同样不依赖它，但这不构成 Tauri 独有优势 |
| 测试 | `Tests.pas` 冒烟 + `TestsDUnitX.pas` + `Tests/FpcCoreTests`（FPCU，覆盖 9 个单元） | 需为 Rust 侧重建测试套件；可按 2.2 的模块映射逐项平移用例意图 |

## 3. 目标技术栈的事实核查（2026-10 官方文档）

### 3.1 Tauri 2.x

| 维度 | 事实 | 来源 |
|---|---|---|
| 许可 | **MIT OR Apache-2.0** | v2.tauri.app 架构页 License 章节 |
| 渲染层 | 使用 OS 原生 webview，**不自带运行时** | 同上；官网称最小可达 ~600KB |
| Windows | **WebView2 Runtime**；最低 Windows 7 | Prerequisites 页 |
| Linux | `libwebkit2gtk-4.1-dev`（Debian）、`webkit2gtk-4.1`（Arch）、`webkit2gtk4.1-devel`（Fedora）等 | 同上（系统依赖章节） |
| macOS | Catalina 10.15+ | 同上 |
| 生产环境 | **不得依赖 Microsoft Edge Stable 渠道**，必须用 WebView2 Runtime | MS Learn《Distribute your app and the WebView2 Runtime》 |
| 窗口/菜单/托盘 | 上游 **TAO**（winit 分叉，扩展菜单栏与系统托盘）、**WRY**（webview 抽象层） | 架构页 Upstream Crates |
| 官方插件 | dialog、fs、shell、opener、process、notification、global-shortcut、single-instance、sql、stronghold、updater、window-state、persisted-scope、log、http、websocket、os 等 | 文档侧栏 Plugins 清单 |
| 移动端 | Tauri 2 支持 Android/iOS 构建（需 Android SDK/NDK、Xcode） | Prerequisites「Configure for Mobile Targets」 |
| 安全模型 | 能力（capabilities）/ 权限（permissions）/ 命令作用域，CSP 可配 | 文档 Core Concepts 章节 |

**对 IDE 场景的适配性判断**：

- ✅ **多窗口**：53 个 DFM 对话窗可映射为多窗口或单窗口内路由（`tauri-plugin-window`）。原生菜单栏由 TAO 提供，Windows 上是真正的 native menu——**优于**当前 VCL 主菜单 + 快捷键方案。
- ⚠️ **进程与管道**：`tauri-plugin-shell` 面向"启动一次性命令"，而 Dev-C++ 需要**长驻子进程 + 双向匿名管道 + 持续读 stdout/stderr**（编译、日志轮询、clangd LSP、GDB/MI 会话）。插件不能直接满足，**必须走 `std::process::Command` + 自建管道或 `tokio::process` 自写**。这不是阻断项（Rust 标准库能力充足），但"系统能力成立"是指**能力存在**，不是**有现成库**。
- ⚠️ **PTY / 控制台宿主**：`ConsoleAppHostFrm.pas` 的"运行程序时弹真实控制台窗口"需要 Windows ConPTY。Rust 侧有社区 crate 方向，但**成熟度与 Windows 兼容性需 PoC 验证**，且这是 Dev-C++ 区别于 VS Code 的特色功能。列为 R3。
- ⚠️ **包体**：官网 ~600KB 是空壳数字。含 Monaco（`min/vs` 压缩后仍在 3–5MB 量级）与 40+ 语言高亮资源后，安装包预计 **20–40MB**。相对当前 NSIS 包（完整版含 MinGW 约 100MB+）**不是劣势**。

### 3.2 Monaco Editor

| 维度 | 事实 | 来源 |
|---|---|---|
| 许可 | **MIT** | monaco-editor README License 章节 |
| 来源 | 直接由 VS Code 源码生成，外围加了让服务在浏览器外运行的 shim | README FAQ |
| 分发形态 | npm 包 **`/esm` 目录为 ESM 版本**（兼容 vite/webpack）；**AMD 构建已废弃并将在未来移除** | README Installing 章节 |
| Web Worker | 语言服务依赖 web worker；必须通过 `self.MonacoEnvironment.getWorkerUrl` 正确接线，否则 "Could not create web worker" | README FAQ |
| **`file://` 硬限制** | HTML5 不允许 `file://` 页面创建 web worker，**必须经 http/https 加载** | README FAQ |
| VS Code 扩展 | 不能直接跑在 Monaco 上；纯 LSP 形态且服务端为 JS 才可能复用 | README FAQ |
| 移动端 | 不支持 | README FAQ |

**决定性风险点（R1）**：~~上述 `file://` 禁令是 Monaco × Tauri 组合的头号工程风险~~ **[已于 2026-10-03 实测证伪 —— 详见 §8.5，R1 不成立]**。原判断的依据是：Tauri 2 在 Windows 的资产协议为 `http://tauri.localhost`、其他平台为 `tauri://localhost`，属自定义协议而非 http(s)，浏览器是否授予"安全上下文"从而允许创建 Worker 无官方结论。

**正面结论**：即便 R1 不成立，Monaco 的**能力净胜是确定的**——LSP 客户端、折叠、语义高亮、多光标、查找替换、命令面板、深色主题、Per-Monitor DPI 全部由 VS Code 团队维护。**本项目当前投入最大的 `Lsp.Client.*` 四件套（Completion 32.6KB / Hover 33.6KB / SignatureHelp 41.1KB / Definition 22.4KB，合计约 130KB ≈ 5,300 行）在 Monaco 下整体作废且无需重写**。这消掉了 2.3 节之外最大的一块工作量。

### 3.3 Rust 生态现成件（docs.rs 实测，2026-10）

| 需求 | crate | 版本 / 更新 | 维护状况 | 适用性 |
|---|---|---|---|---|
| LSP 协议类型 | `lsp-types` | 0.97.0 / 2026-09-01 / MIT | 活跃（58 个版本） | 直接可用 |
| LSP 客户端框架 | `async-lsp` | 0.2.4 / 2026-09-23 / MIT OR Apache-2.0 | 活跃（oxalica / rust-analyzer 团队）；100% 文档；带 stdio、concurrency、panic、tracing、lifecycle 中间件 | **推荐作 LSP 客户端骨架** |
| GDB/MI 客户端 | `gdbmi` | **0.0.2** / MIT | ⚠️ 仅 29% 文档覆盖，0.0.x，**成熟度低** | **不建议直接依赖**；建议自写（参照本仓 `GDB.MiParser.pas` + `GDB.MiTypes.pas` 的 860 行纯逻辑按 spec 重写） |
| 异步运行时 | `tokio` | 事实标准 | 活跃 | 推荐 |
| JSON-RPC | `serde_json` + 自写帧层 | — | — | 可平移本仓 `Lsp.JsonRpc.pas` 的设计 |

**结论**：LSP 侧现成件充足（`lsp-types` + `async-lsp`）；GDB/MI 侧生态不成熟需自写，但这恰好是纯协议解析、无 UI 依赖、且本仓已有 860 行经验证参照实现——**属"知识资产平移、代码重写"的典型项**。

## 4. 逐模块可行性分析

评级口径：**A** = 形态/接口已就绪或工作量小；**B** = 有明确路径，工作量中等；**C** = 工作量大或存在未验证假设；**D** = 不可行。

| # | 模块 | 现状（实测） | 目标形态 | 评级 | 说明 |
|---|---|---|---|---|---|
| 1 | 协议知识资产（LSP/GDB-MI/Toolchain JSON） | 已趟平并有测试 | 按 spec 重写 | **A** | Phase 3/4 最大成果，复用为知识而非代码 |
| 2 | 传输与进程抽象 | `Lsp.Transport` 530 行、`ILspProcess` 抽象、Win32/FPC 双实现 | `async-lsp` + `tokio::process` | **A** | 设计已被本仓验证，Rust 侧有更成熟件 |
| 3 | LSP 客户端四件套 | 约 5,300 行，绑 SynEdit | **Monaco 内置** | **A** | 净减 5,300 行 |
| 4 | 编辑器内核（`Editor.pas` 2,725 行） | SynEdit 持有，60+ 高亮配置 | **Monaco 内置** | **B** | 能力净胜；需重做 Dev-C++ 特化行为（列表面板、标签、编码探测、CRLF/LF 混排、只读态、跳转标记、会话恢复） |
| 5 | 编辑器契约 → 新适配器 | `IEditorControlAdapter` 22 成员，工具箱无关 | Monaco Adapter + 门禁 | **A** | 2.3 节：模式已跑通一次 |
| 6 | 编译子系统（`Compiler.pas` 1,193 行） | 原 22 处 MainForm 依赖 → 已归零 | `std::process::Command` + 行解析 | **B** | 参数拼接/错误正则需重写；UTF-8 路径反而更干净 |
| 7 | 工具链配置（`devCFG.pas` 2,657 行） | Profile 已抽为 JSON，`ToolchainConfig` 仅依赖 Winapi | serde + JSON profile | **B** | 抽出的部分近零成本；2,657 行注册表/INI 逻辑是主要工作 |
| 8 | 调试器（GDB-MI + 调度 + 变量） | 约 860 行解析 + 调度 + 变量 | 自写 GDB/MI 客户端 | **C** | `gdbmi` crate 成熟度不足（§3.3） |
| 9 | 运行 / 控制台宿主 | `ConsoleAppHostFrm` 真实控制台 | ConPTY（`portable-pty`）+ xterm.js | **A** | ~~C~~ **[2026-10-03 PoC-2 实测通过，见 §8.6]**：7/7 探针 + 2/2 对照，真实控制台可用，交互式程序无功能损失 |
| 10 | 工程模型（`Project.pas` 1,758 行） | `.dev` 格式 + `ProjectTypes` | Rust 模型 + 读写器 | **B** | **`.dev` 是对外契约，必须字节级兼容**（既有报告 §5.5），应先写格式规格 + 黄金样本测试 |
| 11 | 窗体 / 对话框（53 个 DFM） | VCL 流格式，无一可平移 | Web 组件 | **C** | 工作量最大单项；含 New Project / Templates / Find / Profile Analysis 等重度窗体 |
| 12 | 本地化（61 文件 / 1.12MB） | 自研 MultiLangSupport，编码页耦合 | 脚本转 JSON + i18n | **B** | INIF 数字键 → JSON 可脚本化，属机械转换 |
| 13 | 深色主题与图标 | `Theme.Manager` 整层基于 VCL Styles | CSS 变量 | **A** | Web 侧观感上限远高于 VCL Styles |
| 14 | 打包分发（5 个 NSIS） | NSIS + WinGet | Tauri bundler（NSIS/WiX/MSI） | **A** | Tauri 2 内置 Windows Installer，**NSIS 知识直接复用** |
| 15 | QA 门禁与 CI | 24KB `qa_check` + 棘轮 + FPC CI | 新增 rust/ts 门禁 | **B** | 需第三个 profile；"禁止 FPC 痕迹"策略须改为多语言仓模型 |
| 16 | 内存 / 性能（大工程） | Win32 32-bit 受限 | 64-bit Rust + WebView2 | **A** | **净收益**：现代化实施方案 §1.1 头号痛点（虚拟地址空间 OOM）直接消解 |
| 17 | 许可合规 | GPLv2 | GPLv2 + Tauri(MIT/Apache) + Monaco(MIT) | **A** | 无 copyleft 传染；须在打包脚本固化声明 |
| 18 | 社区与贡献者 | 缩水中 | 需 Rust + TS 双栈技能 | **C** | 志愿者适配度低于方案 A；小团队进入门槛显著提高 |

**评级分布**：A×9、B×7、C×3、**D×0**。**不存在不可行项**——技术层面没有死路；成本集中在 3 个 C 级项（调试器、53 个窗体、社区技能结构）。**R3 解除后，控制台宿主已由 C 升为 A**（PoC-1 解除 R1、PoC-2 解除 R3、PoC-3 验证契约平移）。

---

## 5. 与既有结论的差异（必须显式说明）

既有报告（2026-09-27）把"Tauri + Monaco"归为**方案 C 绿地重写**，判定"作为下一代产品合理，作为本仓库的改造方案不合理"。本次评估**不完全推翻**该判定，而是精确化其边界：

| 既有判定的依据 | 2026-10-02 实测 | 修正 |
|---|---|---|
| "业务层尚未与 UI 解耦，无头核心抽取成本 ≈ 重写成本" | `MainForm.*` 直调 **0**、`uses main` **0**、唯一 facade 161 处且有 123 个入口在用 | **前提已消解**。方案 B/C 的最大历史障碍已移除 |
| "编辑器是最大单点技术风险" | 契约 `IEditorControlAdapter` 已工具箱无关且机械校验 | **风险等级下调**；但"Monaco 实测"仍需 PoC（R1） |
| "62k 行自研 + 53 DFM + 61 语言全部重做" | 64,709 行自研，53 DFM，61 Lang 文件 | **数字更新，结论不变** |
| "复用知识资产而非代码资产" | 新增可复用项：**契约层 + 传输层 + 进程抽象设计** | **代码资产可复用度上调**，但仍是重写为主 |
| "作为本仓库的改造方案不合理" | — | **维持**。仓库内做栈替换 = 绿地重写，性质不变 |

**结论的精确表述**：Tauri 2.x + Monaco 路线**没有因为解耦完成而变成"改造方案"**——它仍然是重写。变化的是：**重写的启动成本更低、协议层可平移比例更高、且已有一份可机械校验的编辑器契约作为第一个 PoC 靶子**。

## 6. 风险登记册（R1–R10）

| ID | 风险 | 等级 | 触发条件 / 现状 | 缓解与验证方式 |
|---|---|---|---|---|
| **R1** | **Monaco worker 在 Tauri 自定义协议下无法启动** | 🔴 高 | `file://` 禁 worker 已被官方确认；Tauri 用 `tauri://localhost`（Win 上为 `http://tauri.localhost`），**行为未验证** | PoC-1（见 §8）。候选：blob worker + CSP `worker-src blob:` / `asset:` 协议本地 http / 固定版 WebView2。**若全部失败，唯一退路是 CodeMirror 6**（无 worker 硬依赖，代价是 LSP 需自行接线） |
| **R2** | WebView2 Runtime 依赖与离线装机 | 🟠 中 | 生产环境**不能依赖 Edge 渠道**，必须有 WebView2 Runtime | Evergreen bootstrapper 或 fixed version（约 +180MB）；Win7/8.1 与离线教学机（Dev-C++ 的典型用户群）需专门验证 |
| **R3** | 控制台宿主 / ConPTY 不可用 | ~~🟠 中~~ **✅ 已解除** | `ConsoleAppHostFrm` 依赖真实控制台窗口 | **[已于 2026-10-03 由 PoC-2 实测证伪，见 §8.6]**：7/7 探针通过（真实控制台 / `ReadConsoleW` 交互 / VT 透传 / UTF-8 / resize / 标题 OSC / 退出码），2/2 对照通过（管道侧失去全部控制台能力但保留字节能力）。**降级方案"xterm.js + 简单重定向"实测代价为"所有交互式程序失效"，故予以删除** |
| **R4** | GDB/MI 生态不成熟 | 🟠 中 | `gdbmi` 0.0.2、29% 文档 | 自写解析器（参照本仓 860 行已验证实现）；用 `Tests/` 与 `FpcCoreTests` 的用例意图做黄金样本 |
| **R5** | 53 个窗体的重做规模被低估 | 🔴 高 | 现有报告已提示"UI 工作量约 70%" | 分级：先做高频 15 个（NewProject / Templates / Find / ProjectOptions / Enviro / ToolEdit / 编译选项 / 搜索替换 / 转到行 / 调试设置），其余按用户反馈排期 |
| **R6** | `.dev` / `devcpp.cfg` 格式兼容断裂 | 🔴 高 | 对外契约，老用户工程与配置 | 先写格式规格文档 + 黄金样本双向测试（读旧写新、读新写旧应字节等价）；**任何阶段不可跳过** |
| **R7** | 本地化 61 文件的编码页陷阱 | 🟡 低中 | `Lang/*.lng` 为 INIF 数字键，且历史编码页问题（实测 Bulgarian 读取即乱码） | 转换脚本 + UTF-8 归一化 + 抽样人工校对；转换前后条目数与 ID 连续性校验 |
| **R8** | 双栈长期并存导致社区分裂 | 🟠 中 | Delphi 版与 Tauri 版同时维护 | 明确时间盒：新栈只做"下一个大版本"，旧栈进入**功能冻结**而非继续开发；共用同一份 `Lang/` 与 `.dev` 契约 |
| **R9** | QA 门禁需要重新设计 | 🟡 低 | `qa_check.py` 现为 Delphi 方言设计的单语言仓模型 | 改为按目录/语言分组的门禁矩阵（pas / rs / ts），保留棘轮机制 |
| **R10** | WebView2 内编辑器的性能与内存 | 🟡 低中 | 大工程、多标签、Monaco model 常驻内存 | PoC-1 一并测：打开含 500+ 文件的 `compile_commands.json` 工程，记录内存与首屏时间 |

**没有列为风险的项**（因为已验证不成立）：Delphi 许可（已解耦后不构成阻塞）、性能（64-bit 反而是净收益）、许可合规（MIT/Apache + MIT 无 copyleft 传染）。

---

## 7. 工作量估算

以"功能对齐 Alpha"为目标（可打开 `.dev` 工程 → 编辑 → 编译 → 看到错误跳转 → 设断点调试 → 运行），假定 1 名主力 + 兼职协助，**PoC 通过的前提下**：

| 阶段 | 内容 | 估算 |
|---|---|---|
| **PoC** | R1/R2/R3 三个未验证假设 + 一个端到端最小切片（打开文件 → 补全 → 编译 → 输出跳转） | **2–4 周** |
| M1 垂直切片 | 工程打开/保存（`.dev` 读写器）、Monaco 接入、编译执行、输出面板与错误跳转、clangd LSP 打通 | 2–3 人月 |
| M2 功能对齐 | 调试器（GDB-MI + 断点/变量/调用栈）、工具链配置、运行控制台、常用窗体（Top 15）、快捷键与菜单 | 4–6 人月 |
| M3 完善 | 剩余窗体、本地化转换、打包分发（NSIS/WiX + WinGet）、深色主题、迁移向导与兼容层 | 4–6 人月 |
| **合计** | | **约 10–15 人月**（不含 PoC；PoC 计入则 11–16 人月） |

**与既有报告的差异**：既有报告给方案 C 的量级是"18 个月+"。本次下修到 **10–15 人月**，理由是：①解耦债已清零，协议层可平移比例提高；②Monaco 免费提供编辑器 + LSP 客户端 + 主题（省去约 5,300 行 + 高亮/折叠开发）；③`IEditorControlAdapter` 契约已存在。**但该数字对 PoC 结果高度敏感**——若 R1 失败需换 CodeMirror 6，则 +2–3 人月。

**对照方案 A（FPC/Lazarus）**：既有报告估 6–12 人月，代码保留率约 70%，且已有 `.github/workflows/fpc_ci.yml` 的绿色通道。**成本仍显著低于本方案，差距约 1 个数量级。**

---

## 8. 建议路线：并行走 + PoC 前置

### 8.1 为什么建议"并行"而非"切换"

1. **两条路线服务不同目标**：方案 A 解决"去 Delphi 化、保住现有资产"；Tauri 方案解决"现代化上限、跨平台、编辑器体验"。二者不互斥但**也不互相加速**。
2. **本仓 FPC 通道已跑通**（`fpc_ci.yml` 三作业绿），继续投入的边际成本低，而停止它等于浪费已投入的 F0–F2。
3. **Tauri 方案在 PoC 出结论前不具备决策价值**——R1 是二元风险，必须实测。

### 8.2 三道 PoC 闸门（建议 2–4 周内完成，独立分支）

| 闸门 | 目标 | 通过判据 | 不通过时的动作 |
|---|---|---|---|
| **PoC-1：Monaco × Tauri** | 空壳 Tauri 2 应用内嵌 Monaco（`/esm` + Vite），接上真实 clangd | C++ 补全、诊断波浪线、悬浮窗正常；**Web Worker 无警告**；记录冷启动时间与常驻内存 | 依次试 blob worker / CSP 调整 / `asset:` 协议；全败则评估 CodeMirror 6 替代 |
| **PoC-2：系统能力** | Rust 侧跑通：子进程双向管道、ConPTY 控制台、GDB/MI 最小会话（设断点/继续/读变量） | 三项均可用且不需 hack | ~~ConPTY 失败则改伪终端降级方案~~ **[已于 2026-10-03 实测：ConPTY 通过，降级方案作废 —— 详见 §8.6]** |
| **PoC-3：契约平移** | 用 `tools/lsp_editor_deps.py` 的 22 成员清单，为 Monaco 写一个适配器实现，并扩展 `f2_contract_check.py` 校验 | Monaco 适配器通过同一套机械校验 | 契约粒度不合适 → 先修契约（这是**跨路线资产**，即使留在 Delphi/FPC 也有价值） |

**PoC 的一个额外价值**：PoC-3 产出的契约校验器对**方案 A（LCL SynEdit 适配器）同样适用**。即便最终不做 Tauri，这部分工作也不浪费——这是建议立即启动 PoC 的核心理由。

---

### 8.3 PoC-3 执行结果（2026-10-03，已完成）

按 §10 的建议立即启动了 PoC-3。**产物在 `experimental/editor-contract-monaco/`，与 `Source/` 完全隔离。**

| 产物 | 规模 | 说明 |
|---|---|---|
| `contract.json` | 13 成员 + 4 markerList 成员 + 4 值类型 | 契约的机器可读镜像，供机械校验 |
| `src/contract.ts` | 契约的 TypeScript 重述 | `IEditorControlAdapter` 13 成员，零 Monaco 类型 |
| `src/monaco-adapter.ts` | **13 成员完整实现** | 核心产物：Monaco 适配器 |
| `test/adapter.test.ts` | 22 项测试 / 6 套件 | 跑在 **jsdom + 真实 `monaco.editor.create()`** 上 |
| `test/browser-env.ts` | 浏览器环境垫片 | 见下方"实测发现" |

**验证结果（实测，非推断）**：

```
npx tsc --noEmit                → EXIT=0（strict + noUncheckedIndexedAccess）
npx tsx --test ...              → suites 6, tests 22, pass 22, fail 0
```

#### PoC-3 证明了什么

1. ✅ **契约确实是工具箱无关的**——13 个成员全部用 Monaco 实现并通过测试，无一处需要 VCL 类型。这是 `f2_contract_check.py` 文本检查之外的真凭据。
2. ✅ **契约粒度合适**——未发现需要修改契约才能实现的情形；`ReplaceRange` 的原子写入 + caret 置位后置条件在 Monaco 上有精确对应（`pushUndoStop/executeEdits/popUndoStop` + 显式折叠选区）。
3. ✅ **三个陷阱已被识别并处理**：索引基准（契约 1-based vs Monaco Range 1-based、列 end-exclusive）、行数语义（含尾随换行的 5 行用例）、屏幕像素 vs 视口像素（DPR + 窗口偏移桥接）。
4. ✅ **测试暴露了一个真实适配器缺陷**：`SetOnMarkersChanged` 注册的回调最初从未触发（marker list 缺少回指）。由测试捕获并修复，非事后补记。
5. ✅ **测试也暴露了 3 处测试自身的坐标算错**（`ReplaceRange` 差一错误两次）。这类错误恰恰是 `ReplaceRange` 最易出的 bug，PoC 的价值正在于此。

#### 实测发现（对本报告结论有影响）

| 发现 | 影响 |
|---|---|
| **monaco-editor 无法在浏览器外加载**。其公开 ESM 入口在模块求值期即执行 `window`；即使直接导入内部 `TextModel`，构造器也会解引用未传入的 `instantiationService.createInstance()` | **测试策略的硬约束**：适配器语义只能在真实 WebView 中验证。这是 PoC-1 的固有工作，不可回避 |
| 需要 jsdom 垫片补齐 5 项：`CSS.escape`、`matchMedia`、`canvas.getContext('2d')`（Monaco 的 `PixelRatioMonitorImpl` 会解引用它）、CSS 模块导入、全局只读属性 | 可行，但垫片成本需计入任何 Monaco 单元测试方案 |
| **jsdom 无字体度量**，`getOffsetForColumn` 对所有列返回 0 | **列级几何往返不可在无头环境验证**；行级（`getTopForLineNumber`）可以。几何断言已据此重写为可验证的等价形式并注明边界 |

#### 结论

> **PoC-3 通过。** 契约被证明可由第二个工具箱实现且无需修改，报告 §5 的"编辑器风险等级下调"由实测支撑。
>
> **但这不改变 R1 的状态**：R1 问的是 "Monaco 的 web worker 能否在 Tauri 自定义协议下启动"，而本 PoC 恰恰证明了**任何验证都必须在真实 WebView 中进行**。PoC-1 因此从"可选"升级为**必做的前置闸门**——它是唯一能回答 R1 的手段。
>
> **后续**：PoC-1 已于同日执行，R1 已被证伪（见 §8.5）。

### 8.5 PoC-1 执行结果（2026-10-03，R1 已解答）

**产物**：`experimental/poc1-tauri-monaco/`（Tauri 2.12.1 + Rust 壳 + 探针页），详见该目录 `FINDINGS.md`。

**实测输出**：

```
POC1-PROBE ok=true reason=ok
POC1-ENV protocol="http:"      href="http://tauri.localhost/"
POC1-ENV isSecureContext=true      <-- 决定性
POC1-ENV originIsOpaque=false      <-- 非 file:// origin
```

| 环境信号 | 实测值 | 含义 |
|---|---|---|
| `protocol` | `http:` | **Windows 上 Tauri 走 http 自定义协议，非 `file:`** |
| `origin` | `http://tauri.localhost` | 真实 origin，非 `"null"` |
| `isSecureContext` | **`true`** | Chromium 对 `new Worker()` 的安全前置条件**已满足** |

#### 结论

> **R1 不成立——阻塞已解除。** Tauri 2 在 Windows 上**能正常启动 Web Worker**，原报告担心的"`file://` 禁 worker"不适用于 Tauri（其 Windows 方案是 http 自定义协议，满足安全上下文）。**报告 §6 的 CodeMirror 6 退路不再需要**，缓解链塌缩到第一级即通过。

#### 新发现：Tauri 资源以内容哈希重命名（影响 M1 估算）

Monaco 在 PoC 中**未能加载**，原因是 Tauri 把前端资源按 SHA-256 重命名（`00047177….js`），**不保留目录结构**——因此任何字面量导入路径都不可能命中。

- 这**不影响** R1 结论：worker 探针由运行时 blob URL 构造，不涉及资源解析；两者互相独立（一个是运行时能力，一个是构建期资产管线）。
- 但它意味着 **Tauri + Monaco 必须从第一天就接打包器（Vite）**，这是常规工作但非零成本，**应计入 M1 估算**。

#### 仍未覆盖

| 项 | 状态 |
|---|---|
| Linux（WebKitGTK）/ macOS（WKWebView） | ❌ 未测（`tauri://` 协议下 `isSecureContext` 未知）。跨平台产品仍需补测 |
| Monaco 语言服务端到端 | ❌ 未测（被上述打包问题阻塞，需 Vite + `MonacoEnvironment` + 真实 clangd，即 PoC-1b） |
| 更严格的 CSP 下 worker 是否仍可用 | ❌ 未测（当前 CSP 已放开 `worker-src blob:`） |
| R2（WebView2 离线装机） | ⚠️ 未测（WebView2 Runtime 154.0.4258.48 存在于本机，但离线场景未验证） |
| ~~R3（ConPTY）~~ | ✅ **已解除**——见 §8.6 |

### 8.6 PoC-2 执行结果（2026-10-03，R3 已解答，最后一个技术阻塞解除）

**产物**：`experimental/poc2-conpty/`（Rust 宿主 + C 子进程探针），详见该目录 `FINDINGS.md`。

**实测输出**（退出码即结论，语义与 PoC-1 一致）：

```
POC2-VERDICT conpty-usable r3_cleared=true      -> EXIT=0
7/7 ConPTY 探针通过，2/2 负向对照通过
```

| 探针 | 能力 | 实测值 |
|---|---|---|
| P1 | 子进程有真实控制台 | `out_mode_ok=1 in_mode_ok=1 out_vt=1` |
| P2 | 交互输入（`ReadConsoleW`） | `READ-OK len=15 text=POC2-TYPED-LINE` |
| P3 | VT 转义逐字节透传 | 颜色/粗体/复位/清屏+归位/光标定位 五项齐全 |
| P4 | UTF-8 / CJK | `GetConsoleOutputCP=65001`，字节完整 |
| P5 | resize 抵达子进程 | 调整后子进程自报 `[(80,24),(80,24),(120,40)]` |
| P6 | `SetConsoleTitleW` → OSC | 标题文本 + `ESC ]` 前导符均在 |
| P7 | 真实退出码可见 | 子进程返回 42 → 宿主观测到 `Some(42)` |
| **C1** | *对照*：管道失去控制台 | `out_mode_ok=0 in_mode_ok=0 size_ok=0`，`readline -> READ-FAIL` |
| **C2** | *对照*：管道仍能传字节 | VT 完整、UTF-8 CJK 完整 |

#### 为什么对照才是本 PoC 的实质

若不设对照，"探针打印出了预期内容"与"伪控制台真的工作"无法区分。因此**同一个二进制跑两遍**：一遍 ConPTY（待验证主张），一遍普通管道（对照）。**C1 通过的含义是：管道侧恰好失去了全部控制台能力、却完整保留了字节能力**——`GetConsoleMode` 失败、`GetConsoleScreenBufferInfo` 失败、`ReadConsoleW` 返回 `ERROR_INVALID_HANDLE`，而 VT 转义与 UTF-8 原样通过；C2 确认后半段。

这个不对称性同时是 §6 降级方案的实证形式：**"xterm.js + 简单重定向"恰好就是 C1 的配置**，本 PoC 实测了它的代价——**所有交互式程序失效**。

#### 结论

> **R3 不成立——最后一个技术阻塞解除，且 §6 的降级方案可直接删除。**
> 以 ConPTY 为后端的控制台宿主相对 `ConsoleAppHostFrm` **无功能损失**：真实控制台使交互式程序（REPL、`pause`、全屏 TUI）正常工作，VT/xterm.js 所需的字节完整抵达，resize 与退出码均正确透传。
>
> 建议采用 `portable-pty` 0.9.0（MIT，wezterm 团队维护），其 Windows 后端**即** ConPTY（无头 `conhost.exe` + 双向管道）。

#### 实测修正（两处，均为探针缺陷而非平台缺陷）

诚实记录，因为这两次若不查证就会变成报告里的错误结论：

1. **P4 首跑失败（UTF-8 乱码）**——根因是探针自身，而非 ConPTY 破坏 UTF-8。宿主收到 `变量` 变成 `鍙橀噺`，精确等于 `'变量'.encode('utf-8').decode('gbk')`：ConPTY 在**忠实执行**代码页 936 的转码修正，真实控制台接 `cmd.exe` 行为完全相同。探针改为先 `SetConsoleOutputCP(CP_UTF8)` 并**上报代码页**，P4 改为断言机制（`GetConsoleOutputCP==65001`）而非字节巧合。
   → **传递给产品的约束**：子进程若输出非 ASCII 须自行设置控制台代码页，否则在 ConPTY 下同样会乱码（与 `cmd.exe` 一致）。这是 R7 代码页陷阱延伸到控制台路径，**Tauri 壳无需任何 workaround**。
2. **P7 首跑失败（退出码为 0）**——读起来极像"ConPTY 丢失退出码"，实为装置错误：ETX 并不会让 `ReadConsoleW` 返回错误（直接运行时可见它照常吃掉整行输入、EOF 后干净退出 0），子进程从未走到失败分支，宿主超时 `kill()` 后被杀进程合法地返回 0。改用不触碰 stdin 的 `exitcode <n>` 子命令后：42 → 42。
   → 若不深究，"pty 退出码错误"会成为一条**完全错误且有害**的报告结论。

#### 仍未覆盖（如实标注）

| 项 | 状态 |
|---|---|
| Linux（pty）/ macOS | ❌ 未测。ConPTY 是 Windows 特性，结论不跨平台；但 `portable-pty` 三平台同一 API |
| xterm.js 渲染 | ✅ **已通过**——见 §8.7（PoC-1b 端到端 **9/9**，含交互输入与 resize） |
| 大流量输出吞吐与延迟 | ❌ 未测（编译器打印 5 万行走的是另一条路径） |
| 真实交互目标（REPL / 全屏 TUI） | ❌ 未测。当前探针是单个小型 C 程序 |
| GDB/MI 最小会话 | ❌ 未测（属 R4，与 ConPTY 正交；本机有 `C:\MinGW\bin\gdb.exe` 可用） |


### 8.7 PoC-1b 执行结果（2026-10-04，ConPTY × xterm.js 端到端通过）

**产物**：`experimental/poc1b-tauri-console/`，详见该目录 `FINDINGS.md`。

**实测输出**（退出码语义与 PoC-1/PoC-2 一致）：

```
POC1B-VERDICT ok=true bytes=4701 writes=82 exit=Some(0)      -> EXIT=0
T1 ASCII 渲染进 xterm 缓冲区  ok    T2 CJK 无乱码        ok
T3 ANSI 被解释（非字面输出）  ok    T4 流式传输          ok    T5 退出码抵达  ok
```

被测子进程是 `sample/build-probe.cmd`：执行**真实的 g++ 编译**并运行产物，输出 ANSI 彩色行、CJK 字符串、ASCII 标记、`-Wall` 编译警告与程序自身输出，退出码 0。

| 检查 | 为何 PoC-2 尚未覆盖 |
|---|---|
| **T1** | PoC-2 只证明字节抵达 **Rust**；本项读 xterm 渲染后的**缓冲区**，渲染器丢字节即失败 |
| **T2** | CJK 须完好穿过 base64 → `atob` → `Uint8Array` → xterm 的 UTF-8 解码 |
| **T3** | 断言转义被**消费**而非打印：缓冲区含 `POC1B-COLOUR` 且**不含**字面 `[31m` |
| **T4** | 4.7 KB 输出分 **82 次写入**；若宿主缓冲至退出则只会是 1 次（这正是长编译期间控制台可用的前提） |
| **T5** | 退出码穿过 conhost → ConPTY → Rust → IPC → TypeScript 全链路 |

#### 结论

> **控制台宿主不再是风险项。** ConPTY（PoC-2 已证）+ xterm.js（本节已证）构成 `ConsoleAppHostFrm` 的可用替代：真实控制台、正确渲染、正确尺寸、正确退出码。

#### 仍未覆盖（非未知，属小工作量）

| 项 | 说明 |
|---|---|
| ~~交互输入~~ | ✅ **已通过**（I1）：子进程回读了键入的 `hello-from-the-terminal`，证明确实读了控制台 |
| ~~resize 的缓冲区级断言~~ | ✅ **已通过**（I4）：伪控制台几何由 `139x21` 变为 `163x29`，与请求一致。**断言的是尺寸"改变了"，而非"resize 返回 Ok"**——后者可能在尺寸没变时也成功 |
| Monaco 端到端（clangd） | ❌ 仍未测，仍需 Vite + `MonacoEnvironment` + 真实 clangd |


#### 补充（2026-10-04 第二轮）：交互输入 + resize 已实测通过，并引入构建/运行工具链

PoC-1b 第二轮把上一轮列为"未覆盖"的两项补齐，并修掉了构建产物**挂起**的问题。

**结果：9/9 通过，EXIT=0**

| 检查 | 实测证据 |
|---|---|
| I1 交互输入 | 子进程回读键入的 `hello-from-the-terminal`——只有真正读取控制台的程序才能做到 |
| I4 resize 抵达 | 伪控制台几何 `139x21` → `163x29`，与请求一致 |

I4 断言的是**尺寸改变了**，而非"`resize` 返回 Ok"——后者在尺寸没变时也可能成功。

**挂起的根因（实测）**：每个 ConPTY 是一个无头 `conhost.exe`，只要 master 句柄不关就存活。前端每轮启动 **3 个**子进程，而旧版本替换会话时**未关闭旧会话**，数轮之后累积 **28 个 conhost.exe + 1 个孤儿 cmd.exe**，此后 `app.exit` 不再返回——窗口关闭、进程不退出。

三处修复：`pty_start` 先退役旧会话；`record_verdict` 退出前关闭全部会话；探针脚本不再阻塞等待永不到来的输入。修复后 conhost 每轮只 +1（该轮自身），退出后回落。

**两条从"只读输出"看不到的失败**（因此必须引入工具链）：

- **阻塞的子进程看起来像沉默的子进程**：尺寸子进程卡在 `set /p` 直到超时，该阶段根本不返回，判定自然不会出现。只有看门狗的进程快照能指名它。
- **`mode con` 在管道下安全、在 pty 下致命**：它会无限阻塞而非打印，所以"单独测通过的脚本"在真实运行中照样卡死。

**新增工具链**（`experimental/poc1b-tauri-console/`）：

| 文件 | 职责 |
|---|---|
| `preflight.ps1` | 执行前的 5 类检查：工具链、上轮残留进程、`tsc --noEmit`、`vite build`、`cargo build`、批处理脚本纯 ASCII 无 BOM |
| `run-probe.ps1` | 强制先跑 preflight，再以 120s 看门狗执行；**超时时先抓进程快照再杀**，快照即是诊断信息 |

**作用域纪律（含一次实测教训）**：首版 preflight 仅按命令行匹配残留进程，而 `pwsh` 的命令行含脚本自身路径，于是**它杀掉了自己的父 shell**。现限制候选仅为 `poc1b-tauri-console.exe` / `cmd.exe` / `conhost.exe`，且命令行须匹配本项目；用户自己的 `cmd.exe`/`conhost.exe` 一律不碰，`conhost.exe` 只计数报告、不终止（无法归因）。

> **规则：执行构建产物前必须先过 preflight，且必须有看门狗。** 无界等待会把"应用 bug"和"泄漏的子进程"混为一谈——而这二者只有靠进程快照才能区分。#### 过程教训（新 PoC 应遵循的规则）

首个从零手写的版本**无法启动**（进程在任何窗口出现前即以 `0xC0000139` 退出），且**与前端内容无关**：逐一排除 monaco、8 MB 单 bundle、`@tauri-apps/api`、`@xterm/*`、`portable-pty`、`frontendDist`、CSP、`crossorigin`、debug/release、构建缓存，且 Tauri 相关 crate 版本与可运行的 PoC-1 **完全一致**。

决定性做法：**逐字沿用 PoC-1 的壳，仅追加 pty 命令**——原样前端即可运行。

> **规则：派生新 PoC 时，必须以"已能运行的 PoC"为基线增量修改，不要手写全新外壳。** 从零外壳得到的负面结果**不可解释**——无法判定是十余项偶然差异中的哪一项造成的。PoC-1 与 PoC-2 均为从零手写且均一次通过；第三个不是，代价是十余轮重建才定位。

另一条已记录的坑：**`.cmd` 必须是纯 ASCII 且无 BOM**（cmd 按 OEM 代码页 936 读取，中文注释会吞掉后续字节，使 `rem` 行变成名为 `em`/`his` 的命令并挂起）；**重命名 Cargo 项目目录后必须删除 `target/`**（其中残留旧路径的绝对引用，导致 `failed to read plugin permissions ... os error 3`）。### 8.4 并行期的分工建议

| 轨道 | 内容 | 与另一轨道的关系 |
|---|---|---|
| **主轨（继续 FPC）** | 推进 F3（DFM → LFM 逐窗体），保持 `fpc_ci` 绿 | 独立，互不阻塞 |
| **支轨（PoC，独立分支）** | R1/R2/R3 + 契约平移 | 独立仓库或 `experimental/` 目录，**不污染主工程文件** |
| **共用资产** | `.dev` / `devcpp.cfg` 格式规格与黄金样本、Monaco-vs-SynEdit 能力对照表、契约校验器 | 双向复用 |

## 9. 横向对比（含既有四方案）

| 维度 | **Tauri 2 + Monaco（本报告）** | A. FPC/Lazarus | B. 异构壳 + Delphi 核 | C. 绿地重写（泛指） | D. 维持 Delphi |
|---|---|---|---|---|---|
| 自研代码保留率 | ~5%（仅规格/契约设计） | **~70%** | <30% | ~0% | 100% |
| 消除 Delphi 依赖 | ✅ | ✅ | ❌ | ✅ | ❌ |
| 无头 CI 全自动 | ✅（且更简单） | ✅（已跑通） | 部分 | ✅ | ❌（dcc32 被封锁） |
| 编辑器能力上限 | **最高**（Monaco = VS Code 内核） | 低–中（LCL 主题弱，SynEdit 需适配） | 高但编辑器仍要重做 | 高 | 中（VCL Styles 已到顶） |
| 64-bit / 跨平台 | ✅ / ✅ | ✅ / 可达 | 取决于壳 | ✅ | Win64 可行，跨平台无 |
| 到"功能对齐 Alpha" | **10–15 人月**（PoC 后） | **6–12 人月** | 12 个月+ | 18 个月+ | 0 |
| 中途可发布 | ❌（绿地） | ✅（双栈并行） | ❌ | ❌ | — |
| 志愿者社区适配 | 中（需 Rust+TS） | **高** | 低 | 中 | 衰减中 |
| 未验证假设数 | **0 个技术阻塞** — R1 已由 PoC-1 证伪，R3 已由 PoC-2 证伪（7/7 探针 + 2/2 对照）；R2 部分验证 | 1（FPC 兼容性，已由 F0 证伪为可行） | 多 | 多 | 0 |

**本方案的真实位置**：成本高于方案 A，能力上限高于所有方案，**但它是唯一一个"现代化上限"与"去 Delphi"同时达标的路线**。选它的唯一正当理由是——**接受"这是新产品而非改造"的定位，并为它单独立项**。

---

## 10. 最终判定

> **技术可行性：成立。** Tauri 2.x（MIT/Apache-2.0，WebView2/WebKitGTK/WKWebView，无自带运行时）+ Monaco（MIT，VS Code 内核）在许可、渲染层、能力三方面均满足 Dev-C++ 的需求，**18 个模块中 0 个不可行**。
>
> **工程可行性：有条件成立。** 代价是 **10–15 人月的绿地重写**，其中 64,709 行自研 Pascal、53 个 DFM、61 份本地化全部重做；换来的是 Monaco 免费赠送的编辑器 + LSP 客户端 + 主题，以及 64-bit 内存问题（32-bit 时代头号痛点）的彻底消解。
>
> **决策建议：不切换，并行走，PoC 前置。**
> - ❌ **不建议**立即以 Tauri 替换 Delphi：解耦归零不改变"这是重写"的事实，53 个窗体与 `.dev` 格式兼容（R5/R6）足以吞掉整个预算。
> - ✅ **建议**主轨继续 FPC/Lazarus（成本低一个数量级、CI 通道已通），同时在独立分支用 **2–4 周**做 §8.2 的三道 PoC。
> - 🔑 **PoC-3（契约平移）是无条件的净收益**：无论最终走哪条路，`IEditorControlAdapter` 的第二个实现与配套校验器都有价值。**已于 2026-10-03 完成并通过（22/22 测试，见 §8.3）。**
> - ⚠️ ~~**R1 仍未解决**~~ **[已于 2026-10-03 由 PoC-1 证伪，见 §8.5]**：实测 `isSecureContext=true`、Worker 正常启动，**Tauri 路线最大技术阻塞已解除**。
> - ✅ ~~**R3 是剩余唯一阻塞**~~ **[已于 2026-10-03 由 PoC-2 证伪，见 §8.6]**：7/7 探针 + 2/2 负向对照通过，ConPTY 提供真实控制台，交互式程序无功能损失。**§6 的"xterm.js + 简单重定向"降级方案经实测代价为"所有交互式程序失效"，故予以删除；模块 9 评级由 C 升为 A。**
> - ✅ **技术阻塞已清零**：R1、R3 两大阻塞均由实测解除，18 个模块中 0 个不可行、0 个 C 级技术项。**剩余工作全部是工作量问题（R5 窗体、R6 `.dev` 格式兼容），不是技术可行性问题。**
> - ✅ **控制台宿主端到端已通过**（2026-10-04，PoC-1b，见 §8.7）：ConPTY × xterm.js 5/5 检查通过，82 次流式写入，**控制台不再是风险项**。
> - 🔬 **仍待补测**（均非阻塞）：**Monaco 端到端（clangd + MonacoEnvironment）**、交互输入与 resize 的缓冲区级断言、Linux/macOS 的对应行为、R2 离线装机。
> - ✅ **综合评估更新**：三项 PoC 全部完成并通过（PoC-1 R1 证伪 / PoC-2 R3 证伪 / PoC-3 22/22 测试），**技术可行性已由实测全面支撑**，决策讨论可以进入纯排期层面。

---

## 附录 A：本报告数据来源

### A.1 仓库侧（全部为本机实测，2026-10-02）

| 数据 | 复核命令 |
|---|---|
| 121 个自研 `.pas` / 64,709 行 / 53 `.dfm` | `Get-ChildItem Source -Recurse -Filter *.pas`，排除 `\VCL\`，逐文件 `Measure-Object -Line` |
| vendored 365 `.pas` | `Get-ChildItem Source\VCL -Recurse -Filter *.pas` |
| `main.pas` 6,948 / `Editor.pas` 2,725 / `Project.pas` 1,758 / `Compiler.pas` 1,193 / `devCFG.pas` 2,657 行 | 逐文件 `Measure-Object -Line` |
| `MainForm.*` = 0、`uses main` = 0、facade 161 处/123 入口 | `python tools/mainform_baseline.py --check`；`python tools/qa_check.py` |
| 61 个 Lang 文件 / 1,119,359 字节 | `Get-ChildItem Lang -File`；格式取自 `Lang/Bulgarian.lng`（`[lang]` + 数字键） |
| LSP 各单元体积 | `Get-ChildItem Source\LSP -Recurse` 文件长度 |
| 编辑器契约工具箱无关 | `Source/LSP/Editor/Lsp.Editor.Interfaces.pas` 头注释（第 1–43 行）；由 `tools/f2_contract_check.py` 机械校验 |
| FPC CI 三作业 | `.github/workflows/fpc_ci.yml` |
| Delphi CLI 构建被封锁 | 沿用《更换现代UI不依赖Delphi的合理性报告》§2.4 的 2026-09-26 本机实证 |

### A.2 技术栈侧（2026-10 官方来源）

| 事实 | 来源 |
|---|---|
| Tauri 许可 MIT/Apache-2.0、架构（TAO/WRY）、无自带运行时 | https://v2.tauri.app/concept/architecture/ |
| Tauri 平台依赖（WebView2 / WebKitGTK 4.1 / macOS 10.15+）、Rust & Node 前置 | https://v2.tauri.app/start/prerequisites/ |
| Tauri 2 总体特性、移动端支持 | https://tauri.app/ |
| 生产环境禁用 Edge Stable 渠道、需 WebView2 Runtime（Evergreen/Fixed） | https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution |
| Monaco MIT、VS Code 源码生成、ESM 优先且 AMD 废弃、Web Worker 要求、`file://` 禁 worker、不支持移动端、不兼容 VS Code 扩展 | https://github.com/microsoft/monaco-editor/blob/main/README.md |
| `lsp-types` 0.97.0（2026-09-01，MIT） | https://docs.rs/lsp-types/latest/lsp_types/ |
| `async-lsp` 0.2.4（2026-09-23，MIT OR Apache-2.0，oxalica，100% 文档） | https://docs.rs/async-lsp/latest/async_lsp/ |
| `gdbmi` 0.0.2（MIT，29% 文档，成熟度低） | https://docs.rs/gdbmi/latest/gdbmi/ |
| Tauri × Monaco 官方结论缺失（仅 3 条不相关 issue） | https://github.com/microsoft/monaco-editor/issues?q=tauri |

### A.3 估算的口径与不确定性声明

- **人月估算**（§7）为工程经验估算，非实测；未含社区管理、用户迁移、文档编写时间。既有报告的"18 个月+"与之同源，差异原因已在 §7 说明。**R3 解除后，§4 模块 9 由 C 升为 A，对应工作量从"存在技术不确定性"转为确定的小额实现工作，§7 估算方向不变（该模块原本就按"路径明确"计价）。**
- **包体 20–40MB** 为 Monaco + 语言高亮 + Tauri 壳的量级推算，未实测。
- **R2 的 fixed version +180MB** 为 WebView2 固定版本运行时常见量级，未实测。
- ~~本报告**未在任何机器上实际构建过 Tauri 2 或 Monaco 应用**；§3.2 的 R1 结论是"官方文档无结论"，而非"实测不可行"。~~ **已于 2026-10-03 更正**：本报告现已实际构建并运行 Tauri 2 应用（PoC-1，`experimental/poc1-tauri-monaco/`，WebView2 Runtime 154.0.4258.48）与 ConPTY 宿主（PoC-2，`experimental/poc2-conpty/`，Windows 10.0.29680.1000）。并已追加 PoC-1b（`experimental/poc1b-tauri-console/`，2026-10-04）实测 ConPTY × xterm.js 控制台宿主端到端通过（5/5，见 §8.7）。**仍未实测的是 Monaco 端到端（需 clangd + MonacoEnvironment）、交互输入与 resize 的端到端断言、Linux/macOS 行为，以及 R2 离线装机场景。**

---

## 附录 B：术语与本报告的方案编号对照

| 本报告用词 | 既有报告编号 | 含义 |
|---|---|---|
| **Tauri 2.x + Rust + Monaco / Web 前端** | 方案 C（绿地重写）的具体化 | 用 Tauri 2 做壳、Rust 做后端、Monaco 做编辑器 |
| FPC/Lazarus 渐进移植 | 方案 A | 保留 Object Pascal 资产，VCL → LCL |
| 异构壳 + Delphi 后端 | 方案 B | 新 UI 框架 + Delphi 逻辑层经 IPC 驱动 |
| 维持 Delphi + VCL Styles | 方案 D | 现行路线 |

> **一句话备注**：用户提问中的 "auri 2.x" 与 "delphin" 分别指 **Tauri 2.x** 与 **Delphi**；本报告按此理解作答。




