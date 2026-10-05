# F3-SVG：LCL 矢量图标方案

> 生成日期：2026-10-04
> 数据来源：`tools/f3_svg_inventory.py` 实测（非估算）
> 关联：[[FPC-Lazarus渐进式移植实施方案]] §3 F3/F4

---

## 1. 为什么这是当前唯一的架构杠杆

实测发现（见实施方案 §8.6）：**9 个 A 批窗体转换后窗口能开、但图标全空**，另有 4 个 C 批窗体被同一原因阻塞。它们全部依赖 vendored 的 `TSVGIconImageList`。

| 事实 | 实测值 |
|---|---|
| 依赖 SVG 图标的窗体 | **15**（A 批 9 + C 批 6） |
| 其中原本被误判为「已完成」 | **9** |
| `.Images` 赋值点总数 | 97 |
| 其中指向 SVG 列表 | **70**（其余走既有 `TImageList`，不受影响） |

**结论：SVG 一次解锁 13 个窗体**，是当前唯一能改变 F3 排期的动作。

---

## 2. 数据实测：远比预想的轻

| 项 | 实测值 |
|---|---|
| SVG 图像列表 | 5 个（`SVGImageListMenuStyle` / `ProjectStyle` / `ClassStyle` / `MessageStyle` / `IconImageWelcomeScreen`） |
| 图标条目 | **116 条**（94 个不重名，20 个名字重复） |
| SVG 文本总量 | **约 88.6 KB**（116 条，最大单条 4.2 KB） |
| 数据位置 | **DFM 内联**（`SVGText = '<svg .../>'` 属性） |
| 外部依赖 | **零** —— 无 `<image>`、无 `xlink:href`、无 `@font-face`、无 `url()` |

### 这个事实改变了方案选择

因为图标是**自包含的内联文本**：

- ✅ **不存在**文件路径解析问题（无需资源打包/复制）
- ✅ **不存在**对 `fpvectorial` / `lazutils` XML 光栅化链的运行时依赖
- ✅ **数据完全不需要搬动** —— 它已经在 DFM 里
- ⚠️ 唯一与 VCL 耦合的是**控件**（`TSVGIconImageList` 派生自 `TCustomImageList`），不是数据

> **所以问题不是「LCL 能否加载这些 SVG」，而是「用什么把内联 SVG 画到 TCanvas 上」。**

---

## 3. 替换面（必须暴露的 API）

| API | 使用点 | 说明 |
|---|---|---|
| `Images` 属性 | DFM 97 处 / 代码 52 处 | 赋一个图像列表 |
| `ImageIndex` 属性 | **DFM 188 处** / 代码 48 处 | 按索引取图 |
| 索引图像列表 | 116 项 | 需支持 `GetImage`/`SetImage`/`Count` |
| 主题着色 | — | SVG 带 `fill:#7daca8` 等样式，主题切换时需运行时改色 |
| 尺寸缩放 | — | 源图标 `viewBox="0 0 18 18"`，需支持高 DPI 缩放（F4 目标：工具栏 200%/4K 清晰） |
| **每列表独立尺寸** | 5 个列表 | **实测 `Size` 属性是像素边长而非条目数**：19 / 18 / 32(默认) / 25 / 37 px。控件必须按列表尺寸渲染，不能硬编码 |

---

## 4. 方案对比

### 方案 A：移植 vendored `SVGIconImageList`（**不推荐**）

- 该库基于 **Delphi 图形 API + 第三方 SVG 解析器**（`fmx` / `fpvectorial`）
- 在 LCL 下需要重写整个渲染后端
- **且它解决不了数据问题**——数据本来就在 DFM 里，移植库只是搬了个控件壳

### 方案 B：LCL 原生 SVG 渲染控件（**推荐**）

Lazarus 自带 `lazutils` 图形栈与 **`TSVGComponent`/`TSVGImage`**（基于 `fpvectorial`，FCL/LCL 内建）。因此：

```
新控件 TLclSvgImageList = class(TCustomImageList)
  ├─ SVGText: array of AnsiString     // 内联文本，逐项
  ├─ GetImage(i)  → TBitmap           // 首次访问时按需光栅化并缓存
  ├─ 按目标尺寸缓存（Key = (index, w, h, theme)）
  └─ 主题变更时清缓存
```

**优势**：
1. **零数据迁移** —— SVG 文本仍在原 DFM 位置
2. 复用 LCL 内建 SVG 栈，不引入新依赖
3. 按需 + 缓存光栅化：116 个图标只在真正显示时才付出代价
4. 尺寸化缓存直接服务 F4 的「200%/4K 清晰」目标

**代价**：一个约 300–400 行的控件 + 一个把 DFM 的 `SVGIconItems` 转成 `SVGText[]` 的转换步骤。

---

## 5. 实施顺序

| 步 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| 1 | **数据抽取**：从 `DataFrm.dfm` 导出 116 条 SVG → `SvgData.pas` | 可校验的常量单元 | 无 |
| 2 | **`TLclSvgImageList`**：按需光栅化 + 尺寸/主题缓存 | LCL 控件 | 步 1 |
| 3 | **DFM 转换规则**：`TSVGIconImageList` → `TLclSvgImageList`，`SVGIconItems` → `SVGText[]` | 转换器规则 | 步 2 |
| 4 | **接入 A-svg 9 个 + C 批 4 个** | 13 个窗体解锁 | 步 3 |

**关键：步 1 是纯数据搬运，可在无 Lazarus 环境下完成并校验**（比对导出的 SVG 与 DFM 原文逐字节一致）。因此即使本机装不上 Lazarus，方案也能推进到「数据就绪 + 控件代码就绪」，只差真实渲染验证。

---

## 6. 与 F4 的关系

原方案把 F3（窗体转换）与 F4（矢量图标 + 深色主题）视为独立阶段。实测证明：

- **F4 的「矢量图标：LCL 原生 SVG」正是本方案的本体**
- F3 的 13 个窗体等待它
- F4 的深色主题需要图标可运行时改色（`fill` 样式替换），与本方案缓存策略同源

> **建议：把本方案作为 F3-C 的前置，同时它就是 F4 的第一项。两个「阶段」实为同一件事的先后两面。**

---

## 7. 诚实的边界

以下**尚未验证**，不得当作已完成（**2026-10-05 已更新，见 §11**：本机现已能真实编译，三项中两项已有结论）：

- ❌ ~~**LCL 的 `TSVGComponent` 能否处理这些 SVG 的具体子集**~~ —— **该前提本身是错的**：`fpvectorial.pas` 中 `TSVG\w*` **零命中**，根本没有这个类。真实入口是 `TvVectorialDocument.ReadFromStream(S, vfSVG)` + `TvPage.Render(Canvas, …)`。实测见 §11.2
- ❌ **主题改色的具体实现** —— SVG 用 `style="fill:#7daca8"`，需确认改写策略（字符串替换 vs CSS 类）
- ❌ **188 处 `ImageIndex` 的取值是否都在列表范围内** —— 需在控件实现后由运行时校验
- ❌ **116 个图标在高 DPI 下的光栅化质量** —— F4 明确要求 200%/4K 清晰

**外部条件已于 2026-10-05 解除**：`C:\lazarus` 下已可用，且本机成功编译了 LCL 与 fpvectorial 两个包（见 §11.1）。此前"本机无 FPC/Lazarus"的记录已过期。

---

## 11. 首次真实编译：修正了方案里 4 处错误前提（2026-10-05）

本节记录把本方案从"纸面设计"变成"可编译"的过程。**结论先行：§2/§4 关于 LCL API 的三处描述都是错的，而 §1 的产物 `SvgData.pas` 根本编不过。** 所有结论均为实测，非阅读文档所得。

### 11.1 先决条件：LCL 与 fpvectorial 必须**先编译**

装好的 Lazarus **只带源码，不带已编译单元**——`lcl\units\` 下只有 Lazarus IDE 自身的 288 个单元，`graphics.ppu` / `imglist.ppu` / `fpvectorial.ppu` **一个都没有**。两次 `lazbuild`（均 exit 0）后才有：

```
lazbuild --ws=win32 C:\lazarus\lcl\interfaces\lcl.lpk          # LCL
lazbuild C:\lazarus\components\fpvectorial\fpvectorialpkg.lpk  # fpvectorial
```

**在此之前，`TLclSvgImageList` 不只是"没编译过"，而是**不可能编译**。固定的搜索路径见 `tools/build_svg_probe.ps1`。

### 11.2 实测修正：LCL 与 fpvectorial 的真实 API

| §2/§4 的写法 | 实测 | 证据 |
|---|---|---|
| `TSVGComponent` / `TSVGImage`（"FCL/LCL 内建"） | **不存在**，`fpvectorial.pas` 中 `TSVG\w*` 零命中 | 全文检索 |
| `class(TCustomImageList)` + `GetImage(i)→TBitmap` override | **编不过**：`There is no method in an ancestor class to be overridden: "GetImage"`（`SetImage`、`GetCount` 同） | 编译器 |
| 按需光栅化（override 取图） | **不可行**：LCL 的 `GetCount` 是 **private 且非 virtual**，`Count` 读内部 resolution 列表 | `lcl/imglist.pp:302,403` |

LCL 里所有控件的 `Images` 属性都是 `TCustomImageList`（`TBitBtn`/`TSpeedButton`/`TImage`/`TToolBar`…），而现控件是 `TLclSvgImageList = class`——**它永远无法赋给任何 `.Images`**，也无法作为 LFM 组件流式加载。**§4 的控件设计需要重做**：正确形态是 `class(TCustomImageList)` + 用 `Add(Bitmap, nil)` 填充真实位图，代价是放弃"按需"、改为整表光栅化。

真实调用链（实测可用）：

```pascal
uses fpvectorial, svgvectorialreader, fpvectorial2canvas, Interfaces;
Doc := TvVectorialDocument.Create;
Doc.ReadFromStream(Utf8Stream, vfSVG);
Page := Doc.GetPageAsVectorial(0);
Page.Render(Canvas, 0, 0, 1.0, 1.0);
```

三个"沉默的坑"：`svgvectorialreader`（注册 SVG reader，缺则 `Unsupported vector graphics format`）、`fpvectorial2canvas`（注册默认渲染器）、`Interfaces`（LCL widgetset，缺则 `EAccessViolation`）；以及 **UTF-8 字节流**——用 `TStringStream` 在 `-Mdelphiunicode` 下喂进 UTF-16，解析器报 `EXMLReadError … invalid character 0`。

### 11.3 §1 的产物 `SvgData.pas` **编不过**（已修）

原生成器输出的是 record 常量：

```pascal
const
  SVG_IMAGE_LISTS: array[0..4] of TSvgImageList = (
    ( Name: 'SVGImageListMenuStyle';
      Names: array[0..84] of string = ( … ) ) … );
```

Delphi 合法，FPC 直接拒绝：`SvgData.pas(32,14) Fatal: Syntax error, "(" expected but "ARRAY" found`。**数据单元是控件与全部 13 个窗体的地基，而它从来没被编译过。**

实测各种形态（FPC 3.2.2）后改为**独立的静态数组常量 + `var` 记录数组在 `initialization` 填充**。另有两条 FPC 专属要求：数组元素间**必须有逗号**（Delphi 允许换行分隔，FPC 不允许），且**最后一个元素后不能有逗号**。

修完：`--verify` 仍报 **116 条 SVG 与 DFM 逐字节一致**，且 `SvgDataProbe.exe` 运行确认 **5 个列表 / 116 条载荷全部送达**，尺寸 19/18/未声明/25/37 与 `FindSvgListIndex` 均正确。

> 顺带修掉一处**锚错了对象的校验**：原 `--verify` 靠 grep 字面量 `SizePx: 19;` 来确认像素边长已写入，而这个字面量的存在只取决于"用 record 常量"这个排版选择。现在改成调用与生成器**同一个** `init_call()`，校验与写入无法各行其是。

### 11.4 实测：116 个图标中 **109 个真的画出了像素**

`RasterProbe.exe`（真 LCL + fpvectorial，198 行）**逐个光栅化并统计非透明像素**——只"解析成功"不算数，本项目已经两次栽在"结构完好但什么都不画"上：

```
SVGImageListMenuStyle      edge=19   83/ 85 ok  (0 blank)
SVGImageListProjectStyle   edge=18    6/  6 ok  (0 blank)
SVGImageListClassStyle     edge=32    7/ 12 ok  (0 blank)
SVGImageListMessageStyle   edge=25    7/  7 ok  (0 blank)
SVGIconImageWelcomeScreen  edge=37    6/  6 ok  (0 blank)
icons total : 116    rendered ok : 109    blank : 0    elapsed : 265 ms
```

**7 个失败**，症状一致（`EZeroDivide: Floating point division by zero`），已逐一定位到名称：

| 列表 | 失败索引 | 名称 |
|---|---|---|
| `SVGImageListMenuStyle` | 53 / 75 | `iconsnew-56` / `iconsnew-82` |
| `SVGImageListClassStyle` | 2 / 3 / 4 / 9 / 11 | `iconsnew-54/55/56/57/63` |

### 11.4b 根因已查明并修复：零弦弧段（2026-10-06 实测闭环）

> 上一节这条“尚未查明”在 2026-10-06 关闭。原判断有两处错误，均已在下面纠正：**症状阶段写错**（不是渲染期），以及**曾有一个回读 `SvgData.pas` 的脚本报出 85 条列表 696 条项——那个脚本本身是错的**，其对 `viewBox`/`path` 的任何结论都不作数。这条保留，因为它说明了为什么后面改用“走路径语法”的检测器而不是再写一个正则。

**根因**：7 个失败图标**每一个**、且**只有它们**含有“起终点相同”的弧段。fpvectorial 按 SVG 实现说明做端点→圆心参数化（`fpvutils.pas:550`）：

```pascal
m := (sqr(rx*ry) - sqr(rx*y1p) - sqr(ry*x1p)) / (sqr(rx*y1p) + sqr(ry*x1p));
```

零弦时 `x1p = y1p = 0` → 分母 **0**、分子 `(rx*ry)^2 > 0`；而这句除法在下一行 `SameValue` 守卫**之前**执行，守卫救不了它。

**候选筛选**（`tools/f3_svg_divzero.py`）：18 个文本形状候选**无一能分离**（最好的只到“7 个失败里都有，但全集也有”，那证明不了任何事）。改成**走路径语法**的结构候选后：

```
zero-chord-arc      7        7  PERFECT SEPARATOR
zero-radius-arc     0        0  rejected: in no failure
```

**阶段纠正（原记录是推断，不是测量）**：原文写“`EZeroDivide` 发生在渲染而非解析”，那只是从 RasterProbe 单一 try/except 推出来的。新增 `SvgParse.lpr`（**只 `ReadFromStream`，不渲染**）实测 **7/7 在解析期抛出**。因此修复必须落在“喂给解析器之前”。

**A/B 实验**（Python 生成变体、Pascal 判定，判定器不接触生成器内部）：

| 运行 | 结果 | 说明 |
|---|---|---|
| `SvgParse svg\failed` | **7/7 抛 `EZeroDivide`** | 故障在解析期 |
| `SvgTry svg\failed` | 0/7 | 基线：判定器能判负 |
| `SvgTry svg\control` | **3/3 通过** | **判定器不瞎**（3 个未改动的好图标） |
| `SvgTry svg\zerochord` | **7/7 通过且有像素** | 剔除退化弧段后全部渲染 |

变体由 `tools/f3_svg_zerochord.py` 生成，写盘前断言四条：**恰好 7/116 改变**、**与 RasterProbe 的失败名单逐名吻合**（Pascal 侧独立产出的名单）、**重建结果 = 原 token 序列减去被删组**、**输出纯 ASCII**。

> **判定器自身有个真 bug，一并留档**：`SvgTry`/首版探针把**文件路径**当 SVG 内容喂给解析器（`TEncoding.UTF8.GetBytes(AFile)`），**从未读过文件**——对任何输入都返回 0。是 `SvgParse` 首跑报 `EXMLReadError "Illegal at document level"`（报的是**参数**，不是 SVG）才暴露的。**一个对正确文件也给 0 分的判定器，会把修好的东西判成“没修好”**；`control` 目录就是为今后区分“全坏”与“判定器瞎”而设的。

**修复落点：控件，不是数据。** `LclSvgImageList.Rasterise` 在 `ReadFromStream` 前调用新增的 `StripDegenerateArcs`；`SvgData.pas` **一字未动**——`f3_svg_extract.py --verify` 仍报 **116 条逐字节一致**，那条不变式（本项目靠它抓过两次数据丢失）保持原样。

**两个独立实现必须互相校验**：新增 `SvgNorm.lpr`，把 FPC 版输出与 Python 版写盘的 7 个变体**逐字节比对** → **7/7 MATCH**。

> **首版 Pascal 实现被这道校验当场抓下**：数词切分允许消费多个小数点，把 `-.08.38` 并成**一个** token，`Val` 失败后跳字符 → 参数错位 → **漏检 6 段、伪造 4 段**，`SvgListProbe` 的失败数从 7 反升到 **11**。修法是“每个数词至多一个小数点”，并把“无法安全切分”改为**返回原文不改**（fail-safe）。**两套实现照同一份描述各写一遍、互相比较，比各自与自己比较有用得多。**

**修复后实测**：

| 项 | 修复前 | 修复后 |
|---|---|---|
| `SvgListProbe` 五个列表计数 | 83/85 · 6/6 · 7/12 · 7/7 · 6/6 | **85/85 · 6/6 · 12/12 · 7/7 · 6/6** |
| `SvgListProbe` 渲染失败 | 7 | **0** |
| `EXPECTED_MAX_FAILURES` | 7（“已知缺口”天花板） | **0**（回归即失败，该检查同时由 no-op 改为 `Inc(Failures)`） |
| `RasterProbe`（绕过控件，直接读数据） | 7 | **仍为 7 —— 符合设计**：它回答“数据能否被 fpvectorial 直接吃下”，控件回答“控件能否显示” |
| `f3_svg_extract --verify` | 116 逐字节 | **116 逐字节（未受影响）** |

**删除的代价，实测而非估计**：19 段退化弧，半径 **0.050–0.100 user units**，按各自列表边长折算**最大 0.142 px**——任何列表尺寸下都是亚像素；**19 段的 large-arc 全为 0**（(0,1)×12、(0,0)×7），因此“端点相同 + large-arc=1 可能画整圆”的那条规范解读**不适用于本次删除的任何一段**。

> **仍然不猜的一条**：SVG 规范对“端点相同”的**逐字原文**本次没有取到（W3C 页面抓取被截断），故不引用、不复述。上面所有结论都来自**可复跑的实测**；规范措辞若日后取到，再补引文。

### 11.5 步骤 2/3/4 的真实状态

| 步 | 状态 |
|---|---|
| 1 数据抽取 | ✅ **已可编译并经运行时验证**（116 条送达；`--verify` 仍逐字节）。覆盖面缺口见 §12.6 |
| 2 `TLclSvgImageList` | ✅ **编译运行通过，且 7 个 `EZeroDivide` 已修复** —— 走控件 **116/116**、`fail=0`（§11.4b） |
| 3 DFM 转换规则 | ✅ **完成**，且**首次被真实 LCL 加载验证**（§12.7） |
| 4 接入 13 个窗体 | ✅ 消费端完成；生产端 1/3，另两个被**明确拒绝**并记录原因（§12.6） |

### 11.6 步骤 2 完成：控件能真正当图像列表用了

重写后的 `TLclSvgImageList = class(TCustomImageList)`，编译 + 运行验证（`SvgListProbe.exe`）。

> **下图是修复前的读数**（`fail` 合计 7）。2026-10-06 之后同一探针报 **85/85 · 6/6 · 12/12 · 7/7 · 6/6，`fail=0`**，见 §11.4b；这里保留原读数，因为它正是“渲染失败 7 个”的当时证据。

```
SVGImageListMenuStyle     count= 83/ 85 edge=19 ink[0]= 361 fail=2
SVGImageListProjectStyle  count=  6/  6 edge=18 ink[0]= 324 fail=0
SVGImageListClassStyle    count=  7/ 12 edge=32 ink[0]=1024 fail=5
SVGImageListMessageStyle  count=  7/  7 edge=25 ink[0]= 625 fail=0
SVGIconImageWelcomeScreen count=  6/  6 edge=37 ink[0]=1369 fail=0
before theme: count=83 gen=1   →   after theme: count=83 gen=2
RESULT: SVG list works as a real LCL image list
```

验证的是三件旧设计**做不到**的事：`B.Images := L` 能赋给真实 LCL 控件（`TBitBtn`）、`Count`/边长来自数据、`GetBitmap` 取回的图标**有可见像素**。主题切换重渲染后 `Count` 不变、生成计数递增。

> 放弃"按需光栅化"是**被实测逼出来的取舍**：`GetCount` 是 private 非 virtual，per-index hook 无法存在。代价已实测：116 个图标整表光栅化 265 ms。

### 11.7 ⚠️ 需要决策：步骤 3 的产物该放哪里

> **已于 2026-10-06 关闭，选 (b)。** 决策与实测结果见 §12。

步骤 3 的转换规则要产出 `TSVGIconImageList` → `TLclSvgImageList` 的 LFM。但控件目前**放在 `Tests/FpcCoreTests/svg/` 下**，而转换后的 LFM 在 `Tests/FpcCoreTests/lfm/`。两条路：

- **(a) 留在 `Tests/`** — 控件继续作为 F3 的验证装置，不进 `Source/`。代价：将来 `Source/Fpc` 真正建 LCL 工程时要再搬一次。
- **(b) 移进 `Source/`**（如 `Source/Fpc/UI/Controls/LclSvgImageList.pas`）— 一步到位，且 `Source/Fpc` **早已**在 `tools/qa_check.py` 的 `FPC_DIRS` 豁免名单里（“FPC/Lazarus 平移子工程目录”），FPC-only 单元不污染 Delphi 方言门禁。

这是**编排决策而非技术障碍**，故在此停下。原先并列的另一个未知——7 个 `EZeroDivide`——**已于 2026-10-06 查明根因并修复**（§11.4b，走控件 116/116、`fail=0`），**因此本决策是步骤 3 的唯一剩余阻塞**。
---

## 8. 步骤 1 已完成（2026-10-04）：数据就绪并逐字节校验

| 产出 | 内容 | 校验 |
|---|---|---|
| `Tests/FpcCoreTests/svg/SvgData.pas` | 5 个列表 / 116 条 SVG 的 Pascal 常量 | 逐字节往返 |
| `Tests/FpcCoreTests/svg/svg_manifest.json` | 名称、字符数、sha256 | 供其它工具交叉核对 |
| `tools/f3_svg_extract.py` | 抽取器（`--verify` 开启校验） | 退出码即结论 |

```
VERIFY OK: 116 SVG(s) round-trip byte-identical from the DFM into SvgData.pas.
独立复核（行扫描法，非工具自身的正则）：116 条，长度 0 处不符，全部以 </svg> 结尾
```

### 两个被实测纠正的判断

**① `Size` 不是条目数。** 首版抽取器比较 `Size` 与解析出的条目数，报出「`Size=19` 但解析出 85 条」，看起来像解析失败。实际 `FMX.SVGIconImageList.pas:90` 声明为：

```pascal
property Size: Integer read GetSize write SetSize default 32;   // 像素边长
```

**实测 5 个列表的 `Size` 分别是 19 / 18 /（默认 32）/ 25 / 37 像素** —— 这是控件设计必须知道的约束：**各列表图标尺寸不同，渲染时不能硬编码单一尺寸**。

**② 数据量是 88.6 KB，不是 7.2 KB。** 首版正则只捕获每条字符串续行的**第一块**，把 SVG 截到 64 字符（实为 521）。而当时的 `--verify` 拿截断值与自身比对，**通过了** —— 这是自证式校验的典型失效。

> **教训：校验器必须用与生成器不同的方法。** 后来改用「行扫描法」独立提取再比对长度/结尾，116 条全部吻合。若沿用自比对，这个 12 倍的数据丢失会一路带到 LCL 控件里。

## 9. 步骤 2 已完成（2026-10-04）：`TLclSvgImageList` 写完，**门禁却是假绿灯**

| 产出 | 内容 |
|---|---|
| `Tests/FpcCoreTests/svg/LclSvgImageList.pas` | 控件本体（420 行）：按需光栅化 + (索引,宽,高,主题代) 缓存 |
| `tools/f3_svg_extract.py` | 扩展为同时输出 `SizePx` 与 `Names`，并校验之 |
| `tools/lcl_svg_struct_check.py` | 结构门禁，含 `--self-test`（7 例必须失败） |

### 首版控件有 6 处真实缺陷，而门禁报 OK

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | 类声明未闭合（`= class` 后直接跟自由过程，缺 `public`/`end;`） | 编译失败 |
| 2 | `uses` 缺 `SvgData`、`FPCollections` | 编译失败 |
| 3 | **`LoadSvgLists` 从不装载数据** —— 建空列表，`FSvg` 零赋值 | `Count=0`，**每个图标仍为空** |
| 4 | `Result: TBitmap` 却 `:= TSVGToBitmap.Create`（后者派生自 `TFPCustomImage`） | 编译失败 |
| 5 | stale 分支改的是**局部副本** `Entry.Bitmap`，`FCache` 仍指向已释放对象 | 悬垂指针，`ThemeChanged` 二次 `Remove` 已释放内存 |
| 6 | `Size` 用列表名 if/else 链硬编码 | 改名后静默回落到 32 px 默认值 |

> **缺陷 3 最值得记**：它就是本方案要消灭的「空图标」bug，在修复代码内部被**原样复现了一遍**。控件「能跑」、门禁绿、图标全空。

### 门禁为什么是绿的：注释承诺的检查根本没实现

- `check_balance` 有一段长注释描述「按关键字栈追踪 `begin/end`」——**代码里不存在**，实际只检查 `unit` / `end.` / `begin` 三个字符串在不在。
- `STUB_BODY` 正则**定义了却从未被调用**。

两者都属本项目日志里已记过两次的同一族问题：**「没有模式 = 没有断言」**，以及**「断言覆盖不到组合爆炸」**。

### 修复分两类，第二类才是重点

1. **兑现注释**：真正实现关键字栈平衡检查。
2. **让检查「反空转」** —— 新增 `--self-test`：每个检查都必须**能被证伪**。

> **一个从未失败过的检查，不构成已验证的检查。** 首版门禁只打印过 OK，而它罩住的文件有 6 个编译级缺陷。`--self-test` 给每个检查喂一段**刻意写坏**的片段并要求它报错；若某项检查不再报错，报出来的是「此项检查已空转」，而不是「通过」。

`--self-test` 的 7 个用例首次跑挂，暴露了门禁自身的 3 个缺陷（均已修）：

- **`check_ifdef` 会崩溃** —— `rindex()` 在无 `{$ENDIF}` 时抛 `ValueError`，即**门禁在它要报的那个缺陷上抛异常**，于是什么也没报。
- **例程声明的 `end;` 被当成闭块符** —— Pascal 中声明无 `begin` 即无块，`end;` 是终止符。误算会让栈从此浅一层，其后每个 `end` 都对空栈出栈，把**正确代码**判成 `end with no open block`。
- **`ROUTINE_RE` 把类名当例程名** —— `constructor TFoo.Create;` 报成 `TFoo` 未声明 + `Create` 未实现。

> **门禁误报正确代码，比门禁漏报更危险**：前者训练人忽略它，于是它在真正有 bug 时也一并被忽略。stub 检查最初也这样：它对「`except` 分支释放后置 nil」和「查完列表未命中返回 nil」这类**正当**收尾报错，被收窄为「函数体**只有**那一条赋值」才既不误报又能抓真 stub。

### 门禁的真实覆盖边界（注入缺陷实测，非估计）

| 注入的缺陷 | 门禁 |
|---|---|
| `uses` 去掉 `SvgData` + `FPCollections` | ✅ 抓到 |
| 类丢掉结尾 `end;` | ✅ 抓到 |
| 删掉 `implementation` 段 | ✅ 抓到 |
| **`LoadFrom` 不复制 SVG 数据** | ❌ **抓不到** |
| 例程声明无函数体 | ❌ 抓不到 |

**两个 MISSED 不是遗漏，写下来是为了不再假装覆盖了它们：**

- **语义缺陷抓不到**。区分「正确装载」与「装了个空壳」需要类型系统与数据语义，那是编译器的事。它恰恰是 6 个缺陷里危害最大的那个——**在有 Lazarus 之前，本门禁无法声称能防止它再犯**。它由编译器（nil 数组解引用）与 F3 渲染检查兜底。
- 第二个用例注入的是 `publicX`，**根本不是合法 Pascal**；没有文本级门禁该抓它。

> **由此固化一条边界：结构门禁只管「形状」；凡是「文本正确但行为错误」的失效，都在它的能力之外，必须交给能真正跑代码的东西。**

### 同时修掉的一处「测量结果被重新推导」

原控件用列表名 if/else 链硬编码 19/18/25/37 px，而这些值**抽取器早已实测出来**。这是把一份已有测量复制成第二份，并且**改名即静默退化**。现改为随数据走：`SvgData.TSvgImageList.SizePx`，由 `f3_svg_extract.py` 从 DFM 读出并**纳入往返校验**（`--verify` 会核对 `SizePx` 与 DFM 一致）。同时新增 `Names` 数组并一并校验。

### 步骤 2 的诚实边界

| 项 | 状态 |
|---|---|
| 数据就绪且逐字节校验 | ✅ |
| 控件结构通过门禁，且门禁**自证能失败** | ✅ |
| **能否编译** | ❌ **未验证**（本机无 FPC/Lazarus） |
| **fpvectorial 能否解析全部 116 个图标** | ❌ 未验证 |
| 主题改色是否生效 | ❌ 未验证 |
| 188 处 `ImageIndex` 是否越界 | ❌ 未验证 |

> `Size` 的语义（像素边长而非条目数）现在是**数据事实**而非代码假设，因此 5 个列表的尺寸不会再被任何一条 if 链改写。

## 10. 当前进度与剩余

| 步 | 状态 |
|---|---|
| 1 数据抽取 | ✅ 完成并校验（**覆盖面不足**：`NewProjectFrm` 自带的 1 个列表未抽取，见 §12.6） |
| 2 `TLclSvgImageList` 控件 | ✅ **编译 + 运行验证通过**；7 个 `EZeroDivide` 已修复，走控件 **116/116、`fail=0`**（§11.4b），`EXPECTED_MAX_FAILURES` 收紧到 0 |
| 3 DFM 转换规则 | ✅ **完成，并由 §12.7 的探针首次真正加载验证**（5 列表 / 116 图标 / 边长与像素全对） |
| 4 接入 13 个窗体 | ✅ **消费端完成**：15 个 LFM + 68 处绑定全部解析。**生产端 1/3 完成**：`DataFrm` 的 5 个列表已出片段；`NewProjectFrm`（抽取器未覆盖）、`Tools/Packman/Main`（无 LCL 对应控件）被**明确拒绝**而非静默放行 |

步骤 3/4 已纯代码完成并经真实 LCL 运行验证（§12）。**当前剩余项**（均不阻塞已交付部分）：

1. **抽取器覆盖面**：`f3_svg_extract.py` 只读 `DataFrm.dfm`，`NewProjectFrm` 的 1 个列表（名 `Empty`，37 px）缺失 → 该窗体的片段目前被拒绝。
2. **`Tools/Packman/Main`**：需要 `TSVGIconImageCollection` / `TSVGIconVirtualImageList` 的 LCL 对应控件（18 处集合）。
3. **消费端 15 个 LFM 本身尚未被 `lazbuild` 加载**：它们含大量 vendored / 自有控件（`TCompOptionsFrame`、`TSynCppSyn`、`TClassBrowser` 等），受 C 批阻塞；已验证的只是 SVG 列表片段这一层。
4. §7 尚未验证的三项（主题改色、高 DPI 光栅化质量）是质量问题。

> 其中第 3 项是本方案当前最诚实的边界：**“SVG 一次解锁 13 个窗体”成立的前提是 SVG 这一个阻塞被清掉；其余阻塞并未随之消失。** §12.6 的实测把“已解锁”与“仍被其它控件阻塞”分开列了，不再给出一个合并后的乐观数字。
---

## 12. 步骤 3 + 步骤 4 完成：转换规则落地，LFM 首次被真正加载（2026-10-06）

本节记录从“能编译的控件”到“**能被 LCL 加载的转换产物**”这一步。**结论先行：转换规则本身很短，短到不需要写；但让这条规则成立的四个前提，每一个都是实测踩出来的，其中两个此前被当作已经解决。**

### 12.1 §11.7 决策落地：产物移入 `Source/Fpc/`

选 (b)，并发现决策的风险比预估低：`tools/qa_check.py` 的 `FPC_DIRS = ("Source/Fpc", "Tests/FpcCoreTests")` **早就把 `Source/Fpc` 列为方言门禁豁免目录**，只是该目录一直不存在。双 profile 门禁实测全绿，FPC-only 单元没有污染 Delphi 构建。

```
Source/Fpc/UI/Controls/LclSvgImageList.pas   控件本体
Source/Fpc/UI/Data/SvgData.pas + manifest     116 条载荷（生成物）
Source/Fpc/UI/Forms/                          转换产物 **50** 个（顶层 37 + Tools/ 下 13）
                                            + _generated.json（溯源清单）
Tests/FpcCoreTests/svg/*.lpr                  探针（保持验证装置身份）
```

> 50 = 34（A 批）+ 15（SVG 消费端）+ 1（SVG 列表片段），与 `f3_lfm_check.py`
> 报的 `.lfm files : 50` 一致。

### 12.2 规则本体：每个列表只剩一个属性

```
object SVGImageListMenuStyle: TSVGIconImageList     对象 X: TLclSvgImageList
  Size = 19                                           ─────────────────────────
  SVGIconItems = < 116 × SVGText …>        ==>         ListName = 'SVGImageListMenuStyle'
  DisabledGrayScale / Scaled / Left / Top
end                                             end
```

**丢掉的每一个属性都有理由，且理由不是“Delphi 没有”**：

| 丢掉 | 为什么 |
|---|---|
| `SVGIconItems`（116 条 / 88.6 KB） | 字节已在 `SvgData.pas`，且 `f3_svg_extract.py --verify` 逐字节守住它。再抄一份等于让同一事实住两家，而那道往返门禁此后只会查其中一家 |
| `Size` / `Height` | 边长由 `AData.SizePx` 给出（19/18/**未声明**/25/37） |
| `Left` / `Top` | LCL 的 `TCustomImageList` 派生自 **`TLCLComponent` 而非 `TControl`**（`lcl/imglist.pp:266`），根本没有这两个属性——留着不是“无害残留”，是加载器会拒绝的属性 |
| `DisabledGrayScale` / `DisabledOpacity` / `Scaled` | vendored 控件专有，LCL 无对应物 |

**`Height` 是这里唯一真正危险的一个**，值得单独记：`SVGImageListClassStyle` 的 DFM 里写的是 `Height = 18`，而它**不是** `Size`。`Size` 在 LCL 上是未知名，丢了就丢了；`Height` 却是 `TCustomImageList` 的合法 published 属性，而**读取器按文件顺序赋值**——它会落在 `ListName` **之后**，把刚按 32 px 载入的列表缩到 18 px。因此规则用的是**白名单**（只保留 `Color`/`BkColor`/`TransparentColor`/`BlendColor`/`Masked`/`AllocBy`），而不是“列出要丢的东西”。

### 12.3 控制端：流式入口必须挂在 `published` 上

转换规则只改文本；真正让 `ListName` 起作用的是控件。**而这一处差点被写成 `public`**：

> `Error reading SVGImageListMenuStyle.ListName: Unknown property: "ListName"`

组件读取器通过 **RTTI** 解析属性名，FPC 只为 `published` 段生成 RTTI。写成 `public`，转换器照样报告成功、LFM 文本照样正确、**每个图标照样是空的**——本项目第三次栽在同一族问题上（§9 记过两次：“没有模式 = 没有断言”）。这次是它的变体：**属性存在，但没有 RTTI**。

此外 `SetListName` 查不到名字时置 `MissingData = True`：因为“查无此列表”和“确实没有图标”从外面看一模一样，而只有后者不是 bug。

### 12.4 三个“沉默的坑”，按踩中顺序

**① `TReader` 在 FPC 3.2.2 下只有二进制驱动。**
`classesh.inc` 里 `TAbstractObjectReader` 只有 `TBinaryObjectReader` 一个具体子类，`TReader.Create` 无条件构造它。指向文本 LFM 时它**不报错，而是挂死**——在 ASCII 上空转等二进制签名。挂死比报错更坏，因为它看起来像控件里的死锁，而不是 API 用错了。正确入口是 Lazarus 自己的 `LResources.ReadComponentFromTextStream`。

**② `ReadComponentFromBinaryStream` 无条件调用 `OnFindComponentClass`。**
`lresources.pp`：`AClass:=nil; OnFindComponentClass(nil,AClassName,AClass);` —— 传 `nil` 不是“用默认值”，是**空方法指针调用**，本机表现为挂死。该事件是 `of object`，需要一个宿主对象，裸函数也不行。

**③ 探针自己把期望值按位置索引。**
`Expected[ComponentIndex]`：一个只含 `SVGImageListProjectStyle` 的片段被拿去和 `SVGImageListMenuStyle` 的 85 图标 / 19 px 比，报出两条与被测代码无关的失败。**LFM 里的顺序不是任何契约的一部分**，依赖位置的期望就不是期望。改为**按名字查**。

### 12.5 最严重的一处：`.lfm` 的溯源表头让它**无法被加载**

转换器原本给每个 `.lfm` 写 `% ...` 溯源表头。四种注释语法全部实测：

```
{ generated header }      -> EParserError: Symbol expected but { found   (1,164)
(* generated header *)    -> EParserError: Symbol expected but ( found   (1,166)
// generated header       -> EParserError: Symbol expected but / found   (1,163)
% generated header        -> EParserError: Symbol expected but found     (1,162)
```

**`TParser` 不跳注释，直接找 `object`。四种都不行**——而“标准注释语法应该能用”正是本项目反复被迫撤回的猜测。

**即：已产出的 34 个 `.lfm` 全部无法被 LCL 读取**，且它们此前只被结构门禁检查过，结构门禁当然看不出问题。改为：**`.lfm` 不带任何注释**，溯源移到旁挂的 `_generated.json`，并让 `f3_lfm_check.py` 断言“每个 `.lfm` 都必须有一条溯源记录”，防止清单腐烂。

### 12.6 步骤 4 的实际完成度（实测，不是估计）

| 项 | 实测 |
|---|---|
| 消费窗体（`Images = dmMain.<list>`）转换 | **15** 个 LFM |
| 消费侧绑定点，全部能在片段里解析到 | **68** 处，0 悬空 |
| 生产端 SVG 片段 | `DataFrm.svg-lists.lfm`（**5** 个列表） |
| 生产端拒绝 | `Tools/Packman/Main.dfm`（`TSVGIconImageCollection` / `TSVGIconVirtualImageList` 无 LCL 对应物） |
| 生产端拒绝 | `NewProjectFrm.dfm`——**它自己声明了一个列表**，且**步骤 1 从未抽取过它**（说明见本节末） |

**`NewProjectFrm` 是本轮挖出的真实缺口**：它内联了一个名为 `SVGIconImageList` 的单条目列表（1 个图标，名 `Empty`，37 px），而 `f3_svg_extract.py` 只读 `DataFrm.dfm`。转换器现在**读 `svg_manifest.json` 做交叉校验并拒绝它**，而不是让它流出一个 `Count = 0` 的空列表。**抽取器的覆盖面本身仍需扩展**（步骤 1 的遗留项）。

### 12.7 新增门禁：LFM 首次被真实加载

`Tests/FpcCoreTests/svg/SvgLfmProbe.lpr`（245 行）流式加载**转换器实际产出**的文件——不是自己写的固定样本，否则它与控件同源、只能证明控件能被喂进形状相似的东西。实测：

```
STREAMING Source\Fpc\UI\Forms\DataFrm.svg-lists.lfm
  parsed to binary: 422 byte(s)
  streamed root: TSvgImageLists with 5 component(s)

  SVGImageListMenuStyle      Count 85/85  edge 19x19  fail 0  blank 0/85
  SVGImageListProjectStyle   Count  6/ 6  edge 18x18  fail 0  blank 0/ 6
  SVGImageListClassStyle     Count 12/12  edge 32x32  fail 0  blank 0/12
  SVGImageListMessageStyle   Count  7/ 7  edge 25x25  fail 0  blank 0/ 7
  SVGIconImageWelcomeScreen  Count  6/ 6  edge 37x37  fail 0  blank 0/ 6

RESULT: the generated LFM loads and its icons are drawn
```

期望值来自 `SvgData`（第三份独立实现），`SvgData` 与 DFM 的逐字节一致性由 `f3_svg_extract.py --verify` 守住（第四份）。**`RasterProbe` 仍报 7，符合设计**：它绕过控件直喂 fpvectorial，回答的是另一个问题。

### 12.8 门禁的「反空转」验证

新加的检查全部**注入缺陷实测**，而非声称：

| 注入 | 门禁 | 还原 |
|---|---|---|
| 把一个 `ListName` 改错 | ✅ 报「ListName 与组件名不符」 | MD5 一致 |
| 把 `%` 表头加回去 | ✅ 报「首行不是 `object`」 | MD5 一致 |
| 让消费窗体绑定到不存在的列表 | ✅ 报「没有片段声明该列表」 | MD5 一致 |

> 第一版 `ListName` 检查用 `\s*`（在 `re.S` 下**跨行**），于是 `end` 匹配到文件最后一个 `end`，报出 5 条同名失败——每个名字都在和**下一个**组件比。加上 `.lfm` 是 CRLF 而锚点用 `$`（`[ \t]*$` 匹配不到 `\r`），**这些检查一开始一条都没命中**——读起来和全绿完全一样。现在换行先归一化，并在输出里打印 `SVG list fragments: 1 (lists: 5)`，让“命中 0 条”不再长得像“检查通过”。

### 12.9 CI

新增作业 `lcl-svg-runtime`（windows-latest）：先编译 LCL 与 fpvectorial（**两者都不是现成的**，见 §11.1），再从干净检出重新生成数据与 LFM，然后跑 4 个探针，并对两处**设计上的非零读数**断言：转换器因 Packman/Main 拒绝而退出码为 1、`RasterProbe` 仍报 `INCOMPLETE`。

> **诚实的边界**：该作业**只在 Windows 上跑**。探针构建脚本 `build_svg_probe.ps1` 硬编码了 win32 单元目录与 `x86_64-win64`，移植它**没有做**，因此不宣称任何 Linux 徽章。

### 12.10 本轮抓到并修复的缺陷汇总

| # | 缺陷 | 抓到它的 |
|---|---|---|
| 1 | `ListName` 写成 `public`，无 RTTI | 运行时 `Unknown property` |
| 2 | `.lfm` 注释表头使全部 50 个文件无法加载 | 四种注释语法的解析矩阵 |
| 3 | `Height = 18` 会在 `ListName` 之后缩放列表 | 读 LCL 的属性发布顺序 |
| 4 | 集合终止符是 `end>` 而非裸 `>`；需按嵌套计深度 | 解析器 `IndexError` + 28/28 平衡实测 |
| 5 | 片段选择器按**旧**类名筛节点 → 静默跳过所有生产窗体，旧文件留在盘上冒充新产物 | 文件内容与表头对不上 |
| 6 | `NewProjectFrm` 的列表不在 `SvgData` 中 → 会流出空列表 | 转换器对 `svg_manifest.json` 的交叉校验 |
| 7 | `ReadComponentFromBinaryStream` 传 `nil` 即空方法指针调用 | 挂死 |
| 8 | 探针按位置索引期望值 → 报告与被测代码无关的失败 | 一个只含单个列表的片段 |

**第 5 条最值得记**：它是一个**静默的空操作**——代码成功返回、文件保留、`if not svg_nodes` 把它吞掉，而磁盘上的旧文件**带着一张声称规则已生效的表头**。与 §9 记的“缺陷 3”同族：**修复代码内部原样复现了它要消灭的 bug**。

---

## 13. 分支 2：C 批解阻路线图（2026-10-06，实测重算）

上一节结束时"SVG 解锁 13 个窗体"这句话缺一个数：解完之后，**还剩几个真的能编译，剩几个被别的控件挡着**。本节用 `tools/f3_load_routes.py` 从树上重算，替代此前 13 / 15 / 9 三个互相矛盾的手算答案。

### 13.1 关键结论：15 个消费端里，**9 个已无任何阻塞**

```
  converted .lfm in total     : 49
  of which SVG consumers      : 15
  CLEARED by the SVG work     : 9
  still blocked by other code : 6
```

**「9」不是估计，是交叉验证出来的**：`f3_form_survey.py` 独立报「convertible AND svg-independent = 34/53」与「convertible as-is = 43/53」，二者相减 **43 − 34 = 9**，与本工具从 `_generated.json` 侧算出的 9 完全一致。两个工具走不同代码路径得到同一个数，这是本项目一贯要求的交叉校验。

### 13.2 下一块最便宜的证据：把这 9 个**加载**出来

`AStyleFormatterOptionsFrm` / `AboutFrm` / `ClangFormatterOptionsFrm` / `FormatterOptionsFrm` / `IconFrm` / `NewTemplateFrm` / `ParamsFrm` / `ToolEditFrm` / `ToolFrm`

这 9 个**无阻塞控件 + 图标列表已是真列表**，即 `f3_lfm_check.py` 之后没有任何东西挡着编译。它们是全计划里**最便宜的剩余证据**——不需要新写任何控件，只需要像 `SvgLfmProbe` 那样把 LFM 喂给真实 LCL 读取器。**这应当优先于任何新控件的编写。**

### 13.3 阻断项按「退役一个能解锁几个」排序

| 阻断控件 | 归属 | 解锁窗体 | 目标窗体 |
|---|---|---|---|
| `TVirtualImage` | **external**（LCL 有等价物） | **3** | EnviroFrm, LangFrm, main |
| `TCompOptionsFrame` | own | 2 | CompOptionsFrm, ProjectOptionsFrm |
| `TCompOptionsList` | vendored | 2 | CompOptionsFrm, ProjectOptionsFrm |
| `TSynCppSyn` | vendored | 1 | EditorOptFrm |
| `TClassBrowser` `TCodeCompletion` `TControlBar` `TCppParser` `TCppPreprocessor` `TCppTokenizer` `TdevFileMonitor` `TdevShortcuts` | vendored/external | **各 1** | **全部是 main.dfm** |

**排期结论有两层，第二层比第一层重要：**

- **单点最优是 `TVirtualImage`**（3 个窗体），而且它是 **external** —— LCL 侧有对应物，属于**字段级替换**，不需要写控件。这是投入产出比最高的一刀。
- **`main.dfm` 的 8 个阻断项，每一个都只值 1 个窗体**，而且 8 个里有 5 个是 vendored 自研解析器（`TCppParser` / `TCppPreprocessor` / `TCppTokenizer` / `TClassBrowser` / `TCodeCompletion`）。**把 `main.dfm` 当作一个目标去"清空阻断"，成本是 8 次控件移植；而它本身只有 1 个窗体的收益。** 正确做法是把它**排除出近期排期**，而不是让它绑架整条路线。

### 13.4 生产端缺口（缺的是控件，不是窗体）

```
Tools/Packman/Main.dfm: TSVGIconImageCollection, TSVGIconVirtualImageList  -- 无 LCL 对应物
DataFrm.dfm / NewProjectFrm.dfm: SVG 类已全部转换，但没有窗体级 .lfm，原因在本方案 SVG 范围之外
```

> 第一版的这一节把 `DataFrm.dfm:` 和 `NewProjectFrm.dfm:` **印成了空行**——因为它们唯一声明的 SVG 类正是已退役的 `TSVGIconImageList`，减完就空了。**空行读起来像「没有缺口」，而真实原因是完全不同的阻断项。** 现改为必须带原因打印。

### 13.5 路线图自身的反空转验证

工具的价值全在"会重算"。摘掉一个已转换窗体再跑：

| | SVG 消费端 | 仍阻断 | `TVirtualImage` 覆盖面 |
|---|---|---|---|
| 基线 | 15 | 6 | **3** (EnviroFrm, LangFrm, main) |
| 扰动（摘掉 LangFrm） | 14 | 5 | **2** (EnviroFrm, main) |
| 还原 | 15 | 6 | **3** |

`_generated.json` 还原后 MD5 一致，`f3_lfm_check.py` 仍 exit=0。

### 13.6 一条方法论

> **"还有几个窗体被挡着"是情绪指标，"退役哪一个能解锁几个"才是排期指标。** 前者回答一次就过期，后者每次都能重算。这个区别就是 `f3_batch_plan.py`（批次）与本工具（路线）并存的理由：批次回答"能不能转"，路线回答"先动哪个"。
